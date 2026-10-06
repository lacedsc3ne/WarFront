--[[
	War Front - authoritative game simulation.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local Theme = require(Shared:WaitForChild("Theme"))
local CoreRules = require(ServerScriptService:WaitForChild("CoreRules")) -- costs, placement, upgrades, delete, enclaves
local Diplomacy = require(ServerScriptService:WaitForChild("Diplomacy"))
local Warships = require(ServerScriptService:WaitForChild("Warships"))
local Missiles = require(ServerScriptService:WaitForChild("Missiles")) -- nukes in flight, MIRV, SAM missiles
local Railways = require(ServerScriptService:WaitForChild("Railways")) -- factories' railroads and trains
local Revive = require(ServerScriptService:WaitForChild("Revive"))
local Perks = require(ServerScriptService:WaitForChild("Perks")) -- gameplay perk passes and one-use boosts
local Emojis = require(Shared:WaitForChild("Emojis")) -- quick emoji relay (index into a fixed list)
-- Game flow (OpenFront parity): immunity, win check, embargo/target/quick chat, stats; tribe/nation AI.
local Flow = require(ServerScriptService:WaitForChild("GameFlow"))
local NationBuild = require(ServerScriptService:WaitForChild("NationBuild")) -- nation structures, warships, MIRVs
local Teams = require(ServerScriptService:WaitForChild("Teams")) -- team games (modes, assignment, team win)
local Perf = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Perf")) -- workspace attribute FrontlinesPerfServer
local AiBehavior = require(ServerScriptService:WaitForChild("AiBehavior"))
local TribeNames = require(ServerScriptService:WaitForChild("TribeNames"))

local Progression
do
	local mod = ServerScriptService:FindFirstChild("Progression")
	if mod then
		local ok, result = pcall(require, mod)
		if ok then
			Progression = result
		else
			warn("[War Front] Progression failed to load: " .. tostring(result))
		end
	end
end

Players.CharacterAutoLoads = false

-- Matchmaking: this server is the lobby (no rounds; Matchmaker runs the queues), a match server
-- (one round with the lobby's settings, then back to the lobby) or standalone (rounds forever).
local Place = require(Shared:WaitForChild("Place"))
local Matchmaker = require(ServerScriptService:WaitForChild("Matchmaker"))
local match = {
	role = Place.role(),
	cfg = nil :: any, -- Matchmaker.matchConfig() on a match server
	rules = {} :: any, -- cfg.settings: bots, nations, difficulty, instantBuild, infiniteGold, ...
	ready = false, -- settings loaded (match servers)
	waitUntil = nil :: number?, -- tick to start even if not everyone arrived
	done = false, -- the round finished and players were sent back to the lobby
	roundHumans = {} :: { number }, -- ranked: userIds that played the round
}
-- Round rules shared with the clients (modifiers: disabled units, alliances, water nukes, Doomsday
-- Clock, overtime, gold multiplier, compact map) and the Doomsday Clock itself.
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local DoomsdayClock = require(ServerScriptService:WaitForChild("DoomsdayClock"))
-- Loaded map: the catalog id, compact or not, a revision bumped on every (re)load, and the tiles
-- water nukes turned into water this round (late joiners replay them).
local mapState = { compact = false, rev = 0, edited = false, water = {} :: { number }, pending = {} :: { number } }

local net = Shared:FindFirstChild("Net") or Instance.new("RemoteEvent")
net.Name = "Net"
net.Parent = Shared

local MapCatalog = require(Shared:WaitForChild("MapCatalog"))
local mapsFolder = Shared:WaitForChild("Maps")
local currentMapId = "Europe"
local map = MapUtil.load(mapsFolder:WaitForChild(currentMapId))
local W, HGT, SIZE = map.width, map.height, map.size
local rng = Random.new()

local NB = table.create(4)
local NB2 = table.create(4)
local NB3 = table.create(4)

local FALLOUT_OWNER = 65535 -- wire marker: unowned tile with fallout

-- State
local owner: buffer -- u16 owner id per tile (0 = nobody)
local fallout: buffer -- u8 per tile
local changedFlag: buffer
local changedList: { number }
local players: { [number]: any }
local nextId: number
local attacks: { any }
local structures: { [number]: any }
local structureAt: { [number]: any }
local nextStructureId: number
local boats: { [number]: any }
local nextBoatId: number
local nukes: { [number]: any }
local nextNukeId: number
local spawnTiles: { number }
local routeCache: { [string]: any }
local tick = 0
local roundStartTick = 0
local phase = "Lobby" -- Lobby | Spawn | Play | Ended
local phaseEndTick = 0
local winnerName: string? = nil
-- Team games: this round's mode, the mode the lobby is voting into, rounds played, winning team,
-- and the team names in play.
local teamState = { mode = { kind = "FFA" }, nextMode = { kind = "FFA" }, round = 0, winner = nil :: string?, list = {} :: { string } }
-- In-match interaction rules taken from OpenFront (retreat, delete, emoji): winnerId is the round
-- winner's player id for the win modal.
local interactRules = {
	RETREAT_DELAY = 20, -- ticks an ordered retreat holds the attack before the troops come home
	RETREAT_MALUS = 0.25, -- share of the troops lost retreating from a player (or by boat)
	DELETE_COOLDOWN = 300, -- ticks between deleting your own structures
	DELETE_RADIUS = 5, -- Manhattan tiles around the clicked tile
	winnerId = 0,
}
local structuresDirty = false
local rosterDirty = false
local byUser: { [number]: any } = {}
-- Players who pressed Play in the main menu. Only they are put into rounds.
local wantsPlay: { [number]: boolean } = {}
local eliminationOrder: { any } = {}

local function getOwner(t: number): number
	return buffer.readu16(owner, t * 2)
end

local function ownable(t: number): boolean
	return MapUtil.isOwnable(map, t)
end

local function isWater(t: number): boolean
	return not MapUtil.isLand(map, t)
end

local function coastal(t: number): boolean
	local n = MapUtil.neighbors(map, t, NB3)
	for i = 1, n do
		if isWater(NB3[i]) then
			return true
		end
	end
	return false
end

local function dist2(a: number, b: number): number
	local dx, dy = a % W - b % W, a // W - b // W
	return dx * dx + dy * dy
end

local function packRGB(r: number, g: number, b: number): number
	return math.floor(r) * 65536 + math.floor(g) * 256 + math.floor(b)
end

-- OpenFront palettes (Theme.lua): distinct human / nation colours per round, one flat bot colour.
local roundColors = Theme.newRoundColors()
local function nextColor(kind: string): number
	return roundColors:take(kind)
end

local function feed(text: string, kind: string?, ownerId: number?)
	net:FireAllClients("event", { text = text, kind = kind or "info", owner = ownerId or 0 })
end

local function playerOf(p): Player?
	return if p.userId then Players:GetPlayerByUserId(p.userId) else nil
end

-- Event shown to one player only (OpenFront displayMessage / displayIncomingUnit to a player id).
local function notify(playerId: number, text: string, kind: string?)
	local p = players and players[playerId]
	local plr = p and playerOf(p)
	if plr then
		net:FireClient(plr, "event", { text = text, kind = kind or "info", owner = playerId })
	end
end

-- PlayerImpl.canTrade: no embargo in either direction (embargoes live in GameFlow).
local function canTrade(a, b): boolean
	return a ~= nil and b ~= nil and a ~= b and Flow.canTrade(a.id, b.id)
end

-- Tile ownership
local function markChanged(t: number)
	if buffer.readu8(changedFlag, t) == 0 then
		buffer.writeu8(changedFlag, t, 1)
		changedList[#changedList + 1] = t
	end
end

local function refreshBorder(t: number)
	local o = getOwner(t)
	if o == 0 then
		return
	end
	local p = players[o]
	local n = MapUtil.neighbors(map, t, NB2)
	local isBorder = false
	for i = 1, n do
		if getOwner(NB2[i]) ~= o then
			isBorder = true
			break
		end
	end
	p.border[t] = if isBorder then true else nil
end

local function transferStructure(s, newOwner: number)
	local old = s.owner
	if old ~= 0 and players[old] then
		local op = players[old]
		op.counts[s.kind] -= 1
		op.structs[s] = nil
		if s.kind == "City" and s.done then
			op.cities -= (s.level or 1) -- max troops count finished city levels
		end
	end
	s.owner = newOwner
	if newOwner ~= 0 then
		local np = players[newOwner]
		np.counts[s.kind] = (np.counts[s.kind] or 0) + 1
		np.structs[s] = true
		if s.kind == "City" and s.done then
			np.cities += (s.level or 1)
		end
	end
	structuresDirty = true
end

local function removeStructure(s)
	Railways.onRemoved(s)
	if s.owner ~= 0 and players[s.owner] then
		local op = players[s.owner]
		op.counts[s.kind] -= 1
		op.structs[s] = nil
		if s.kind == "City" and s.done then
			op.cities -= (s.level or 1)
		end
	end
	structures[s.id] = nil
	structureAt[s.tile] = nil
	structuresDirty = true
end

local function setOwner(t: number, newOwner: number)
	local old = getOwner(t)
	if old == newOwner then
		return
	end
	local x, y = t % W, t // W
	if old ~= 0 then
		local op = players[old]
		op.tiles -= 1
		op.sumX -= x
		op.sumY -= y
		op.border[t] = nil
	end
	buffer.writeu16(owner, t * 2, newOwner)
	if newOwner ~= 0 then
		local np = players[newOwner]
		np.tiles += 1
		np.sumX += x
		np.sumY += y
		if np.tiles > np.peakTiles then
			np.peakTiles = np.tiles
		end
		buffer.writeu8(fallout, t, 0)
	end

	local s = structureAt[t]
	if s then
		if newOwner == 0 or s.kind == "DefensePost" then -- PlayerExecution: captured defense posts are destroyed
			removeStructure(s)
		else
			transferStructure(s, newOwner)
		end
	end

	markChanged(t)
	refreshBorder(t)
	local n = MapUtil.neighbors(map, t, NB)
	for i = 1, n do
		refreshBorder(NB[i])
	end
end

-- Players
local function newPlayer(name: string, kind: string, userId: number?)
	local id = nextId
	nextId += 1
	local p = {
		id = id,
		name = name,
		kind = kind,
		userId = userId,
		color = nextColor(kind),
		troops = Config.START_TROOPS[kind],
		gold = 0,
		tiles = 0,
		peakTiles = 0,
		sumX = 0,
		sumY = 0,
		border = {},
		alive = true,
		spawned = false,
		spawnTile = nil,
		cities = 0, -- finished cities
		counts = {}, -- structures per kind, incl. under construction
		structs = {},
		maxTroops = Config.maxTroops(kind, 0, 0), -- so the HUD shows a real cap during the spawn phase
		outgoing = {},
		boats = 0,
		kills = 0,
		level = 0,
		vip = false,
	}
	if kind ~= "Human" then
		p.ai = AiBehavior.newState(kind) -- OpenFront TribeExecution / NationExecution parameters
	end
	players[id] = p
	rosterDirty = true
	return p
end

local function endAttack(a, refund: boolean)
	for i, other in attacks do
		if other == a then
			table.remove(attacks, i)
			break
		end
	end
	a.attacker.outgoing[a] = nil
	if refund and a.attacker.alive then
		a.attacker.troops += math.max(0, a.troops)
	end
	a.dead = true
end

local function killPlayer(p, killer)
	if not p.alive then
		return
	end
	p.alive = false
	p.troops = 0
	p.deathTick = tick
	table.insert(eliminationOrder, p)
	for a in pairs(p.outgoing) do
		endAttack(a, false)
	end
	for s in pairs(p.structs) do
		removeStructure(s)
	end
	if killer and killer.alive then
		killer.kills += 1
		-- Gold (and the "conquest" event) only change hands through CoreRules.conquerPlayer, as in
		-- OpenFront: conquered by attack or encirclement, not by a nuke.
	end
	Flow.noteKill(if killer and killer.alive then killer else nil, p, p.conquestGold or 0)
	p.gold = 0
	rosterDirty = true
	Revive.onKilled(p, killer)
	if p.kind ~= "Bot" then
		feed(p.name .. " was eliminated" .. (if killer then " by " .. killer.name else ""), "death", p.id)
	end
end

Diplomacy.init({
	net = net,
	players = function()
		return players
	end,
	feed = feed,
	endAttack = endAttack,
	playerOf = playerOf,
	-- OpenFront alliance answers and relation updates (AiBehavior / GameFlow).
	aiAnswer = function(nation, from, renew: boolean): boolean
		return AiBehavior.allianceAnswer(nation, from, renew)
	end,
	onAllianceFormed = function(p, q)
		Flow.updateRelation(p, q.id, 100)
		Flow.updateRelation(q, p.id, 100)
		Flow.endTemporaryEmbargo(p, q.id)
		Flow.endTemporaryEmbargo(q, p.id)
	end,
	onAllianceBroken = function(p, q)
		-- BreakAllianceExecution: the betrayed side hates the breaker, its neighbours distrust it.
		Flow.updateRelation(q, p.id, -100)
		for _, o in players do
			if o ~= p and o ~= q and o.kind == "Nation" and o.alive then
				for bt in pairs(p.border) do
					local n = MapUtil.neighbors(map, bt, NB3)
					local hit = false
					for i = 1, n do
						if getOwner(NB3[i]) == o.id then
							hit = true
							break
						end
					end
					if hit then
						Flow.updateRelation(o, p.id, -40)
						break
					end
				end
			end
		end
	end,
	onDonate = function(p, q, what: string, amount: number, t: number)
		if what == "troops" then
			Flow.updateRelation(q, p.id, 50)
		else
			-- DonateGoldExecution: 5 points per chunk (Medium 5,000 gold, growing every 5 min), max 100.
			local chunk = 5000 * (1 + (t - roundStartTick) / 3000)
			Flow.updateRelation(q, p.id, math.min(100, math.floor(amount / chunk) * 5))
		end
	end,
})

Flow.init({
	net = net,
	players = function()
		return players
	end,
	tick = function()
		return tick
	end,
	phase = function()
		return phase
	end,
	roundStartTick = function()
		return roundStartTick
	end,
	landTiles = function()
		return map.landTiles
	end,
	fallout = function()
		return fallout
	end,
	size = function()
		return SIZE
	end,
	playerOf = playerOf,
	allied = function(a: number, b: number): boolean
		return Diplomacy.allied(a, b)
	end,
	decline = function(p, q)
		Diplomacy.decline(p, q)
	end,
})

-- Spawning
local function farFromSpawns(t: number, minDist: number, ignore: number?): boolean
	local x, y = t % W, t // W
	for _, s in spawnTiles do
		if s ~= ignore and math.abs(s % W - x) + math.abs(s // W - y) < minDist then
			return false
		end
	end
	return true
end

local function claimSpawn(p, t: number)
	local r = Config.SPAWN_RADIUS
	local cx, cy = t % W, t // W
	for dy = -r, r do
		for dx = -r, r do
			if dx * dx + dy * dy <= r * r then
				local x, y = cx + dx, cy + dy
				if x >= 0 and x < W and y >= 0 and y < HGT then
					local tt = y * W + x
					if ownable(tt) and getOwner(tt) == 0 then
						setOwner(tt, p.id)
					end
				end
			end
		end
	end
	p.spawned = true
	p.spawnTile = t
	spawnTiles[#spawnTiles + 1] = t
	Flow.noteSpawn(p, t)
end

local function unclaimSpawn(p)
	if not p.spawnTile then
		return
	end
	for i, s in spawnTiles do
		if s == p.spawnTile then
			table.remove(spawnTiles, i)
			break
		end
	end
	local r = Config.SPAWN_RADIUS
	local cx, cy = p.spawnTile % W, p.spawnTile // W
	for dy = -r, r do
		for dx = -r, r do
			local x, y = cx + dx, cy + dy
			if x >= 0 and x < W and y >= 0 and y < HGT then
				local tt = y * W + x
				if getOwner(tt) == p.id then
					setOwner(tt, 0)
				end
			end
		end
	end
	p.spawned = false
	p.spawnTile = nil
end

local function randomSpawnTile(minDist: number): number?
	for _ = 1, 4000 do
		local t = rng:NextInteger(0, SIZE - 1)
		if ownable(t) and getOwner(t) == 0 and farFromSpawns(t, minDist) then
			return t
		end
	end
	return nil
end

local function nearestTile(x: number, y: number, maxR: number, pred: (number) -> boolean): number?
	for r = 0, maxR do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local xx, yy = x + dx, y + dy
					if xx >= 0 and xx < W and yy >= 0 and yy < HGT then
						local t = yy * W + xx
						if pred(t) then
							return t
						end
					end
				end
			end
		end
	end
	return nil
end

-- Water pathfinding (BFS over water tiles)
local bfsStamp = buffer.create(SIZE * 2)
local bfsParent = buffer.create(SIZE * 4)
local bfsGen = 0
local BFS_LIMIT = 160000

-- Searches from the water next to `fromLand` until it reaches water next to a land tile
-- that satisfies `isGoal`. Returns the water path ordered from the goal side to the side
-- next to fromLand, plus the goal land tile, or nil.
local function waterPath(fromLand: number, isGoal: (number) -> boolean): ({ number }?, number?)
	bfsGen = (bfsGen % 65534) + 1
	if bfsGen == 1 then
		buffer.fill(bfsStamp, 0, 0)
	end
	local queue = {}
	local head = 1
	local n = MapUtil.neighbors(map, fromLand, NB)
	for i = 1, n do
		local w = NB[i]
		if isWater(w) and buffer.readu16(bfsStamp, w * 2) ~= bfsGen then
			buffer.writeu16(bfsStamp, w * 2, bfsGen)
			buffer.writei32(bfsParent, w * 4, -1)
			queue[#queue + 1] = w
		end
	end
	local visited = #queue
	while head <= #queue do
		local w = queue[head]
		head += 1
		local m = MapUtil.neighbors(map, w, NB2)
		for i = 1, m do
			local nt = NB2[i]
			if isWater(nt) then
				if buffer.readu16(bfsStamp, nt * 2) ~= bfsGen then
					buffer.writeu16(bfsStamp, nt * 2, bfsGen)
					buffer.writei32(bfsParent, nt * 4, w)
					queue[#queue + 1] = nt
					visited += 1
				end
			elseif nt ~= fromLand and isGoal(nt) then
				-- Walk back to the start.
				local path = {}
				local cur = w
				while cur ~= -1 do
					path[#path + 1] = cur
					cur = buffer.readi32(bfsParent, cur * 4)
				end
				return path, nt
			end
		end
		if visited > BFS_LIMIT then
			break
		end
	end
	return nil, nil
end

-- Trade routes: the same BFS run as a background job (own buffers), resumed for a few ms each
-- tick, so a new port pair never stalls the simulation. One job at a time.
local routeJobs = {
	stamp = buffer.create(SIZE * 2),
	parent = buffer.create(SIZE * 4),
	gen = 0,
	job = nil :: any, -- { key = string, co = thread }
	BUDGET = 0.003, -- seconds per tick
}
function routeJobs.search(fromLand: number, goal: number): { number }?
	local stamp, parent = routeJobs.stamp, routeJobs.parent
	routeJobs.gen = (routeJobs.gen % 65534) + 1
	local gen = routeJobs.gen
	if gen == 1 then
		buffer.fill(stamp, 0, 0)
	end
	local nb, nb2 = {}, {}
	local queue = {}
	local head = 1
	local n = MapUtil.neighbors(map, fromLand, nb)
	for i = 1, n do
		local w = nb[i]
		if isWater(w) and buffer.readu16(stamp, w * 2) ~= gen then
			buffer.writeu16(stamp, w * 2, gen)
			buffer.writei32(parent, w * 4, -1)
			queue[#queue + 1] = w
		end
	end
	local t0 = os.clock()
	local steps = 0
	while head <= #queue do
		local w = queue[head]
		head += 1
		local m = MapUtil.neighbors(map, w, nb2)
		for i = 1, m do
			local nt = nb2[i]
			if isWater(nt) then
				if buffer.readu16(stamp, nt * 2) ~= gen then
					buffer.writeu16(stamp, nt * 2, gen)
					buffer.writei32(parent, nt * 4, w)
					queue[#queue + 1] = nt
				end
			elseif nt == goal then
				local path = {}
				local cur = w
				while cur ~= -1 do
					path[#path + 1] = cur
					cur = buffer.readi32(parent, cur * 4)
				end
				return path
			end
		end
		if #queue > BFS_LIMIT then
			break
		end
		steps += 1
		if steps % 256 == 0 and os.clock() - t0 > routeJobs.BUDGET then
			coroutine.yield()
			t0 = os.clock()
		end
	end
	return nil
end
function routeJobs.step()
	local job = routeJobs.job
	if not job then
		return
	end
	local ok, path = coroutine.resume(job.co)
	if not ok then
		warn("trade route search failed: " .. tostring(path))
		routeCache[job.key] = false
		routeJobs.job = nil
	elseif coroutine.status(job.co) == "dead" then
		routeCache[job.key] = path or false
		routeJobs.job = nil
	end
end

-- Attacks
-- Used by warships so they never fire on allied ships.
local function isAllied(aId: number, bId: number): boolean
	return Diplomacy.allied(aId, bId)
end

local function heapPush(a, tile: number, pri: number)
	local keys, vals = a.hk, a.hv
	local i = #keys + 1
	keys[i], vals[i] = pri, tile
	while i > 1 do
		local parent = i // 2
		if keys[parent] <= keys[i] then
			break
		end
		keys[parent], keys[i] = keys[i], keys[parent]
		vals[parent], vals[i] = vals[i], vals[parent]
		i = parent
	end
end

local function heapPop(a): number?
	local keys, vals = a.hk, a.hv
	local n = #keys
	if n == 0 then
		return nil
	end
	local top = vals[1]
	keys[1], vals[1] = keys[n], vals[n]
	keys[n], vals[n] = nil, nil
	n -= 1
	local i = 1
	while true do
		local l, r, s = i * 2, i * 2 + 1, i
		if l <= n and keys[l] < keys[s] then s = l end
		if r <= n and keys[r] < keys[s] then s = r end
		if s == i then break end
		keys[s], keys[i] = keys[i], keys[s]
		vals[s], vals[i] = vals[i], vals[s]
		i = s
	end
	return top
end

local function enqueueFront(a, t: number)
	if not a.front[t] then
		a.front[t] = true
		a.frontCount += 1
	end
	local me = a.attacker.id
	local mine = 0
	local n = MapUtil.neighbors(map, t, NB2)
	for i = 1, n do
		if getOwner(NB2[i]) == me then
			mine += 1
		end
	end
	local cls = Config.terrainClass(MapUtil.magnitude(map, t))
	local roughness = if cls == Config.PLAINS then 1 elseif cls == Config.HIGHLAND then 1.5 else 2
	-- Tiles touching more of our land and flatter tiles are taken first, with jitter.
	local pri = (rng:NextInteger(0, 7) + 10) * (1 - mine * 0.5 + roughness / 2) + tick
	heapPush(a, t, pri)
end

local function addNeighborsOf(a, t: number)
	local n = MapUtil.neighbors(map, t, NB)
	for i = 1, n do
		local nt = NB[i]
		if getOwner(nt) == a.target and ownable(nt) then
			enqueueFront(a, nt)
		end
	end
end

local function rebuildFront(a)
	a.hk, a.hv = {}, {}
	a.front, a.frontCount = {}, 0
	for bt in pairs(a.attacker.border) do
		local n = MapUtil.neighbors(map, bt, NB)
		for i = 1, n do
			local nt = NB[i]
			if getOwner(nt) == a.target and ownable(nt) and not a.front[nt] then
				enqueueFront(a, nt)
			end
		end
	end
end

local function adjacentTo(t: number, id: number): boolean
	local n = MapUtil.neighbors(map, t, NB2)
	for i = 1, n do
		if getOwner(NB2[i]) == id then
			return true
		end
	end
	return false
end

local function isDefended(defender, t: number): boolean
	local r2 = Config.DEFENSE_RADIUS * Config.DEFENSE_RADIUS
	for s in pairs(defender.structs) do
		if s.kind == "DefensePost" and s.done and dist2(s.tile, t) <= r2 then
			return true
		end
	end
	return false
end

local function findAttack(p, targetId: number)
	for a in pairs(p.outgoing) do
		if a.target == targetId then
			return a
		end
	end
	return nil
end

local nextAttackUid = 0
local function registerAttack(a)
	CoreRules.noteAttack(a.attacker) -- conquest gold: a human who never attacked "didn't play"
	nextAttackUid += 1
	a.uid = nextAttackUid
	attacks[#attacks + 1] = a
	a.attacker.outgoing[a] = true
end

-- Cancels troops against an opposing attack. Returns the troops left over.
local function cancelOpposing(p, targetId: number, troops: number): number
	if targetId == 0 then
		return troops
	end
	for other in pairs(players[targetId].outgoing) do
		if other.target == p.id then
			if other.troops >= troops then
				other.troops -= troops
				return 0
			end
			troops -= other.troops
			endAttack(other, false)
			return troops
		end
	end
	return troops
end

-- Land attack. Returns true if it was started (troops spent).
local function startLandAttack(p, targetId: number, troops: number): boolean
	-- Flow.canAttackPlayer: allies (unless disconnected) and, for human attackers, immune players.
	if not Flow.canAttackPlayer(p, targetId) or Revive.blocks(p, targetId) then
		return false
	end
	local existing = findAttack(p, targetId)
	if existing then
		Flow.onAttack(p, targetId)
		Flow.stat(p, "troopsSent", troops)
		existing.retreatAt = nil -- new troops call off a pending retreat
		p.troops -= troops
		existing.troops += troops
		rebuildFront(existing)
		return true
	end
	local a = { attacker = p, target = targetId, troops = troops, hk = {}, hv = {}, front = {}, frontCount = 0 }
	rebuildFront(a)
	if a.frontCount == 0 then
		return false
	end
	p.troops -= troops
	Flow.onAttack(p, targetId)
	Flow.stat(p, "troopsSent", troops)
	a.troops = cancelOpposing(p, targetId, a.troops)
	if a.troops > 0 then
		registerAttack(a)
	end
	return true
end

local function conquerTile(a, t: number, borderSize: number): (boolean, number)
	local att = a.attacker
	local defender = if a.target ~= 0 then players[a.target] else nil
	local cls = Config.terrainClass(MapUtil.magnitude(map, t))
	local defended = defender ~= nil and isDefended(defender, t)
	local falloutRatio = if buffer.readu8(fallout, t) == 1 then CoreRules.falloutRatio() else nil
	local traitor = defender ~= nil and Diplomacy.isTraitor(defender.id, tick)
	local loss, dLoss, frac = Config.attackTile(att, defender, a.troops, cls, borderSize, defended, falloutRatio, traitor)
	a.troops -= loss
	if defender then
		defender.troops = math.max(0, defender.troops - dLoss)
	end
	setOwner(t, att.id)
	addNeighborsOf(a, t)
	if defender then
		CoreRules.handleDeadDefender(att, defender) -- under 100 full-size tiles: conquered outright
	end
	if defender and defender.tiles <= 0 then
		killPlayer(defender, att)
		endAttack(a, true)
		return true, frac
	end
	return false, frac
end

local function tickAttack(a)
	local att = a.attacker
	local defender = if a.target ~= 0 then players[a.target] else nil
	if not att.alive or (defender and not defender.alive) then
		endAttack(a, true)
		return
	end
	if a.retreatAt then
		-- Ordered retreat (OpenFront RetreatExecution): the front holds, then the troops come home,
		-- minus a malus when retreating from a player.
		if tick >= a.retreatAt then
			local deaths = if a.target ~= 0 then math.floor(a.troops * interactRules.RETREAT_MALUS) else 0
			att.troops += math.max(0, a.troops - deaths)
			endAttack(a, false)
			local plr = playerOf(att)
			if plr and deaths > 0 then
				net:FireClient(plr, "event", { text = string.format("Attack cancelled, %d soldiers killed during retreat", deaths), kind = "attack", owner = att.id })
			end
		end
		return
	end
	-- AttackExecution: border size + random 0..4 full-size tiles (/ LINEAR_SCALE here).
	local borderSize = a.frontCount + rng:NextInteger(0, Config.ATTACK_BORDER_JITTER) / Config.LINEAR_SCALE
	local budget = 1
	while budget > 0 do
		if a.troops < 1 then
			endAttack(a, false)
			return
		end
		local t = heapPop(a)
		if t == nil then
			endAttack(a, true)
			return
		end
		if a.front[t] then
			a.front[t] = nil
			a.frontCount -= 1
		end
		if getOwner(t) == a.target and ownable(t) and adjacentTo(t, att.id) then
			local finished, frac = conquerTile(a, t, borderSize)
			if finished then
				return
			end
			budget -= frac
		end
	end
end

-- Boats (transport ships)
local function launchBoat(p, clickTile: number, troops: number): boolean
	if p.boats >= Config.MAX_BOATS then
		return false
	end
	local targetId = getOwner(clickTile)
	if not Flow.canAttackPlayer(p, targetId) or Revive.blocks(p, targetId) then
		return false
	end
	-- Landing spot: the coastal tile of the target nearest to where the player clicked.
	local landing = nearestTile(clickTile % W, clickTile // W, 20, function(t)
		return getOwner(t) == targetId and ownable(t) and coastal(t)
	end)
	if not landing then
		return false
	end
	local path, _ = waterPath(landing, function(t)
		return getOwner(t) == p.id
	end)
	if not path or #path < 2 then
		return false
	end
	-- path runs from our coast to the landing; the last element is the water next to the landing.
	troops = math.floor(math.min(troops, p.troops))
	if troops < 1 then
		return false
	end
	p.troops -= troops
	p.boats += 1
	Flow.stat(p, "boatsSent", 1)
	Flow.stat(p, "troopsSent", troops)
	local id = nextBoatId
	nextBoatId += 1
	local boat = {
		id = id,
		owner = p.id,
		troops = troops,
		path = path,
		pos = 1,
		landing = landing,
		kind = "transport",
	}
	-- The search started at the landing, so the path already runs from our coast to the landing.
	boats[id] = boat
	local pathBuf = buffer.create(#path * 4)
	for i, t in path do
		buffer.writeu32(pathBuf, (i - 1) * 4, t)
	end
	net:FireAllClients("boat", {
		id = id,
		owner = p.id,
		kind = "transport",
		troops = troops,
		path = pathBuf,
		start = SimClock.now(),
		speed = Config.BOAT_SPEED / Config.TICK,
	})
	return true
end

local function removeBoat(b)
	boats[b.id] = nil
	if b.kind == "transport" then
		local p = players[b.owner]
		if p then
			p.boats -= 1
		end
	end
	net:FireAllClients("boatEnd", b.id)
end

local function landBoat(b)
	local p = players[b.owner]
	removeBoat(b)
	if not p or not p.alive then
		return
	end
	if b.retreating then
		-- Back home (OpenFront TransportShipExecution): the troops rejoin, minus the retreat malus.
		local deaths = math.floor(b.troops * interactRules.RETREAT_MALUS)
		p.troops += b.troops - deaths
		local plr = playerOf(p)
		if plr and deaths > 0 then
			net:FireClient(plr, "event", { text = string.format("Attack cancelled, %d soldiers killed during retreat", deaths), kind = "attack", owner = p.id })
		end
		return
	end
	local L = b.landing
	local targetId = getOwner(L)
	if targetId == p.id or Flow.isFriendly(p, targetId) or Revive.shielded(targetId) then
		p.troops += b.troops -- allied (or target shielded) while at sea: the troops come home
		return
	end
	local defender = if targetId ~= 0 then players[targetId] else nil
	Flow.onAttack(p, targetId) -- the landing starts an attack (AttackExecution.init)
	local troops = cancelOpposing(p, targetId, b.troops)
	if troops <= 0 then
		return
	end
	local a = findAttack(p, targetId)
	if a then
		a.troops += troops
	else
		a = { attacker = p, target = targetId, troops = troops, hk = {}, hv = {}, front = {}, frontCount = 0 }
		registerAttack(a)
	end
	-- Take the beach, then push inland from it. The landing tile is remembered for nations'
	-- beachhead follow-up attacks (AiAttackBehavior.followUpLandings uses attack.sourceTile()).
	a.landing, a.followed = L, false
	local finished = conquerTile(a, L, math.max(1, a.frontCount))
	if not finished and a.frontCount == 0 then
		endAttack(a, true)
	end
	if defender and defender.alive and defender.kind ~= "Bot" then
		feed(p.name .. " landed troops in " .. defender.name, "attack", p.id)
	end
end

-- Trade ships
local function announceBoat(b)
	local pathBuf = buffer.create(#b.path * 4)
	for i, t in b.path do
		buffer.writeu32(pathBuf, (i - 1) * 4, t)
	end
	net:FireAllClients("boat", {
		id = b.id,
		owner = b.owner,
		kind = b.kind,
		troops = b.troops,
		path = pathBuf,
		start = SimClock.now() - (b.pos - 1) / Config.BOAT_SPEED * Config.TICK,
		speed = Config.BOAT_SPEED / Config.TICK,
		retreating = b.retreating,
	})
end

-- DefaultConfig.tradeShipSaturation (global spawn throttle by trade ships at sea).
local function tradeSaturation(numShips: number): number
	local function sigmoid(x, k, mid)
		return 1 / (1 + math.exp(-k * (x - mid)))
	end
	local boost = 1 + 0.45 * math.exp(-numShips / 120)
	local damping = 1 - sigmoid(numShips, math.log(2) / 50, 330)
	local plateau = 0.25 * (1 - sigmoid(numShips, math.log(2) / 100, 800))
	return boost * math.max(damping, plateau)
end

local TRADE_SHORT_RANGE = 300 / Config.LINEAR_SCALE -- tradeShipShortRangeDebuff (Manhattan tiles)

-- A new water route is a BFS over the whole sea (tens of ms on big maps): it runs as a
-- background job (routeJobs) and the reverse of a known route is reused.
local function tradeRoute(port, dest)
	local key = port.id .. ">" .. dest.id
	local route = routeCache[key]
	if route == nil then
		local back = routeCache[dest.id .. ">" .. port.id]
		if back ~= nil then
			if back then
				route = table.create(#back)
				for i = #back, 1, -1 do
					route[#route + 1] = back[i]
				end
			else
				route = false
			end
		else
			-- Searched in the background (routeJobs); the port tries another pick meanwhile.
			if not routeJobs.job then
				local from, goal = dest.tile, port.tile
				routeJobs.job = { key = key, co = coroutine.create(function()
					return routeJobs.search(from, goal)
				end) }
			end
			return nil
		end
		routeCache[key] = route
	end
	return route
end

-- PortExecution.tradingPorts: other players' ports we may trade with, nearest first, as a
-- probability list (port level copies; again for the nearest few that aren't too close; again
-- for allies that aren't too close).
local function launchTrade(port)
	local p = players[port.owner]
	if not p then
		return
	end
	local list = {}
	for _, s in structures do
		if s.kind == "Port" and s.done and s.owner ~= port.owner and s.owner ~= 0 and players[s.owner].alive and canTrade(p, players[s.owner]) then
			list[#list + 1] = s
		end
	end
	if #list == 0 then
		return
	end
	local function md(s)
		return math.abs(s.tile % W - port.tile % W) + math.abs(s.tile // W - port.tile // W)
	end
	table.sort(list, function(a, b)
		return md(a) < md(b)
	end)
	local bonusCount = math.min(math.max(#list / 3, 4), #list) -- proximityBonusPortsNb
	local weighted = {}
	for i, s in list do
		local copies = math.max(1, s.level or 1)
		local tooClose = md(s) < TRADE_SHORT_RANGE
		local times = 1
		if not tooClose and i - 1 < bonusCount then
			times += 1
		end
		if not tooClose and Diplomacy.allied(port.owner, s.owner) then
			times += 1
		end
		for _ = 1, copies * times do
			weighted[#weighted + 1] = s
		end
	end
	-- OpenFront only lists ports on the same water body; unreachable picks are retried.
	local dest, route = nil, nil
	for _ = 1, 4 do
		local pick = weighted[rng:NextInteger(1, #weighted)]
		local r = tradeRoute(port, pick)
		if r and #r >= 2 then
			dest, route = pick, r
			break
		end
	end
	if not dest then
		return
	end
	local id = nextBoatId
	nextBoatId += 1
	-- The search started at the destination, so the route runs from our port to theirs.
	local b = { id = id, owner = port.owner, kind = "trade", path = route, pos = 1, from = port, to = dest, origOwner = port.owner, traveled = 0 }
	boats[id] = b
	announceBoat(b)
end

-- PortExecution.tick / shouldSpawnTradeShip: every 10 ticks, one roll per port level with a pity
-- timer, against the global saturation of trade ships at sea.
local function tickPortTrade(s)
	if (tick + s.id) % 10 ~= 0 then
		return
	end
	local numShips = 0
	for _, b in boats do
		if b.kind == "trade" then
			numShips += 1
		end
	end
	for _ = 1, math.max(1, s.level or 1) do
		local rejections = s.tradeRejections or 0
		local rate = math.max(1, math.floor(100 * (1 / (rejections + 1)) / tradeSaturation(numShips)))
		if rng:NextInteger(1, rate) == 1 then
			s.tradeRejections = 0
			launchTrade(s)
			return
		end
		s.tradeRejections = rejections + 1
	end
end

-- Warship capture (TradeShipExecution): the ship changes hands and sails to the captor's nearest
-- reachable port; with none it is lost.
local function captureTrade(b, captorId: number): boolean
	if boats[b.id] ~= b or b.kind ~= "trade" then
		return false
	end
	local captor = players[captorId]
	if not captor then
		return false
	end
	local here = b.path[math.clamp(math.floor(b.pos), 1, #b.path)]
	local orig = b.owner
	if orig ~= captorId then
		notify(orig, "Your trade ship was captured by " .. captor.name, "attack")
	end
	local path, port = Warships.routeToPort(here, captorId)
	if not path or #path < 2 then
		removeBoat(b)
		return true
	end
	b.traveled = (b.traveled or 0) + math.floor(b.pos)
	b.captured = true
	b.origOwner = b.origOwner or orig
	b.owner = captorId
	b.to = port
	b.path, b.pos = path, 1
	net:FireAllClients("boatEnd", b.id)
	announceBoat(b)
	return true
end

-- TradeShipExecution.tick checks; false = the ship was removed.
local function checkTrade(b): boolean
	local owner = players[b.owner]
	local destAlive = b.to and structures[b.to.id] == b.to and b.to.owner ~= 0
	if not b.captured then
		local destOwner = destAlive and players[b.to.owner] or nil
		if not destAlive or b.to.owner == b.from.owner or not canTrade(owner, destOwner) then
			removeBoat(b)
			return false
		end
	elseif not destAlive or b.to.owner ~= b.owner then
		local here = b.path[math.clamp(math.floor(b.pos), 1, #b.path)]
		local path, port = Warships.routeToPort(here, b.owner)
		if not path or #path < 2 then
			removeBoat(b)
			return false
		end
		b.traveled = (b.traveled or 0) + math.floor(b.pos)
		b.to, b.path, b.pos = port, path, 1
		net:FireAllClients("boatEnd", b.id)
		announceBoat(b)
	end
	return true
end

local function finishTrade(b)
	removeBoat(b)
	local gold = Config.tradeGold((b.traveled or 0) + #b.path)
	if b.captured then
		local owner = players[b.owner]
		if owner and owner.alive then
			owner.gold += gold
			if b.owner ~= b.origOwner then
				local victim = players[b.origOwner]
				notify(b.owner, string.format("Received %d gold from ship captured from %s", gold, if victim then victim.name else "?"), "info")
			end
		end
		return
	end
	local from = players[b.from.owner]
	local to = players[b.to.owner]
	if from and from.alive and b.from.owner ~= 0 then
		from.gold += gold
	end
	if to and to.alive and b.to.owner ~= 0 and b.to.owner ~= b.from.owner then
		to.gold += gold
	end
end

-- Structures
-- OpenFront costWrapper: levels owned vs levels ever built (Port and Factory share one count).
local function structureCost(p, kind: string): number
	return CoreRules.cost(p, kind)
end

local function tryBuild(p, t: number, kind: string): boolean
	local def = Config.STRUCTURES[kind]
	if not def or phase ~= "Play" or not p.alive or MatchRules.unitDisabled(kind) then
		return false -- (disabledUnits: Nukes / SAMs Disabled)
	end
	-- Building next to one of ours of an upgradable kind levels it up instead
	-- (PlayerImpl.buildableUnits: canUpgrade wins over canBuild).
	local up = CoreRules.upgradeTarget(p, kind, t)
	if up then
		return CoreRules.upgrade(p, up) > 0
	end
	-- Nearest valid own tile within the search radius; ports: nearest own shore tile.
	local spot = CoreRules.spawnTile(p, t, kind)
	if not spot then
		return false
	end
	t = spot
	local cost = structureCost(p, kind)
	if p.gold < cost then
		return false
	end
	p.gold -= cost
	CoreRules.noteBuilt(p, kind)
	local s = {
		id = nextStructureId,
		kind = kind,
		tile = t,
		owner = 0,
		done = false,
		readyTick = tick + (if match.rules.instantBuild then 0 else def.build), -- host option instantBuild
		cooldownUntil = 0,
		nextTrade = 0,
		level = 1, -- raised by upgrades (UpgradeStructureExecution)
	}
	nextStructureId += 1
	structures[s.id] = s
	structureAt[t] = s
	transferStructure(s, p.id)
	Flow.noteBuild(p, kind)
	return true
end

-- Nukes
-- Nuking an ally (its land at the target, or a real chunk of it in the blast) ends the alliance first.
local function breakAlliancesForNuke(p, target: number, radius: number)
	local hit = {}
	local victim = getOwner(target)
	if Diplomacy.allied(p.id, victim) then
		hit[victim] = Config.NUKE_ALLY_BREAK_TILES
	end
	local cx, cy, r = target % W, target // W, math.ceil(radius)
	for dy = -r, r do
		for dx = -r, r do
			local x, y = cx + dx, cy + dy
			if dx * dx + dy * dy <= radius * radius and x >= 0 and x < W and y >= 0 and y < HGT then
				local o = getOwner(y * W + x)
				if o ~= 0 and o ~= p.id and Diplomacy.allied(p.id, o) then
					hit[o] = (hit[o] or 0) + 1
				end
			end
		end
	end
	for id, count in hit do
		if count >= Config.NUKE_ALLY_BREAK_TILES then
			Diplomacy.breakAlliance(p, players[id], tick)
		end
	end
end

-- Flight, SAM interception and MIRV splitting live in the Missiles ModuleScript.
local function launchNuke(p, target: number, kind: string, down: boolean?): boolean
	if not Config.NUKES[kind] or phase ~= "Play" or not p.alive or MatchRules.unitDisabled(kind) then
		return false
	end
	if Flow.nukesBlocked() then
		return false -- PlayerImpl.nukeSpawn: no nukes during spawn immunity
	end
	if not Missiles.launch(p, target, kind, down) then
		return false
	end
	structuresDirty = true -- clients draw the silo reload bar
	Flow.stat(p, "bombsLaunched", 1)
	local victim = getOwner(target)
	if victim ~= 0 and players[victim] then
		Flow.updateRelation(players[victim], p.id, -100) -- NukeExecution
	end
	local plr = playerOf(p)
	if plr and Progression then
		Progression.noteNuke(plr)
	end
	return true
end

local function impassable(t: number): boolean
	return MapUtil.isLand(map, t) and not ownable(t)
end

-- NukeExecution.detonate. n = { owner, kind, to, inner, outer } from Missiles.
local DETONATED = { AtomBomb = "%s - atom bomb detonated", HydrogenBomb = "%s - hydrogen bomb detonated" }
-- NukeExecution.tilesToDestroy with water nukes: a smooth, irregular disc (random radii at 16
-- angles, lightly smoothed) so no scattered land pixels are left to boat to.
local function waterBlast(center: number, inner: number, outer: number): { number }
	local SAMPLES = 16
	local i2, o2 = inner * inner, outer * outer
	local radii = {}
	for i = 1, SAMPLES do
		radii[i] = i2 + rng:NextNumber() * (o2 - i2)
	end
	local prev = table.clone(radii)
	for i = 1, SAMPLES do
		local l = (i - 2) % SAMPLES + 1
		local r = i % SAMPLES + 1
		radii[i] = prev[i] * 0.6 + prev[l] * 0.2 + prev[r] * 0.2
	end
	local cx, cy = center % W, center // W
	local R = math.ceil(outer)
	local out = {}
	for py = math.max(0, cy - R), math.min(HGT - 1, cy + R) do
		for px = math.max(0, cx - R), math.min(W - 1, cx + R) do
			local dx, dy = px - cx, py - cy
			local d2 = dx * dx + dy * dy
			local keep = d2 <= o2
			if keep and d2 > i2 then
				local a = (math.atan2(dy, dx) + math.pi) / (2 * math.pi) * SAMPLES
				local i0 = math.floor(a) % SAMPLES
				local i1 = (i0 + 1) % SAMPLES
				local frac = a - math.floor(a)
				keep = d2 <= radii[i0 + 1] * (1 - frac) + radii[i1 + 1] * frac
			end
			local t = py * W + px
			if keep and not impassable(t) then
				out[#out + 1] = t
			end
		end
	end
	return out
end

-- Water nukes: the blasted land becomes water (MapUtil.toWater on the server and every client).
-- Queued and applied once per tick (WaterManager.tick), so a MIRV's warheads make one edit.
local function flushWater()
	local pending = mapState.pending
	if not pending or #pending == 0 then
		return
	end
	mapState.pending = {}
	local list = {}
	for _, t in pending do
		if getOwner(t) == 0 then -- conquered since it was queued: stays land
			list[#list + 1] = t
		end
	end
	local converted = MapUtil.toWater(map, list)
	if #converted == 0 then
		return
	end
	mapState.edited = true
	for _, t in converted do
		buffer.writeu8(fallout, t, 0)
		mapState.water[#mapState.water + 1] = t
	end
	routeCache = {} -- boat routes may cross the new water
	net:FireAllClients("water", converted)
end

local function detonate(n)
	local cx, cy = n.to % W, n.to // W
	local outer, inner = n.outer, n.inner
	local o2, i2 = outer * outer, inner * inner
	local lost = {}
	local function hit(t: number)
		local o = getOwner(t)
		if o ~= 0 then
			lost[o] = (lost[o] or 0) + 1
			setOwner(t, 0)
		end
		buffer.writeu8(fallout, t, 1)
		markChanged(t)
	end
	if MatchRules.get().waterNukes then
		local blasted = {}
		for _, t in waterBlast(n.to, inner, outer) do
			if ownable(t) then
				hit(t)
				blasted[#blasted + 1] = t
			end
		end
		mapState.pending = mapState.pending or {}
		table.move(blasted, 1, #blasted, #mapState.pending + 1, mapState.pending)
	else
		-- tilesToDestroy: BFS from the target; the inner disc always, the outer ring at 50% per tile.
		local seen = { [n.to] = true }
		local queue = { n.to }
		local head = 1
		while head <= #queue do
			local t = queue[head]
			head += 1
			if ownable(t) then
				hit(t)
			end
			local k = MapUtil.neighbors(map, t, NB3)
			for i = 1, k do
				local nt = NB3[i]
				if not seen[nt] then
					seen[nt] = true
					local dx, dy = nt % W - cx, nt // W - cy
					local d2 = dx * dx + dy * dy
					if d2 <= o2 and (d2 <= i2 or rng:NextNumber() < 0.5) and not impassable(nt) then
						queue[#queue + 1] = nt
					end
				end
			end
		end
	end
	local attacker = players[n.owner]
	local warhead = n.kind == "MIRVWarhead"
	for id, count in lost do
		local p = players[id]
		local before = p.tiles + count
		-- nukeDeathFactor per destroyed full-size tile (AREA_SCALE of them per tile here).
		local function survive(troops: number): number
			if warhead then
				local maxT = math.max(1, p.maxTroops)
				for _ = 1, count * Config.AREA_SCALE do
					local excess = math.max(0, troops - 0.03 * maxT)
					troops -= 500 * (1 - math.exp(-2 * excess / maxT))
				end
				return math.max(0, troops)
			end
			-- prod (1 - 5 / tilesLeft) over the destroyed tiles ~ ((before - lost) / before) ^ 5
			return troops * (math.max(0, before - count) / math.max(1, before)) ^ 5
		end
		p.troops = survive(p.troops)
		for a in pairs(p.outgoing) do
			a.troops = survive(a.troops)
		end
		for _, b in boats do
			if b.kind == "transport" and b.owner == id then
				b.troops = math.floor(survive(b.troops))
			end
		end
		if DETONATED[n.kind] and attacker then
			notify(id, string.format(DETONATED[n.kind], attacker.name), "nuke")
		end
	end
	-- Every unit inside the outer radius is deleted (structures, ships, trains).
	for _, s in structures do
		if dist2(s.tile, n.to) < o2 then
			removeStructure(s)
		end
	end
	for _, b in boats do
		local bt = b.path[math.clamp(math.floor(b.pos), 1, #b.path)]
		if bt and dist2(bt, n.to) < o2 then
			removeBoat(b)
		end
	end
	Warships.destroyInBlast(n.to, o2, n.owner)
	Railways.destroyInBlast(n.to, o2)
	for id in lost do
		local p = players[id]
		if p.tiles <= 0 then
			killPlayer(p, attacker)
		end
	end
end

-- Warships (logic lives in the Warships ModuleScript)
Warships.init({
	map = map,
	net = net,
	rng = rng,
	feed = feed,
	removeBoat = removeBoat,
	notify = notify,
	captureTrade = captureTrade,
	isAllied = function(a: number, b: number): boolean
		return isAllied(a, b)
	end,
	players = function()
		return players
	end,
	boats = function()
		return boats
	end,
	tick = function()
		return tick
	end,
})

Missiles.init({
	map = map,
	net = net,
	rng = rng,
	notify = notify,
	detonate = detonate,
	getOwner = getOwner,
	breakAlliancesForNuke = breakAlliancesForNuke,
	breakAlliance = function(p, victim)
		Diplomacy.breakAlliance(p, victim, tick)
	end,
	allied = function(a: number, b: number): boolean
		return a == b or Diplomacy.allied(a, b)
	end,
	markStructures = function()
		structuresDirty = true
	end,
	players = function()
		return players
	end,
	structures = function()
		return structures
	end,
	tick = function()
		return tick
	end,
})

Railways.init({
	map = map,
	net = net,
	-- SoundEffectController.handleTrainStation: the owner hears "build-train-station".
	stationBuilt = function(ownerId: number)
		local p = players and players[ownerId]
		local plr = p and playerOf(p)
		if plr then
			net:FireClient(plr, "stationBuilt")
		end
	end,
	rng = rng,
	canTrade = canTrade,
	allied = function(a: number, b: number): boolean
		return Diplomacy.allied(a, b)
	end,
	players = function()
		return players
	end,
	structures = function()
		return structures
	end,
	tick = function()
		return tick
	end,
})

Revive.init({
	net = net,
	wantsPlay = wantsPlay,
	feed = feed,
	playerOf = playerOf,
	endAttack = endAttack,
	removeBoat = removeBoat,
	claimSpawn = claimSpawn,
	randomSpawnTile = randomSpawnTile,
	nearestTile = nearestTile,
	getOwner = getOwner,
	ownable = ownable,
	size = function()
		return W, HGT
	end,
	phase = function()
		return phase
	end,
	tick = function()
		return tick
	end,
	players = function()
		return players
	end,
	attacks = function()
		return attacks
	end,
	boats = function()
		return boats
	end,
	spawnTiles = function()
		return spawnTiles
	end,
	eliminationOrder = function()
		return eliminationOrder
	end,
	markRoster = function()
		rosterDirty = true
	end,
	extraRevives = function(p)
		return Perks.extraRevives(p)
	end,
	notify = notify,
	progression = Progression,
	isRanked = function()
		return match.cfg ~= nil and match.cfg.kind == "ranked"
	end,
})

Perks.init({
	net = net,
	feed = feed,
	notify = notify,
	playerOf = playerOf,
	progression = Progression,
	isRanked = function()
		return match.cfg ~= nil and match.cfg.kind == "ranked"
	end,
	tick = function()
		return tick
	end,
	roundStartTick = function()
		return roundStartTick
	end,
	phase = function()
		return phase
	end,
	players = function()
		return players or {}
	end,
	addShield = Revive.addShield,
})

-- A boost or revive bought with Robux during a match is used right away when it can be.
Progression.onItemBought = function(plr: Player, key: string)
	local p = if players then byUser[plr.UserId] else nil
	if not p then
		return
	end
	if key == "revive" then
		if not p.alive then
			Revive.buyRevive(plr, p)
		end
	elseif p.alive and phase == "Play" then
		Perks.useBoost(plr, p, key, true)
	end
end

CoreRules.init({
	net = net,
	playerOf = playerOf,
	getOwner = getOwner,
	setOwner = setOwner,
	removeStructure = removeStructure,
	killPlayer = killPlayer,
	allied = function(a: number, b: number): boolean
		return Diplomacy.allied(a, b)
	end,
	markStructures = function()
		structuresDirty = true
	end,
	map = function()
		return map
	end,
	fallout = function()
		return fallout
	end,
	players = function()
		return players
	end,
	structures = function()
		return structures
	end,
	attacks = function()
		return attacks
	end,
	tick = function()
		return tick
	end,
})

-- AI (bots and nations)
local function scanNeighbors(p, limit: number)
	local hasNeutral = false
	local found = {}
	local count = 0
	for bt in pairs(p.border) do
		count += 1
		if count > limit then
			break
		end
		local n = MapUtil.neighbors(map, bt, NB)
		for i = 1, n do
			local o = getOwner(NB[i])
			if o == 0 then
				if ownable(NB[i]) then
					hasNeutral = true
				end
			elseif o ~= p.id then
				found[o] = true
			end
		end
	end
	return hasNeutral, found
end

local function randomOwnedTile(p): number?
	if p.tiles == 0 then
		return nil
	end
	local cx, cy = math.floor(p.sumX / p.tiles), math.floor(p.sumY / p.tiles)
	local spread = math.max(4, math.floor(math.sqrt(p.tiles) / 2))
	for _ = 1, 40 do
		local x = cx + rng:NextInteger(-spread, spread)
		local y = cy + rng:NextInteger(-spread, spread)
		if x >= 0 and x < W and y >= 0 and y < HGT then
			local t = y * W + x
			if getOwner(t) == p.id then
				return t
			end
		end
	end
	return p.spawnTile
end

local function randomBorderTile(p, pred): number?
	local count = 0
	for t in pairs(p.border) do
		count += 1
		if count > 400 then
			break
		end
		if pred(t) and rng:NextNumber() < 0.3 then
			return t
		end
	end
	return nil
end

local function aiBuild(p)
	local roll = rng:NextNumber()
	if (p.counts.Port or 0) == 0 and roll < 0.5 then
		local t = randomBorderTile(p, coastal)
		if t and tryBuild(p, t, "Port") then
			return
		end
	end
	if p.tiles > 600 and (p.counts.MissileSilo or 0) == 0 and p.gold >= 1000000 and roll < 0.25 then
		local t = randomOwnedTile(p)
		if t and tryBuild(p, t, "MissileSilo") then
			return
		end
	end
	if roll < 0.2 then
		local t = randomBorderTile(p, function()
			return true
		end)
		if t and tryBuild(p, t, "DefensePost") then
			return
		end
	end
	local t = randomOwnedTile(p)
	if t then
		tryBuild(p, t, "City")
	end
end

local function aiThink(p)
	local ai = p.ai
	if p.kind == "Nation" then
		if p.gold >= structureCost(p, "City") and rng:NextNumber() < 0.5 then
			aiBuild(p)
		end
		Warships.aiConsider(p)
	end
	if p.troops < p.maxTroops * ai.trigger then
		return
	end
	local hasNeutral, neighbors = scanNeighbors(p, 1500)
	Diplomacy.aiThink(p, neighbors, tick)
	local send = p.troops - p.maxTroops * ai.reserve
	if send < 1 then
		return
	end
	if hasNeutral then
		startLandAttack(p, 0, math.floor(send))
		return
	end
	-- Pick the weakest neighbour (by troops per tile); bots pick at random.
	local best, bestScore = nil, math.huge
	local strongest = nil
	for id in pairs(neighbors) do
		local o = players[id]
		if o and o.alive and not Diplomacy.allied(p.id, id) then
			local score = if p.kind == "Bot" then rng:NextNumber() else o.troops / math.max(1, o.tiles) + (if o.kind == "Bot" then -1e6 else 0)
			if score < bestScore then
				best, bestScore = o, score
			end
			if o.kind ~= "Bot" and (strongest == nil or o.tiles > strongest.tiles) then
				strongest = o
			end
		end
	end
	-- Nations with a silo occasionally nuke their biggest rival.
	if p.kind == "Nation" and strongest and strongest.tiles > p.tiles * 0.6 and p.gold >= Config.NUKES.AtomBomb.cost and rng:NextNumber() < 0.15 then
		local t = randomOwnedTile(strongest)
		if t and launchNuke(p, t, "AtomBomb") then
			return
		end
	end
	if best and (p.kind == "Bot" or best.troops < p.troops * 1.2 or rng:NextNumber() < 0.2) then
		startLandAttack(p, best.id, math.floor(send))
	elseif p.kind == "Nation" and not best and rng:NextNumber() < 0.3 then
		-- Cut off by water: try a naval landing on a random nearby player.
		local t = randomOwnedTile(p)
		if t then
			local target = nearestTile(t % W, t // W, 60, function(tt)
				local o = getOwner(tt)
				return o ~= 0 and o ~= p.id and coastal(tt) and not Diplomacy.allied(p.id, o)
			end)
			if target then
				launchBoat(p, target, math.floor(send * 0.5))
			end
		end
	end
end

NationBuild.init({
	players = function()
		return players
	end,
	nations = function()
		local out = {}
		for _, q in players do
			if q.kind == "Nation" then
				out[#out + 1] = q
			end
		end
		return out
	end,
	tick = function()
		return tick
	end,
	map = function()
		return map
	end,
	landTiles = function()
		return map.landTiles
	end,
	getOwner = getOwner,
	isWater = isWater,
	allied = function(a: number, b: number): boolean
		return Diplomacy.allied(a, b)
	end,
	sameTeam = function(a: number, b: number): boolean
		return Diplomacy.sameTeam(a, b)
	end,
	attacks = function()
		return attacks
	end,
	boats = function()
		return boats
	end,
	boatAlive = function(b): boolean
		return boats[b.id] == b
	end,
	boatTile = function(b): number
		return b.path[math.clamp(math.floor(b.pos), 1, #b.path)]
	end,
	randomOwnedTile = randomOwnedTile,
	randomBorderTileFacing = function(p, enemyId: number): number?
		return randomBorderTile(p, function(t)
			local x, y = t % W, t // W
			return (x > 0 and getOwner(t - 1) == enemyId)
				or (x < W - 1 and getOwner(t + 1) == enemyId)
				or (y > 0 and getOwner(t - W) == enemyId)
				or (y < HGT - 1 and getOwner(t + W) == enemyId)
		end)
	end,
	spawnTile = function(p, t: number, kind: string): number?
		return CoreRules.spawnTile(p, t, kind)
	end,
	cost = function(p, kind: string): number
		return structureCost(p, kind)
	end,
	nukeCost = function(p, kind: string): number
		return Missiles.cost(p, kind)
	end,
	samRange = function(level: number): number
		return Missiles.samRange(level)
	end,
	canUpgrade = function(p, s): boolean
		return CoreRules.canUpgrade(p, s)
	end,
	upgrade = function(p, s): number
		return CoreRules.upgrade(p, s)
	end,
	tryBuild = function(p, t: number, kind: string): boolean
		return tryBuild(p, t, kind)
	end,
	launchNuke = function(p, t: number, kind: string): boolean
		return launchNuke(p, t, kind)
	end,
	inboundMirv = function(a: number, b: number): boolean
		return Missiles.inboundMirv(a, b)
	end,
	updateRelation = function(p, otherId: number, delta: number)
		Flow.updateRelation(p, otherId, delta)
	end,
	hasPort = function(p): boolean
		return Warships.hasPort(p)
	end,
	warshipCost = function(p): number
		return Warships.cost(p)
	end,
	warshipCount = function(id: number): number
		return Warships.count(id)
	end,
	warshipTotal = function(): number
		return Warships.total()
	end,
	warshipCovering = function(t: number, r: number, id: number): boolean
		return Warships.covering(t, r, id)
	end,
	warshipSend = function(p, t: number): boolean
		return Warships.sendAny(p, t)
	end,
	buyWarship = function(p, t: number): boolean
		return Warships.tryBuy(p, t, "Warship")
	end,
	enemyWarshipNear = function(p): number?
		return Warships.enemyNear(p)
	end,
})

-- aiThink above is the old AI and is no longer called: AiBehavior (OpenFront TribeExecution /
-- NationExecution / AiAttackBehavior) drives tribes and nations. aiBuild is still used for structures.
AiBehavior.init({
	players = function()
		return players
	end,
	tick = function()
		return tick
	end,
	phase = function()
		return phase
	end,
	roundStartTick = function()
		return roundStartTick
	end,
	landTiles = function()
		return map.landTiles
	end,
	map = function()
		return map
	end,
	getOwner = getOwner,
	ownable = ownable,
	isWater = isWater,
	hasFallout = function(t: number): boolean
		return buffer.readu8(fallout, t) == 1
	end,
	attacks = function()
		return attacks
	end,
	startLandAttack = startLandAttack,
	launchBoat = launchBoat,
	launchNuke = launchNuke,
	build = function(p)
		NationBuild.structures(p) -- NationStructureBehavior
	end,
	warships = function(p)
		NationBuild.warships(p) -- NationWarshipBehavior
	end,
	mirv = function(p)
		NationBuild.mirv(p) -- NationMIRVBehavior
	end,
	claimSpawn = claimSpawn,
	unclaimSpawn = unclaimSpawn,
	randomOwnedTile = randomOwnedTile,
	deleteStructure = function(p)
		-- Tribes scrap captured structures, one per delete cooldown (TribeExecution.deleteNextStructure).
		if p.lastDelete and tick - p.lastDelete < interactRules.DELETE_COOLDOWN then
			return
		end
		for s in pairs(p.structs) do
			p.lastDelete = tick
			removeStructure(s)
			return
		end
	end,
})

-- Networking
local function rosterPayload()
	local list = {}
	for id, p in players do
		-- [11] = the "Hidden Names" stand-in for human players (createRandomName)
		list[#list + 1] = { id, p.name, p.kind, p.color, p.userId or 0, p.level, p.vip, p.flag or "", Flow.kindName(p.kind), p.team or "", if p.kind == "Human" then TribeNames.anonymous(p.name) else "" }
	end
	return list
end

local function statsPayload(): buffer
	local count = 0
	for _ in players do
		count += 1
	end
	local b = buffer.create(count * 31)
	local o = 0
	for id, p in players do
		local attacking = 0 -- PlayerInfoOverlay: troops in this player's outgoing attacks
		for a in pairs(p.outgoing) do
			attacking += a.troops
		end
		buffer.writeu16(b, o, id)
		buffer.writeu8(b, o + 2, if p.alive then 1 else 0)
		buffer.writeu32(b, o + 3, math.clamp(math.floor(p.troops), 0, 4294967295))
		buffer.writeu32(b, o + 7, math.clamp(math.floor(p.maxTroops), 0, 4294967295))
		buffer.writeu32(b, o + 11, math.clamp(math.floor(p.gold), 0, 4294967295))
		buffer.writeu32(b, o + 15, p.tiles)
		local cx = if p.tiles > 0 then p.sumX / p.tiles else 0
		local cy = if p.tiles > 0 then p.sumY / p.tiles else 0
		buffer.writeu16(b, o + 19, math.floor(cx * 10) % 65536)
		buffer.writeu16(b, o + 21, math.floor(cy * 10) % 65536)
		buffer.writeu16(b, o + 23, p.cities)
		buffer.writeu16(b, o + 25, p.kills)
		buffer.writeu32(b, o + 27, math.clamp(math.floor(attacking), 0, 4294967295))
		o += 31
	end
	return b
end

local function wireOwner(t: number): number
	local o = getOwner(t)
	if o == 0 and buffer.readu8(fallout, t) == 1 then
		return FALLOUT_OWNER
	end
	return o
end

local function ownersSnapshot(): buffer
	local runs = {}
	local cur, len = wireOwner(0), 0
	for t = 0, SIZE - 1 do
		local o = wireOwner(t)
		if o == cur then
			len += 1
		else
			runs[#runs + 1] = cur
			runs[#runs + 1] = len
			cur, len = o, 1
		end
	end
	runs[#runs + 1] = cur
	runs[#runs + 1] = len
	local b = buffer.create(#runs // 2 * 6)
	for i = 1, #runs, 2 do
		local off = (i - 1) // 2 * 6
		buffer.writeu16(b, off, runs[i])
		buffer.writeu32(b, off + 2, runs[i + 1])
	end
	return b
end

local function flushTileChanges()
	if #changedList == 0 then
		return
	end
	local groups = {}
	local order = {}
	for _, t in changedList do
		buffer.writeu8(changedFlag, t, 0)
		local o = wireOwner(t)
		local g = groups[o]
		if not g then
			g = {}
			groups[o] = g
			order[#order + 1] = o
		end
		g[#g + 1] = t
	end
	local bytes = 0
	for _, o in order do
		bytes += 6 + #groups[o] * 4
	end
	local b = buffer.create(bytes)
	local off = 0
	for _, o in order do
		local g = groups[o]
		buffer.writeu16(b, off, o)
		buffer.writeu32(b, off + 2, #g)
		off += 6
		for _, t in g do
			buffer.writeu32(b, off, t)
			off += 4
		end
	end
	table.clear(changedList)
	net:FireAllClients("tiles", b)
end

local function structuresPayload()
	local list = {}
	-- Rows: id, kind, tile, owner, done, then (appended, optional) server times for OpenFront's
	-- progress bar: [6]/[7] construction start/end, [8]/[9] missile reload start/end.
	local now = SimClock.now()
	for _, s in structures do
		-- [10] = level (UpgradeStructureExecution), always the last field.
		local row = { s.id, s.kind, s.tile, s.owner, s.done, 0, 0, 0, 0, s.level or 1, 0 } -- no gaps (remotes drop them)
		-- [11] = server time the structure is deleted (DeleteUnitExecution mark), 0 = not marked.
		if CoreRules.isMarked(s) then
			row[11] = now + (s.deleteAt - tick) * Config.TICK
		end
		local def = Config.STRUCTURES[s.kind]
		if not s.done and def then
			row[6] = now + (s.readyTick - def.build - tick) * Config.TICK
			row[7] = now + (s.readyTick - tick) * Config.TICK
		end
		if s.cooldownUntil > tick then
			local cd = if s.kind == "SAM" then Config.SAM_COOLDOWN else Config.SILO_COOLDOWN
			row[8] = now + (s.cooldownUntil - cd - tick) * Config.TICK
			row[9] = now + (s.cooldownUntil - tick) * Config.TICK
		end
		list[#list + 1] = row
	end
	return list
end

local function boatsPayload()
	local list = {}
	local now = SimClock.now()
	for _, b in boats do
		local pathBuf = buffer.create(#b.path * 4)
		for i, t in b.path do
			buffer.writeu32(pathBuf, (i - 1) * 4, t)
		end
		list[#list + 1] = {
			id = b.id,
			owner = b.owner,
			kind = b.kind,
			troops = b.troops,
			path = pathBuf,
			start = now - (b.pos - 1) / Config.BOAT_SPEED * Config.TICK,
			speed = Config.BOAT_SPEED / Config.TICK,
		}
	end
	return list
end

-- Map vote
local voteOptions: { any } = {} -- catalog entries offered in this lobby
local votes: { [number]: string } = {} -- UserId -> map id

local function startMapVote()
	table.clear(votes)
	-- The public lobby schedule: the next round's mode is known while players vote on the map.
	teamState.nextMode = Teams.rollMode(teamState.round + 1, rng)
	local pool = {}
	for _, info in MapCatalog do
		if mapsFolder:FindFirstChild(info.id) then
			pool[#pool + 1] = info
		end
	end
	-- Don't offer the map that was just played if there are enough others.
	if #pool > Config.MAP_VOTE_OPTIONS then
		for i = #pool, 1, -1 do
			if pool[i].id == currentMapId then
				table.remove(pool, i)
			end
		end
	end
	-- Variety: one map from the smaller half and one from the larger half, the rest random.
	table.sort(pool, function(a, b)
		return a.land < b.land
	end)
	local options = {}
	local count = math.min(Config.MAP_VOTE_OPTIONS, #pool)
	if count >= 2 then
		local half = #pool // 2
		options[1] = table.remove(pool, rng:NextInteger(1, half))
		options[2] = table.remove(pool, rng:NextInteger(half, #pool))
	end
	while #options < count do
		options[#options + 1] = table.remove(pool, rng:NextInteger(1, #pool))
	end
	for i = #options, 2, -1 do
		local j = rng:NextInteger(1, i)
		options[i], options[j] = options[j], options[i]
	end
	voteOptions = options
end

local function votePayload()
	local counts = {}
	for uid, id in votes do
		if Players:GetPlayerByUserId(uid) then
			counts[id] = (counts[id] or 0) + 1
		end
	end
	local list = {}
	for i, info in voteOptions do
		list[i] = { id = info.id, name = info.name, width = info.width, height = info.height, votes = counts[info.id] or 0 }
	end
	return { options = list, current = currentMapId }
end

-- Most votes wins (random tie-break, random option if nobody voted). nil = keep the current map.
local function voteWinner(): string?
	local best, bestCount = {}, -1
	for _, o in votePayload().options do
		if o.votes > bestCount then
			best, bestCount = { o.id }, o.votes
		elseif o.votes == bestCount then
			best[#best + 1] = o.id
		end
	end
	-- Ties go to the first listed option, so the menu's "NEXT MAP" card (the leading option,
	-- first on ties) is always the map that actually loads. The list order is already random.
	return best[1]
end

-- Swaps the active map and every SIZE-dependent buffer that isn't rebuilt by resetWorld.
local function loadMap(id: string, compact: boolean?): boolean
	local mod = mapsFolder:FindFirstChild(id)
	if not mod then
		warn("[War Front] map module missing: " .. id)
		return false
	end
	local ok, result = pcall(MapUtil.load, mod)
	if not ok then
		warn("[War Front] map " .. id .. " failed to load: " .. tostring(result))
		return false
	end
	map = if compact then MapUtil.compact(result) else result
	W, HGT, SIZE = map.width, map.height, map.size
	currentMapId = id
	mapState.compact = compact == true
	mapState.rev += 1
	mapState.edited = false
	mapState.water = {}
	mapState.pending = {}
	bfsStamp = buffer.create(SIZE * 2)
	bfsParent = buffer.create(SIZE * 4)
	bfsGen = 0
	routeJobs.job = nil
	routeJobs.stamp = buffer.create(SIZE * 2)
	routeJobs.parent = buffer.create(SIZE * 4)
	routeJobs.gen = 0
	Warships.setMap(map)
	Missiles.setMap(map)
	Railways.setMap(map)
	return true
end

-- Game speed (OpenFront single-player ReplayPanel: x0.5 / x1 / x2 / Max, plus pause). Only while
-- the server has a single player; SimClock carries the speed to every timed animation.
local gameSpeed = {
	mult = 1, -- chosen speed; MAX_SPEED for "Max"
	paused = false,
	MAX_SPEED = 6, -- "Max": as fast as the server keeps up with, up to 6x
	CHOICES = { [0.5] = true, [1] = true, [2] = true, [6] = true },
	ticks = 0, -- ticks run since the last rate check
	checkAt = os.clock(),
	actual = 1, -- measured ticks per real second / 10
}
function gameSpeed.solo(): boolean
	return #Players:GetPlayers() == 1
end
function gameSpeed.effective(): number
	return if gameSpeed.paused then 0 else gameSpeed.actual
end

local function phasePayload()
	local out = {
		phase = phase,
		round = teamState.round,
		-- Seconds of play so far (game time), so a client that joins late or plays at another
		-- speed still shows the right timer; speed = current game speed (0 = paused).
		elapsed = if phase == "Play" then math.max(0, tick - roundStartTick) * Config.TICK else 0,
		speed = gameSpeed.effective(),
		speedChoice = gameSpeed.mult,
		paused = gameSpeed.paused,
		solo = gameSpeed.solo(),
		ticksLeft = math.max(0, phaseEndTick - tick),
		winner = winnerName,
		winnerId = interactRules.winnerId,
		vote = if phase == "Lobby" then votePayload() else nil,
		-- OpenFront public FFA has no match timer (maxTimerValue undefined), so timeLeft is nil.
		timeLeft = nil,
		spawnImmunity = Flow.immunitySeconds(),
		winPercent = Flow.winPercent(), -- share of non-fallout land needed to win (overtime lowers it)
		-- Team games: the mode label ("Free for All", "4 teams", "Duos", "Humans vs Nations") of the
		-- round being played (or, in the lobby, the one being voted into) and the winning team.
		mode = Teams.label(if phase == "Lobby" then teamState.nextMode else teamState.mode),
		teamGame = Teams.isTeam(if phase == "Lobby" then teamState.nextMode else teamState.mode),
		teams = teamState.list,
		winnerTeam = teamState.winner,
	}
	if Matchmaker.active and phase == "Lobby" then
		-- Lobby place: the three public lobbies (FFA / Teams / Special) instead of a local vote.
		out.vote = nil
		out.lobbies = Matchmaker.lobbyPhase().lobbies
	elseif match.cfg then
		out.matchKind = match.cfg.kind
		out.vote = nil
		if phase == "Lobby" then
			-- Waiting for everyone teleported in (Matchmaker settings list the players).
			local expected = if type(match.cfg.players) == "table" then #match.cfg.players else 0
			local here = 0
			for _, plr in Players:GetPlayers() do
				if wantsPlay[plr.UserId] then
					here += 1
				end
			end
			out.waiting = { here = here, expected = math.max(expected, here) }
			out.ticksLeft = if match.waitUntil then math.max(0, match.waitUntil - tick) else 0
		end
		if (match.rules.maxTimer or 0) > 0 and phase == "Play" then
			-- maxTimerValue: the leader wins when the game timer runs out (HudSidebars counts down).
			out.timeLeft = math.max(0, match.rules.maxTimer * 60 - math.max(0, tick - roundStartTick) * Config.TICK)
		end
	end
	return out
end

local function sendInit(plr: Player)
	local p = byUser[plr.UserId]
	net:FireClient(plr, "init", {
		phase = phasePayload(),
		roster = rosterPayload(),
		owners = ownersSnapshot(),
		stats = statsPayload(),
		structures = structuresPayload(),
		boats = boatsPayload(),
		units = Warships.snapshot(),
		myId = if p then p.id else 0,
		map = currentMapId,
		-- The exact map loaded (compact, reloads after water nukes) and this round's water edits.
		mapKey = currentMapId .. (if mapState.compact then "@c" else "") .. "#" .. mapState.rev,
		compact = mapState.compact,
		water = mapState.water,
	})
	Diplomacy.sendInit(plr, p, tick)
	Revive.sendInit(plr)
	Railways.sendInit(plr)
end

-- AttackImpl.clusteredPositions -> clusterBorderTiles(30, 2): the attack's front split into
-- 8-connected segments (BFS), largest first; segments under 30 full-size tiles (8 of ours, the
-- front is a line) are dropped unless nothing bigger exists, at most 2 kept. Each segment is
-- represented by its tile nearest the segment's centroid (AttackingTroopsController labels).
local CLUSTER_MIN = math.ceil(30 / Config.LINEAR_SCALE)
local DIAG8 = { -1, 0, 1, 0, 0, -1, 0, 1, -1, -1, 1, -1, -1, 1, 1, 1 }
local function attackClusters(a): { number }
	if a.clusterTick == tick then
		return a.clusters
	end
	local front = a.front
	local visited = {}
	local found = {}
	for start in pairs(front) do
		if visited[start] then
			continue
		end
		visited[start] = true
		local queue = { start }
		local qi, sx, sy = 1, 0, 0
		while qi <= #queue do
			local t = queue[qi]
			qi += 1
			local x, y = t % W, t // W
			sx += x
			sy += y
			for k = 1, 15, 2 do
				local nx, ny = x + DIAG8[k], y + DIAG8[k + 1]
				if nx >= 0 and ny >= 0 and nx < W and ny < HGT then
					local nt = ny * W + nx
					if front[nt] and not visited[nt] then
						visited[nt] = true
						queue[#queue + 1] = nt
					end
				end
			end
		end
		local n = #queue
		local cx, cy = sx / n, sy / n
		local best, bestD = start, math.huge
		for _, t in queue do
			local dx, dy = t % W - cx, t // W - cy
			local d = dx * dx + dy * dy
			if d < bestD then
				best, bestD = t, d
			end
		end
		found[#found + 1] = { best, n }
	end
	table.sort(found, function(p, q)
		return p[2] > q[2]
	end)
	local out = {}
	for _, c in found do
		if #out < 2 and (c[2] >= CLUSTER_MIN or #out == 0) then
			out[#out + 1] = c[1]
		end
	end
	a.clusterTick, a.clusters = tick, out
	return out
end

local function sendPersonal()
	for _, plr in Players:GetPlayers() do
		local p = byUser[plr.UserId]
		if p then
			local list = {}
			for a in pairs(p.outgoing) do
				-- [4] attack id, [5] front label tiles (only against players, like OpenFront)
				list[#list + 1] = { a.target, math.floor(a.troops), a.retreatAt ~= nil, a.uid or 0, if a.target ~= 0 then attackClusters(a) else nil }
			end
			-- Attacks display: incoming land attacks (not from bots) and boats both ways.
			local incoming = {}
			for _, a in attacks do
				if a.target == p.id and not a.dead and a.attacker.kind ~= "Bot" then
					incoming[#incoming + 1] = { a.attacker.id, math.floor(a.troops), a.retreatAt ~= nil, a.uid or 0, attackClusters(a) }
				end
			end
			local myBoats, boatsIn = {}, {}
			for _, b in boats do
				if b.kind == "transport" then
					local eta = math.max(0, math.ceil((#b.path - b.pos) / Config.BOAT_SPEED * Config.TICK))
					if b.owner == p.id then
						myBoats[#myBoats + 1] = { b.id, b.troops, if b.retreating then p.id else getOwner(b.landing), eta, b.retreating == true }
					elseif not b.retreating and getOwner(b.landing) == p.id then
						boatsIn[#boatsIn + 1] = { b.id, b.troops, b.owner, eta }
					end
				end
			end
			local costs = {}
			for kind in Config.STRUCTURES do
				costs[kind] = structureCost(p, kind)
			end
			costs.Warship = Warships.cost(p)
			for _, kind in Config.NUKE_ORDER do
				costs[kind] = Missiles.cost(p, kind) -- MIRV price rises with every MIRV launched
			end
			local hasSilo, siloReady = Missiles.siloReady(p)
			local rels = {} -- each Nation's relation to me (PlayerPanel relation pill)
			for _, q in players do
				if q.kind == "Nation" and q.alive and q ~= p then
					rels[#rels + 1] = { q.id, Flow.relation(q, p.id) }
				end
			end
			net:FireClient(plr, "me", {
				id = p.id,
				attacks = list,
				costs = costs,
				boats = p.boats,
				hasSilo = hasSilo,
				siloReady = siloReady,
				hasPort = Warships.hasPort(p),
				incoming = incoming,
				boatList = myBoats,
				boatsIn = boatsIn,
				deleteCooldown = math.max(0, math.ceil(((p.lastDelete or -1e9) + interactRules.DELETE_COOLDOWN - tick) * Config.TICK)),
				immunityEndsIn = Flow.immunityLeft(p, math.max(0, phaseEndTick - tick)),
				embargoes = Flow.embargoList(p), -- ids I embargo
				embargoedBy = Flow.embargoedBy(p), -- ids embargoing me (embargo icon is either way)
				targets = Flow.transitiveTargets(p), -- my targets + my allies' (target icon)
				relations = rels,
			})
		end
	end
end

-- Game flow
local function resetWorld()
	roundColors = Theme.newRoundColors()
	owner = buffer.create(SIZE * 2)
	fallout = buffer.create(SIZE)
	changedFlag = buffer.create(SIZE)
	changedList = {}
	players = {}
	nextId = 1
	attacks = {}
	structures = {}
	structureAt = {}
	nextStructureId = 1
	boats = {}
	nextBoatId = 1
	nukes = {}
	nextNukeId = 1
	spawnTiles = {}
	routeCache = {}
	routeJobs.job = nil
	byUser = {}
	eliminationOrder = {}
	Warships.reset()
	Missiles.reset()
	Railways.reset()
	winnerName = nil
	interactRules.winnerId = 0
	teamState.winner = nil
	tick = 0
	Diplomacy.reset()
	Revive.reset()
	CoreRules.reset()
	Flow.reset()
	NationBuild.reset()
end

-- Custom names (OpenFront UsernameInput: 3-20 letters, numbers, spaces, _ - .). Roblox rules:
-- every name shown to others goes through TextService filtering first.
local customNames: { [number]: string } = {}
local nameBusy: { [Player]: boolean } = {}
local TextService = game:GetService("TextService")
local function setPlayerName(plr: Player, raw: any)
	if nameBusy[plr] then
		return
	end
	local function reply(ok: boolean, nameOrError: string)
		net:FireClient(plr, "nameResult", { ok = ok, name = if ok then nameOrError else nil, error = if ok then nil else nameOrError })
	end
	if typeof(raw) ~= "string" then
		return
	end
	local name = string.gsub(string.gsub(raw, "^%s+", ""), "%s+$", "")
	name = string.gsub(name, "%s+", " ")
	if name == "" then
		customNames[plr.UserId] = nil
		name = plr.DisplayName
	else
		if utf8.len(name) == nil or #name > 20 then
			reply(false, "Username must not exceed 20 characters.")
			return
		elseif #name < 3 then
			reply(false, "Username must be at least 3 characters long.")
			return
		elseif string.find(name, "[^%w _%-%.]") then
			reply(false, "Username can only contain letters, numbers, spaces, underscores, hyphens, and periods.")
			return
		end
		nameBusy[plr] = true
		local ok, filtered = pcall(function()
			local result = TextService:FilterStringAsync(name, plr.UserId, Enum.TextFilterContext.PublicChat)
			return result:GetNonChatStringForBroadcastAsync()
		end)
		nameBusy[plr] = nil
		if not plr.Parent then
			return
		end
		if not ok or type(filtered) ~= "string" or filtered ~= name then
			reply(false, if ok then "That name isn't allowed." else "Couldn't check that name right now, try again.")
			return
		end
		customNames[plr.UserId] = name
	end
	-- Shown from the next round; right away while the round hasn't started fighting yet.
	local p = byUser[plr.UserId]
	if p and (phase == "Lobby" or phase == "Spawn") then
		p.name = name
		rosterDirty = true
	end
	reply(true, name)
end

local function addHuman(plr: Player)
	if byUser[plr.UserId] then
		return byUser[plr.UserId]
	end
	local p = newPlayer(customNames[plr.UserId] or plr.DisplayName, "Human", plr.UserId)
	if Progression then
		local rgb = Progression.colorFor(plr)
		if rgb then
			p.color = packRGB(rgb[1], rgb[2], rgb[3])
		end
		p.level, p.vip = Progression.tagFor(plr)
	end
	byUser[plr.UserId] = p
	if phase == "Spawn" and type(match.rules.startingGold) == "number" then
		p.gold = match.rules.startingGold -- joined during the spawn phase: same starting gold
	end
	-- Joining a team round during the spawn phase: the smallest team (Humans in HvN).
	if Teams.isTeam(teamState.mode) and #teamState.list > 0 and phase == "Spawn" then
		local team = teamState.list[1]
		if not Teams.isHvN(teamState.mode) then
			local size = {}
			for _, q in players do
				if q.team then
					size[q.team] = (size[q.team] or 0) + 1
				end
			end
			for _, t in teamState.list do
				if (size[t] or 0) < (size[team] or 0) then
					team = t
				end
			end
		end
		p.team = team
		p.color = Theme.teamPlayerColor(team, tostring(p.id))
		Diplomacy.setTeam(p.id, team)
		rosterDirty = true
	end
	return p
end

local function setPhase(newPhase: string, duration: number)
	phase = newPhase
	phaseEndTick = tick + duration
	if newPhase ~= "Spawn" and newPhase ~= "Play" then
		-- the speed / pause only last for the round (the end screen and lobby run at normal speed)
		gameSpeed.mult, gameSpeed.actual, gameSpeed.paused = 1, 1, false
		if SimClock.speed() ~= 1 then
			SimClock.set(1)
		end
	end
	net:FireAllClients("phase", phasePayload())
end

-- Re-anchors the game clock at the speed actually being simulated and tells every client.
function gameSpeed.apply()
	local target = if gameSpeed.paused then 0 else gameSpeed.actual
	if math.abs(SimClock.speed() - target) > 1e-3 then
		SimClock.set(target)
	end
	net:FireAllClients("phase", phasePayload())
end

function gameSpeed.request(kind: string, value: any)
	if not gameSpeed.solo() or (phase ~= "Spawn" and phase ~= "Play") then
		return
	end
	if kind == "pause" then
		gameSpeed.paused = if typeof(value) == "boolean" then value else not gameSpeed.paused
	elseif typeof(value) == "number" and gameSpeed.CHOICES[value] then
		gameSpeed.mult = value
		gameSpeed.actual = value
		gameSpeed.ticks, gameSpeed.checkAt = 0, os.clock()
	else
		return
	end
	gameSpeed.apply()
end

-- Back to normal speed as soon as a second player is in the server.
function gameSpeed.reset()
	if gameSpeed.mult ~= 1 or gameSpeed.paused then
		gameSpeed.mult, gameSpeed.actual, gameSpeed.paused = 1, 1, false
		gameSpeed.apply()
	end
end

local function startNewGame()
	local nextMap = if match.cfg then match.cfg.map else voteWinner()
	local compact = match.rules.compact == true
	-- Reload on a new map, a size change, or after water nukes edited the terrain.
	if nextMap and (nextMap ~= currentMapId or compact ~= mapState.compact or mapState.edited) then
		loadMap(nextMap, compact)
	end
	voteOptions = {}
	table.clear(votes)
	resetWorld()
	teamState.round += 1
	teamState.mode = (match.cfg and match.cfg.mode) or teamState.nextMode or { kind = "FFA" }
	teamState.list = {}
	-- MapPlaylist: Humans vs Nations lobbies play Hard nations, every other public lobby Medium.
	Config.NATION_DIFFICULTY = if Teams.isHvN(teamState.mode) then "Hard" else "Medium"
	if match.cfg then
		-- Lobby settings (private lobby host options, ranked 1v1 rules).
		local r = match.rules
		if type(r.difficulty) == "string" then
			Config.NATION_DIFFICULTY = r.difficulty
		end
		Config.HARD_TIME_LIMIT_SECONDS = if (r.maxTimer or 0) > 0 then r.maxTimer * 60 else 170 * 60
		Config.SPAWN_IMMUNITY_TICKS = if type(r.immunitySeconds) == "number" then math.floor(r.immunitySeconds / Config.TICK) else 50
		Diplomacy.setDonations(r.donateGold, r.donateTroops)
	end
	-- Round rules every script reads (Shared.MatchRules). Standalone rounds play like public
	-- lobbies: overtime in Free for All.
	do
		local r = match.rules
		local disabled = {}
		if type(r.disabledUnits) == "table" then
			for _, k in r.disabledUnits do
				if type(k) == "string" then
					disabled[#disabled + 1] = k
				end
			end
		end
		local overtime = if match.cfg then r.overtime == true else not Teams.isTeam(teamState.mode)
		MatchRules.set({
			mods = r.mods,
			disabled = disabled,
			noAlliances = r.noAlliances == true,
			waterNukes = r.waterNukes == true,
			doomsday = r.doomsday,
			overtime = overtime,
			goldMult = r.goldMultiplier,
			compact = mapState.compact,
			allianceTicks = if type(r.allianceMinutes) == "number" and r.allianceMinutes > 0 then r.allianceMinutes * 600 else 0,
		})
		Config.ALLIANCE_TICKS = MatchRules.allianceTicks() -- custom alliance duration (Diplomacy)
		Config.GOLD_MULTIPLIER = if type(r.goldMultiplier) == "number" and r.goldMultiplier > 0 then r.goldMultiplier else 1
		DoomsdayClock.start(if type(r.doomsday) == "string" then r.doomsday else nil)
	end
	for _, plr in Players:GetPlayers() do
		if wantsPlay[plr.UserId] then
			addHuman(plr)
		end
	end
	local nationList = if match.rules.nations == false then {} else map.nations -- host option: nations off
	if mapState.compact and #nationList > 0 then
		-- Compact maps use 25 % of the nations, at least one (NationCreation.getCompactMapNationCount).
		local shuffled = table.clone(nationList)
		for i = #shuffled, 2, -1 do
			local j = rng:NextInteger(1, i)
			shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
		end
		nationList = table.move(shuffled, 1, math.max(1, math.floor(#shuffled * 0.25)), 1, {})
	end
	for _, n in nationList do
		-- NationExecution.randomSpawnLand: random free land near the map's spawn cell.
		local t = AiBehavior.nationSpawnTile(n[2], n[3]) or nearestTile(n[2], n[3], 12, function(tt)
			return ownable(tt) and getOwner(tt) == 0
		end)
		if t then
			local p = newPlayer(n[1], "Nation")
			p.ai.cellX, p.ai.cellY = n[2], n[3]
			-- OpenFront flag code (MapCatalog nation field 4); older map modules may lack it.
			p.flag = n[4] or ""
			if p.flag == "" then
				for _, info in MapCatalog do
					if info.id == currentMapId then
						for _, cn in info.nations do
							if cn[1] == n[1] then
								p.flag = cn[4] or ""
							end
						end
					end
				end
			end
			claimSpawn(p, t)
		end
	end
	-- Team games: humans and nations get teams (TeamAssignment.assignTeams) and team colours.
	do
		local humans, nations = {}, {}
		for _, p in players do
			if p.kind == "Human" then
				humans[#humans + 1] = p
			elseif p.kind == "Nation" then
				nations[#nations + 1] = p
			end
		end
		teamState.list = Teams.assign(teamState.mode, humans, nations, rng)
		Diplomacy.setTeamMode(Teams.isTeam(teamState.mode))
		for _, list in { humans, nations } do
			for _, p in list do
				Diplomacy.setTeam(p.id, p.team)
				if p.team then
					p.color = Theme.teamPlayerColor(p.team, tostring(p.id))
				end
			end
		end
	end
	-- NUM_BOTS is tuned for Europe (~135K land tiles); smaller maps get proportionally fewer bots.
	-- (Compact maps: OpenFront's 100 bots already are the quarter, so scale by the full map's land.)
	local botLand = map.landTiles * (if mapState.compact then 4 else 1)
	local botCount = math.clamp(math.floor(Config.NUM_BOTS * botLand / 134751 + 0.5), 12, Config.NUM_BOTS)
	if type(match.rules.bots) == "number" then
		-- Host option "bots" in OpenFront units (0-400 = our 0-100), scaled by land like above.
		local wanted = match.rules.bots / 4
		botCount = if wanted <= 0 then 0 else math.clamp(math.floor(wanted * botLand / 134751 + 0.5), 1, Config.NUM_BOTS)
	end
	-- Tribe names from the map's OpenFront name themes (TribeSpawner.randomTribeName).
	local folder = nil
	for _, info in MapCatalog do
		if info.id == currentMapId then
			folder = info.folder
		end
	end
	local tribeName = TribeNames.picker(folder, rng)
	for _ = 1, botCount do
		-- SpawnExecution: keep the minimum distance for the first tries, then relax it.
		local t = randomSpawnTile(Config.MIN_SPAWN_DISTANCE) or randomSpawnTile(0)
		if t then
			local p = newPlayer(tribeName(), "Bot")
			if Teams.isTeam(teamState.mode) then
				p.team = "Bot" -- maybeAssignTeam: tribes are on the Bot team
				Diplomacy.setTeam(p.id, "Bot")
			end
			claimSpawn(p, t)
		end
	end
	if match.rules.randomSpawn then
		-- Host option randomSpawn: humans start on a random free spot (they can't pick one).
		for _, p in players do
			if p.kind == "Human" and not p.spawned then
				local t = randomSpawnTile(Config.MIN_SPAWN_DISTANCE) or randomSpawnTile(0)
				if t then
					claimSpawn(p, t)
				end
			end
		end
	end
	if type(match.rules.startingGold) == "number" and match.rules.startingGold > 0 then
		-- Config.startingGold: every human and nation (not tribes) starts with it.
		for _, p in players do
			if p.kind ~= "Bot" then
				p.gold = match.rules.startingGold
			end
		end
	end
	table.clear(match.roundHumans)
	for _, p in players do
		if p.kind == "Human" and p.userId then
			match.roundHumans[#match.roundHumans + 1] = p.userId
		end
	end
	for _, plr in Players:GetPlayers() do
		sendInit(plr)
	end
	rosterDirty = false
	setPhase("Spawn", Config.SPAWN_PHASE_TICKS)
end

local function endGame(winner, winnerTeam: string?)
	winnerName = if winnerTeam then winnerTeam .. " team" elseif winner then winner.name else nil
	interactRules.winnerId = if winner and not winnerTeam then winner.id else 0
	teamState.winner = winnerTeam
	if winnerTeam then
		feed(winnerTeam .. " team has won!", "win", 0)
	elseif winner then
		feed(winner.name .. " has conquered the map!", "win", winner.id)
	end
	-- Placements: living players by land, then the eliminated in reverse order of death.
	local ranking = {}
	for _, p in players do
		if p.alive then
			ranking[#ranking + 1] = p
		end
	end
	table.sort(ranking, function(a, b)
		return a.tiles > b.tiles
	end)
	for i = #eliminationOrder, 1, -1 do
		ranking[#ranking + 1] = eliminationOrder[i]
	end
	if Progression then
		local results = {}
		local roundSeconds = (tick - roundStartTick) * Config.TICK
		for place, p in ranking do
			local plr = playerOf(p)
			if plr then
				results[#results + 1] = {
					player = plr,
					placement = place,
					won = if winnerTeam then p.team == winnerTeam else p == winner,
					peakPercent = p.peakTiles / map.landTiles * 100,
					eliminations = p.kills,
					seconds = roundSeconds,
					stats = Flow.statsFor(p, place), -- OpenFront per-match stats
				}
			end
		end
		local mapName = currentMapId
		for _, info in MapCatalog do
			if info.id == currentMapId then
				mapName = info.name
			end
		end
		task.spawn(Progression.roundEnded, results, {
			map = currentMapId,
			mapName = mapName .. (if mapState.compact then " (Compact)" else ""),
			mode = Teams.label(teamState.mode),
			kind = if match.cfg then match.cfg.kind else "standalone",
			players = #ranking,
		})
	end
	for place, p in ranking do
		local plr = playerOf(p)
		if plr then
			net:FireClient(plr, "matchStats", Flow.statsFor(p, place))
		end
	end
	if match.cfg and match.cfg.kind == "ranked" and Progression and #match.roundHumans == 2 then
		-- Ranked 1v1: the better-placed of the two players wins the Elo.
		local first, second
		for _, p in ranking do
			if p.kind == "Human" and p.userId then
				if not first then
					first = p.userId
				elseif not second then
					second = p.userId
				end
			end
		end
		if not second then
			for _, uid in match.roundHumans do
				if uid ~= first then
					second = uid
				end
			end
		end
		if first and second then
			task.spawn(Progression.rankedResult, first, second)
		end
	end
	local endSeconds = if match.role == "match" then Config.MATCH_END_SECONDS else Config.END_SCREEN_SECONDS
	setPhase("Ended", math.floor(endSeconds / Config.TICK))
end

local function step()
	tick += 1

	if phase == "Lobby" and (Matchmaker.active or match.role == "match") then
		if tick % 10 == 0 then
			net:FireAllClients("phase", phasePayload())
		end
		if match.role == "match" and match.ready and not match.done then
			-- Start when everyone the lobby sent is here, or after MATCH_WAIT_SECONDS.
			local expected = if type(match.cfg.players) == "table" then match.cfg.players else {}
			local here, all = 0, true
			for _, uid in expected do
				if Players:GetPlayerByUserId(uid) then
					here += 1
				else
					all = false
				end
			end
			if #Players:GetPlayers() > 0 then
				match.waitUntil = match.waitUntil or (tick + math.floor(Config.MATCH_WAIT_SECONDS / Config.TICK))
				if (#expected > 0 and all) or tick >= match.waitUntil then
					startNewGame()
				end
			end
		end
	elseif phase == "Lobby" then
		if tick % 10 == 0 then
			net:FireAllClients("phase", phasePayload())
		end
		local anyReady = false
		for _, plr in Players:GetPlayers() do
			if wantsPlay[plr.UserId] then
				anyReady = true
				break
			end
		end
		if not anyReady then
			-- Nobody has pressed Play yet: keep the lobby open.
			phaseEndTick = tick + math.floor(Config.MAP_VOTE_LOBBY_SECONDS / Config.TICK)
		elseif tick >= phaseEndTick then
			startNewGame()
		end
	elseif phase == "Spawn" then
		AiBehavior.step(tick) -- nations hop around their spawn cell
		if tick >= phaseEndTick then
			for _, p in players do
				if p.kind == "Human" and not p.spawned then
					-- OpenFront: a player who never picks a starting location doesn't play this
					-- round; they watch (SpawnExecution only runs for players who clicked).
					p.alive = false
					p.troops = 0
					p.deathTick = tick
					rosterDirty = true
					notify(p.id, "You didn't pick a starting location, so you're watching this round.", "info")
				end
			end
			roundStartTick = tick
			Perks.onPlay() -- perk passes (starting troops, gold, growth, Safe Landing shield)
			setPhase("Play", 0)
		end
	elseif phase == "Play" then
		for _, p in players do
			if p.alive then
				p.maxTroops = Config.maxTroops(p.kind, p.tiles, p.cities)
				if p.reinforceUntil then
					if tick < p.reinforceUntil then
						p.maxTroops = math.floor(p.maxTroops * (p.reinforceMult or 1)) -- Reinforcements boost (Perks)
					else
						p.reinforceUntil = nil
					end
				end
				local growth = Config.troopGrowth(p.kind, p.troops, p.maxTroops)
				if growth > 0 and p.perkGrowth then
					-- Rapid Growth: faster, but never past the cap that normal growth stops at.
					p.troops = math.max(p.troops, math.min(p.troops + growth * p.perkGrowth, p.maxTroops))
				else
					p.troops += growth
				end
				p.gold += Config.goldPerTick(p.kind) * (p.perkGold or 1)
				if p.kind == "Human" then
					-- Host options infiniteGold / infiniteTroops.
					if match.rules.infiniteGold then
						p.gold = math.max(p.gold, 1e9)
					end
					if match.rules.infiniteTroops then
						p.troops = math.max(p.troops, 1e9)
					end
				end
			end
		end
		Perf.start("structures")
		routeJobs.step()
		for _, s in structures do
			if not s.done and tick >= s.readyTick then
				s.done = true
				if s.kind == "City" and s.owner ~= 0 then
					players[s.owner].cities += 1
				end
				Perf.start("structures:rail")
				Railways.onBuilt(s) -- City / Port / Factory train stations
				Perf.stop("structures:rail")
				structuresDirty = true
			elseif s.kind == "Port" and s.done and s.owner ~= 0 then
				Perf.start("structures:trade")
				tickPortTrade(s)
				Perf.stop("structures:trade")
			end
		end
		Perf.stop("structures")
		Perf.start("ai")
		AiBehavior.step(tick)
		Perf.stop("ai")
		Perf.start("flow+diplo")
		Flow.step()
		Diplomacy.step(tick)
		Perf.stop("flow+diplo")
		Perf.start("attacks")
		for _, a in table.clone(attacks) do
			if not a.dead then
				tickAttack(a)
			end
		end
		Perf.stop("attacks")
		Perf.start("boats")
		for _, b in boats do
			b.pos += Config.BOAT_SPEED
			if b.pos >= #b.path then
				if b.kind == "transport" then
					landBoat(b)
				elseif checkTrade(b) and b.pos >= #b.path then
					finishTrade(b) -- (a rerouted captured ship starts a new route instead)
				end
			elseif b.kind == "trade" then
				checkTrade(b) -- destination lost / embargo / captured ship rerouting
			end
		end
		Perf.stop("boats")
		Perf.start("warships")
		Warships.tick()
		Perf.stop("warships")
		Perf.start("missiles")
		Missiles.tick()
		Perf.stop("missiles")
		Perf.start("railways")
		Railways.tick()
		Perf.stop("railways")
		Revive.step()
		Perf.start("coreRules")
		CoreRules.step() -- delete marks, fallout share, encircled territory
		Perf.stop("coreRules")
		Perf.start("doomsday")
		DoomsdayClock.step(tick)
		Perf.stop("doomsday")
		if tick % 10 == 0 and (DoomsdayClock.enabled() or MatchRules.get().overtime) then
			-- Once a second for the Doomsday Clock / Overtime panels: the land the shares are taken
			-- of (non-fallout land) and who is under the Doomsday bar.
			net:FireAllClients("clock", { land = Flow.winLand(), doom = DoomsdayClock.status() })
		end
		if tick % 10 == 0 then
			-- WinCheckExecution (FFA): most land > winPercent of non-fallout land, or the hard time limit.
			local winner, noHumans = Flow.checkWin()
			if Teams.isTeam(teamState.mode) then
				-- WinCheckExecution.checkWinnerTeam
				local team = Teams.checkWin(players, Flow.winLand(), Flow.winPercent())
				if not team and Flow.timeUp() then
					team = Teams.leader(players)
				end
				if team then
					endGame(nil, team)
				elseif noHumans then
					endGame(nil)
				end
			elseif winner then
				endGame(winner)
			elseif noHumans then
				endGame(nil)
			end
		end
	elseif phase == "Ended" and match.role == "match" then
		-- Match server: one round, then everyone goes back to the lobby (retried while anyone stays).
		if tick >= phaseEndTick and (not match.done or (tick % 150 == 0 and not RunService:IsStudio())) then
			match.done = true
			Matchmaker.toLobby(Players:GetPlayers())
		end
	elseif phase == "Ended" then
		if tick >= phaseEndTick then
			startMapVote()
			setPhase("Lobby", math.floor(Config.MAP_VOTE_LOBBY_SECONDS / Config.TICK))
		end
	end

	if phase ~= "Lobby" and players then
		flushWater()
		Perf.start("flushTiles")
		flushTileChanges()
		Perf.stop("flushTiles")
		Diplomacy.flush(tick)
		Railways.flush()
		if rosterDirty then
			rosterDirty = false
			net:FireAllClients("roster", rosterPayload())
		end
		if structuresDirty then
			structuresDirty = false
			net:FireAllClients("structures", structuresPayload())
		end
		if tick % 5 == 0 then
			Perf.start("stats+personal")
			net:FireAllClients("stats", statsPayload())
			sendPersonal()
			Perf.stop("stats+personal")
		end
		if (phase == "Spawn" or phase == "Ended") and tick % 10 == 0 then
			-- (Ended: keeps the "next round / back to the lobby in N s" banner counting down)
			net:FireAllClients("phase", phasePayload())
		end
	end
end

-- Client requests
local lastRequest: { [Player]: number } = {}

net.OnServerEvent:Connect(function(plr: Player, kind: any, a1: any, a2: any, a3: any)
	if typeof(kind) ~= "string" then
		return
	end
	if kind == "ready" then
		if players then
			sendInit(plr)
		else
			net:FireClient(plr, "phase", phasePayload())
		end
		return
	end
	if Matchmaker.handles(kind) then
		-- Lobby place: public lobby, ranked queue and private lobbies (Matchmaker).
		Matchmaker.handle(plr, kind, a1, a2)
		return
	end
	if kind == "leave" and match.role == "match" then
		-- Exit Game / Main Menu on a match server: back to the lobby place.
		wantsPlay[plr.UserId] = nil
		Matchmaker.toLobby({ plr })
		return
	end
	if kind == "play" then
		-- Pressed Play in the main menu: join this round if it's still picking spawns, else the next one.
		wantsPlay[plr.UserId] = true
		if players and byUser[plr.UserId] then
			Flow.setDisconnected(byUser[plr.UserId], false) -- back in their own round
		end
		if phase == "Spawn" and players and not byUser[plr.UserId] then
			addHuman(plr)
			sendInit(plr)
		end
		net:FireClient(plr, "joined", { phase = phase, inRound = byUser[plr.UserId] ~= nil })
		return
	end
	if kind == "setName" then
		setPlayerName(plr, a1)
		return
	end
	if kind == "gameSpeed" or kind == "pause" then
		gameSpeed.request(kind, a1)
		return
	end
	local now = os.clock()
	if lastRequest[plr] and now - lastRequest[plr] < 0.05 then
		return
	end
	lastRequest[plr] = now
	if kind == "vote" then
		if phase == "Lobby" and typeof(a1) == "string" then
			for _, info in voteOptions do
				if info.id == a1 then
					votes[plr.UserId] = a1
					net:FireAllClients("phase", phasePayload())
					break
				end
			end
		end
		return
	end
	if Revive.handles(kind) then
		Revive.handle(plr, if players then byUser[plr.UserId] else nil, kind)
		return
	end
	if not players then
		return
	end
	local p = byUser[plr.UserId]
	if kind == "boost" then
		if p then
			Perks.useBoost(plr, p, a1) -- a1 = boost key (MetaConfig.BOOSTS)
		end
		return
	end
	if not p or typeof(a1) ~= "number" or a1 ~= a1 then
		return
	end
	if Diplomacy.handles(kind) then
		if phase == "Play" then
			Diplomacy.handle(p, kind, math.floor(a1), a2, tick)
		end
		return
	end
	if Flow.handles(kind) then
		-- "embargo" (playerId | 0 = all, on), "target" (playerId), "quickChat" (to, phraseKey, targetId?)
		Flow.handle(p, kind, math.floor(a1), a2, a3)
		return
	end
	if kind == "retreat" or kind == "boatRetreat" or kind == "retaliate" or kind == "emoji" then
		-- Attacks display / keybinds / emoji table (OpenFront rules). a1 is a player or boat id.
		if phase ~= "Play" or not p.alive then
			return
		end
		local id = math.floor(a1)
		if kind == "retreat" then
			local a = findAttack(p, id)
			if a and not a.dead and not a.retreatAt then
				a.retreatAt = tick + interactRules.RETREAT_DELAY
			end
		elseif kind == "boatRetreat" then
			local b = boats[id]
			if b and b.kind == "transport" and b.owner == p.id and not b.retreating then
				-- Sail back along the way we came, from where the boat is now.
				local back = {}
				for i = math.max(1, math.floor(b.pos)), 1, -1 do
					back[#back + 1] = b.path[i]
				end
				if #back < 2 then
					back[2] = back[1]
				end
				b.path, b.pos, b.retreating = back, 1, true
				local pathBuf = buffer.create(#back * 4)
				for i, t in back do
					buffer.writeu32(pathBuf, (i - 1) * 4, t)
				end
				-- Re-announce the boat with its new route (clients replace it in place).
				net:FireAllClients("boatEnd", b.id)
				net:FireAllClients("boat", {
					id = b.id,
					owner = b.owner,
					kind = "transport",
					troops = b.troops,
					path = pathBuf,
					start = SimClock.now(),
					speed = Config.BOAT_SPEED / Config.TICK,
					retreating = true,
				})
			end
		elseif kind == "retaliate" then
			-- Counter-attack the attacker with min(their attack, ratio x our troops).
			local attacker = players[id]
			if attacker and attacker.alive and typeof(a2) == "number" and a2 == a2 then
				local theirs = 0
				for a in pairs(attacker.outgoing) do
					if a.target == p.id and not a.dead then
						theirs += a.troops
					end
				end
				local troops = math.floor(math.min(theirs, p.troops * math.clamp(a2, 0.01, 1)))
				if theirs > 0 and troops >= 1 then
					startLandAttack(p, id, troops)
				end
			end
		elseif kind == "emoji" then
			-- a1 = recipient player id (0 = everyone), a2 = index into Shared.Emojis.LIST.
			if typeof(a2) ~= "number" or a2 ~= a2 then
				return
			end
			local index = math.floor(a2)
			local to = if id == p.id then 0 else id
			if index < 1 or index > Emojis.COUNT or (to ~= 0 and not (players[to] and players[to].alive)) then
				return
			end
			p.emojiAt = p.emojiAt or {}
			if p.emojiAt[to] and tick - p.emojiAt[to] < Emojis.COOLDOWN_TICKS then
				return
			end
			p.emojiAt[to] = tick
			net:FireAllClients("emoji", { from = p.id, to = to, i = index })
		end
		return
	end
	local t = math.floor(a1)
	if t < 0 or t >= SIZE then
		return
	end

	if kind == "spawn" then
		if phase ~= "Spawn" or not ownable(t) then
			return
		end
		local o = getOwner(t)
		if o ~= 0 and o ~= p.id then
			return
		end
		-- OpenFront lets a player spawn anywhere free (no minimum distance for picked spawns).
		unclaimSpawn(p)
		claimSpawn(p, t)
	elseif kind == "attack" then
		if phase ~= "Play" or not p.alive or typeof(a2) ~= "number" or a2 ~= a2 then
			return
		end
		local ratio = math.clamp(a2, 0.01, 1)
		local target = getOwner(t)
		if target == p.id then
			return
		end
		if target ~= 0 and not players[target].alive then
			return
		end
		if target == 0 and not ownable(t) then
			return
		end
		local troops = math.floor(p.troops * ratio)
		if troops < 1 then
			return
		end
		-- Land attack if we share a border, otherwise send a boat.
		if not startLandAttack(p, target, troops) then
			launchBoat(p, t, troops)
		end
	elseif kind == "boat" then
		if phase ~= "Play" or not p.alive or typeof(a2) ~= "number" or a2 ~= a2 then
			return
		end
		if getOwner(t) == p.id then
			return
		end
		launchBoat(p, t, math.floor(p.troops * math.clamp(a2, 0.01, 1)))
	elseif kind == "build" then
		if typeof(a2) == "string" and Config.STRUCTURES[a2] then
			tryBuild(p, t, a2)
		end
	elseif kind == "nuke" then
		if typeof(a2) == "string" and Config.NUKES[a2] then
			launchNuke(p, t, a2, a3 == true) -- a3: rocket arcs down the map
		end
	elseif kind == "buildUnit" then
		if phase == "Play" and typeof(a2) == "string" and Config.UNITS[a2] then
			Warships.tryBuy(p, t, a2)
		end
	elseif kind == "deleteStructure" then
		-- OpenFront "Delete Unit": mark our nearest finished structure near the tile (30 s cooldown);
		-- it is removed 30 s later unless captured first (CoreRules / DeleteUnitExecution).
		if phase == "Play" then
			CoreRules.requestDelete(p, t)
		end
	elseif kind == "upgrade" then
		-- UpgradeStructureExecution: a2 = structure kind (BuildMenu sends it); without it, the
		-- structure on the tile or the nearest upgradable one of ours.
		if phase ~= "Play" or not p.alive then
			return
		end
		local target = nil
		if typeof(a2) == "string" and Config.STRUCTURES[a2] then
			target = CoreRules.upgradeTarget(p, a2, t)
		else
			local s = structureAt[t]
			if s and s.owner == p.id then
				target = CoreRules.upgradeTarget(p, s.kind, t)
			end
			if not target then
				for _, kind2 in Config.STRUCTURE_ORDER do
					target = CoreRules.upgradeTarget(p, kind2, t)
					if target then
						break
					end
				end
			end
		end
		if target and not MatchRules.unitDisabled(target.kind) then
			-- a3 = bulk amount (x1 / x5 / x10 / max), capped at MAX_UPGRADE_AMOUNT by CoreRules.
			local amount = if typeof(a3) == "number" and a3 == a3 then a3 else 1
			CoreRules.upgrade(p, target, amount)
		end
	elseif kind == "moveWarship" then
		-- a1 = destination water tile, a2 = warship id
		if phase == "Play" and p.alive and typeof(a2) == "number" and a2 == a2 then
			Warships.move(p, math.floor(a2), t)
		end
	end
end)

-- New players start in the main menu; they join a round when they press Play.
Players.PlayerAdded:Connect(function(plr)
	Teams.loadFriends(plr) -- friends end up on the same team
	if not gameSpeed.solo() then
		gameSpeed.reset()
	end
	if match.role == "match" then
		-- Match servers: everyone plays (they were sent here by the lobby).
		wantsPlay[plr.UserId] = true
	end
end)

for _, plr in Players:GetPlayers() do
	Teams.loadFriends(plr)
end

Players.PlayerRemoving:Connect(function(plr)
	Teams.forget(plr.UserId)
	-- MarkDisconnectedExecution: the nation stays on the map, marked disconnected.
	if players and byUser[plr.UserId] then
		Flow.setDisconnected(byUser[plr.UserId], true)
	end
	lastRequest[plr] = nil
	wantsPlay[plr.UserId] = nil
	votes[plr.UserId] = nil
	if match.cfg and match.cfg.kind == "ranked" and (phase == "Spawn" or phase == "Play") and players then
		-- Ranked 1v1: leaving forfeits; the other player wins.
		for _, uid in match.roundHumans do
			local other = byUser[uid]
			if uid ~= plr.UserId and other and Players:GetPlayerByUserId(uid) then
				endGame(other)
				break
			end
		end
	end
end)

-- Studio-only test hook (never exists in live servers): ServerStorage.WFDev
-- (BindableFunction) lets Studio tools set up test situations quickly.
--   ("info", userId) -> { id, tiles, gold, troops, cx, cy, W, H, phase }
--   ("gold", userId, amount)   ("troops", userId, amount)
--   ("grab", userId, cx, cy, r) take every ownable tile in a radius
--   ("win", userId)            end the round with that player as the winner
--   ("item", userId, key, n)   add n boosts (or "revive") to the player's inventory
--   ("kill", userId)           defeat that player (defeat screen / revive tests)
if RunService:IsStudio() then
	local dev = Instance.new("BindableFunction")
	dev.Name = "WFDev"
	dev.OnInvoke = function(cmd: string, uid: number, a: any, b: any, c: any)
		local p = players and byUser[uid]
		if cmd == "info" then
			if not p then
				return { phase = phase, W = W, H = HGT }
			end
			return { id = p.id, tiles = p.tiles, gold = p.gold, troops = p.troops, cx = p.tiles > 0 and p.sumX // p.tiles or 0, cy = p.tiles > 0 and p.sumY // p.tiles or 0, W = W, H = HGT, phase = phase }
		elseif not p then
			return "no player"
		elseif cmd == "gold" then
			p.gold += a
		elseif cmd == "troops" then
			p.troops += a
		elseif cmd == "grab" then
			local n = 0
			for y = math.max(0, b - c), math.min(HGT - 1, b + c) do
				for x = math.max(0, a - c), math.min(W - 1, a + c) do
					local t = y * W + x
					if (x - a) ^ 2 + (y - b) ^ 2 <= c * c and ownable(t) and getOwner(t) ~= p.id then
						setOwner(t, p.id)
						n += 1
					end
				end
			end
			return n
		elseif cmd == "win" then
			endGame(p)
		elseif cmd == "kill" then -- ("kill", userId): defeat that player now
			killPlayer(p, nil)
		elseif cmd == "item" then -- ("item", userId, key, n): add n boosts / revives to the inventory
			for _ = 1, (tonumber(b) or 1) do
				Progression.returnBoost(Players:GetPlayerByUserId(uid), a)
			end
		end
		return true
	end
	dev.Parent = game:GetService("ServerStorage")
end

-- Main loop
resetWorld()
players = nil :: any
phaseEndTick = math.floor(Config.MAP_VOTE_LOBBY_SECONDS / Config.TICK)
startMapVote()

DoomsdayClock.init({
	players = function()
		return players
	end,
	teamGame = function(): boolean
		return Teams.isTeam(teamState.mode)
	end,
	elapsed = function(): number
		return math.max(0, tick - roundStartTick) * Config.TICK
	end,
	land = function(): number
		return Flow.winLand()
	end,
	getOwner = getOwner,
	relinquish = function(t: number)
		-- Rot: wasteland, not a prize (the land goes to nobody, with fallout).
		setOwner(t, 0)
		buffer.writeu8(fallout, t, 1)
		markChanged(t)
	end,
	map = function()
		return map
	end,
	tick = function(): number
		return tick
	end,
	kill = function(p)
		killPlayer(p, nil)
	end,
})

Matchmaker.init({
	net = net,
	progression = Progression,
	mapPool = function()
		local pool = {}
		for _, info in MapCatalog do
			if mapsFolder:FindFirstChild(info.id) then
				pool[#pool + 1] = info
			end
		end
		return pool
	end,
	rollTeams = function()
		return Teams.rollTeams(rng)
	end,
	modeTitle = Teams.title,
	isTeam = Teams.isTeam,
})
if match.role == "match" then
	for _, plr in Players:GetPlayers() do
		wantsPlay[plr.UserId] = true
	end
	task.spawn(function()
		local cfg = Matchmaker.matchConfig()
		if not cfg then
			-- Not started by the lobby (or its settings are gone): send everyone to the lobby.
			warn("[War Front] match server without settings; sending players to the lobby")
			match.done = true
			Players.PlayerAdded:Connect(function(plr)
				Matchmaker.toLobby({ plr })
			end)
			Matchmaker.toLobby(Players:GetPlayers())
			return
		end
		match.cfg = cfg
		match.rules = if type(cfg.settings) == "table" then cfg.settings else {}
		if type(cfg.map) ~= "string" or not mapsFolder:FindFirstChild(cfg.map) then
			cfg.map = "Europe"
		end
		workspace:SetAttribute("WFMatchKind", cfg.kind)
		match.ready = true
	end)
end

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	if gameSpeed.paused then
		acc = 0
		gameSpeed.ticks, gameSpeed.checkAt = 0, os.clock()
		return
	end
	local mult = gameSpeed.mult
	acc = math.min(acc + dt * mult, Config.TICK * 3 * math.max(1, mult))
	local stopAt = os.clock() + 0.014 -- never spend more than ~14 ms of a frame simulating
	while acc >= Config.TICK do
		acc -= Config.TICK
		Perf.start("tick")
		local ok, err = pcall(step)
		Perf.stop("tick")
		gameSpeed.ticks += 1
		if not ok then
			warn("[War Front] tick error: " .. tostring(err))
		end
		if mult > 1 and os.clock() > stopAt then
			acc = 0 -- the server can't keep up: run slower instead of piling up ticks
			break
		end
	end
	-- Once a second when sped up: the real speed (a busy server may not reach the chosen one).
	if mult ~= 1 then
		local now = os.clock()
		if now - gameSpeed.checkAt >= 1 then
			local real = gameSpeed.ticks * Config.TICK / (now - gameSpeed.checkAt)
			gameSpeed.ticks, gameSpeed.checkAt = 0, now
			local measured = math.min(mult, math.floor(real * 20 + 0.5) / 20)
			if math.abs(measured - gameSpeed.actual) / mult > 0.08 then
				gameSpeed.actual = measured
				gameSpeed.apply()
			end
		end
	end
end)
