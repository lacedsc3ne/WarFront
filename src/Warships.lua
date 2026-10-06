--[[
	War Front - warships, shells and naval combat (server side).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Rules ported from OpenFront (AGPL-3.0): src/core/execution/WarshipExecution.ts (targeting,
	patrol, trade-ship hunting, repair retreat / docking), ShellExecution.ts (homing shells),
	src/core/game/UnitImpl.ts (veterancy) and DefaultConfig.ts (warship numbers).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.

	ModuleScript used by GameServer. GameServer calls Warships.init(ctx) once and then
	reset / tick / tryBuy / move / snapshot / cost / aiConsider / destroyInBlast / routeToPort.
]]

-- Scale: full-size distances / LINEAR_SCALE (Config): patrol 100 -> 25, targeting 130 -> 32.5,
-- passive healing 150 -> 37.5, docking 5 -> 1.5 (rounded up so a ship next to the port docks),
-- capture 5 -> Manhattan 1, shells 3 tiles/tick -> 0.75. Ticks, health and damage are unchanged.
-- Network: "units" buffer, 16 bytes per warship: u32 id, u16 owner, u32 tile, u16 health,
--   u8 flags (bit0 = in combat / "angry", bit1 = retreating or docked), u8 veterancy, u16 max health.
-- "shot" buffer, 15 bytes per shell: u32 from tile, u32 target tile (at launch), u16 estimated
--   flight ticks, u8 target kind (1 = warship, 2 = boat), u32 target id (homing on the client).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))

local Warships = {}

local L = Config.LINEAR_SCALE
local DOCKING_RANGE = 1.5
local RETREAT_PERCENT = 75 -- warshipRetreatHealthPercent
local MANUAL_MOVE_NO_RETREAT = 50 -- ticks after a move order without auto-retreat
local PORT_HEAL_PER_LEVEL = 5 -- warshipPortHealingBonusPerLevel
local PORT_SWITCH = 0.75 -- warshipPortSwitchThreshold
local SHELL_LIFETIME = 50 -- shellLifetime: ticks a shell keeps flying after its ship sank
local MAX_VETERANCY = 3
local VET_HEALTH_BONUS = 20 -- percent per level
local VET_DAMAGE_BONUS = 20
local VET_TRANSPORTS, VET_CAPTURES = 10, 25
local VET_LEVEL_POINTS = VET_TRANSPORTS * VET_CAPTURES
local SAFE_FROM_PIRATES = 20 -- safeFromPiratesCooldownMax
local COMBAT_FLAG_TICKS = 10

local ctx -- set by init: see GameServer
local map, W, SIZE
local NB = table.create(4)

local ships: { [number]: any } = {}
local nextShipId = 1
local shells: { any } = {}
local doomed: { [any]: boolean } = {} -- transport boats that already have a shell on the way
local pendingShots: { any } = {}
local lastSentCount = 0

local LOCAL_BFS_LIMIT = 20000
local FAR_BFS_LIMIT = 160000

local bfsStamp: buffer
local bfsParent: buffer
local bfsGen = 0

local function isWater(t: number): boolean
	return not MapUtil.isLand(map, t)
end

local function dist2(a: number, b: number): number
	local dx, dy = a % W - b % W, a // W - b // W
	return dx * dx + dy * dy
end

