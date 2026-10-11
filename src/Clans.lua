--[[
	War Front - clans: create, join (open or by request), roles, clan tag on names, clan stats and
	the clan leaderboard.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.Clans (ModuleScript), started by GameServer.
-- DataStore "WF_Clans_v1":
--   "c_<TAG>"  clan { tag, name, desc, open, leader, created, wins, games,
--                     members = { ["<userId>"] = { r = "leader" | "officer" | "member", n = name, j = time } },
--                     requests = { ["<userId>"] = { n = name, t = time } } }
--   "u_<userId>" -> TAG of the player's clan (the membership index; the clan record decides)
--   "index"    { [TAG] = { n = name, m = members, o = open, w = wins, g = games } } for browsing
--              and the clan leaderboard
-- MessagingService "WFClans" { u = userId, t = TAG | false } tells other servers a player's clan
-- changed (accepted, kicked) so their name tag updates without rejoining; { c = TAG } says a clan
-- changed (Shared.ClanEvent "changed" to every client, so Clans pages refresh live).
-- Client -> server: Shared.ClanFn (RemoteFunction) :InvokeServer(op, arg) -> ok, result | message
--   "me"                     { clan = view?, role?, medals, tokens, cost, charterId, max }
--   "view", TAG              view of any clan (requests only for its officers)
--   "list", query?           up to 100 clans, most wins first, filtered by tag/name
--   "create", { name, tag, desc, open, pay = "medals" | "charter" }
--   "join", TAG              open clan: join; otherwise send a request
--   "cancel", TAG            withdraw a request
--   "accept" / "decline", userId        officers
--   "kick", userId                      officers kick members, the leader anyone
--   "promote" / "demote", userId        leader: member <-> officer
--   "transfer", userId                  leader hands over leadership
--   "leave"                  (the leader must transfer first; a lone leader disbands the clan)
--   "settings", { desc, open }          leader
-- Clans.init(ctx)          ctx: progression, onTagChanged(plr, tag?)
-- Clans.load(plr)          on join: finds the player's clan (background)
-- Clans.forget(plr)
-- Clans.tagOf(plr) -> TAG?
-- Clans.display(plr, name) -> "[TAG] name" or name
-- Clans.roundEnded(results)  clan games / wins (one game per clan per round)

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))

local Clans = {}

local CFG = MetaConfig.CLAN
local TOPIC = "WFClans"

local store
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("WF_Clans_v1" .. (if RunService:IsStudio() then "_Studio" else ""))
	end)
	store = if ok then result else nil
end

local ctx: any = {}
local userTag: { [number]: string } = {} -- online players' clan tags
local busy: { [Player]: boolean } = {}
local indexCache = { at = -math.huge, data = {} :: { [string]: any } }

local fn = Shared:FindFirstChild("ClanFn") or Instance.new("RemoteFunction")
fn.Name = "ClanFn"
fn.Parent = Shared

-- Live updates: Shared.ClanEvent ("changed", TAG) goes to every player on every server whenever a
-- clan changes (members, roles, requests, settings, wins), so open Clans pages and the clan
-- leaderboard refresh by themselves. Other servers hear it through MessagingService { c = TAG },
-- which also drops their cached index.
local clanEvent = Shared:FindFirstChild("ClanEvent") or Instance.new("RemoteEvent")
clanEvent.Name = "ClanEvent"
clanEvent.Parent = Shared

local function clanChanged(tag: string)
	indexCache.at = -math.huge
	clanEvent:FireAllClients("changed", tag)
	task.spawn(pcall, function()
		MessagingService:PublishAsync(TOPIC, { c = tag })
	end)
end

local function now(): number
	return os.time()
end

local function get(key: string): any
	if not store then
		return nil
	end
	local ok, v = pcall(function()
		return store:GetAsync(key)
	end)
	return if ok then v else nil, ok
end

-- UpdateAsync with a callback that may refuse (return nil + reason). Returns ok, newValue | reason.
local function update(key: string, f: (any) -> (any, string?)): (boolean, any)
	if not store then
		return false, "Clans can't be saved right now."
	end
	local reason
	local ok, result = pcall(function()
		return store:UpdateAsync(key, function(old)
			local new, why = f(old)
			reason = why
			return new
		end)
	end)
	if not ok then
		return false, "Couldn't reach the clan servers, try again."
	end
	if reason then
		return false, reason
	end
	return true, result
