-- War Front Night menu: My items. Copyright (C) 2026 Liam (lacedsc3ne).
-- Colour logic mirrors MenuPages (renderInventory / renderInventoryTab, MenuPages.inventoryColours,
-- ownsColor, and the old store's colour cards) and MetaConfig.COLORS: equip with MetaFn "equipColor",
-- buy with "buyColor" (asks first), group colour through Roblox's join-group prompt + "groupCheck",
-- and the All Colours game pass prompt. Boost counts come from profile.boosts.
-- Titles: profile.titles (owned ids) / profile.title, MetaFn "equipTitle" (id or "" to remove).
-- Flags: any Shared.Flags code from the MapCatalog nations, MetaFn "equipFlag" (code or "" to remove).

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local Art = require(script.Parent.Parent:WaitForChild("Art"))
local MetaConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MetaConfig"))
local Flags = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Flags"))
local MapCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapCatalog"))
local FlagKit = require(script.Parent.Parent.Parent:WaitForChild("FlagKit"))

local C, F = Kit.C, Kit.F
local make = Kit.make
local G = MetaConfig.GROUP
local TEAL = Color3.fromRGB(45, 212, 191)
local AUTO_Y = Enum.AutomaticSize.Y
local CENTER = Enum.HorizontalAlignment.Center
local MIDDLE = Enum.VerticalAlignment.Center
local NOT_ENOUGH = "Not enough medals. Get more in the Shop"

local TABS = {
	{ "colours", "Colours" },
	{ "boosts", "Boosts" },
	{ "titles", "Titles" },
	{ "flags", "Flags" },
}

-- Titles in season pass order (shared with the server's season pass rewards).
local TITLES = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SeasonTitles")).ORDER

local FLAG_PAGE = 40 -- flag tiles drawn at a time ("Show more" adds the next lot)

local BOOST_LOOK = {
	goldCrate = { name = "Gold crate", icon = "Coins", color = C.YELLOW },
	reinforcements = { name = "Reinforcements", icon = "Users", color = C.CYAN },
	shield = { name = "Shield", icon = "Shield", color = C.GREEN },
	nukeVoucher = { name = "Free nuke", icon = "Rocket", color = C.PINK },
}

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

-- Robux price of the All Colours pass (MenuPages.marketInfo), fetched once.
local marketCache: { [string]: any } = {}
local marketListeners: { [() -> ()]: boolean } = {}
local function marketInfo(isPass: boolean, id: number): any?
	local k = (if isPass then "pass" else "prod") .. id
	local v = marketCache[k]
	if v == nil then
		marketCache[k] = false
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfoAsync(id, if isPass then Enum.InfoType.GamePass else Enum.InfoType.Product)
			end)
			if ok and type(info) == "table" then
				marketCache[k] = info
				for fn in marketListeners do
					task.spawn(fn)
				end
			end
		end)
	end
	return v or nil
end

local function ownsColor(p: any, c: any): boolean
	if c.group then
		return p.inGroup == true -- group members only (MetaConfig.GROUP)
	end
	return c.price == 0 or p.allColors == true or (type(p.ownedColors) == "table" and table.find(p.ownedColors, c.id) ~= nil)
end

-- "using" | "owned" | "group" (join to use) | "level" (too low to buy) | "price" (buy with medals)
local function colourState(p: any, c: any): string
	if p.color == c.id then
		return "using"
	elseif ownsColor(p, c) then
		return "owned"
	elseif c.group then
		return "group"
	elseif (tonumber(p.level) or 1) < c.level then
		return "level"
	end
	return "price"
end

local function stateLook(state: string, c: any): (string?, string, Color3)
	if state == "using" then
		return nil, "Using", C.YELLOW
	elseif state == "owned" then
		return nil, "Owned", C.GREEN
	elseif state == "group" then
		return nil, "Group only", TEAL
	elseif state == "level" then
		return "Lock", "Level " .. c.level, C.MUTED
	end
	return "Medal", numberText(c.price), C.YELLOW
