--[[
	War Front - owner admin tools (server).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- ServerScriptService.Admin (ModuleScript), started by GameServer with Admin.init(ctx).
-- Only MetaConfig.ADMINS may use it: every request is checked here on the server, the client menu
-- (StarterPlayerScripts.AdminPanel, F2) only shows the buttons.

-- Shared.AdminFn (RemoteFunction) ops -> (ok, result | message):
--   "overview"                         this server, its players, global state
--   "lookup", query                    any player by name or user id (profile, where, ban)
--   "player", { uid, action, ... }     medals / xp / item / reset / kick / message / ban / unban,
--                                      and in a match on this server: gold / troops / kill / revive / win
--   "server", { action, ... }          pause / speed / endRound / announce / medalsAll / kickAll / shutdown
--   "global", { action, ... }          announce / event / stopEvent / maintenance / shutdownAll
--   "servers"                          every running server (MemoryStore heartbeat)
--   "join", jobId                      teleport the admin into that server
--   "log"                              the last admin actions

-- Cross-server: MessagingService topic "WFAdmin" (requests and global actions), "WFAdminRe"
-- (answers). Global state (event multipliers, maintenance) in DataStore WF_Admin_v1 "global",
-- the action log in "log". Live servers in MemoryStore sorted map "WF1_Servers".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))

local Admin = {}

local ctx: any = nil
local JOB = if game.JobId ~= "" then game.JobId else "studio"
local TOPIC, REPLY = "WFAdmin", "WFAdminRe"
local MATCH_ACTIONS = { gold = true, troops = true, kill = true, revive = true, win = true }
local EDIT_ACTIONS = { medals = true, xp = true, item = true, reset = true }

local store = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore("WF_Admin_v1")
	end)
	store = if ok then s else nil
end
local serverMap = nil
do
	local ok, m = pcall(function()
		return MemoryStoreService:GetSortedMap("WF1_Servers")
	end)
	serverMap = if ok then m else nil
end

-- Global state, mirrored in every server.
local global = { event = nil :: any, maintenance = nil :: any }

local function isAdmin(plr: Player?): boolean
	return plr ~= nil and MetaConfig.isAdmin(plr.UserId)
end

local function clampText(s: any, max: number): string
	if typeof(s) ~= "string" then
		return ""
	end
	s = string.gsub(s, "[%c]", " ")
	return string.sub(s, 1, max)
end

local function publish(topic: string, msg: any)
	pcall(function()
		MessagingService:PublishAsync(topic, msg)
	end)
end

-- Announcements show as a big popup (MetaClient "announce").
local function announceHere(text: string, from: string?, target: Player?)
	local meta = Shared:FindFirstChild("Meta")
	if not meta then
		return
	end
	local data = { text = text, from = from }
	if target then
		meta:FireClient(target, "announce", data)
	else
		meta:FireAllClients("announce", data)
	end
end

local function log(by: Player, action: string, target: string?)
	if not store then
		return
	end
	task.spawn(function()
		pcall(function()
			store:UpdateAsync("log", function(old)
				local list = if type(old) == "table" then old else {}
				table.insert(list, { t = os.time(), by = by.Name, a = action, x = target })
				while #list > 100 do
					table.remove(list, 1)
				end
				return list
			end)
		end)
	end)
end

-- Event multipliers
local function applyGlobal()
	local ev = global.event
	if ev and (tonumber(ev.expires) or 0) > os.time() then
		ctx.progression.event.medals = math.clamp(tonumber(ev.medals) or 1, 1, 10)
		ctx.progression.event.xp = math.clamp(tonumber(ev.xp) or 1, 1, 10)
	else
		ctx.progression.event.medals, ctx.progression.event.xp = 1, 1
	end
	workspace:SetAttribute("WFEvent", if ctx.progression.event.medals > 1 or ctx.progression.event.xp > 1 then string.format("%gx medals, %gx XP", ctx.progression.event.medals, ctx.progression.event.xp) else nil)
end

