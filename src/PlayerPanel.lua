--[[
	War Front - player info panel, send troops / gold dialog and emoji table.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.PlayerPanel (ModuleScript), used by RadialMenu / GameClient
-- (via Interact). Mirrors OpenFront's PlayerPanel.ts, SendResourceModal.ts and EmojiTable.ts:
--   panel   flag, name, Nation / Tribe chip, traitor badge, gold and troops, betrayals, trading,
--           the player's alliances (time left each), our alliance's time left, and actions:
--           Emojis, send Troops, send Gold, Break Alliance / Send Alliance.
--   send    "Send Troops / Gold to <name>": available, 10/25/50/75/Max presets, slider, send / keep.
--   emojis  5-column table of Shared.Emojis; picking one sends it (to everyone if it's us).
-- PlayerPanel.setup(ctx)
--   ctx.gui, ctx.net, ctx.roster, ctx.getMyId(), ctx.fmt(n), ctx.contextMenu (diplomacy state),
--   ctx.getPhase()
-- PlayerPanel.show(playerId), PlayerPanel.hide(), PlayerPanel.isOpen()
-- PlayerPanel.openSendModal(playerId, "troops" | "gold"), PlayerPanel.showEmojiTable(playerId)

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Emojis = require(Shared:WaitForChild("Emojis"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local FlagKit = require(script.Parent:WaitForChild("FlagKit"))

local PlayerPanel = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local ZINC900 = Color3.fromRGB(24, 24, 27)
local ZINC800 = Color3.fromRGB(39, 39, 42)
local ZINC700 = Color3.fromRGB(63, 63, 70)
local ZINC600 = Color3.fromRGB(82, 82, 91)
local ZINC400 = Color3.fromRGB(161, 161, 170)
local ZINC300 = Color3.fromRGB(212, 212, 216)
local ZINC200 = Color3.fromRGB(228, 228, 231)
local ZINC100 = Color3.fromRGB(244, 244, 245)
local RED400 = Color3.fromRGB(248, 113, 113)
local RED500 = Color3.fromRGB(239, 68, 68)
local YELLOW400 = Color3.fromRGB(250, 204, 21)
local EMERALD400 = Color3.fromRGB(52, 211, 153)
local INDIGO400 = Color3.fromRGB(129, 140, 248)
local INDIGO600 = Color3.fromRGB(79, 70, 229)
local BLUE400 = Color3.fromRGB(96, 165, 250)
local AMBER400 = Color3.fromRGB(251, 191, 36)
local GOLD = Color3.fromHex("#f59e0b")
local PURPLE = Color3.fromRGB(168, 85, 247)
local AMBER_FILL = Color3.fromRGB(234, 179, 8)

-- getRelationClass / relation.*: text, text colour, bg (x/10), border (x/30-40)
local RELATION_LOOK = {
	[0] = { "Hostile", Color3.fromRGB(254, 202, 202), RED500, RED400 },
	[1] = { "Distrustful", Color3.fromRGB(252, 165, 165), Color3.fromRGB(252, 165, 165), Color3.fromRGB(252, 165, 165) },
	[2] = { "Neutral", ZINC200, Color3.fromRGB(113, 113, 122), ZINC400 },
	[3] = { "Friendly", Color3.fromRGB(167, 243, 208), Color3.fromRGB(16, 185, 129), EMERALD400 },
}
local BUTTON_COLORS = { normal = Color3.fromRGB(240, 240, 240), red = RED400, green = EMERALD400, indigo = INDIGO400, yellow = GOLD }
local PRESETS = { 10, 25, 50, 75, 100 }
local PANEL_W = 360

local ctx: any = nil
local gui: ScreenGui

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

local function corner(parent: Instance, r: number?)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextSize = props.TextSize or 14
	return make("TextLabel", props)
end

local function usingGamepad(): boolean
	return string.find(UserInputService:GetLastInputType().Name, "Gamepad") ~= nil
end

local function serverNow(): number
	return SimClock.now()
end

-- OpenFront renderDuration: 1:05 style for minutes, "45s" below a minute.
local function duration(s: number): string
	s = math.max(0, math.floor(s))
	if s >= 60 then
		return string.format("%d:%02d", s // 60, s % 60)
	end
	return s .. "s"
end

local function expiryColor(s: number?): Color3
	if not s then
		return WHITE
	elseif s <= 30 then
		return RED400
	elseif s <= 60 then
		return YELLOW400
	end
	return EMERALD400
end

local function hlist(parent: Instance, pad: number, align: Enum.HorizontalAlignment?)
	return make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, pad),
		Parent = parent,
	})
end

local function closeButton(parent: Instance, onClick: () -> (), zindex: number)
	local b = make("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = ZINC700,
		AutoButtonColor = false,
		FontFace = FONT_BOLD,
		TextSize = 14,
		TextColor3 = WHITE,
		Text = "X",
		ZIndex = zindex,
		Parent = parent,
	})
	corner(b, 14)
	b.MouseEnter:Connect(function()
		b.BackgroundColor3 = RED500
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = ZINC700
	end)
	b.SelectionGained:Connect(function()
		b.BackgroundColor3 = RED500
	end)
	b.SelectionLost:Connect(function()
		b.BackgroundColor3 = ZINC700
	end)
	b.Activated:Connect(onClick)
	return b
end

-- A full-screen dimmer (OpenFront bg-black/15) that closes the dialog on its own when clicked.
local function dimmer(name: string, zindex: number, onClick: () -> ())
	local d = make("TextButton", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.85,
		AutoButtonColor = false,
		Selectable = false,
		Text = "",
		Visible = false,
		ZIndex = zindex,
		Parent = gui,
	})
	d.Activated:Connect(onClick)
	d.MouseButton2Click:Connect(onClick)
	return d
end

local function card(name: string, width: number, zindex: number, radius: number?)
	local c = make("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = ZINC900,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = zindex,
		Parent = gui,
	})
	corner(c, radius or 16)
	local stroke = make("UIStroke", { Color = WHITE, Transparency = 0.95, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = c })
	make("UISizeConstraint", { MaxSize = Vector2.new(width, math.huge), Parent = c })
	return c, stroke