end

local function colourOf(c: any): Color3
	return Color3.fromRGB(c.rgb[1], c.rgb[2], c.rgb[3])
end

-- Small builders -------------------------------------------------------------------------------

local function wrapText(parent: Instance, order: number, text: string, size: number, color: Color3?, font: Font?, align: Enum.TextXAlignment?): TextLabel
	return Kit.text({
		Text = text,
		TextSize = size,
		TextColor3 = color or C.TEXT,
		FontFace = font or F.BODY,
		TextWrapped = true,
		TextXAlignment = align or Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = AUTO_Y,
		LayoutOrder = order,
		Parent = parent,
	})
end

local function iconSquare(parent: Instance, icon: string, color: Color3, size: number, order: number, dim: boolean?): Frame
	local sq = make("Frame", { Name = "IconSquare", BackgroundColor3 = color, BackgroundTransparency = if dim then 0.92 else 0.8, BorderSizePixel = 0, Size = UDim2.fromOffset(size, size), LayoutOrder = order, Parent = parent })
	Kit.corner(sq, math.floor(size * 0.28))
	Kit.icon(icon, { Name = "Icon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.58, 0.58), ImageColor3 = color, ImageTransparency = if dim then 0.55 else 0, Parent = sq })
	return sq
end

local function grid(parent: Instance, order: number, cols: number, cellH: number, gap: number, width: UDim?): Frame
	local g = make("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.new(width or UDim.new(1, 0), UDim.new(0, 0)), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	make("UIGridLayout", {
		CellPadding = UDim2.fromOffset(gap, gap),
		CellSize = UDim2.new(1 / cols, -math.ceil(gap * (cols - 1) / cols), 0, cellH),
		FillDirectionMaxCells = cols,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = g,
	})
	return g
end

-- Actions (same server calls as MenuPages) -----------------------------------------------------

-- MetaFn op, then show the server's message. The server pushes the new profile itself, which
-- redraws the page through ctx.onProfile.
local function invoke(ctx: any, op: string, arg: any?, fallback: string?)
	task.spawn(function()
		local ok, msg = ctx.meta(op, arg)
		local text = if type(msg) == "string" then msg elseif ok then "" else (fallback or "Something went wrong, try again")
		if not ok and text == "Not enough medals" then
			text = NOT_ENOUGH
		end
		if text ~= "" then
			ctx.toast(text, if ok then "ok" else "error")
		end
	end)
end

-- Roblox's join-group prompt, then the server checks membership and gives the rewards.
local function joinGroup(ctx: any)
	task.spawn(function()
		local ok = pcall(function()
			game:GetService("GroupService"):PromptJoinAsync(G.id)
		end)
		if not ok then
			ctx.toast("Open the group page on Roblox to join: " .. G.name, "info")
		end
		invoke(ctx, "groupCheck")
	end)
end

local function confirmColour(ctx: any, c: any)
	local p = ctx.profile()
	local coins = tonumber(p and p.coins) or 0
	local pop = ctx.popup({ width = 380, accent = C.YELLOW })
	local card = pop.card
	Kit.list(card, false, 12, { HorizontalAlignment = CENTER })
	local sw = make("Frame", { Name = "Swatch", BackgroundColor3 = colourOf(c), BorderSizePixel = 0, Size = UDim2.fromOffset(64, 64), LayoutOrder = 1, Parent = card })
	Kit.corner(sw)
	Kit.stroke(sw, C.LINE, 2)
	Kit.text({ Text = "Buy " .. c.name .. "?", FontFace = F.TITLE, TextSize = 22, LayoutOrder = 2, Parent = card })
	wrapText(card, 3, "Your land colour in every battle, from your next one", 15, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
	local cost = make("Frame", { Name = "Cost", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 4, Parent = card })
	Kit.list(cost, true, 6, { VerticalAlignment = MIDDLE })
	Kit.icon("Medal", { Size = UDim2.fromOffset(18, 18), ImageColor3 = C.YELLOW, LayoutOrder = 1, Parent = cost })
	Kit.text({ Text = numberText(c.price) .. " medals · you have " .. numberText(coins), FontFace = F.BOLD, TextSize = 15, TextColor3 = C.YELLOW, LayoutOrder = 2, Parent = cost })
	local buttons = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 5, Parent = card })
	Kit.list(buttons, true, 10)
	Kit.button("secondary", "Cancel", { height = 46, size = UDim2.new(0.5, -5, 0, 46), layoutOrder = 1, parent = buttons, onActivated = function()
		pop.close()
	end })
	Kit.button("primary", "Buy", { name = "Buy", height = 46, size = UDim2.new(0.5, -5, 0, 46), layoutOrder = 2, parent = buttons, onActivated = function()
		pop.close()
		invoke(ctx, "buyColor", c.id)
	end })
