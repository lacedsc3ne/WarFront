--[[
	War Front - the Clans page (browse, create, your clan with members, requests and settings) and
	the clan leaderboard tab.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.ClanPages (ModuleScript), used by MenuPages and MainMenu.
-- Talks to ServerScriptService.Clans through Shared.ClanFn (see Clans.lua for the ops).
-- Sets the PlayerGui attribute "WFClanTag" (TAG or "") whenever it learns the player's clan, so
-- the main menu's TAG button can show it.
-- ClanPages.render(page)            the Clans page (MenuKit page)
-- ClanPages.renderBoard(page)       the "Clans" tab of the leaderboard
-- ClanPages.summary(body, order)    the profile's Clans tab
-- ClanPages.refreshTag()            asks the server for the player's clan (sets WFClanTag)

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local ClanView = require(script.Parent:WaitForChild("ClanView"))
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make

local Shared = ReplicatedStorage:WaitForChild("Shared")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local ClanPages = {}

local ROLE_NAMES = { leader = "Leader", officer = "Officer", member = "Member" }
local ROLE_COLORS = { leader = C.CYBER, officer = C.AQUARIUS, member = C.GRAY300 }

local function call(op: string, arg: any?): (boolean, any)
	for attempt = 1, 4 do
		local ok, success, result = pcall(function()
			return Shared:WaitForChild("ClanFn"):InvokeServer(op, arg)
		end)
		if not ok then
			return false, "Couldn't reach the server, try again."
		end
		-- Another request of ours (a live refresh) is still running on the server: try again shortly.
		if success ~= true and result == "One moment..." and attempt < 4 then
			task.wait(0.4)
		else
			return success == true, result
		end
	end
	return false, "One moment..."
end

local function setTag(tag: string?)
	playerGui:SetAttribute("WFClanTag", tag or "")
end

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local function winRate(w: number, g: number): string
	return if g > 0 then string.format("%d%%", math.floor(w / g * 100 + 0.5)) else "-"
end

local function textBox(parent: Instance, order: number, placeholder: string, height: number?, props: { [string]: any }?)
	local box = make("TextBox", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height or 44),
		BackgroundColor3 = C.BLACK,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.GRAY400,
		Text = "",
		TextColor3 = C.WHITE,
		FontFace = F.MEDIUM,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = (height or 44) > 44,
		TextYAlignment = if (height or 44) > 44 then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		Parent = parent,
	})
	for k, v in props or {} do
		(box :: any)[k] = v
	end
	MenuKit.corner(box, 8)
	MenuKit.stroke(box, 0.85)
	MenuKit.pad(box, 12, 12, if (height or 44) > 44 then 10 else 0, 0)
	return box
end