local function loadGlobal()
	if not store then
		return
	end
	local ok, data = pcall(function()
		return store:GetAsync("global")
	end)
	if ok and type(data) == "table" then
		global.event, global.maintenance = data.event, data.maintenance
	end
	applyGlobal()
end

local function saveGlobal()
	if not store then
		return false
	end
	return pcall(function()
		store:SetAsync("global", { event = global.event, maintenance = global.maintenance })
	end)
end

local function kickForMaintenance()
	local m = global.maintenance
	if not (m and m.on) then
		return
	end
	for _, plr in Players:GetPlayers() do
		if not isAdmin(plr) then
			plr:Kick("War Front is down for maintenance. " .. (m.reason or "Please come back soon!"))
		end
	end
end

-- Players
local function nameOf(uid: number): string
	local plr = Players:GetPlayerByUserId(uid)
	if plr then
		return plr.Name
	end
	local ok, n = pcall(function()
		return Players:GetNameFromUserIdAsync(uid)
	end)
	return if ok and n then n else tostring(uid)
end

local function banInfo(uid: number): any
	local ok, pages = pcall(function()
		return Players:GetBanHistoryAsync(uid)
	end)
	if not ok or not pages then
		return nil
	end
	local entries = pages:GetCurrentPage()
	local last = entries[1]
	for _, e in entries do
		if not last or (e.StartTime or "") > (last.StartTime or "") then
			last = e
		end
	end
	if not last or not last.Ban then
		return { banned = false }
	end
	local start = DateTime.fromIsoDate(last.StartTime or "")
	local endsAt = if (last.Duration or -1) < 0 or not start then nil else start.UnixTimestamp + last.Duration
	if endsAt and endsAt <= os.time() then
		return { banned = false }
	end
	return { banned = true, reason = last.DisplayReason, ends = endsAt }
end

-- Actions on a player who is in this server. Returns (ok, message); nil when they aren't here.
local function localPlayerAction(uid: number, action: string, args: any, by: string?): (boolean?, string?)
	local plr = Players:GetPlayerByUserId(uid)
	if not plr then
		return nil, nil
	end
	if EDIT_ACTIONS[action] then
		return ctx.progression.adminEdit(uid, action, args.key, args.amount)
	elseif action == "kick" then
		local reason = clampText(args.reason, 200)
		plr:Kick(if reason ~= "" then reason else "You were removed from the server.")
		return true, "Kicked " .. plr.Name
	elseif action == "message" then
		local text = clampText(args.text, 300)
		if text == "" then
			return false, "Type a message first"
		end
		announceHere(text, by, plr)
		return true, "Message sent to " .. plr.Name
	end
	return false, "Unknown action"
end

local pending: { [string]: any } = {}

-- Ask the other servers to do it (the player may be there); waits for an answer.
local function remote(msg: any, timeout: number): any?
	local id = string.sub(HttpService:GenerateGUID(false), 1, 12)
	msg.req, msg.from = id, JOB
	pending[id] = { done = false }
	publish(TOPIC, msg)
	local t0 = os.clock()
	while not pending[id].done and os.clock() - t0 < timeout do
		task.wait(0.1)
	end
	local r = pending[id]
	pending[id] = nil
	return if r.done then r else nil
end

