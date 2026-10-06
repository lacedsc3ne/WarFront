--[[
	War Front - nation AI for structures, warships and MIRVs.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(src/core/execution/nation/NationStructureBehavior.ts, NationWarshipBehavior.ts,
	NationMIRVBehavior.ts). Modified version re-implemented in Luau for Roblox; not affiliated with
	or endorsed by OpenFront.
]]

-- ServerScriptService.NationBuild (ModuleScript), used by GameServer through AiBehavior.
--
-- NationBuild.init(ctx)
-- NationBuild.structures(p)  NationStructureBehavior.handleStructures (attack tick + 1/3 + 2/3)
-- NationBuild.warships(p)    maybeSpawnWarship + retaliation + counterWarshipInfestation
-- NationBuild.mirv(p)        NationMIRVBehavior.considerMIRV
-- NationBuild.reset()
--
-- Scale: distances from OpenFront are divided by Config.LINEAR_SCALE (marked "/ L"), tile counts
-- by Config.AREA_SCALE (marked "/ A").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))

local NationBuild = {}

local L = Config.LINEAR_SCALE
local A = Config.AREA_SCALE

local ctx: any = nil
local rng = Random.new()

local SAM_RATIO = { Easy = 0.15, Medium = 0.2, Hard = 0.25, Impossible = 0.3 }
local RATIOS = {
	Port = { ratio = 0.75, perceived = 1 },
	Factory = { ratio = 0.75, perceived = 1 },
	SAM = { ratio = 0.2, perceived = 0.3 }, -- ratio replaced by SAM_RATIO[difficulty]
	MissileSilo = { ratio = 0.2, perceived = 1 },
}
local CITY_PERCEIVED = 1
local CITIES_BEFORE_SAVING = 3
local FACTORY_COASTAL_MULT = 0.33
local MAX_SILOS = 3
local FIRST_SILO_RATIO = 0.4
local UPGRADE_DENSITY = 1 / (1500 / A) -- structures per tile above which nations upgrade
local HIGH_NATION_DENSITY = 1 / (7500 / A)
local POST_SAVE_PHASE = 150 -- ticks
local UNDER_ATTACK_RATIO = 0.35
local POST_RATIO_PER_POST = 0.4
local BUILD_ORDER = { "Port", "Factory", "SAM", "MissileSilo" }

local MIRV_COOLDOWN = 300
local MIRV_HESITATION = { Easy = 2, Medium = 4, Hard = 8, Impossible = 16 }
local MIRV_VICTORY_PCT = { Easy = 75, Medium = 65, Hard = 55, Impossible = 40 }
local MIRV_GAP_MULT = { Easy = 2, Medium = 1.5, Hard = 1.25, Impossible = 1.15 }
local MIRV_MIN_CITIES = { Easy = 20, Medium = 10, Hard = 10, Impossible = 8 }
local mirvTargets: { [number]: number } = {} -- game.nationMirvTargets(): victim id -> tick

local function difficulty(): string
	return Config.NATION_DIFFICULTY or "Medium"
end

local function chance(n: number): boolean
	return rng:NextInteger(1, n) == 1
end

local function W(): number
	return ctx.map().width
end