end

local function selectFirst(root: Instance)
	if not usingGamepad() then
		return
	end
	task.defer(function()
		for _, d in root:GetDescendants() do
			if d:IsA("GuiButton") and d.Selectable and d.Visible and d.Name ~= "Close" then
				GuiService.SelectedObject = d
				return
			end
		end
	end)
end

local function dropSelection(root: Instance)
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(root) then
		GuiService.SelectedObject = nil
	end
end

-- Emoji table (EmojiTable.ts)
local emojiDim: TextButton
local emojiCard: Frame
local emojiTarget = 0

local function hideEmojiTable()
	if emojiCard and emojiCard.Visible then
		dropSelection(emojiCard)
		emojiCard.Visible = false
		emojiDim.Visible = false
	end
end

function PlayerPanel.showEmojiTable(playerId: number)
	if not ctx then
		return
	end
	emojiTarget = playerId
	emojiDim.Visible = true
	emojiCard.Visible = true
	selectFirst(emojiCard)
end

local function buildEmojiTable()
	emojiDim = dimmer("EmojiTableDim", 80, hideEmojiTable)
	local c = card("EmojiTable", 400, 81, 10)
	emojiCard = c
	c.AutomaticSize = Enum.AutomaticSize.None
	c.Size = UDim2.new(1, -32, 0, 0)
	closeButton(c, hideEmojiTable, 90).Position = UDim2.new(1, 12, 0, -12)
	local scroll = make("ScrollingFrame", {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 1, -20),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 82,
		Parent = c,
	})
	local grid = make("UIGridLayout", { CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
	for i, e in Emojis.LIST do
		local b = make("TextButton", {
			Name = "Emoji" .. i,
			BackgroundColor3 = ZINC800,
			AutoButtonColor = true,
			FontFace = FONT,
			TextSize = 32,
			TextColor3 = WHITE,
			Text = e,
			LayoutOrder = i,
			ZIndex = 83,
			Parent = scroll,
		})
		corner(b, 8)
		make("UIStroke", { Color = ZINC600, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		b.Activated:Connect(function()
			ctx.net:FireServer("emoji", emojiTarget, i)
			hideEmojiTable()
		end)
	end
	-- Square cells, 5 per row, sized to the card; the card is as tall as the screen allows.
	local function layout()
		local w = math.min(400, gui.AbsoluteSize.X - 32)
		local cell = math.floor((w - 20 - 4 - 8 * (Emojis.COLUMNS - 1)) / Emojis.COLUMNS)
		grid.CellSize = UDim2.fromOffset(cell, cell)
		local rows = math.ceil(Emojis.COUNT / Emojis.COLUMNS)
		local h = rows * cell + (rows - 1) * 8 + 20
		c.Size = UDim2.fromOffset(w, math.min(h, gui.AbsoluteSize.Y - 60))
	end
	layout()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
end

-- Send troops / gold (SendResourceModal.ts)
local send = { open = false, target = 0, mode = "troops", amount = 0, percent = nil :: number? }
local sendDim: TextButton
local sendCard: Frame
local sendUI: any = {}
local hidePanel: () -> ()

local function closeSend()
	if not send.open then
		return
	end
	send.open = false
	dropSelection(sendCard)
	sendCard.Visible = false
	sendDim.Visible = false
end

local function sendTotal(): number
	local mine = ctx.roster[ctx.getMyId()]
	if not mine or not mine.stats.alive then
		return 0
	end
	return math.floor(if send.mode == "troops" then mine.stats.troops else mine.stats.gold)
end

-- Troops are capped by what the receiver can still hold; gold is not.
local function sendCap(): number?
	local t = ctx.roster[send.target]
	if not t or not t.stats.alive then
		return 0
	end
	if send.mode ~= "troops" then
		return nil
	end
	return math.max(0, math.floor(t.stats.maxTroops - t.stats.troops))
end

local function clampSend(n: number): number
	local total = sendTotal()
	local cap = sendCap()
	local hardMax = if cap then math.min(total, cap) else total
	return math.clamp(math.floor(n), 0, math.max(0, hardMax))
end

local function refreshSend()
	if not send.open then
		return
	end
	local total = sendTotal()
	local fmtAmount = if send.mode == "troops" then (ctx.fmtTroops or ctx.fmt) else ctx.fmt -- renderTroops for troops
	if send.percent then
		send.amount = clampSend(total * send.percent / 100)
	else
		send.amount = clampSend(send.amount)
	end
	local target = ctx.roster[send.target]
	local name = if target then target.name else "?"
	local dead = total <= 0 or not target or not target.stats.alive
	sendUI.title.Text = (if send.mode == "troops" then "Send Troops to " else "Send Gold to ") .. name
	sendUI.available.Text = "Available  " .. fmtAmount(total)
	local pct = if total > 0 then math.floor(send.amount / total * 100 + 0.5) else 0
	for i, b in sendUI.presets do
		local active = (send.percent or pct) == PRESETS[i]
		b.BackgroundColor3 = if dead then ZINC800 elseif active then INDIGO600 else ZINC800
		b.TextColor3 = if dead then ZINC400 elseif active then WHITE else ZINC200
	end
	local frac = if total > 0 then send.amount / total else 0
	sendUI.fill.Size = UDim2.fromScale(frac, 1)
	sendUI.fill.BackgroundColor3 = if send.mode == "troops" then PURPLE else AMBER_FILL
	sendUI.knob.Position = UDim2.fromScale(frac, 0.5)
	sendUI.bubble.Position = UDim2.new(frac, 0, 0, -6)
	sendUI.bubble.Text = string.format("%d%% • %s", pct, fmtAmount(send.amount))
	local cap = sendCap()
	sendUI.capMark.Visible = cap ~= nil and total > 0
	if cap and total > 0 then
		sendUI.capMark.Position = UDim2.fromScale(math.clamp(math.min(cap, total) / total, 0, 1), 0.5)
	end
	local keep = math.max(0, total - send.amount)
	local lowKeep = send.mode == "troops" and keep < math.floor(total * 0.3)
	sendUI.summary.Text = string.format(
		'Send <font color="#818cf8"><b>%s</b></font> · Keep <font color="%s"><b>%s</b></font>',
		fmtAmount(send.amount),
		if lowKeep then "#fbbf24" else "#34d399",
		fmtAmount(keep)
	)
	sendUI.capNote.Visible = cap ~= nil and send.percent ~= nil and clampSend(total * send.percent / 100) < math.floor(total * send.percent / 100)
	sendUI.capNote.Text = "Receiver can accept only " .. fmtAmount(cap or 0) .. " right now."
	local canSend = not dead and send.amount > 0
	sendUI.sendButton.BackgroundTransparency = if canSend then 0 else 0.5
	sendUI.sendButton.AutoButtonColor = canSend
end

local function confirmSend()
	local total = sendTotal()
	if total <= 0 or send.amount <= 0 then
		return
	end
	-- The server takes a share of our current amount (it re-checks the receiver's room).
	ctx.net:FireServer(if send.mode == "troops" then "donateTroops" else "donateGold", send.target, math.clamp(send.amount / total, 0.01, 1))
	closeSend()
	hidePanel()
end

local function buildSendModal()
	sendDim = dimmer("SendResourceDim", 78, closeSend)
	local c = card("SendResource", 380, 79)
	sendCard = c
	closeButton(c, closeSend, 90)
	local body = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, ZIndex = 80, Parent = c })
	make("UIPadding", { PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20), PaddingTop = UDim.new(0, 18), PaddingBottom = UDim.new(0, 18), Parent = body })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = body })
	sendUI.title = label({ Size = UDim2.new(1, -30, 0, 24), FontFace = FONT_BOLD, TextSize = 18, TextColor3 = ZINC100, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 1, ZIndex = 81, Parent = body })
	local availRow = make("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 81, Parent = body })
	sendUI.available = label({ Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 0.85, BackgroundColor3 = INDIGO600, TextSize = 13, TextColor3 = Color3.fromRGB(224, 231, 255), ZIndex = 82, Parent = availRow })
	sendUI.available.BackgroundTransparency = 0.85
	corner(sendUI.available, 11)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = sendUI.available })
	make("UIStroke", { Color = INDIGO400, Transparency = 0.6, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = sendUI.available })

	local presetRow = make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, LayoutOrder = 3, ZIndex = 81, Parent = body })
	hlist(presetRow, 8)
	sendUI.presets = {}
	for i, p in PRESETS do
		local b = make("TextButton", {
			Size = UDim2.new(0.2, -7, 1, 0),
			BackgroundColor3 = ZINC800,
			AutoButtonColor = true,
			FontFace = FONT,
			TextSize = 14,
			TextColor3 = ZINC200,
			Text = if p == 100 then "Max" else (p .. "%"),
			LayoutOrder = i,
			ZIndex = 82,
			Parent = presetRow,
		})
		corner(b, 8)
		make("UIStroke", { Color = ZINC700, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		b.Activated:Connect(function()
			send.percent = p
			refreshSend()
		end)
		sendUI.presets[i] = b
	end

	-- Slider: track, fill, knob, "pct • amount" bubble, cap marker.
	local sliderBox = make("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, LayoutOrder = 4, ZIndex = 81, Parent = body })
	local track = make("TextButton", {
		Name = "Slider",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 8),
		Size = UDim2.new(1, -8, 0, 8),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.72,
		AutoButtonColor = false,
		Text = "",
		Selectable = false,
		ZIndex = 82,
		Parent = sliderBox,
	})
	corner(track, 4)
	sendUI.fill = make("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0, ZIndex = 83, Parent = track })
	corner(sendUI.fill, 4)
	sendUI.knob = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = WHITE, ZIndex = 85, Parent = track })
	corner(sendUI.knob, 8)
	make("UIStroke", { Color = ZINC900, Thickness = 2, Parent = sendUI.knob })
	sendUI.capMark = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2, 12), BackgroundColor3 = AMBER400, BorderSizePixel = 0, ZIndex = 84, Visible = false, Parent = track })
	sendUI.bubble = label({
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = 12,
		TextColor3 = ZINC100,
		ZIndex = 86,
		Parent = track,
	})
	sendUI.bubble.BackgroundTransparency = 0
	sendUI.bubble.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
	corner(sendUI.bubble, 4)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = sendUI.bubble })
	local dragging = false
	local function setFromX(x: number)
		local total = sendTotal()
		local f = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		send.percent = nil
		send.amount = clampSend(total * f)
		refreshSend()
	end
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	sendUI.capNote = label({ Size = UDim2.new(1, 0, 0, 16), TextSize = 12, TextColor3 = Color3.fromRGB(252, 211, 77), TextXAlignment = Enum.TextXAlignment.Left, Visible = false, LayoutOrder = 5, ZIndex = 81, Parent = body })
	sendUI.summary = label({ Size = UDim2.new(1, 0, 0, 18), TextSize = 14, TextColor3 = ZINC200, RichText = true, LayoutOrder = 6, ZIndex = 81, Parent = body })

	local actions = make("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 7, ZIndex = 81, Parent = body })
	hlist(actions, 8, Enum.HorizontalAlignment.Right)
	local cancel = make("TextButton", { Size = UDim2.fromOffset(96, 40), BackgroundColor3 = ZINC800, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = ZINC100, Text = "Cancel", LayoutOrder = 1, ZIndex = 82, Parent = actions })
	corner(cancel, 8)
	make("UIStroke", { Color = ZINC700, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = cancel })
	cancel.Activated:Connect(closeSend)
	sendUI.sendButton = make("TextButton", { Size = UDim2.fromOffset(96, 40), BackgroundColor3 = INDIGO600, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = WHITE, Text = "Send", LayoutOrder = 2, ZIndex = 82, Parent = actions })
	corner(sendUI.sendButton, 8)
	sendUI.sendButton.Activated:Connect(confirmSend)
end

function PlayerPanel.openSendModal(playerId: number, mode: string)
	if not ctx or not ctx.roster[playerId] then
		return
	end
	PlayerPanel.show(playerId)
	send.open, send.target, send.mode, send.percent, send.amount = true, playerId, mode, nil, 0
	-- Start at the attack ratio's share, like OpenFront's default amount.
	local ratio = if ctx.getRatio then ctx.getRatio() else 0.2
	send.amount = clampSend(sendTotal() * ratio)
	sendDim.Visible = true
	sendCard.Visible = true
	refreshSend()
	if usingGamepad() then
		task.defer(function()
			GuiService.SelectedObject = sendUI.presets[2]
		end)
	end
end

-- Player panel (PlayerPanel.ts)
local panel = { open = false, id = 0, actionsKey = "", alliesKey = "", lastTarget = -math.huge, lastEmbargoAll = -math.huge }
local panelDim: TextButton
local panelCard: Frame
local panelStroke: UIStroke
local ui: any = {}

function hidePanel()
	if not panel.open then
		return
	end
	panel.open = false
	closeSend()
	hideEmojiTable()
	dropSelection(panelCard)
	panelCard.Visible = false
	panelDim.Visible = false
end
PlayerPanel.hide = hidePanel

function PlayerPanel.isOpen(): boolean
	return panel.open
end

local function divider(order: number, parent: Instance)
	make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, LayoutOrder = order, ZIndex = 72, Parent = parent })