local function playerOp(admin: Player, args: any): (boolean, string)
	local uid = tonumber(args.uid)
	local action = args.action
	if not uid or uid <= 0 or typeof(action) ~= "string" then
		return false, "Pick a player first"
	end
	uid = math.floor(uid)
	if MetaConfig.isAdmin(uid) and uid ~= admin.UserId and (action == "kick" or action == "ban" or action == "reset") then
		return false, "You can't do that to another owner"
	end
	local who = nameOf(uid)
	log(admin, action, who)
	if action == "ban" then
		local seconds = tonumber(args.seconds) or -1
		local reason = clampText(args.reason, 300)
		local ok, err = pcall(function()
			Players:BanAsync({
				UserIds = { uid },
				ApplyToUniverse = true,
				Duration = if seconds > 0 then math.floor(seconds) else -1,
				DisplayReason = if reason ~= "" then reason else "Banned from War Front.",
				PrivateReason = "By " .. admin.Name,
				ExcludeAltAccounts = false,
			})
		end)
		return ok, if ok then ("Banned " .. who .. (if seconds > 0 then " for " .. math.floor(seconds / 3600) .. " h" else " permanently")) else ("Ban failed: " .. tostring(err))
	elseif action == "unban" then
		local ok, err = pcall(function()
			Players:UnbanAsync({ UserIds = { uid }, ApplyToUniverse = true })
		end)
		return ok, if ok then ("Unbanned " .. who) else ("Unban failed: " .. tostring(err))
	elseif MATCH_ACTIONS[action] then
		return ctx.matchAction(uid, action, tonumber(args.amount))
	end
	-- Here? Then another server? Then the saved data (edits only).
	local ok, msg = localPlayerAction(uid, action, args, admin.Name)
	if ok ~= nil then
		return ok, msg or ""
	end
	local reply = remote({ op = "player", uid = uid, action = action, key = args.key, amount = args.amount, reason = args.reason, text = args.text, by = admin.Name }, 4)
	if reply then
		return reply.ok, (reply.msg or "") .. " (other server)"
	end
	if EDIT_ACTIONS[action] then
		return ctx.progression.adminEdit(uid, action, args.key, args.amount)
	end
	return false, who .. " isn't online"
end

-- This server
local function serverInfo(): any
	local list = {}
	for _, plr in Players:GetPlayers() do
		local s = ctx.playerState(plr.UserId)
		list[#list + 1] = {
			uid = plr.UserId,
			name = plr.Name,
			display = plr.DisplayName,
			admin = isAdmin(plr),
			inMatch = s ~= nil,
			alive = s and s.alive,
			gold = s and s.gold,
			troops = s and s.troops,
			tiles = s and s.tiles,
		}
	end
	local m = ctx.matchInfo()
	m.job, m.place, m.players, m.max = JOB, game.PlaceId, list, Players.MaxPlayers
	return m
end

local function serverOp(admin: Player, args: any): (boolean, string)
	local action = args.action
	log(admin, "server " .. tostring(action))
	if action == "announce" then
		local text = clampText(args.text, 300)
		if text == "" then
			return false, "Type a message first"
		end
		announceHere(text, admin.Name)
		return true, "Announced in this server"
	elseif action == "medalsAll" then
		local n = math.floor(tonumber(args.amount) or 0)
		if n == 0 then
			return false, "Enter an amount"
		end
		local count = 0
		for _, plr in Players:GetPlayers() do
			if ctx.progression.adminEdit(plr.UserId, "medals", nil, n) then
				count += 1
			end
		end
		return true, string.format("%+d medals to %d players", n, count)
	elseif action == "kickAll" or action == "shutdown" then
		local reason = clampText(args.reason, 200)
		if reason == "" then
			reason = if action == "shutdown" then "This server was shut down by the developers." else "You were removed from the server."
		end
		for _, plr in Players:GetPlayers() do
			if plr ~= admin and not (action == "kickAll" and isAdmin(plr)) then
				plr:Kick(reason)
			end
		end
		if action == "shutdown" then
			task.delay(1, function()
				if admin.Parent then
					admin:Kick(reason)
				end
			end)
		end
		return true, if action == "shutdown" then "Shutting down" else "Kicked everyone else"
	end
	return ctx.serverAction(action, args.value)
end

