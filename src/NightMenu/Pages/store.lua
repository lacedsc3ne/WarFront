-- War Front Night menu: Shop. Copyright (C) 2026 Liam (lacedsc3ne).
-- Purchase logic mirrors the old store in MenuPages (renderStore / renderStoreTab, storeInvoke,
-- cardAction, joinGroup, ownsColor, marketInfo, robuxText) and StoreView.featured: the same MetaFn ops
-- (buyBoost, buyColor, equipColor, clearColor, groupCheck), the same MarketplaceService prompts and
-- ownership checks, and the same "purchases are paused" guard. New: medal purchases ask first.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local Art = require(script.Parent.Parent:WaitForChild("Art"))
local MetaConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MetaConfig"))

local C, F = Kit.C, Kit.F
local make = Kit.make
local G = MetaConfig.GROUP
local TEAL = Color3.fromRGB(45, 212, 191)
local AUTO_Y = Enum.AutomaticSize.Y
local CENTER = Enum.HorizontalAlignment.Center
local MIDDLE = Enum.VerticalAlignment.Center
local NOT_ENOUGH = "Not enough medals. Get more in the Medals tab"

local TABS = {
	{ "foryou", "For you" },
	{ "boosts", "Boosts" },
	{ "perks", "Perks" },
	{ "colours", "Colours" },
	{ "medals", "Medals" },
}

