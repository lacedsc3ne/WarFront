--[[
	Frontlines (working title) - hover stats panel (top-centre player info, like OpenFront's).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.HoverPanel (ModuleScript), used by GameClient.
-- While the pointer (mouse, gamepad virtual cursor, or a recent touch) is over a player's
-- territory, a compact panel replaces the slim top banner:
--   [coin] gold   [ troops (icon) max troops ]   <- troop bar
--   Name  Nation [Ally]
--   [city] 3  [port] 1  [defense] 0  [silo] 0  [sam] 0  [warship] 2
-- HoverPanel.init(ctx)
--   ctx.gui, ctx.banner, ctx.roster, ctx.fmt(n), ctx.getMyId(), ctx.getStructures() -> list of
--   {id, kind, tile, owner, done}, ctx.getUnits() -> { [id]: { owner } }, ctx.contextMenu
--   (isAlly / isTraitor), ctx.deviceLayout (state.profile)
-- HoverPanel.update(ownerId, viaGamepad) -> boolean  (call every frame; true while shown)

local UserInputService = game:GetService("UserInputService")

local IconKit = require(script.Parent:WaitForChild("IconKit"))

local HoverPanel = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local NAVY = Color3.fromRGB(10, 22, 40)
local SLATE = Color3.fromRGB(51, 65, 85)
local GRAY600 = Color3.fromRGB(75, 85, 99)
local GRAY900 = Color3.fromRGB(17, 24, 39)
local MALIBU = Color3.fromRGB(0, 132, 209)
local YELLOW = Color3.fromRGB(250, 204, 21)

local TOUCH_HOLD = 2.5 -- seconds the panel stays up after the last touch
local REFRESH = 0.2 -- seconds between text refreshes for the same player

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

-- Structure / unit counters (PlayerInfoOverlay.displayUnitCount order: City, Factory, Port,
-- Missile Silo, SAM, Warship - no Defense Post), counting total levels: { Config kind, icon name }
local COUNTERS = {
	{ "City", "City" },
	{ "Port", "Port" },
	{ "MissileSilo", "Silo" },
	{ "SAM", "SAM" },
	{ "Warship", "Warship" },
}
if Config.STRUCTURES.Factory then
	table.insert(COUNTERS, 2, { "Factory", "Factory" })
end

local function make(className: string, props: { [string]: any })
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.TextSize = props.TextSize or 13
	return make("TextLabel", props)
end

local function hlist(parent, align: Enum.HorizontalAlignment, pad: number)
	return make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = align,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, pad),
		Parent = parent,
	})
end