local function tagBadge(parent: Instance, tag: string, size: number?): TextLabel
	local t = MenuKit.text({
		Size = UDim2.fromOffset(0, size or 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0,
		BackgroundColor3 = C.MALIBU,
		FontFace = F.BOLD,
		TextSize = if size and size > 30 then 18 else 13,
		TextColor3 = C.WHITE,
		Text = "[" .. tag .. "]",
		Parent = parent,
	})
	MenuKit.corner(t, 6)
	MenuKit.pad(t, 8, 8, 0, 0)
	return t
end

-- A button that asks "Sure?" before running (kick, leave, transfer).
local function confirmButton(kind: string, props: { [string]: any }, run: () -> ()): TextButton
	local label = props.Text
	local b = ClanView.action(MenuKit.button(kind, props), if props.Text == "KICK" or props.Text == "LEAVE CLAN" or props.Text == "DISBAND" then "danger" else "secondary")
	local armed = false
	b.Activated:Connect(function()
		if armed then
			armed = false
			b.Text = label
			run()
			return
		end
		armed = true
		b.Text = "SURE?"
		task.delay(3, function()
			if armed then
				armed = false
				b.Text = label
			end
		end)
	end)
	return b
end

local render: (page: any, tab: string?) -> ()

-- Live view: what the Clans page (or the clan leaderboard) shows right now, so a server "changed"
-- push (Shared.ClanEvent) or the periodic check can refresh it in place. marker = an instance of
-- that view; once it's gone (page closed or switched), nothing refreshes.
local live: { [string]: any } = {}
local function setLive(page: any, kind: string, marker: Instance, extra: { [string]: any }?)
	live = { page = page, kind = kind, marker = marker }
	for k, v in extra or {} do
		live[k] = v
	end
end

-- One clan: header, stats, join / leave, settings, requests and members.
local function renderClan(page: any, clan: any, me: any, back: (() -> ())?, keepScroll: boolean?)
	local scroll = page.body.CanvasPosition
	page:clear()
	local body = page.body
	local o = 0
	local function n()
		o += 1
		return o
	end
	local status = MenuKit.paragraph(body, 1000, "", { TextSize = 14, TextColor3 = C.AMBER300, TextXAlignment = Enum.TextXAlignment.Center })
	local function after(ok: boolean, result: any, stay: boolean?)
		if not ok then
			status.Text = tostring(result)
			return
		end
		if type(result) == "table" then
			if result.role then
				setTag(result.tag)
			end
			if stay then
				renderClan(page, result, me, back)
				return
			end
		end
		render(page)
	end
	if back then
		local b = ClanView.action(MenuKit.button("secondary", { LayoutOrder = n(), Size = UDim2.fromOffset(180, 34), FontFace = F.BOLD, TextSize = 13, Text = "< BROWSE CLANS", Parent = body }),"secondary")
		b.Activated:Connect(back)
	end

	-- Summary and permission-aware management tabs.
	local count = #clan.members
	local head,actions = ClanView.summary(page,clan,n())
	setLive(page, if back then "clan" else "mine", head, { tag = clan.tag, me = me, back = back })
	local sectionTabs={{key="members",label="MEMBERS"}}
	if clan.requests then table.insert(sectionTabs,{key="requests",label="REQUESTS"}) end
	if clan.role=="leader" then table.insert(sectionTabs,{key="settings",label="SETTINGS"}) end
	if page.clanSectionTag~=clan.tag then page.clanSection="members" end
	page.clanSectionTag=clan.tag
	local valid=false for _,t in sectionTabs do if t.key==page.clanSection then valid=true end end
	if not valid then page.clanSection="members" end
	local nav=ClanView.sections(page,sectionTabs,page.clanSection,function(key)
		page.clanSection=key
		renderClan(page,clan,me,back,true)
	end)
	nav.LayoutOrder=n()
	local membersPanel=ClanView.panel(body,n(),"ClanMembers",8);membersPanel.Visible=page.clanSection=="members"
	local requestsPanel=if clan.requests then ClanView.panel(body,n(),"ClanRequests",8) else nil
	if requestsPanel then requestsPanel.Visible=page.clanSection=="requests" end
	local settingsPanel=if clan.role=="leader" then ClanView.panel(body,n(),"ClanSettings",10) else nil
	if settingsPanel then settingsPanel.Visible=page.clanSection=="settings" end
	local inClan = me and me.clan ~= nil
	if clan.role then
		local leave=ClanView.panel(body,999,"ClanLeave",0)
		actions=make("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,40),Parent=leave})
		local lone = clan.role == "leader" and count == 1
		confirmButton("gray", { Size = UDim2.fromOffset(150, 40), FontFace = F.BOLD, TextSize = 14, Text = if lone then "DISBAND" else "LEAVE CLAN", Parent = actions }, function()
			local ok, result = call("leave")
			if ok then
				setTag(nil)
			end
			after(ok, result)
		end)
	elseif clan.requested then
		local b = MenuKit.button("gray", { Size = UDim2.fromOffset(190, 40), FontFace = F.BOLD, TextSize = 14, Text = "CANCEL REQUEST", Parent = actions })
		b.Activated:Connect(function()
			local ok, result = call("cancel", clan.tag)
			after(ok, result, true)
		end)
	elseif not inClan then
		local full = count >= clan.max
		local b = MenuKit.button(if full then "gray" else "primary", { Size = UDim2.fromOffset(190, 40), FontFace = F.BOLD, TextSize = 14, Text = if full then "CLAN FULL" elseif clan.open then "JOIN CLAN" else "REQUEST TO JOIN", Parent = actions })
		b.Activated:Connect(function()
			if full then
				return
			end
			b.Text = "..."
			local ok, result = call("join", clan.tag)
			if ok and type(result) == "table" and result.role then
				setTag(result.tag)
				render(page) -- joined: the page switches to My Clan
				return
			end
			after(ok, result, true)
		end)
	else
		MenuKit.text({ Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, TextSize = 13, TextTransparency = 0.5, Text = "Leave your clan to join this one.", Parent = actions })
	end

	-- Leader settings
	if clan.role == "leader" then
		MenuKit.heading(settingsPanel, n(), nil, "Clan settings")
		local card = make("Frame",{LayoutOrder=n(),BackgroundTransparency=1,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,Parent=settingsPanel})
		MenuKit.list(card,false,10)
		local desc = textBox(card, 1, "Description (up to 120 characters)", 70, { Text = clan.desc })
		local open = clan.open
		ClanView.clanStatus(card, 2, function()
			return open
		end, function(v)
			open = v
		end)
		local save = MenuKit.button("primary", { LayoutOrder = 3, Size = UDim2.fromOffset(150, 40), FontFace = F.BOLD, TextSize = 14, Text = "SAVE", Parent = card })
		save.Activated:Connect(function()
			save.Text = "..."
			local ok, result = call("settings", { desc = desc.Text, open = open })
			save.Text = "SAVE"
			after(ok, result, true)
		end)
	end

	-- Join requests (officers)
	if clan.requests then
		MenuKit.heading(requestsPanel, n(), nil, "Join requests (" .. #clan.requests .. ")")
		if #clan.requests == 0 then
			MenuKit.paragraph(requestsPanel, n(), "No requests right now.", { TextSize = 14, TextTransparency = 0.5 })
		end
		for _, r in clan.requests do
			local line = ClanView.panel(requestsPanel,n(),"JoinRequest",0)
			local acc,dec = ClanView.requestRow(line,r)
			acc.Activated:Connect(function()
				local ok, result = call("accept", r.u)
				after(ok, result, true)
			end)
			dec.Activated:Connect(function()
				local ok, result = call("decline", r.u)
				after(ok, result, true)
			end)
		end
	end

	-- Members
	MenuKit.heading(membersPanel, n(), nil, "Members (" .. count .. "/" .. clan.max .. ")")
	for _, m in clan.members do
		local line = ClanView.panel(membersPanel,n(),"ClanMember",0)
		local btns = ClanView.memberRow(line,m,m.u==localPlayer.UserId,string.upper(ROLE_NAMES[m.r] or "Member"),ROLE_COLORS[m.r] or C.WHITE)
		local function action(text: string, op: string, kind: string, confirm: boolean)
			local props = { Size = UDim2.fromOffset(if #text > 7 then 112 else 76, 32), FontFace = F.BOLD, TextSize = 12, Text = text, Parent = btns }
			local function run()
				local ok, result = call(op, m.u)
				if ok and op == "transfer" then
					me.clan = result
				end
				after(ok, result, true)
			end
			if confirm then
				confirmButton(kind, props, run)
			else
				MenuKit.button(kind, props).Activated:Connect(run)
			end
		end
		if m.u ~= localPlayer.UserId then
			if clan.role == "leader" then
				if m.r == "member" then
					action("PROMOTE", "promote", "secondary", false)
				elseif m.r == "officer" then
					action("DEMOTE", "demote", "secondary", false)
				end
				action("MAKE LEADER", "transfer", "secondary", true)
				action("KICK", "kick", "gray", true)
			elseif clan.role == "officer" and m.r == "member" then
				action("KICK", "kick", "gray", true)
			end
		end
	end
	ClanView.decorate(body)
	page:layout(page.mobile)
	page.body.CanvasPosition = if keepScroll then scroll else Vector2.zero
end

-- Browse: search + list of clans (most wins first).
local function renderBrowse(page: any, me: any)
	page:clear()
	local controls=ClanView.browse(page)
	local box,list=controls.search,controls.list
	local fillToken=0
	local cached={}
	local filter=1
	local pageIndex=1
	local filterNames={"ALL CLANS ▾","OPEN CLANS ▾","BY REQUEST ▾"}
	local function clearRows()
		for _,c in list:GetChildren() do if c:IsA("GuiObject") then c:Destroy() end end
	end
	local function draw()
		if not controls.root.Parent then return end
		clearRows()
		local rows={}
		for _,c in cached do
			if filter==1 or (filter==2 and c.o) or (filter==3 and not c.o) then table.insert(rows,c) end
		end
		local pages=math.max(1,math.ceil(#rows/4))
		pageIndex=math.clamp(pageIndex,1,pages)
		controls.count.Text=pageIndex.." / "..pages
		controls.prev.Active=pageIndex>1;controls.next.Active=pageIndex<pages
		controls.prev.TextTransparency=if pageIndex>1 then 0 else 0.55
		controls.next.TextTransparency=if pageIndex<pages then 0 else 0.55
		if #rows==0 then
			MenuKit.paragraph(list,1,if box.Text~="" or filter~=1 then "No clans match that search." else "No clans yet. Be the first to create one!",{TextSize=15,TextColor3=C.GRAY300})
		end
		for j=(pageIndex-1)*4+1,math.min(pageIndex*4,#rows) do
			local c=rows[j]
			ClanView.browseRow(list,j,c,me.max or 50,function()
				local okView,clan=call("view",c.t)
				if not controls.root.Parent then return end
				if okView then
					renderClan(page,clan,me,function() render(page,"browse") end)
				else MenuKit.paragraph(list,1000,tostring(clan),{TextColor3=C.AMBER300}) end
			end)
		end
	end
	local function fill(query: string,silent: boolean?)
		fillToken+=1
		local token=fillToken
		local note
		if not silent then clearRows();note=MenuKit.paragraph(list,0,"Loading clans...",{TextSize=14,TextColor3=C.GRAY300}) end
		task.spawn(function()
			local ok,clans=call("list",query)
			if not controls.root.Parent or token~=fillToken then if note then note:Destroy() end;return end
			if note then note:Destroy() end
			if not ok or type(clans)~="table" then
				clearRows();MenuKit.paragraph(list,1,tostring(clans),{TextColor3=C.AMBER300});return
			end
			cached=clans;draw()
		end)
	end
	box.FocusLost:Connect(function() pageIndex=1;fill(box.Text) end)
	controls.filter.Activated:Connect(function() filter=filter%3+1;controls.filter.Text=filterNames[filter];pageIndex=1;draw() end)
	controls.prev.Activated:Connect(function() pageIndex=math.max(1,pageIndex-1);draw() end)
	controls.next.Activated:Connect(function() pageIndex+=1;draw() end)
	setLive(page,"browse",controls.root,{me=me,refresh=function() fill(box.Text,true) end})
	page:layout(page.mobile)
	fill("")
end

-- Create: name, tag, description, open; pay with medals or a Clan Charter (Robux).
local function renderCreate(page: any, me: any)
	live = {} -- a form being filled in: never refreshed under the player
	page:clear()
	local form=ClanView.create(page,me,localPlayer)
	local card=form.root
	local name,tag,desc=form.name,form.tag,form.desc
	local open = true
	ClanView.clanStatus(form.toggle, 6, function()
		return open
	end, function(v)
		open = v
	end)
	local preview = form.matchName
	local function updatePreview()
		local t = string.upper((string.gsub(tag.Text, "[^%w]", "")))
		if tag.Text ~= t then
			tag.Text = string.sub(t, 1, 5)
		end
		form.update(name.Text,string.sub(t,1,5))
	end
	tag:GetPropertyChangedSignal("Text"):Connect(updatePreview)
	name:GetPropertyChangedSignal("Text"):Connect(updatePreview)
	updatePreview()
	local row = form.actions
	local status = form.status
	local function create(pay: string)
		status.Text = "Creating..."
		local ok, result = call("create", { name = name.Text, tag = tag.Text, desc = desc.Text, open = open, pay = pay })
		if not ok then
			status.Text = tostring(result)
			return false
		end
		setTag(result.tag)
		render(page)
		return true
	end
	local medals = MenuKit.button("primary", { Size = UDim2.fromOffset(250, 44), FontFace = F.BOLD, TextSize = 15, Text = "CREATE · " .. numberText(me.cost) .. " MEDALS", Parent = row })
	medals.Activated:Connect(function()
		create("medals")
	end)
	if (me.tokens or 0) > 0 then
		local use = MenuKit.button("primary", { Size = UDim2.fromOffset(250, 44), FontFace = F.BOLD, TextSize = 15, Text = "USE CLAN CHARTER (x" .. me.tokens .. ")", Parent = row })
		use.Activated:Connect(function()
			create("charter")
		end)
	elseif (me.charterId or 0) ~= 0 then
		local robux = MenuKit.button("primary", { Size = UDim2.fromOffset(200, 44), FontFace = F.BOLD, TextSize = 15, Text = "CREATE · R$", Parent = row })
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfoAsync(me.charterId, Enum.InfoType.Product)
			end)
			if ok and type(info) == "table" and info.PriceInRobux then
				robux.Text = "CREATE · R$ " .. info.PriceInRobux
			end
		end)
		robux.Activated:Connect(function()
			if name.Text == "" or tag.Text == "" then
				status.Text = "Fill in a name and a tag first."
				return
			end
			local conn
			conn = MarketplaceService.PromptProductPurchaseFinished:Connect(function(uid, productId, bought)
				if uid ~= localPlayer.UserId or productId ~= me.charterId then
					return
				end
				conn:Disconnect()
				if not bought then
					return
				end
				-- The charter lands in the inventory when Roblox confirms the purchase.
				status.Text = "Purchase received, creating your clan..."
				for _ = 1, 6 do
					task.wait(1.5)
					if not status.Parent then
						return
					end
					local okMe, mine = call("me")
					if okMe and mine.tokens and mine.tokens > 0 then
						create("charter")
						return
					end
				end
				status.Text = "Your Clan Charter will be ready in a moment. Try again from this page."
			end)
			MarketplaceService:PromptProductPurchase(localPlayer, me.charterId)
		end)
	end
end

render = function(page: any, tab: string?)
	ClanView.prepare(page)
	page.title.Text = "CLANS"
	page:setTabs({})
	page:clear()
	local loading = MenuKit.paragraph(page.body, 1, "Loading...", { TextSize = 14, TextTransparency = 0.5 })
	task.spawn(function()
		local ok, me = call("me")
		if not loading.Parent then
			return
		end
		if not ok or type(me) ~= "table" then
			loading.Text = tostring(me)
			return
		end
		setTag(if me.clan then me.clan.tag else nil)
		local tabs = if me.clan
			then { { key = "mine", label = "My Clan" }, { key = "browse", label = "Browse" } }
			else { { key = "browse", label = "Browse" }, { key = "create", label = "Create Clan" } }
		local first = tab or tabs[1].key
		page:setTabs(tabs, first, function(key)
			if key == "mine" and me.clan then
				renderClan(page, me.clan, me)
			elseif key == "create" then
				renderCreate(page, me)
			else
				renderBrowse(page, me)
			end
		end)
	end)
end

function ClanPages.render(page: any)
	render(page)
end

-- Leaderboard tab: top clans by wins.
function ClanPages.renderBoard(page: any)
	page:clear()
	local body = page.body
	local widths = { 0.1, 0.46, 0.16, 0.14, 0.14 }
	local function rowFrame(order: number, values: { string }, header: boolean, mine: boolean?)
		local r = make("Frame", { LayoutOrder = order, BackgroundColor3 = if mine then C.MALIBU else C.WHITE, BackgroundTransparency = if header then 1 elseif mine then 0.75 else 0.96, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, if header then 28 else 40), Parent = body })
		MenuKit.corner(r, 8)
		local x = 0
		for i, v in values do
			MenuKit.text({ Position = UDim2.new(x, 12, 0, 0), Size = UDim2.new(widths[i], -12, 1, 0), FontFace = if header or i == 2 then F.BOLD else F.MEDIUM, TextSize = if header then 11 else 14, TextTransparency = if header then 0.5 else 0, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = if header then string.upper(v) else v, Parent = r })
			x += widths[i]
		end
	end
	local topNote = MenuKit.paragraph(body, 1, "Clans rank by wins: a clan wins when any of its members wins a game.", { TextSize = 12, TextTransparency = 0.6 })
	rowFrame(2, { "Rank", "Clan", "Wins", "Games", "Members" }, true)
	local loading = MenuKit.paragraph(body, 3, "Loading clans...", { TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 0.6 })
	setLive(page, "board", topNote) -- the note at the top stays while rows reload
	task.spawn(function()
		local ok, clans = call("list", "")
		if not loading.Parent then
			return
		end
		if not ok or type(clans) ~= "table" then
			loading.Text = "Error loading leaderboard"
			return
		end
		if #clans == 0 then
			loading.Text = "No clans yet"
			return
		end
		loading:Destroy()
		local mine = playerGui:GetAttribute("WFClanTag")
		for i, c in clans do
			rowFrame(3 + i, { "#" .. i, "[" .. c.t .. "] " .. tostring(c.n), numberText(c.w), numberText(c.g), tostring(c.m) }, false, c.t == mine)
		end
	end)
end

-- Profile > Clans: the player's clan at a glance.
function ClanPages.summary(body: Instance, order: number)
	local card = MenuKit.card(body, order, 16, 14, 6)
	local line = MenuKit.paragraph(card, 1, "Loading...", { TextSize = 14, TextTransparency = 0.5 })
	task.spawn(function()
		local ok, me = call("me")
		if not line.Parent then
			return
		end
		if not ok or type(me) ~= "table" then
			line.Text = tostring(me)
			return
		end
		if not me.clan then
			setTag(nil)
			line.Text = "You're not in a clan. Open Clans in the menu to join or create one."
			return
		end
		local c = me.clan
		setTag(c.tag)
		line.Text = "[" .. c.tag .. "] " .. c.name
		line.FontFace = F.BOLD
		line.TextSize = 20
		line.TextTransparency = 0
		MenuKit.paragraph(card, 2, (ROLE_NAMES[c.role] or "Member") .. "  ·  Rank #" .. tostring(c.rank or "-") .. "  ·  " .. numberText(c.wins) .. " wins  ·  " .. #c.members .. "/" .. c.max .. " members", { TextSize = 13, TextTransparency = 0.45 })
	end)
end

-- Refreshes whatever the live view shows (server push or the periodic check).
local function refreshLive()
	local v = live
	local page = v.page
	if not page or not v.marker or not v.marker.Parent then
		return
	end
	local focused = game:GetService("UserInputService"):GetFocusedTextBox()
	if focused and focused:IsDescendantOf(page.body) then
		return -- typing (search, description): don't redraw under the player
	end
	if v.kind == "board" then
		local scroll = page.body.CanvasPosition
		ClanPages.renderBoard(page)
		task.delay(0.5, function()
			page.body.CanvasPosition = scroll
		end)
		return
	end
	local ok, me = call("me")
	if not ok or type(me) ~= "table" or live ~= v or not v.marker.Parent then
		return
	end
	setTag(if me.clan then me.clan.tag else nil)
	local wasIn = v.me and v.me.clan ~= nil
	local isIn = me.clan ~= nil
	if wasIn ~= isIn or (v.kind == "mine" and not isIn) then
		render(page) -- joined / accepted / kicked / disbanded: the tabs change
		return
	end
	if v.kind == "mine" then
		renderClan(page, me.clan, me, nil, true)
	elseif v.kind == "clan" then
		local okView, clan = call("view", v.tag)
		if okView and type(clan) == "table" and live == v and v.marker.Parent then
			renderClan(page, clan, me, v.back, true)
		end
	elseif v.kind == "browse" and v.refresh then
		v.me = me
		v.refresh()
	end
end

-- Server pushes ("changed", TAG) are bundled (at most one refresh a second); browse, the
-- leaderboard and your own clan are also re-checked every 20 s in case a push was missed.
do
	local pending, lastPoll = false, os.clock()
	task.spawn(function()
		local ev = Shared:WaitForChild("ClanEvent", 30)
		if ev and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(function(kind: string, tag: any)
				if kind ~= "changed" then
					return
				end
				local v = live
				local mine = tag == playerGui:GetAttribute("WFClanTag")
				if v.kind == "browse" or v.kind == "board" or mine or (v.kind == "clan" and v.tag == tag) then
					pending = true -- lists show every clan; otherwise only ours or the one on screen
				end
			end)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local v = live
			local due = pending or (v.kind ~= nil and v.kind ~= "clan" and os.clock() - lastPoll > 20)
			if due and v.marker and v.marker.Parent then
				pending = false
				lastPoll = os.clock()
				pcall(refreshLive)
			elseif pending then
				pending = false
				ClanPages.refreshTag() -- page closed: keep the menu's TAG button current
			end
		end
	end)
end

function ClanPages.refreshTag()
	task.spawn(function()
		local ok, me = call("me")
		if ok and type(me) == "table" then
			setTag(if me.clan then me.clan.tag else nil)
		end
	end)
end

return ClanPages