end

local function pill(parent: Instance, order: number, emoji: string)
	local f = make("Frame", { Size = UDim2.new(0.5, -4, 0, 34), BackgroundColor3 = WHITE, BackgroundTransparency = 0.96, LayoutOrder = order, ZIndex = 72, Parent = parent })
	corner(f, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 8), Parent = f })
	hlist(f, 6)
	label({ Size = UDim2.fromOffset(18, 20), TextSize = 15, Text = emoji, LayoutOrder = 1, ZIndex = 73, Parent = f })
	local value = label({ Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, Text = "", LayoutOrder = 2, ZIndex = 73, Parent = f })
	local unit = label({ Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, TextSize = 14, TextColor3 = ZINC200, Text = "", LayoutOrder = 3, ZIndex = 73, Parent = f })
	return value, unit
end

local function statRow(parent: Instance, order: number, emoji: string, name: string)
	local row = make("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = order, ZIndex = 72, Parent = parent })
	label({ Size = UDim2.new(0.7, 0, 1, 0), TextSize = 15, TextColor3 = ZINC100, TextXAlignment = Enum.TextXAlignment.Left, Text = emoji .. "  " .. name, ZIndex = 73, Parent = row })
	return label({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.3, 0, 1, 0), FontFace = FONT_BOLD, TextSize = 14, TextColor3 = ZINC200, TextXAlignment = Enum.TextXAlignment.Right, Text = "", ZIndex = 73, Parent = row })
