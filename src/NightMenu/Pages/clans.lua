-- War Front Night menu: Clans. Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). Same server behaviour as StarterPlayerScripts.ClanPages:
-- talks to ServerScriptService.Clans through Shared.ClanFn (ops me / view / list / create / join /
-- cancel / accept / decline / kick / promote / demote / transfer / leave / settings / claimGoal), keeps the
-- PlayerGui attribute "WFClanTag" current and refreshes live on Shared.ClanEvent ("changed", TAG)
-- plus a 20 s check. All player text (names, tags, descriptions) is checked by the server's
-- TextService filter before it is saved; this page only shows what the server returns.
-- Tests may pass ctx.clanCall(op, arg) -> (ok, result), ctx.userId, ctx.setClanTag(tag) and
-- ctx.clanTest(api) (api.openCreate(), api.memberMenu(clan, member)).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local UserInputService = game:GetService("UserInputService")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local ROLE_NAMES = { leader = "Leader", officer = "Officer", member = "Member" }
local ROLE_ICONS = { leader = { "Crown", C.YELLOW }, officer = { "Star", C.CYAN }, member = { "User", C.MUTED } }
local BADGES = { C.YELLOW, C.CYAN, C.GREEN, C.PURPLE, C.PINK }
local PER_PAGE = 6

-- Server --------------------------------------------------------------------------------------

-- Same retry rule as ClanPages.call: "One moment..." means another request of ours is still running.
local function realCall(op: string, arg: any?): (boolean, any)
	for attempt = 1, 4 do
		local ok, success, result = pcall(function()
			return ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClanFn"):InvokeServer(op, arg)
		end)
		if not ok then
			return false, "Couldn't reach the server, try again."
		end
		if success ~= true and result == "One moment..." and attempt < 4 then
			task.wait(0.4)
		else
			return success == true, result
		end
	end
	return false, "One moment..."
end

local function playerGui(): Instance?
	local lp = Players.LocalPlayer
	return lp and lp:FindFirstChildOfClass("PlayerGui")
end

local function writeTag(tag: string?)
	local pg = playerGui()
	if pg then
		pg:SetAttribute("WFClanTag", tag or "")
	end
end

local function currentTag(): string?
	local pg = playerGui()
	local t = pg and pg:GetAttribute("WFClanTag")
	return if type(t) == "string" and t ~= "" then t else nil
end

-- Asks the server for the player's clan and updates WFClanTag (ClanPages.refreshTag).
local function refreshTag()
	task.spawn(function()
		local ok, me = realCall("me")
		if ok and type(me) == "table" then
			writeTag(if me.clan then me.clan.tag else nil)
		end
	end)
end

-- One ClanEvent listener for the whole session (like ClanPages): marks the open page for a
-- refresh, or keeps the menu's TAG current once the page is closed.
local activePage: any = nil
local watcherStarted = false
local function startWatcher()
	if watcherStarted then
		return
	end
	watcherStarted = true
	task.spawn(function()
		local ev = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClanEvent", 30)
		if not (ev and ev:IsA("RemoteEvent")) then
			return
		end
		local pending = false
		ev.OnClientEvent:Connect(function(kind: string, tag: any)
			if kind ~= "changed" then
				return
			end
			local S = activePage
			local mine = tag == currentTag()
			if S then
				local v = S.live
				if v and (v.kind == "browse" or mine or (v.kind == "clan" and v.tag == tag)) then
					S.pending = true
				end
			elseif mine then
				pending = true
			end
		end)
		while true do
			task.wait(1)
			if pending and not activePage then
				pending = false
				refreshTag()
			end
		end
	end)
end