end

-- Owned -> equip (MenuPages.inventoryColours), group -> join, level-locked -> say why,
-- otherwise buy with medals (old store colour card).
local function colourAction(ctx: any, c: any)
	local p = ctx.profile()
	if not p then
		return
	end
	local state = colourState(p, c)
	if state == "owned" then
		invoke(ctx, "equipColor", c.id, "Couldn't use this colour. Try again")
	elseif state == "group" then
		joinGroup(ctx)
	elseif state == "level" then
		ctx.toast("Reach level " .. c.level .. " to unlock " .. c.name, "info")
	elseif state == "price" then
		if (tonumber(p.coins) or 0) < c.price then
			ctx.toast(NOT_ENOUGH, "error")
		else
			confirmColour(ctx, c)
		end
	end
end

-- Colours tab ----------------------------------------------------------------------------------

local function colourTile(parent: Instance, order: number, p: any, c: any, selected: boolean, onClick: () -> ())
	local state = colourState(p, c)
	local using = state == "using"
	local dim = state == "level"
	local b = make("TextButton", {
		Name = "Colour_" .. c.id,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = if selected then C.RAISED else C.CARD,
		BorderSizePixel = 0,
		LayoutOrder = order,
		SelectionImageObject = Kit.ring,
		Parent = parent,
	})
	Kit.corner(b, 12)
	Kit.stroke(b, if using then C.YELLOW elseif selected then C.MUTED else C.LINE, if using then 2 else 1.5)
	Kit.pad(b, 8, 8, 12, 10)
	Kit.list(b, false, 6, { HorizontalAlignment = CENTER })
	local circle = make("Frame", { Name = "Swatch", BackgroundColor3 = colourOf(c), BackgroundTransparency = if dim then 0.55 else 0, BorderSizePixel = 0, Size = UDim2.fromOffset(46, 46), LayoutOrder = 1, Parent = b })
	Kit.corner(circle)
	Kit.stroke(circle, C.LINE, 1.5)
	Kit.text({ Text = c.name, FontFace = F.BOLD, TextSize = 15, TextColor3 = if dim then C.MUTED else C.TEXT, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 2, Parent = b })
	local line = make("Frame", { Name = "State", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 3, Parent = b })
	Kit.list(line, true, 4, { VerticalAlignment = MIDDLE })
	local icon, text, color = stateLook(state, c)
	if icon then
		Kit.icon(icon, { Size = UDim2.fromOffset(15, 15), ImageColor3 = color, LayoutOrder = 1, Parent = line })
	end
	Kit.text({ Text = text, FontFace = F.TITLE, TextSize = 14, TextColor3 = color, LayoutOrder = 2, Parent = line })
	local base = b.BackgroundColor3
	Kit.hover(b, function(s)
		b.BackgroundColor3 = if s == "idle" then base else C.RAISED:Lerp(C.WHITE, 0.06)
	end)
	b.Activated:Connect(onClick)
	return b