end

local function actionButton(parent: Instance, order: number, n: number, icon: string, text: string, kind: string, onClick: () -> ())
	local color = BUTTON_COLORS[kind] or BUTTON_COLORS.normal
	local b = make("TextButton", {
		Size = UDim2.new(1 / n, -4 * (n - 1) / n, 0, 54),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.96,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = order,
		ZIndex = 73,
		Parent = parent,
	})
	corner(b, 8)
	make("UIStroke", { Color = WHITE, Transparency = 0.9, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
	IconKit.image(icon, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 7), Size = UDim2.fromOffset(20, 20), ImageColor3 = ZINC400, ZIndex = 74, Parent = b })
	label({ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(1, -6, 0, 18), FontFace = FONT_BOLD, TextSize = 13, TextColor3 = color, TextTruncate = Enum.TextTruncate.AtEnd, Text = text, ZIndex = 74, Parent = b })
	local function lit(on: boolean)
		b.BackgroundTransparency = if on then 0.9 else 0.96
	end
	b.MouseEnter:Connect(function()
		lit(true)
	end)
	b.MouseLeave:Connect(function()
		lit(false)
	end)
	b.SelectionGained:Connect(function()
		lit(true)
	end)
	b.SelectionLost:Connect(function()
		lit(false)
	end)
	b.Activated:Connect(onClick)
	return b