-- Small helpers -------------------------------------------------------------------------------

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local function badgeColor(tag: string): Color3
	local h = 0
	for i = 1, #tag do
		h = (h * 31 + string.byte(tag, i)) % 9973
	end
	return BADGES[h % #BADGES + 1]
end

local function tagBadge(tag: string, size: number, order: number?): Frame
	local f = make("Frame", { Name = "TagBadge", BackgroundColor3 = badgeColor(tag), BorderSizePixel = 0, Size = UDim2.fromOffset(size, size), LayoutOrder = order or 0 })
	Kit.corner(f, math.floor(size * 0.28))
	local t = Kit.text({ Name = "Tag", Text = tag, FontFace = F.TITLE, TextColor3 = C.BG, TextScaled = true, Size = UDim2.fromScale(1, 1), Parent = f })
	Kit.pad(t, 5, 5, 4, 4)
	make("UITextSizeConstraint", { MaxTextSize = math.floor(size * 0.4), Parent = t })
	return f
end

local function muted(text: string, props: { [string]: any }?): TextLabel
	local p = props or {}
	p.Text = text
	p.FontFace = p.FontFace or F.BODY
	p.TextSize = p.TextSize or 14
	p.TextColor3 = p.TextColor3 or C.MUTED
	return Kit.text(p)
end

local function wrapped(text: string, props: { [string]: any }): TextLabel
	props.Text = text
	props.TextWrapped = true
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.Size = UDim2.new(1, 0, 0, 0)
	props.AutomaticSize = Enum.AutomaticSize.Y
	return Kit.text(props)
end

local function column(parent: Instance, order: number, width: number?): Frame
	local f = make("Frame", {
		BackgroundTransparency = 1,
		Size = if width then UDim2.fromOffset(width, 0) else UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.list(f, false, 14)
	return f
end

local function card(parent: Instance, order: number, name: string?): Frame
	local f = Kit.card({ Name = name or "Card", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.pad(f, 18, 18, 16, 16)
	Kit.list(f, false, 10)
	return f
end

local function row(parent: Instance, order: number, height: number?, gap: number?): Frame
	local f = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height or 0), AutomaticSize = if height then Enum.AutomaticSize.None else Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.list(f, true, gap or 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	return f
end

local function input(parent: Instance, placeholder: string, opts: { [string]: any }?): TextBox
	local o = opts or {}
	local tall = (o.height or 44) > 44
	local box = make("TextBox", {
		Name = o.name or "Input",
		Text = o.text or "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.MUTED,
		TextColor3 = C.TEXT,
		FontFace = F.BOLD,
		TextSize = 16,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = if tall then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		TextWrapped = tall,
		BackgroundColor3 = C.DEEP,
		BorderSizePixel = 0,
		Size = o.size or UDim2.new(1, 0, 0, o.height or 44),
		LayoutOrder = o.layoutOrder or 0,
		SelectionImageObject = Kit.ring,
		Parent = parent,
	})
	Kit.corner(box, 10)
	Kit.stroke(box)
	Kit.pad(box, 12, 12, if tall then 10 else 0, if tall then 10 else 0)
	return box
end

-- Dashed outline (UIStroke has no dashes): short bars along each edge, redrawn on resize.
local function dashed(frame: GuiObject, color: Color3)
	local holder = make("Frame", { Name = "Dashes", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = frame })
	local function draw()
		holder:ClearAllChildren()
		local w, h = frame.AbsoluteSize.X, frame.AbsoluteSize.Y
		if w < 40 or h < 40 then
			return
		end
		local r, dash, gap = 14, 9, 6
		local function bar(pos: UDim2, size: UDim2)
			make("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Position = pos, Size = size, Parent = holder })
		end
		local x = r
		while x + dash <= w - r do
			bar(UDim2.new(x / w, 0, 0, 0), UDim2.new(dash / w, 0, 0, 2))
			bar(UDim2.new(x / w, 0, 1, -2), UDim2.new(dash / w, 0, 0, 2))
			x += dash + gap
		end
		local y = r
		while y + dash <= h - r do
			bar(UDim2.new(0, 0, y / h, 0), UDim2.new(0, 2, dash / h, 0))
			bar(UDim2.new(1, -2, y / h, 0), UDim2.new(0, 2, dash / h, 0))
			y += dash + gap
		end
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(draw)
	task.defer(draw)
end

-- Runs fn once at a time for a button (the old page showed "..." while a request ran).
local function busyRun(btn: GuiButton, fn: () -> ())
	if btn:GetAttribute("Busy") then
		return
	end
	btn:SetAttribute("Busy", true)
	btn:SetAttribute("Disabled", true)
	task.spawn(function()
		local ok, err = pcall(fn)
		if btn.Parent then
			btn:SetAttribute("Busy", nil)
			btn:SetAttribute("Disabled", false)
		end
		if not ok then
			warn("[War Front] clans: " .. tostring(err))
		end
	end)
end

local function joinedText(j: any): string?
	local t = tonumber(j)
	if not t then
		return nil
	end
	local ok, s = pcall(function()
		return DateTime.fromUnixTimestamp(t):FormatLocalTime("MMM YYYY", "en-us")
	end)
	return if ok then s else nil
end

-- Page ----------------------------------------------------------------------------------------

local load, renderClan, renderBrowse

local function clearBody(S)
	for _, c in S.page.body:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function setTag(S, tag: string?)
	if S.ctx.setClanTag then
		S.ctx.setClanTag(tag)
	else
		writeTag(tag)
	end
end

local function stateCard(S, text: string, retry: (() -> ())?)
	clearBody(S)
	local c = card(S.page.body, 1, "State")
	c:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Center
	Kit.icon(if retry then "AlertCircle" else "Hourglass", { Size = UDim2.fromOffset(30, 30), ImageColor3 = if retry then C.PINK else C.MUTED, LayoutOrder = 1, Parent = c })
	wrapped(text, { FontFace = F.BOLD, TextSize = 16, TextColor3 = if retry then C.TEXT else C.MUTED, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = c })
	if retry then
		Kit.button("secondary", "Try again", { icon = "Refresh", height = 40, layoutOrder = 3, parent = c, onActivated = retry })
	end
end

-- A popup with a title, a line of text and buttons: { {kind, text, fn} } (fn nil = just close).
local function ask(S, title: string, text: string, buttons: { any }, accent: Color3?)
	local phone = S.ctx.layout() == "phone"
	local p = S.ctx.popup({ width = if phone then 330 else 420, accent = accent })
	Kit.list(p.card, false, 12)
	Kit.text({ Text = title, FontFace = F.TITLE, TextSize = 22, LayoutOrder = 1, Parent = p.card })
	wrapped(text, { FontFace = F.BODY, TextSize = 15, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = p.card })
	local r = row(p.card, 3, 44, 10)
	r:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Right
	for i, b in buttons do
		local btn
		btn = Kit.button(b[1], b[2], { height = 42, layoutOrder = i, parent = r, onActivated = function()
			if b[3] then
				busyRun(btn, function()
					b[3]()
					p.close()
				end)
			else
				p.close()
			end
		end })
	end
	return p
end

-- Same as ClanPages' after(): show the error, keep WFClanTag current, then redraw this clan or
-- reload the page.
local function after(S, back: (() -> ())?, ok: boolean, result: any, stay: boolean?)
	if S.closed then
		return
	end
	if not ok then
		S.ctx.toast(tostring(result), "error")
		return
	end
	if type(result) == "table" then
		if result.role then
			setTag(S, result.tag)
		end
		if stay then
			renderClan(S, result, back, true)
			return
		end
	end
	load(S)
end

local function tabs(S, active: string, order: number)
	if not (S.me and S.me.clan) then
		return
	end
	local t = Kit.tabs({ { "mine", "My clan" }, { "browse", "Find clans" } }, active, function(key)
		if key == "mine" and S.me.clan then
			renderClan(S, S.me.clan, nil)
		else
			renderBrowse(S)
		end
	end)
	t.LayoutOrder = order
	t.Parent = S.page.body
end

local function invite(S)
	task.spawn(function()
		local lp = Players.LocalPlayer
		if not lp then
			return
		end
		local okCan, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(lp)
		end)
		if okCan and can then
			pcall(function()
				SocialService:PromptGameInvite(lp)
			end)
		else
			S.ctx.toast("Invites aren't available right now.", "info")
		end
	end)
end

-- Two columns on desktop / console, stacked on phone. Returns left, right (right may be nil).
local function columns(S, order: number, hasRight: boolean)
	local phone = S.ctx.layout() == "phone"
	local holder = make("Frame", { Name = "Columns", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = S.page.body })
	Kit.list(holder, not phone, 14)
	local left = column(holder, 1, nil)
	local right
	if hasRight then
		if phone then
			right = column(holder, 2, nil)
		else
			left.Size = UDim2.fromOffset(0, 0)
			Kit.flex(left)
			right = column(holder, 2, 340)
		end
	end
	return left, right
end

-- Members / requests / settings rows ----------------------------------------------------------

local function memberMenu(S, clan, m, back)
	local name = tostring(m.n)
	local function run(op: string)
		local ok, result = S.call(op, m.u)
		if ok and op == "transfer" and S.me then
			S.me.clan = result
		end
		after(S, back, ok, result, true)
	end
	local opts = {}
	if clan.role == "leader" then
		if m.r == "member" then
			table.insert(opts, { "secondary", "Make officer", "Star", function()
				run("promote")
			end })
		elseif m.r == "officer" then
			table.insert(opts, { "secondary", "Make member", "User", function()
				run("demote")
			end })
		end
		table.insert(opts, { "secondary", "Make leader", "Crown", function()
			ask(S, "Make " .. name .. " the leader?", "They will run the clan and you will become an officer.", {
				{ "ghost", "Cancel" },
				{ "primary", "Make leader", function()
					run("transfer")
				end },
			})
		end, true })
	end
	if clan.role == "leader" or (clan.role == "officer" and m.r == "member") then
		table.insert(opts, { "danger", "Remove from clan", "Close", function()
			ask(S, "Remove " .. name .. "?", name .. " will leave [" .. clan.tag .. "]. They can ask to join again later.", {
				{ "ghost", "Cancel" },
				{ "danger", "Remove", function()
					run("kick")
				end },
			}, C.PINK)
		end, true })
	end
	if #opts == 0 then
		return
	end
	local phone = S.ctx.layout() == "phone"
	local p = S.ctx.popup({ width = if phone then 320 else 360 })
	Kit.list(p.card, false, 10)
	Kit.text({ Text = name, FontFace = F.TITLE, TextSize = 22, LayoutOrder = 0, Parent = p.card })
	muted(ROLE_NAMES[m.r] or "Member", { LayoutOrder = 1, Parent = p.card })
	for i, o in opts do
		local btn
		btn = Kit.button(o[1], o[2], { icon = o[3], height = 44, size = UDim2.new(1, 0, 0, 44), layoutOrder = 1 + i, parent = p.card, onActivated = function()
			if o[5] then
				p.close()
				o[4]()
			else
				busyRun(btn, function()
					o[4]()
					p.close()
				end)
			end
		end })
	end
end

local function memberRow(S, parent: Instance, order: number, clan, m, back)
	local me = m.u == S.myId
	local r = make("Frame", { Name = "Member", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = order, Parent = parent })
	Kit.list(r, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local look = ROLE_ICONS[m.r] or ROLE_ICONS.member
	local dot = make("Frame", { BackgroundColor3 = C.RAISED, BorderSizePixel = 0, Size = UDim2.fromOffset(40, 40), LayoutOrder = 1, Parent = r })
	Kit.corner(dot)
	Kit.icon(look[1], { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), ImageColor3 = look[2], Parent = dot })
	local info = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = r })
	Kit.flex(info)
	Kit.list(info, false, 2)
	Kit.text({ Text = tostring(m.n) .. (if me then " (you)" else ""), FontFace = F.BOLD, TextSize = 16, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, Parent = info })
	local since = joinedText(m.j)
	muted((ROLE_NAMES[m.r] or "Member") .. (if since then " · joined " .. since else ""), { LayoutOrder = 2, Parent = info })
	local can = not me and (clan.role == "leader" or (clan.role == "officer" and m.r == "member"))
	if can then
		Kit.iconButton("Menu", { name = "MemberActions", size = 36, layoutOrder = 3, parent = r, onActivated = function()
			memberMenu(S, clan, m, back)
		end })
	end
end

local function requestsCard(S, parent: Instance, order: number, clan, back)
	local c = card(parent, order, "JoinRequests")
	Kit.text({ Text = "Join requests · " .. #clan.requests, FontFace = F.TITLE, TextSize = 20, LayoutOrder = 0, Parent = c })
	if #clan.requests == 0 then
		muted("No requests right now.", { LayoutOrder = 1, Parent = c })
	end
	for i, req in clan.requests do
		local r = row(c, i, 48, 10)
		local info = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = r })
		Kit.flex(info)
		Kit.list(info, false, 2)
		Kit.text({ Text = tostring(req.n), FontFace = F.BOLD, TextSize = 16, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, Parent = info })
		muted("Wants to join", { LayoutOrder = 2, Parent = info })
		local acc, dec
		acc = Kit.iconButton("Check", { name = "Accept", size = 36, color = C.GREEN, iconColor = C.GREEN_TEXT, layoutOrder = 2, parent = r, onActivated = function()
			busyRun(acc, function()
				local ok, result = S.call("accept", req.u)
				after(S, back, ok, result, true)
			end)
		end })
		dec = Kit.iconButton("Close", { name = "Decline", size = 36, color = C.PINK, iconColor = C.BG, layoutOrder = 3, parent = r, onActivated = function()
			busyRun(dec, function()
				local ok, result = S.call("decline", req.u)
				after(S, back, ok, result, true)
			end)
		end })
	end
end

local function settingsCard(S, parent: Instance, order: number, clan, back)
	local c = card(parent, order, "ClanSettings")
	Kit.text({ Text = "Clan settings", FontFace = F.TITLE, TextSize = 20, LayoutOrder = 0, Parent = c })
	muted("Description", { FontFace = F.BOLD, LayoutOrder = 1, Parent = c })
	local desc = input(c, "Description (up to 120 characters)", { name = "Description", text = clan.desc or "", height = 72, layoutOrder = 2 })
	muted("Who can join", { FontFace = F.BOLD, LayoutOrder = 3, Parent = c })
	local open = clan.open == true
	local seg = Kit.segmented({ { "open", "Anyone" }, { "closed", "Ask first" } }, if open then "open" else "closed", function(key)
		open = key == "open"
	end)
	seg.LayoutOrder = 4
	seg.Parent = c
	local save
	save = Kit.button("secondary", "Save", { icon = "Check", height = 40, layoutOrder = 5, parent = c, onActivated = function()
		busyRun(save, function()
			local ok, result = S.call("settings", { desc = desc.Text, open = open })
			if ok then
				S.ctx.toast("Clan settings saved.", "ok")
			end
			after(S, back, ok, result, true)
		end)
	end })
end

-- Weekly clan goal (Clans.view: weekWins / goal / goalMedals / goalClaimed; op claimGoal).
local function goalCard(S, parent: Instance, order: number, clan, back)
	local goal = tonumber(clan.goal) or 0
	local wins = tonumber(clan.weekWins) or 0
	local medals = tonumber(clan.goalMedals) or 0
	local c = card(parent, order, "ClanGoal")
	local head = row(c, 1, 40, 8)
	require(script.Parent.Parent:WaitForChild("Art")).image("ClanGoal", { Size = UDim2.fromOffset(40, 40), LayoutOrder = 1, Parent = head })
	Kit.text({ Text = "Clan goal this week", FontFace = F.TITLE, TextSize = 20, LayoutOrder = 2, Parent = head })
	muted("Win " .. goal .. " battles together", { LayoutOrder = 2, Parent = c })
	local bar = Kit.progress(if goal > 0 then wins / goal else 0, C.CYAN)
	bar.LayoutOrder = 3
	bar.Parent = c
	muted(wins .. "/" .. goal .. " · prize: " .. numberText(medals) .. " medals each", { LayoutOrder = 4, Parent = c })
	if clan.goalClaimed then
		Kit.chip("Collected", { name = "GoalCollected", icon = "Check", color = C.GREEN, textColor = C.GREEN_TEXT, iconColor = C.GREEN_TEXT, stroke = false, height = 40, layoutOrder = 5, parent = c })
	elseif goal > 0 and wins >= goal then
		local b
		b = Kit.button("robux", "Collect " .. numberText(medals), { name = "CollectGoal", icon = "Medal", height = 42, layoutOrder = 5, parent = c, onActivated = function()
			busyRun(b, function()
				local ok, result = S.call("claimGoal")
				if ok then
					S.ctx.toast(if type(result) == "string" and result ~= "" then result else "+" .. numberText(medals) .. " medals collected!", "ok")
				end
				after(S, back, ok, result)
			end)
		end })
	end
end

-- One clan (yours or another) -----------------------------------------------------------------

local function leave(S, clan, back)
	local count = #clan.members
	local function go()
		local ok, result = S.call("leave")
		if ok then
			setTag(S, nil)
			if type(result) == "string" then
				S.ctx.toast(result, "ok")
			end
		end
		after(S, back, ok, result)
	end
	if clan.role == "leader" and count > 1 then
		-- Server rule (Clans.leave): the leader must hand over first.
		ask(S, "Make someone else the leader first", "Open the menu next to a member and pick Make leader. Then you can leave.", { { "secondary", "OK" } })
	elseif clan.role == "leader" then
		ask(S, "Disband [" .. clan.tag .. "]?", "You're the only member, so leaving deletes the clan for good.", {
			{ "ghost", "Cancel" },
			{ "danger", "Disband", go },
		}, C.PINK)
	else
		ask(S, "Leave [" .. clan.tag .. "]?", "You can join or start another clan afterwards.", {
			{ "ghost", "Cancel" },
			{ "danger", "Leave", go },
		}, C.PINK)
	end
end

renderClan = function(S, clan, back: (() -> ())?, keepScroll: boolean?)
	if S.closed then
		return
	end
	local body = S.page.body
	local scroll = body.CanvasPosition
	clearBody(S)
	S.live = { kind = if back then "clan" else "mine", tag = clan.tag, me = S.me, back = back }
	local phone = S.ctx.layout() == "phone"
	local count = #clan.members
	local inClan = S.me and S.me.clan ~= nil

	if back then
		Kit.button("ghost", "Back to clans", { icon = "ChevronLeft", height = 36, padX = 8, layoutOrder = 1, parent = body, onActivated = back })
	else
		tabs(S, "mine", 1)
	end

	-- Top row: badge, name, stats, actions
	local head = card(body, 2, "ClanHead")
	local top = row(head, 1, nil, 14)
	tagBadge(clan.tag, if phone then 48 else 60, 1).Parent = top
	local info = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = top })
	Kit.flex(info)
	Kit.list(info, false, 3)
	Kit.text({ Text = tostring(clan.name), FontFace = F.TITLE, TextSize = if phone then 22 else 26, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, if phone then 26 else 30), LayoutOrder = 1, Parent = info })
	local stats = {}
	if clan.rank then
		table.insert(stats, "Clan rank #" .. tostring(clan.rank))
	end
	table.insert(stats, numberText(clan.wins) .. " wins")
	table.insert(stats, count .. "/" .. tostring(clan.max) .. " members")
	table.insert(stats, if clan.open then "anyone can join" else "ask to join")
	wrapped(table.concat(stats, " · "), { FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = info })
	if clan.desc and clan.desc ~= "" then
		wrapped(clan.desc, { FontFace = F.BODY, TextSize = 14, TextColor3 = C.TEXT, LayoutOrder = 3, Parent = info })
	end
	local actions = make("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 44), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 3 })
	Kit.list(actions, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	actions.Parent = if phone then head else top
	if clan.role then
		Kit.button("secondary", "Invite", { icon = "UserPlus", height = 42, layoutOrder = 1, parent = actions, onActivated = function()
			invite(S)
		end })
		Kit.button("danger", if clan.role == "leader" and count == 1 then "Disband" else "Leave", { icon = "Logout", height = 42, layoutOrder = 2, parent = actions, onActivated = function()
			leave(S, clan, back)
		end })
	elseif clan.requested then
		local b
		b = Kit.button("secondary", "Cancel request", { icon = "Close", height = 42, parent = actions, onActivated = function()
			busyRun(b, function()
				local ok, result = S.call("cancel", clan.tag)
				after(S, back, ok, result, true)
			end)
		end })
	elseif not inClan then
		local full = count >= (tonumber(clan.max) or math.huge)
		local b
		b = Kit.button(if full then "secondary" elseif clan.open then "primary" else "secondary", if full then "Clan full" elseif clan.open then "Join" else "Ask to join", {
			icon = if full then nil elseif clan.open then "UserPlus" else "Lock",
			height = 42,
			parent = actions,
			onActivated = function()
				if full then
					return
				end
				busyRun(b, function()
					local ok, result = S.call("join", clan.tag)
					if ok and type(result) == "table" and result.role then
						setTag(S, result.tag)
						S.ctx.toast("Welcome to [" .. tostring(result.tag) .. "]!", "ok")
						load(S) -- joined: the page switches to your clan
						return
					end
					if ok then
						S.ctx.toast("Request sent. The clan's officers will decide.", "ok")
					end
					after(S, back, ok, result, true)
				end)
			end,
		})
		if full then
			b:SetAttribute("Disabled", true)
		end
	else
		muted("Leave your clan to join this one.", { Parent = actions })
	end

	-- Members (left) + requests / settings (right)
	local showGoal = clan.role ~= nil and clan.goal ~= nil
	local hasRight = clan.requests ~= nil or clan.role == "leader" or (showGoal and not phone)
	local left, right = columns(S, 3, hasRight)
	if showGoal then
		-- Desktop: top of the right column. Phone: right under the header.
		goalCard(S, if phone then left else right, 0, clan, back)
	end
	local members = card(left, 1, "Members")
	Kit.text({ Text = "Members · " .. count .. "/" .. tostring(clan.max), FontFace = F.TITLE, TextSize = 20, LayoutOrder = 0, Parent = members })
	for i, m in clan.members do
		memberRow(S, members, i, clan, m, back)
	end
	if right then
		if clan.requests then
			requestsCard(S, right, 1, clan, back)
		end
		if clan.role == "leader" then
			settingsCard(S, right, 2, clan, back)
		end
	end
	task.defer(function()
		if body.Parent then
			body.CanvasPosition = if keepScroll then scroll else Vector2.zero
		end
	end)
end

-- Create ----------------------------------------------------------------------------------------

local function openCreate(S)
	local me = S.me
	local phone = S.ctx.layout() == "phone"
	S.paused = true -- a form being filled in: never refreshed under the player (ClanPages)
	local p = S.ctx.popup({ width = if phone then 340 else 470, accent = C.YELLOW, onClose = function()
		S.paused = false
	end })
	local c = p.card
	Kit.list(c, false, 10)
	local head = row(c, 1, 36, 10)
	Kit.icon("FlagPlus", { Size = UDim2.fromOffset(26, 26), ImageColor3 = C.YELLOW, LayoutOrder = 1, Parent = head })
	local title = Kit.text({ Text = "Start your own clan", FontFace = F.TITLE, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2, Parent = head })
	Kit.flex(title)
	Kit.iconButton("Close", { size = 34, layoutOrder = 3, parent = head, onActivated = p.close })

	local function label(text: string, hint: string, order: number)
		local r = row(c, order, 20, 8)
		Kit.text({ Text = text, FontFace = F.BOLD, TextSize = 15, LayoutOrder = 1, Parent = r })
		muted(hint, { TextSize = 13, LayoutOrder = 2, Parent = r })
	end
	label("Clan name", "3 to 24 characters", 2)
	local name = input(c, "Clan name", { name = "ClanName", layoutOrder = 3 })
	label("Tag", "2 to 5 letters or numbers", 4)
	local tag = input(c, "TAG", { name = "ClanTag", layoutOrder = 5 })
	label("Description", "optional, up to 120 characters", 6)
	local desc = input(c, "What is your clan about?", { name = "ClanDescription", height = 64, layoutOrder = 7 })
	label("Who can join", "", 8)
	local open = true
	local seg = Kit.segmented({ { "open", "Anyone" }, { "closed", "Ask first" } }, "open", function(key)
		open = key == "open"
	end)
	seg.LayoutOrder = 9
	seg.Parent = c
	local lp = Players.LocalPlayer
	local myName = if lp then lp.DisplayName else "You"
	local preview = muted("", { LayoutOrder = 10, Parent = c })
	local function updatePreview()
		-- Same tag clean-up as ClanPages: upper case, letters and numbers, at most 5.
		local t = string.upper((string.gsub(tag.Text, "[^%w]", "")))
		if tag.Text ~= string.sub(t, 1, 5) then
			tag.Text = string.sub(t, 1, 5)
		end
		local shown = string.sub(t, 1, 5)
		preview.Text = "In battles: " .. (if shown ~= "" then "[" .. shown .. "] " else "") .. myName
	end
	tag:GetPropertyChangedSignal("Text"):Connect(updatePreview)
	name:GetPropertyChangedSignal("Text"):Connect(updatePreview)
	updatePreview()
	local status = wrapped("", { FontFace = F.BOLD, TextSize = 14, TextColor3 = C.PINK, LayoutOrder = 11, Parent = c })

	local function create(pay: string): boolean
		status.TextColor3 = C.MUTED
		status.Text = "Creating..."
		local ok, result = S.call("create", { name = name.Text, tag = tag.Text, desc = desc.Text, open = open, pay = pay })
		if not ok or type(result) ~= "table" then
			status.TextColor3 = C.PINK
			status.Text = tostring(result)
			return false
		end
		setTag(S, result.tag)
		p.close()
		S.ctx.toast("Clan [" .. tostring(result.tag) .. "] created!", "ok")
		load(S)
		return true
	end

	local buttons = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 12, Parent = c })
	Kit.list(buttons, false, 8)
	local medals
	medals = Kit.button("primary", "Create · " .. numberText(me.cost), { icon = "Medal", height = 48, size = UDim2.new(1, 0, 0, 48), layoutOrder = 1, parent = buttons, onActivated = function()
		busyRun(medals, function()
			create("medals")
		end)
	end })
	if (tonumber(me.tokens) or 0) > 0 then
		local use
		use = Kit.button("secondary", "Use Clan Charter (x" .. tostring(me.tokens) .. ")", { icon = "Key", height = 44, size = UDim2.new(1, 0, 0, 44), layoutOrder = 2, parent = buttons, onActivated = function()
			busyRun(use, function()
				create("charter")
			end)
		end })
	elseif (tonumber(me.charterId) or 0) ~= 0 then
		local robux = Kit.button("robux", "Create with Robux", { height = 44, size = UDim2.new(1, 0, 0, 44), layoutOrder = 2, parent = buttons })
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfoAsync(me.charterId, Enum.InfoType.Product)
			end)
			if ok and type(info) == "table" and info.PriceInRobux and robux.Parent then
				Kit.setButtonText(robux, "Create · R$ " .. info.PriceInRobux)
			end
		end)
		robux.Activated:Connect(function()
			if name.Text == "" or tag.Text == "" then
				status.TextColor3 = C.PINK
				status.Text = "Fill in a name and a tag first."
				return
			end
			if not lp then
				return
			end
			local conn
			conn = MarketplaceService.PromptProductPurchaseFinished:Connect(function(uid, productId, bought)
				if uid ~= lp.UserId or productId ~= me.charterId then
					return
				end
				conn:Disconnect()
				if not bought then
					return
				end
				-- The charter lands in the inventory when Roblox confirms the purchase.
				status.TextColor3 = C.MUTED
				status.Text = "Purchase received, creating your clan..."
				for _ = 1, 6 do
					task.wait(1.5)
					if not status.Parent then
						return
					end
					local okMe, mine = S.call("me")
					if okMe and type(mine) == "table" and mine.tokens and mine.tokens > 0 then
						create("charter")
						return
					end
				end
				status.Text = "Your Clan Charter will be ready in a moment. Try again from this page."
			end)
			table.insert(S.conns, conn)
			MarketplaceService:PromptProductPurchase(lp, me.charterId)
		end)
	end