end

-- A little piece of map: the player's land (three overlapping blobs with a darker rim) between two
-- neighbours, on the sea.
local function territory(parent: Instance, order: number, colour: Color3): Frame
	local sea = make("Frame", { Name = "Territory", BackgroundColor3 = C.DEEP, BorderSizePixel = 0, ClipsDescendants = true, Size = UDim2.new(1, 0, 0, 150), LayoutOrder = order, Parent = parent })
	Kit.corner(sea, 10)
	Kit.stroke(sea)
	-- A blob is a rounded frame; its rim is a slightly bigger frame behind it. Overlapping blobs of
	-- one land draw all rims first, then all fills, so only the outer edge shows.
	local function shapes(list: { any }, fill: Color3, rim: Color3, z: number)
		for _, b in list do
			local edge = make("Frame", { Name = "Rim", BackgroundColor3 = rim, BorderSizePixel = 0, Position = UDim2.new(b[1], -3, b[2], -3), Size = UDim2.new(b[3], 6, b[4], 6), ZIndex = z, Parent = sea })
			Kit.corner(edge, b[5] + 3)
		end
		for _, b in list do
			local f = make("Frame", { Name = "Land", BackgroundColor3 = fill, BorderSizePixel = 0, Position = UDim2.fromScale(b[1], b[2]), Size = UDim2.fromScale(b[3], b[4]), ZIndex = z + 1, Parent = sea })
			Kit.corner(f, b[5])
		end
	end
	shapes({ { -0.08, 0.62, 0.42, 0.55, 34 } }, C.MAP_LAND, C.MAP_EDGE, 1)
	shapes({ { 0.74, -0.15, 0.4, 0.6, 34 } }, C.MAP_LAND, C.MAP_EDGE, 1)
	shapes({ { 0.24, 0.16, 0.42, 0.52, 34 }, { 0.46, 0.34, 0.34, 0.48, 30 }, { 0.32, 0.5, 0.26, 0.36, 22 } }, colour, colour:Lerp(Color3.new(0, 0, 0), 0.35), 3)
	local _, sat, val = colour:ToHSV()
	Kit.icon("Flag", { Name = "Capital", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.45, 0.42), Size = UDim2.fromOffset(20, 20), ImageColor3 = if val > 0.85 and sat < 0.3 then C.BG else C.WHITE, ZIndex = 5, Parent = sea })
	return sea
end