end

local function buildPanel()
	panelDim = dimmer("PlayerPanelDim", 70, hidePanel)
	panelCard, panelStroke = card("PlayerPanel", PANEL_W, 71)
	closeButton(panelCard, hidePanel, 76)
	local scroll = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 100),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 72,
		Parent = panelCard,
	})
	panelCard.AutomaticSize = Enum.AutomaticSize.None
	local body = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, ZIndex = 72, Parent = scroll })
	make("UIPadding", { PaddingLeft = UDim.new(0, 24), PaddingRight = UDim.new(0, 24), PaddingTop = UDim.new(0, 22), PaddingBottom = UDim.new(0, 22), Parent = body })
	local list = make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 9), Parent = body })
	ui.body = body
	-- The card is as tall as its content, up to 90% of the screen (then it scrolls).
	local function fit()
		local h = list.AbsoluteContentSize.Y + 44
		local maxH = gui.AbsoluteSize.Y * 0.9
		panelCard.Size = UDim2.fromOffset(math.min(PANEL_W, gui.AbsoluteSize.X - 16), math.min(h, maxH))
		scroll.Size = UDim2.fromScale(1, 1)
	end
	list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	ui.fit = fit

	-- Identity: flag, name, Nation / Tribe chip; traitor badge under it.
	local identity = make("Frame", { Size = UDim2.new(1, -24, 0, 40), BackgroundTransparency = 1, LayoutOrder = 1, ZIndex = 72, Parent = body })
	hlist(identity, 10)
	ui.flagBox = make("Frame", { Size = UDim2.fromOffset(40, 40), BackgroundColor3 = ZINC800, ClipsDescendants = true, LayoutOrder = 1, ZIndex = 73, Parent = identity })
	corner(ui.flagBox, 20)
	ui.name = label({ Size = UDim2.new(1, -150, 1, 0), FontFace = FONT_BOLD, TextSize = 20, TextColor3 = Color3.fromRGB(250, 250, 250), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, ZIndex = 73, Parent = identity })
	ui.chip = label({ Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 12, LayoutOrder = 3, ZIndex = 73, Parent = identity })
	ui.chip.BackgroundTransparency = 0.9
	corner(ui.chip, 11)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = ui.chip })
	ui.chipStroke = make("UIStroke", { Transparency = 0.75, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ui.chip })

	ui.traitor = make("Frame", { Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = RED500, BackgroundTransparency = 0.9, Visible = false, LayoutOrder = 2, ZIndex = 72, Parent = body })
	corner(ui.traitor, 12)
	make("UIStroke", { Color = RED400, Transparency = 0.7, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ui.traitor })
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = ui.traitor })
	hlist(ui.traitor, 6)
	IconKit.image("Traitor", { Size = UDim2.fromOffset(16, 16), ImageColor3 = Color3.fromRGB(254, 202, 202), LayoutOrder = 1, ZIndex = 73, Parent = ui.traitor })
	label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = Color3.fromRGB(254, 202, 202), Text = "Traitor", LayoutOrder = 2, ZIndex = 73, Parent = ui.traitor })
	ui.traitorTime = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = Color3.fromRGB(254, 226, 226), Text = "", LayoutOrder = 3, ZIndex = 73, Parent = ui.traitor })

	-- renderRelationPillIfNation: a Nation's relation to us (not when traitor / allied).
	ui.relation = label({ Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, Text = "", Visible = false, LayoutOrder = 2, ZIndex = 73, Parent = body })
	ui.relation.BackgroundTransparency = 0.9
	corner(ui.relation, 11)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = ui.relation })
	ui.relationStroke = make("UIStroke", { Transparency = 0.7, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ui.relation })

	divider(3, body)
	local resources = make("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 4, ZIndex = 72, Parent = body })
	hlist(resources, 8)
	ui.gold, ui.goldUnit = pill(resources, 1, "💰")
	ui.troops, ui.troopsUnit = pill(resources, 2, "🛡️")
	ui.goldUnit.Text, ui.troopsUnit.Text = "Gold", "Troops"

	divider(5, body)
	ui.betrayals = statRow(body, 6, "⚠️", "Betrayals")
	ui.trading = statRow(body, 7, "⚓", "Trading")
	ui.trading.Text = "Active"
	ui.trading.TextColor3 = BLUE400

	divider(8, body)
	local alliHead = make("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 9, ZIndex = 72, Parent = body })
	label({ Size = UDim2.new(0.8, 0, 1, 0), TextSize = 15, TextColor3 = ZINC200, TextXAlignment = Enum.TextXAlignment.Left, Text = "Alliances", ZIndex = 73, Parent = alliHead })
	ui.allyCount = label({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(22, 20), TextSize = 12, TextColor3 = ZINC100, ZIndex = 73, Parent = alliHead })
	ui.allyCount.BackgroundTransparency = 0.9
	ui.allyCount.BackgroundColor3 = WHITE
	corner(ui.allyCount, 10)
	ui.allyBox = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = ZINC800, BackgroundTransparency = 0.3, LayoutOrder = 10, ZIndex = 72, Parent = body })
	corner(ui.allyBox, 8)
	make("UIStroke", { Color = ZINC700, Transparency = 0.4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ui.allyBox })
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = ui.allyBox })
	local chips = hlist(ui.allyBox, 6)
	pcall(function()
		chips.Wraps = true
	end)

	ui.expiryRow = make("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, Visible = false, LayoutOrder = 11, ZIndex = 72, Parent = body })
	label({ Size = UDim2.new(0.7, 0, 1, 0), FontFace = FONT_BOLD, TextSize = 15, TextColor3 = ZINC300, TextXAlignment = Enum.TextXAlignment.Left, Text = "Alliance Expires In", ZIndex = 73, Parent = ui.expiryRow })
	ui.expiry = label({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.3, 0, 1, 0), FontFace = FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 73, Parent = ui.expiryRow })

	ui.actionsDivider = make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, LayoutOrder = 12, ZIndex = 72, Parent = body })
	ui.row1 = make("Frame", { Size = UDim2.new(1, 0, 0, 54), BackgroundTransparency = 1, LayoutOrder = 13, ZIndex = 72, Parent = body })
	hlist(ui.row1, 4)
	ui.row2 = make("Frame", { Size = UDim2.new(1, 0, 0, 54), BackgroundTransparency = 1, LayoutOrder = 14, ZIndex = 72, Parent = body })
	hlist(ui.row2, 4)
	ui.row3 = make("Frame", { Size = UDim2.new(1, 0, 0, 54), BackgroundTransparency = 1, LayoutOrder = 15, ZIndex = 72, Parent = body })
	hlist(ui.row3, 4)
