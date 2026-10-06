--[[
	War Front - nukes in flight, MIRVs, MIRV warheads, SAM launchers and SAM missiles (server).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Rules ported from OpenFront (AGPL-3.0): src/core/execution/NukeExecution.ts, MIRVExecution.ts,
	SAMLauncherExecution.ts (SAMTargetingSystem), SAMMissileExecution.ts, MissileSiloExecution.ts and
	the matching numbers in src/core/configuration/DefaultConfig.ts. Modified version
	re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.Missiles (ModuleScript), used by GameServer.
-- Missiles.init(ctx) / setMap(map) / reset() / tick()
-- Missiles.cost(p, kind) -> gold                 (MIRV: 25M + 15M per MIRV launched this match)
-- Missiles.launch(p, targetTile, kind) -> bool   AtomBomb | HydrogenBomb | MIRV
-- Missiles.siloReady(p) -> (hasSilo, ready)
-- Missiles.samRange(level) -> tiles
-- Scale: our tiles are LINEAR_SCALE (4) full-size tiles per axis, so every OpenFront distance and
-- speed below is divided by 4 (marked "/ L").
-- Network (server -> client):
--   "nuke"       { id, owner, kind, from, to, start, duration, speed, arc = true }  (speed in tiles/s
--                along the Ballistics arc; start = server time the missile starts moving)
--   "nukeEnd"    { id, exploded, tile, radius, silent? }   silent = MIRV carrier separated (no fx)
--   "warheads"   { owner, from, start, list = buffer }  per warhead 12 bytes:
--                u32 id, u32 target tile, u16 wait ticks (from `start`), u16 speed * 64 (tiles/tick)
--   "warheadEnd" buffer, per warhead 9 bytes: u32 id, u32 tile, u8 exploded (1) / intercepted (0)
--   "samMissile" { owner, from, to, start, duration }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))

local Missiles = {}

local L = Config.LINEAR_SCALE
local TARGETABLE_RANGE = 150 / L -- defaultNukeTargetableRange
local MAX_SAM_RANGE = 150 / L -- maxSamRange
local SAM_DETECTION = MAX_SAM_RANGE * 4
local SAM_MISSILE_SPEED = 12 / L -- defaultSamMissileSpeed (tiles per tick)
local SAM_COOLDOWN = 90 -- SAMCooldown (ticks)
local SILO_COOLDOWN = 90 -- SiloCooldown (ticks)

-- MIRVExecution
local MIRV_RANGE = 1500 / L
local MIRV_SPREAD = 55 / L -- minimum Manhattan distance between warhead targets
local MIRV_WARHEADS = 350
local MIRV_BASE_SPEED = 15 -- full-size tiles per tick (nukeSpeed(MIRV))
local MIRV_NORMALIZE_TICKS = 14 -- mirvNormalizeTargetTicks
local WARHEAD_SPEED = 22 / L -- nukeSpeed(MIRVWarhead)
local WARHEAD_INNER, WARHEAD_OUTER = 12 / L, 18 / L -- nukeMagnitudes(MIRVWarhead)

local ctx: any = nil
local map: any = nil
local W, H = 0, 0

local nukes: { [number]: any } = {}
local nextId = 1
local samMissiles: { any } = {}
local mirvsLaunched = 0
local warheadEnds: { number } = {}

function Missiles.samRange(level: number): number
	-- samRange(level) = maxSamRange - 480 / (level + 5): 70 at level 1, toward 150 (full-size)
	return (150 - 480 / (math.max(1, level) + 5)) / L
end

local function tileXY(t: number): (number, number)
	return t % W, t // W
end

local function dist2(a: number, b: number): number
	local ax, ay = a % W, a // W
	local bx, by = b % W, b // W
	return (ax - bx) ^ 2 + (ay - by) ^ 2
end