local function manhattan(a: number, b: number): number
	return math.abs(a % W - b % W) + math.abs(a // W - b // W)
end

local function isShore(t: number): boolean
	return bit32.band(buffer.readu8(map.terrain, t), 64) ~= 0
end

-- Water-only BFS from `from` to `goal`. Returns the tile list from `from` to `goal` (inclusive).
local function bfsPath(from: number, goal: number, limit: number): { number }?
	if from == goal then
		return { from }
	end
	if not isWater(goal) then
		return nil
	end
	bfsGen = (bfsGen % 65534) + 1
	if bfsGen == 1 then
		buffer.fill(bfsStamp, 0, 0)
	end
	buffer.writeu16(bfsStamp, from * 2, bfsGen)
	buffer.writei32(bfsParent, from * 4, -1)
	local queue = { from }
	local head = 1
	while head <= #queue do
		local w = queue[head]
		head += 1
		local n = MapUtil.neighbors(map, w, NB)
		for i = 1, n do
			local nt = NB[i]
			if isWater(nt) and buffer.readu16(bfsStamp, nt * 2) ~= bfsGen then
				buffer.writeu16(bfsStamp, nt * 2, bfsGen)
				buffer.writei32(bfsParent, nt * 4, w)
				if nt == goal then
					local rev = {}
					local cur = nt
					while cur ~= -1 do
						rev[#rev + 1] = cur
						cur = buffer.readi32(bfsParent, cur * 4)
					end
					local path = table.create(#rev)
					for j = #rev, 1, -1 do
						path[#path + 1] = rev[j]
					end
					return path
				end
				queue[#queue + 1] = nt
			end
		end
		if #queue > limit then
			break
		end
	end
	return nil
end

local function nearestWater(t: number, r: number): number?
	local cx, cy = t % W, t // W
	local H = map.height
	for rr = 1, r do
		for dy = -rr, rr do
			for dx = -rr, rr do
				if math.max(math.abs(dx), math.abs(dy)) == rr then
					local x, y = cx + dx, cy + dy
					if x >= 0 and x < W and y >= 0 and y < H and isWater(y * W + x) then
						return y * W + x
					end
				end
			end
		end
	end
	return nil
end

-- The water tile a ship sails to for a port (a neighbour of the port tile).
local function portWater(port): number?
	local n = MapUtil.neighbors(map, port.tile, NB)
	for i = 1, n do
		if isWater(NB[i]) then
			return NB[i]
		end
	end
	return nearestWater(port.tile, 3)
end

local function donePorts(p)
	local list = {}
	for s in pairs(p.structs) do
		if s.kind == "Port" and s.done then
			list[#list + 1] = s
		end
	end
	return list
end

local function shipCount(ownerId: number): number
	local n = 0
	for _, s in ships do
		if s.owner == ownerId then
			n += 1
		end
	end
	return n
end

local function boatTile(b): number
	local path = b.path
	return path[math.clamp(math.floor(b.pos), 1, #path)]
end

local function hostile(a: number, b: number): boolean
	return a ~= b and not ctx.isAllied(a, b)
end

local function maxHealth(s): number
	return math.floor(Config.WARSHIP_HEALTH * (100 + s.vet * VET_HEALTH_BONUS) / 100)
end

local function addVeterancy(s, points: number)
	if s.vet >= MAX_VETERANCY then
		return
	end
	s.vetProgress += points
	while s.vetProgress >= VET_LEVEL_POINTS and s.vet < MAX_VETERANCY do
		s.vetProgress -= VET_LEVEL_POINTS
		s.vet += 1
	end
end

local function removeShip(s, killerId: number?)
	if ships[s.id] ~= s then
		return
	end
	ships[s.id] = nil
	local players = ctx.players()
	local p = players[s.owner]
	if killerId and p then
		local k = players[killerId]
		if k and (k.kind ~= "Bot" or p.kind ~= "Bot") then
			ctx.feed(k.name .. " sank a warship of " .. p.name, "attack", killerId)
		end
		ctx.notify(s.owner, "Your Warship was destroyed", "attack")
	end
end

-- Public API
function Warships.init(c)
	ctx = c
	map = c.map
	W, SIZE = map.width, map.size
	bfsStamp = buffer.create(SIZE * 2)
	bfsParent = buffer.create(SIZE * 4)
end

-- Called by GameServer whenever a different map is loaded for the next round.
function Warships.setMap(m)
	map = m
	W, SIZE = map.width, map.size
	bfsStamp = buffer.create(SIZE * 2)
	bfsParent = buffer.create(SIZE * 4)
	bfsGen = 0
end

function Warships.reset()
	ships = {}
	nextShipId = 1
	shells = {}
	doomed = {}
	pendingShots = {}
	lastSentCount = 0
end

function Warships.cost(p): number
	return Config.UNITS.Warship.cost(shipCount(p.id))
end

function Warships.hasPort(p): boolean
	return #donePorts(p) > 0
end

-- Water path from a boat's current tile to the nearest finished port of `ownerId` it can reach
-- (TradeShipExecution: captured ships sail to the captor's closest port). Returns path, port.
function Warships.routeToPort(fromTile: number, ownerId: number): ({ number }?, any)
	local p = ctx.players()[ownerId]
	if not p or not isWater(fromTile) then
		return nil, nil
	end
	local ports = donePorts(p)
	table.sort(ports, function(a, b)
		return manhattan(a.tile, fromTile) < manhattan(b.tile, fromTile)
	end)
	for _, port in ports do
		local goal = portWater(port)
		if goal then
			local path = bfsPath(fromTile, goal, FAR_BFS_LIMIT)
			if path then
				return path, port
			end
		end
	end
	return nil, nil
end

-- Buys a warship next to the player's finished port nearest to `clickTile`.
-- Nation AI helpers (NationWarshipBehavior).
-- Owners whose warships don't heal (Doomsday Clock, set by the Doomsday module).
Warships.noHeal = {} :: { [number]: boolean }

-- Doomsday Clock drain: damage(maxHealth, health) -> health to remove, for each of ownerId's ships.
-- Never sinks a ship (the caller keeps it above the floor).
function Warships.drainOwner(ownerId: number, damage: (number, number) -> number)
	for _, s in ships do
		if s.owner == ownerId and s.health > 0 then
			local d = damage(maxHealth(s), s.health)
			if d > 0 then
				s.health = math.max(1, s.health - d)
			end
		end
	end
end

function Warships.count(ownerId: number): number
	return shipCount(ownerId)
end

function Warships.total(): number
	local n = 0
	for _ in ships do
		n += 1
	end
	return n
end

-- True if one of ownerId's warships is, or patrols, within Manhattan distance r of tile.
function Warships.covering(tile: number, r: number, ownerId: number): boolean
	for _, s in ships do
		if s.owner == ownerId and (manhattan(s.tile, tile) < r or (s.patrol and manhattan(s.patrol, tile) < r)) then
			return true
		end
	end
	return false
end

-- Tile of a hostile warship within reach of p's ports (counterWarshipInfestation), or nil.
function Warships.enemyNear(p): number?
	local ports = donePorts(p)
	for _, s in ships do
		if hostile(p.id, s.owner) then
			for _, port in ports do
				if manhattan(s.tile, port.tile) < 100 / Config.LINEAR_SCALE then
					return s.tile
				end
			end
		end
	end
	return nil
end

-- Sends one of ownerId's warships to patrol near tile (maybeMoveWarship). Returns true if moved.
function Warships.sendAny(p, tile: number): boolean
	for _, s in ships do
		if s.owner == p.id then
			return Warships.move(p, s.id, tile)
		end
	end
	return false
end

function Warships.tryBuy(p, clickTile: number, kind: string): boolean
	if kind ~= "Warship" or not p.alive then
		return false
	end
	local ports = donePorts(p)
	if #ports == 0 then
		return false
	end
	local cost = Warships.cost(p)
	if p.gold < cost then
		return false
	end
	table.sort(ports, function(a, b)
		return dist2(a.tile, clickTile) < dist2(b.tile, clickTile)
	end)
	local spawn
	for _, port in ports do
		spawn = portWater(port)
		if spawn then
			break
		end
	end
	if not spawn then
		return false
	end
	p.gold -= cost
	local s = {
		id = nextShipId,
		owner = p.id,
		tile = spawn,
		health = Config.WARSHIP_HEALTH,
		patrol = spawn,
		path = nil,
		pi = 1,
		acc = 0,
		target = nil,
		lastShot = -math.huge,
		fails = 0,
		state = "patrolling",
		retreatPort = nil,
		lastManual = -math.huge,
		healRemainder = 0,
		vet = 0,
		vetProgress = 0,
		combatUntil = 0,
	}
	nextShipId += 1
	-- A click on water becomes the patrol point if the ship can sail there.
	if isWater(clickTile) and clickTile ~= spawn then
		local path = bfsPath(spawn, clickTile, FAR_BFS_LIMIT)
		if path then
			s.patrol = clickTile
			s.path, s.pi = path, 1
		end
	end
	ships[s.id] = s
	return true
end

local function cancelRetreat(s)
	s.state = "patrolling"
	s.retreatPort = nil
	s.healRemainder = 0
	s.path = nil
end

-- Player order: new patrol point for one of their warships (also cancels a repair retreat and
-- disables auto-retreat for 5 s, WarshipExecution.handleManualPatrolOverride).
function Warships.move(p, unitId: number, tile: number): boolean
	local s = ships[unitId]
	if not s or s.owner ~= p.id or not isWater(tile) then
		return false
	end
	local path = bfsPath(s.tile, tile, FAR_BFS_LIMIT)
	if not path then
		return false
	end
	if s.state ~= "patrolling" then
		cancelRetreat(s)
	end
	s.lastManual = ctx.tick()
	s.patrol = tile
	s.path, s.pi = path, 1
	s.fails = 0
	if s.target and s.target.kind == "trade" then
		s.target = nil
	end
	return true
end

-- Nations: occasionally buy a warship when they have a port and spare gold.
function Warships.aiConsider(p)
	if ctx.rng:NextNumber() > 0.08 then
		return
	end
	local count = shipCount(p.id)
	if count >= 3 or p.tiles < 150 * (count + 1) then
		return
	end
	local ports = donePorts(p)
	if #ports == 0 or p.gold < Warships.cost(p) + 300000 then
		return
	end
	local port = ports[ctx.rng:NextInteger(1, #ports)]
	Warships.tryBuy(p, port.tile, "Warship")
end

-- Nukes delete every warship inside the blast (NukeExecution.detonate).
function Warships.destroyInBlast(tile: number, radius2: number, nukerId: number)
	for _, s in ships do
		if dist2(s.tile, tile) < radius2 then
			removeShip(s, if hostile(nukerId, s.owner) then nukerId else nil)
		end
	end
end

function Warships.snapshot(): buffer
	local count = 0
	for _ in ships do
		count += 1
	end
	local now = ctx.tick()
	local b = buffer.create(count * 16)
	local o = 0
	for _, s in ships do
		buffer.writeu32(b, o, s.id)
		buffer.writeu16(b, o + 4, s.owner)
		buffer.writeu32(b, o + 6, s.tile)
		buffer.writeu16(b, o + 10, math.clamp(math.ceil(s.health), 0, 65535))
		local flags = 0
		if s.combatUntil > now then
			flags += 1
		end
		if s.state ~= "patrolling" then
			flags += 2
		end
		buffer.writeu8(b, o + 12, flags)
		buffer.writeu8(b, o + 13, s.vet)
		buffer.writeu16(b, o + 14, maxHealth(s))
		o += 16
	end
	return b
end

-- Movement
local function randomPatrolTile(s): number?
	local rng = ctx.rng
	local half = math.floor(Config.WARSHIP_PATROL_RANGE / 2)
	local px, py = s.patrol % W, s.patrol // W
	local H = map.height
	for attempt = 1, 40 do
		local r = if attempt > 25 then half * 2 else half
		local x = px + rng:NextInteger(-r, r)
		local y = py + rng:NextInteger(-r, r)
		if x >= 0 and x < W and y >= 0 and y < H then
			local t = y * W + x
			if isWater(t) and (attempt > 30 or not isShore(t)) then
				return t
			end
		end
	end
	return nil
end

-- Moves one tile along the current path. Returns false when there is no path left.
local function stepPath(s): boolean
	local path = s.path
	if not path then
		return false
	end
	if s.pi >= #path then
		s.path = nil
		return false
	end
	s.pi += 1
	s.tile = path[s.pi]
	if s.pi >= #path then
		s.path = nil
	end
	return true
end

local function patrolStep(s)
	if stepPath(s) then
		return
	end
	local goal, limit
	if dist2(s.tile, s.patrol) > Config.WARSHIP_PATROL_RANGE * Config.WARSHIP_PATROL_RANGE then
		goal, limit = s.patrol, FAR_BFS_LIMIT
	else
		goal, limit = randomPatrolTile(s), LOCAL_BFS_LIMIT
	end
	if not goal or goal == s.tile then
		return
	end
	local path = bfsPath(s.tile, goal, limit)
	if path then
		s.fails = 0
		s.path, s.pi = path, 1
		stepPath(s)
	else
		s.fails += 1
		if s.fails > 5 or limit == FAR_BFS_LIMIT then
			-- Patrol point unreachable from here: patrol where we are instead.
			s.patrol = s.tile
			s.fails = 0
		end
	end
end

-- One tile toward a moving goal: greedy over water (bestNeighborToward), else a short BFS path.
local function chaseStep(s, goal: number)
	if s.path and s.chaseGoal and manhattan(s.chaseGoal, goal) <= 3 and stepPath(s) then
		return
	end
	local best, bestD = nil, manhattan(s.tile, goal)
	local n = MapUtil.neighbors(map, s.tile, NB)
	for i = 1, n do
		local nt = NB[i]
		if isWater(nt) then
			local d = manhattan(nt, goal)
			if d < bestD then
				best, bestD = nt, d
			end
		end
	end
	if best then
		s.path = nil
		s.tile = best
		return
	end
	local path = bfsPath(s.tile, goal, LOCAL_BFS_LIMIT)
	if path then
		s.path, s.pi, s.chaseGoal = path, 1, goal
		stepPath(s)
	else
		s.target = nil -- unreachable
	end
end

-- Targets and shells
-- Refs: { kind = "transport" | "trade", boat = b } or { kind = "ship", ship = other }
local function refAlive(ref): boolean
	if ref.kind == "ship" then
		return ships[ref.ship.id] == ref.ship
	end
	return ctx.boats()[ref.boat.id] == ref.boat
end

local function refTile(ref): number
	if ref.kind == "ship" then
		return ref.ship.tile
	end
	return boatTile(ref.boat)
end

local function refOwner(ref): number
	if ref.kind == "ship" then
		return ref.ship.owner
	end
	return ref.boat.owner
end

-- WarshipExecution.findBestTarget: transports first, then warships, then (when allowed) trade
-- ships; nearest wins within a priority.
local function findTarget(s, includeTrade: boolean)
	local r2 = Config.WARSHIP_TARGET_RANGE * Config.WARSHIP_TARGET_RANGE
	local pr2 = Config.WARSHIP_PATROL_RANGE * Config.WARSHIP_PATROL_RANGE
	local now = ctx.tick()
	local hasPort = nil
	local best, bestPri, bestD = nil, math.huge, math.huge
	for _, b in ctx.boats() do
		if hostile(s.owner, b.owner) and not doomed[b] then
			local t = boatTile(b)
			local d = dist2(s.tile, t)
			if d <= r2 then
				local pri
				if b.kind == "transport" then
					pri = 0
				elseif b.kind == "trade" and includeTrade then
					if hasPort == nil then
						hasPort = Warships.hasPort(ctx.players()[s.owner])
					end
					local destOwner = b.to and b.to.owner or 0
					if hasPort and (b.safeUntil or -1) <= now and dist2(s.patrol, t) <= pr2
						and destOwner ~= s.owner and not ctx.isAllied(s.owner, destOwner)
					then
						pri = 2
					end
				end
				if pri and (pri < bestPri or (pri == bestPri and d < bestD)) then
					best, bestPri, bestD = { kind = b.kind, boat = b }, pri, d
				end
			end
		end
	end
	for _, o in ships do
		if hostile(s.owner, o.owner) and o.health > 0 and o.state ~= "docked" then
			local d = dist2(s.tile, o.tile)
			if d <= r2 and (1 < bestPri or (bestPri == 1 and d < bestD)) then
				best, bestPri, bestD = { kind = "ship", ship = o }, 1, d
			end
		end
	end
	return best
end

local function shoot(s, ref)
	local tick = ctx.tick()
	s.combatUntil = tick + COMBAT_FLAG_TICKS
	if tick - s.lastShot <= Config.WARSHIP_SHELL_RATE then
		return
	end
	if ref.kind ~= "transport" then
		s.lastShot = tick -- warships don't need to reload when attacking transport ships
	else
		doomed[ref.boat] = true -- one shell sinks a transport: don't send another
	end
	local to = refTile(ref)
	local flight = math.max(1, math.ceil(math.sqrt(dist2(s.tile, to)) / Config.SHELL_SPEED))
	shells[#shells + 1] = { owner = s.owner, ship = s, ref = ref, x = s.tile % W, y = s.tile // W, deadline = nil }
	pendingShots[#pendingShots + 1] = { s.tile, to, flight, if ref.kind == "ship" then 1 else 2, if ref.kind == "ship" then ref.ship.id else ref.boat.id }
end

local function shellDamage(sh): number
	local roll = ctx.rng:NextInteger(1, 5)
	local mult = (roll - 1) * 25 + 200
	local vet = if ships[sh.ship.id] == sh.ship then sh.ship.vet else 0
	if vet > 0 then
		mult = math.floor(mult * (100 + vet * VET_DAMAGE_BONUS) / 100)
	end
	return math.floor(Config.SHELL_DAMAGE / 250 * mult + 0.5)
end

local function shellHit(sh)
	local ref = sh.ref
	local firing = sh.ship
	local firingAlive = ships[firing.id] == firing
	if ref.kind == "ship" then
		local target = ref.ship
		target.health -= shellDamage(sh)
		if target.health <= 0 then
			removeShip(target, sh.owner)
			if firingAlive then
				firing.vetProgress = 0
				firing.vet = math.min(MAX_VETERANCY, firing.vet + 1)
			end
		end
	elseif ref.kind == "transport" then
		-- Transport ships sink with all troops aboard.
		local b = ref.boat
		local players = ctx.players()
		local victim, killer = players[b.owner], players[sh.owner]
		ctx.removeBoat(b)
		if victim and killer and (victim.kind ~= "Bot" or killer.kind ~= "Bot") then
			ctx.feed(killer.name .. " sank a transport of " .. victim.name, "attack", sh.owner)
		end
		if firingAlive then
			addVeterancy(firing, VET_CAPTURES) -- a transport is worth captureThreshold points
		end
	end
end

-- ShellExecution: homes on the target's current tile at 3 full-size tiles per tick.
local function tickShells()
	local tick = ctx.tick()
	local i = 1
	while i <= #shells do
		local sh = shells[i]
		local ref = sh.ref
		local remove = false
		if not refAlive(ref) or refOwner(ref) == sh.owner or (sh.deadline and tick >= sh.deadline) then
			remove = true
			if ref.kind == "transport" then
				doomed[ref.boat] = nil
			end
		else
			if not sh.deadline and ships[sh.ship.id] ~= sh.ship then
				sh.deadline = tick + SHELL_LIFETIME
			end
			local t = refTile(ref)
			local tx, ty = t % W, t // W
			local dx, dy = tx - sh.x, ty - sh.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d <= Config.SHELL_SPEED then
				remove = true
				if ref.kind == "transport" then
					doomed[ref.boat] = nil
				end
				shellHit(sh)
			else
				sh.x += dx / d * Config.SHELL_SPEED
				sh.y += dy / d * Config.SHELL_SPEED
			end
		end
		if remove then
			table.remove(shells, i)
		else
			i += 1
		end
	end
end

local function capture(s, b)
	local players = ctx.players()
	local captor = players[s.owner]
	if captor and captor.alive and ctx.captureTrade(b, s.owner) then
		addVeterancy(s, VET_TRANSPORTS) -- a capture is worth transportThreshold points
	end
end

-- Repair retreat (WarshipExecution.handleRepairRetreat and helpers)
local function dockedAt(port, exclude): number
	local n = 0
	for _, o in ships do
		if o ~= exclude and o.owner == port.owner and o.state == "docked" and o.retreatPort == port then
			n += 1
		end
	end
	return n
end

local function portFull(port, exclude): boolean
	return dockedAt(port, exclude) >= math.max(1, port.level or 1)
end

local function nearestAvailablePort(s, p)
	local best, bestD = nil, math.huge
	for _, port in donePorts(p) do
		if not portFull(port, s) then
			local d = dist2(s.tile, port.tile)
			if d < bestD then
				best, bestD = port, d
			end
		end
	end
	return best, bestD
end

local function portExists(port, p): boolean
	return port ~= nil and port.owner == p.id and p.structs[port] == true and port.done
end

local function heal(s, p)
	if Warships.noHeal[p.id] then
		return -- Doomsday Clock: a doomed side's ships don't heal (WarshipExecution.healWarship)
	end
	local mh = maxHealth(s)
	local r2 = Config.WARSHIP_HEAL_RANGE * Config.WARSHIP_HEAL_RANGE
	for _, port in donePorts(p) do
		if dist2(port.tile, s.tile) <= r2 then
			s.health = math.min(mh, s.health + Config.WARSHIP_HEAL_PER_TICK)
			break
		end
	end
	if s.state == "docked" and portExists(s.retreatPort, p) then
		local docked = dockedAt(s.retreatPort, nil)
		if docked > 0 then
			s.healRemainder += math.max(1, s.retreatPort.level or 1) * PORT_HEAL_PER_LEVEL / docked
			local whole = math.floor(s.healRemainder)
			if whole > 0 then
				s.healRemainder -= whole
				s.health = math.min(mh, s.health + whole)
			end
		end
	end
end

local function startRetreat(s, p)
	local port = nearestAvailablePort(s, p)
	if not port then
		local ports = donePorts(p)
		port = ports[1]
	end
	if not port then
		return
	end
	s.state = "retreating"
	s.retreatPort = port
	s.path = nil
	s.target = nil
	s.healRemainder = 0
end

-- Returns true when the retreat handled this tick.
local function handleRetreat(s, p): boolean
	if s.state == "patrolling" then
		return false
	end
	-- Fire back at transports / warships while retreating.
	local aggro = findTarget(s, false)
	if aggro then
		shoot(s, aggro)
	end
	-- Keep the retreat port valid, prefer a much closer free one.
	if not portExists(s.retreatPort, p) then
		local port = nearestAvailablePort(s, p)
		if not port then
			cancelRetreat(s)
			return false
		end
		s.retreatPort, s.path = port, nil
	elseif portFull(s.retreatPort, s) and s.state ~= "docked" then
		local alt = nearestAvailablePort(s, p)
		if alt and alt ~= s.retreatPort then
			s.retreatPort, s.path = alt, nil
		end
	else
		local alt, altD = nearestAvailablePort(s, p)
		if alt and alt ~= s.retreatPort and altD < dist2(s.tile, s.retreatPort.tile) * PORT_SWITCH then
			s.retreatPort, s.path = alt, nil
		end
	end
	local port = s.retreatPort
	if dist2(s.tile, port.tile) <= DOCKING_RANGE * DOCKING_RANGE then
		if not portFull(port, s) then
			s.state = "docked"
			s.path = nil
			return true
		end
		-- Port full: wait nearby, leave if already repaired.
		if s.health >= maxHealth(s) then
			cancelRetreat(s)
			return false
		end
		return true
	end
	s.acc += Config.WARSHIP_SPEED
	while s.acc >= 1 do
		s.acc -= 1
		if not stepPath(s) then
			local goal = portWater(port)
			local path = goal and bfsPath(s.tile, goal, FAR_BFS_LIMIT)
			if path then
				s.path, s.pi = path, 1
				stepPath(s)
			else
				local alt = nearestAvailablePort(s, p)
				if alt and alt ~= port then
					s.retreatPort = alt
				else
					cancelRetreat(s)
				end
				break
			end
		end
	end
	return true
end

local function tickShip(s)
	local players = ctx.players()
	local p = players[s.owner]
	if not p or not p.alive then
		removeShip(s, nil)
		return
	end
	if s.health <= 0 then
		removeShip(s, nil)
		return
	end
	local healthBefore = s.health
	heal(s, p)
	local tick = ctx.tick()

	if s.state == "docked" then
		if not portExists(s.retreatPort, p) or s.health >= maxHealth(s) then
			cancelRetreat(s)
		else
			return
		end
	end
	if handleRetreat(s, p) then
		return
	end
	if s.state == "patrolling" and tick - s.lastManual >= MANUAL_MOVE_NO_RETREAT
		and healthBefore < math.floor(maxHealth(s) * RETREAT_PERCENT / 100) and Warships.hasPort(p)
	then
		startRetreat(s, p)
		if handleRetreat(s, p) then
			return
		end
	end

	local ref = findTarget(s, true)
	-- Keep hunting the same trade ship if nothing more important showed up.
	if s.target and s.target.kind == "trade" and refAlive(s.target) and (ref == nil or ref.kind == "trade") then
		ref = s.target
	end
	if ref and ref.kind ~= "trade" then
		s.target = nil
		shoot(s, ref)
	else
		s.target = ref
	end

	local hunting = s.target ~= nil
	if hunting then
		s.combatUntil = tick + COMBAT_FLAG_TICKS
	end
	s.acc += Config.WARSHIP_SPEED * (if hunting then 2 else 1)
	while s.acc >= 1 do
		s.acc -= 1
		if s.target then
			local b = s.target.boat
			if not refAlive(s.target) then
				s.target = nil
			elseif manhattan(s.tile, boatTile(b)) <= 5 / L then
				capture(s, b)
				s.target = nil
				s.path = nil
			else
				chaseStep(s, boatTile(b))
			end
		else
			patrolStep(s)
		end
	end
	-- Captures also happen when the trade ship sails into range on its own.
	if s.target and refAlive(s.target) and manhattan(s.tile, boatTile(s.target.boat)) <= 5 / L then
		capture(s, s.target.boat)
		s.target = nil
		s.path = nil
	end
end

function Warships.tick()
	local tick = ctx.tick()
	-- Trade ships on shoreline water are safe from pirates for a while.
	for _, b in ctx.boats() do
		if b.kind == "trade" then
			local t = boatTile(b)
			if t and isShore(t) then
				b.safeUntil = tick + SAFE_FROM_PIRATES
			end
		end
	end
	for _, s in ships do
		tickShip(s)
	end
	tickShells()
	if #pendingShots > 0 then
		local n = #pendingShots
		local b = buffer.create(n * 15)
		for i, sh in pendingShots do
			local o = (i - 1) * 15
			buffer.writeu32(b, o, sh[1])
			buffer.writeu32(b, o + 4, sh[2])
			buffer.writeu16(b, o + 8, math.min(65535, sh[3]))
			buffer.writeu8(b, o + 10, sh[4])
			buffer.writeu32(b, o + 11, sh[5])
		end
		table.clear(pendingShots)
		ctx.net:FireAllClients("shot", b)
	end
	if tick % 2 == 0 then
		local count = 0
		for _ in ships do
			count += 1
		end
		if count > 0 or lastSentCount > 0 then
			lastSentCount = count
			ctx.net:FireAllClients("units", Warships.snapshot())
		end
	end
end

return Warships