end

local function clearChildren(f: Instance, className: string)
	for _, c in f:GetChildren() do
		if c:IsA(className) then
			c:Destroy()
		end
	end
end

-- Which actions this viewer has on the shown player (PlayerPanel.renderActions).
local function actionsFor(id: number)
	local myId = ctx.getMyId()
	local mine = ctx.roster[myId]
	local other = ctx.roster[id]
	local CM = ctx.contextMenu
	local alive = mine ~= nil and mine.stats.alive and ctx.getPhase() == "Play"
	if not alive or not other then
		return nil
	end
	local self = id == myId
	local allied = not self and CM.isAlly(id)
	local me = ctx.getMe and ctx.getMe() or {}
	local embargoed = false
	for _, e in me.embargoes or {} do
		if e == id then
			embargoed = true
		end
	end
	local a = {
		self = self,
		chat = other.kind ~= "Bot" and ctx.quickChat ~= nil,
		-- PlayerImpl.canTarget: not us, not friendly, no target set in the last 15 s (targetCooldown)
		target = not self and not allied and other.stats.alive and os.clock() - panel.lastTarget >= 15,
		embargo = not self and not embargoed, -- GameRunner: canEmbargo = !hasEmbargoAgainst(other)
		embargoAll = os.clock() - panel.lastEmbargoAll >= 10, -- embargoAllCooldown 10 s
		emoji = other.stats.alive,
		troops = allied and (other.kind ~= "Human" or CM.teamGame()) and other.stats.alive and mine.stats.troops >= 1,
		gold = allied and (other.kind ~= "Human" or CM.teamGame()) and other.stats.alive and mine.stats.gold >= 1,
		breakAlly = allied and not CM.isTeammate(id),
		sendAlly = not self and not allied and other.kind ~= "Bot" and other.stats.alive and not CM.hasOutgoing(id) and not MatchRules.alliancesOff(),
	}
	return a
end

