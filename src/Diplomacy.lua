--[[
	Frontlines (working title) - diplomacy: alliance requests, alliances, traitors, donations.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.Diplomacy (ModuleScript). GameServer calls init() once with hooks into the
-- simulation, reset() per round, step() every Play tick and flush() every tick.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MatchRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchRules"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)

local Diplomacy = {}

local rng = Random.new()
local ctx: any = nil -- { net, players(), feed(text, kind, id), endAttack(a, refund), playerOf(p) }

local alliances: { [number]: any } = {} -- pairKey -> { a, b, expires }
local requests: { [number]: any } = {} -- dirKey(from, to) -> { from, to, expires, renew, aiAnswerAt }
local cooldownUntil: { [number]: number } = {} -- dirKey -> tick
local traitorUntil: { [number]: number } = {} -- player id -> tick
-- Team games (PlayerImpl.isOnSameTeam): player id -> team name. Tribes are on "Bot", which is never
-- a shared team. Teammates count as friendly everywhere Diplomacy.allied is asked.
local teams: { [number]: string } = {}
local teamMode = false
-- Lobby host options donateGold / donateTroops (nil = OpenFront's public rule: team games only).
local donateRule: { gold: boolean?, troops: boolean? } = {}
local dirty = false -- alliance / traitor list changed
local touched: { [number]: boolean } = {} -- player ids whose request lists changed

local KINDS = {
	allyRequest = true,
	allyAccept = true,
	allyDecline = true,
	allyBreak = true,
	donateTroops = true,
	donateGold = true,
}

local function pairKey(a: number, b: number): number
	if a > b then
		a, b = b, a
	end
	return a * 65536 + b
end

local function dirKey(from: number, to: number): number
	return from * 65536 + to
end

local function timeAt(tick: number, at: number): number
	return SimClock.now() + (at - tick) * Config.TICK
end

-- Personal feed line for a human player.
local function notify(p, text: string, kind: string?)
	local plr = ctx.playerOf(p)
	if plr then
		ctx.net:FireClient(plr, "event", { text = text, kind = kind or "ally", owner = p.id })
	end
end

local function touch(a: number, b: number)
	touched[a] = true
	touched[b] = true
end

function Diplomacy.init(hooks)
	ctx = hooks
end

function Diplomacy.reset()
	table.clear(alliances)
	table.clear(requests)
	table.clear(cooldownUntil)
	table.clear(traitorUntil)
	table.clear(touched)
	table.clear(teams)
	teamMode = false
	dirty = true
end

-- Team games ------------------------------------------------------------------------------
function Diplomacy.setTeamMode(on: boolean)
	teamMode = on
end

function Diplomacy.setDonations(gold: boolean?, troops: boolean?)
	donateRule.gold, donateRule.troops = gold, troops
end

function Diplomacy.isTeamMode(): boolean
	return teamMode
end

function Diplomacy.setTeam(id: number, team: string?)
	teams[id] = team
end

function Diplomacy.teamOf(id: number): string?
	return teams[id]
end

function Diplomacy.sameTeam(a: number, b: number): boolean
	if a == b then
		return false
	end
	local ta, tb = teams[a], teams[b]
	return ta ~= nil and ta == tb and ta ~= "Bot"
end

function Diplomacy.handles(kind: string): boolean
	return KINDS[kind] == true
end

function Diplomacy.allied(a: number, b: number): boolean
	if a == b or a == 0 or b == 0 then
		return false
	end
	-- PlayerImpl.isFriendly: allied or on the same team.
	return alliances[pairKey(a, b)] ~= nil or Diplomacy.sameTeam(a, b)
end

function Diplomacy.isTraitor(id: number, tick: number): boolean
	local u = traitorUntil[id]
	return u ~= nil and u > tick
end

local function allyCount(id: number): number
	local n = 0
	for _, al in alliances do
		if al.a == id or al.b == id then
			n += 1
		end
	end
	return n
end

local function stopAttacks(p, q)
	for a in pairs(p.outgoing) do
		if a.target == q.id then
			ctx.endAttack(a, true)
		end
	end
end

local function involvesHuman(p, q): boolean
	return p.kind == "Human" or q.kind == "Human"
end

local function form(p, q, tick: number)
	local k = pairKey(p.id, q.id)
	local al = alliances[k]
	if al then
		al.expires = tick + Config.ALLIANCE_TICKS
		notify(p, "Alliance with " .. q.name .. " renewed")
		notify(q, "Alliance with " .. p.name .. " renewed")
	else
		alliances[k] = { a = p.id, b = q.id, expires = tick + Config.ALLIANCE_TICKS }
		if ctx.onAllianceFormed then
			ctx.onAllianceFormed(p, q)
		end
		-- Allies can't fight: running attacks between them stop and their troops go home.
		stopAttacks(p, q)
		stopAttacks(q, p)
		if involvesHuman(p, q) then
			ctx.feed(p.name .. " and " .. q.name .. " formed an alliance", "ally", p.id)
		end
	end
	dirty = true
end

-- p accepts q's request.
function Diplomacy.accept(p, q, tick: number): boolean
	local k = dirKey(q.id, p.id)
	if not requests[k] or MatchRules.alliancesOff() then
		return false
	end
	requests[k] = nil
	touch(p.id, q.id)
	if not p.alive or not q.alive then
		return false
	end
	form(q, p, tick)
	return true
end

-- p declines q's request.
function Diplomacy.decline(p, q)
	local k = dirKey(q.id, p.id)
	if not requests[k] then
		return
	end
	requests[k] = nil
	touch(p.id, q.id)
	notify(q, p.name .. " declined your alliance request")
end

-- p asks q for an alliance (or a renewal of the current one).
function Diplomacy.request(p, q, tick: number): boolean
	if p == q or p.kind == "Bot" or not p.alive or not q.alive then
		return false
	end
	if MatchRules.alliancesOff() then
		return false -- disableAlliances ("Alliances Disabled")
	end
	-- Tribes accept every request (OpenFront TribeExecution); nobody can ally a disconnected player.
	if p.disconnected or q.disconnected then
		return false
	end
	if Diplomacy.sameTeam(p.id, q.id) then
		return false -- teammates are already friendly
	end
	local al = alliances[pairKey(p.id, q.id)]
	if al and al.expires - tick > Config.ALLIANCE_RENEW_TICKS then
		return false -- too early to renew
	end
	-- Asking someone who already asked us is an acceptance.
	if requests[dirKey(q.id, p.id)] then
		return Diplomacy.accept(p, q, tick)
	end
	local k = dirKey(p.id, q.id)
	if requests[k] or (cooldownUntil[k] or 0) > tick then
		return false
	end
	local r = { from = p.id, to = q.id, expires = tick + Config.ALLIANCE_REQUEST_TICKS, renew = al ~= nil }
	if q.kind ~= "Human" then
		r.aiAnswerAt = tick + rng:NextInteger(10, 40)
	end
	requests[k] = r
	cooldownUntil[k] = tick + Config.ALLIANCE_REQUEST_COOLDOWN
	touch(p.id, q.id)
	if q.kind == "Human" then
		notify(q, p.name .. (if al then " wants to renew your alliance" else " requests an alliance"))
	end
	return true
end

-- p breaks its alliance with q and becomes a traitor.
function Diplomacy.breakAlliance(p, q, tick: number): boolean
	local k = pairKey(p.id, q.id)
	if not alliances[k] then
		return false
	end
	alliances[k] = nil
	requests[dirKey(p.id, q.id)] = nil
	requests[dirKey(q.id, p.id)] = nil
	touch(p.id, q.id)
	if ctx.onAllianceBroken then
		ctx.onAllianceBroken(p, q)
	end
	-- OpenFront BrokeAllianceUpdate: the betrayed player's screen flashes red (AlertFrame).
	local victim = ctx.playerOf(q)
	if victim then
		ctx.net:FireClient(victim, "betrayed", p.id)
	end
	-- OpenFront: leaving a traitor or a disconnected ally is not a betrayal.
	if Diplomacy.isTraitor(q.id, tick) or q.disconnected then
		ctx.feed("The alliance between " .. p.name .. " and " .. q.name .. " ended", "ally", p.id)
		dirty = true
		return true
	end
	traitorUntil[p.id] = tick + Config.TRAITOR_TICKS
	dirty = true
	ctx.feed(p.name .. " betrayed " .. q.name .. " and is now a traitor", "traitor", p.id)
	return true
end

-- Nation answering a request from `from`.
local function nationAccepts(nation, from, renew: boolean, tick: number): boolean
	if ctx.aiAnswer then
		-- OpenFront nation/tribe alliance behaviour (AiBehavior.allianceAnswer).
		return ctx.aiAnswer(nation, from, renew, tick)
	end
	if Diplomacy.isTraitor(from.id, tick) and rng:NextNumber() < 0.8 then
		return false
	end
	if renew then
		-- A nation that has outgrown its ally might let the alliance lapse.
		return nation.troops < from.troops * Config.NATION_BETRAY_RATIO or rng:NextNumber() < 0.5
	end
	if allyCount(nation.id) >= Config.NATION_MAX_ALLIES then
		return false
	end
	return from.troops >= nation.troops * 0.6 or rng:NextNumber() < 0.25
end

-- Called from the nation AI with the set of neighbouring player ids. Returns nothing.
function Diplomacy.aiThink(p, neighbors: { [number]: boolean }, tick: number)
	if p.kind ~= "Nation" then
		return
	end
	local players = ctx.players()
	-- Betray an ally that has become much weaker, now and then.
	for id in pairs(neighbors) do
		local o = players[id]
		if o and o.alive and Diplomacy.allied(p.id, id) then
			if p.troops > o.troops * Config.NATION_BETRAY_RATIO and p.tiles > o.tiles and rng:NextNumber() < 0.04 then
				Diplomacy.breakAlliance(p, o, tick)
				return
			end
		end
	end
	-- Ask to renew alliances that are about to run out.
	for _, al in alliances do
		if (al.a == p.id or al.b == p.id) and al.expires - tick <= Config.ALLIANCE_RENEW_TICKS then
			local o = players[if al.a == p.id then al.b else al.a]
			if o and p.troops < o.troops * Config.NATION_BETRAY_RATIO and rng:NextNumber() < 0.5 then
				Diplomacy.request(p, o, tick)
			end
		end
	end
	-- Occasionally court a strong neighbour.
	if rng:NextNumber() < 0.06 and allyCount(p.id) < Config.NATION_MAX_ALLIES then
		local best = nil
		for id in pairs(neighbors) do
			local o = players[id]
			if
				o
				and o.alive
				and o.kind ~= "Bot"
				and not Diplomacy.allied(p.id, id)
				and not Diplomacy.isTraitor(id, tick)
				and o.troops >= p.troops * 0.8
				and (best == nil or o.troops > best.troops)
			then
				best = o
			end
		end
		if best then
			Diplomacy.request(p, best, tick)
		end
	end
end

function Diplomacy.step(tick: number)
	local players = ctx.players()
	for k, r in requests do
		local from, to = players[r.from], players[r.to]
		if not from or not to or not from.alive or not to.alive or tick >= r.expires then
			requests[k] = nil
			touch(r.from, r.to)
		elseif r.aiAnswerAt and tick >= r.aiAnswerAt then
			r.aiAnswerAt = nil
			if nationAccepts(to, from, r.renew, tick) then
				Diplomacy.accept(to, from, tick)
			else
				Diplomacy.decline(to, from)
			end
		end
	end
	for k, al in alliances do
		local a, b = players[al.a], players[al.b]
		if not a or not b or not a.alive or not b.alive then
			alliances[k] = nil
			dirty = true
		elseif tick >= al.expires then
			alliances[k] = nil
			dirty = true
			if involvesHuman(a, b) then
				ctx.feed("The alliance between " .. a.name .. " and " .. b.name .. " expired", "ally", a.id)
			end
		end
	end
	for id, u in traitorUntil do
		if u <= tick then
			traitorUntil[id] = nil
			dirty = true
		end
	end
end

local function diplomacyPayload(tick: number)
	local list = {}
	for _, al in alliances do
		list[#list + 1] = { al.a, al.b, timeAt(tick, al.expires) }
	end
	local traitors = {}
	for id, u in traitorUntil do
		if u > tick then
			traitors[#traitors + 1] = { id, timeAt(tick, u) }
		end
	end
	return { alliances = list, traitors = traitors }
end

local function requestsPayload(id: number, tick: number)
	local incoming, outgoing = {}, {}
	for _, r in requests do
		if r.to == id then
			incoming[#incoming + 1] = { r.from, timeAt(tick, r.expires), r.renew }
		elseif r.from == id then
			outgoing[#outgoing + 1] = { r.to, timeAt(tick, r.expires), r.renew }
		end
	end
	return { incoming = incoming, outgoing = outgoing }
end

-- Sends what changed since the last call.
function Diplomacy.flush(tick: number)
	if dirty then
		dirty = false
		ctx.net:FireAllClients("diplomacy", diplomacyPayload(tick))
	end
	if next(touched) then
		local players = ctx.players()
		for id in touched do
			local p = players and players[id]
			local plr = p and ctx.playerOf(p)
			if plr then
				ctx.net:FireClient(plr, "allyRequests", requestsPayload(id, tick))
			end
		end
		table.clear(touched)
	end
end

-- Full state for a (re)joining client; call right after its "init".
function Diplomacy.sendInit(plr: Player, p, tick: number)
	ctx.net:FireClient(plr, "diplomacy", diplomacyPayload(tick))
	ctx.net:FireClient(plr, "allyRequests", requestsPayload(if p then p.id else 0, tick))
end

-- Client request: kind is one of KINDS, targetId a player id, arg the attack ratio for donations.
function Diplomacy.handle(p, kind: string, targetId: number, arg: any, tick: number)
	local players = ctx.players()
	local q = players[targetId]
	if not q or q == p or not p.alive or not q.alive then
		return
	end
	if kind == "allyRequest" then
		Diplomacy.request(p, q, tick)
	elseif kind == "allyAccept" then
		Diplomacy.accept(p, q, tick)
	elseif kind == "allyDecline" then
		Diplomacy.decline(p, q)
	elseif kind == "allyBreak" then
		Diplomacy.breakAlliance(p, q, tick)
	elseif kind == "donateTroops" or kind == "donateGold" then
		-- OpenFront DonateTroopExecution / DonateGoldExecution (rules_core).
		if not Diplomacy.allied(p.id, q.id) or (arg ~= nil and (typeof(arg) ~= "number" or arg ~= arg)) then
			return
		end
		-- canDonateGold / canDonateTroops: public FFA games turn donations to humans off
		-- (donateGold / donateTroops are only on in team games).
		local allowed = teamMode
		local rule = if kind == "donateGold" then donateRule.gold else donateRule.troops
		if rule ~= nil then
			allowed = rule
		end
		if q.kind == "Human" and not allowed then
			return
		end
		-- canDonate*: one donation per recipient every DONATE_COOLDOWN ticks (troops and gold share it).
		p.donatedAt = p.donatedAt or {}
		if p.donatedAt[q.id] and tick - p.donatedAt[q.id] < Config.DONATE_COOLDOWN then
			return
		end
		-- The ratio comes from the attack-ratio slider; without one, OpenFront's default third.
		local ratio = if arg == nil then 1 / 3 else math.clamp(arg, 0.01, 1)
		if kind == "donateTroops" then
			-- Capped at what the ally can still hold (maxTroops - troops).
			local room = math.max(0, math.floor(q.maxTroops - q.troops))
			local amount = math.min(math.floor(p.troops * ratio), room)
			if amount < 1 then
				return
			end
			p.troops -= amount
			q.troops += amount
			p.donatedAt[q.id] = tick
			if ctx.onDonate then
				ctx.onDonate(p, q, "troops", amount, tick)
			end
			notify(p, string.format("Sent %s troops to %s", Config.renderTroops(amount), q.name))
			notify(q, string.format("Received %s troops from %s", Config.renderTroops(amount), p.name))
		else
			local amount = math.floor(p.gold * ratio)
			if amount < 1 then
				return
			end
			p.gold -= amount
			q.gold += amount
			p.donatedAt[q.id] = tick
			if ctx.onDonate then
				ctx.onDonate(p, q, "gold", amount, tick)
			end
			notify(p, string.format("Sent %s gold to %s", Config.renderNumber(amount), q.name))
			notify(q, string.format("Received %s gold from %s", Config.renderNumber(amount), p.name))
		end
	end
end

return Diplomacy
