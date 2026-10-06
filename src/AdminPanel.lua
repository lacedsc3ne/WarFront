--[[
	War Front - owner admin menu (client).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- StarterPlayer.StarterPlayerScripts.AdminPanel (LocalScript). F2 opens it, only for
-- MetaConfig.ADMINS. Everything it does goes through Shared.AdminFn, which checks the owner list
-- on the server again (ServerScriptService.Admin). Tabs: Players, Server, Global, Servers, Log.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))
if not MetaConfig.isAdmin(localPlayer.UserId) then
	return
end

local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make
local adminFn = Shared:WaitForChild("AdminFn", 30)

local gui = make("ScreenGui", {
	Name = "FrontlinesAdmin",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = localPlayer:WaitForChild("PlayerGui"),
})
local modal = MenuKit.modal(gui, "AdminWindow")
local page = modal.page
page.title.Text = "ADMIN"
modal.box.BackgroundTransparency = 0 -- solid: the main menu shouldn't show through
page.frame.BackgroundTransparency = 0.05

local state: any = {
	tab = "players",
	overview = nil,
	target = nil, -- lookup result
	status = "",
	statusOk = true,
	itemIdx = 1,
	banIdx = 2,
	eventMedals = 2,
	eventXp = 1,
	eventHours = 24,
}
local render: () -> ()

local function call(op: string, args: any?): (boolean, any)
	if not adminFn then
		return false, "Admin service not found"
	end
	local ok, success, result = pcall(function()
		return adminFn:InvokeServer(op, args)
	end)
	if not ok then
		return false, "Couldn't reach the server"
	end
	return success == true, result
end

local function setStatus(ok: boolean, msg: any)
	state.status = tostring(msg or "")
	state.statusOk = ok
end

local function fmt(n: any): string
	n = tonumber(n)
	if not n then
		return "-"
	end
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^(-?),", "%1"))
end

local function ago(t: number): string
	local d = os.time() - t
	if d < 60 then
		return d .. " s ago"
	elseif d < 3600 then
		return math.floor(d / 60) .. " min ago"
	elseif d < 86400 then
		return math.floor(d / 3600) .. " h ago"
	end
	return math.floor(d / 86400) .. " d ago"
end

-- UI pieces. Things inside a row are ordered by creation (seq), card sections by explicit order.
local seq = 0
local function nextOrder(): number
	seq += 1
	return seq
end

local function text(parent: Instance, order: number?, s: string, props: any?)
	return MenuKit.paragraph(parent, order or nextOrder(), s, props)
end

local function card(order: number, title: string?): Frame
	local c = MenuKit.card(page.body, order, 16, 14, 10)
	if title then
		text(c, 0, title, { FontFace = F.BOLD, TextSize = 16, TextColor3 = C.WHITE })
	end
	return c
end

