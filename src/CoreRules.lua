--[[
	War Front - core structure and territory rules (server side).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Rules ported from OpenFront (AGPL-3.0): src/core/configuration/Config.ts (costWrapper,
	conquerGoldAmount), src/core/game/PlayerImpl.ts (validStructureSpawnTiles, portSpawn,
	findUnitToUpgrade, canUpgradeUnit, upgradeUnit), UpgradeStructureExecution.ts,
	DeleteUnitExecution.ts, AttackExecution.ts (handleDeadDefender), GameImpl.conquerPlayer and
	PlayerExecution.ts (removeClusters: encircled territory changes hands).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.CoreRules (ModuleScript), used by GameServer.
--
-- CoreRules.init(ctx) / reset() / step()
-- CoreRules.cost(p, kind, extra?) -> gold         costWrapper: levels owned vs levels ever built
-- CoreRules.spawnTile(p, tile, kind) -> tile?     where a new structure would go (nil = nowhere)
-- CoreRules.upgradeTarget(p, kind, tile) -> s?    the structure a build/upgrade there would level up
-- CoreRules.upgrade(p, s, amount?) -> levels      UpgradeStructureExecution
-- CoreRules.noteBuilt(p, kind)                    a new structure was placed (unitsConstructed)
-- CoreRules.requestDelete(p, tile) -> boolean     DeleteUnitExecution: mark, remove 30 s later
-- CoreRules.isMarked(s) -> boolean
-- CoreRules.falloutRatio() -> share of land tiles with fallout
-- CoreRules.noteAttack(p)                          p launched an attack (conquest gold rule)
-- CoreRules.conquerPlayer(conqueror, conquered)   gold transfer + "conquest" event
-- CoreRules.handleDeadDefender(attacker, defender)
--
-- Scale: one tile here is LINEAR_SCALE (4) full-size tiles per axis. Distances from OpenFront are
-- divided by 4 (see Config.MIN_STRUCTURE_DISTANCE etc.); tile counts by AREA_SCALE (16).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))

local CoreRules = {}

local ctx: any = nil
local NB = table.create(4)
local NB2 = table.create(4)
local NB8 = table.create(8)

-- Fallout share, recounted in slices (a full pass every FALLOUT_PASS ticks).
local FALLOUT_PASS = 10
local falloutScan = 0
local falloutCount = 0
local falloutRunning = 0
local falloutRatio = 0

function CoreRules.init(c)
	ctx = c
end

function CoreRules.reset()
	falloutScan, falloutCount, falloutRunning, falloutRatio = 0, 0, 0, 0
end

local function mapNow()
	return ctx.map()
end

local function notify(p, text: string, kind: string?)
	local plr = p and ctx.playerOf(p)
	if plr then
		ctx.net:FireClient(plr, "event", { text = text, kind = kind or "info", owner = p.id })
	end
end

--------------------------------------------------------------------------------
-- Cost scaling (Config.costWrapper)
--------------------------------------------------------------------------------
-- unitsOwned: a structure under construction counts 1, a finished one its level.
local function ownedLevels(p, kind: string): number
	local n = 0
	for s in pairs(p.structs) do
		if s.kind == kind then
			n += if s.done then (s.level or 1) else 1
		end
	end
	return n
end

