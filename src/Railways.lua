--[[
	War Front - railroads, train stations and trains (server).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Rules ported from OpenFront (AGPL-3.0): src/core/execution/FactoryExecution.ts,
	TrainStationExecution.ts, TrainExecution.ts, RecomputeRailClusterExecution.ts, CityExecution.ts /
	PortExecution.ts (createStation), src/core/game/RailNetworkImpl.ts, TrainStation.ts, Railroad.ts,
	src/core/pathfinding/algorithms/AStar.Rail.ts and DefaultConfig.ts (train numbers).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.Railways (ModuleScript), used by GameServer.
-- Railways.init(ctx) / setMap(map) / reset()
-- Railways.onBuilt(s)       a structure finished construction (City / Port / Factory matter)
-- Railways.onRemoved(s)     a structure was destroyed or deleted
-- Railways.tick()           every Play tick: port stations, train spawns, train movement
-- Railways.destroyInBlast(tile, radius2, nukerId)   nukes delete trains inside the blast
-- Railways.flush()          send this tick's "rails" / "trains" changes
-- Railways.sendInit(plr)    full rail network + trains for a (re)joining client
-- Railways.trainUnits() -> number
-- Scale: OpenFront distances / LINEAR_SCALE (4): station range 110 -> 27.5, min range 15 -> 3.75,
-- max railroad length 110 * 1.4142 -> 38.9 tiles, snap radius 3 -> 1 tile, train speed
-- 2 -> 0.5 tiles per tick, car spacing 2 -> 0.5 tiles. Train counts, spawn odds and gold are
-- not distances and stay as in OpenFront.
-- Network (server -> client):
--   "rails"  { add = { { id, tiles: buffer of u32 } ... }, remove = { id ... } }
--   "trains" { add = { { id, owner, path: buffer of u32 tiles, start: server time at path[1],
--                        speed: tiles / s, cars: number (carriages, plus engine + tail engine) } },
--              remove = { id ... } }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local MapUtil = require(Shared:WaitForChild("MapUtil"))

local Railways = {}

local L = Config.LINEAR_SCALE
local STATION_MAX_RANGE = 110 / L -- trainStationMaxRange
local STATION_MIN_RANGE = 15 / L -- trainStationMinRange
local RAILROAD_MAX_SIZE = 110 * 1.4142 / L -- railroadMaxSize (path tiles)
local MAX_CONNECTION_DISTANCE = 4 -- RailNetworkImpl.maxConnectionDistance (station hops)
local SNAP_RADIUS = 1 -- stationRadius 3 full-size, rounded up to one of our tiles
local TRAIN_SPEED = 2 / L -- tiles per tick
local TRAIN_CARS = 5 -- TrainStationExecution.numCars (plus engine and tail engine = 7 units)
local UNITS_PER_TRAIN = TRAIN_CARS + 2
local SPAWN_COOLDOWN = 10 -- ticks between two trains of one factory
local WATER_PENALTY, DIR_PENALTY, H_WEIGHT = 5, 3, 2 -- AStar.Rail
local ASTAR_LIMIT = 40000

local ctx: any = nil
local map: any = nil
local W, H, SIZE = 0, 0, 0
local NB = table.create(4)

local stations: { [number]: any } = {}
local stationOf: { [any]: any } = {}
local nextStationId = 1
local rails: { [number]: any } = {}
local nextRailId = 1
local railAt: { [number]: { [number]: boolean } } = {}
local trains: { [number]: any } = {}
local nextTrainId = 1
local clustersDirty = false
local nextPortCheck = 0

local outRailsAdd, outRailsRemove = {}, {}
local outTrainsAdd, outTrainsRemove = {}, {}

local function dist2(a: number, b: number): number
	local dx, dy = a % W - b % W, a // W - b // W
	return dx * dx + dy * dy
end

local function tilesBuffer(tiles: { number }): buffer
	local b = buffer.create(#tiles * 4)
	for i, t in tiles do
		buffer.writeu32(b, (i - 1) * 4, t)
	end
	return b
end

local function isWater(t: number): boolean
	return not MapUtil.isLand(map, t)
end

local function isShore(t: number): boolean
	return bit32.band(buffer.readu8(map.terrain, t), 64) ~= 0
end

local function impassable(t: number): boolean
	return MapUtil.isLand(map, t) and not MapUtil.isOwnable(map, t)
end

local function canTrade(a, b): boolean
	return ctx.canTrade(a, b)
end

local function ownerOf(st)
	return ctx.players()[st.s.owner]
end

local function isTradeStation(st): boolean
	return st.s.kind == "City" or st.s.kind == "Port"
end

local function stationActive(st): boolean
	return stations[st.id] == st and ctx.structures()[st.s.id] == st.s
end

-- TrainStation.tradeAvailable
local function tradeAvailable(st, player): boolean
	local o = ownerOf(st)
	if not o or not player then
		return false
	end
	return o == player or canTrade(player, o)
end

-- Rail pathfinding (AStar.Rail on our map)
local heapT, heapP = {}, {}
local function hpush(t, p)
	local n = #heapT + 1
	heapT[n], heapP[n] = t, p
	while n > 1 do
		local up = n // 2
		if heapP[up] <= p then
			break
		end
		heapT[n], heapP[n] = heapT[up], heapP[up]
		heapT[up], heapP[up] = t, p
		n = up
	end
end
local function hpop(): number?
	local n = #heapT
	if n == 0 then
		return nil
	end
	local top = heapT[1]
	local lt, lp = heapT[n], heapP[n]
	heapT[n], heapP[n] = nil, nil
	n -= 1
	if n > 0 then
		local i = 1
		while true do
			local c = i * 2
			if c > n then
				break
			end
			if c + 1 <= n and heapP[c + 1] < heapP[c] then
				c += 1
			end
			if heapP[c] >= lp then
				break
			end
			heapT[i], heapP[i] = heapT[c], heapP[c]
			i = c
		end
		heapT[i], heapP[i] = lt, lp
	end
	return top
end

local function traversable(from: number, to: number): boolean
	if impassable(from) or impassable(to) then
		return false
	end
	if not isWater(to) then
		return true
	end
	return isShore(from) or isShore(to)
end

local function railPath(from: number, to: number): { number }?
	table.clear(heapT)
	table.clear(heapP)
	local g = { [from] = 0 }
	local parent = { [from] = -1 }
	local closed = {}
	local gx, gy = to % W, to // W
	hpush(from, 0)
	local expanded = 0
	while true do
		local cur = hpop()
		if not cur then
			return nil
		end
		if not closed[cur] then
			closed[cur] = true
			if cur == to then
				local rev = {}
				local c = cur
				while c ~= -1 do
					rev[#rev + 1] = c
					c = parent[c]
				end
				local path = table.create(#rev)
				for i = #rev, 1, -1 do
					path[#path + 1] = rev[i]
				end
				return path
			end
			expanded += 1
			if expanded > ASTAR_LIMIT then
				return nil
			end
			local prev = parent[cur]
			local n = MapUtil.neighbors(map, cur, NB)
			local base = g[cur]
			for i = 1, n do
				local nt = NB[i]
				if not closed[nt] and traversable(cur, nt) then
					local c = if isWater(nt) or isShore(nt) then 1 + WATER_PENALTY else 1
					if prev ~= -1 and cur - prev ~= nt - cur then
						c += DIR_PENALTY
					end
					local ng = base + c
					local old = g[nt]
					if old == nil or ng < old then
						g[nt] = ng
						parent[nt] = cur
						hpush(nt, ng + H_WEIGHT * (math.abs(nt % W - gx) + math.abs(nt // W - gy)))
					end
				end
			end
		end
	end
end

-- Railroads
local function registerRail(r)
	rails[r.id] = r
	for _, t in r.tiles do
		local set = railAt[t]
		if not set then
			set = {}
			railAt[t] = set
		end
		set[r.id] = true
	end
	r.from.rails[r.id] = r
	r.to.rails[r.id] = r
	outRailsAdd[#outRailsAdd + 1] = { r.id, tilesBuffer(r.tiles) }
end

local function unregisterRail(r)
	if rails[r.id] ~= r then
		return
	end
	rails[r.id] = nil
	for _, t in r.tiles do
		local set = railAt[t]
		if set then
			set[r.id] = nil
			if next(set) == nil then
				railAt[t] = nil
			end
		end
	end
	r.from.rails[r.id] = nil
	r.to.rails[r.id] = nil
	outRailsRemove[#outRailsRemove + 1] = r.id
end

local function newRail(from, to, tiles)
	local r = { id = nextRailId, from = from, to = to, tiles = tiles }
	nextRailId += 1
	registerRail(r)
	return r
end

local function neighborsOf(st)
	local list = {}
	for _, r in st.rails do
		list[#list + 1] = if r.from == st then r.to else r.from
	end
	return list
end

local function railBetween(a, b)
	for _, r in a.rails do
		if (r.from == a and r.to == b) or (r.from == b and r.to == a) then
			return r
		end
	end
	return nil
end

-- Station hops from start to dest (-1 if not within maxDistance).
local function distanceFrom(start, dest, maxDistance: number): number
	if start == dest then
		return 0
	end
	local visited = { [start] = true }
	local queue = { { start, 0 } }
	local head = 1
	while head <= #queue do
		local st, d = queue[head][1], queue[head][2]
		head += 1
		if d < maxDistance then
			for _, nb in neighborsOf(st) do
				if nb == dest then
					return d + 1
				end
				if not visited[nb] then
					visited[nb] = true
					queue[#queue + 1] = { nb, d + 1 }
				end
			end
		end
	end
	return -1
end

local function connect(a, b): boolean
	local path = railPath(a.tile, b.tile)
	if path and #path > 0 and #path < RAILROAD_MAX_SIZE then
		newRail(a, b, path)
		return true
	end
	return false
end

-- Structures of the station kinds within range, nearest first.
local function nearbyStructures(tile: number, range: number, kinds: { [string]: boolean }, doneOnly: boolean)
	local r2 = range * range
	local list = {}
	for _, s in ctx.structures() do
		if kinds[s.kind] and (s.done or not doneOnly) then
			local d = dist2(s.tile, tile)
			if d <= r2 then
				list[#list + 1] = { s = s, d = d }
			end
		end
	end
	table.sort(list, function(x, y)
		return x.d < y.d
	end)
	return list
end

local STATION_KINDS = { City = true, Port = true, Factory = true }

-- Snaps the new station onto rails passing next to it (RailNetworkImpl.connectToExistingRails).
local function connectToExistingRails(st): boolean
	local found = {}
	local x0, y0 = st.tile % W, st.tile // W
	for y = math.max(0, y0 - SNAP_RADIUS), math.min(H - 1, y0 + SNAP_RADIUS) do
		for x = math.max(0, x0 - SNAP_RADIUS), math.min(W - 1, x0 + SNAP_RADIUS) do
			local set = railAt[y * W + x]
			if set then
				for id in set do
					found[id] = true
				end
			end
		end
	end
	local any = false
	local ids = {}
	for id in found do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ids do
		local r = rails[id]
		if r and r.from ~= st and r.to ~= st then
			local best, bestD = 1, math.huge
			for i, t in r.tiles do
				local d = dist2(t, st.tile)
				if d < bestD then
					best, bestD = i, d
				end
			end
			-- OpenFront skips the split when the closest tile is the rail's first tile.
			if best > 1 and best <= #r.tiles then
				local a, b = r.from, r.to
				unregisterRail(r)
				local t1 = table.move(r.tiles, 1, best - 1, 1, {})
				local t2 = table.move(r.tiles, best, #r.tiles, 1, {})
				newRail(a, st, t1)
				newRail(st, b, t2)
				any = true
				-- Trains already running over the split rail now stop at the new station too
				-- (OpenFront re-routes through it; the tiles they follow don't change).
				local n = #r.tiles
				for _, tr in trains do
					local i = tr.leg
					while i < #tr.stations do
						local s1, s2 = tr.stations[i], tr.stations[i + 1]
						local offset = nil
						if s1 == a and s2 == b then
							offset = best - 1
						elseif s1 == b and s2 == a then
							offset = n - best
						end
						if offset then
							local base = if i == 1 then 1 else tr.stops[i - 1]
							local stopIdx = base + offset
							if stopIdx > tr.pos and stopIdx < tr.stops[i] then
								table.insert(tr.stations, i + 1, st)
								table.insert(tr.stops, i, stopIdx)
								i += 1
							end
						end
						i += 1
					end
				end
			end
		end
	end
	return any
end

local function connectToNearbyStations(st)
	for _, e in nearbyStructures(st.tile, STATION_MAX_RANGE, STATION_KINDS, false) do
		local other = stationOf[e.s]
		if other and other ~= st then
			local hops = distanceFrom(other, st, MAX_CONNECTION_DISTANCE)
			if (hops == -1 or hops > MAX_CONNECTION_DISTANCE) and e.d > STATION_MIN_RANGE * STATION_MIN_RANGE then
				connect(st, other)
			end
		end
	end
end

local function addStation(s, spawnTrains: boolean)
	if stationOf[s] then
		local st = stationOf[s]
		st.spawnTrains = st.spawnTrains or spawnTrains
		return st
	end
	local st = {
		id = nextStationId,
		s = s,
		tile = s.tile,
		rails = {},
		spawnTrains = spawnTrains,
		lastSpawn = -1e9,
		cluster = nil,
	}
	nextStationId += 1
	stations[st.id] = st
	stationOf[s] = st
	if not connectToExistingRails(st) then
		connectToNearbyStations(st)
	end
	clustersDirty = true
	if ctx.stationBuilt and s.owner and s.owner ~= 0 then
		ctx.stationBuilt(s.owner)
	end
	return st
end

local function removeStation(st)
	for _, r in table.clone(st.rails) do
		unregisterRail(r)
	end
	stations[st.id] = nil
	stationOf[st.s] = nil
	clustersDirty = true
end

-- RecomputeRailClusterExecution: connected components of the station graph.
local function recomputeClusters()
	if not clustersDirty then
		return
	end
	clustersDirty = false
	for _, st in stations do
		st.cluster = nil
	end
	for _, st in stations do
		if not st.cluster then
			local cl = { stations = {}, trade = {} }
			local queue = { st }
			st.cluster = cl
			local head = 1
			while head <= #queue do
				local cur = queue[head]
				head += 1
				cl.stations[#cl.stations + 1] = cur
				if isTradeStation(cur) then
					cl.trade[#cl.trade + 1] = cur
				end
				for _, nb in neighborsOf(cur) do
					if not nb.cluster then
						nb.cluster = cl
						queue[#queue + 1] = nb
					end
				end
			end
		end
	end
end

local function factoryNearby(tile: number): boolean
	return #nearbyStructures(tile, STATION_MAX_RANGE, { Factory = true }, true) > 0
end

-- Structures
function Railways.onBuilt(s)
	if s.kind == "Factory" then
		-- FactoryExecution.createStation: the factory spawns trains; nearby cities, ports and
		-- factories become stations too.
		local nearby = nearbyStructures(s.tile, STATION_MAX_RANGE, STATION_KINDS, true)
		addStation(s, true)
		for _, e in nearby do
			if e.s ~= s and not stationOf[e.s] then
				addStation(e.s, e.s.kind == "Factory")
			end
		end
	elseif s.kind == "City" or s.kind == "Port" then
		-- CityExecution / PortExecution.createStation: only with a factory in range.
		if not stationOf[s] and factoryNearby(s.tile) then
			addStation(s, false)
		end
	end
end

function Railways.onRemoved(s)
	local st = stationOf[s]
	if st then
		removeStation(st)
	end
end

-- Trains
local function sigmoid(x: number, k: number, mid: number): number
	return 1 / (1 + math.exp(-k * (x - mid)))
end

-- DefaultConfig.trainSaturation / trainSpawnRate
local function trainSaturation(units: number): number
	local boost = 1 + 0.5 * math.exp(-units / 30)
	local damping = 1 - sigmoid(units, math.log(2) / 100, 560)
	local plateau = 0.25 * (1 - sigmoid(units, math.log(2) / 150, 900))
	return boost * math.max(damping, plateau)
end

function Railways.trainUnits(): number
	local n = 0
	for _ in trains do
		n += UNITS_PER_TRAIN
	end
	return n
end

local function trainSpawnRate(factories: number, units: number): number
	return math.max(1, math.floor((factories + 10) * 15 / trainSaturation(units)))
end

-- DefaultConfig.trainGold
local function trainGold(rel: string, visited: number): number
	visited = math.max(0, visited - 9)
	local base = if rel == "ally" then 35000 elseif rel == "self" then 10000 else 25000
	return math.floor(math.max(5000, base - visited * 5000) * (Config.GOLD_MULTIPLIER or 1)) -- goldMultiplier
end

-- Station path by fewest hops (PathFinder.Station, unit edge cost).
local function stationPath(from, to)
	if from.cluster ~= to.cluster then
		return nil
	end
	local parent = { [from] = false }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head += 1
		if cur == to then
			local rev = {}
			local c = cur
			while c do
				rev[#rev + 1] = c
				c = parent[c]
			end
			local path = {}
			for i = #rev, 1, -1 do
				path[#path + 1] = rev[i]
			end
			return path
		end
		for _, nb in neighborsOf(cur) do
			if parent[nb] == nil then
				parent[nb] = cur
				queue[#queue + 1] = nb
			end
		end
	end
	return nil
end

local function orientedTiles(a, b): { number }?
	local r = railBetween(a, b)
	if not r then
		return nil
	end
	if r.from == a then
		return r.tiles
	end
	local rev = table.create(#r.tiles)
	for i = #r.tiles, 1, -1 do
		rev[#rev + 1] = r.tiles[i]
	end
	return rev
end

local function spawnTrain(owner, source, dest)
	local path = stationPath(source, dest)
	if not path or #path <= 1 then
		return
	end
	local tiles = {}
	local stops = {} -- path index at which station k + 1 is reached
	for i = 1, #path - 1 do
		local seg = orientedTiles(path[i], path[i + 1])
		if not seg then
			return
		end
		for j, t in seg do
			if not (j == 1 and #tiles > 0 and tiles[#tiles] == t) then
				tiles[#tiles + 1] = t
			end
		end
		stops[i] = #tiles
	end
	local id = nextTrainId
	nextTrainId += 1
	local tr = {
		id = id,
		owner = owner.id,
		stations = path,
		tiles = tiles,
		stops = stops,
		leg = 1, -- heading to stations[leg + 1]
		pos = 1, -- 1-based position along tiles
		visited = 0,
		startTick = ctx.tick(),
	}
	trains[id] = tr
	outTrainsAdd[#outTrainsAdd + 1] = {
		id = id,
		owner = owner.id,
		path = tilesBuffer(tiles),
		start = SimClock.now(),
		speed = TRAIN_SPEED / Config.TICK,
		cars = TRAIN_CARS,
	}
end

local function removeTrain(tr)
	if trains[tr.id] == tr then
		trains[tr.id] = nil
		outTrainsRemove[#outTrainsRemove + 1] = tr.id
	end
end

-- TrainStation.rel: self, then teammates ("team", paid like "other"), then allies.
local function relation(a, b): string
	if a == b then
		return "self"
	elseif a.team ~= nil and a.team == b.team then
		return "team"
	elseif ctx.allied(a.id, b.id) then
		return "ally"
	end
	return "other"
end

-- TrainStation.onTrainStop (TradeStationStopHandler for cities and ports).
local function stationReached(tr, st)
	if isTradeStation(st) then
		local players = ctx.players()
		local trainOwner = players[tr.owner]
		local stOwner = ownerOf(st)
		if trainOwner and stOwner then
			local gold = trainGold(relation(trainOwner, stOwner), tr.visited)
			-- addGold(gold, station tile): shows "+gold" over the station for its owner.
			if stOwner ~= trainOwner then
				ctx.addIncome(stOwner, gold, st.tile)
			end
			ctx.addIncome(trainOwner, gold, st.tile)
		end
		tr.visited += 1
	end
end

local function tickTrain(tr)
	local players = ctx.players()
	local owner = players[tr.owner]
	local a, b = tr.stations[tr.leg], tr.stations[tr.leg + 1]
	if not owner or not owner.alive or not a or not b or not stationActive(a) or not stationActive(b) or not tradeAvailable(b, owner) then
		removeTrain(tr)
		return
	end
	tr.pos += TRAIN_SPEED
	while tr.pos >= tr.stops[tr.leg] do
		stationReached(tr, tr.stations[tr.leg + 1])
		tr.leg += 1
		if tr.leg >= #tr.stations then
			removeTrain(tr) -- destination reached
			return
		end
		local nxt = tr.stations[tr.leg + 1]
		if not stationActive(nxt) or not tradeAvailable(nxt, owner) then
			removeTrain(tr)
			return
		end
	end
end

local function tickFactory(st, now: number, units: number, factoryCount)
	if now < st.lastSpawn + SPAWN_COOLDOWN then
		return
	end
	local owner = ownerOf(st)
	local cl = st.cluster
	if not owner or not owner.alive or not cl then
		return
	end
	local eligible = {}
	for _, d in cl.trade do
		if stations[d.id] == d and tradeAvailable(d, owner) then
			eligible[#eligible + 1] = d
		end
	end
	if #eligible == 0 then
		return
	end
	local rate = trainSpawnRate(factoryCount[owner.id] or 0, units)
	local spawn = false
	for _ = 1, math.max(1, st.s.level or 1) do
		if ctx.rng:NextInteger(1, rate) == 1 then
			spawn = true
			break
		end
	end
	if not spawn then
		return
	end
	local dest = eligible[ctx.rng:NextInteger(1, #eligible)]
	if dest == st then
		return
	end
	spawnTrain(owner, st, dest)
	st.lastSpawn = now
end

function Railways.tick()
	local now = ctx.tick()
	-- PortExecution: a finished port without a station joins once a factory is in range.
	if now >= nextPortCheck then
		nextPortCheck = now + 10
		for _, s in ctx.structures() do
			if s.kind == "Port" and s.done and s.owner ~= 0 and not stationOf[s] and factoryNearby(s.tile) then
				addStation(s, false)
			end
		end
	end
	-- Stations whose structure vanished without a removal hook.
	for _, st in stations do
		if ctx.structures()[st.s.id] ~= st.s then
			removeStation(st)
		end
	end
	recomputeClusters()
	local units = Railways.trainUnits()
	local factoryCount = {}
	for _, s in ctx.structures() do
		if s.kind == "Factory" and s.owner ~= 0 then
			factoryCount[s.owner] = (factoryCount[s.owner] or 0) + 1
		end
	end
	for _, st in stations do
		if st.spawnTrains and st.s.done then
			tickFactory(st, now, units, factoryCount)
		end
	end
	for _, tr in trains do
		tickTrain(tr)
	end
end

function Railways.destroyInBlast(tile: number, radius2: number)
	for _, tr in trains do
		local t = tr.tiles[math.clamp(math.floor(tr.pos), 1, #tr.tiles)]
		if t and dist2(t, tile) < radius2 then
			removeTrain(tr)
		end
	end
end

function Railways.flush()
	if #outRailsAdd > 0 or #outRailsRemove > 0 then
		ctx.net:FireAllClients("rails", { add = outRailsAdd, remove = outRailsRemove })
		outRailsAdd, outRailsRemove = {}, {}
	end
	if #outTrainsAdd > 0 or #outTrainsRemove > 0 then
		ctx.net:FireAllClients("trains", { add = outTrainsAdd, remove = outTrainsRemove })
		outTrainsAdd, outTrainsRemove = {}, {}
	end
end

function Railways.sendInit(plr: Player)
	local add = {}
	for id, r in rails do
		add[#add + 1] = { id, tilesBuffer(r.tiles) }
	end
	ctx.net:FireClient(plr, "rails", { add = add, remove = {}, reset = true })
	local tadd = {}
	local now = SimClock.now()
	for _, tr in trains do
		tadd[#tadd + 1] = {
			id = tr.id,
			owner = tr.owner,
			path = tilesBuffer(tr.tiles),
			start = now - (tr.pos - 1) / TRAIN_SPEED * Config.TICK,
			speed = TRAIN_SPEED / Config.TICK,
			cars = TRAIN_CARS,
		}
	end
	ctx.net:FireClient(plr, "trains", { add = tadd, remove = {}, reset = true })
end

function Railways.init(c)
	ctx = c
	Railways.setMap(c.map)
end

function Railways.setMap(m)
	map = m
	W, H, SIZE = m.width, m.height, m.size
end

function Railways.reset()
	stations = {}
	stationOf = {}
	nextStationId = 1
	rails = {}
	nextRailId = 1
	railAt = {}
	trains = {}
	nextTrainId = 1
	clustersDirty = false
	nextPortCheck = 0
	outRailsAdd, outRailsRemove = {}, {}
	outTrainsAdd, outTrainsRemove = {}, {}
end

return Railways
