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
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make

local Shared = ReplicatedStorage:WaitForChild("Shared")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local ClanPages = {}

local ROLE_NAMES = { leader = "Leader", officer = "Officer", member = "Member" }
local ROLE_COLORS = { leader = C.CYBER, officer = C.AQUARIUS, member = C.GRAY300 }

local function call(op: string, arg: any?): (boolean, any)
	local ok, success, result = pcall(function()
		return Shared:WaitForChild("ClanFn"):InvokeServer(op, arg)
	end)
	if not ok then
		return false, "Couldn't reach the server, try again."
	end
	return success == true, result
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
	local b = MenuKit.button(kind, props)
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

-- One clan: header, stats, join / leave, settings, requests and members.
local function renderClan(page: any, clan: any, me: any, back: (() -> ())?)
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
		local b = MenuKit.button("secondary", { LayoutOrder = n(), Size = UDim2.fromOffset(120, 34), FontFace = F.BOLD, TextSize = 13, Text = "< BACK", Parent = body })
		b.Activated:Connect(back)
	end

	-- Header
	local head = MenuKit.card(body, n(), 16, 14, 8)
	local row = make("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = head })
	MenuKit.list(row, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	tagBadge(row, clan.tag, 34)
	MenuKit.text({ Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, FontFace = F.BOLD, TextSize = 24, Text = clan.name, Parent = row })
	if clan.desc ~= "" then
		MenuKit.paragraph(head, 2, clan.desc, { TextSize = 14, TextTransparency = 0.3 })
	end
	local count = #clan.members
	MenuKit.paragraph(head, 3, table.concat({
		"Rank #" .. tostring(clan.rank or "-"),
		numberText(clan.wins) .. " wins",
		numberText(clan.games) .. " games",
		"Win rate " .. winRate(clan.wins, clan.games),
		count .. "/" .. clan.max .. " members",
		if clan.open then "Open to join" else "Join by request",
	}, "  ·  "), { TextSize = 13, TextTransparency = 0.45 })

	-- Join / leave
	local actions = make("Frame", { LayoutOrder = 4, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = head })
	MenuKit.list(actions, true, 8)
	local inClan = me and me.clan ~= nil
	if clan.role then
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
		MenuKit.heading(body, n(), "Gear", "Clan settings")
		local card = MenuKit.card(body, n(), 16, 14, 10)
		local desc = textBox(card, 1, "Description (up to 120 characters)", 70, { Text = clan.desc })
		local open = clan.open
		MenuKit.toggleRow(card, 2, "Open clan", "Anyone can join without a request", function()
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
		MenuKit.heading(body, n(), "People", "Join requests (" .. #clan.requests .. ")")
		if #clan.requests == 0 then
			MenuKit.paragraph(body, n(), "No requests right now.", { TextSize = 14, TextTransparency = 0.5 })
		end
		for _, r in clan.requests do
			local line = MenuKit.card(body, n(), 12, 8, 0)
			local inner = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = line })
			MenuKit.text({ Size = UDim2.new(1, -230, 1, 0), FontFace = F.BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(r.n), Parent = inner })
			local acc = MenuKit.button("primary", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -112, 0.5, 0), Size = UDim2.fromOffset(104, 32), FontFace = F.BOLD, TextSize = 13, Text = "ACCEPT", Parent = inner })
			local dec = MenuKit.button("gray", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(104, 32), FontFace = F.BOLD, TextSize = 13, Text = "DECLINE", Parent = inner })
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
	MenuKit.heading(body, n(), "People", "Members (" .. count .. "/" .. clan.max .. ")")
	for _, m in clan.members do
		local line = MenuKit.card(body, n(), 12, 8, 0)
		local inner = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = line })
		local av = make("ImageLabel", { Size = UDim2.fromOffset(36, 36), BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.9, Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(m.u) .. "&w=48&h=48", Parent = inner })
		MenuKit.round(av)
		MenuKit.text({ Position = UDim2.fromOffset(46, 0), Size = UDim2.new(1, -380, 1, 0), FontFace = F.BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(m.n) .. (if m.u == localPlayer.UserId then "  (you)" else ""), Parent = inner })
		local role = MenuKit.text({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(1, -330, 0.5, 0), Size = UDim2.fromOffset(80, 22), FontFace = F.BOLD, TextSize = 12, TextColor3 = ROLE_COLORS[m.r] or C.WHITE, Text = string.upper(ROLE_NAMES[m.r] or "Member"), Parent = inner })
		role.TextXAlignment = Enum.TextXAlignment.Left
		-- Actions this viewer may take on this member.
		local btns = make("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(240, 32), BackgroundTransparency = 1, Parent = inner })
		MenuKit.list(btns, true, 6, { HorizontalAlignment = Enum.HorizontalAlignment.Right })
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
	page.body.CanvasPosition = Vector2.zero
end

-- Browse: search + list of clans (most wins first).
local function renderBrowse(page: any, me: any)
	page:clear()
	local body = page.body
	local box = textBox(body, 1, "Search clans by tag or name")
	local list = make("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
	MenuKit.list(list, false, 8)
	local function fill(query: string)
		for _, c in list:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local note = MenuKit.paragraph(list, 0, "Loading clans...", { TextSize = 14, TextTransparency = 0.5 })
		task.spawn(function()
			local ok, clans = call("list", query)
			if not note.Parent then
				return
			end
			if not ok or type(clans) ~= "table" then
				note.Text = tostring(clans)
				return
			end
			if #clans == 0 then
				note.Text = if query ~= "" then "No clans match that search." else "No clans yet. Be the first to create one!"
				return
			end
			note:Destroy()
			for i, c in clans do
				local row = make("TextButton", { LayoutOrder = i, Text = "", AutoButtonColor = false, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 56), Parent = list })
				MenuKit.corner(row, 12)
				local st = MenuKit.stroke(row, 0.9)
				MenuKit.hover(row, function(s)
					row.BackgroundTransparency = if s == "idle" then 0.95 else 0.9
					st.Transparency = if s == "idle" then 0.9 else 0.7
				end)
				MenuKit.text({ Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(36, 56), FontFace = F.BOLD, TextSize = 14, TextTransparency = 0.4, Text = "#" .. i, Parent = row })
				local badge = tagBadge(row, c.t)
				badge.AnchorPoint = Vector2.new(0, 0.5)
				badge.Position = UDim2.new(0, 54, 0.5, 0)
				MenuKit.text({ Position = UDim2.fromOffset(150, 8), Size = UDim2.new(1, -330, 0, 22), FontFace = F.BOLD, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(c.n), Parent = row })
				MenuKit.text({ Position = UDim2.fromOffset(150, 30), Size = UDim2.new(1, -330, 0, 18), TextSize = 12, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, Text = c.m .. " members  ·  " .. (if c.o then "Open" else "By request"), Parent = row })
				MenuKit.text({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0), Size = UDim2.fromOffset(160, 20), FontFace = F.BOLD, TextSize = 14, TextColor3 = C.CYBER, TextXAlignment = Enum.TextXAlignment.Right, Text = numberText(c.w) .. " wins", Parent = row })
				row.Activated:Connect(function()
					local okView, clan = call("view", c.t)
					if okView then
						renderClan(page, clan, me, function()
							render(page, "browse")
						end)
					end
				end)
			end
		end)
	end
	box.FocusLost:Connect(function()
		fill(box.Text)
	end)
	fill("")
