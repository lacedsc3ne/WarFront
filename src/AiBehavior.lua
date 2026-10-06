--[[
	War Front - tribe and nation AI.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.AiBehavior (ModuleScript), driven by GameServer every tick.
-- Re-implements OpenFront's TribeExecution (bots, called "tribes"), NationExecution and the shared
-- AiAttackBehavior, plus NationAllianceBehavior (alliance answers/requests/betrayal),
-- NationExecution's embargo handling and NationNukeBehavior's target and tile choice.
-- Difficulty comes from Config.NATION_DIFFICULTY (public FFA lobbies use "Medium").
-- Structures are still placed by GameServer's aiBuild (hook `build`) on OpenFront's schedule
-- (attack tick plus 1/3 and 2/3 of the interval); warships by Warships.aiConsider (hook `warships`).
-- Not ported: NationEmojiBehavior, NationMIRVBehavior, NationStructureBehavior's placement scoring,
-- warship-aware boat routing (sail/blocker). Hard/Impossible beachheads are ported (sendBeachhead,
-- followUpLandings).
-- Distances: OpenFront tile distances are divided by Config.LINEAR_SCALE (our map is 1/4 per axis).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local Diplomacy = require(ServerScriptService:WaitForChild("Diplomacy"))
local Flow = require(ServerScriptService:WaitForChild("GameFlow"))

local AI = {}

local ctx: any = nil
-- ctx = { players(), tick(), phase(), roundStartTick(), map(), getOwner(t), ownable(t), isWater(t),
--         hasFallout(t), attacks(), startLandAttack(p, id, troops), launchBoat(p, tile, troops),
--         launchNuke(p, tile, kind), build(p), warships(p), claimSpawn(p, t), unclaimSpawn(p),
--         randomOwnedTile(p), deleteStructure(p) }

local rng = Random.new()
local NB = table.create(4)
local NB2 = table.create(4)
local L = Config.LINEAR_SCALE

local function chance(n: number): boolean -- PseudoRandom.chance(n): 1 in n
	return rng:NextInteger(0, n - 1) == 0
end

local function nextInt(lo: number, hi: number): number -- PseudoRandom.nextInt: hi exclusive
	return rng:NextInteger(lo, hi - 1)
end

local function difficulty(): string
	return Config.NATION_DIFFICULTY or "Medium"
end

local function hardPlus(): boolean
	local d = difficulty()
	return d == "Hard" or d == "Impossible"
end

function AI.init(hooks)
	ctx = hooks
end

-- State
-- Per-player AI parameters (TribeExecution / NationExecution constructors).
function AI.newState(kind: string)
	local rate
	if kind == "Bot" then
		rate = nextInt(40, 80)
	else
		local d = difficulty()
		rate = if d == "Easy"
			then nextInt(65, 100)
			elseif d == "Hard" then nextInt(45, 60)
			elseif d == "Impossible" then nextInt(30, 50)
			else nextInt(55, 70)
	end
	local s = {
		rate = rate,
		offset = nextInt(0, rate),
		trigger = nextInt(50, 60) / 100,
		reserve = nextInt(30, 40) / 100,
		expand = nextInt(10, 20) / 100,
		started = false,
		neighborsTN = true,
		botSent = 0,
	}
	if kind == "Nation" then
		s.hydroNation = chance(3)
		s.atomCost = Config.NUKES.AtomBomb and Config.NUKES.AtomBomb.cost or math.huge
		s.hydroCost = Config.NUKES.HydrogenBomb and Config.NUKES.HydrogenBomb.cost or math.huge
		s.recentNukes = {}
		s.embargoMalus = {}
	end
	return s
end

-- Map helpers
-- One pass over the border: bordering players (land), unowned land, fallout, shore tiles.
local function scan(p)
	local map = ctx.map()
	local seen, list = {}, {}
	local hasTN, anyUnowned, nuked = false, false, false
	local shore = {}
	for bt in pairs(p.border) do
		local n = MapUtil.neighbors(map, bt, NB)
		local isShore = false
		for i = 1, n do
			local t = NB[i]
			if ctx.isWater(t) then
				isShore = true
			elseif ctx.ownable(t) then
				local o = ctx.getOwner(t)
				if o == 0 then
					anyUnowned = true
					if ctx.hasFallout(t) then
						nuked = true
					else
						hasTN = true
					end
				elseif o ~= p.id and not seen[o] then
					seen[o] = true
					list[#list + 1] = o
				end
			end
		end
		if isShore then
			shore[#shore + 1] = bt
		end
	end
	return { set = seen, list = list, hasTN = hasTN, anyUnowned = anyUnowned, nuked = nuked, shore = shore }
end

local function shoreOf(q, limit: number): { number }
	local map = ctx.map()
	local out = {}
	for bt in pairs(q.border) do
		local n = MapUtil.neighbors(map, bt, NB2)
		for i = 1, n do
			if ctx.isWater(NB2[i]) then
				out[#out + 1] = bt
				break
			end
		end
		if #out >= limit then
			break
		end
	end
	return out
end

local function manhattan(a: number, b: number, w: number): number
	return math.abs(a % w - b % w) + math.abs(a // w - b // w)
end

local function incomingFrom(p)
	local byAttacker = {}
	for _, a in ctx.attacks() do
		if a.target == p.id and not a.dead then
			byAttacker[a.attacker.id] = (byAttacker[a.attacker.id] or 0) + a.troops
		end
	end
	return byAttacker
end

local function totalIncoming(p): number
	local sum = 0
	for _, v in incomingFrom(p) do
		sum += v
	end
	return sum
end

local function outgoingTroops(p): number
	local sum = 0
	for a in pairs(p.outgoing) do
		sum += a.troops
	end
	return sum
end

-- Attack behaviour (AiAttackBehavior)
local B = {} -- behaviour functions, forward-declared table

-- findIncomingAttackPlayer: the largest incoming attack from a non-friendly player
-- (bots are ignored unless we are a bot ourselves).
function B.incomingAttacker(p)
	local players = ctx.players()
	local best, bestTroops = nil, 0
	for id, troops in incomingFrom(p) do
		local q = players[id]
		if q and q.alive and not Flow.isFriendly(p, id) and (p.kind == "Bot" or q.kind ~= "Bot") and troops > bestTroops then
			best, bestTroops = q, troops
		end
	end
	return best
end

-- shouldAttack: tribes attack anyone; nations hold back against humans now and then.
function B.shouldAttack(p, targetId: number): boolean
	local q = ctx.players()[targetId]
	if targetId == 0 or not q or q.kind ~= "Human" or Diplomacy.isTraitor(targetId, ctx.tick()) or p.kind == "Bot" then
		return true
	end
	local d = difficulty()
	if d == "Easy" and nextInt(0, 4) ~= 0 then
		return false
	end
	if d == "Medium" and chance(4) then
		return false
	end
	return true
end

function B.neighborTroopCap(p, ignore): number
	if p.kind == "Bot" then
		return math.huge
	end
	local d = difficulty()
	local keep = if d == "Hard" then 0.75 elseif d == "Impossible" then 0.9 else nil
	if not keep then
		return math.huge
	end
	local maxN = 0
	local players = ctx.players()
	for _, id in p.ai.scan.list do
		local q = players[id]
		if q and q ~= ignore and q.kind ~= "Bot" and not Flow.isFriendly(p, id) and q.troops > maxN then
			maxN = q.troops
		end
	end
	if maxN == 0 then
		return math.huge
	end
	return math.max(0, p.troops - math.ceil(maxN * keep))
end

function B.troopSendCap(p, ignore): number
	local cap = B.neighborTroopCap(p, ignore)
	local inc = totalIncoming(p)
	if inc > 0 then
		cap = math.max(cap, inc)
	end
	return cap
end

function B.capForExpansion(p): number
	local cap = B.troopSendCap(p)
	if cap > 0 then
		return cap
	end
	return math.ceil(p.troops * 0.05)
end

function B.tooWeak(p, troops: number, q): boolean
	if p.kind == "Bot" or totalIncoming(p) > 0 then
		return false
	end
	return hardPlus() and troops < q.troops * 0.2
end

function B.botAttackTroops(q, maxTroops: number): number
	if difficulty() == "Easy" then
		return maxTroops
	end
	local troops = q.troops * 4
	if troops > maxTroops then
		troops = if maxTroops < q.troops * 2 then 0 else maxTroops
	end
	return troops
end

-- calculateAttackTroops. nonBot(targetTroops) gives the amount for non-bot targets.
function B.attackTroops(p, targetId: number, nonBot, opponent): number?
	local ai = p.ai
	local q = if targetId ~= 0 then ctx.players()[targetId] else nil
	local botStructs = q ~= nil and q.kind == "Bot" and next(q.structs) ~= nil
	local useReserve = q ~= nil and not botStructs
	local keep = p.maxTroops * (if useReserve then ai.reserve else ai.expand)
	local troops
	local isBotAttack = q ~= nil and q.kind == "Bot" and p.kind ~= "Bot"
	if isBotAttack then
		troops = B.botAttackTroops(q, p.troops - keep - ai.botSent)
	else
		troops = nonBot(keep)
	end
	troops = math.min(troops, if q then B.troopSendCap(p, opponent) else B.capForExpansion(p), p.troops)
	if troops < 1 then
		return nil
	end
	if q then
		local pileOn = 0
		if q == opponent then
			pileOn = totalIncoming(q)
		end
		if B.tooWeak(p, troops + pileOn, q) then
			return nil
		end
	end
	if isBotAttack then
		ai.botSent += troops
	end
	return math.floor(troops)
end

local function keepReserve(p)
	return function(keep: number): number
		return p.troops - keep
	end
end

function B.sendLand(p, targetId: number, nonBot, opponent): boolean
	local troops = B.attackTroops(p, targetId, nonBot or keepReserve(p), opponent)
	if not troops then
		return false
	end
	return ctx.startLandAttack(p, targetId, troops)
end

-- Closest pair of our shore and theirs (closestTwoTiles), sampled.
function B.landingFor(p, q): number?
	local ours = p.ai.scan.shore
	if #ours == 0 then
		return nil
	end
	local theirs = shoreOf(q, 120)
	if #theirs == 0 then
		return nil
	end
	local w = ctx.map().width
	local step = math.max(1, #ours // 120)
	local best, bestD = nil, math.huge
	for i = 1, #ours, step do
		local a = ours[i]
		for _, b in theirs do
			local d = manhattan(a, b, w)
			if d < bestD then
				best, bestD = b, d
			end
		end
	end
	return best
end

-- AiAttackBehavior.landsBeachheads: Hard & Impossible nations boat a tiny force and attack by land
-- the moment it lands.
local function landsBeachheads(p): boolean
	return p.kind == "Nation" and hardPlus()
end

-- sendBeachhead: a 1% boat, if the land attack following its landing would be worth making now.
function B.sendBeachhead(p, targetId: number, landing: number): boolean
	local q = if targetId ~= 0 then ctx.players()[targetId] else nil
	local troops = B.attackTroops(p, targetId, function(keep: number): number
		return p.troops - keep
	end, q)
	if not troops then
		return false
	end
	local boatTroops = math.max(1, math.floor(p.troops / 100))
	-- Only the boat leaves now: the land attack is budgeted once it lands.
	if q and q.kind == "Bot" then
		p.ai.botSent += boatTroops - troops
	end
	return ctx.launchBoat(p, landing, boatTroops)
end

-- followUpLandings (every tick): when one of our boats lands (its attack remembers the landing
-- tile), attack its target by land from there, once, if we still hold land next to that coast.
function B.followUpLandings(p)
	local players = ctx.players()
	for _, a in ctx.attacks() do
		if a.attacker == p and a.landing and not a.followed and not a.dead then
			a.followed = true
			local L0 = a.landing
			local target = a.target
			local map = ctx.map()
			local n = MapUtil.neighbors(map, L0, NB2)
			local holds = false
			for i = 1, n do
				local t = NB2[i]
				if MapUtil.isLand(map, t) and ctx.ownable(t) and ctx.getOwner(t) == target then
					holds = true
					break
				end
			end
			if holds then
				B.sendLand(p, target, nil, players[target])
			end
		end
	end
end

function B.canBoat(p): boolean
	return p.boats < Config.MAX_BOATS and #p.ai.scan.shore > 0
end

function B.sendBoat(p, q): boolean
	if not B.canBoat(p) then
		return false
	end
	local landing = B.landingFor(p, q)
	if not landing then
		return false
	end
	if landsBeachheads(p) then
		return B.sendBeachhead(p, q.id, landing)
	end
	local troops = B.attackTroops(p, q.id, function()
		return p.troops / 5
	end)
	if not troops then
		return false
	end
	return ctx.launchBoat(p, landing, troops)
end

-- Unowned land a short hop across the water (5 full-size tiles, rounded up here).
function B.boatToNearbyTN(p): boolean
	if not B.canBoat(p) then
		return false
	end
	local map = ctx.map()
	local w, h = map.width, map.height
	local hop = math.ceil(5 / L)
	local shores = p.ai.scan.shore
	for i = 1, #shores, 10 do
		local b = shores[i]
		local bx, by = b % w, b // w
		for _, d in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
			local x1, y1 = bx + d[1], by + d[2]
			local nx, ny = bx + d[1] * (hop + 1), by + d[2] * (hop + 1)
			if x1 >= 0 and x1 < w and y1 >= 0 and y1 < h and nx >= 0 and nx < w and ny >= 0 and ny < h then
				local t = ny * w + nx
				if ctx.isWater(y1 * w + x1) and ctx.ownable(t) and ctx.getOwner(t) == 0 and not ctx.hasFallout(t) then
					if landsBeachheads(p) then
						return B.sendBeachhead(p, 0, t)
					end
					local troops = math.floor(math.min(p.troops / 5, B.capForExpansion(p)))
					if troops < 1 then
						return false
					end
					return ctx.launchBoat(p, t, troops)
				end
			end
		end
	end
	return false
end

function B.sendAttack(p, targetId: number, force: boolean?): boolean
	if not force and not B.shouldAttack(p, targetId) then
		return false
	end
	if targetId ~= 0 then
		local q = ctx.players()[targetId]
		if not q or not q.alive then
			return false
		end
		if p.ai.scan.set[targetId] then
			return B.sendLand(p, targetId)
		end
		return B.sendBoat(p, q)
	end
	if p.ai.scan.anyUnowned then
		return B.sendLand(p, 0)
	end
	return B.boatToNearbyTN(p)
end

-- canReach: by land, or (Medium and below: any) boat route. Route length/warships are not checked.
function B.canReach(p, q): boolean
	if p.ai.scan.set[q.id] then
		return true
	end
	return B.canBoat(p) and #shoreOf(q, 1) > 0
end

local function isFFA(): boolean
	return true -- War Front only has free-for-all rounds
end

function B.traitorNeighbor(p)
	local list = {}
	local players = ctx.players()
	local now = ctx.tick()
	for _, id in p.ai.scan.list do
		local q = players[id]
		if q and q.alive and not Flow.isFriendly(p, id) and Diplomacy.isTraitor(id, now) then
			list[#list + 1] = q
		end
	end
	return if #list > 0 then list[rng:NextInteger(1, #list)] else nil
end

function B.attackRandomTarget(p)
	local ai = p.ai
	if p.troops < p.maxTroops * ai.trigger then
		return
	end
	local inc = B.incomingAttacker(p)
	if inc and B.sendAttack(p, inc.id, true) then
		return
	end
	local traitor = B.traitorNeighbor(p)
	if traitor and chance(3) and B.sendAttack(p, traitor.id) then
		return
	end
	local list = table.clone(ai.scan.list)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	local players = ctx.players()
	for _, id in list do
		local q = players[id]
		if q and q.alive and not Flow.isFriendly(p, id) then
			if not ((q.kind == "Nation" or q.kind == "Human") and chance(2)) then
				if B.sendAttack(p, id) then
					return
				end
			end
		end
	end
end

-- findRunawayLeader: non-bot player with the most land, if far enough ahead of the runner-up.
function B.runawayLeader()
	local d = difficulty()
	local factor = if d == "Medium" then 3 elseif d == "Hard" then 2 elseif d == "Impossible" then 1.5 else nil
	if not factor then
		return nil
	end
	local leader, runnerUp = nil, nil
	for _, q in ctx.players() do
		if q.alive and q.kind ~= "Bot" and q.tiles > 0 then
			if leader == nil or q.tiles > leader.tiles then
				runnerUp, leader = leader, q
			elseif runnerUp == nil or q.tiles > runnerUp.tiles then
				runnerUp = q
			end
		end
	end
	if leader and runnerUp and leader.tiles >= runnerUp.tiles * factor then
		return leader
	end
	return nil
end

-- Alliances (NationAllianceBehavior)
local function allyCount(p): number
	local n = 0
	for id, q in ctx.players() do
		if id ~= p.id and q.alive and Diplomacy.allied(p.id, id) then
			n += 1
		end
	end
	return n
end

local function allianceDecision(p, other, isResponse: boolean): boolean
	local d = difficulty()
	local confused = if d == "Easy" then chance(10) elseif d == "Medium" then chance(20) elseif d == "Hard" then chance(40) else false
	if confused then
		return chance(2)
	end
	local now = ctx.tick()
	if Diplomacy.isTraitor(other.id, now) and nextInt(0, 100) >= 10 then
		return false
	end
	if hardPlus() then
		local total = 0
		for _, q in ctx.players() do
			if q.alive and q.kind ~= "Bot" then
				total += 1
			end
		end
		if allyCount(other) >= total * (if d == "Hard" then 0.5 else 0.25) then
			return false
		end
	end
	if B.runawayLeader() == other then
		return false
	end
	-- Threat: ally with players much stronger than us.
	local threat
	if d == "Easy" then
		threat = false
	elseif d == "Medium" then
		threat = other.troops > p.troops * 2.5
	elseif d == "Hard" then
		threat = other.troops > p.troops and other.maxTroops > p.maxTroops * 2
	else
		threat = other.troops > p.troops * 1.5
			or (other.troops > p.troops and other.maxTroops > p.maxTroops * 1.5)
			or (other.troops > p.troops and other.tiles > p.tiles * 1.5)
	end
	if threat then
		return true
	end
	local rel = Flow.relation(p, other.id)
	if rel < Flow.NEUTRAL then
		return false
	end
	if rel == Flow.FRIENDLY then
		if d == "Hard" then
			if nextInt(0, 100) >= 17 then
				return true
			end
		elseif d == "Impossible" then
			if nextInt(0, 100) >= 33 then
				return true
			end
		else
			return true
		end
	end
	-- Already enough alliances?
	if d == "Medium" and allyCount(p) >= nextInt(4, 6) then
		return false
	elseif d == "Hard" and allyCount(p) >= nextInt(3, 5) then
		return false
	elseif d == "Impossible" and allyCount(p) >= nextInt(2, 4) then
		return false
	end
	-- Early game: accept most requests.
	local elapsed = ctx.tick() - ctx.roundStartTick()
	if d == "Easy" then
		if elapsed < 3000 and nextInt(0, 100) >= 10 then
			return true
		end
	elseif d == "Medium" then
		if elapsed < 1800 and nextInt(0, 100) >= 30 then
			return true
		end
	elseif d == "Hard" then
		if elapsed < 1800 and nextInt(0, 100) >= 50 then
			return true
		end
	elseif elapsed < 600 and nextInt(0, 100) >= 70 then
		return true
	end
	-- Similarly strong?
	local troopRange = ({ Easy = { 60, 70 }, Medium = { 70, 80 }, Hard = { 75, 85 }, Impossible = { 80, 90 } })[d]
	local tileRange = ({ Easy = { 70, 80 }, Medium = { 80, 90 }, Hard = { 85, 95 }, Impossible = { 90, 100 } })[d]
	local mine = p.troops + outgoingTroops(p)
	local theirs = other.troops + outgoingTroops(other)
	local troopThreshold = mine * nextInt(troopRange[1], troopRange[2]) / 100
	local tileThreshold = p.tiles * nextInt(tileRange[1], tileRange[2]) / 100
	return theirs > troopThreshold or (other.tiles > tileThreshold and theirs > mine * 0.5)
end

-- Diplomacy hook: how an AI answers an alliance (or renewal) request from `from`.
-- Tribes accept everything (TribeExecution.acceptAllAllianceRequests).
function AI.allianceAnswer(p, from, renew: boolean): boolean
	if p.kind == "Bot" then
		return true
	end
	if from.disconnected then
		return false
	end
	return allianceDecision(p, from, true)
end

function B.maybeSendAllianceRequests(p, enemies)
	for _, q in enemies do
		local typeOk = q.kind ~= "Bot" or difficulty() == "Easy"
		if chance(30) and typeOk and not q.disconnected and allianceDecision(p, q, false) then
			Diplomacy.request(p, q, ctx.tick())
		end
	end
end

local function juiciest(cands)
	-- findJuiciestTarget: more non-defensive structures, emptier armies, more land.
	local best, bestScore = nil, -math.huge
	for _, q in cands do
		local structs = 0
		for s in pairs(q.structs) do
			if s.kind ~= "DefensePost" and s.kind ~= "MissileSilo" then
				structs += s.level or 1
			end
		end
		local gap = if q.maxTroops > 0 then 1 - q.troops / q.maxTroops else 0
		local score = structs * 2 + gap + q.tiles / 1000
		if score > bestScore then
			best, bestScore = q, score
		end
	end
	return best
end

function B.betray(p, q)
	Diplomacy.breakAlliance(p, q, ctx.tick())
end

function B.maybeBetray(p, q, juiciestAlly, friends, enemies): boolean
	if not Diplomacy.allied(p.id, q.id) then
		return false
	end
	local d = difficulty()
	local now = ctx.tick()
	if hardPlus() and juiciestAlly == q then
		local threat = q.troops + outgoingTroops(q)
		for _, e in enemies do
			threat += e.troops + outgoingTroops(e)
		end
		if not Diplomacy.isTraitor(q.id, now) then
			for _, f in friends do
				if f ~= q and Diplomacy.allied(p.id, f.id) then
					threat += f.troops + outgoingTroops(f)
				end
			end
		end
		if threat < p.troops * 0.33 then
			B.betray(p, q)
			return true
		end
	end
	if (d == "Easy" or d == "Medium") and not (d == "Easy" and q.kind == "Human") and p.troops >= q.troops * 10 then
		B.betray(p, q)
		return true
	end
	if d ~= "Easy" and Diplomacy.isTraitor(q.id, now) and q.troops < p.troops * 1.2 then
		B.betray(p, q)
		return true
	end
	if d ~= "Easy" and #friends + #enemies == 1 and q.troops * 3 < p.troops then
		B.betray(p, q)
		return true
	end
	return false
end

-- Nation strategies (AiAttackBehavior.attackBestTarget / getAttackStrategies)
function B.attackBots(p): boolean
	local players = ctx.players()
	local bots = {}
	for _, id in p.ai.scan.list do
		local q = players[id]
		if q and q.alive and q.kind == "Bot" and not Flow.isFriendly(p, id) then
			bots[#bots + 1] = q
		end
	end
	if #bots == 0 then
		return false
	end
	p.ai.botSent = 0
	table.sort(bots, function(a, b)
		local sa, sb = next(a.structs) ~= nil, next(b.structs) ~= nil
		if sa ~= sb then
			return sa
		end
		return a.troops / math.max(1, a.tiles) < b.troops / math.max(1, b.tiles)
	end)
	local d = difficulty()
	local par = if d == "Easy" then 1 elseif d == "Medium" then (if chance(2) then 1 else 2) elseif d == "Hard" then 3 else 100
	for i = 1, math.min(par, #bots) do
		B.sendAttack(p, bots[i].id)
	end
	return p.ai.botSent > 0
end

function B.retaliate(p): boolean
	local attacker = B.incomingAttacker(p)
	if not attacker then
		return false
	end
	if hardPlus() and isFFA() and p.ai.scan.set[attacker.id] then
		-- sendRetaliation: cancel the incoming troops and push back if we can match them.
		local incoming = incomingFrom(p)[attacker.id] or 0
		local pressing = 0
		for a in pairs(p.outgoing) do
			if a.target == attacker.id then
				pressing += a.troops
			end
		end
		local spare = math.min(p.troops - p.maxTroops * p.ai.expand, B.neighborTroopCap(p, attacker))
		local aboveReserve = p.troops - p.maxTroops * p.ai.reserve
		local counter = incoming + math.max(0, attacker.troops - pressing)
		local send = if spare >= counter
			then math.max(counter, math.min(aboveReserve, spare))
			else math.min(incoming, math.max(spare, aboveReserve))
		return B.sendLand(p, attacker.id, function()
			return send
		end, attacker)
	end
	return B.sendAttack(p, attacker.id, true)
end

function B.attackWithRandomBoat(p, enemies)
	if not B.canBoat(p) then
		return
	end
	local shore = p.ai.scan.shore
	local src = shore[rng:NextInteger(1, #shore)]
	local map = ctx.map()
	local w, h = map.width, map.height
	local reach = math.floor(150 / L)
	local players = ctx.players()
	local bordering = {}
	for _, q in enemies do
		bordering[q.id] = true
	end
	local function find(highInterest: boolean): number?
		local x, y = src % w, src // w
		for _ = 1, 500 do
			local rx, ry = x + rng:NextInteger(-reach, reach), y + rng:NextInteger(-reach, reach)
			if rx >= 0 and rx < w and ry >= 0 and ry < h then
				local t = ry * w + rx
				if ctx.ownable(t) then
					local o = ctx.getOwner(t)
					local q = players[o]
					if o ~= p.id and not bordering[o] and not (q and isFFA() and q.troops > p.troops) then
						local ok
						if highInterest then
							ok = o == 0 or (q ~= nil and q.kind == "Bot")
						else
							ok = o == 0 or not Flow.isFriendly(p, o)
						end
						if ok then
							return t
						end
					end
				end
			end
		end
		return nil
	end
	local t = find(true) or find(false)
	if not t then
		return
	end
	local o = ctx.getOwner(t)
	if landsBeachheads(p) then
		B.sendBeachhead(p, o, t)
		return
	end
	local cap = if o ~= 0 then B.troopSendCap(p) else B.capForExpansion(p)
	local troops = math.floor(math.min(p.troops / 5, cap))
	if troops < 1 then
		return
	end
	if o ~= 0 and B.tooWeak(p, troops, players[o]) then
		return
	end
	ctx.launchBoat(p, t, troops)
end

function B.nearestIslandEnemy(p)
	if not B.canBoat(p) then
		return nil
	end
	local w = ctx.map().width
	local cx = if p.tiles > 0 then p.sumX / p.tiles else 0
	local cy = if p.tiles > 0 then p.sumY / p.tiles else 0
	local list = {}
	for id, q in ctx.players() do
		if id ~= p.id and q.alive and q.tiles > 0 and not Flow.isFriendly(p, id) and not (isFFA() and q.troops >= p.troops) then
			local qx, qy = q.sumX / q.tiles, q.sumY / q.tiles
			list[#list + 1] = { q = q, d = math.abs(qx - cx) + math.abs(qy - cy) }
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local reachable = {}
	for _, e in list do
		if B.canReach(p, e.q) then
			reachable[#reachable + 1] = e.q
			if #reachable >= 2 then
				break
			end
		end
	end
	if #reachable == 0 then
		return nil
	end
	if #reachable >= 2 and chance(3) then
		return reachable[2]
	end
	local _ = w
	return reachable[1]
end

function B.assistAllies(p): boolean
	local players = ctx.players()
	for id, ally in players do
		if id ~= p.id and ally.alive and Diplomacy.allied(p.id, id) then
			local ts = Flow.targetsOf(id)
			if #ts > 0 and Flow.relation(p, id) >= Flow.FRIENDLY then
				for _, t in ts do
					if t ~= p.id and not Flow.isFriendly(p, t) and B.sendAttack(p, t) then
						Flow.updateRelation(p, id, -20)
						return true
					end
				end
			end
		end
	end
	return false
end

-- Strategies, in Medium's order: bots, nuked, assist, betray, hated, afk, traitor, crown, weakest,
-- island (donate only applies to team games). Other difficulties use their own orders.
function B.attackBestTarget(p, friends, enemies)
	local ai = p.ai
	local d = difficulty()
	if hardPlus() and B.retaliate(p) then
		return
	end
	local players = ctx.players()
	local botWithStructs = false
	for _, id in ai.scan.list do
		local q = players[id]
		if q and q.kind == "Bot" and next(q.structs) ~= nil and not Flow.isFriendly(p, id) then
			botWithStructs = true
			break
		end
	end
	if botWithStructs and B.attackBots(p) then
		return
	end
	if p.troops < p.maxTroops * ai.reserve then
		return
	end
	if d == "Medium" and B.retaliate(p) then
		return
	end
	if p.troops < p.maxTroops * ai.trigger and not chance(10) then
		return
	end

	local now = ctx.tick()
	local function pick(find)
		local pool = table.clone(enemies)
		while true do
			local t = find(pool)
			if not t then
				return nil
			end
			if d == "Easy" or B.canReach(p, t) then
				return t
			end
			table.remove(pool, table.find(pool, t))
		end
	end
	local function first(pool, pred)
		for _, q in pool do
			if pred(q) then
				return q
			end
		end
		return nil
	end

	local S = {}
	S.bots = function()
		return B.attackBots(p)
	end
	S.retaliate = function()
		return B.retaliate(p)
	end
	S.assist = function()
		return B.assistAllies(p)
	end
	S.traitor = function()
		local t = pick(function(pool)
			return first(pool, function(q)
				return Diplomacy.isTraitor(q.id, now) and (not isFFA() or q.troops < p.troops * 1.2)
			end)
		end)
		return t ~= nil and B.sendAttack(p, t.id)
	end
	S.afk = function()
		local t = pick(function(pool)
			return first(pool, function(q)
				return q.disconnected == true and (not isFFA() or q.troops < p.troops * 3)
			end)
		end)
		return t ~= nil and B.sendAttack(p, t.id)
	end
	S.betray = function()
		if #friends == 0 then
			return false
		end
		local jui = juiciest(friends)
		for _, f in friends do
			if B.maybeBetray(p, f, jui, friends, enemies) then
				return B.sendAttack(p, f.id, true)
			end
		end
		return false
	end
	S.nuked = function()
		return ai.scan.nuked and B.sendAttack(p, 0)
	end
	S.victim = function()
		local t = pick(function(pool)
			return first(pool, function(q)
				if isFFA() and q.troops > p.troops * 1.2 then
					return false
				end
				return totalIncoming(q) > q.troops * 0.5
			end)
		end)
		return t ~= nil and B.sendAttack(p, t.id)
	end
	S.juicy = function()
		local t = pick(function(pool)
			local c = {}
			for _, q in pool do
				if q.troops <= p.troops * 0.75 then
					c[#c + 1] = q
				end
			end
			return juiciest(c)
		end)
		return t ~= nil and B.sendAttack(p, t.id)
	end
	S.hated = function()
		for _, r in Flow.relationsSorted(p) do
			if r.relation == Flow.HOSTILE then
				local q = players[r.id]
				if q and not Flow.isFriendly(p, r.id) and not (isFFA() and q.troops > p.troops * 3) then
					if d == "Easy" or B.canReach(p, q) then
						return B.sendAttack(p, r.id)
					end
				end
			end
		end
		return false
	end
	S.veryWeak = function()
		local t = pick(function(pool)
			return first(pool, function(q)
				return q.troops < q.maxTroops * 0.15 and (not isFFA() or q.troops < p.troops * 1.2)
			end)
		end)
		return t ~= nil and B.sendAttack(p, t.id)
	end
	S.weakest = function()
		local t = pick(function(pool)
			return first(pool, function(q)
				return not isFFA() or q.troops < p.troops
			end)
		end)
		return t ~= nil and B.sendAttack(p, t.id)
	end
	S.island = function()
		if pick(function(pool)
			return pool[1]
		end) == nil then
			local e = B.nearestIslandEnemy(p)
			if e then
				return B.sendAttack(p, e.id)
			end
		end
		return false
	end
	S.donate = function()
		return false -- team games only
	end
	S.crown = function()
		local leader = B.runawayLeader()
		if not leader or not table.find(enemies, leader) or not ai.scan.set[leader.id] then
			return false
		end
		if not hardPlus() and totalIncoming(leader) < leader.troops * 0.1 then
			return false
		end
		return B.shouldAttack(p, leader.id) and B.sendLand(p, leader.id, nil, leader)
	end

	local order
	if d == "Easy" then
		order = { "nuked", "bots", "retaliate", "assist", "betray", "hated", "weakest" }
	elseif d == "Hard" then
		order = { "bots", "assist", "betray", "nuked", "traitor", "afk", "hated", "veryWeak", "juicy", "victim", "crown", "weakest", "island", "donate" }
	elseif d == "Impossible" then
		order = { "bots", "veryWeak", "betray", "assist", "victim", "crown", "traitor", "juicy", "afk", "nuked", "hated", "weakest", "island", "donate" }
	else
		order = { "bots", "nuked", "assist", "betray", "hated", "afk", "traitor", "crown", "weakest", "island", "donate" }
	end
	for _, name in order do
		if S[name]() then
			return
		end
	end
end

-- chooseAttack
function B.maybeAttack(p)
	local ai = p.ai
	local players = ctx.players()
	local all = {}
	for _, id in ai.scan.list do
		local q = players[id]
		if q and q.alive then
			all[#all + 1] = q
		end
	end
	table.sort(all, function(a, b)
		return a.troops < b.troops
	end)
	local friends, enemies = {}, {}
	for _, q in all do
		if Flow.isFriendly(p, q.id) then
			friends[#friends + 1] = q
		else
			enemies[#enemies + 1] = q
		end
	end
	if ai.scan.hasTN and B.sendAttack(p, 0) then
		return
	end
	local d = difficulty()
	local holdBoats = B.incomingAttacker(p) ~= nil and (if d == "Medium" then chance(2) elseif d == "Easy" then false else true)
	if #enemies == 0 then
		if not holdBoats and chance(5) then
			B.attackWithRandomBoat(p, enemies)
		end
	else
		if not holdBoats and chance(10) then
			B.attackWithRandomBoat(p, enemies)
			return
		end
		B.maybeSendAllianceRequests(p, enemies)
	end
	B.attackBestTarget(p, friends, enemies)
end

-- Nation embargoes (NationExecution.updateRelationsFromEmbargos / handleEmbargoesToHostileNations)
function B.embargoes(p)
	local ai = p.ai
	local d = difficulty()
	for id, q in ctx.players() do
		if id ~= p.id and q.alive then
			local theyEmbargo = Flow.hasEmbargoAgainst(id, p.id)
			if theyEmbargo and not ai.embargoMalus[id] then
				Flow.updateRelation(p, id, -20)
				ai.embargoMalus[id] = true
			elseif not theyEmbargo and ai.embargoMalus[id] then
				Flow.updateRelation(p, id, 20)
				ai.embargoMalus[id] = nil
			end
			local rel = Flow.relation(p, id)
			local mine = Flow.hasEmbargoAgainst(p.id, id)
			if rel <= Flow.HOSTILE and not mine then
				Flow.addEmbargo(p, id, false)
			elseif rel >= Flow.NEUTRAL and mine and d ~= "Hard" and d ~= "Impossible" then
				Flow.stopEmbargo(p, id)
			elseif rel >= Flow.FRIENDLY and mine and d ~= "Impossible" then
				Flow.stopEmbargo(p, id)
			end
		end
	end
end

-- Nukes (NationNukeBehavior)
local NUKE_VALUE = { City = 25000, DefensePost = 5000, MissileSilo = 50000, Port = 15000, Factory = 15000 }

function B.nukeTarget(p)
	local players = ctx.players()
	local alive = {}
	for _, q in players do
		if q.alive and q.tiles > 0 then
			alive[#alive + 1] = q
		end
	end
	if hardPlus() and #alive == 2 then
		return if alive[1] == p then alive[2] else alive[1]
	end
	local inc = B.incomingAttacker(p)
	if inc then
		return inc
	end
	for id, ally in players do
		if id ~= p.id and ally.alive and Diplomacy.allied(p.id, id) and Flow.relation(p, id) >= Flow.FRIENDLY then
			for _, t in Flow.targetsOf(id) do
				if t ~= p.id and not Flow.isFriendly(p, t) and players[t] then
					return players[t]
				end
			end
		end
	end
	for _, r in Flow.relationsSorted(p) do
		if r.relation == Flow.HOSTILE and not Flow.isFriendly(p, r.id) then
			local q = players[r.id]
			if q and not (p.maxTroops >= q.maxTroops * 2) then
				return q
			end
		end
	end
	-- FFA crown.
	table.sort(alive, function(a, b)
		return a.tiles > b.tiles
	end)
	local first = alive[1]
	if not first or first == p or Flow.isFriendly(p, first.id) then
		return nil
	end
	local land = ctx.landTiles() - Flow.falloutTiles()
	if land <= 0 then
		return nil
	end
	local share = first.tiles / land
	if share > 0.5 then
		return first
	end
	if B.runawayLeader() ~= first then
		return nil
	end
	local d = difficulty()
	local threshold = if d == "Medium" then 0.3 elseif d == "Hard" then 0.2 elseif d == "Impossible" then 0.1 else nil
	if not threshold then
		return nil
	end
	if not p.ai.scan.set[first.id] then
		threshold *= 2
	end
	if share - p.tiles / land > threshold then
		return first
	end
	return nil
end

function B.maybeSendNuke(p)
	local ai = p.ai
	local silos = {}
	for s in pairs(p.structs) do
		if s.kind == "MissileSilo" and s.done then
			silos[#silos + 1] = s
		end
	end
	if #silos == 0 or Flow.nukesBlocked() then
		return
	end
	local q = B.nukeTarget(p)
	if not q or q.kind == "Bot" or not B.shouldAttack(p, q.id) then
		return
	end
	local heavy = totalIncoming(p) >= p.troops
	local atomCost, hydroCost = ai.atomCost, ai.hydroCost
	if hardPlus() and heavy then
		atomCost = Config.NUKES.AtomBomb.cost
		hydroCost = if Config.NUKES.HydrogenBomb then Config.NUKES.HydrogenBomb.cost else math.huge
	end
	local kind
	if Config.NUKES.HydrogenBomb and p.gold >= hydroCost then
		kind = "HydrogenBomb"
	elseif Config.NUKES.AtomBomb and (not ai.hydroNation or heavy) and p.gold >= atomCost then
		kind = "AtomBomb"
	else
		return
	end
	local def = Config.NUKES[kind]
	local map = ctx.map()
	local w, h = map.width, map.height
	local range = math.ceil(def.outer)
	local half = math.floor(range / 2)
	local now = ctx.tick()
	for i = #ai.recentNukes, 1, -1 do
		if now - ai.recentNukes[i].tick > 600 then
			table.remove(ai.recentNukes, i)
		end
	end
	-- Candidates: 10 (Impossible: 30) random tiles of the target plus its structures.
	local cands = {}
	for _ = 1, if difficulty() == "Impossible" then 30 else 10 do
		local t = ctx.randomOwnedTile(q)
		if t then
			cands[t] = true
		end
	end
	local structs = {}
	for s in pairs(q.structs) do
		structs[#structs + 1] = s
		cands[s.tile] = true
	end
	local function validTile(t: number): boolean
		local o = ctx.getOwner(t)
		if o == q.id then
			return true
		end
		return hardPlus() and o == 0 and not ctx.isWater(t)
	end
	-- boundingBoxTiles: the square ring at `r` around (cx, cy).
	local function ringOk(cx: number, cy: number, r: number): boolean
		for dx = -r, r do
			for _, dy in { -r, r } do
				local x, y = cx + dx, cy + dy
				if x >= 0 and x < w and y >= 0 and y < h and not validTile(y * w + x) then
					return false
				end
			end
		end
		for dy = -r + 1, r - 1 do
			for _, dx in { -r, r } do
				local x, y = cx + dx, cy + dy
				if x >= 0 and x < w and y >= 0 and y < h and not validTile(y * w + x) then
					return false
				end
			end
		end
		return true
	end
	local best, bestValue = nil, -1
	local o2 = def.outer * def.outer
	for t in cands do
		local cx, cy = t % w, t // w
		if ringOk(cx, cy, range) and ringOk(cx, cy, half) then
			local value = 0
			local samNear = false
			for _, s in structs do
				local dx, dy = s.tile % w - cx, s.tile // w - cy
				local d2 = dx * dx + dy * dy
				if d2 <= o2 then
					value += (NUKE_VALUE[s.kind] or 0) * (s.level or 1)
				end
				local samR = 50 / L
				if s.kind == "SAM" and d2 <= samR * samR then
					samNear = true
				end
			end
			if difficulty() == "Medium" and samNear then
				value = -1
			else
				-- Prefer tiles near a silo: 30 per full-size tile of distance, keep 20 % of the value.
				local nearest = math.huge
				for _, s in silos do
					local dx, dy = s.tile % w - cx, s.tile // w - cy
					nearest = math.min(nearest, math.sqrt(dx * dx + dy * dy) * L)
				end
				value = math.max(value * 0.2, value - nearest * 30)
				for _, r in ai.recentNukes do
					local inner = Config.NUKES[r.kind].inner
					local dx, dy = r.tile % w - cx, r.tile // w - cy
					if dx * dx + dy * dy <= inner * inner then
						value -= 1000000
					end
				end
			end
			if value > bestValue then
				best, bestValue = t, value
			end
		end
	end
	if not best or (bestValue <= 0 and difficulty() == "Impossible") then
		return
	end
	if ctx.launchNuke(p, best, kind) then
		ai.recentNukes[#ai.recentNukes + 1] = { tick = now, tile = best, kind = kind }
		-- Simulated saving for a MIRV: each launch makes the next one feel pricier.
		if kind == "AtomBomb" then
			ai.atomCost *= 1.5
		else
			ai.hydroCost *= 1.25
		end
	end
end

-- Ticks
local function tribeTick(p)
	local ai = p.ai
	ai.scan = scan(p)
	if not ai.started then
		ai.started = true
		B.sendAttack(p, 0) -- first tick: expand
		return
	end
	-- deleteNextStructure: tribes scrap captured structures one by one.
	if next(p.structs) ~= nil then
		ctx.deleteStructure(p)
	end
	local traitor = B.traitorNeighbor(p)
	if traitor then
		local odds = if Diplomacy.allied(p.id, traitor.id) then 6 else 3
		if chance(odds) then
			if Diplomacy.allied(p.id, traitor.id) then
				Diplomacy.breakAlliance(p, traitor, ctx.tick())
			end
			if B.sendAttack(p, traitor.id) then
				return
			end
		end
	end
	if ai.neighborsTN then
		if ai.scan.anyUnowned then
			if B.sendAttack(p, 0) then
				return
			end
		else
			ai.neighborsTN = false
		end
	end
	B.attackRandomTarget(p)
end

local function nationTick(p)
	local ai = p.ai
	ai.scan = scan(p)
	if not ai.started then
		-- forceSendAttack(terraNullius): half the army.
		ai.started = true
		local troops = math.floor(p.troops / 2)
		if troops >= 1 then
			ctx.startLandAttack(p, 0, troops)
		end
		return
	end
	B.embargoes(p)
	if ctx.mirv then
		ctx.mirv(p)
	end
	ctx.build(p)
	ctx.warships(p)
	B.maybeAttack(p)
	B.maybeSendNuke(p)
end

-- NationExecution.randomSpawnLand: random free land within the delta of the map's spawn cell,
-- mountains half as likely.
function AI.nationSpawnTile(cx: number, cy: number): number?
	local map = ctx.map()
	local w, h = map.width, map.height
	local delta = Config.NATION_SPAWN_DELTA
	for _ = 1, 50 do
		local x, y = rng:NextInteger(cx - delta, cx + delta - 1), rng:NextInteger(cy - delta, cy + delta - 1)
		if x >= 0 and x < w and y >= 0 and y < h then
			local t = y * w + x
			if ctx.ownable(t) and ctx.getOwner(t) == 0 then
				local mountain = Config.terrainClass(MapUtil.magnitude(map, t)) == Config.MOUNTAIN
				if not (mountain and chance(2)) then
					return t
				end
			end
		end
	end
	return nil
end

-- Called every tick from GameServer (Spawn and Play phases).
function AI.step(tick: number)
	local phase = ctx.phase()
	if phase == "Spawn" then
		-- Nations hop to a new spot near their cell every attack interval during the spawn phase.
		for _, p in ctx.players() do
			local ai = p.ai
			if ai and p.kind == "Nation" and ai.cellX and p.spawned and tick % ai.rate == ai.offset then
				local t = AI.nationSpawnTile(ai.cellX, ai.cellY)
				if t then
					ctx.unclaimSpawn(p)
					ctx.claimSpawn(p, t)
				end
			end
		end
		return
	end
	if phase ~= "Play" then
		return
	end
	local beachheads = hardPlus()
	for _, p in ctx.players() do
		local ai = p.ai
		if ai and p.alive then
			if beachheads and p.kind == "Nation" and ai.started then
				B.followUpLandings(p)
			end
			local off = tick % ai.rate
			if off == ai.offset then
				if p.kind == "Bot" then
					tribeTick(p)
				else
					nationTick(p)
				end
				ai.scan = nil
			elseif p.kind == "Nation" and ai.started then
				-- Structures twice more between attack ticks (1/3 and 2/3 of the interval).
				local third = (ai.offset + ai.rate // 3) % ai.rate
				local twoThirds = (ai.offset + (ai.rate * 2) // 3) % ai.rate
				if off == third or off == twoThirds then
					ctx.build(p)
				end
			end
		end
	end
end

AI._behaviour = B -- exposed for debugging

return AI
