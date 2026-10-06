--[[
	War Front - hover stats panel (top-centre player info, OpenFront's PlayerInfoOverlay).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.HoverPanel (ModuleScript), used by GameClient.
--
-- While the pointer (mouse, gamepad virtual cursor, or a recent touch) is over a player's
-- territory, OpenFront's PlayerInfoOverlay replaces the slim top banner (bg-gray-800/92, 500 px):
--   left column (w-36):  [coin gold]  (soldier) ↑ attacking troops
--                        [ troops   (soldier)   max troops ]  troop bar (sky-700 + malibu)
--   right column:        flag  Name  Nation  [alliance icon + time] [traitor icon]
--                        [city n] [factory n] [port n] [silo n] [SAM n] [warship n]  unit chips
-- Scaled down on narrow screens (phones).
--
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
local MONO_BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
local MONO = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Regular)
local GRAY800 = Color3.fromRGB(31, 41, 55)
local GRAY600 = Color3.fromRGB(75, 85, 99)
local GRAY500 = Color3.fromRGB(107, 114, 128)
local GRAY400 = Color3.fromRGB(156, 163, 175)
local GRAY900 = Color3.fromRGB(17, 24, 39)
local SKY700 = Color3.fromRGB(3, 105, 161)
local MALIBU = Color3.fromRGB(0, 132, 209)
local AQUARIUS = Color3.fromRGB(63, 169, 245)
local YELLOW = Color3.fromRGB(250, 204, 21)
local GREEN500 = Color3.fromRGB(34, 197, 94)
local WIDTH = 500 -- sm:w-[500px]

local TOUCH_HOLD = 2.5 -- seconds the panel stays up after the last touch
local REFRESH = 0.2 -- seconds between text refreshes for the same player

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local SimClock = require(Shared:WaitForChild("SimClock"))
local FlagKit = require(script.Parent:WaitForChild("FlagKit"))

-- Structure / unit counters (PlayerInfoOverlay.displayUnitCount order: City, Factory, Port,
-- Missile Silo, SAM, Warship - no Defense Post), counting total levels: { Config kind, icon name }
local COUNTERS = {
	{ "City", "City" },
	{ "Factory", "Factory" },
	{ "Port", "Port" },
	{ "MissileSilo", "Silo" },
	{ "SAM", "SAM" },
	{ "Warship", "Warship" },
}

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

local function corner(o: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = o })
end

local function border(o: Instance, color: Color3)
	make("UIStroke", { Color = color, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = o })
end

-- drop-shadow-[0_1px_1px_rgba(0,0,0,0.8)] on light text
local function shadow(t: TextLabel)
	t.TextStrokeColor3 = Color3.new(0, 0, 0)
	t.TextStrokeTransparency = 0.55
end

-- OpenFront renderDuration (1:05 / 45s)
local function duration(sec: number): string
	sec = math.max(0, math.floor(sec))
	if sec >= 60 then
		return string.format("%d:%02d", sec // 60, sec % 60)
	end
	return sec .. "s"
end

local ctx: any = nil
local ui: any = nil
local shownId = 0
local lastRefresh = 0
local lastTouch = -math.huge
local hidBanner = false

local function build()
	local frame = make("Frame", {
		Name = "HoverPanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = false,
		Visible = false,
		ZIndex = 15,
		Parent = ctx.gui,
	})
	corner(frame, 8) -- rounded-b-lg
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = frame })
	local scale = make("UIScale", { Name = "HoverScale", Parent = frame })
	local content = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), ZIndex = 15, Parent = frame })

	-- Left: gold + attacking troops, troop bar (w-36 = 144 px)
	local left = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, 144, 1, 0), ZIndex = 15, Parent = content })
	local gold = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 15, Parent = left })
	corner(gold, 6)
	border(gold, YELLOW)
	make("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5), Parent = gold })
	hlist(gold, Enum.HorizontalAlignment.Center, 4)
	IconKit.image("Gold", { Size = UDim2.fromOffset(13, 13), LayoutOrder = 1, ZIndex = 16, Parent = gold })
	local goldText = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = YELLOW, Text = "0", LayoutOrder = 2, ZIndex = 16, Parent = gold })

	-- attacking troops (soldier + ↑ over the number), white/40 when 0, aquarius otherwise
	local atk = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0), Size = UDim2.fromOffset(0, 24), ZIndex = 15, Parent = left })
	local atkTop = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(24, 11), ZIndex = 15, Parent = atk })
	hlist(atkTop, Enum.HorizontalAlignment.Center, 1)
	local atkIcon = IconKit.image("Soldier", { Size = UDim2.fromOffset(10, 10), LayoutOrder = 1, ZIndex = 16, Parent = atkTop })
	local atkArrow = label({ Size = UDim2.fromOffset(8, 11), FontFace = FONT_BOLD, TextSize = 11, Text = "↑", LayoutOrder = 2, ZIndex = 16, Parent = atkTop })
	local atkText = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 11), Size = UDim2.new(1, 0, 0, 13), FontFace = FONT_BOLD, TextSize = 13, Text = "0", ZIndex = 16, Parent = atk })
	shadow(atkText)

	local bar = make("Frame", { Position = UDim2.new(0, 0, 1, -24), Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = GRAY900, BackgroundTransparency = 0.4, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 15, Parent = left })
	corner(bar, 6)
	border(bar, GRAY600)
	local troopFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = SKY700, BorderSizePixel = 0, ZIndex = 15, Parent = bar })
	local atkFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = MALIBU, BorderSizePixel = 0, ZIndex = 15, Parent = bar })
	local troopsText = label({ Position = UDim2.fromOffset(6, 0), Size = UDim2.new(0.5, -6, 1, 0), FontFace = FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Text = "0", ZIndex = 17, Parent = bar })
	local maxText = label({ Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0.5, -6, 1, 0), FontFace = FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, Text = "0", ZIndex = 17, Parent = bar })
	shadow(troopsText)
	shadow(maxText)
	IconKit.image("Soldier", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 14), ZIndex = 17, Parent = bar })

	-- Right: identity row + unit chips
	local right = make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(152, 0), Size = UDim2.new(1, -152, 1, 0), ZIndex = 15, Parent = content })
	local idRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), ZIndex = 15, Parent = right })
	hlist(idRow, Enum.HorizontalAlignment.Left, 8)
	local flag = make("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(36, 24), ScaleType = Enum.ScaleType.Fit, Visible = false, LayoutOrder = 1, ZIndex = 16, Parent = idRow })
	local nameText = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = MONO_BOLD, TextSize = 18, Text = "", LayoutOrder = 2, ZIndex = 16, Parent = idRow })
	make("UISizeConstraint", { MaxSize = Vector2.new(200, 24), Parent = nameText })
	nameText.TextTruncate = Enum.TextTruncate.AtEnd
	local typeText = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = MONO, TextSize = 12, TextColor3 = GRAY400, Text = "", LayoutOrder = 3, ZIndex = 16, Parent = idRow })
	local allyBox = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Visible = false, LayoutOrder = 5, ZIndex = 15, Parent = idRow })
	hlist(allyBox, Enum.HorizontalAlignment.Left, 4)
	IconKit.image("Alliance", { Size = UDim2.fromOffset(18, 18), LayoutOrder = 1, ZIndex = 16, Parent = allyBox })
	local allyText = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 12, Text = "", LayoutOrder = 2, ZIndex = 16, Parent = allyBox })
	local traitorBox = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Visible = false, LayoutOrder = 4, ZIndex = 15, Parent = idRow })
	hlist(traitorBox, Enum.HorizontalAlignment.Left, 3)
	IconKit.image("Traitor", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, ZIndex = 16, Parent = traitorBox })
	local traitorText = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 13, TextColor3 = Color3.fromRGB(127, 29, 29), Text = "", LayoutOrder = 2, ZIndex = 16, Parent = traitorBox })
	traitorText.TextStrokeColor3 = Color3.new(0, 0, 0)
	traitorText.TextStrokeTransparency = 0.6

	local chips = make("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -28), Size = UDim2.new(1, 0, 0, 28), ZIndex = 15, Parent = right })
	hlist(chips, Enum.HorizontalAlignment.Left, 4)
	local counters = {}
	for i, c in COUNTERS do
		-- displayUnitCount: border-gray-500 rounded-md w-12 h-7, icon w-4 + number text-xs
		local chip = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(48, 28), LayoutOrder = i, ZIndex = 15, Parent = chips })
		corner(chip, 6)
		border(chip, GRAY500)
		hlist(chip, Enum.HorizontalAlignment.Center, 4)
		IconKit.image(c[2], { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, ZIndex = 16, Parent = chip })
		local n = label({ Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT, TextSize = 12, Text = "0", LayoutOrder = 2, ZIndex = 16, Parent = chip })
		counters[c[1]] = { chip = chip, text = n }
	end

	ui = {
		frame = frame,
		scale = scale,
		goldText = goldText,
		gold = gold,
		atk = atk,
		atkIcon = atkIcon,
		atkArrow = atkArrow,
		atkText = atkText,
		troopFill = troopFill,
		atkFill = atkFill,
		troopsText = troopsText,
		maxText = maxText,
		flag = flag,
		nameText = nameText,
		typeText = typeText,
		allyBox = allyBox,
		allyText = allyText,
		traitorBox = traitorBox,
		traitorText = traitorText,
		counters = counters,
	}
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
	local fmtT = ctx.fmtTroops or fmt -- renderTroops
	ui.goldText.Text = fmt(s.gold) -- renderNumber
	-- The attacking-troops column fills the space right of the gold pill.
	local gw = ui.gold.AbsoluteSize.X / math.max(0.01, ui.scale.Scale)
	ui.atk.Position = UDim2.fromOffset(gw + 4, 0)
	ui.atk.Size = UDim2.new(1, -(gw + 4), 0, 24)
	local attacking = s.attacking or 0
	local hot = attacking > 0
	ui.atkText.Text = fmtT(attacking)
	ui.atkText.TextColor3 = if hot then AQUARIUS else Color3.new(1, 1, 1)
	ui.atkText.TextTransparency = if hot then 0 else 0.6
	ui.atkArrow.TextColor3 = ui.atkText.TextColor3
	ui.atkArrow.TextTransparency = ui.atkText.TextTransparency
	ui.atkIcon.ImageColor3 = if hot then AQUARIUS else Color3.new(1, 1, 1)
	ui.atkIcon.ImageTransparency = if hot then 0 else 0.6

	-- renderTroopBar: troops (sky-700) then attacking troops (malibu), both out of max troops.
	local base = math.max(1, s.maxTroops)
	local green = math.clamp(s.troops / base, 0, 1)
	local orange = math.clamp(attacking / base, 0, 1 - green)
	ui.troopFill.Size = UDim2.fromScale(green, 1)
	ui.atkFill.Position = UDim2.fromScale(green, 0)
	ui.atkFill.Size = UDim2.fromScale(orange, 1)
	ui.troopsText.Text = fmtT(s.troops)
	ui.maxText.Text = fmtT(s.maxTroops)

	-- Identity: flag, name (green when friendly), player type, traitor / alliance markers.
	ui.flag.Visible = FlagKit.set(ui.flag, p.flag)
	local myId = ctx.getMyId()
	local me = ctx.roster[myId]
	local cm = ctx.contextMenu
	local allied = cm ~= nil and cm.isAlly(id)
	local teammate = me ~= nil and id ~= myId and (p.team or "") ~= "" and p.team == me.team
	ui.nameText.Text = p.name .. (if id == myId then " (you)" else "")
	ui.nameText.TextColor3 = if allied or teammate then GREEN500 else Color3.new(1, 1, 1)
	ui.typeText.Text = kindName(p) .. (if (p.team or "") ~= "" and p.kind ~= "Bot" then " [" .. p.team .. "]" else "")
	local traitorEnds = cm and cm.traitorUntil and cm.traitorUntil(id)
	local traitorLeft = if traitorEnds then traitorEnds - SimClock.now() else 0
	ui.traitorBox.Visible = cm ~= nil and cm.isTraitor(id)
	ui.traitorText.Text = if traitorLeft > 0 then duration(traitorLeft) else ""
	local expiry = allied and cm.allyExpiry and cm.allyExpiry(id)
	ui.allyBox.Visible = allied
	ui.allyText.Text = if expiry then duration(expiry - SimClock.now()) else ""

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
		-- displayUnitCount hides units the round's rules disable (and Factory if it isn't in the game).
		c.chip.Visible = not MatchRules.unitDisabled(kind) and (Config.STRUCTURES[kind] ~= nil or Config.UNITS[kind] ~= nil)
		c.text.Text = tostring(counts[kind] or 0)
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

	local gui = ctx.gui

	-- Same scale as the banner (console UI scale), smaller when 500 px doesn't fit (phones).
	local banner = ctx.banner
	local bs = banner:FindFirstChild("DeviceScale")
	local s = if bs and bs:IsA("UIScale") then bs.Scale else 1
	s = math.min(s, (gui.AbsoluteSize.X - 8) / WIDTH)
	ui.scale.Scale = s
	local gp = gui.AbsolutePosition
	local bp, bz = banner.AbsolutePosition, banner.AbsoluteSize
	local half = ui.frame.AbsoluteSize.X / 2
	if half < 1 then
		half = WIDTH * s / 2
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