local function row(parent: Instance, order: number): Frame
	local r = make("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Parent = r })
	return r
end

local function box(parent: Instance, placeholder: string, width: number, value: string?): TextBox
	local b = make("TextBox", {
		LayoutOrder = nextOrder(),
		Size = UDim2.fromOffset(width, 36),
		BackgroundColor3 = C.BLACK,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.GRAY400,
		Text = value or "",
		TextColor3 = C.WHITE,
		FontFace = F.MEDIUM,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = parent,
	})
	MenuKit.corner(b, 8)
	MenuKit.stroke(b, 0.85)
	MenuKit.pad(b, 10, 10, 0, 0)
	return b
end

local function button(parent: Instance, label: string, kind: string, onClick: () -> (), width: number?): TextButton
	local b = MenuKit.button(kind, { LayoutOrder = nextOrder(), Size = UDim2.fromOffset(width or 0, 36), AutomaticSize = if width then Enum.AutomaticSize.None else Enum.AutomaticSize.X, FontFace = F.BOLD, TextSize = 13, Text = label, Parent = parent })
	if not width then
		MenuKit.pad(b, 14, 14, 0, 0)
	end
	b.Activated:Connect(onClick)
	return b
end

-- Red button that needs a second click within 4 s.
local function danger(parent: Instance, label: string, onConfirm: () -> ()): TextButton
	local armed = false
	local b
	b = button(parent, label, "gray", function()
		if armed then
			armed = false
			onConfirm()
			return
		end
		armed = true
		b.Text = "CLICK AGAIN TO CONFIRM"
		task.delay(4, function()
			if armed and b.Parent then
				armed = false
				b.Text = label
			end
		end)
	end)
	b.BackgroundColor3 = C.RED500
	b.TextColor3 = C.WHITE
	MenuKit.hover(b, function(s)
		b.BackgroundColor3 = if s == "idle" then C.RED500 else C.RED400
	end)
	return b
end

-- Cycles through options on click: options = { { value, label } }.
local function cycle(parent: Instance, options: { any }, get: () -> number, set: (number) -> (), width: number?): TextButton
	local b
	b = button(parent, "", "secondary", function()
		set(get() % #options + 1)
		b.Text = "‹ " .. options[get()][2] .. " ›"
	end, width or 150)
	b.Text = "‹ " .. options[get()][2] .. " ›"
	return b
end

-- Runs an admin request, shows the result at the top and re-renders.
local function act(op: string, args: any, after: (() -> ())?)
	task.spawn(function()
		setStatus(true, "Working...")
		render()
		local ok, res = call(op, args)
		setStatus(ok, res)
		if after then
			after()
		end
		render()
	end)
end

local function refreshOverview()
	local ok, res = call("overview")
	if ok and type(res) == "table" then
		state.overview = res
	end
end

local function lookup(query: any)
	task.spawn(function()
		setStatus(true, "Looking up " .. tostring(query) .. "...")
		render()
		local ok, res = call("lookup", query)
		if ok then
			state.target = res
			setStatus(true, "")
		else
			setStatus(false, res)
		end
		render()
	end)
end

local function relookup()
	if state.target then
		local ok, res = call("lookup", tostring(state.target.uid))
		if ok then
			state.target = res
		end
	end
	refreshOverview()
end

-- Tabs
local BANS = { { 3600, "1 hour" }, { 86400, "1 day" }, { 604800, "7 days" }, { 2592000, "30 days" }, { -1, "Permanent" } }
local MULTS = { { 1, "1x" }, { 1.5, "1.5x" }, { 2, "2x" }, { 3, "3x" } }
local HOURS = { { 1, "1 hour" }, { 6, "6 hours" }, { 24, "24 hours" }, { 48, "2 days" }, { 72, "3 days" }, { 168, "7 days" } }

local function indexOf(list: { any }, v: any): number
	for i, o in list do
		if o[1] == v then
			return i
		end
	end
	return 1
end

local function renderPlayers()
	local o = state.overview
	local c = card(1, "Find a player")
	local r = row(c, 1)
	local q = box(r, "Username or user id", 260)
	button(r, "LOOK UP", "primary", function()
		lookup(q.Text)
	end)
	q.FocusLost:Connect(function(enter)
		if enter then
			lookup(q.Text)
		end
	end)

	local here = card(2, "In this server")
	if o and o.server then
		for i, pl in o.server.players do
			local line = string.format("%s  (@%s)%s", pl.display, pl.name, if pl.admin then "  ·  owner" else "")
			if pl.inMatch then
				line ..= string.format("   ·   %s  ·  %s gold  ·  %s troops  ·  %s tiles", if pl.alive then "alive" else "defeated", fmt(pl.gold), fmt(pl.troops), fmt(pl.tiles))
			end
			local b = button(here, line, "secondary", function()
				lookup(tostring(pl.uid))
			end)
			b.LayoutOrder = i
			b.AutomaticSize = Enum.AutomaticSize.None
			b.Size = UDim2.new(1, 0, 0, 34)
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.FontFace = F.MEDIUM
		end
	else
		text(here, 1, "Loading...")
	end

	local t = state.target
	if not t then
		return
	end
	local p = t.profile
	local info = card(3, string.format("%s  (id %d)%s", t.name, t.uid, if t.admin then "  ·  OWNER" else ""))
	local where = if t.where then "Online: " .. t.where else "Offline"
	text(info, 1, where, { TextColor3 = if t.where then C.EMERALD300 else C.GRAY400 })
	if t.ban and t.ban.banned then
		text(info, 2, "BANNED" .. (if t.ban.ends then " until " .. os.date("%Y-%m-%d %H:%M", t.ban.ends) else " permanently") .. (if t.ban.reason then ": " .. tostring(t.ban.reason) else ""), { TextColor3 = C.RED400, FontFace = F.BOLD })
	end
	if p then
		local items = {}
		for k, v in p.boosts or {} do
			if (tonumber(v) or 0) > 0 then
				items[#items + 1] = k .. " x" .. v
			end
		end
		text(info, 3, string.format("Medals %s  ·  Level %d (%s XP)  ·  Games %s  ·  Wins %s  ·  ELO %s  ·  Streak %d", fmt(p.medals), p.level or 1, fmt(p.xp), fmt(p.games), fmt(p.wins), if p.elo then fmt(p.elo) else "-", p.streak or 0))
		text(info, 4, "Items: " .. (if #items > 0 then table.concat(items, ", ") else "none"), { TextTransparency = 0.3 })
	else
		text(info, 3, "No War Front data yet", { TextTransparency = 0.3 })
	end
	if t.match then
		text(info, 5, string.format("In a match here: %s  ·  %s gold  ·  %s troops  ·  %s tiles", if t.match.alive then "alive" else "defeated", fmt(t.match.gold), fmt(t.match.troops), fmt(t.match.tiles)), { TextColor3 = C.AQUARIUS })
	end

	local function player(action: string, extra: any?)
		local args = extra or {}
		args.uid, args.action = t.uid, action
		act("player", args, relookup)
	end

	local data = card(4, "Data")
	local r1 = row(data, 1)
	local medals = box(r1, "Medals", 120)
	button(r1, "GIVE MEDALS", "primary", function()
		player("medals", { amount = tonumber(medals.Text) or 0 })
	end)
	button(r1, "TAKE MEDALS", "gray", function()
		player("medals", { amount = -(tonumber(medals.Text) or 0) })
	end)
	local xp = box(r1, "XP", 100)
	button(r1, "GIVE XP", "primary", function()
		player("xp", { amount = tonumber(xp.Text) or 0 })
	end)
	local r2 = row(data, 2)
	local items = (state.overview and state.overview.items) or {}
	if #items > 0 then
		local opts = {}
		for _, it in items do
			opts[#opts + 1] = { it.key, it.name }
		end
		cycle(r2, opts, function()
			return math.clamp(state.itemIdx, 1, #opts)
		end, function(i)
			state.itemIdx = i
		end, 180)
		local count = box(r2, "Amount", 90, "1")
		button(r2, "GIVE ITEM", "primary", function()
			player("item", { key = opts[math.clamp(state.itemIdx, 1, #opts)][1], amount = tonumber(count.Text) or 1 })
		end)
		button(r2, "TAKE ITEM", "gray", function()
			player("item", { key = opts[math.clamp(state.itemIdx, 1, #opts)][1], amount = -(tonumber(count.Text) or 1) })
		end)
	end
	local r3 = row(data, 3)
	danger(r3, "RESET ALL DATA", function()
		player("reset")
	end)

	local m = card(5, "Match (this server)")
	local r4 = row(m, 1)
	local gold = box(r4, "Gold", 120)
	button(r4, "SET GOLD", "primary", function()
		player("gold", { amount = tonumber(gold.Text) or 0 })
	end)
	local troops = box(r4, "Troops", 120)
	button(r4, "SET TROOPS", "primary", function()
		player("troops", { amount = tonumber(troops.Text) or 0 })
	end)
	local r5 = row(m, 2)
	button(r5, "REVIVE", "secondary", function()
		player("revive")
	end)
	button(r5, "MAKE WINNER", "secondary", function()
		player("win")
	end)
	danger(r5, "DEFEAT", function()
		player("kill")
	end)

	local mod = card(6, "Moderation")
	local r6 = row(mod, 1)
	local msg = box(r6, "Private message to this player", 360)
	button(r6, "SEND", "primary", function()
		player("message", { text = msg.Text })
	end)
	local r7 = row(mod, 2)
	local reason = box(r7, "Reason (shown to them)", 360)
	danger(r7, "KICK", function()
		player("kick", { reason = reason.Text })
	end)
	local r8 = row(mod, 3)
	cycle(r8, BANS, function()
		return state.banIdx
	end, function(i)
		state.banIdx = i
	end)
	danger(r8, "BAN", function()
		player("ban", { seconds = BANS[state.banIdx][1], reason = reason.Text })
	end)
	button(r8, "UNBAN", "secondary", function()
		player("unban")
	end)
	text(mod, 4, "Bans use Roblox's ban system: they cover every server and alt accounts.", { TextSize = 12, TextTransparency = 0.5 })
end

local function renderServer()
	local o = state.overview
	local s = o and o.server
	local c = card(1, "This server")
	if s then
		text(c, 1, string.format("%s server  ·  %s  ·  map %s  ·  %s  ·  %d / %d players", tostring(s.role), tostring(s.kind or "public"), tostring(s.map), tostring(s.phase), #s.players, s.max or 0))
		text(c, 2, string.format("Speed x%s%s  ·  Round %s  ·  Job %s", tostring(s.speed), if s.paused then " (paused)" else "", tostring(s.round), string.sub(tostring(s.job), 1, 8)), { TextTransparency = 0.4, TextSize = 12 })
	end
	local r = row(c, 3)
	button(r, if s and s.paused then "RESUME" else "PAUSE", "primary", function()
		act("server", { action = "pause" }, refreshOverview)
	end)
	for _, v in { 0.5, 1, 2, 6 } do
		button(r, "x" .. v, "secondary", function()
			act("server", { action = "speed", value = v }, refreshOverview)
		end, 56)
	end
	danger(r, "END ROUND", function()
		act("server", { action = "endRound" }, refreshOverview)
	end)

	local a = card(2, "Announce in this server")
	local r2 = row(a, 1)
	local msg = box(r2, "Message", 420)
	button(r2, "SEND", "primary", function()
		act("server", { action = "announce", text = msg.Text })
	end)

	local g = card(3, "Everyone in this server")
	local r3 = row(g, 1)
	local medals = box(r3, "Medals", 120)
	button(r3, "GIVE EVERYONE MEDALS", "primary", function()
		act("server", { action = "medalsAll", amount = tonumber(medals.Text) or 0 }, refreshOverview)
	end)
	local r4 = row(g, 2)
	local reason = box(r4, "Reason (shown to them)", 300)
	danger(r4, "KICK EVERYONE ELSE", function()
		act("server", { action = "kickAll", reason = reason.Text }, refreshOverview)
	end)
	danger(r4, "SHUT DOWN SERVER", function()
		act("server", { action = "shutdown", reason = reason.Text })
	end)
end

local function renderGlobal()
	local o = state.overview or {}
	local a = card(1, "Announce in every server")
	local r = row(a, 1)
	local msg = box(r, "Message", 420)
	button(r, "SEND TO ALL", "primary", function()
		act("global", { action = "announce", text = msg.Text })
	end)

	local e = card(2, "Reward event")
	local ev = o.event
	if ev and (ev.expires or 0) > os.time() then
		text(e, 1, string.format("Running: %gx medals, %gx XP, ends %s", ev.medals or 1, ev.xp or 1, os.date("%Y-%m-%d %H:%M", ev.expires)), { TextColor3 = C.EMERALD300 })
	else
		text(e, 1, "No event running. Multiplies the medals and XP from every match.", { TextTransparency = 0.4 })
	end
	local r2 = row(e, 2)
	text(r2, nil, "Medals", { Size = UDim2.fromOffset(60, 36), AutomaticSize = Enum.AutomaticSize.None })
	cycle(r2, MULTS, function()
		return indexOf(MULTS, state.eventMedals)
	end, function(i)
		state.eventMedals = MULTS[i][1]
	end, 100)
	text(r2, nil, "XP", { Size = UDim2.fromOffset(30, 36), AutomaticSize = Enum.AutomaticSize.None })
	cycle(r2, MULTS, function()
		return indexOf(MULTS, state.eventXp)
	end, function(i)
		state.eventXp = MULTS[i][1]
	end, 100)
	cycle(r2, HOURS, function()
		return indexOf(HOURS, state.eventHours)
	end, function(i)
		state.eventHours = HOURS[i][1]
	end, 130)
	local r3 = row(e, 3)
	button(r3, "START EVENT", "primary", function()
		act("global", { action = "event", medals = state.eventMedals, xp = state.eventXp, hours = state.eventHours }, refreshOverview)
	end)
	button(r3, "STOP EVENT", "gray", function()
		act("global", { action = "stopEvent" }, refreshOverview)
	end)

	local m = card(3, "Maintenance")
	local on = o.maintenance and o.maintenance.on
	text(m, 1, if on then "ON: only owners can join." else "Off. When on, everyone except the owners is kicked and can't join.", { TextColor3 = if on then C.RED400 else C.WHITE, TextTransparency = if on then 0 else 0.4 })
	local r4 = row(m, 2)
	local reason = box(r4, "Message for players", 300)
	if on then
		button(r4, "TURN OFF", "primary", function()
			act("global", { action = "maintenance", on = false }, refreshOverview)
		end)
	else
		danger(r4, "TURN ON", function()
			act("global", { action = "maintenance", on = true, reason = reason.Text }, refreshOverview)
		end)
	end

	local s = card(4, "Shut down every server")
	text(s, 1, "Kicks everyone (except owners) from every War Front server, e.g. before an update.", { TextTransparency = 0.4 })
	local r5 = row(s, 2)
	local why = box(r5, "Message for players", 300)
	danger(r5, "SHUT DOWN ALL", function()
		act("global", { action = "shutdownAll", reason = why.Text })
	end)
end

local function renderServers()
	local c = card(1, "Live servers")
	local r = row(c, 1)
	button(r, "REFRESH", "primary", function()
		state.servers = nil
		render()
	end)
	if state.servers == nil then
		text(c, 2, "Loading...")
		task.spawn(function()
			local ok, list = call("servers")
			state.servers = if ok and type(list) == "table" then list else {}
			if state.tab == "servers" then
				render()
			end
		end)
		return
	end
	if #state.servers == 0 then
		text(c, 2, "No servers found.")
		return
	end
	table.sort(state.servers, function(a, b)
		return (a.count or 0) > (b.count or 0)
	end)
	local myJob = state.overview and state.overview.server and state.overview.server.job
	for i, s in state.servers do
		local line = row(c, i + 2)
		text(line, nil, string.format("%s  ·  %s  ·  %s  ·  %s  ·  %d / %d players", tostring(s.role), tostring(s.kind or "public"), tostring(s.map or "-"), tostring(s.phase or "-"), s.count or 0, s.max or 0), { Size = UDim2.fromOffset(470, 36), AutomaticSize = Enum.AutomaticSize.None })
		if s.job == myJob then
			text(line, nil, "YOU ARE HERE", { Size = UDim2.fromOffset(110, 36), AutomaticSize = Enum.AutomaticSize.None, TextColor3 = C.EMERALD300, FontFace = F.BOLD })
		else
			button(line, "JOIN", "primary", function()
				act("join", s.job)
			end, 80)
		end
	end
end

local function renderLog()
	local c = card(1, "Admin log (last 100 actions)")
	if state.log == nil then
		text(c, 1, "Loading...")
		task.spawn(function()
			local ok, list = call("log")
			state.log = if ok and type(list) == "table" then list else {}
			if state.tab == "log" then
				render()
			end
		end)
		return
	end
	if #state.log == 0 then
		text(c, 1, "Nothing yet.")
	end
	for i = #state.log, 1, -1 do
		local e = state.log[i]
		text(c, #state.log - i + 1, string.format("%s  ·  %s  ·  %s%s", ago(tonumber(e.t) or 0), tostring(e.by), tostring(e.a), if e.x then "  ·  " .. tostring(e.x) else ""), { TextSize = 13 })
	end
end

render = function()
	if not modal.isOpen() then
		return
	end
	local canvas = page.body.CanvasPosition
	page:clear()
	if state.status ~= "" then
		text(page.body, 0, state.status, { FontFace = F.BOLD, TextColor3 = if state.statusOk then C.EMERALD300 else C.RED400 })
	end
	if state.tab == "players" then
		renderPlayers()
	elseif state.tab == "server" then
		renderServer()
	elseif state.tab == "global" then
		renderGlobal()
	elseif state.tab == "servers" then
		renderServers()
	else
		renderLog()
	end
	page.body.CanvasPosition = canvas
end

local function open()
	modal.open()
	state.status = ""
	page:setTabs({
		{ key = "players", label = "Players" },
		{ key = "server", label = "Server" },
		{ key = "global", label = "Global" },
		{ key = "servers", label = "Servers" },
		{ key = "log", label = "Log" },
	}, state.tab, function(key)
		state.tab = key
		state.status = ""
		if key == "servers" then
			state.servers = nil
		elseif key == "log" then
			state.log = nil
		end
		render()
	end)
	task.spawn(function()
		refreshOverview()
		render()
	end)
end

UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode ~= Enum.KeyCode.F2 or UserInputService:GetFocusedTextBox() then
		return
	end
	if modal.isOpen() then
		modal.close()
	else
		open()
	end
end)