end

-- Browse ----------------------------------------------------------------------------------------

local function createCard(S, parent: Instance, order: number)
	local me = S.me
	local outer = make("Frame", { Name = "StartClan", BackgroundColor3 = C.CARD, BackgroundTransparency = 0.4, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.corner(outer, 12)
	dashed(outer, C.LINE)
	local c = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = outer })
	Kit.pad(c, 20, 20, 22, 22)
	Kit.list(c, false, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local dot = make("Frame", { BackgroundColor3 = C.RAISED, BorderSizePixel = 0, Size = UDim2.fromOffset(52, 52), LayoutOrder = 1, Parent = c })
	Kit.corner(dot)
	Kit.icon("FlagPlus", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(28, 28), ImageColor3 = C.YELLOW, Parent = dot })
	Kit.text({ Text = "Start your own clan", FontFace = F.TITLE, TextSize = 21, LayoutOrder = 2, Parent = c })
	wrapped("Pick a name and a 2–5 letter tag", { FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 3, Parent = c })
	Kit.button("primary", numberText(me.cost) .. " to create", { icon = "Medal", height = 46, layoutOrder = 4, parent = c, onActivated = function()
		openCreate(S)
	end })
	if (tonumber(me.tokens) or 0) > 0 then
		muted("You have " .. tostring(me.tokens) .. " Clan Charter" .. (if me.tokens == 1 then "" else "s"), { TextSize = 13, LayoutOrder = 5, Parent = c })
	end