local function manhattan(a: number, b: number): number
	local w = W()
	return math.abs(a % w - b % w) + math.abs(a // w - b // w)
end

local function dist2(a: number, b: number): number
	local w = W()
	local dx, dy = a % w - b % w, a // w - b // w
	return dx * dx + dy * dy
end

local function stateOf(p)
	local st = p.nb
	if not st then
		st = { placements = 0, lastTick = nil, postSaveStart = nil, crowdedFirst = false, trade = {}, dealt = {} }
		p.nb = st
	end
	return st
end

-- unitsOwned: levels of finished structures, 1 per site under construction.
local function owned(p, kind: string): number
	local n = 0
	for s in pairs(p.structs) do
		if s.kind == kind then
			n += if s.done then (s.level or 1) else 1
		end
	end
	return n
end

local function listOf(p, kind: string)
	local out = {}
	for s in pairs(p.structs) do
		if s.kind == kind then
			out[#out + 1] = s
		end
	end
	return out
end

local function structureCount(p): number
	local n = 0
	for _ in pairs(p.structs) do
		n += 1
	end
	return n
end

local function cost(p, kind: string): number
	return ctx.cost(p, kind)
end

local function nukeCost(p, kind: string): number
	return ctx.nukeCost(p, kind)
end

-- Gold the nation saves up for (getSaveUpTarget, FFA with MIRVs enabled).
local function saveUpTarget(p): number
	return nukeCost(p, "MIRV") + nukeCost(p, "HydrogenBomb")
end

local function perceivedCost(p, kind: string): number
	local real = cost(p, kind)
	local target = saveUpTarget(p)
	if target == 0 or p.gold >= target then
		return real
	end
	if owned(p, "City") < CITIES_BEFORE_SAVING and difficulty() ~= "Easy" then
		return real
	end
	local inc = if kind == "City" then CITY_PERCEIVED else (RATIOS[kind] and RATIOS[kind].perceived or 0.1)
	return math.ceil(real * (1 + inc * owned(p, kind)))
end

local function spacing(): (number, number)
	local border = Config.NUKES.AtomBomb.outer -- nukeMagnitudes(AtomBomb).outer, already / L
	return border, border * 2
end

-- Distance to the nearest tile we don't own, searched in rings up to `cap`.
local function borderDist(p, t: number, cap: number): number
	local map = ctx.map()
	local w, h = map.width, map.height
	local cx, cy = t % w, t // w
	local r = math.ceil(cap)
	for d = 1, r do
		for dx = -d, d do
			local dyAbs = d - math.abs(dx)
			for _, dy in { dyAbs, -dyAbs } do
				local x, y = cx + dx, cy + dy
				if x < 0 or y < 0 or x >= w or y >= h then
					return d
				end
				local tt = y * w + x
				if ctx.getOwner(tt) ~= p.id and not ctx.isWater(tt) then
					return d
				end
				if dyAbs == 0 then
					break
				end
			end
		end
	end
	return cap
end

local function nearestOf(tiles, t: number): number
	local best = math.huge
	for _, o in tiles do
		if o ~= t then
			local d = manhattan(o, t)
			if d < best then
				best = d
			end
		end
	end
	return best
end

local function tilesOf(list)
	local out = {}
	for i, s in list do
		out[i] = s.tile
	end
	return out
end

local function isShore(t: number): boolean
	local map = ctx.map()
	return MapUtil.isLand(map, t) and bit32.band(buffer.readu8(map.terrain, t), 0x40) ~= 0
end

local function hasCoast(p): boolean
	for _ = 1, 40 do
		local t = ctx.randomOwnedTile(p)
		if t and isShore(t) then
			return true
		end
	end
	return false
end

-- Value functions (structureSpawnTileValue) ----------------------------------------
local function valueFn(p, kind: string)
	local borderSpacing, structureSpacing = spacing()
	local map = ctx.map()
	local same = tilesOf(listOf(p, kind))
	if kind == "Port" then
		return function(t)
			local d = nearestOf(same, t)
			return if d == math.huge then 1 else d
		end
	end
	local factories = if kind == "City" then tilesOf(listOf(p, "Factory")) else nil
	local protect
	if kind == "SAM" then
		protect = {}
		local byLevel = difficulty() == "Hard" or difficulty() == "Impossible"
		for s in pairs(p.structs) do
			if s.kind == "City" or s.kind == "Factory" or s.kind == "MissileSilo" or s.kind == "Port" then
				protect[#protect + 1] = { tile = s.tile, weight = if byLevel then (s.level or 1) else 1 }
			end
		end
	end
	local samRange = ctx.samRange(1)
	return function(t)
		local w = MapUtil.magnitude(map, t)
		w += math.min(borderDist(p, t, borderSpacing), borderSpacing)
		local d = nearestOf(same, t)
		if d ~= math.huge then
			w += math.min(d, structureSpacing)
		end
		if factories then
			local d2 = nearestOf(factories, t)
			if d2 ~= math.huge then
				w += math.min(d2, structureSpacing)
			end
		end
		if protect and difficulty() ~= "Easy" then
			for _, e in protect do
				if dist2(t, e.tile) <= samRange * samRange then
					w += structureSpacing * e.weight
				end
			end
		end
		return w
	end
end

local function spawnTile(p, kind: string): number?
	local value = valueFn(p, kind)
	local best, bestValue = nil, 0
	for _ = 1, 25 do
		local t = ctx.randomOwnedTile(p)
		if t then
			local spot = ctx.spawnTile(p, t, kind)
			if spot then
				local v = value(spot)
				if best == nil or v > bestValue then
					best, bestValue = spot, v
				end
			end
		end
	end
	return best
end

-- Upgrades (maybeUpgradeStructure / findBestStructureToUpgrade) ------------------------
local RANDOM_UPGRADE = { Easy = 70, Medium = 40, Hard = 25, Impossible = 10 }

local function density(p): number
	return if p.tiles > 0 then structureCount(p) / p.tiles else 0
end

local function bestToUpgrade(p, list)
	local ok = {}
	for _, s in list do
		if ctx.canUpgrade(p, s) then
			ok[#ok + 1] = s
		end
	end
	if #ok == 0 then
		return nil
	end
	if rng:NextInteger(0, 99) < (RANDOM_UPGRADE[difficulty()] or 40) then
		return ok[rng:NextInteger(1, #ok)]
	end
	local sams = listOf(p, "SAM")
	local scored = {}
	for _, s in ok do
		local score = 0
		for _, sam in sams do
			local r = ctx.samRange(sam.level or 1)
			if dist2(s.tile, sam.tile) <= r * r then
				score += 10 + math.max(0, (sam.level or 1) - 1) * 7.5
			end
		end
		scored[#scored + 1] = { s = s, score = score + rng:NextInteger(0, 4) }
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)
	if #scored >= 2 and chance(2) then
		return scored[if #scored >= 3 then rng:NextInteger(2, 3) else 2].s
	end
	return scored[1].s
end

local function maybeSpawn(p, kind: string): boolean
	if p.gold < perceivedCost(p, kind) then
		return false
	end
	local def = Config.STRUCTURES[kind]
	if density(p) > UPGRADE_DENSITY and def and def.upgradable then
		local list = listOf(p, kind)
		local s = bestToUpgrade(p, list)
		if s and ctx.upgrade(p, s) > 0 then
			return true
		end
		if #list > 0 then
			return false -- wait for construction instead of crowding the land
		end
	end
	local t = spawnTile(p, kind)
	if not t then
		return false
	end
	return ctx.tryBuild(p, t, kind)
end

local function shouldBuild(p, kind: string, cities: number, coastal: boolean): boolean
	local cfg = RATIOS[kind]
	if not cfg or MatchRules.unitDisabled(kind) then
		return false -- disabledUnits (Nukes / SAMs Disabled)
	end
	local ratio = if kind == "SAM" then (SAM_RATIO[difficulty()] or 0.2) else cfg.ratio
	if kind == "Factory" and coastal then
		ratio *= FACTORY_COASTAL_MULT
	end
	local have = owned(p, kind)
	if kind == "MissileSilo" then
		if have >= MAX_SILOS then
			return false
		end
		if have == 0 then
			ratio = FIRST_SILO_RATIO
		end
	end
	return have < math.floor(cities * ratio)
end

-- Defense posts near land-attack fronts (tryBuildDefensePost) --------------------------
local function incomingLand(p)
	local list, troops = {}, 0
	for _, a in ctx.attacks() do
		if a.target == p.id and a.attacker and a.attacker.alive then
			list[#list + 1] = a
			troops += a.troops
		end
	end
	return list, troops
end

local function defenseNeeded(p): boolean
	if difficulty() == "Easy" or p.troops <= 0 then
		return false
	end
	local _, troops = incomingLand(p)
	return troops / p.troops >= UNDER_ATTACK_RATIO
end

local function tryDefensePost(p): boolean
	local d = difficulty()
	if d == "Easy" or (d == "Medium" and not chance(2)) or p.troops <= 0 then
		return false
	end
	local list, troops = incomingLand(p)
	if #list == 0 then
		return false
	end
	local ratio = troops / p.troops
	if ratio < UNDER_ATTACK_RATIO then
		return false
	end
	local allowed = if d == "Medium" then 1 else math.ceil(ratio / POST_RATIO_PER_POST)
	-- Front tiles: our tiles bordering the attackers.
	local front = {}
	for _, a in list do
		for _ = 1, 8 do
			local t = ctx.randomBorderTileFacing(p, a.attacker.id)
			if t then
				front[#front + 1] = t
			end
		end
	end
	if #front == 0 then
		return false
	end
	local near = 0
	local radius = 30 / L
	for s in pairs(p.structs) do
		if s.kind == "DefensePost" and nearestOf(front, s.tile) <= radius then
			near += 1
		end
	end
	if near >= allowed or p.gold < cost(p, "DefensePost") then
		return false
	end
	for _ = 1, 25 do
		local f = front[rng:NextInteger(1, #front)]
		local w = W()
		local x = f % w + rng:NextInteger(-3, 3)
		local y = f // w + rng:NextInteger(-3, 3)
		local t = y * w + x
		if x >= 0 and y >= 0 and x < w and y < ctx.map().height and ctx.getOwner(t) == p.id then
			if ctx.tryBuild(p, t, "DefensePost") then
				return true
			end
		end
	end
	return false
end

local function doStructures(p): boolean
	local st = stateOf(p)
	local cities = owned(p, "City")
	local coastal = hasCoast(p)
	-- Crowded maps: the first structure is a port (or a factory when landlocked).
	if not st.crowdedFirst and (#ctx.nations() / math.max(1, ctx.landTiles())) > HIGH_NATION_DENSITY then
		if maybeSpawn(p, if coastal then "Port" else "Factory") then
			st.crowdedFirst = true
			return true
		end
	end
	for _, kind in BUILD_ORDER do
		if not (kind == "Port" and not coastal) and shouldBuild(p, kind, cities, coastal) then
			if maybeSpawn(p, kind) then
				return true
			end
		end
	end
	return maybeSpawn(p, "City")
end

function NationBuild.structures(p)
	if not p.alive or p.kind ~= "Nation" then
		return
	end
	local st = stateOf(p)
	if st.placements > 0 then
		if tryDefensePost(p) then
			return
		end
		if defenseNeeded(p) then
			return
		end
	end
	-- isInPostSaveUpBlockedPhase: 15 s on / 15 s off once the save-up target is reached.
	local now = ctx.tick()
	if st.postSaveStart == nil and p.gold >= saveUpTarget(p) then
		st.postSaveStart = now
	end
	if st.postSaveStart and (now - st.postSaveStart) % (POST_SAVE_PHASE * 2) >= POST_SAVE_PHASE then
		return
	end
	if doStructures(p) then
		st.lastTick = now
		st.placements += 1
	end
end

-- Warships (NationWarshipBehavior) ------------------------------------------------------
local RETALIATE = { Easy = 0, Medium = 15, Hard = 50, Impossible = 80 }

local function retaliate(p, tile: number, enemyId: number, reason: string)
	if enemyId == p.id or enemyId == 0 then
		return
	end
	if ctx.warshipCovering(tile, 90 / L, p.id) then
		return
	end
	if ctx.warshipCount(p.id) >= 10 then
		ctx.warshipSend(p, tile)
		return
	end
	if rng:NextInteger(0, 99) < (RETALIATE[difficulty()] or 0) then
		if not ctx.buyWarship(p, tile) then
			ctx.warshipSend(p, tile)
			return
		end
		ctx.updateRelation(p, enemyId, if reason == "trade" then -7.5 else -15)
	end
end

function NationBuild.warships(p)
	if not p.alive or p.kind ~= "Nation" then
		return
	end
	local st = stateOf(p)
	-- maybeSpawnWarship: 1 in 50, only while we have none.
	if chance(50) and ctx.warshipCount(p.id) == 0 and ctx.hasPort(p) and p.gold > ctx.warshipCost(p) then
		local port = listOf(p, "Port")
		if #port > 0 then
			ctx.buyWarship(p, port[rng:NextInteger(1, #port)].tile)
		end
	end
	-- Trade ships we owned that now belong to someone else were captured.
	for id, b in st.trade do
		if not ctx.boatAlive(b) then
			st.trade[id] = nil
		elseif b.owner ~= p.id then
			st.trade[id] = nil
			retaliate(p, ctx.boatTile(b), b.owner, "trade")
		end
	end
	for _, b in ctx.boats() do
		if b.kind == "trade" and b.owner == p.id then
			st.trade[b.id] = b
		end
	end
	-- Incoming hostile transports far from their target: send a warship to meet them.
	for id, b in ctx.boats() do
		if b.kind == "transport" and b.owner ~= p.id and not b.retreating and not st.dealt[id] then
			local target = b.path[#b.path]
			if target and ctx.getOwner(target) == p.id and not ctx.allied(p.id, b.owner) then
				st.dealt[id] = true
				if manhattan(ctx.boatTile(b), target) >= 20 / L then
					retaliate(p, target, b.owner, "transport")
					break
				end
			end
		end
	end
	for id in st.dealt do
		if not ctx.boats()[id] then
			st.dealt[id] = nil
		end
	end
	-- counterWarshipInfestation (Hard / Impossible): a rich nation answers an enemy fleet near it.
	local d = difficulty()
	if (d == "Hard" or d == "Impossible") and ctx.warshipTotal() > 10 and ctx.hasPort(p) and p.gold > ctx.warshipCost(p) * 3 then
		local enemyTile = ctx.enemyWarshipNear(p)
		if enemyTile and not ctx.warshipCovering(enemyTile, 90 / L, p.id) then
			ctx.buyWarship(p, enemyTile)
		end
	end
end

-- MIRV (NationMIRVBehavior) -------------------------------------------------------------
local function validTargets(p)
	local out = {}
	for _, q in ctx.players() do
		if q ~= p and q.alive and q.kind ~= "Bot" and not ctx.sameTeam(p.id, q.id) then
			out[#out + 1] = q
		end
	end
	return out
end

local function recentlyMirved(q): boolean
	local t = mirvTargets[q.id]
	return t ~= nil and ctx.tick() - t < MIRV_COOLDOWN
end

local function sendMirv(p, q): boolean
	-- Aim at the target's most valuable structure, else a random tile of theirs.
	local best, bestLevel = nil, 0
	for s in pairs(q.structs) do
		if s.done and (s.kind == "City" or s.kind == "Factory" or s.kind == "Port") and (s.level or 1) > bestLevel then
			best, bestLevel = s.tile, s.level or 1
		end
	end
	local t = best or ctx.randomOwnedTile(q)
	if t and ctx.launchNuke(p, t, "MIRV") then
		mirvTargets[q.id] = ctx.tick()
		return true
	end
	return false
end

function NationBuild.mirv(p)
	if not p.alive or p.kind ~= "Nation" then
		return
	end
	if owned(p, "MissileSilo") == 0 or p.gold < nukeCost(p, "MIRV") then
		return
	end
	local d = difficulty()
	if chance(MIRV_HESITATION[d] or 4) then
		return
	end
	local targets = validTargets(p)
	-- Counter-MIRV: the biggest player with a MIRV in flight at us.
	local counter = nil
	for _, q in targets do
		if ctx.inboundMirv(q.id, p.id) and (counter == nil or q.tiles > counter.tiles) then
			counter = q
		end
	end
	if counter and not recentlyMirved(counter) then
		sendMirv(p, counter)
		return
	end
	-- Victory denial: someone close to winning.
	local land = ctx.landTiles()
	local threshold = land * (MIRV_VICTORY_PCT[d] or 65)
	local denial = nil
	for _, q in targets do
		if q.tiles * 100 >= threshold and (denial == nil or q.tiles > denial.tiles) then
			denial = q
		end
	end
	if denial and not recentlyMirved(denial) then
		sendMirv(p, denial)
		return
	end
	-- Steamroll stop: the city leader far ahead of the runner-up.
	local ranked = {}
	for _, q in ctx.players() do
		if q.alive then
			ranked[#ranked + 1] = { q = q, cities = owned(q, "City") }
		end
	end
	if #ranked < 2 then
		return
	end
	table.sort(ranked, function(a, b)
		return a.cities > b.cities
	end)
	local top = ranked[1]
	if top.cities <= (MIRV_MIN_CITIES[d] or 10) then
		return
	end
	if top.cities >= ranked[2].cities * (MIRV_GAP_MULT[d] or 1.5) and top.q ~= p and top.q.kind ~= "Bot" and not ctx.sameTeam(p.id, top.q.id) and not recentlyMirved(top.q) then
		sendMirv(p, top.q)
	end
end

function NationBuild.reset()
	table.clear(mirvTargets)
end

function NationBuild.init(c)
	ctx = c
end

return NationBuild