local function rebuildActions(id: number)
	local a = actionsFor(id)
	local key = if a then string.format("%s%s%s%s%s%s%s%s%s%s", tostring(a.self), tostring(a.emoji), tostring(a.troops), tostring(a.gold), tostring(a.breakAlly), tostring(a.sendAlly), tostring(a.chat), tostring(a.target), tostring(a.embargo), tostring(a.embargoAll)) else "none"
	if key == panel.actionsKey then
		return
	end
	panel.actionsKey = key
	local hadSelection = GuiService.SelectedObject ~= nil and GuiService.SelectedObject:IsDescendantOf(panelCard)
	dropSelection(ui.row1)
	dropSelection(ui.row2)
	dropSelection(ui.row3)
	clearChildren(ui.row1, "TextButton")
	clearChildren(ui.row2, "TextButton")
	clearChildren(ui.row3, "TextButton")
	ui.actionsDivider.Visible = a ~= nil
	ui.row1.Visible, ui.row2.Visible, ui.row3.Visible = false, false, false
	if not a then
		return
	end
	local first = {}
	if a.chat then
		first[#first + 1] = { "Chat", "Chat", "normal", function()
			hidePanel()
			ctx.quickChat.open(id)
		end }
	end
	if a.emoji then
		first[#first + 1] = { "Emoji", "Emojis", "normal", function()
			PlayerPanel.showEmojiTable(id)
		end }
	end
	if a.target then
		first[#first + 1] = { "Target", "Target", "normal", function()
			panel.lastTarget = os.clock()
			ctx.net:FireServer("target", id)
			hidePanel()
		end }
	end
	if a.troops then
		first[#first + 1] = { "DonateTroops", "Troops", "normal", function()
			PlayerPanel.openSendModal(id, "troops")
		end }
	end
	if a.gold then
		first[#first + 1] = { "DonateGold", "Gold", "normal", function()
			PlayerPanel.openSendModal(id, "gold")
		end }
	end
	for i, d in first do
		actionButton(ui.row1, i, #first, d[1], d[2], d[3], d[4])
	end
	ui.row1.Visible = #first > 0
	local second = {}
	if not a.self then
		if a.embargo then
			second[#second + 1] = { "Stop", "Stop Trading", "yellow", function()
				ctx.net:FireServer("embargo", id, true)
				hidePanel()
			end }
		else
			second[#second + 1] = { "Port", "Start Trading", "green", function()
				ctx.net:FireServer("embargo", id, false)
				hidePanel()
			end }
		end
	end
	if a.breakAlly then
		second[#second + 1] = { "Traitor", "Break Alliance", "red", function()
			ctx.net:FireServer("allyBreak", id)
			hidePanel()
		end }
	end
	if a.sendAlly then
		second[#second + 1] = { "Alliance", "Send Alliance", "indigo", function()
			ctx.net:FireServer(if ctx.contextMenu.hasIncoming(id) then "allyAccept" else "allyRequest", id)
			hidePanel()
		end }
	end
	for i, d in second do
		actionButton(ui.row2, i, #second, d[1], d[2], d[3], d[4])
	end
	ui.row2.Visible = #second > 0
	if a.self then
		-- EmbargoAllExecution: every non-bot player but us (sent as one "embargo" per player).
		local function all(on: boolean)
			if os.clock() - panel.lastEmbargoAll < 10 then
				return
			end
			panel.lastEmbargoAll = os.clock()
			local list = {}
			for _, e in (ctx.getMe and ctx.getMe() or {}).embargoes or {} do
				list[e] = true
			end
			for pid, p in ctx.roster do
				if pid ~= id and p.kind ~= "Bot" and p.stats.alive and (list[pid] == true) ~= on then
					ctx.net:FireServer("embargo", pid, on)
				end
			end
			hidePanel()
		end
		local wait = if a.embargoAll then "" else " ⏳"
		actionButton(ui.row3, 1, 2, "Stop", "Stop Trading with All" .. wait, "yellow", function()
			all(true)
		end)
		actionButton(ui.row3, 2, 2, "Port", "Start Trading with All" .. wait, "green", function()
			all(false)
		end)
		ui.row3.Visible = true
	end
	if hadSelection or (panel.open and usingGamepad() and GuiService.SelectedObject == nil) then
		selectFirst(panelCard)
	end
end

local function refreshPanel()
	if not panel.open then
		return
	end
	local id = panel.id
	local p = ctx.roster[id]
	if not p then
		hidePanel()
		return
	end
	local CM = ctx.contextMenu
	ui.name.Text = p.name
	ui.gold.Text = ctx.fmt(p.stats.gold or 0)
	ui.troops.Text = (ctx.fmtTroops or ctx.fmt)(p.stats.troops or 0)
	ui.betrayals.Text = tostring(CM.betrayals[id] or 0)
	-- Trading: "Stopped" (amber-400) / "Active" (blue-400). OpenFront asks whether THEY embargo us;
	-- the shared contract only sends our own embargoes (me.embargoes), so that is what shows here.
	local stopped = false
	for _, e in (ctx.getMe and ctx.getMe() or {}).embargoes or {} do
		if e == id then
			stopped = true
		end
	end
	ui.trading.Text = if stopped then "Stopped" else "Active"
	ui.trading.TextColor3 = if stopped then AMBER400 else BLUE400

	-- Traitor badge + red ring.
	local traitor = CM.isTraitor(id)
	ui.traitor.Visible = traitor

	-- Relation pill (Hostile / Distrustful / Neutral / Friendly) for Nations.
	local rel = nil
	if p.kind == "Nation" and not traitor and id ~= ctx.getMyId() and not CM.isAlly(id) then
		for _, r in (ctx.getMe and ctx.getMe() or {}).relations or {} do
			if r[1] == id then
				rel = r[2]
			end
		end
	end
	ui.relation.Visible = rel ~= nil
	if rel ~= nil then
		local look = RELATION_LOOK[rel] or RELATION_LOOK[2]
		ui.relation.Text = look[1]
		ui.relation.TextColor3 = look[2]
		ui.relation.BackgroundColor3 = look[3]
		ui.relationStroke.Color = look[4]
	end
	panelStroke.Color = if traitor then RED500 else WHITE
	panelStroke.Thickness = if traitor then 2 else 1
	panelStroke.Transparency = if traitor then 0.45 + 0.25 * math.sin(os.clock() * math.pi / 1.2) else 0.95

	-- This player's alliances, soonest to expire first.
	local now = serverNow()
	local allies = {}
	for _, e in CM.alliances or {} do
		local other = if e[1] == id then e[2] elseif e[2] == id then e[1] else nil
		if other and ctx.roster[other] then
			allies[#allies + 1] = { name = ctx.roster[other].name, left = math.max(0, e[3] - now) }
		end
	end
	table.sort(allies, function(x, y)
		if math.floor(x.left) ~= math.floor(y.left) then
			return x.left < y.left
		end
		return string.lower(x.name) < string.lower(y.name)
	end)
	ui.allyCount.Text = tostring(#allies)
	local parts = {}
	for i, a in allies do
		parts[i] = a.name .. ":" .. math.floor(a.left)
	end
	local key = "#" .. table.concat(parts, "|") -- never "" so the empty list still draws "None"
	if key ~= panel.alliesKey then
		panel.alliesKey = key
		clearChildren(ui.allyBox, "Frame")
		clearChildren(ui.allyBox, "TextLabel")
		if #allies == 0 then
			label({ Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, TextSize = 14, TextColor3 = ZINC400, Text = "None", ZIndex = 73, Parent = ui.allyBox })
		end
		for i, a in allies do
			local chip = make("Frame", { Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = WHITE, BackgroundTransparency = 0.95, LayoutOrder = i, ZIndex = 73, Parent = ui.allyBox })
			corner(chip, 6)
			make("UIStroke", { Color = WHITE, Transparency = 0.9, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = chip })
			make("UIPadding", { PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9), Parent = chip })
			hlist(chip, 6)
			label({ Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, TextSize = 14, TextColor3 = ZINC100, Text = a.name, LayoutOrder = 1, ZIndex = 74, Parent = chip })
			label({ Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 11, TextColor3 = expiryColor(a.left), Text = duration(a.left), LayoutOrder = 2, ZIndex = 74, Parent = chip })
		end
	end

	-- Our own alliance with them.
	local exp = CM.allyExpiry(id)
	ui.expiryRow.Visible = exp ~= nil and id ~= ctx.getMyId()
	if exp then
		local left = math.max(0, exp - now)
		ui.expiry.Text = duration(left)
		ui.expiry.TextColor3 = expiryColor(left)
	end
	if traitor then
		local untilT = if CM.traitorUntil then CM.traitorUntil(id) else nil
		ui.traitorTime.Text = if untilT then "• " .. duration(untilT - now) else ""
	end
	rebuildActions(id)
	refreshSend()
end

function PlayerPanel.show(playerId: number)
	if not ctx then
		return
	end
	local p = ctx.roster[playerId]
	if not p then
		return
	end
	hideEmojiTable()
	closeSend()
	panel.open, panel.id, panel.actionsKey, panel.alliesKey = true, playerId, "", ""
	-- Identity row (static while open).
	clearChildren(ui.flagBox, "ImageLabel")
	local flag = if p.flag and p.flag ~= "" then FlagKit.image(p.flag, { Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Crop, ZIndex = 74, Parent = ui.flagBox }) else nil
	if flag then
		-- rounded-full: ClipsDescendants doesn't follow the box's UICorner, so round the image itself
		make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = flag })
	end
	ui.flagBox.Visible = flag ~= nil
	if p.kind == "Nation" then
		ui.chip.Visible = true
		ui.chip.Text = "🏛️ Nation"
		ui.chip.TextColor3 = Color3.fromRGB(199, 210, 254)
		ui.chip.BackgroundColor3 = Color3.fromRGB(99, 102, 241)
		ui.chipStroke.Color = INDIGO400
	elseif p.kind == "Bot" then
		ui.chip.Visible = true
		ui.chip.Text = "⚔️ Tribe"
		ui.chip.TextColor3 = Color3.fromRGB(233, 213, 255)
		ui.chip.BackgroundColor3 = PURPLE
		ui.chipStroke.Color = Color3.fromRGB(192, 132, 252)
	else
		ui.chip.Visible = false
	end
	panelDim.Visible = true
	panelCard.Visible = true
	refreshPanel()
	ui.fit()
	selectFirst(panelCard)
end

-- Setup
function PlayerPanel.setup(c)
	ctx = c
	gui = c.gui
	buildPanel()
	buildSendModal()
	buildEmojiTable()

	-- Esc / B close the topmost dialog.
	UserInputService.InputBegan:Connect(function(input)
		local k = input.KeyCode
		if k ~= Enum.KeyCode.Escape and k ~= Enum.KeyCode.ButtonB then
			return
		end
		if emojiCard.Visible then
			hideEmojiTable()
		elseif send.open then
			closeSend()
		elseif panel.open then
			hidePanel()
		end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		if panel.open and ctx.getPhase() ~= "Play" and ctx.getPhase() ~= "Ended" then
			hidePanel()
		end
		refreshPanel()
	end)
end

return PlayerPanel