end

local function browseRow(S, parent: Instance, order: number, c, back)
	local maxMembers = tonumber(S.me.max) or 50
	local full = (tonumber(c.m) or 0) >= maxMembers
	local inClan = S.me.clan ~= nil
	local r = make("TextButton", { Name = "Clan_" .. tostring(c.t), Text = "", AutoButtonColor = false, BackgroundColor3 = C.CARD, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 68), LayoutOrder = order, SelectionImageObject = Kit.ring, Parent = parent })
	Kit.corner(r, 12)
	local stroke = Kit.stroke(r)
	Kit.pad(r, 12, 12, 0, 0)
	Kit.list(r, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.hover(r, function(state)
		r.BackgroundColor3 = if state == "idle" then C.CARD else C.RAISED
		stroke.Color = if state == "idle" then C.LINE else C.MUTED
	end)
	tagBadge(tostring(c.t), 44, 1).Parent = r
	local info = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = r })
	Kit.flex(info)
	Kit.list(info, false, 2)
	Kit.text({ Text = tostring(c.n), FontFace = F.TITLE, TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 1, Parent = info })
	local line = row(info, 2, 18, 5)
	muted(tostring(c.m) .. "/" .. maxMembers .. " members · " .. numberText(c.w) .. " wins", { LayoutOrder = 1, Parent = line })
	if not c.o then
		muted("·", { LayoutOrder = 2, Parent = line })
		Kit.icon("Lock", { Size = UDim2.fromOffset(14, 14), ImageColor3 = C.MUTED, LayoutOrder = 3, Parent = line })
		muted("ask to join", { LayoutOrder = 4, Parent = line })
	end
	local function view()
		busyRun(r, function()
			local ok, clan = S.call("view", c.t)
			if S.closed then
				return
			end
			if ok and type(clan) == "table" then
				renderClan(S, clan, back)
			else
				S.ctx.toast(tostring(clan), "error")
			end
		end)
	end
	r.Activated:Connect(function()
		if not r:GetAttribute("Busy") then
			view()
		end
	end)
	if inClan then
		Kit.icon("ChevronRight", { Size = UDim2.fromOffset(20, 20), ImageColor3 = C.MUTED, LayoutOrder = 3, Parent = r })
	elseif full then
		muted("full", { FontFace = F.BOLD, LayoutOrder = 3, Parent = r })
	else
		local b
		b = Kit.button(if c.o then "primary" else "secondary", if c.o then "Join" else "Ask", { height = 38, layoutOrder = 3, parent = r, onActivated = function()
			busyRun(b, function()
				local ok, result = S.call("join", c.t)
				if ok and type(result) == "table" and result.role then
					setTag(S, result.tag)
					S.ctx.toast("Welcome to [" .. tostring(result.tag) .. "]!", "ok")
					load(S)
					return
				end
				if ok then
					S.ctx.toast("Request sent. The clan's officers will decide.", "ok")
				end
				after(S, back, ok, result, true)
			end)
		end })
	end