local function escape(s: string): string
	return (string.gsub(s, "[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

local ctx: any = nil
local ui: any = nil
local shownId = 0
local lastRefresh = 0
local lastTouch = -math.huge
local hidBanner = false
local compactNow: boolean? = nil

local function build()
	local frame = make("Frame", {
		Name = "HoverPanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = NAVY,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Active = false,
		Visible = false,
		ZIndex = 15,
		Parent = ctx.gui,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 8), Parent = frame })
	make("UIStroke", { Color = SLATE, Transparency = 0.3, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = frame })
	local padding = make("UIPadding", { Parent = frame })
	local scale = make("UIScale", { Name = "HoverScale", Parent = frame })
	local list = make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 3), Parent = frame })

	-- Row 1: gold | troop bar
	local row1 = make("Frame", { BackgroundTransparency = 1, LayoutOrder = 1, ZIndex = 15, Parent = frame })
	local goldBox = make("Frame", { BackgroundTransparency = 1, ZIndex = 15, Parent = row1 })
	hlist(goldBox, Enum.HorizontalAlignment.Left, 4)
	local goldIcon = IconKit.image("Gold", { ImageColor3 = YELLOW, LayoutOrder = 1, ZIndex = 16, Parent = goldBox })
	local goldText = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextColor3 = YELLOW, Text = "0", LayoutOrder = 2, ZIndex = 16, Parent = goldBox })

	local bar = make("Frame", { BackgroundColor3 = GRAY900, BackgroundTransparency = 0.3, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 15, Parent = row1 })
	make("UICorner", { CornerRadius = UDim.new(0, 5), Parent = bar })
	make("UIStroke", { Color = GRAY600, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = bar })
	local fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = MALIBU, BorderSizePixel = 0, ZIndex = 15, Parent = bar })
	make("UICorner", { CornerRadius = UDim.new(0, 5), Parent = fill })
	local barRow = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 16, Parent = bar })
	hlist(barRow, Enum.HorizontalAlignment.Center, 4)
	local troopsText = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextStrokeTransparency = 0.5, Text = "0", LayoutOrder = 1, ZIndex = 16, Parent = barRow })
	local troopIcon = IconKit.image("Troops", { LayoutOrder = 2, ZIndex = 16, Parent = barRow })
	local maxText = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextStrokeTransparency = 0.5, Text = "0", LayoutOrder = 3, ZIndex = 16, Parent = barRow })

	-- Row 2: name + kind / tags
	local nameText = label({ FontFace = FONT, RichText = true, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", LayoutOrder = 2, ZIndex = 16, Parent = frame })

	-- Row 3: structure counters
	local row3 = make("Frame", { BackgroundTransparency = 1, LayoutOrder = 3, ZIndex = 15, Parent = frame })
	local row3List = hlist(row3, Enum.HorizontalAlignment.Center, 10)
	local counters = {}
	for i, c in COUNTERS do
		local cell = make("Frame", { Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, LayoutOrder = i, ZIndex = 15, Parent = row3 })
		hlist(cell, Enum.HorizontalAlignment.Left, 3)
		local icon = IconKit.image(c[2], { LayoutOrder = 1, ZIndex = 16, Parent = cell })
		local n = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, Text = "0", LayoutOrder = 2, ZIndex = 16, Parent = cell })
		counters[c[1]] = { icon = icon, text = n }
	end

	ui = {
		frame = frame,
		padding = padding,
		scale = scale,
		list = list,
		row1 = row1,
		goldBox = goldBox,
		goldIcon = goldIcon,
		goldText = goldText,
		bar = bar,
		fill = fill,
		troopsText = troopsText,
		troopIcon = troopIcon,
		maxText = maxText,
		nameText = nameText,
		row3 = row3,
		row3List = row3List,
		counters = counters,
	}
end

-- Sizes for the normal (desktop / tablet / console) or compact (phone) layout.
local function applyLayout(compact: boolean)
	if compactNow == compact then
		return
	end
	compactNow = compact
	local w = if compact then 236 else 300
	local rowH = if compact then 18 else 22
	local text = if compact then 11 else 13
	local icon = if compact then 12 else 14
	local goldW = if compact then 62 else 76
	local p = if compact then 5 else 7
	ui.frame.Size = UDim2.fromOffset(w, 0)
	ui.padding.PaddingLeft = UDim.new(0, p + 2)
	ui.padding.PaddingRight = UDim.new(0, p + 2)
	ui.padding.PaddingTop = UDim.new(0, p)
	ui.padding.PaddingBottom = UDim.new(0, p)
	ui.list.Padding = UDim.new(0, if compact then 2 else 4)
	ui.row1.Size = UDim2.new(1, 0, 0, rowH)
	ui.goldBox.Size = UDim2.new(0, goldW, 1, 0)
	ui.bar.Position = UDim2.fromOffset(goldW + 4, 0)
	ui.bar.Size = UDim2.new(1, -(goldW + 4), 1, 0)
	ui.goldIcon.Size = UDim2.fromOffset(icon, icon)
	ui.troopIcon.Size = UDim2.fromOffset(icon - 1, icon - 1)
	for _, t in { ui.goldText, ui.troopsText, ui.maxText } do
		t.TextSize = text
	end
	ui.nameText.Size = UDim2.new(1, 0, 0, if compact then 15 else 18)
	ui.nameText.TextSize = text + 1
	ui.row3.Size = UDim2.new(1, 0, 0, if compact then 14 else 16)
	ui.row3List.Padding = UDim.new(0, if compact then 7 else 11)
	for _, c in ui.counters do
		c.icon.Size = UDim2.fromOffset(icon - 1, icon - 1)
		c.text.TextSize = text
	end
end

local function kindName(p): string
	if p.kind == "Bot" then
		return "Tribe" -- en.json player_type.bot
	elseif p.kind == "Human" then
		return "Player"
	end
	return "Nation"