local function previewCard(parent: Instance, order: number, p: any, c: any, width: UDim2)
	local card = Kit.card({ Name = "Preview", Size = width, AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	Kit.pad(card, 14, 14, 14, 16)
	Kit.list(card, false, 8)
	territory(card, 1, colourOf(c))
	local head = make("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 2, Parent = card })
	Kit.list(head, true, 8, { VerticalAlignment = MIDDLE })
	Kit.text({ Text = c.name, FontFace = F.TITLE, TextSize = 20, LayoutOrder = 1, Parent = head })
	local icon, text, color = stateLook(colourState(p, c), c)
	if icon then
		Kit.icon(icon, { Size = UDim2.fromOffset(15, 15), ImageColor3 = color, LayoutOrder = 2, Parent = head })
	end
	Kit.text({ Text = text, FontFace = F.TITLE, TextSize = 14, TextColor3 = color, LayoutOrder = 3, Parent = head })
	wrapText(card, 3, "This is how your land looks in battle", 14, C.MUTED)
	local id = MetaConfig.GAMEPASS.AllColors
	if not p.allColors and id ~= 0 then
		local info = marketInfo(true, id)
		local price = info and tonumber(info.PriceInRobux)
		Kit.button("secondary", "Unlock every colour" .. (if price then " · R$ " .. price else ""), {
			name = "AllColours",
			icon = "Palette",
			iconColor = C.GREEN,
			height = 42,
			textSize = 15,
			padX = 10,
			size = UDim2.new(1, 0, 0, 42),
			layoutOrder = 4,
			parent = card,
			onActivated = function()
				MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, id)
			end,
		})
	end
	return card
end

local function drawColours(content: Instance, ctx: any, p: any, phone: boolean, selected: string, onSelect: (string) -> ())
	local pick = MetaConfig.color(selected) or MetaConfig.COLORS[1]
	local row = make("Frame", { Name = "Colours", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = content })
	Kit.list(row, not phone, 14)
	local g = grid(row, 1, if phone then 3 else 5, 124, 12, if phone then UDim.new(1, 0) else UDim.new(1, -314))
	for i, c in MetaConfig.COLORS do
		colourTile(g, i, p, c, c.id == pick.id, function()
			onSelect(c.id)
			colourAction(ctx, c)
		end)
	end
	previewCard(row, 2, p, pick, if phone then UDim2.new(1, 0, 0, 0) else UDim2.fromOffset(300, 0))
end

-- Titles tab -----------------------------------------------------------------------------------

local function stateLine(parent: Instance, order: number, icon: string?, text: string, color: Color3, font: Font?)
	local line = make("Frame", { Name = "State", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, Parent = parent })
	Kit.list(line, true, 4, { VerticalAlignment = MIDDLE })
	if icon then
		Kit.icon(icon, { Size = UDim2.fromOffset(14, 14), ImageColor3 = color, LayoutOrder = 1, Parent = line })
	end
	Kit.text({ Name = "Text", Text = text, FontFace = font or F.TITLE, TextSize = 14, TextColor3 = color, LayoutOrder = 2, Parent = line })
	return line
end

local function pickCard(parent: Instance, name: string, order: number, using: boolean, onClick: () -> ()): TextButton
	local b = make("TextButton", {
		Name = name,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.CARD,
		BorderSizePixel = 0,
		LayoutOrder = order,
		SelectionImageObject = Kit.ring,
		Parent = parent,
	})
	Kit.corner(b, 12)
	Kit.stroke(b, if using then C.YELLOW else C.LINE, if using then 2 else 1.5)
	Kit.hover(b, function(s)
		b.BackgroundColor3 = if s == "idle" then C.CARD else C.RAISED
	end)
	b.Activated:Connect(onClick)
	return b
end

local function drawTitles(content: Instance, ctx: any, p: any, phone: boolean)
	wrapText(content, 1, "Earn titles from the season pass. Your title shows on your profile.", 14, C.MUTED)
	local g = grid(content, 2, if phone then 2 else 4, 132, 12)
	local owned = if type(p.titles) == "table" then p.titles else {}
	local current = if type(p.title) == "string" and p.title ~= "" then p.title else nil

	local none = pickCard(g, "Title_none", 0, current == nil, function()
		if current ~= nil then
			invoke(ctx, "equipTitle", "", "Couldn't remove your title. Try again")
		end
	end)
	Kit.pad(none, 12, 12, 14, 12)
	Kit.list(none, false, 6, { HorizontalAlignment = CENTER, VerticalAlignment = MIDDLE })
	Kit.text({ Name = "Name", Text = "No title", FontFace = F.TITLE, TextSize = 18, TextColor3 = C.MUTED, LayoutOrder = 1, Parent = none })
	if current == nil then
		stateLine(none, 2, nil, "Using", C.YELLOW)
	else
		stateLine(none, 2, nil, "Tap to remove", C.MUTED, F.BODY)
	end

	for i, t in TITLES do
		local id, name = t[1], t[2]
		local has = table.find(owned, id) ~= nil
		local using = current == id
		local b = pickCard(g, "Title_" .. id, i, using, function()
			if not has then
				ctx.toast("Unlock " .. name .. " in the season pass", "info")
			elseif not using then
				invoke(ctx, "equipTitle", id, "Couldn't use this title. Try again")
			end
		end)
		Kit.pad(b, 12, 12, 10, 10)
		Kit.list(b, false, 4, { HorizontalAlignment = CENTER, VerticalAlignment = MIDDLE })
		if Art.title(id) then
			Art.image(Art.title(id), { Name = "Badge", Size = UDim2.fromOffset(52, 52), ImageTransparency = if has then 0 else 0.55, LayoutOrder = 0, Parent = b })
		end
		Kit.text({
			Name = "Name",
			Text = name,
			FontFace = F.TITLE,
			TextSize = 18,
			TextColor3 = if has then C.TEXT else C.MUTED,
			TextTransparency = if has then 0 else 0.35,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 22),
			LayoutOrder = 1,
			Parent = b,
		})
		if using then
			stateLine(b, 2, nil, "Using", C.YELLOW)
		elseif has then
			stateLine(b, 2, nil, "Tap to use", C.MUTED, F.BODY)
		else
			stateLine(b, 2, "Lock", "Season pass reward", C.MUTED, F.BODY)
		end
	end
end

-- Flags tab ------------------------------------------------------------------------------------

-- Every flag code used by a map's nations (deduped, only codes Shared.Flags can draw), built once.
local flagList: { { code: string, name: string, search: string } }? = nil
local function allFlags(): { { code: string, name: string, search: string } }
	if flagList then
		return flagList
	end
	local list, byCode = {}, {}
	for _, map in MapCatalog do
		if type(map) == "table" and type(map.nations) == "table" then
			for _, n in map.nations do
				local name, code = n[1], n[4]
				if type(code) == "string" and code ~= "" and Flags.has(code) then
					local e = byCode[code]
					if not e then
						e = { code = code, name = if type(name) == "string" then name else string.upper(code), search = string.lower(code) }
						byCode[code] = e
						table.insert(list, e)
					end
					if type(name) == "string" then
						e.search ..= "\n" .. string.lower(name)
					end
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	flagList = list
	return list
end

-- Draws the flags tab and returns update(profile), which restyles the tiles in place so the
-- search box keeps its text and focus when the profile changes.
local function drawFlags(content: Instance, ctx: any, p: any, phone: boolean, state: { query: string }): (any) -> ()
	local current: string? = if type(p.flag) == "string" and p.flag ~= "" then p.flag else nil
	local tiles: { [string]: { stroke: UIStroke, state: TextLabel } } = {}
	local shown = FLAG_PAGE

	wrapText(content, 1, "Your flag shows next to your name in battles.", 14, C.MUTED)

	local searchRow = make("Frame", { Name = "Search", BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 2, Parent = content })
	Kit.corner(searchRow, 10)
	Kit.stroke(searchRow)
	make("UISizeConstraint", { MaxSize = Vector2.new(420, 44), Parent = searchRow })
	Kit.icon("Search", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(18, 18), ImageColor3 = C.MUTED, Parent = searchRow })
	local box = make("TextBox", {
		Name = "SearchBox",
		Text = state.query,
		PlaceholderText = "Search by country or code",
		PlaceholderColor3 = C.MUTED,
		ClearTextOnFocus = false,
		FontFace = F.BOLD,
		TextSize = 16,
		TextColor3 = C.TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(40, 0),
		Size = UDim2.new(1, -52, 1, 0),
		SelectionImageObject = Kit.ring,
		Parent = searchRow,
	})

	local g = grid(content, 3, if phone then 3 else 5, 116, 10)
	local moreHolder = make("Frame", { Name = "More", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 4, Parent = content })
	Kit.list(moreHolder, false, 8, { HorizontalAlignment = CENTER })

	local function style(code: string)
		local t = tiles[code]
		if t then
			local using = code == (current or "")
			t.stroke.Color = if using then C.YELLOW else C.LINE
			t.stroke.Thickness = if using then 2 else 1.5
			t.state.Visible = using
		end
	end

	local function tile(code: string, name: string, order: number)
		local b = pickCard(g, "Flag_" .. (if code == "" then "none" else code), order, false, function()
			if code ~= (current or "") then
				invoke(ctx, "equipFlag", code, if code == "" then "Couldn't remove your flag. Try again" else "Couldn't use this flag. Try again")
			end
		end)
		Kit.pad(b, 8, 8, 10, 8)
		Kit.list(b, false, 5, { HorizontalAlignment = CENTER, VerticalAlignment = MIDDLE })
		local pic = if code ~= "" then FlagKit.image(code, { Name = "Flag", Size = UDim2.fromOffset(math.floor(40 * FlagKit.ASPECT), 40), LayoutOrder = 1, Parent = b }) else nil
		if not pic then
			local holder = make("Frame", { Name = "Flag", BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.fromOffset(math.floor(40 * FlagKit.ASPECT), 40), LayoutOrder = 1, Parent = b })
			Kit.corner(holder, 6)
			Kit.icon(if code == "" then "Close" else "Flag", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), ImageColor3 = C.MUTED, Parent = holder })
		end
		Kit.text({ Name = "Name", Text = name, FontFace = F.BOLD, TextSize = 14, TextColor3 = if code == "" then C.MUTED else C.TEXT, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 2, Parent = b })
		local st = Kit.text({ Name = "Using", Text = "Using", FontFace = F.TITLE, TextSize = 13, TextColor3 = C.YELLOW, Visible = false, LayoutOrder = 3, Parent = b })
		tiles[code] = { stroke = b:FindFirstChildOfClass("UIStroke") :: UIStroke, state = st }
		style(code)
	end

	local function fill()
		for _, ch in g:GetChildren() do
			if not ch:IsA("UIGridLayout") then
				ch:Destroy()
			end
		end
		for _, ch in moreHolder:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		table.clear(tiles)
		local q = string.lower((string.gsub(state.query, "^%s+", "")))
		q = string.gsub(q, "%s+$", "")
		local matches = {}
		for _, e in allFlags() do
			if q == "" or string.find(e.search, q, 1, true) then
				table.insert(matches, e)
			end
		end
		if q == "" then
			tile("", "No flag", 0)
		end
		for i = 1, math.min(shown, #matches) do
			tile(matches[i].code, matches[i].name, i)
		end
		if #matches == 0 then
			wrapText(moreHolder, 1, "No flags match \"" .. state.query .. "\".", 15, C.MUTED, F.BOLD, Enum.TextXAlignment.Center)
		elseif #matches > shown then
			Kit.button("secondary", "Show more (" .. (#matches - shown) .. " left)", { name = "ShowMore", height = 40, textSize = 15, layoutOrder = 2, parent = moreHolder, onActivated = function()
				shown += FLAG_PAGE * 2
				fill()
			end })
		end
	end

	-- Redraw the grid shortly after typing stops.
	local typed = 0
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > 30 then
			box.Text = string.sub(box.Text, 1, 30)
			return
		end
		state.query = box.Text
		typed += 1
		local my = typed
		task.delay(0.2, function()
			if my == typed and g.Parent then
				shown = FLAG_PAGE
				fill()
			end
		end)
	end)
	fill()

	return function(np: any)
		local old = current or ""
		current = if type(np) == "table" and type(np.flag) == "string" and np.flag ~= "" then np.flag else nil
		style(old)
		style(current or "")
	end