end

renderBrowse = function(S)
	if S.closed then
		return
	end
	clearBody(S)
	local body = S.page.body
	local inClan = S.me.clan ~= nil
	local back = function()
		renderBrowse(S)
	end
	if inClan then
		tabs(S, "browse", 1)
	else
		muted("Team up and climb the clan rankings together", { TextSize = 15, LayoutOrder = 1, Parent = body })
	end
	local left, right = columns(S, 2, not inClan)
	if right then
		createCard(S, right, 1)
	end

	-- Search well
	local well = make("Frame", { Name = "Search", BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 1, Parent = left })
	Kit.corner(well, 12)
	Kit.stroke(well)
	Kit.pad(well, 14, 12)
	Kit.list(well, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon("Search", { Size = UDim2.fromOffset(20, 20), ImageColor3 = C.MUTED, LayoutOrder = 1, Parent = well })
	local box = make("TextBox", {
		Name = "ClanSearch",
		Text = "",
		PlaceholderText = "Search clans by name or tag",
		PlaceholderColor3 = C.MUTED,
		TextColor3 = C.TEXT,
		FontFace = F.BOLD,
		TextSize = 16,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 2,
		SelectionImageObject = Kit.ring,
		Parent = well,
	})
	Kit.flex(box)

	-- Filter (ClanPages: all / open / by request)
	local filter = "all"
	local pageIndex = 1
	local cached = {}
	local list = make("Frame", { Name = "ClanList", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = left })
	Kit.list(list, false, 8)
	local pager = row(left, 4, 36, 12)
	pager:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Center
	pager.Visible = false
	local draw
	local prev = Kit.iconButton("ChevronLeft", { name = "Previous", size = 36, layoutOrder = 1, parent = pager, onActivated = function()
		pageIndex = math.max(1, pageIndex - 1)
		draw()
	end })
	local count = Kit.text({ Text = "1 / 1", FontFace = F.TITLE, TextSize = 16, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = pager })
	local nextB = Kit.iconButton("ChevronRight", { name = "Next", size = 36, layoutOrder = 3, parent = pager, onActivated = function()
		pageIndex += 1
		draw()
	end })
	local seg = Kit.segmented({ { "all", "All clans" }, { "open", "Open" }, { "ask", "Ask to join" } }, "all", function(key)
		filter = key
		pageIndex = 1
		draw()
	end)
	seg.Size = UDim2.fromOffset(0, 38)
	seg.LayoutOrder = 2
	seg.Parent = left

	local function clearRows()
		for _, ch in list:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
	end
	draw = function()
		if not list.Parent then
			return
		end
		clearRows()
		local rows = {}
		for _, c in cached do
			if filter == "all" or (filter == "open" and c.o) or (filter == "ask" and not c.o) then
				table.insert(rows, c)
			end
		end
		local pages = math.max(1, math.ceil(#rows / PER_PAGE))
		pageIndex = math.clamp(pageIndex, 1, pages)
		count.Text = pageIndex .. " / " .. pages
		pager.Visible = pages > 1
		prev.Visible = pageIndex > 1
		nextB.Visible = pageIndex < pages
		if #rows == 0 then
			local empty = card(list, 1, "Empty")
			wrapped(if box.Text ~= "" or filter ~= "all" then "No clans match that search." else "No clans yet. Be the first to create one!", { FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Center, Parent = empty })
		end
		for j = (pageIndex - 1) * PER_PAGE + 1, math.min(pageIndex * PER_PAGE, #rows) do
			browseRow(S, list, j, rows[j], back)
		end
	end
	local fillToken = 0
	local function fill(query: string, silent: boolean?)
		fillToken += 1
		local token = fillToken
		if not silent then
			clearRows()
			muted("Loading clans...", { LayoutOrder = 0, Parent = list })
		end
		task.spawn(function()
			local ok, clans = S.call("list", query)
			if not list.Parent or token ~= fillToken or S.closed then
				return
			end
			if not ok or type(clans) ~= "table" then
				clearRows()
				local err = card(list, 1, "Error")
				err:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Center
				wrapped(tostring(clans), { FontFace = F.BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = err })
				Kit.button("secondary", "Try again", { icon = "Refresh", height = 40, layoutOrder = 2, parent = err, onActivated = function()
					fill(box.Text)
				end })
				return
			end
			cached = clans
			draw()
		end)
	end
	box.FocusLost:Connect(function()
		pageIndex = 1
		fill(box.Text)
	end)
	S.live = { kind = "browse", me = S.me, refresh = function()
		fill(box.Text, true)
	end }
	fill("")
end

-- Loading the player's clan ---------------------------------------------------------------------

load = function(S, tab: string?)
	if S.closed then
		return
	end
	S.gen += 1
	local gen = S.gen
	S.live = nil
	stateCard(S, "Loading clans...")
	task.spawn(function()
		local ok, me = S.call("me")
		if S.closed or gen ~= S.gen then
			return
		end
		if not ok or type(me) ~= "table" then
			stateCard(S, tostring(me), function()
				load(S, tab)
			end)
			return
		end
		setTag(S, if me.clan then me.clan.tag else nil)
		S.me = me
		if me.clan and tab ~= "browse" then
			renderClan(S, me.clan, nil)
		else
			renderBrowse(S)
		end
	end)
end

-- Refreshes whatever is on screen (ClanPages.refreshLive).
local function refreshLive(S)
	local v = S.live
	if not v or S.closed or S.paused then
		return
	end
	local focused = UserInputService:GetFocusedTextBox()
	if focused and focused:IsDescendantOf(S.page.body) then
		return -- typing (search, description): don't redraw under the player
	end
	local ok, me = S.call("me")
	if not ok or type(me) ~= "table" or S.live ~= v or S.closed then
		return
	end
	setTag(S, if me.clan then me.clan.tag else nil)
	local wasIn = v.me and v.me.clan ~= nil
	local isIn = me.clan ~= nil
	if wasIn ~= isIn or (v.kind == "mine" and not isIn) then
		load(S) -- joined / accepted / kicked / disbanded
		return
	end
	S.me = me
	if v.kind == "mine" then
		renderClan(S, me.clan, nil, true)
	elseif v.kind == "clan" then
		local okView, clan = S.call("view", v.tag)
		if okView and type(clan) == "table" and S.live == v and not S.closed then
			renderClan(S, clan, v.back, true)
		end
	elseif v.kind == "browse" and v.refresh then
		v.me = me
		v.refresh()
	end
end

return {
	title = "Clans",
	refreshTag = refreshTag,
	render = function(page, ctx)
		Kit.list(page.body, false, 14)
		local lp = Players.LocalPlayer
		local S = {
			page = page,
			ctx = ctx,
			call = ctx.clanCall or realCall,
			myId = ctx.userId or (if lp then lp.UserId else 0),
			gen = 0,
			conns = {},
			closed = false,
			paused = false,
			pending = false,
		}
		local real = ctx.clanCall == nil
		if real then
			activePage = S
			startWatcher()
			-- Server pushes are bundled (one refresh a second at most); browse and your own clan are
			-- also re-checked every 20 s in case a push was missed (ClanPages).
			task.spawn(function()
				local lastPoll = os.clock()
				while not S.closed do
					task.wait(1)
					local v = S.live
					local due = S.pending or (v ~= nil and v.kind ~= "clan" and os.clock() - lastPoll > 20)
					if due and v and not S.paused then
						S.pending = false
						lastPoll = os.clock()
						pcall(refreshLive, S)
					end
				end
			end)
		end
		load(S)
		if ctx.clanTest then
			-- Edit-mode tests only: open the popups that normally need a click.
			ctx.clanTest({
				openCreate = function()
					openCreate(S)
				end,
				memberMenu = function(clan, m)
					memberMenu(S, clan, m, nil)
				end,
			})
		end
		return function()
			S.closed = true
			S.live = nil
			if activePage == S then
				activePage = nil
			end
			for _, c in S.conns do
				c:Disconnect()
			end
		end
	end,
}