-- Plain names and short effects for the shop cards (MetaConfig keeps the real items and prices).
local BOOST_LOOK = {
	goldCrate = { name = "Gold crate", short = "+" .. (MetaConfig.BOOST_GOLD // 1000) .. "K gold", effect = "Get " .. (MetaConfig.BOOST_GOLD // 1000) .. "K gold right away in a battle", icon = "Coins", color = C.YELLOW },
	reinforcements = { name = "Reinforcements", short = "+25% troops", effect = "25% more troops now, and room for 25% more for 60 s", icon = "Users", color = C.CYAN },
	shield = { name = "Shield", short = "30 s safe from attacks", effect = "30 s safe from land attacks. Nukes still hit, and attacking a player ends it", icon = "Shield", color = C.GREEN },
	nukeVoucher = { name = "Free nuke", short = "Next nuke is free", effect = "Your next atom bomb is free. You still need a missile silo", icon = "Rocket", color = C.PINK },
	revive = { name = "Extra revive", short = "Come back once more", effect = "Come back after you're defeated, on top of your free revive", icon = "Heart", color = C.PURPLE },
}

local PERK_LOOK = {
	startingArmy = { name = "Starting army", short = "25% more troops at the start of every battle", icon = "Users", color = C.CYAN },
	warEconomy = { name = "War economy", short = "15% more gold over time", icon = "Coins", color = C.YELLOW },
	rapidGrowth = { name = "Rapid growth", short = "Troops grow 10% faster", icon = "Grow", color = C.GREEN },
	secondChance = { name = "Second chance", short = "2 revives each battle instead of 1", icon = "Heart", color = C.PINK },
	safeLanding = { name = "Safe landing", short = "Your spawn shield lasts 10 s longer", icon = "Shield", color = C.PURPLE },
}

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

-- Robux price of a pass / developer product (MenuPages.marketInfo): fetched once, open shop pages
-- redraw when it arrives. nil until then (or if the lookup failed).
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

local function robuxText(info: any?): string
	local price = info and tonumber(info.PriceInRobux)
	return if price then "R$ " .. tostring(price) else "Buy"
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

local function heading(parent: Instance, order: number, text: string): TextLabel
	return Kit.text({ Text = text, FontFace = F.TITLE, TextSize = 20, LayoutOrder = order, Parent = parent })
end

local function iconSquare(parent: Instance, icon: string, color: Color3, size: number, order: number, solid: boolean?): Frame
	local sq = make("Frame", {
		Name = "IconSquare",
		BackgroundColor3 = color,
		BackgroundTransparency = if solid then 0 else 0.8,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.corner(sq, math.floor(size * 0.28))
	Kit.icon(icon, { Name = "Icon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.58, 0.58), ImageColor3 = if solid then C.YELLOW_TEXT else color, Parent = sq })
	return sq
end

-- The pass / product's own Roblox icon (the same picture as on the Store page), else the line icon.
local function storeIcon(parent: Instance, isPass: boolean, id: number, icon: string, color: Color3, size: number, order: number, solid: boolean?): GuiObject
	local info = if id ~= 0 then marketInfo(isPass, id) else nil
	local image = info and tonumber(info.IconImageAssetId)
	if image and image > 0 then
		local img = make("ImageLabel", {
			Name = "IconSquare",
			BackgroundColor3 = C.DEEP,
			BorderSizePixel = 0,
			Image = "rbxassetid://" .. image,
			ScaleType = Enum.ScaleType.Crop,
			Size = UDim2.fromOffset(size, size),
			LayoutOrder = order,
			Parent = parent,
		})
		Kit.corner(img, math.floor(size * 0.24))
		return img
	end
	return iconSquare(parent, icon, color, size, order, solid)
end

-- Horizontal row (fixed height, or as tall as its content).
local function hrow(parent: Instance, order: number, gap: number, height: number?): Frame
	local f = make("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or 0),
		AutomaticSize = if height then Enum.AutomaticSize.None else AUTO_Y,
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.list(f, true, gap, { VerticalAlignment = MIDDLE })
	return f
end

-- Column that takes the width left in an hrow.
local function column(parent: Instance, order: number, gap: number?): Frame
	local f = make("Frame", { Name = "Column", BackgroundTransparency = 1, Size = UDim2.new(), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	Kit.flex(f)
	Kit.list(f, false, gap or 2)
	return f
end

local function grid(parent: Instance, order: number, cols: number, cellH: number, gap: number): Frame
	local g = make("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	make("UIGridLayout", {
		CellPadding = UDim2.fromOffset(gap, gap),
		CellSize = UDim2.new(1 / cols, -math.ceil(gap * (cols - 1) / cols), 0, cellH),
		FillDirectionMaxCells = cols,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = g,
	})
	return g
end

local function ownedChip(parent: Instance, order: number): Frame
	return Kit.chip("Owned", { name = "Owned", icon = "Check", iconColor = C.GREEN, textColor = C.GREEN, strokeColor = C.GREEN_EDGE, height = 36, layoutOrder = order, parent = parent })
end

-- Actions (same server calls as MenuPages) -----------------------------------------------------

-- MenuPages.storeInvoke: MetaFn op, then show the server's message. The server pushes the new
-- profile itself, which redraws the page through ctx.onProfile.
local function invoke(ctx: any, op: string, arg: any?)
	task.spawn(function()
		local ok, msg = ctx.meta(op, arg)
		local text = if type(msg) == "string" then msg elseif ok then "" else "Something went wrong, try again"
		if not ok and text == "Not enough medals" then
			text = NOT_ENOUGH
		end
		if text ~= "" then
			ctx.toast(text, if ok then "ok" else "error")
		end
	end)
end

local function buyPass(id: number)
	MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, id)
end

local function buyProduct(ctx: any, id: number)
	local p = ctx.profile()
	if not (p and p.saving) then
		ctx.toast("Purchases are paused: your progress can't be saved right now", "error")
		return
	end
	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, id)
end

-- Roblox's favourite prompt; the client checks the favourite and tells the server (rewards follow).
local function favoriteGame(ctx: any)
	task.spawn(function()
		local FavoriteGame = require(script.Parent.Parent.Parent:WaitForChild("FavoriteGame"))
		if FavoriteGame.prompt() == true then
			invoke(ctx, "favorited")
		else
			ctx.toast("Not a favourite yet. Tap the star in Roblox's prompt", "info")
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

-- "Buy Gold crate?" popup for anything paid with medals.
local function confirmMedals(ctx: any, o: any)
	local p = ctx.profile()
	local coins = tonumber(p and p.coins) or 0
	local pop = ctx.popup({ width = 380, accent = C.YELLOW })
	local card = pop.card
	Kit.list(card, false, 12, { HorizontalAlignment = CENTER })
	if o.swatch then
		local sw = make("Frame", { Name = "Swatch", BackgroundColor3 = o.swatch, BorderSizePixel = 0, Size = UDim2.fromOffset(64, 64), LayoutOrder = 1, Parent = card })
		Kit.corner(sw)
		Kit.stroke(sw, C.LINE, 2)
	else
		iconSquare(card, o.icon, o.color, 64, 1)
	end
	Kit.text({ Text = o.title, FontFace = F.TITLE, TextSize = 22, LayoutOrder = 2, Parent = card })
	wrapText(card, 3, o.effect, 15, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
	local cost = make("Frame", { Name = "Cost", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 4, Parent = card })
	Kit.list(cost, true, 6, { VerticalAlignment = MIDDLE })
	Art.image("Medal", { Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = cost })
	Kit.text({ Text = numberText(o.price) .. " medals · you have " .. numberText(coins), FontFace = F.BOLD, TextSize = 15, TextColor3 = C.YELLOW, LayoutOrder = 2, Parent = cost })
	local buttons = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 5, Parent = card })
	Kit.list(buttons, true, 10)
	Kit.button("secondary", "Cancel", { height = 46, size = UDim2.new(0.5, -5, 0, 46), layoutOrder = 1, parent = buttons, onActivated = function()
		pop.close()
	end })
	Kit.button("primary", "Buy", { name = "Buy", height = 46, size = UDim2.new(0.5, -5, 0, 46), layoutOrder = 2, parent = buttons, onActivated = function()
		pop.close()
		o.onBuy()
	end })
	return pop
end

local function buyBoostWithMedals(ctx: any, b: any, look: any)
	local p = ctx.profile()
	if not p then
		return
	end
	if (tonumber(p.coins) or 0) < b.coins then
		ctx.toast(NOT_ENOUGH, "error")
		return
	end
	confirmMedals(ctx, {
		icon = look.icon,
		color = look.color,
		title = "Buy " .. look.name .. "?",
		effect = look.effect,
		price = b.coins,
		onBuy = function()
			invoke(ctx, "buyBoost", b.key)
		end,
	})
end

-- Old store colour card actions: Using -> back to random, owned -> equip, group -> join,
-- level-locked -> nothing to buy yet, otherwise buy with medals.
local function colourClick(ctx: any, c: any)
	local p = ctx.profile()
	if not p then
		return
	end
	local state = colourState(p, c)
	if state == "using" then
		invoke(ctx, "clearColor")
	elseif state == "owned" then
		invoke(ctx, "equipColor", c.id)
	elseif state == "group" then
		joinGroup(ctx)
	elseif state == "level" then
		ctx.toast("Reach level " .. c.level .. " to unlock " .. c.name, "info")
	elseif (tonumber(p.coins) or 0) < c.price then
		ctx.toast(NOT_ENOUGH, "error")
	else
		confirmMedals(ctx, {
			swatch = colourOf(c),
			title = "Buy " .. c.name .. "?",
			effect = "Your land colour in every battle, from your next one",
			price = c.price,
			onBuy = function()
				invoke(ctx, "buyColor", c.id)
			end,
		})
	end
end

-- Cards ----------------------------------------------------------------------------------------

local function vipCard(parent: Instance, order: number, p: any)
	local id = MetaConfig.GAMEPASS.VIP
	if id == 0 then
		return
	end
	local card = Kit.card({ Name = "VIP", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	local st = card:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = C.YELLOW
		st.Thickness = 2
	end
	Kit.pad(card, 18, 18, 16, 16)
	Kit.list(card, true, 14, { VerticalAlignment = MIDDLE })
	storeIcon(card, true, id, "Crown", C.YELLOW, 64, 1, true)
	local col = column(card, 2, 4)
	Kit.text({ Text = "VIP", FontFace = F.TITLE, TextSize = 26, TextColor3 = C.YELLOW, LayoutOrder = 1, Parent = col })
	wrapText(col, 2, string.format("%gx", MetaConfig.VIP_MULT) .. " XP and medals forever · gold name · VIP tag", 15, C.MUTED, F.BOLD)
	if p.vip then
		ownedChip(card, 3)
	else
		Kit.button("robux", robuxText(marketInfo(true, id)), { name = "BuyVIP", height = 44, layoutOrder = 3, parent = card, onActivated = function()
			buyPass(id)
		end })
	end
end

local function boostCard(parent: Instance, order: number, ctx: any, p: any, b: any, phone: boolean)
	local look = BOOST_LOOK[b.key] or { name = b.name, short = b.desc, effect = b.desc, icon = "Bolt", color = C.CYAN }
	local card = Kit.card({ Name = "Boost_" .. b.key, LayoutOrder = order, Parent = parent })
	Kit.pad(card, 14, 14, 14, 14)
	Kit.list(card, false, 8)
	storeIcon(card, false, b.id, look.icon, look.color, 48, 1)
	local nameRow = hrow(card, 2, 8)
	Kit.text({ Text = look.name, FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = nameRow })
	local n = tonumber(type(p.boosts) == "table" and p.boosts[b.key]) or 0
	if n > 0 then
		Kit.text({ Name = "Count", Text = "x" .. n, FontFace = F.TITLE, TextSize = 15, TextColor3 = C.GREEN, LayoutOrder = 2, Parent = nameRow })
	end
	Kit.text({ Text = look.short, FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Parent = card })
	local pills = make("Frame", { Name = "Prices", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, if phone then 84 else 38), LayoutOrder = 4, Parent = card })
	Kit.list(pills, not phone, 8)
	local size = if phone then UDim2.new(1, 0, 0, 38) else nil
	Kit.button("primary", numberText(b.coins), { name = "BuyWithMedals", icon = "Medal", height = 38, textSize = 16, padX = 14, size = size, layoutOrder = 1, parent = pills, onActivated = function()
		buyBoostWithMedals(ctx, b, look)
	end })
	if b.id ~= 0 then
		Kit.button("robux", robuxText(marketInfo(false, b.id)), { name = "BuyWithRobux", height = 38, textSize = 16, padX = 14, size = size, layoutOrder = 2, parent = pills, onActivated = function()
			buyProduct(ctx, b.id)
		end })
	end
end

local function boostGrid(parent: Instance, order: number, ctx: any, p: any, list: { any }, phone: boolean)
	local g = grid(parent, order, if phone then 2 else 4, if phone then 216 else 168, 12)
	local i = 0
	for _, b in list do
		if not b.hidden then
			i += 1
			boostCard(g, i, ctx, p, b, phone)
		end
	end
end

local function perkRows(parent: Instance, order: number, p: any)
	local card = Kit.card({ Name = "Perks", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	Kit.pad(card, 16, 16, 6, 6)
	Kit.list(card, false, 0)
	local owned = if type(p.perks) == "table" then p.perks else {}
	local i = 0
	for _, perk in MetaConfig.PERKS do
		if perk.id == 0 then
			continue
		end
		i += 1
		if i > 1 then
			make("Frame", { Name = "Divider", BackgroundColor3 = C.LINE, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), LayoutOrder = i * 2 - 1, Parent = card })
		end
		local look = PERK_LOOK[perk.key] or { name = perk.name, short = perk.desc, icon = "Star", color = C.CYAN }
		local row = make("Frame", { Name = "Perk_" .. perk.key, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = i * 2, Parent = card })
		Kit.pad(row, 0, 0, 10, 10)
		Kit.list(row, true, 12, { VerticalAlignment = MIDDLE })
		storeIcon(row, true, perk.id, look.icon, look.color, 48, 1)
		local col = column(row, 2, 2)
		Kit.text({ Text = look.name, FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = col })
		wrapText(col, 2, look.short, 14, C.MUTED)
		if owned[perk.key] == true then
			ownedChip(row, 3)
		else
			local id = perk.id
			Kit.button("robux", robuxText(marketInfo(true, id)), { name = "BuyPerk", height = 38, textSize = 16, layoutOrder = 3, parent = row, onActivated = function()
				buyPass(id)
			end })
		end
	end
end

local function colourTile(parent: Instance, order: number, p: any, c: any, onClick: () -> ())
	local state = colourState(p, c)
	local using = state == "using"
	local dim = state == "level"
	local b = make("TextButton", {
		Name = "Colour_" .. c.id,
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
	Kit.pad(b, 8, 8, 12, 10)
	Kit.list(b, false, 6, { HorizontalAlignment = CENTER })
	local circle = make("Frame", { Name = "Swatch", BackgroundColor3 = colourOf(c), BackgroundTransparency = if dim then 0.55 else 0, BorderSizePixel = 0, Size = UDim2.fromOffset(46, 46), LayoutOrder = 1, Parent = b })
	Kit.corner(circle)
	Kit.stroke(circle, C.LINE, 1.5)
	Kit.text({ Text = c.name, FontFace = F.BOLD, TextSize = 15, TextColor3 = if dim then C.MUTED else C.TEXT, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 2, Parent = b })
	local line = make("Frame", { Name = "State", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 3, Parent = b })
	Kit.list(line, true, 4, { VerticalAlignment = MIDDLE })
	local icon, text, color
	if state == "using" then
		text, color = "Using", C.YELLOW
	elseif state == "owned" then
		text, color = "Owned", C.GREEN
	elseif state == "group" then
		text, color = "Group only", TEAL
	elseif state == "level" then
		icon, text, color = "Lock", "Level " .. c.level, C.MUTED
	else
		icon, text, color = "Medal", numberText(c.price), C.YELLOW
	end
	if icon then
		Kit.icon(icon, { Size = UDim2.fromOffset(15, 15), ImageColor3 = color, LayoutOrder = 1, Parent = line })
	end
	Kit.text({ Text = text, FontFace = F.TITLE, TextSize = 14, TextColor3 = color, LayoutOrder = 2, Parent = line })
	Kit.hover(b, function(s)
		b.BackgroundColor3 = if s == "idle" then C.CARD else C.RAISED
	end)
	b.Activated:Connect(onClick)
	return b
end

local function allColoursCard(parent: Instance, order: number, p: any)
	local id = MetaConfig.GAMEPASS.AllColors
	if id == 0 then
		return
	end
	local card = Kit.card({ Name = "AllColours", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	Kit.pad(card, 16, 16, 14, 14)
	Kit.list(card, true, 12, { VerticalAlignment = MIDDLE })
	storeIcon(card, true, id, "Palette", C.PURPLE, 52, 1)
	local col = column(card, 2, 2)
	Kit.text({ Text = "Every colour", FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = col })
	wrapText(col, 2, "Unlock every land colour at once (not the group colour)", 14, C.MUTED)
	if p.allColors then
		ownedChip(card, 3)
	else
		Kit.button("robux", robuxText(marketInfo(true, id)), { name = "BuyAllColours", height = 40, textSize = 16, layoutOrder = 3, parent = card, onActivated = function()
			buyPass(id)
		end })
	end
end

local function medalPacks(parent: Instance, order: number, ctx: any, phone: boolean)
	local packs = {}
	for _, prod in MetaConfig.PRODUCTS do
		if prod.id ~= 0 then
			table.insert(packs, prod)
		end
	end
	if #packs == 0 then
		wrapText(parent, order, "Medal packs are coming soon.", 15, C.MUTED)
		return
	end
	local g = grid(parent, order, if phone then 1 else 3, if phone then 92 else 230, 12)
	for i, prod in packs do
		local card = Kit.card({ Name = "Pack_" .. prod.coins, LayoutOrder = i, Parent = g })
		local popular = prod.coins == 1500
		local function buy()
			buyProduct(ctx, prod.id)
		end
		local price = robuxText(marketInfo(false, prod.id))
		if phone then
			Kit.pad(card, 16, 16, 10, 10)
			Kit.list(card, true, 12, { VerticalAlignment = MIDDLE })
			Art.image(if i >= 3 then "GiftBig" else "Medal", { Size = UDim2.fromOffset(40 + i * 6, 40 + i * 6), LayoutOrder = 1, Parent = card })
			local col = column(card, 2, 0)
			Kit.text({ Text = numberText(prod.coins), FontFace = F.TITLE, TextSize = 24, LayoutOrder = 1, Parent = col })
			Kit.text({ Text = if popular then "medals · popular" else "medals", FontFace = F.BODY, TextSize = 14, TextColor3 = if popular then C.CYAN else C.MUTED, LayoutOrder = 2, Parent = col })
			Kit.button("robux", price, { name = "BuyPack", height = 40, textSize = 16, layoutOrder = 3, parent = card, onActivated = buy })
		else
			Kit.pad(card, 16, 16, 14, 16)
			Kit.list(card, false, 6, { HorizontalAlignment = CENTER, VerticalAlignment = Enum.VerticalAlignment.Bottom })
			if popular then
				Kit.text({ Text = "Popular", FontFace = F.TITLE, TextSize = 14, TextColor3 = C.CYAN, LayoutOrder = 0, Parent = card })
			end
			local s = 44 + i * 12
			Art.image(if i >= 3 then "GiftBig" else "Medal", { Size = UDim2.fromOffset(s, s), LayoutOrder = 1, Parent = card })
			Kit.text({ Text = numberText(prod.coins), FontFace = F.TITLE, TextSize = 28, LayoutOrder = 2, Parent = card })
			Kit.text({ Text = "medals", FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = card })
			Kit.button("robux", price, { name = "BuyPack", height = 42, textSize = 17, size = UDim2.new(1, 0, 0, 42), layoutOrder = 4, parent = card, onActivated = buy })
		end
	end
end

local function groupCard(parent: Instance, order: number, ctx: any, p: any, phone: boolean)
	local boost = MetaConfig.boost(G.DAILY_BOOST)
	local colour = MetaConfig.color(G.COLOR)
	local boostName = if boost and BOOST_LOOK[boost.key] then BOOST_LOOK[boost.key].name elseif boost then boost.name else "boost"
	local card = Kit.card({ Name = "Group", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	Kit.pad(card, 18, 18, 16, 16)
	Kit.list(card, false, 10)
	local head = hrow(card, 1, 12)
	Art.image("Gift", { Size = UDim2.fromOffset(52, 52), LayoutOrder = 1, Parent = head })
	local col = column(head, 2, 2)
	Kit.text({ Text = "Join " .. G.name .. " group", FontFace = F.TITLE, TextSize = 20, LayoutOrder = 1, Parent = col })
	wrapText(col, 2, "Free rewards: join the group and favourite the game", 14, C.MUTED)
	local rows = {
		{ text = numberText(G.MEDALS) .. " medals, once when you join", done = p.groupMedals == true, doneText = "Claimed", waitText = "On its way" },
		{ text = (if colour then colour.name else "Group") .. " colour, only for the group", done = p.inGroup == true, doneText = "Unlocked", waitText = "On its way" },
		{ text = "A free " .. string.lower(boostName) .. " every day you play", done = p.groupBoostToday == true, doneText = "Got today's", waitText = "Tomorrow" },
	}
	for i, r in rows do
		local row = hrow(card, 1 + i, 10)
		Kit.icon("CheckCircle", { Size = UDim2.fromOffset(18, 18), ImageColor3 = if r.done then C.GREEN else C.LINE, LayoutOrder = 1, Parent = row })
		local c = column(row, 2, 0)
		wrapText(c, 1, r.text, 15, C.TEXT, F.BOLD)
		Kit.text({
			Text = if r.done then r.doneText elseif p.inGroup and p.favorited then r.waitText elseif p.inGroup then "Favourite to unlock" else "Join to unlock",
			FontFace = F.TITLE,
			TextSize = 14,
			TextColor3 = if r.done then C.GREEN else C.MUTED,
			LayoutOrder = 3,
			Parent = row,
		})
	end
	if p.inGroup and p.favorited then
		wrapText(card, 10, "You're in " .. G.name .. " group and the game is a favourite. Rewards are given automatically when you join the game.", 14, C.GREEN)
	else
		local count = (if p.inGroup then 0 else 1) + (if p.favorited then 0 else 1) + 1
		local buttons = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, if phone then count * 52 - 8 else 44), LayoutOrder = 10, Parent = card })
		Kit.list(buttons, not phone, 8)
		local size = if phone then UDim2.new(1, 0, 0, 44) else nil
		if not p.inGroup then
			Kit.button("primary", "Join the group", { name = "JoinGroup", icon = "UserPlus", height = 44, textSize = 17, size = size, layoutOrder = 1, parent = buttons, onActivated = function()
				joinGroup(ctx)
			end })
		end
		if not p.favorited then
			Kit.button(if p.inGroup then "primary" else "secondary", "Favourite the game", { name = "FavoriteGame", icon = "Star", height = 44, textSize = 17, size = size, layoutOrder = 2, parent = buttons, onActivated = function()
				favoriteGame(ctx)
			end })
		end
		Kit.button("secondary", "Check again", { name = "CheckGroup", height = 44, textSize = 16, size = size, layoutOrder = 3, parent = buttons, onActivated = function()
			invoke(ctx, "groupCheck")
		end })
	end
end

-- Tabs -----------------------------------------------------------------------------------------

local function drawTab(content: Instance, tab: string, ctx: any, p: any, phone: boolean)
	if tab == "foryou" then
		vipCard(content, 1, p)
		heading(content, 2, "Boosts")
		boostGrid(content, 3, ctx, p, MetaConfig.BOOSTS, phone)
		groupCard(content, 4, ctx, p, phone)
	elseif tab == "boosts" then
		wrapText(content, 1, "Use boosts in a battle from the boosts bar once the fighting starts, as many as you own, one after another. Bought during a battle, they're used right away. Extra revives are used from the defeat screen.", 14, C.MUTED)
		boostGrid(content, 2, ctx, p, MetaConfig.SHOP_ITEMS, phone)
	elseif tab == "perks" then
		wrapText(content, 1, "Perks are yours forever and work in every battle: alone, private or public.", 14, C.MUTED)
		perkRows(content, 2, p)
	elseif tab == "colours" then
		allColoursCard(content, 1, p)
		wrapText(content, 2, "Your land colour in every battle, from your next one. Pick a colour you own to use it, or pick the one you're using to go back to a random colour.", 14, C.MUTED)
		local g = grid(content, 3, if phone then 3 else 5, 124, 12)
		for i, c in MetaConfig.COLORS do
			colourTile(g, i, p, c, function()
				colourClick(ctx, c)
			end)
		end
		wrapText(content, 4, "Colours only change how your land looks. Medals buy colours and boosts.", 13, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
	else
		wrapText(content, 1, "Medals buy colours and boosts.", 14, C.MUTED)
		medalPacks(content, 2, ctx, phone)
	end
end

return {
	title = "Shop",
	headerRight = function()
		local chip = Kit.chip("…", { name = "ShopMedals", icon = "Medal", iconColor = C.YELLOW, textColor = C.YELLOW, height = 34, textSize = 16 })
		chip.Icon:Destroy()
		Art.image("Medal", { Name = "Icon", Size = UDim2.fromOffset(26, 26), LayoutOrder = 1, Parent = chip })
		return chip
	end,
	render = function(page, ctx)
		local body = page.body
		local phone = ctx.layout() == "phone"
		local active = "foryou"
		local alive = true
		Kit.list(body, false, 14)

		local tabScroll = make("ScrollingFrame", {
			Name = "TabStrip",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 34),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 0,
			Selectable = false,
			LayoutOrder = 0,
			Parent = body,
		})
		local content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = body })
		Kit.list(content, false, 14)

		local function paintCoins()
			local chip = page.header:FindFirstChild("ShopMedals")
			local label = chip and chip:FindFirstChild("Label")
			local p = ctx.profile()
			if label then
				label.Text = if p then numberText(p.coins) else "…"
			end
		end

		local function draw(keepScroll: boolean)
			if not alive or not content.Parent then
				return
			end
			local y = body.CanvasPosition
			for _, ch in content:GetChildren() do
				if not ch:IsA("UIListLayout") then
					ch:Destroy()
				end
			end
			paintCoins()
			local p = ctx.profile()
			if not p then
				wrapText(content, 1, "Loading your profile...", 15, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
			else
				drawTab(content, active, ctx, p, phone)
			end
			if keepScroll then
				body.CanvasPosition = y
			else
				body.CanvasPosition = Vector2.zero
			end
		end

		local tabs = Kit.tabs(TABS, active, function(key)
			active = key
			draw(false)
		end)
		tabs.Parent = tabScroll

		-- Robux prices arrive one by one: redraw once shortly after (MenuPages.refreshStores).
		local queued = false
		local function onMarket()
			if queued then
				return
			end
			queued = true
			task.delay(0.15, function()
				queued = false
				draw(true)
			end)
		end
		marketListeners[onMarket] = true
		ctx.onProfile(function()
			draw(true)
		end)
		draw(false)

		return function()
			alive = false
			marketListeners[onMarket] = nil
		end
	end,
}