end

local function fill(id: number)
	local p = ctx.roster[id]
	if not p then
		return
	end
	local s = p.stats
	local fmt = ctx.fmt
	ui.goldText.Text = fmt(s.gold)
	local fmtT = ctx.fmtTroops or fmt -- renderTroops
	ui.troopsText.Text = fmtT(s.troops)
	ui.maxText.Text = fmtT(s.maxTroops)
	ui.fill.Size = UDim2.fromScale(math.clamp(s.troops / math.max(1, s.maxTroops), 0, 1), 1)

	local parts = { "<b>" .. escape(p.name) .. "</b>", '<font color="#9ca3af">' .. kindName(p) .. "</font>" }
	if id == ctx.getMyId() then
		parts[#parts + 1] = '<font color="#ffd700">(you)</font>'
	end
	local cm = ctx.contextMenu
	if cm and cm.isAlly(id) then
		parts[#parts + 1] = '<font color="#6ef0a0">[Ally]</font>'
	end
	if cm and cm.isTraitor(id) then
		parts[#parts + 1] = '<font color="#ff6e5a">[Traitor]</font>'
	end
	ui.nameText.Text = table.concat(parts, " ")

	local counts = {}
	for _, st in ctx.getStructures() do
		if st[4] == id then
			local lvl = if type(st[10]) == "number" and st[10] > 0 then st[10] else 1 -- totalUnitLevels
			counts[st[2]] = (counts[st[2]] or 0) + lvl
		end
	end
	for _, u in ctx.getUnits() do
		if u.owner == id then
			counts.Warship = (counts.Warship or 0) + 1
		end
	end
	for kind, c in ui.counters do
		local n = counts[kind] or 0
		c.text.Text = tostring(n)
		c.text.TextTransparency = if n > 0 then 0 else 0.45
		c.icon.ImageTransparency = if n > 0 then 0 else 0.45
	end
end

local function hide()
	if ui and ui.frame.Visible then
		ui.frame.Visible = false
	end
	shownId = 0
	if hidBanner then
		hidBanner = false
		ctx.banner.Visible = true
	end
end

function HoverPanel.init(c)
	ctx = c
	build()
	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			lastTouch = os.clock()
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			lastTouch = os.clock()
		end
	end)
end

function HoverPanel.update(ownerId: number, viaGamepad: boolean): boolean
	if not ui then
		return false
	end
	local p = if ownerId ~= 0 then ctx.roster[ownerId] else nil
	local pointerOk = viaGamepad
	if not pointerOk then
		local last = UserInputService:GetLastInputType()
		if last == Enum.UserInputType.Touch then
			pointerOk = os.clock() - lastTouch < TOUCH_HOLD
		else
			pointerOk = not UserInputService.TouchEnabled or UserInputService.MouseEnabled
		end
	end
	if not p or not p.stats.alive or not pointerOk then
		hide()
		return false
	end

	local dl = ctx.deviceLayout
	local profile = if dl and dl.state then dl.state.profile else "desktop"
	local gui = ctx.gui
	applyLayout(profile == "phone" or gui.AbsoluteSize.X < 560)

	-- Same scale as the banner (console UI scale), placed where the banner sits.
	local banner = ctx.banner
	local bs = banner:FindFirstChild("DeviceScale")
	local s = if bs and bs:IsA("UIScale") then bs.Scale else 1
	ui.scale.Scale = s
	local gp = gui.AbsolutePosition
	local bp, bz = banner.AbsolutePosition, banner.AbsoluteSize
	local half = ui.frame.AbsoluteSize.X / 2
	if half < 1 then
		half = (if compactNow then 236 else 300) * s / 2
	end
	local x = math.clamp(bp.X + bz.X / 2 - gp.X, half + 4, math.max(half + 4, gui.AbsoluteSize.X - half - 4))
	ui.frame.Position = UDim2.fromOffset(x, bp.Y - gp.Y)

	local now = os.clock()
	if ownerId ~= shownId or now - lastRefresh >= REFRESH then
		shownId = ownerId
		lastRefresh = now
		fill(ownerId)
	end
	ui.frame.Visible = true
	if banner.Visible then
		hidBanner = true
		banner.Visible = false
	end
	return true
end

return HoverPanel