-- unitsConstructed: every structure this player placed or upgraded (captured ones don't count).
local function builtCount(p, kind: string): number
	return p.built and p.built[kind] or 0
end

function CoreRules.cost(p, kind: string, extra: number?): number
	local def = Config.STRUCTURES[kind]
	if not def then
		return math.huge
	end
	local n = 0
	for _, k in def.shares or { kind } do
		n += math.min(ownedLevels(p, k), builtCount(p, k))
	end
	return def.cost(n + (extra or 0))
end

function CoreRules.noteBuilt(p, kind: string)
	p.built = p.built or {}
	p.built[kind] = (p.built[kind] or 0) + 1
end

--------------------------------------------------------------------------------
-- Placement (PlayerImpl.validStructureSpawnTiles / landBasedStructureSpawn / portSpawn)
--------------------------------------------------------------------------------
local function d2(map, a: number, b: number): number
	local W = map.width
	local dx, dy = a % W - b % W, a // W - b // W
	return dx * dx + dy * dy
end

local function manhattan(map, a: number, b: number): number
	local W = map.width
	return math.abs(a % W - b % W) + math.abs(a // W - b // W)
end

local function isShore(map, t: number): boolean
	if not MapUtil.isLand(map, t) then
		return false
	end
	local n = MapUtil.neighbors(map, t, NB2)
	for i = 1, n do
		if not MapUtil.isLand(map, NB2[i]) then
			return true
		end
	end
	return false
end

-- Own tiles reachable from `tile` through own tiles inside the search radius, that keep the
-- minimum distance to every structure (any owner, incl. under construction), nearest first.
local function validSpawnTiles(p, tile: number): { number }
	local map = mapNow()
	if ctx.getOwner(tile) ~= p.id then
		return {}
	end
	local W = map.width
	local R = Config.STRUCTURE_SEARCH_RADIUS
	local R2 = R * R
	local cx, cy = tile % W, tile // W
	local seen = { [tile] = true }
	local list = { tile }
	local stack = { tile }
	while #stack > 0 do
		local t = table.remove(stack)
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local nt = NB[i]
			if not seen[nt] then
				seen[nt] = true
				local dx, dy = nt % W - cx, nt // W - cy
				if dx * dx + dy * dy < R2 and ctx.getOwner(nt) == p.id then
					list[#list + 1] = nt
					stack[#stack + 1] = nt
				end
			end
		end
	end
	-- Structures close enough to block any of these tiles.
	local minD = Config.MIN_STRUCTURE_DISTANCE
	local minD2 = minD * minD
	local reach = (R + minD) ^ 2
	local near = {}
	for _, s in ctx.structures() do
		if d2(map, s.tile, tile) <= reach then
			near[#near + 1] = s.tile
		end
	end
	local valid = {}
	local order = {}
	for i, t in list do
		local blocked = false
		for _, st in near do
			if d2(map, st, t) < minD2 then
				blocked = true
				break
			end
		end
		if not blocked then
			valid[#valid + 1] = t
			order[t] = i
		end
	end
	table.sort(valid, function(a, b)
		local da, db = d2(map, a, tile), d2(map, b, tile)
		if da ~= db then
			return da < db
		end
		return order[a] < order[b] -- OpenFront's sort is stable over the flood order
	end)
	return valid
end

function CoreRules.spawnTile(p, tile: number, kind: string): number?
	local def = Config.STRUCTURES[kind]
	if not def then
		return nil
	end
	local valid = validSpawnTiles(p, tile)
	if #valid == 0 then
		return nil
	end
	if not def.coastal then
		return valid[1]
	end
	-- Port: the own shore tile nearest (Manhattan) to the click inside radiusPortSpawn that is
	-- also a valid structure tile.
	local map = mapNow()
	local W, H = map.width, map.height
	local validSet = {}
	for _, t in valid do
		validSet[t] = true
	end
	local r = math.floor(Config.PORT_SPAWN_RADIUS)
	local cx, cy = tile % W, tile // W
	local best, bestD = nil, math.huge
	for dy = -r, r do
		for dx = -r, r do
			local d = math.abs(dx) + math.abs(dy)
			local x, y = cx + dx, cy + dy
			if d <= r and d < bestD and x >= 0 and x < W and y >= 0 and y < H then
				local t = y * W + x
				if validSet[t] and isShore(map, t) then
					best, bestD = t, d
				end
			end
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Upgrades (findUnitToUpgrade / canUpgradeUnit / upgradeUnit / UpgradeStructureExecution)
--------------------------------------------------------------------------------
function CoreRules.isMarked(s): boolean
	return s.deleteAt ~= nil and s.deleteBy == s.owner
end

-- The nearest structure of `kind` (any owner, incl. under construction) within the minimum
-- structure distance; it only counts if p may upgrade it.
function CoreRules.upgradeTarget(p, kind: string, tile: number)
	local def = Config.STRUCTURES[kind]
	if not def or not def.upgradable then
		return nil
	end
	local map = mapNow()
	local R = Config.MIN_STRUCTURE_DISTANCE
	local best, bestD = nil, R * R
	for _, s in ctx.structures() do
		if s.kind == kind then
			local d = d2(map, s.tile, tile)
			if d <= bestD then
				best, bestD = s, d
			end
		end
	end
	if best and best.owner == p.id and best.done and not CoreRules.isMarked(best) then
		return best
	end
	return nil
end

local function canUpgrade(p, s): boolean
	local def = Config.STRUCTURES[s.kind]
	return def ~= nil
		and def.upgradable == true
		and p.alive
		and s.owner == p.id
		and s.done
		and not CoreRules.isMarked(s)
		and p.gold >= CoreRules.cost(p, s.kind)
end

function CoreRules.canUpgrade(p, s): boolean
	return canUpgrade(p, s)
end

-- Returns how many levels were added (0 = refused).
function CoreRules.upgrade(p, s, amount: number?): number
	amount = math.clamp(math.floor(amount or 1), 1, Config.MAX_UPGRADE_AMOUNT)
	local done = 0
	for _ = 1, amount do
		if not canUpgrade(p, s) then
			break
		end
		p.gold -= CoreRules.cost(p, s.kind)
		s.level = (s.level or 1) + 1
		CoreRules.noteBuilt(p, s.kind)
		if s.kind == "City" then
			p.cities += 1 -- finished city levels raise max troops
		end
		if s.kind == "MissileSilo" or s.kind == "SAM" then
			-- UnitImpl.increaseLevel: the new missile slot starts reloading.
			s.missiles = s.missiles or {}
			table.insert(s.missiles, ctx.tick())
		end
		done += 1
	end
	if done > 0 then
		ctx.markStructures()
	end
	return done
end

--------------------------------------------------------------------------------
-- Delete Unit (DeleteUnitExecution + the radial menu's selection)
--------------------------------------------------------------------------------
function CoreRules.requestDelete(p, tile: number): boolean
	local map = mapNow()
	if not p.alive or ctx.getOwner(tile) ~= p.id or not MapUtil.isLand(map, tile) then
		return false
	end
	if p.lastDelete and ctx.tick() - p.lastDelete < Config.DELETE_UNIT_COOLDOWN then
		return false
	end
	local best, bestD = nil, math.huge
	for s in pairs(p.structs) do
		local d = manhattan(map, s.tile, tile)
		if s.done and not CoreRules.isMarked(s) and d <= Config.DELETE_SELECTION_RADIUS and d < bestD then
			best, bestD = s, d
		end
	end
	if not best then
		return false
	end
	p.lastDelete = ctx.tick()
	best.deleteAt = ctx.tick() + Config.DELETION_MARK_TICKS
	best.deleteBy = p.id
	ctx.markStructures()
	return true
end

local function stepDeletions()
	local now = ctx.tick()
	for _, s in ctx.structures() do
		if s.deleteAt then
			if s.deleteBy ~= s.owner then
				-- Captured while marked: the mark is cleared (UnitImpl.setOwner).
				s.deleteAt, s.deleteBy = nil, nil
				ctx.markStructures()
			elseif now > s.deleteAt then
				local p = ctx.players()[s.owner]
				ctx.removeStructure(s)
				notify(p, "Unit voluntarily deleted", "info")
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Fallout share (AttackExecution falloutRatio = numTilesWithFallout / numLandTiles)
--------------------------------------------------------------------------------
local function stepFallout()
	local map = mapNow()
	local size = map.size
	local buf = ctx.fallout()
	local chunk = math.ceil(size / FALLOUT_PASS)
	local stop = math.min(size, falloutScan + chunk)
	for t = falloutScan, stop - 1 do
		if buffer.readu8(buf, t) == 1 then
			falloutRunning += 1
		end
	end
	falloutScan = stop
	if falloutScan >= size then
		falloutCount = falloutRunning
		falloutRunning, falloutScan = 0, 0
		falloutRatio = falloutCount / math.max(1, map.landTiles)
	end
end

function CoreRules.falloutRatio(): number
	return falloutRatio
end

--------------------------------------------------------------------------------
-- Conquest (GameImpl.conquerPlayer, Config.conquerGoldAmount)
--------------------------------------------------------------------------------
function CoreRules.noteAttack(p)
	p.attacked = true
end

function CoreRules.conquerPlayer(conqueror, conquered)
	if conquered.conqueredBy == conqueror.id then
		return -- already handed over (a remnant island being mopped up)
	end
	conquered.conqueredBy = conqueror.id
	local captured = 0
	-- A human who never attacked anyone didn't play: no gold changes hands.
	if conquered.kind == "Human" and not conquered.attacked then
		notify(conqueror, string.format("Conquered %s (didn't play, no gold awarded)", conquered.name), "info")
	else
		captured = Config.conquerGold(conquered.kind, conquered.gold, true)
		notify(conqueror, string.format("Conquered %s, received %s gold", conquered.name, Config.renderNumber(captured)), "info")
		conqueror.gold += captured
		conquered.gold = 0
	end
	-- OpenFront ConquestEvent: the conqueror's client shows a sword + "+ gold" (MapFx.conquest).
	conquered.conquestGold = captured -- GameFlow per-match stats (goldWar)
	ctx.net:FireAllClients("conquest", { killer = conqueror.id, victim = conquered.id, gold = math.floor(captured) })
end

-- AttackExecution.handleDeadDefender: under 100 full-size tiles left, the defender is conquered
-- and its remaining land goes to the attacker (tiles touching it) or to a neighbouring enemy of
-- the defender, pass after pass.
function CoreRules.handleDeadDefender(attacker, defender)
	if defender.tiles * Config.AREA_SCALE >= Config.DEAD_DEFENDER_TILES then
		return
	end
	CoreRules.conquerPlayer(attacker, defender)
	local map = mapNow()
	local getOwner = ctx.getOwner
	local players = ctx.players()
	-- Collect the defender's tiles: flood from its border tiles through its own land.
	local tiles, seen = {}, {}
	local stack = {}
	for t in pairs(defender.border) do
		if not seen[t] then
			seen[t] = true
			stack[#stack + 1] = t
		end
	end
	while #stack > 0 do
		local t = table.remove(stack)
		tiles[#tiles + 1] = t
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local nt = NB[i]
			if not seen[nt] and getOwner(nt) == defender.id then
				seen[nt] = true
				stack[#stack + 1] = nt
			end
		end
	end
	for _ = 1, 100 do
		local progressed = false
		for _, t in tiles do
			if getOwner(t) == defender.id then
				local n = MapUtil.neighbors(map, t, NB)
				local taker = nil
				for i = 1, n do
					if getOwner(NB[i]) == attacker.id then
						taker = attacker.id
						break
					end
				end
				if not taker then
					for i = 1, n do
						local o = getOwner(NB[i])
						if o ~= 0 and o ~= defender.id and players[o] and not ctx.allied(o, defender.id) then
							taker = o
							break
						end
					end
				end
				if taker then
					ctx.setOwner(t, taker)
					progressed = true
				end
			end
		end
		if not progressed then
			break
		end
	end
end

--------------------------------------------------------------------------------
-- Encircled territory (PlayerExecution.removeClusters)
--------------------------------------------------------------------------------
local function onEdge(map, t: number): boolean
	local W, H = map.width, map.height
	local x, y = t % W, t // W
	return x == 0 or y == 0 or x == W - 1 or y == H - 1
end

local function isOceanShore(map, t: number): boolean
	local n = MapUtil.neighbors(map, t, NB2)
	for i = 1, n do
		local b = buffer.readu8(map.terrain, NB2[i])
		if b < 128 and bit32.band(b, 32) ~= 0 then
			return true
		end
	end
	return false
end

-- 8-neighbours of t into NB8.
local function neighbors8(map, t: number): number
	local W, H = map.width, map.height
	local x, y = t % W, t // W
	local n = 0
	for dy = -1, 1 do
		for dx = -1, 1 do
			if dx ~= 0 or dy ~= 0 then
				local xx, yy = x + dx, y + dy
				if xx >= 0 and xx < W and yy >= 0 and yy < H then
					n += 1
					NB8[n] = yy * W + xx
				end
			end
		end
	end
	return n
end

-- Border tiles grouped 8-connected, each with its bounding box { minX, minY, maxX, maxY }.
local function calculateClusters(map, p)
	local W = map.width
	local clusters, boxes = {}, {}
	local done = {}
	for start in pairs(p.border) do
		if not done[start] then
			done[start] = true
			local cluster = { start }
			local stack = { start }
			local x0, y0 = start % W, start // W
			local box = { x0, y0, x0, y0 }
			while #stack > 0 do
				local t = table.remove(stack)
				local n = neighbors8(map, t)
				for i = 1, n do
					local nt = NB8[i]
					if not done[nt] and p.border[nt] then
						done[nt] = true
						cluster[#cluster + 1] = nt
						stack[#stack + 1] = nt
						local x, y = nt % W, nt // W
						if x < box[1] then box[1] = x end
						if y < box[2] then box[2] = y end
						if x > box[3] then box[3] = x end
						if y > box[4] then box[4] = y end
					end
				end
			end
			clusters[#clusters + 1] = cluster
			boxes[#boxes + 1] = box
		end
	end
	return clusters, boxes
end

local function contains(outer, inner): boolean
	return outer[1] <= inner[1] and outer[2] <= inner[2] and outer[3] >= inner[3] and outer[4] >= inner[4]
end

-- Territory id per cluster (8-connected flood through own land), computed on demand.
local function territoryOf(map, p, clusters, clusterOf, ids, idx: number, nextId)
	if ids[idx] then
		return ids[idx]
	end
	local id = nextId[1]
	nextId[1] += 1
	local start = clusters[idx][1]
	local seen = { [start] = true }
	local stack = { start }
	ids[idx] = id
	local getOwner = ctx.getOwner
	while #stack > 0 do
		local t = table.remove(stack)
		local n = neighbors8(map, t)
		for i = 1, n do
			local nt = NB8[i]
			if not seen[nt] and getOwner(nt) == p.id then
				seen[nt] = true
				stack[#stack + 1] = nt
				local c = clusterOf[nt]
				if c and not ids[c] then
					ids[c] = id
				end
			end
		end
	end
	return id
end

local function surroundedBySamePlayer(map, p, cluster, box)
	local W = map.width
	local getOwner = ctx.getOwner
	local enemy = nil
	local bx = { math.huge, math.huge, -math.huge, -math.huge }
	for _, t in cluster do
		if isOceanShore(map, t) or onEdge(map, t) then
			return nil
		end
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local o = getOwner(NB[i])
			if o == 0 then
				return nil
			end
			if o ~= p.id then
				if enemy and enemy ~= o then
					return nil
				end
				enemy = o
				local x, y = NB[i] % W, NB[i] // W
				if x < bx[1] then bx[1] = x end
				if y < bx[2] then bx[2] = y end
				if x > bx[3] then bx[3] = x end
				if y > bx[4] then bx[4] = y end
			end
		end
	end
	if enemy and contains(bx, box) then
		return enemy
	end
	return nil
end

local function isSurrounded(map, p, cluster, box): boolean
	local W = map.width
	local getOwner = ctx.getOwner
	local hasEnemy = false
	local bx = { math.huge, math.huge, -math.huge, -math.huge }
	for _, t in cluster do
		if isShore(map, t) or onEdge(map, t) then
			return false
		end
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local o = getOwner(NB[i])
			if o ~= 0 and o ~= p.id then
				hasEnemy = true
				local x, y = NB[i] % W, NB[i] // W
				if x < bx[1] then bx[1] = x end
				if y < bx[2] then bx[2] = y end
				if x > bx[3] then bx[3] = x end
				if y > bx[4] then bx[4] = y end
			end
		end
	end
	return hasEnemy and contains(bx, box)
end

local function capturingPlayer(map, p, cluster)
	local getOwner = ctx.getOwner
	local players = ctx.players()
	local counts, order = {}, {}
	for _, t in cluster do
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local o = getOwner(NB[i])
			if o ~= 0 and o ~= p.id and players[o] and not ctx.allied(o, p.id) then
				if not counts[o] then
					order[#order + 1] = o
				end
				counts[o] = (counts[o] or 0) + 1
			end
		end
	end
	if #order == 0 then
		return nil
	end
	-- The neighbour with the biggest attack on p, else the one with the longest shared border.
	local best, bestTroops = nil, 0
	for _, a in ctx.attacks() do
		if not a.dead and a.target == p.id and counts[a.attacker.id] and a.troops > bestTroops then
			best, bestTroops = a.attacker.id, a.troops
		end
	end
	if best then
		return players[best]
	end
	local mode, modeCount = nil, -1
	for _, o in order do
		if counts[o] > modeCount then
			mode, modeCount = o, counts[o]
		end
	end
	return players[mode]
end

-- Walls of other players all round: walking through own and unclaimed land never reaches water
-- or the map edge.
local function isEnclosed(map, p, start: number): boolean
	local getOwner = ctx.getOwner
	local seen = { [start] = true }
	local stack = { start }
	while #stack > 0 do
		local t = table.remove(stack)
		if onEdge(map, t) then
			return false
		end
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local nt = NB[i]
			if not seen[nt] then
				local o = getOwner(nt)
				if o == 0 or o == p.id then
					if o == 0 and not MapUtil.isLand(map, nt) then
						return false
					end
					seen[nt] = true
					stack[#stack + 1] = nt
				end
			end
		end
	end
	return true
end

local function removeCluster(map, p, cluster)
	local getOwner = ctx.getOwner
	for _, t in cluster do
		if getOwner(t) ~= p.id then
			return
		end
	end
	local capturing = capturingPlayer(map, p, cluster)
	if not capturing then
		return
	end
	local first = cluster[1]
	if not isEnclosed(map, p, first) then
		return
	end
	local tiles = { first }
	local seen = { [first] = true }
	local stack = { first }
	while #stack > 0 do
		local t = table.remove(stack)
		local n = MapUtil.neighbors(map, t, NB)
		for i = 1, n do
			local nt = NB[i]
			if not seen[nt] and getOwner(nt) == p.id then
				seen[nt] = true
				tiles[#tiles + 1] = nt
				stack[#stack + 1] = nt
			end
		end
	end
	if #tiles == p.tiles then
		CoreRules.conquerPlayer(capturing, p)
	end
	for _, t in tiles do
		ctx.setOwner(t, capturing.id)
	end
	if p.tiles <= 0 then
		ctx.killPlayer(p, capturing)
	end
end

local function removeClusters(p)
	local map = mapNow()
	local clusters, boxes = calculateClusters(map, p)
	if #clusters == 0 then
		return
	end
	local largest = 1
	for i = 2, #clusters do
		if #clusters[i] > #clusters[largest] then
			largest = i
		end
	end
	if #clusters > 1 then
		-- Doughnut fix: a hole's rim can be the biggest border cluster; if the largest cluster
		-- lies inside another cluster of the same contiguous territory, use the biggest non-hole.
		local clusterOf = nil
		local ids, nextId = {}, { 1 }
		local function sameTerritory(a: number, b: number): boolean
			if not clusterOf then
				clusterOf = {}
				for c, cl in clusters do
					for _, t in cl do
						clusterOf[t] = c
					end
				end
			end
			return territoryOf(map, p, clusters, clusterOf, ids, a, nextId) == territoryOf(map, p, clusters, clusterOf, ids, b, nextId)
		end
		local function isHole(i: number): boolean
			for j = 1, #clusters do
				if j ~= i and contains(boxes[j], boxes[i]) and sameTerritory(i, j) then
					return true
				end
			end
			return false
		end
		if isHole(largest) then
			local best, bestLen = nil, -1
			for i = 1, #clusters do
				if i ~= largest and #clusters[i] > bestLen and not isHole(i) then
					best, bestLen = i, #clusters[i]
				end
			end
			if best then
				largest = best
			end
		end
	end
	local enemy = surroundedBySamePlayer(map, p, clusters[largest], boxes[largest])
	if enemy and not ctx.allied(enemy, p.id) then
		removeCluster(map, p, clusters[largest])
	end
	for i = 1, #clusters do
		if i ~= largest and p.alive and isSurrounded(map, p, clusters[i], boxes[i]) then
			removeCluster(map, p, clusters[i])
		end
	end
end

local function stepClusters()
	local now = ctx.tick()
	for _, p in ctx.players() do
		if p.alive and p.tiles > 0 then
			-- Cheap stand-in for lastTileChange: the tile count and the coordinate sums.
			local sig = p.tiles * 1e9 + p.sumX * 7 + p.sumY
			if p.clusterAt == nil then
				p.clusterAt = now + (p.id % Config.CLUSTER_CALC_TICKS)
				p.clusterSig = nil
			end
			local due = now - p.clusterAt > Config.CLUSTER_CALC_TICKS or p.tiles * Config.AREA_SCALE < 100
			if due and sig ~= p.clusterSig then
				p.clusterAt = now
				p.clusterSig = sig
				removeClusters(p)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Per tick (Play phase)
--------------------------------------------------------------------------------
function CoreRules.step()
	stepDeletions()
	stepFallout()
	stepClusters()
end

return CoreRules