end

-- Boosts tab -----------------------------------------------------------------------------------

local function drawBoosts(content: Instance, ctx: any, p: any, phone: boolean)
	wrapText(content, 1, "Use boosts in a battle from the boosts bar once the fighting starts.", 14, C.MUTED)
	local g = grid(content, 2, if phone then 2 else 4, 182, 12)
	local owned = if type(p.boosts) == "table" then p.boosts else {}
	for i, b in MetaConfig.BOOSTS do
		local look = BOOST_LOOK[b.key] or { name = b.name, icon = "Bolt", color = C.CYAN }
		local n = tonumber(owned[b.key]) or 0
		local none = n <= 0
		local card = Kit.card({ Name = "Boost_" .. b.key, LayoutOrder = i, Parent = g })
		Kit.pad(card, 14, 14, 14, 14)
		Kit.list(card, false, 6)
		-- The boost's own picture (as in the Shop); the line icon only shows until it loads.
		local sq = iconSquare(card, look.icon, look.color, 48, 1, none)
		local pic = Art.product(b.id, { Size = UDim2.fromScale(1, 1), ImageTransparency = if none then 0.45 else 0, Parent = sq }, function()
			sq.BackgroundTransparency = 1
			local line = sq:FindFirstChild("Icon")
			if line then
				line.Visible = false
			end
		end)
		Kit.corner(pic, 12)
		Kit.text({ Text = look.name, FontFace = F.BOLD, TextSize = 16, TextColor3 = if none then C.MUTED else C.TEXT, LayoutOrder = 2, Parent = card })
		Kit.text({ Name = "Count", Text = "x" .. n, FontFace = F.TITLE, TextSize = 34, TextColor3 = if none then C.MUTED else C.TEXT, TextTransparency = if none then 0.3 else 0, LayoutOrder = 3, Parent = card })
		if none then
			Kit.button("primary", "Get more", { name = "GetMore", height = 36, textSize = 15, layoutOrder = 4, parent = card, onActivated = function()
				ctx.open("store")
			end })
		else
			Kit.text({ Text = "Ready for your next battle", FontFace = F.BODY, TextSize = 13, TextColor3 = C.GREEN, LayoutOrder = 4, Parent = card })
		end
	end