local function manhattan(a: number, b: number): number
	return math.abs(a % W - b % W) + math.abs(a // W - b // W)
end

local function toTile(x: number, y: number): number
	local tx = math.clamp(math.floor(x), 0, W - 1)
	local ty = math.clamp(math.floor(y), 0, H - 1)
	return ty * W + tx
end

local function levelOf(s): number
	return math.max(1, s.level or 1)
end

local function queueOf(s)
	local q = s.missiles
	if not q then
		q = {}
		s.missiles = q
	end
	return q
end

local function slotFree(s): boolean
	return s.done and #queueOf(s) < levelOf(s)
end

-- Missile slots reload one by one (UnitImpl missileTimerQueue); cooldownUntil is what the
-- structures payload shows as the reload bar (only while every slot is used).
local function reload(s, cd: number, now: number)
	local q = queueOf(s)
	while q[1] and now - q[1] >= cd do
		table.remove(q, 1)
	end
	local want = if #q >= levelOf(s) then q[1] + cd else 0
	if s.cooldownUntil ~= want then
		s.cooldownUntil = want
		ctx.markStructures()
	end
end

local function useSlot(s, cd: number)
	local now = ctx.tick()
	table.insert(queueOf(s), now)
	reload(s, cd, now)
end

local function serverNow(): number
	return SimClock.now()
end

-- Flights
-- Builds the per-tick trajectory (tile at each tick) and SAM-targetable flags of a flight.
local function plan(n, fromTile: number, toTile_: number, speed: number, ignoreBounds: boolean?)
	local fx, fy = tileXY(fromTile)
	local tx, ty = tileXY(toTile_)
	local c = Ballistics.curve(fx + 0.5, fy + 0.5, tx + 0.5, ty + 0.5, H, ignoreBounds)
	local ticks = Ballistics.ticks(c, speed)
	local traj = table.create(ticks + 1, 0)
	local targetable = table.create(ticks + 1, false)
	local r2 = TARGETABLE_RANGE * TARGETABLE_RANGE
	for i = 0, ticks do
		local x, y = Ballistics.at(c, i * speed)
		local t = if i == ticks then toTile_ else toTile(x, y)
		traj[i + 1] = t
		targetable[i + 1] = dist2(t, toTile_) < r2 or dist2(fromTile, t) < r2
	end
	n.from, n.to, n.speed, n.ticks, n.traj, n.targetable, n.curve = fromTile, toTile_, speed, ticks, traj, targetable, c
end

local function curIndex(n, now: number): number
	return math.clamp(now - n.start, 0, n.ticks)
end

local function curTile(n, now: number): number
	return n.traj[curIndex(n, now) + 1]
end

local function nearestSilo(p, target: number)
	local best, bestD = nil, math.huge
	for s in pairs(p.structs) do
		if s.kind == "MissileSilo" and slotFree(s) then
			local d = dist2(s.tile, target)
			if d < bestD then
				best, bestD = s, d
			end
		end
	end
	return best
end

function Missiles.siloReady(p): (boolean, boolean)
	local has, ready = false, false
	for s in pairs(p.structs) do
		if s.kind == "MissileSilo" and s.done then
			has = true
			if slotFree(s) then
				ready = true
			end
		end
	end
	return has, ready
end

function Missiles.cost(p, kind: string): number
	local def = Config.NUKES[kind]
	if not def then
		return math.huge
	end
	if def.costStep then
		return def.cost + def.costStep * mirvsLaunched
	end
	return def.cost
end

local INBOUND = {
	AtomBomb = "%s - atom bomb inbound",
	HydrogenBomb = "%s - hydrogen bomb inbound",
}

local function announce(n, kind: string)
	ctx.net:FireAllClients("nuke", {
		id = n.id,
		owner = n.owner,
		kind = kind,
		from = n.from,
		to = n.to,
		start = serverNow() + (n.start - ctx.tick()) * Config.TICK,
		duration = n.ticks * Config.TICK,
		speed = n.speed / Config.TICK,
		arc = true,
	})
end

-- OpenFront MIRVExecution.calculateDeterministicSpeed: flight time normalised toward 14 ticks
-- (sqrt heuristic), lengths measured in full-size tiles.
local function mirvSpeed(fromTile: number, sepTile: number): number
	local fx, fy = tileXY(fromTile)
	local sx, sy = tileXY(sepTile)
	local ideal = Ballistics.curve(fx * L, fy * L, sx * L, sy * L, H * L, true)
	local actual = Ballistics.curve(fx + 0.5, fy + 0.5, sx + 0.5, sy + 0.5, H, false)
	local SCALE = 100
	local baseScaled = MIRV_NORMALIZE_TICKS * SCALE
	local idealInt = math.floor(Ballistics.length(ideal) / MIRV_BASE_SPEED * SCALE)
	local target = baseScaled
	if idealInt > baseScaled then
		local diff = idealInt - baseScaled
		target = baseScaled + math.floor(math.sqrt(diff)) * 14 + math.floor(diff * 10 / 100)
	elseif idealInt < baseScaled then
		local diff = baseScaled - idealInt
		target = baseScaled - math.floor(math.sqrt(diff)) * 10
	end
	target = math.max(SCALE, target)
	return math.max(0.05, Ballistics.length(actual) * SCALE / target)
end

-- True while a MIRV from attackerId aimed at victimId is in flight (NationMIRVBehavior).
function Missiles.inboundMirv(attackerId: number, victimId: number): boolean
	for _, n in nukes do
		if n.mirv and n.owner == attackerId and n.victim == victimId then
			return true
		end
	end
	return false
end

function Missiles.launch(p, target: number, kind: string): boolean
	local def = Config.NUKES[kind]
	if not def or not p.alive or target < 0 or target >= W * H then
		return false
	end
	-- Impassable terrain cannot be nuked (PlayerImpl.nukeSpawn).
	if MapUtil.isLand(map, target) and not MapUtil.isOwnable(map, target) then
		return false
	end
	local victimId = ctx.getOwner(target)
	if def.mirv and (victimId == 0 or victimId == p.id) then
		return false -- "only targets selected player"
	end
	local cost = Missiles.cost(p, kind)
	if p.gold < cost then
		return false
	end
	local silo = nearestSilo(p, target)
	if not silo then
		return false
	end
	p.gold -= cost
	useSlot(silo, SILO_COOLDOWN)
	local now = ctx.tick()
	local id = nextId
	nextId += 1
	local n = { id = id, owner = p.id, kind = kind, start = now + 1, victim = victimId }
	local players = ctx.players()
	local victim = players[victimId]
	if def.mirv then
		mirvsLaunched += 1
		-- Betrayal on launch: the alliance with the target player ends.
		if victim and ctx.allied(p.id, victimId) then
			ctx.breakAlliance(p, victim)
		end
		local bx, by = tileXY(target)
		local sx, sy = tileXY(silo.tile)
		local sep = toTile(math.floor((bx + sx) / 2), math.max(0, by - 500 / L) + 50 / L)
		n.mirv = true
		n.baseX, n.baseY = bx, by
		n.dst = target
		n.targets = { target }
		n.spawned = false
		plan(n, silo.tile, sep, mirvSpeed(silo.tile, sep), false)
		for i = 1, #n.targetable do
			n.targetable[i] = false -- the MIRV carrier itself can't be intercepted
		end
		nukes[id] = n
		announce(n, kind)
		if victim then
			ctx.notify(victimId, string.format("⚠️⚠️⚠️ %s - MIRV INBOUND ⚠️⚠️⚠️", p.name), "nuke")
		end
	else
		ctx.breakAlliancesForNuke(p, target, def.outer)
		n.inner, n.outer = def.inner, def.outer
		plan(n, silo.tile, target, def.speed, false)
		nukes[id] = n
		announce(n, kind)
		if victim and INBOUND[kind] then
			ctx.notify(victimId, string.format(INBOUND[kind], p.name), "nuke")
		end
	end
	return true
end

-- MIRV warheads
local function overlapping(grid, x: number, y: number): boolean
	local cs = math.ceil(MIRV_SPREAD)
	local cx, cy = x // cs, y // cs
	for gy = cy - 1, cy + 1 do
		for gx = cx - 1, cx + 1 do
			local cell = grid[gy * 65536 + gx]
			if cell then
				for _, e in cell do
					if math.abs(e[1] - x) + math.abs(e[2] - y) < MIRV_SPREAD then
						return true
					end
				end
			end
		end
	end
	return false
end

local function gridAdd(grid, x: number, y: number)
	local cs = math.ceil(MIRV_SPREAD)
	local key = (y // cs) * 65536 + x // cs
	local cell = grid[key]
	if not cell then
		cell = {}
		grid[key] = cell
	end
	cell[#cell + 1] = { x, y }
end

local function rebuildGrid(n)
	n.grid = {}
	for _, t in n.targets do
		local x, y = tileXY(t)
		gridAdd(n.grid, x, y)
	end
end

local function tryTarget(n): number?
	local rng = ctx.rng
	for _ = 1, 100 do
		local x = math.floor(rng:NextNumber() * MIRV_RANGE * 2 - MIRV_RANGE + n.baseX + 0.5)
		local y = math.floor(rng:NextNumber() * MIRV_RANGE * 2 - MIRV_RANGE + n.baseY + 0.5)
		if x >= 0 and x < W and y >= 0 and y < H then
			local t = y * W + x
			if MapUtil.isLand(map, t)
				and (x - n.baseX) ^ 2 + (y - n.baseY) ^ 2 <= MIRV_RANGE * MIRV_RANGE
				and ctx.getOwner(t) == n.victim
				and not overlapping(n.grid, x, y)
			then
				return t
			end
		end
	end
	return nil
end

local function stage(n, attempts: number)
	if not n.grid then
		rebuildGrid(n)
	end
	for _ = 1, attempts do
		if #n.targets >= MIRV_WARHEADS then
			break
		end
		local t = tryTarget(n)
		if t then
			n.targets[#n.targets + 1] = t
			local x, y = tileXY(t)
			gridAdd(n.grid, x, y)
		end
	end
end

local function spawnWarheads(n, remaining: number)
	-- Re-check ownership, top up, sort far-to-near (MIRVExecution.finalizeDestinations).
	local kept = {}
	for _, t in n.targets do
		if t == n.dst or ctx.getOwner(t) == n.victim then
			kept[#kept + 1] = t
		end
	end
	n.targets = kept
	rebuildGrid(n)
	stage(n, 500 + (10 - remaining) * 50)
	table.sort(n.targets, function(a, b)
		return manhattan(a, n.dst) > manhattan(b, n.dst)
	end)
	local now = ctx.tick()
	local waitBase = math.max(0, remaining)
	local buf = buffer.create(#n.targets * 12)
	for i, t in n.targets do
		local offset = if i <= 70 then 0 elseif i <= 140 then 1 elseif i <= 210 then 2 elseif i <= 280 then 3 else 4
		local wait = waitBase + ctx.rng:NextInteger(0, 14)
		local id = nextId
		nextId += 1
		local w = { id = id, owner = n.owner, kind = "MIRVWarhead", warhead = true, start = now + 1 + wait, inner = WARHEAD_INNER, outer = WARHEAD_OUTER }
		plan(w, n.to, t, WARHEAD_SPEED + offset / L, false)
		nukes[id] = w
		local o = (i - 1) * 12
		buffer.writeu32(buf, o, id)
		buffer.writeu32(buf, o + 4, t)
		buffer.writeu16(buf, o + 8, math.min(65535, 1 + wait))
		buffer.writeu16(buf, o + 10, math.min(65535, math.floor(w.speed * 64 + 0.5)))
	end
	ctx.net:FireAllClients("warheads", { owner = n.owner, from = n.to, start = serverNow(), list = buf })
end

-- SAM launchers (SAMTargetingSystem)
local function samTicks(samTile: number, t: number): number
	return math.ceil(manhattan(samTile, t) / SAM_MISSILE_SPEED)
end

-- Absolute tick at which this SAM should fire at nuke n (and the interception tile), or
-- -1 (unreachable at this level) / -2 (never reachable).
local function interception(s, n, now: number): (number, number?)
	local samTile = s.tile
	local range = Missiles.samRange(levelOf(s))
	local r2 = range * range
	local max2 = MAX_SAM_RANGE * MAX_SAM_RANGE
	local ci = curIndex(n, now)
	local wait = math.max(0, n.start - now)
	local last = n.ticks -- index of the final tile
	local maxIdx = last - 1
	local minD, closest = math.huge, samTile
	local inc, lastD = 0, -1
	for i = ci, maxIdx do
		local t = n.traj[i + 1]
		local d2 = dist2(samTile, t)
		if d2 < minD then
			minD, closest = d2, t
		end
		inc = if lastD ~= -1 and d2 > lastD then inc + 1 else 0
		lastD = d2
		local nukeTicks = i - ci + wait
		local st = samTicks(samTile, t)
		if n.targetable[i + 1] and d2 <= r2 and nukeTicks >= st then
			return now + nukeTicks - st, t
		end
		if inc > 3 and d2 > max2 then
			break
		end
	end
	-- Interception right before detonation.
	if maxIdx >= 0 and n.targetable[last + 1] and dist2(samTile, n.traj[last + 1]) <= r2 and n.targetable[maxIdx + 1] then
		local t = n.traj[maxIdx + 1]
		local before = (maxIdx - ci + wait) - samTicks(samTile, t)
		if before >= 0 then
			return now + before, t
		end
	end
	return if minD > max2 then -2 else -1, closest
end

local function targetScore(s, n, now: number): number
	local timeToExplode = math.max(1, n.ticks - curIndex(n, now))
	local typeBonus = if n.kind == "HydrogenBomb" then 70001 else 0
	local distanceBonus = math.max(0, 200000 - manhattan(s.tile, n.to) * L * 1000)
	local urgency = math.max(0, 10000 - timeToExplode * 100)
	return typeBonus + distanceBonus + urgency
end

local function fireSam(s, n, tile: number, now: number)
	useSlot(s, SAM_COOLDOWN)
	n.targeted = true
	local flight = math.max(1, samTicks(s.tile, tile))
	local m = { owner = s.owner, sam = s, nuke = n, tile = tile, arrive = now + flight }
	samMissiles[#samMissiles + 1] = m
	ctx.net:FireAllClients("samMissile", {
		owner = s.owner,
		from = s.tile,
		to = tile,
		start = serverNow(),
		duration = flight * Config.TICK,
	})
end

local function tickSam(s, now: number, structures)
	reload(s, SAM_COOLDOWN, now)
	local cache = s.samCache
	if not cache then
		cache = {}
		s.samCache = cache
	end
	if s.samLevelSeen ~= levelOf(s) then
		s.samLevelSeen = levelOf(s)
		for id, v in cache do
			if v == -1 then
				cache[id] = nil
			end
		end
	end
	for id in cache do
		if not nukes[math.abs(id)] then
			cache[id] = nil
		end
	end
	if not slotFree(s) then
		return
	end
	local targets = nil
	local det2 = SAM_DETECTION * SAM_DETECTION
	for id, n in nukes do
		if n.mirv or n.targeted or n.owner == s.owner or ctx.allied(s.owner, n.owner) then
			continue
		end
		if dist2(s.tile, curTile(n, now)) > det2 then
			continue
		end
		local when = cache[id]
		local tile = nil
		if when == nil or (when >= 0 and when < now) then
			when, tile = interception(s, n, now)
			cache[id] = when
			cache[-id] = tile
		else
			tile = cache[-id]
		end
		if when >= 0 and when <= now + 1 and tile then
			targets = targets or {}
			targets[#targets + 1] = { n = n, tile = tile, score = targetScore(s, n, now) }
			cache[id] = nil
			cache[-id] = nil
		end
	end
	if targets then
		table.sort(targets, function(a, b)
			return a.score > b.score
		end)
		for _, tg in targets do
			if not slotFree(s) then
				break
			end
			fireSam(s, tg.n, tg.tile, now)
		end
	end
end

-- Tick
local UNIT_NAMES = { AtomBomb = "Atom Bomb", HydrogenBomb = "Hydrogen Bomb", MIRVWarhead = "MIRV" }

local function finish(n, exploded: boolean, tile: number)
	nukes[n.id] = nil
	if n.warhead then
		local o = #warheadEnds
		warheadEnds[o + 1] = n.id
		warheadEnds[o + 2] = tile
		warheadEnds[o + 3] = if exploded then 1 else 0
	else
		ctx.net:FireAllClients("nukeEnd", { id = n.id, exploded = exploded, tile = tile, radius = if exploded then n.outer else 2 })
	end
end

local function tickMissiles(now: number)
	local i = 1
	while i <= #samMissiles do
		local m = samMissiles[i]
		local n = m.nuke
		local alive = nukes[n.id] == n
		local samAlive = ctx.structures()[m.sam.id] == m.sam
		if not alive or not samAlive or ctx.allied(m.owner, n.owner) then
			if alive then
				n.targeted = false -- another SAM may retarget it
				n.held = false -- a nuke held at its target detonates next tick
			end
			table.remove(samMissiles, i)
		elseif now >= m.arrive then
			table.remove(samMissiles, i)
			finish(n, false, curTile(n, now))
			ctx.notify(m.owner, string.format("SAM intercepted %s", UNIT_NAMES[n.kind] or n.kind), "sam")
		else
			i += 1
		end
	end
end

local function pendingInterception(n, now: number): boolean
	for _, m in samMissiles do
		if m.nuke == n and m.arrive <= now + 1 then
			return true
		end
	end
	return false
end

function Missiles.tick()
	local now = ctx.tick()
	local structures = ctx.structures()
	for _, s in structures do
		if s.kind == "MissileSilo" then
			reload(s, SILO_COOLDOWN, now)
		end
	end
	for _, s in structures do
		if s.kind == "SAM" and s.done and s.owner ~= 0 then
			tickSam(s, now, structures)
		end
	end
	tickMissiles(now)
	for id, n in nukes do
		if not ctx.players()[n.owner] then
			nukes[id] = nil
			continue
		end
		local remaining = n.ticks - (now - n.start)
		if n.mirv then
			if remaining <= 20 and remaining > 10 then
				stage(n, 100)
			end
			if remaining <= 10 and not n.spawned then
				n.spawned = true
				spawnWarheads(n, remaining)
			end
			if remaining <= 0 then
				nukes[id] = nil
				ctx.net:FireAllClients("nukeEnd", { id = id, exploded = false, tile = n.to, radius = 0, silent = true })
			end
		elseif remaining <= 0 and not n.held then
			if n.targeted and pendingInterception(n, now) then
				n.held = true -- the SAM missile about to hit decides (NukeExecution)
			else
				nukes[id] = nil
				ctx.detonate(n)
				finish(n, true, n.to)
			end
		end
	end
	if #warheadEnds > 0 then
		local count = #warheadEnds // 3
		local b = buffer.create(count * 9)
		for k = 0, count - 1 do
			buffer.writeu32(b, k * 9, warheadEnds[k * 3 + 1])
			buffer.writeu32(b, k * 9 + 4, warheadEnds[k * 3 + 2])
			buffer.writeu8(b, k * 9 + 8, warheadEnds[k * 3 + 3])
		end
		table.clear(warheadEnds)
		ctx.net:FireAllClients("warheadEnd", b)
	end
end

function Missiles.init(c)
	ctx = c
	Missiles.setMap(c.map)
end

function Missiles.setMap(m)
	map = m
	W, H = m.width, m.height
end

function Missiles.reset()
	nukes = {}
	nextId = 1
	samMissiles = {}
	mirvsLaunched = 0
	warheadEnds = {}
end

return Missiles