-- Every server
local function globalOp(admin: Player, args: any): (boolean, string)
	local action = args.action
	log(admin, "global " .. tostring(action))
	if action == "announce" then
		local text = clampText(args.text, 300)
		if text == "" then
			return false, "Type a message first"
		end
		announceHere(text, admin.Name)
		publish(TOPIC, { op = "announce", text = text, by = admin.Name, from = JOB })
		return true, "Announced in every server"
	elseif action == "event" then
		local hours = math.clamp(tonumber(args.hours) or 24, 1, 24 * 14)
		global.event = {
			medals = math.clamp(tonumber(args.medals) or 2, 1, 10),
			xp = math.clamp(tonumber(args.xp) or 1, 1, 10),
			expires = os.time() + hours * 3600,
		}
		saveGlobal()
		applyGlobal()
		publish(TOPIC, { op = "global", from = JOB })
		return true, string.format("Event on for %d h: %gx medals, %gx XP", hours, global.event.medals, global.event.xp)
	elseif action == "stopEvent" then
		global.event = nil
		saveGlobal()
		applyGlobal()
		publish(TOPIC, { op = "global", from = JOB })
		return true, "Event stopped"
	elseif action == "maintenance" then
		local on = args.on == true
		global.maintenance = if on then { on = true, reason = clampText(args.reason, 200) } else nil
		saveGlobal()
		publish(TOPIC, { op = "global", from = JOB })
		kickForMaintenance()
		return true, if on then "Maintenance on: only owners can join" else "Maintenance off"
	elseif action == "shutdownAll" then
		local reason = clampText(args.reason, 200)
		if reason == "" then
			reason = "War Front is restarting for an update. Rejoin in a minute!"
		end
		publish(TOPIC, { op = "shutdown", reason = reason, from = JOB })
		for _, plr in Players:GetPlayers() do
			if not isAdmin(plr) then
				plr:Kick(reason)
			end
		end
		return true, "Every server is closing (owners stay)"
	end
	return false, "Unknown action"
end