end

return {
	title = "My items",
	render = function(page, ctx)
		local body = page.body
		local phone = ctx.layout() == "phone"
		local active = "colours"
		local alive = true
		local first = ctx.profile()
		local selected: string = (first and first.color) or MetaConfig.COLORS[1].id
		Kit.list(body, false, 14)

		local content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = body })
		Kit.list(content, false, 14)
		local flagState = { query = "" }
		local updateFlags: ((any) -> ())? = nil

		local draw: (boolean) -> ()
		draw = function(keepScroll: boolean)
			if not alive or not content.Parent then
				return
			end
			local y = body.CanvasPosition
			for _, ch in content:GetChildren() do
				if not ch:IsA("UIListLayout") then
					ch:Destroy()
				end
			end
			local p = ctx.profile()
			updateFlags = nil
			if not p then
				wrapText(content, 1, "Loading your items...", 15, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
			elseif active == "titles" then
				drawTitles(content, ctx, p, phone)
			elseif active == "flags" then
				updateFlags = drawFlags(content, ctx, p, phone, flagState)
			elseif active == "colours" then
				drawColours(content, ctx, p, phone, selected, function(id)
					if selected ~= id then
						selected = id
						draw(true)
					end
				end)
			else
				drawBoosts(content, ctx, p, phone)
			end
			body.CanvasPosition = if keepScroll then y else Vector2.zero
		end

		local tabs = Kit.tabs(TABS, active, function(key)
			active = key
			draw(false)
		end)
		tabs.LayoutOrder = 0
		tabs.Parent = body

		local queued = false
		local function onMarket()
			if queued then
				return
			end
			queued = true
			task.delay(0.15, function()
				queued = false
				if active == "colours" then
					draw(true)
				end
			end)
		end
		marketListeners[onMarket] = true
		ctx.onProfile(function(p)
			if not first and p and p.color then
				first = p
				selected = p.color
			end
			if active == "flags" and updateFlags and p then
				updateFlags(p)
				return
			end
			draw(true)
		end)
		draw(false)

		return function()
			alive = false
			marketListeners[onMarket] = nil
		end
	end,
}