end

-- u_<uid> is the authority for membership. Legacy string indexes remain readable.
local function membershipTag(value)
 return if type(value) == "string" then value elseif type(value) == "table" then value.tag else nil
end
local function claimMembership(uid, tag)
 local token = HttpService:GenerateGUID(false)
 local ok, value = update("u_" .. uid, function(old)
  if type(old) == "table" and old.claim == token then return old end
  if membershipTag(old) then return nil, "That player already has a clan or a pending membership." end
  return { tag=tag, claim=token, phase="pending", at=now() }
 end)
 return ok, if ok then token else value
end
local function commitMembership(uid, tag, token)
 return update("u_" .. uid, function(old)
  if type(old) ~= "table" or old.claim ~= token or old.tag ~= tag then
   return nil, "Membership changed while this request was running."
  end
  local out = table.clone(old); out.phase = "committed"; return out
 end)
end
local function clearMembership(uid, tag, token)
 return update("u_" .. uid, function(old)
  if membershipTag(old) ~= tag or (token and (type(old) ~= "table" or old.claim ~= token)) then
   return nil, "Membership has already changed."
  end
  return false -- UpdateAsync nil cancels; false durably represents no clan.
 end)
end

local function setLocal(uid: number, tag: string?)
	if userTag[uid] == tag then
		return
	end
	userTag[uid] = tag
	local plr = Players:GetPlayerByUserId(uid)
	if plr and ctx.onTagChanged then
		task.spawn(ctx.onTagChanged, plr, tag)
	end
end

-- Tell every server (this one included) that a player's clan changed.
local function announce(uid: number, tag: string?)
	setLocal(uid, tag)
	task.spawn(pcall, function()
		MessagingService:PublishAsync(TOPIC, { u = uid, t = tag or false })
	end)
end

local function memberCount(rec): number
	local n = 0
	for _ in rec.members do
		n += 1
	end
	return n
end

local function indexEntry(rec)
	return { n = rec.name, m = memberCount(rec), o = rec.open == true, w = rec.wins or 0, g = rec.games or 0 }
end

local function setIndex(tag: string, entry: any?)
	update("index", function(old)
		local idx = if type(old) == "table" then old else {}
		idx[tag] = entry
		return idx
	end)
	clanChanged(tag)
end

local function readIndex(): { [string]: any }
	if os.clock() - indexCache.at < 30 then
		return indexCache.data
	end
	local idx = get("index")
	indexCache.data = if type(idx) == "table" then idx else {}
	indexCache.at = os.clock()
	return indexCache.data
end

-- Weekly clan goal: every member can collect GOAL.MEDALS once the clan has GOAL.WINS wins this week.
local GOAL = { WINS = 25, MEDALS = 200 }