local function servers(): any
	if not serverMap then
		return {}
	end
	local ok, items = pcall(function()
		return serverMap:GetRangeAsync(Enum.SortDirection.Ascending, 100)
	end)
	if not ok then
		return {}
	end
	local out = {}
	for _, it in items do
		local v = it.value
		if type(v) == "table" then
			v.access = nil -- stays on the server
			out[#out + 1] = v
		end
	end
	return out
end

local function joinServer(admin: Player, job: any): (boolean, string)
	if typeof(job) ~= "string" or not serverMap then
		return false, "Pick a server"
	end
	if job == JOB then
		return false, "You're already in that server"
	end
	local ok, v = pcall(function()
		return serverMap:GetAsync(job)
	end)
	if not ok or type(v) ~= "table" then
		return false, "That server is gone"
	end
	log(admin, "join server", tostring(v.role) .. " " .. tostring(v.map))
	ctx.progression.handOff(admin)
	local tpOk, err = pcall(function()
		if v.access then
			local opts = Instance.new("TeleportOptions")
			opts.ReservedServerAccessCode = v.access
			TeleportService:TeleportAsync(v.place, { admin }, opts)
		else
			TeleportService:TeleportToPlaceInstance(v.place, v.job, admin)
		end
	end)
	return tpOk, if tpOk then "Joining..." else ("Teleport failed: " .. tostring(err))
end

local function lookup(query: any): (boolean, any)
	query = clampText(query, 40)
	query = string.gsub(query, "^@", "")
	if query == "" then
		return false, "Type a username or user id"
	end
	local uid = tonumber(query)
	if not uid then
		local ok, id = pcall(function()
			return Players:GetUserIdFromNameAsync(query)
		end)
		if not ok or not id then
			return false, "No Roblox user called " .. query
		end
		uid = id
	end
	uid = math.floor(uid :: number)
	local where = nil
	if Players:GetPlayerByUserId(uid) then
		where = "this server"
	else
		for _, s in servers() do
			if type(s.uids) == "table" and table.find(s.uids, uid) then
				where = string.format("%s server (%s, %s)", tostring(s.role), tostring(s.map or "-"), tostring(s.phase or "-"))
				break
			end
		end
	end
	return true, {
		uid = uid,
		name = nameOf(uid),
		admin = MetaConfig.isAdmin(uid),
		profile = ctx.progression.adminView(uid),
		where = where,
		ban = banInfo(uid),
		match = ctx.playerState(uid),
	}
end

-- Heartbeat for the server list
local function heartbeat()
	if not serverMap then
		return
	end
	local uids = {}
	for _, plr in Players:GetPlayers() do
		if #uids < 60 then
			uids[#uids + 1] = plr.UserId
		end
	end
	local m = ctx.matchInfo()
	local info = {
		job = JOB,
		place = game.PlaceId,
		role = m.role,
		kind = m.kind,
		map = m.map,
		phase = m.phase,
		count = #Players:GetPlayers(),
		max = Players.MaxPlayers,
		uids = uids,
		access = m.access,
		t = os.time(),
	}
	pcall(function()
		if #Players:GetPlayers() == 0 then
			serverMap:RemoveAsync(JOB)
		else
			serverMap:SetAsync(JOB, info, 90)
		end
	end)
end

-- Messages from other servers
local function onMessage(message: any)
	local msg = message.Data
	if type(msg) ~= "table" or msg.from == JOB then
		return
	end
	if msg.op == "announce" then
		announceHere(clampText(msg.text, 300), msg.by)
	elseif msg.op == "global" then
		loadGlobal()
		kickForMaintenance()
	elseif msg.op == "shutdown" then
		for _, plr in Players:GetPlayers() do
			if not isAdmin(plr) then
				plr:Kick(clampText(msg.reason, 200))
			end
		end
	elseif msg.op == "player" and typeof(msg.uid) == "number" then
		local ok, text = localPlayerAction(msg.uid, msg.action, msg, msg.by)
		if ok ~= nil then
			publish(REPLY, { req = msg.req, ok = ok, msg = text })
		end
	end
end

local function onReply(message: any)
	local msg = message.Data
	if type(msg) == "table" and typeof(msg.req) == "string" and pending[msg.req] then
		pending[msg.req] = { done = true, ok = msg.ok == true, msg = msg.msg }
	end
end

function Admin.init(c)
	ctx = c
	local fn = Shared:FindFirstChild("AdminFn") or Instance.new("RemoteFunction")
	fn.Name = "AdminFn"
	fn.Parent = Shared
	local busy: { [Player]: boolean } = {}
	fn.OnServerInvoke = function(plr: Player, op: any, args: any)
		if not isAdmin(plr) then
			return false, "Not allowed"
		end
		if busy[plr] then
			return false, "Still working on the last request"
		end
		busy[plr] = true
		local ok, a, b = pcall(function()
			if op == "overview" then
				return true, { server = serverInfo(), event = global.event, maintenance = global.maintenance, items = (function()
					local list = {}
					for _, it in MetaConfig.SHOP_ITEMS do
						list[#list + 1] = { key = it.key, name = it.name }
					end
					return list
				end)() }
			elseif op == "lookup" then
				return lookup(args)
			elseif op == "player" and type(args) == "table" then
				return playerOp(plr, args)
			elseif op == "server" and type(args) == "table" then
				return serverOp(plr, args)
			elseif op == "global" and type(args) == "table" then
				return globalOp(plr, args)
			elseif op == "servers" then
				return true, servers()
			elseif op == "join" then
				return joinServer(plr, args)
			elseif op == "log" then
				local okLog, list = pcall(function()
					return store and store:GetAsync("log")
				end)
				return true, if okLog and type(list) == "table" then list else {}
			end
			return false, "Unknown request"
		end)
		busy[plr] = nil
		if not ok then
			warn("[War Front] admin " .. tostring(op) .. " failed: " .. tostring(a))
			return false, "Error: " .. tostring(a)
		end
		return a, b
	end

	Players.PlayerAdded:Connect(function(plr)
		local m = global.maintenance
		if m and m.on and not isAdmin(plr) then
			plr:Kick("War Front is down for maintenance. " .. (m.reason or "Please come back soon!"))
		end
	end)
	task.spawn(function()
		loadGlobal()
		kickForMaintenance()
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, onMessage)
		end)
		pcall(function()
			MessagingService:SubscribeAsync(REPLY, onReply)
		end)
		local n = 0
		while true do
			heartbeat()
			n += 1
			if n % 4 == 0 then
				loadGlobal() -- event expiry and missed messages
			end
			task.wait(15)
		end
	end)
	game:BindToClose(function()
		if serverMap and not RunService:IsStudio() then
			pcall(function()
				serverMap:RemoveAsync(JOB)
			end)
		end
	end)
end

return Admin