end

-- Create: name, tag, description, open; pay with medals or a Clan Charter (Robux).
local function renderCreate(page: any, me: any)
	page:clear()
	local body = page.body
	local card = MenuKit.card(body, 1, 16, 16, 10)
	MenuKit.paragraph(card, 1, "Create a clan", { FontFace = F.BOLD, TextSize = 20 })
	MenuKit.paragraph(card, 2, "Your tag shows in front of your name in every match, and clanmates are put on the same team.", { TextSize = 14, TextTransparency = 0.4 })
	local name = textBox(card, 3, "Clan name (3-24 characters)")
	local tag = textBox(card, 4, "Tag (2-5 letters or numbers)")
	local desc = textBox(card, 5, "Description (optional, up to 120 characters)", 70)
	local open = true
	MenuKit.toggleRow(card, 6, "Open clan", "Anyone can join without a request", function()
		return open
	end, function(v)
		open = v
	end)
	local preview = MenuKit.paragraph(card, 7, "", { FontFace = F.BOLD, TextSize = 16, TextColor3 = C.AQUARIUS })
	local function updatePreview()
		local t = string.upper((string.gsub(tag.Text, "[^%w]", "")))
		if tag.Text ~= t then
			tag.Text = string.sub(t, 1, 5)
		end
		preview.Text = if t ~= "" then "In matches: [" .. string.sub(t, 1, 5) .. "] " .. localPlayer.DisplayName else ""
	end
	tag:GetPropertyChangedSignal("Text"):Connect(updatePreview)
	updatePreview()
	local row = make("Frame", { LayoutOrder = 8, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), Parent = card })
	MenuKit.list(row, true, 8)
	local status = MenuKit.paragraph(card, 9, "", { TextSize = 14, TextColor3 = C.AMBER300 })
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
				return MarketplaceService:GetProductInfo(me.charterId, Enum.InfoType.Product)
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
			else { { key = "browse", label = "Browse" }, { key = "create", label = "Create" } }
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
	MenuKit.paragraph(body, 1, "Clans rank by wins: a clan wins when any of its members wins a game.", { TextSize = 12, TextTransparency = 0.6 })
	rowFrame(2, { "Rank", "Clan", "Wins", "Games", "Members" }, true)
	local loading = MenuKit.paragraph(body, 3, "Loading clans...", { TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 0.6 })
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

function ClanPages.refreshTag()
	task.spawn(function()
		local ok, me = call("me")
		if ok and type(me) == "table" then
			setTag(if me.clan then me.clan.tag else nil)
		end
	end)
end

return ClanPages
