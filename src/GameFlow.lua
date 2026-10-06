--[[
	War Front - game flow rules: spawn immunity, win check, embargoes, targets, quick chat,
	disconnected players, nation relations and per-match stats.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.GameFlow (ModuleScript), driven by GameServer.
--
-- Rules follow OpenFront's WinCheckExecution, PlayerImpl.isImmune/canAttackPlayer, EmbargoExecution,
-- EmbargoAllExecution, TargetPlayerExecution, QuickChatExecution, MarkDisconnectedExecution,
-- PlayerImpl relations (relation()/updateRelation()/decayRelations()) and StatsImpl.
--
-- Client -> server kinds (handled here):
--   "embargo"   (playerId, on: boolean)        playerId 0 = everyone (EmbargoAllExecution, 10 s cooldown)
--   "target"    (playerId)                     mark a player as target for 10 s (15 s cooldown)
--   "quickChat" (recipientId, phraseKey, targetId?)  phraseKey "<category>.<key>" (Shared.QuickChat)
-- Server -> client kinds:
--   "quickChat"  (to sender and recipient) { from, to, key, target }  target = [P1] player id or 0
--   "matchStats" (personal, at round end)  see Flow.statsFor
--   "event"      (allies of a targeter)     "<name> requests you attack <target>" (kind "target")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local QuickChat = require(Shared:WaitForChild("QuickChat"))

local Flow = {}

local ctx: any = nil
-- ctx = { net, players(), tick(), phase(), roundStartTick(), landTiles(), fallout() -> buffer,
--         size() -> number, playerOf(p), allied(a, b), decline(p, q) }


local embargoes: { [number]: { [number]: { created: number, temp: boolean } } } = {}
local lastEmbargoAll: { [number]: number } = {}
local targets: { [number]: { { tick: number, id: number } } } = {}
local quickChatAt: { [number]: { [number]: number } } = {}
local relations: { [number]: { [number]: { v: number, t: number } } } = {}
local stats: { [number]: any } = {}

-- Fallout count, recounted a slice per tick (numTilesWithFallout for the win check).
local falloutCount = 0
local falloutScan = 0
local falloutPartial = 0

local KINDS = { embargo = true, target = true, quickChat = true }

function Flow.init(hooks)
	ctx = hooks
end

function Flow.reset()
	table.clear(embargoes)
	table.clear(lastEmbargoAll)
	table.clear(targets)
	table.clear(quickChatAt)
	table.clear(relations)
	table.clear(stats)
	falloutCount, falloutScan, falloutPartial = 0, 0, 0
end

local function isBot(p): boolean
	return p.kind == "Bot"
end

-- Roster field 9 (shared contract): "human" | "nation" | "tribe".
function Flow.kindName(kind: string): string
	return if kind == "Human" then "human" elseif kind == "Nation" then "nation" else "tribe"
end

--------------------------------------------------------------------------------
-- Disconnected players (MarkDisconnectedExecution)
--------------------------------------------------------------------------------
-- A human who leaves stays on the map (land, troops, structures) but is "disconnected":
-- allies no longer count as friendly (they may attack without betraying), alliance requests
-- to/from them are refused, and nations treat them as easy ("afk") targets.
function Flow.setDisconnected(p, on: boolean)
	if p and p.kind == "Human" then
		p.disconnected = on or nil
	end
end

--------------------------------------------------------------------------------
-- Friendliness and spawn immunity
--------------------------------------------------------------------------------
-- PlayerImpl.isFriendly: allied, unless the other player is disconnected.
function Flow.isFriendly(p, otherId: number): boolean
	if otherId == 0 or otherId == p.id then
		return otherId == p.id
	end
	local q = ctx.players()[otherId]
	if not q or q.disconnected then
		return false
	end
	return ctx.allied(p.id, otherId)
end

local function immunityTicksLeft(): number
	local phase = ctx.phase()
	if phase == "Spawn" then
		return Config.SPAWN_IMMUNITY_TICKS -- isSpawnImmunityActive() is true for the whole spawn phase
	elseif phase ~= "Play" then
		return 0
	end
	return math.max(0, ctx.roundStartTick() + Config.SPAWN_IMMUNITY_TICKS - ctx.tick())
end

-- PlayerImpl.isImmune: humans and nations are immune during the spawn phase and the first
-- SPAWN_IMMUNITY_TICKS after it; tribes never are.
function Flow.isImmune(q): boolean
	if q.kind == "Bot" then
		return false
	end
	return ctx.phase() == "Spawn" or immunityTicksLeft() > 0
end

-- PlayerImpl.canAttackPlayer: never a friendly player; only HUMAN attackers respect immunity.
function Flow.canAttackPlayer(p, targetId: number): boolean
	if targetId == 0 then
		return true
	end
	if Flow.isFriendly(p, targetId) then
		return false
	end
	local q = ctx.players()[targetId]
	if q and p.kind == "Human" and Flow.isImmune(q) then
		return false
	end
	return true
end

-- PlayerImpl.nukeSpawn: no nukes at all while spawn immunity is active.
function Flow.nukesBlocked(): boolean
	return ctx.phase() ~= "Play" or immunityTicksLeft() > 0
end

-- `me.immunityEndsIn` (seconds). During the spawn phase this counts the rest of the spawn
-- phase plus the immunity that follows it.
function Flow.immunityLeft(p, spawnTicksLeft: number): number
	if not p or p.kind == "Bot" then
		return 0
	end
	local phase = ctx.phase()
	if phase == "Spawn" then
		return (spawnTicksLeft + Config.SPAWN_IMMUNITY_TICKS) * Config.TICK
	end
	return immunityTicksLeft() * Config.TICK
end

function Flow.immunitySeconds(): number
	return Config.SPAWN_IMMUNITY_TICKS * Config.TICK
end

--------------------------------------------------------------------------------
-- Relations (only nations act on them; PlayerImpl.relation / updateRelation / decayRelations)
--------------------------------------------------------------------------------
-- Values run -100..100 and decay 0.05 per tick toward 0 (applied lazily here).
-- Hostile < -50 <= Distrustful < 0 <= Neutral < 50 <= Friendly.
Flow.HOSTILE, Flow.DISTRUSTFUL, Flow.NEUTRAL, Flow.FRIENDLY = 0, 1, 2, 3

local function relEntry(holderId: number, otherId: number)
	local m = relations[holderId]
	local e = m and m[otherId]
	if not e then
		return nil
	end
	local now = ctx.tick()
	local dt = now - e.t
	if dt > 0 then
		local mag = math.abs(e.v) - 0.05 * dt
		e.v = if mag < 0.1 then 0 else math.sign(e.v) * mag
		e.t = now
	end
	return e
end

function Flow.relationValue(holder, otherId: number): number
	local e = relEntry(holder.id, otherId)
	return if e then e.v else 0
end

function Flow.relation(holder, otherId: number): number
	local v = Flow.relationValue(holder, otherId)
	if v < -50 then
		return Flow.HOSTILE
	elseif v < 0 then
		return Flow.DISTRUSTFUL
	elseif v < 50 then
		return Flow.NEUTRAL
	end
	return Flow.FRIENDLY
end

function Flow.updateRelation(holder, otherId: number, delta: number)
	if not holder or holder.kind ~= "Nation" or otherId == holder.id or otherId == 0 then
		return
	end
	local m = relations[holder.id]
	if not m then
		m = {}
		relations[holder.id] = m
	end
	local e = relEntry(holder.id, otherId)
	if not e then
		e = { v = 0, t = ctx.tick() }
		m[otherId] = e
	end
	e.v = math.clamp(e.v + delta, -100, 100)
end

-- allRelationsSorted(): living players, worst relation first.
function Flow.relationsSorted(holder): { any }
	local list = {}
	local m = relations[holder.id]
	if not m then
		return list
	end
	local players = ctx.players()
	for id in m do
		local q = players[id]
		if q and q.alive then
			list[#list + 1] = { id = id, value = Flow.relationValue(holder, id) }
		end
	end
	table.sort(list, function(a, b)
		return a.value < b.value
	end)
	for _, r in list do
		r.relation = Flow.relation(holder, r.id)
	end
	return list
end

local ATTACK_RELATION = { Easy = -60, Medium = -70, Hard = -80, Impossible = -100 }

--------------------------------------------------------------------------------
-- Embargoes (EmbargoExecution / EmbargoAllExecution / temporary embargoes)
--------------------------------------------------------------------------------
function Flow.hasEmbargoAgainst(aId: number, bId: number): boolean
	local m = embargoes[aId]
	return m ~= nil and m[bId] ~= nil
end

-- PlayerImpl.canTrade: no embargo in either direction.
function Flow.canTrade(aId: number, bId: number): boolean
	if aId == bId then
		return false
	end
	return not Flow.hasEmbargoAgainst(aId, bId) and not Flow.hasEmbargoAgainst(bId, aId)
end

function Flow.addEmbargo(p, otherId: number, temporary: boolean)
	local m = embargoes[p.id]
	if not m then
		m = {}
		embargoes[p.id] = m
	end
	local e = m[otherId]
	if e and not e.temp then
		return -- a manual embargo is never downgraded
	end
	m[otherId] = { created = ctx.tick(), temp = temporary }
end

function Flow.stopEmbargo(p, otherId: number)
	local m = embargoes[p.id]
	if m then
		m[otherId] = nil
	end
end

-- Alliance formed: embargoes that were created automatically end (AllianceRequestExecution).
function Flow.endTemporaryEmbargo(p, otherId: number)
	local m = embargoes[p.id]
	local e = m and m[otherId]
	if e and e.temp then
		m[otherId] = nil
	end
end

function Flow.embargoList(p): { number }
	local list = {}
	local m = embargoes[p.id]
	if m then
		for id in m do
			list[#list + 1] = id
		end
	end
	return list
end

function Flow.embargoedBy(p): { number }
	local list = {}
	for id, m in embargoes do
		if m[p.id] then
			list[#list + 1] = id
		end
	end
	return list
end

local function embargoAll(p, on: boolean): boolean
	local now = ctx.tick()
	if lastEmbargoAll[p.id] and now - lastEmbargoAll[p.id] < Config.EMBARGO_ALL_COOLDOWN_TICKS then
		return false
	end
	local any = false
	for id, q in ctx.players() do
		if id ~= p.id and q.alive and not isBot(q) then
			any = true
			if on then
				if not Flow.hasEmbargoAgainst(p.id, id) then
					Flow.addEmbargo(p, id, false)
				end
			else
				Flow.stopEmbargo(p, id)
			end
		end
	end
	if any then
		lastEmbargoAll[p.id] = now
	end
	return any
end

--------------------------------------------------------------------------------
-- Targets (TargetPlayerExecution)
--------------------------------------------------------------------------------
function Flow.canTarget(p, otherId: number): boolean
	if otherId == p.id or Flow.isFriendly(p, otherId) then
		return false
	end
	local now = ctx.tick()
	for _, t in targets[p.id] or {} do
		if now - t.tick < Config.TARGET_COOLDOWN_TICKS then
			return false
		end
	end
	return true
end

-- targets(): players this player targeted in the last TARGET_DURATION_TICKS.
function Flow.targetsOf(id: number): { number }
	local list = {}
	local now = ctx.tick()
	for _, t in targets[id] or {} do
		if now - t.tick < Config.TARGET_DURATION_TICKS and not table.find(list, t.id) then
			list[#list + 1] = t.id
		end
	end
	return list
end

-- transitiveTargets(): my targets plus my allies' (what the target icon on name labels shows).
function Flow.transitiveTargets(p): { number }
	local list = Flow.targetsOf(p.id)
	for id, q in ctx.players() do
		if id ~= p.id and q.alive and ctx.allied(p.id, id) then
			for _, t in Flow.targetsOf(id) do
				if not table.find(list, t) then
					list[#list + 1] = t
				end
			end
		end
	end
	return list
end

local function doTarget(p, otherId: number)
	local players = ctx.players()
	local q = players[otherId]
	if not q or not q.alive or not Flow.canTarget(p, otherId) then
		return
	end
	local list = targets[p.id]
	if not list then
		list = {}
		targets[p.id] = list
	end
	list[#list + 1] = { tick = ctx.tick(), id = otherId }
	if #list > 8 then
		table.remove(list, 1)
	end
	Flow.updateRelation(q, p.id, -40)
	-- EventsDisplay.onTargetPlayerEvent: friendly players see the request.
	for id, ally in players do
		if id ~= p.id and ally.alive and Flow.isFriendly(ally, p.id) then
			local plr = ctx.playerOf(ally)
			if plr then
				ctx.net:FireClient(plr, "event", {
					text = p.name .. " requests you attack " .. q.name,
					kind = "target",
					owner = otherId,
				})
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Quick chat (QuickChatExecution)
--------------------------------------------------------------------------------
local function quickChat(p, toId: number, key: any, targetId: any)
	if typeof(key) ~= "string" or toId == p.id then
		return
	end
	local phrase = QuickChat.BY_KEY[key]
	local to = ctx.players()[toId]
	if not phrase or not to then
		return
	end
	local target = 0
	if phrase.requiresPlayer then
		if typeof(targetId) ~= "number" or targetId ~= targetId then
			return
		end
		target = math.floor(targetId)
		if not ctx.players()[target] then
			return
		end
	end
	local sent = quickChatAt[p.id]
	if not sent then
		sent = {}
		quickChatAt[p.id] = sent
	end
	local now = ctx.tick()
	if sent[toId] and now - sent[toId] < QuickChat.COOLDOWN_TICKS then
		return
	end
	sent[toId] = now
	local payload = { from = p.id, to = toId, key = key, target = target }
	local a, b = ctx.playerOf(p), ctx.playerOf(to)
	if a then
		ctx.net:FireClient(a, "quickChat", payload)
	end
	if b and b ~= a then
		ctx.net:FireClient(b, "quickChat", payload)
	end
end

--------------------------------------------------------------------------------
-- Client requests
--------------------------------------------------------------------------------
function Flow.handles(kind: string): boolean
	return KINDS[kind] == true
end

-- All three are inactive during the spawn phase in OpenFront (activeDuringSpawnPhase() false).
function Flow.handle(p, kind: string, id: number, a2: any, a3: any)
	if ctx.phase() ~= "Play" or not p.alive then
		return
	end
	if kind == "embargo" then
		local on = a2 == true
		if id == 0 then
			embargoAll(p, on)
			return
		end
		local q = ctx.players()[id]
		if not q or id == p.id then
			return
		end
		if on then
			Flow.addEmbargo(p, id, false)
		else
			Flow.stopEmbargo(p, id)
		end
	elseif kind == "target" then
		doTarget(p, id)
	elseif kind == "quickChat" then
		quickChat(p, id, a2, a3)
	end
end

--------------------------------------------------------------------------------
-- Attack hook (AttackExecution.init)
--------------------------------------------------------------------------------
-- Called when p starts (or reinforces) an attack on a player. Non-bot targets embargo non-bot
-- attackers for 5 minutes, the attacker turns down a pending alliance request from the target,
-- and the target's relation to the attacker drops by the difficulty's amount.
function Flow.onAttack(p, targetId: number)
	if targetId == 0 then
		return
	end
	local q = ctx.players()[targetId]
	if not q then
		return
	end
	if not isBot(p) and not isBot(q) then
		Flow.addEmbargo(q, p.id, true)
		ctx.decline(p, q)
	end
	Flow.updateRelation(q, p.id, ATTACK_RELATION[Config.NATION_DIFFICULTY] or -70)
	Flow.stat(p, "attacksSent", 1)
	Flow.stat(q, "attacksReceived", 1)
end

--------------------------------------------------------------------------------
-- Per-tick upkeep
--------------------------------------------------------------------------------
function Flow.step()
	local now = ctx.tick()
	-- Temporary embargoes expire (PlayerExecution).
	for _, m in embargoes do
		for id, e in m do
			if e.temp and now - e.created > Config.TEMP_EMBARGO_TICKS then
				m[id] = nil
			end
		end
	end
	-- Recount fallout in slices: a full pass every 10 ticks.
	local size = ctx.size()
	local buf = ctx.fallout()
	local chunk = math.ceil(size / 10)
	local stop = math.min(size, falloutScan + chunk)
	local n = falloutPartial
	for t = falloutScan, stop - 1 do
		if buffer.readu8(buf, t) == 1 then
			n += 1
		end
	end
	if stop >= size then
		falloutCount, falloutScan, falloutPartial = n, 0, 0
	else
		falloutScan, falloutPartial = stop, n
	end
end

function Flow.falloutTiles(): number
	return falloutCount
end

--------------------------------------------------------------------------------
-- Win check (WinCheckExecution, FFA)
--------------------------------------------------------------------------------
local function elapsedSeconds(): number
	if ctx.phase() ~= "Play" and ctx.phase() ~= "Ended" then
		return 0
	end
	return (ctx.tick() - ctx.roundStartTick()) * Config.TICK
end

-- Config.percentageTilesOwnedToWin: 80 %, minus 2 whole points per minute after 30 minutes when
-- overtime is on (every public FFA game; MatchRules.overtime), no floor.
function Flow.winPercent(): number
	local base = math.floor(Config.WIN_FRACTION * 100 + 0.5)
	local past = math.floor(elapsedSeconds()) - Config.OVERTIME_START_MINUTES * 60
	if past <= 0 or not MatchRules.get().overtime then
		return base
	end
	return math.max(0, base - math.floor(past * Config.OVERTIME_DROP_PER_MINUTE / 60))
end

-- Land the win share is taken of (non-fallout land), and whether the hard time limit is reached.
function Flow.winLand(): number
	return ctx.landTiles() - falloutCount
end

function Flow.timeUp(): boolean
	return elapsedSeconds() >= Config.HARD_TIME_LIMIT_SECONDS
end

-- Returns the winner (or nil) and whether no human is connected any more.
function Flow.checkWin()
	local leader, humans = nil, 0
	for _, p in ctx.players() do
		if p.alive and p.tiles > 0 and (leader == nil or p.tiles > leader.tiles) then
			leader = p
		end
		if p.kind == "Human" and ctx.playerOf(p) then
			humans += 1
		end
	end
	if leader then
		if elapsedSeconds() >= Config.HARD_TIME_LIMIT_SECONDS then
			return leader, humans == 0
		end
		local land = ctx.landTiles() - falloutCount
		-- Cross-multiplied like OpenFront: strictly more than the share.
		if leader.tiles * 100 > land * Flow.winPercent() then
			return leader, humans == 0
		end
	end
	return nil, humans == 0
end

--------------------------------------------------------------------------------
-- Per-match stats (StatsImpl subset)
--------------------------------------------------------------------------------
local function statsOf(p)
	local s = stats[p.id]
	if not s then
		s = {
			attacksSent = 0, -- attacks launched (land + landings)
			attacksReceived = 0,
			troopsSent = 0,
			boatsSent = 0,
			bombsLaunched = 0,
			built = {}, -- structure kind -> count
			kills = 0,
			goldWar = 0, -- gold taken from eliminated players
			spawnTile = -1,
			deathSeconds = -1,
		}
		stats[p.id] = s
	end
	return s
end

function Flow.stat(p, key: string, amount: number)
	if not p then
		return
	end
	local s = statsOf(p)
	if type(s[key]) == "number" then
		s[key] += amount
	end
end

function Flow.noteBuild(p, kind: string)
	if p then
		local b = statsOf(p).built
		b[kind] = (b[kind] or 0) + 1
	end
end

function Flow.noteSpawn(p, tile: number)
	if p then
		statsOf(p).spawnTile = tile
	end
end

function Flow.noteKill(killer, victim, gold: number)
	if killer then
		local s = statsOf(killer)
		s.kills += 1
		s.goldWar += gold
	end
	if victim then
		statsOf(victim).deathSeconds = math.floor(elapsedSeconds())
	end
end

-- Stats table for one player at round end (also the "matchStats" payload).
function Flow.statsFor(p, placement: number?)
	local s = statsOf(p)
	return {
		placement = placement or 0,
		peakTiles = p.peakTiles,
		finalTiles = p.tiles,
		peakPercent = p.peakTiles / math.max(1, ctx.landTiles()) * 100,
		seconds = math.floor(elapsedSeconds()),
		attacksSent = s.attacksSent,
		attacksReceived = s.attacksReceived,
		troopsSent = math.floor(s.troopsSent),
		boatsSent = s.boatsSent,
		bombsLaunched = s.bombsLaunched,
		built = s.built,
		kills = s.kills,
		goldWar = math.floor(s.goldWar),
		deathSeconds = s.deathSeconds,
	}
end

return Flow