-- What a client sees of a clan. Requests only for officers of that clan.
local function view(rec, viewer: number)
	local members = {}
	for id, m in rec.members do
		members[#members + 1] = { u = tonumber(id), n = m.n, r = m.r, j = m.j }
	end
	local rankOrder = { leader = 1, officer = 2, member = 3 }
	table.sort(members, function(a, b)
		if a.r ~= b.r then
			return (rankOrder[a.r] or 4) < (rankOrder[b.r] or 4)
		end
		return (a.j or 0) < (b.j or 0)
	end)
	local mine = rec.members[tostring(viewer)]
	local out = {
		tag = rec.tag,
		name = rec.name,
		desc = rec.desc or "",
		open = rec.open == true,
		wins = rec.wins or 0,
		games = rec.games or 0,
		created = rec.created,
		members = members,
		max = CFG.MAX_MEMBERS,
		role = if mine then mine.r else nil,
		requested = rec.requests[tostring(viewer)] ~= nil,
	}
	if mine and (mine.r == "leader" or mine.r == "officer") then
		local reqs = {}
		for id, r in rec.requests do
			reqs[#reqs + 1] = { u = tonumber(id), n = r.n, t = r.t }
		end
		table.sort(reqs, function(a, b)
			return (a.t or 0) < (b.t or 0)
		end)
		out.requests = reqs
	end
	-- Rank on the clan leaderboard (by wins).
	local idx = readIndex()
	local better = 0
	for t, e in idx do
		if t ~= rec.tag and (e.w or 0) > (rec.wins or 0) then
			better += 1
		end
	end
	out.rank = better + 1
	-- Weekly clan goal (wins this week, counted in Clans.roundEnded).
	local wk = (os.time() // 86400 + 3) // 7
	out.weekWins = if type(rec.week) == "table" and rec.week.n == wk then tonumber(rec.week.wins) or 0 else 0
	out.goal = GOAL.WINS
	out.goalMedals = GOAL.MEDALS
	local viewerPlayer = Players:GetPlayerByUserId(viewer)
	if mine and viewerPlayer and ctx.progression and ctx.progression.clanGoalClaimed then
		out.goalClaimed = ctx.progression.clanGoalClaimed(viewerPlayer, wk)
	end
	return out
end

local function normalize(rec)
	rec.members = if type(rec.members) == "table" then rec.members else {}
	rec.requests = if type(rec.requests) == "table" then rec.requests else {}
	return rec
end

local function readClan(tag: string)
	local rec, ok = get("c_" .. tag)
	if not ok or type(rec) ~= "table" then
		return nil, ok
	end
	return normalize(rec), true
end

-- Resolve unknown write outcomes by reading, never by blindly removing a claim.
-- A crash leaves a durable pending claim; load() completes or reconciles it.
local function finishMembership(uid, tag, token, rec)
 if not rec then
  local readOK
  rec, readOK = readClan(tag)
  if not readOK then return false, "Membership is pending; please try again later." end
 end
 local member = rec and rec.members[tostring(uid)]
 if member and member.claim == token then
  local ok, why = commitMembership(uid, tag, token)
  if ok then return true, rec end
  -- Fence compensation by claim token: never remove a replacement member.
  local index, readOK = get("u_" .. uid)
  if readOK and (type(index) ~= "table" or index.claim ~= token) then
   update("c_" .. tag, function(old)
    if type(old) ~= "table" then return nil end
    local out = normalize(old); local m = out.members[tostring(uid)]
    if m and m.claim == token then out.members[tostring(uid)] = nil end
    return out
   end)
  end
  return false, why
 end
 clearMembership(uid, tag, token)
 return false, "The clan membership could not be completed."
end

-- Text checks
local function filtered(plr: Player, text: string): (boolean, string?)
	if text == "" then
		return true
	end
	local ok, out = pcall(function()
		local r = TextService:FilterStringAsync(text, plr.UserId, Enum.TextFilterContext.PublicChat)
		return r:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		return false, "Couldn't check that text right now, try again."
	end
	if out ~= text then
		return false, nil
	end
	return true
end

local function cleanText(raw: any, maxLen: number): string?
	if typeof(raw) ~= "string" then
		return nil
	end
	local s = string.gsub(string.gsub(raw, "^%s+", ""), "%s+$", "")
	s = string.gsub(s, "%s+", " ")
	if utf8.len(s) == nil or #s > maxLen then
		return nil
	end
	return s
end

local function displayName(plr: Player): string
	return plr.DisplayName
end

-- Ops
local ops = {}

function ops.claimGoal(plr: Player)
	local uid = plr.UserId
	local tag = userTag[uid]
	if not tag then
		return false, "Join a clan first."
	end
	local rec = readClan(tag)
	if not rec or not rec.members[tostring(uid)] then
		return false, "Join a clan first."
	end
	local wk = (os.time() // 86400 + 3) // 7
	local wins = if type(rec.week) == "table" and rec.week.n == wk then tonumber(rec.week.wins) or 0 else 0
	if wins < GOAL.WINS then
		return false, "Your clan needs " .. (GOAL.WINS - wins) .. " more wins this week."
	end
	if not (ctx.progression and ctx.progression.claimClanGoal) then
		return false, "Rewards can't be saved right now."
	end
	return ctx.progression.claimClanGoal(plr, wk, GOAL.MEDALS)
end

function ops.me(plr: Player)
	local uid = plr.UserId
	local tag = userTag[uid]
	local out = {
		cost = CFG.CREATE_MEDALS,
		charterId = CFG.CHARTER.id,
		max = CFG.MAX_MEMBERS,
		tokens = if ctx.progression then ctx.progression.itemCount(plr, CFG.CHARTER.key) else 0,
	}
	if tag then
		local rec = readClan(tag)
		if rec and rec.members[tostring(uid)] then
			out.clan = view(rec, uid)
		else
			setLocal(uid, nil)
		end
	end
	return true, out
end

function ops.view(plr: Player, tag: any)
	if typeof(tag) ~= "string" then
		return false, "Unknown clan."
	end
	local rec = readClan(string.upper(tag))
	if not rec then
		return false, "That clan doesn't exist anymore."
	end
	return true, view(rec, plr.UserId)
end

function ops.list(_plr: Player, query: any)
	local q = if typeof(query) == "string" then string.lower(string.sub(query, 1, 30)) else ""
	local list = {}
	for tag, e in readIndex() do
		if q == "" or string.find(string.lower(tag), q, 1, true) or string.find(string.lower(e.n or ""), q, 1, true) then
			list[#list + 1] = { t = tag, n = e.n, m = e.m, o = e.o, w = e.w or 0, g = e.g or 0 }
		end
	end
	table.sort(list, function(a, b)
		if a.w ~= b.w then
			return a.w > b.w
		end
		return a.m > b.m
	end)
	while #list > 100 do
		table.remove(list)
	end
	return true, list
end

function ops.create(plr: Player, arg: any)
	if type(arg) ~= "table" then
		return false, "Fill in a name and a tag."
	end
	local uid = plr.UserId
	if userTag[uid] then
		return false, "Leave your clan first."
	end
	local name = cleanText(arg.name, 24)
	if not name or #name < 3 then
		return false, "Clan name: 3 to 24 characters."
	end
	if string.find(name, "[^%w _%-%.']") then
		return false, "Clan name: letters, numbers, spaces and - _ . ' only."
	end
	local tag = typeof(arg.tag) == "string" and string.upper(arg.tag) or ""
	if not string.match(tag, "^%w%w%w?%w?%w?$") then
		return false, "Tag: 2 to 5 letters or numbers."
	end
	local desc = cleanText(arg.desc or "", 120)
	if not desc then
		return false, "Description: up to 120 characters."
	end
	for _, text in { name, tag, desc } do
		local ok, why = filtered(plr, text)
		if not ok then
			return false, why or "That name, tag or description isn't allowed."
		end
	end
	local claimed, token = claimMembership(uid, tag)
	if not claimed then return false, token end
	-- Pay first (refunded if the tag is taken).
	local pay = if arg.pay == "charter" then "charter" else "medals"
	local prog = ctx.progression
	if not prog then
		clearMembership(uid, tag, token)
		return false, "Clans can't be saved right now."
	end
	if pay == "charter" then
		if not prog.takeBoost(plr, CFG.CHARTER.key) then
			clearMembership(uid, tag, token)
			return false, "You don't have a Clan Charter."
		end
	elseif not prog.spendCoins(plr, CFG.CREATE_MEDALS) then
		clearMembership(uid, tag, token)
		return false, "You need " .. CFG.CREATE_MEDALS .. " medals to create a clan."
	end
	local function refund()
		if pay == "charter" then
			prog.returnBoost(plr, CFG.CHARTER.key)
		else
			prog.refundCoins(plr, CFG.CREATE_MEDALS)
		end
	end
	local ok, rec = update("c_" .. tag, function(old)
		if old ~= nil then
			return nil, "The tag [" .. tag .. "] is already taken."
		end
		return {
			tag = tag,
			name = name,
			desc = desc,
			open = arg.open ~= false,
			leader = uid,
			created = now(),
			wins = 0,
			games = 0,
			members = { [tostring(uid)] = { r = "leader", n = displayName(plr), j = now(), claim = token } },
			requests = {},
		}
	end)
	if not ok then
		local recovered, outcome = finishMembership(uid, tag, token)
		if not recovered then
			local index, readOK = get("u_" .. uid)
			if readOK and membershipTag(index) ~= tag then refund() end
			return false, outcome
		end
		rec = outcome
	else
		local committed, outcome = finishMembership(uid, tag, token, rec)
		if not committed then return false, outcome end
	end
	setIndex(tag, indexEntry(normalize(rec)))
	announce(uid, tag)
	return true, view(normalize(rec), uid)
end

function ops.join(plr: Player, tag: any)
	local uid = plr.UserId
	if typeof(tag) ~= "string" then
		return false, "Unknown clan."
	end
	tag = string.upper(tag)
	if userTag[uid] then
		return false, "Leave your clan first."
	end
	local initial, readOK = readClan(tag)
	if not readOK then return false, "Could not read the clan; try again later." end
	if not initial then return false, "That clan does not exist." end
	local token
	if initial.open then
		local claimed, result = claimMembership(uid, tag)
		if not claimed then return false, result end
		token = result
	end
	local joined = false
	local ok, rec = update("c_" .. tag, function(old)
		if type(old) ~= "table" then
			return nil, "That clan doesn't exist anymore."
		end
		joined = false -- UpdateAsync can rerun after a conflict.
		local r = normalize(old)
		local key = tostring(uid)
		if r.members[key] then
			joined = true
			return r
		end
		if memberCount(r) >= CFG.MAX_MEMBERS then
			return nil, "That clan is full."
		end
		if r.open then
			if not token then return nil, "Clan settings changed; please try joining again." end
			r.members[key] = { r = "member", n = displayName(plr), j = now(), claim = token }
			r.requests[key] = nil
			joined = true
		else
			r.requests[key] = { n = displayName(plr), t = now() }
		end
		return r
	end)
	if not ok then
		if not token then return false, rec end
		local recovered, outcome = finishMembership(uid, tag, token)
		if not recovered then return false, outcome end
		rec, joined = outcome, true
	end
	rec = normalize(rec)
	if joined then
		if token then
			local committed, why = finishMembership(uid, tag, token, rec)
			if not committed then return false, why end
		end
		setIndex(tag, indexEntry(rec))
		announce(uid, tag)
	else
		if token then clearMembership(uid, tag, token) end
		clanChanged(tag) -- new request: the clan's officers see it
	end
	return true, view(rec, uid)
end

function ops.cancel(plr: Player, tag: any)
	if typeof(tag) ~= "string" then
		return false, "Unknown clan."
	end
	local ok, rec = update("c_" .. string.upper(tag), function(old)
		if type(old) ~= "table" then
			return nil, "That clan doesn't exist anymore."
		end
		local r = normalize(old)
		r.requests[tostring(plr.UserId)] = nil
		return r
	end)
	if not ok then
		return false, rec
	end
	clanChanged(string.upper(tag))
	return true, view(normalize(rec), plr.UserId)
end

-- Runs f(rec, me, targetKey) on the caller's clan; f returns nil + reason to refuse.
local function manage(plr: Player, target: any, f: (any, any, string) -> (any, string?)): (boolean, any)
	local uid = plr.UserId
	local tag = userTag[uid]
	if not tag then
		return false, "You're not in a clan."
	end
	local key = tostring(tonumber(target) or 0)
	local ok, rec = update("c_" .. tag, function(old)
		if type(old) ~= "table" then
			return nil, "Your clan doesn't exist anymore."
		end
		local r = normalize(old)
		local me = r.members[tostring(uid)]
		if not me then
			return nil, "You're not in this clan anymore."
		end
		return f(r, me, key)
	end)
	if not ok then
		return false, rec
	end
	rec = normalize(rec)
	setIndex(tag, indexEntry(rec))
	return true, rec
end

local function isOfficer(m): boolean
	return m.r == "leader" or m.r == "officer"
end

function ops.accept(plr: Player, target: any)
 local tid = tonumber(target)
 if not tid or tid ~= tid or math.abs(tid) == math.huge or tid % 1 ~= 0 then return false, "Unknown player." end
 local tag = userTag[plr.UserId]
 if not tag then return false, "You're not in a clan." end
 local initial, readOK = readClan(tag)
 if not readOK then return false, "Could not read the clan." end
 local me = initial and initial.members[tostring(plr.UserId)]
 if not me or not isOfficer(me) then return false, "Only officers can accept requests." end
 if not initial.requests[tostring(tid)] then return false, "That request is gone." end
 local claimed, token = claimMembership(tid, tag)
 if not claimed then return false, token end
 local ok, rec = manage(plr, tid, function(r, officer, key)
  if not isOfficer(officer) then return nil, "Only officers can accept requests." end
  local req = r.requests[key]
  if not req then return nil, "That request is gone." end
  if memberCount(r) >= CFG.MAX_MEMBERS then return nil, "Your clan is full." end
  r.requests[key] = nil
  r.members[key] = { r="member", n=req.n, j=now(), claim=token }
  return r
 end)
 local committed, outcome = finishMembership(tid, tag, token, if ok then rec else nil)
 if not committed then return false, outcome end
 announce(tid, tag)
 return true, view(outcome, plr.UserId)
end

function ops.decline(plr: Player, target: any)
	local ok, rec = manage(plr, target, function(r, me, key)
		if not isOfficer(me) then
			return nil, "Only officers can decline requests."
		end
		r.requests[key] = nil
		return r
	end)
	if not ok then
		return false, rec
	end
	return true, view(rec, plr.UserId)
end

function ops.kick(plr: Player, target: any)
	local tid = tonumber(target)
	local ok, rec = manage(plr, target, function(r, me, key)
		local t = r.members[key]
		if not t then
			return nil, "That player isn't in your clan."
		end
		if key == tostring(plr.UserId) then
			return nil, "Use Leave to leave your clan."
		end
		local can = (me.r == "leader") or (me.r == "officer" and t.r == "member")
		if not can then
			return nil, "You can't remove that player."
		end
		r.members[key] = nil
		return r
	end)
	if not ok then
		return false, rec
	end
	if tid then
		clearMembership(tid, rec.tag)
		announce(tid, nil)
	end
	return true, view(rec, plr.UserId)
end

local function setRole(plr: Player, target: any, from: string, to: string)
	local ok, rec = manage(plr, target, function(r, me, key)
		if me.r ~= "leader" then
			return nil, "Only the leader can change roles."
		end
		local t = r.members[key]
		if not t or t.r ~= from then
			return nil, "Can't change that player's role."
		end
		t.r = to
		return r
	end)
	if not ok then
		return false, rec
	end
	return true, view(rec, plr.UserId)
end

function ops.promote(plr: Player, target: any)
	return setRole(plr, target, "member", "officer")
end

function ops.demote(plr: Player, target: any)
	return setRole(plr, target, "officer", "member")
end

function ops.transfer(plr: Player, target: any)
	local ok, rec = manage(plr, target, function(r, me, key)
		if me.r ~= "leader" then
			return nil, "Only the leader can hand over the clan."
		end
		local t = r.members[key]
		if not t or key == tostring(plr.UserId) then
			return nil, "Pick another member."
		end
		t.r = "leader"
		me.r = "officer"
		r.leader = tonumber(key)
		return r
	end)
	if not ok then
		return false, rec
	end
	return true, view(rec, plr.UserId)
end

function ops.settings(plr: Player, arg: any)
	if type(arg) ~= "table" then
		return false, "Nothing to change."
	end
	local desc = cleanText(arg.desc or "", 120)
	if not desc then
		return false, "Description: up to 120 characters."
	end
	local okText, why = filtered(plr, desc)
	if not okText then
		return false, why or "That description isn't allowed."
	end
	local ok, rec = manage(plr, 0, function(r, me)
		if me.r ~= "leader" then
			return nil, "Only the leader can change clan settings."
		end
		r.desc = desc
		r.open = arg.open == true
		return r
	end)
	if not ok then
		return false, rec
	end
	return true, view(rec, plr.UserId)
end

function ops.leave(plr: Player)
	local uid = plr.UserId
	local tag = userTag[uid]
	if not tag then
		return false, "You're not in a clan."
	end
	local disband = false
	local ok, rec = update("c_" .. tag, function(old)
		if type(old) ~= "table" then
			return nil
		end
		disband = false -- Recompute for each UpdateAsync callback.
		local r = normalize(old)
		local me = r.members[tostring(uid)]
		if not me then
			return r
		end
		if me.r == "leader" then
			if memberCount(r) > 1 then
				return nil, "Make someone else the leader first."
			end
			disband = true
		end
		r.members[tostring(uid)] = nil
		return r
	end)
	if not ok then
		return false, rec
	end
	if disband then
		pcall(function()
			store:RemoveAsync("c_" .. tag)
		end)
		setIndex(tag, nil)
	elseif type(rec) == "table" then
		setIndex(tag, indexEntry(normalize(rec)))
	end
	clearMembership(uid, tag)
	announce(uid, nil)
	return true, if disband then "Clan disbanded." else "You left [" .. tag .. "]."
end

local lastCall: { [Player]: number } = {}
Players.PlayerRemoving:Connect(function(plr)
	lastCall[plr] = nil
end)

fn.OnServerInvoke = function(plr: Player, op: any, arg: any)
	local f = typeof(op) == "string" and ops[op]
	if not f then
		return false, "Unknown action."
	end
	if busy[plr] then
		return false, "One moment..."
	end
	-- Every clan request reads the DataStore: at most about 3 a second per player. A request that
	-- comes too soon waits its turn (one at a time: busy refuses the rest while it waits).
	busy[plr] = true
	local now = os.clock()
	if lastCall[plr] and now - lastCall[plr] < 0.3 then
		task.wait(0.3 - (now - lastCall[plr]))
	end
	lastCall[plr] = os.clock()
	local ok, a, b = pcall(f, plr, arg)
	busy[plr] = nil
	if not ok then
		warn("[Clans] " .. tostring(op) .. ": " .. tostring(a))
		return false, "Something went wrong, try again."
	end
	return a, b
end

-- Public
function Clans.init(c)
	ctx = c or {}
	pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function(msg)
			local d = msg.Data
			if type(d) == "table" and type(d.c) == "string" and #d.c <= 8 then
				indexCache.at = -math.huge
				clanEvent:FireAllClients("changed", d.c)
				return
			end
			if type(d) == "table" and tonumber(d.u) and Players:GetPlayerByUserId(d.u) then
				setLocal(d.u, if type(d.t) == "string" then d.t else nil)
			end
		end)
	end)
end

function Clans.load(plr: Player)
 task.spawn(function()
  local uid = plr.UserId
  local index, indexOK = get("u_" .. uid)
  if not indexOK then return end
  local tag = membershipTag(index)
  if not tag then return end
  local rec, readOK = readClan(tag)
  if not readOK then return end -- An outage is not proof that membership was removed.
  if type(index) == "table" and index.phase == "pending" then
   local member = rec and rec.members[tostring(uid)]
   if member and member.claim == index.claim then
    local committed = commitMembership(uid, tag, index.claim)
    if not committed then return end
   elseif now() - (index.at or now()) >= 600 then
    clearMembership(uid, tag, index.claim)
    return
   else
    return -- Allow the in-flight transaction to finish; do not clear its claim.
   end
  end
  if rec and rec.members[tostring(uid)] then
   if rec.members[tostring(uid)].n ~= plr.DisplayName then
    update("c_" .. tag, function(old)
     if type(old) ~= "table" then return nil end
     local r = normalize(old)
     if r.members[tostring(uid)] then r.members[tostring(uid)].n = plr.DisplayName end
     return r
    end)
   end
   if plr.Parent then setLocal(uid, tag) end
  else
   clearMembership(uid, tag, if type(index) == "table" then index.claim else nil)
  end
 end)
end

function Clans.forget(plr: Player)
	userTag[plr.UserId] = nil
	busy[plr] = nil
end

function Clans.tagOf(plr: Player): string?
	return userTag[plr.UserId]
end

function Clans.display(plr: Player, name: string): string
	local tag = userTag[plr.UserId]
	return if tag then "[" .. tag .. "] " .. name else name
end

-- After a round: every clan with a member who played long enough gets one game, and a win if any
-- of its members won.
function Clans.roundEnded(results)
	local minSecs = MetaConfig.REWARDS.minSecondsForReward
	local byTag: { [string]: boolean } = {}
	for _, r in results do
		local tag = r.player and userTag[r.player.UserId]
		if tag and (r.seconds or 0) >= minSecs then
			byTag[tag] = byTag[tag] or r.won == true
		end
	end
	for tag, won in byTag do
		local ok, rec = update("c_" .. tag, function(old)
			if type(old) ~= "table" then
				return nil
			end
			local r = normalize(old)
			r.games = (r.games or 0) + 1
			if won then
				r.wins = (r.wins or 0) + 1
				local wk = (os.time() // 86400 + 3) // 7
				if type(r.week) ~= "table" or r.week.n ~= wk then
					r.week = { n = wk, wins = 0 }
				end
				r.week.wins = (tonumber(r.week.wins) or 0) + 1
			end
			return r
		end)
		if ok and type(rec) == "table" then
			setIndex(tag, indexEntry(normalize(rec)))
		end
	end
end

return Clans
