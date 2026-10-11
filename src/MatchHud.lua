--[[
	War Front - match HUD extras: attacks display, spawn timer, heads-up message,
	win modal and emoji bubbles.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MatchHud (ModuleScript), used by GameClient (via Interact).
-- Mirrors these OpenFront layers (src/client/hud/layers):
--   AttacksDisplay.ts  rows above the control panel: our attacks (with a retreat button), boats at
--                      sea (ETA, retreat), incoming attacks (retaliate) and incoming boats
--   SpawnTimer.ts      9 px bar across the top filling up during the spawn phase
--   HeadsUpMessage.ts  "Choose a starting location" banner (15% from the top) and toasts
--   WinModal.ts        end-of-round card: "You Won!" / "<name> has won!" / "Nation <name> has won!"
--   EventsDisplay.ts   emoji lines ("<name>: 😀", "Sent <name>: 😀"); the emoji also floats over
--                      the sender's territory for 5 s (NameLayer)
-- Reads the "me" snapshot (attacks, incoming, boatList, boatsIn) through ctx.getMe(); listens to
-- Shared.Net itself for "init", "phase" and "emoji".
-- MatchHud.setup(ctx)
--   ctx.gui, ctx.net, ctx.roster, ctx.getMyId(), ctx.getMe(), ctx.getPhase(), ctx.getRatio(),
--   ctx.fmt(n), ctx.stack (HudStack frame: the attack rows go in it), ctx.labelLayer (map overlay
--   frame for emoji bubbles), ctx.mapSize() -> (W, H), ctx.focusPlayer(id),
--   ctx.pushFeed(text, kind, owner), ctx.exitGame()
-- MatchHud.toast(text, color?)   OpenFront "show-message" toast ("green" | "red")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Emojis = require(Shared:WaitForChild("Emojis"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local Replay = require(script.Parent:WaitForChild("Replay"))
local ClockPanels = require(script.Parent:WaitForChild("ClockPanels"))

local MatchHud = {}

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(14, 43, 64)
local RED400 = Color3.fromRGB(248, 113, 113)
local RED_ICON = Color3.fromRGB(220, 38, 38)
local AQUARIUS = Color3.fromRGB(0,177,235)
local SLATE300 = Color3.fromRGB(203, 213, 225)
local BRIGHT_BLUE = Color3.fromHex("#1e90ff")

local ctx: any = nil
local gui: ScreenGui

local MatchSkin=require(script.Parent:WaitForChild("MatchSkin"))
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
	MatchSkin.decorate(inst)
	return inst
end

local function corner(parent: Instance, r: number?)
	make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function label(props)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextSize = props.TextSize or 14
	return make("TextLabel", props)
end

local function nameOf(id: number): string
	if id == 0 then
		return "Wilderness"
	end
	local p = ctx.roster[id]
	return if p then p.name else "?"
end

-- OpenFront getBoatETA: 1s, 35s, 1m, 1m1s ...
local function eta(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	if seconds <= 0 then
		return "0s"
	end
	local m, s = seconds // 60, seconds % 60
	return (if m > 0 then m .. "m" else "") .. (if s > 0 then s .. "s" else "")
end

-- Attacks display
local attacks = { rows = {} :: { [string]: any }, frame = nil :: any, grid = nil :: any }

local ROW_H = 32
local MAX_H = 112 -- OpenFront max-h-[7rem]

local function rowButton(parent: Instance, order: number)
	local b = make("TextButton", {
		Size = UDim2.new(1, -30, 1, 0),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 3),
		Parent = b,
	})
	return b
end

-- Night look for one attack / boat row: coloured stripe on the left, icon in a round badge, troops in
-- the title font, the name filling the free space, the time as a small pill and a round action button.
local function nightRow(row)
	local K, F = MatchSkin.Kit.C, MatchSkin.Kit.F
	local f = row.frame
	f.BackgroundColor3, f.BackgroundTransparency = K.CARD, 0
	f:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 10)
	local pad = f:FindFirstChildWhichIsA("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 12), UDim.new(0, 4)
	row.accent = make("Frame", { Name = "Accent", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -8, 0.5, 0), Size = UDim2.new(0, 3, 1, -12), BorderSizePixel = 0, BackgroundColor3 = K.CYAN, ZIndex = 4, Parent = f })
	corner(row.accent, 2)
	local list = row.main:FindFirstChildWhichIsA("UIListLayout")
	list.Padding = UDim.new(0, 7)
	local chip = make("Frame", { Name = "IconChip", Size = UDim2.fromOffset(22, 22), BackgroundColor3 = K.DEEP, BorderSizePixel = 0, LayoutOrder = 1, ZIndex = 4, Parent = row.main })
	corner(chip, 11)
	row.icon.AnchorPoint, row.icon.Position, row.icon.Parent = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), chip
	row.troops.FontFace, row.troops.TextSize = F.TITLE, 15
	row.name.FontFace = F.BOLD
	make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill, Parent = row.name })
	row.extra.FontFace, row.extra.TextSize, row.extra.TextColor3 = F.BOLD, 12, K.MUTED
	row.extra.BackgroundColor3, row.extra.BackgroundTransparency = K.DEEP, 0
	corner(row.extra, 9)
	make("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7), Parent = row.extra })
	row.action.Size = UDim2.fromOffset(26, 26)
	row.action:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
	row.status.FontFace, row.status.TextColor3 = F.BOLD, K.CYAN
end

local function makeRow(key: string)
	local f = make("Frame", {
		Name = key,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = attacks.grid,
	})
	corner(f, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 4), Parent = f })
	local main = rowButton(f, 1)
	local icon = IconKit.image("Soldier", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, ZIndex = 4, Parent = main })
	local arrow = label({ Size = UDim2.fromOffset(9, 16), FontFace = FONT_BOLD, TextSize = 13, Text = "", LayoutOrder = 2, ZIndex = 4, Parent = main })
	local troops = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, Text = "", LayoutOrder = 3, ZIndex = 4, Parent = main })
	local name = label({ Size = UDim2.new(1, -110, 0, 16), TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, Text = "", LayoutOrder = 4, ZIndex = 4, Parent = main })
	local extra = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, TextSize = 12, TextColor3 = SLATE300, Text = "", LayoutOrder = 5, ZIndex = 4, Parent = main })
	-- Right side: retreat (X), retaliate (sword) or "(retreating...)".
	local action = make("TextButton", {
		Name = "Action",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(26, 22),
		BackgroundColor3 = Color3.fromRGB(127, 29, 29),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		FontFace = FONT_BOLD,
		TextSize = 14,
		TextColor3 = RED400,
		Text = "",
		ZIndex = 4,
		Parent = f,
	})
	corner(action, 6)
	local retreat = IconKit.image("Back", { Name = "RetreatArrow", AnchorPoint = Vector2.new(0.5,0.5), Position = UDim2.fromScale(0.5,0.5), Size = UDim2.fromOffset(18,18), ImageColor3 = AQUARIUS, ZIndex = 5, Parent = action })
	local actionStroke = make("UIStroke", { Color = Color3.fromRGB(185, 28, 28), Transparency = 0.5, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = action })
	local sword = IconKit.image("Sword", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 16), ImageColor3 = RED_ICON, Visible = false, ZIndex = 5, Parent = action })
	local status = label({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -2, 0.5, 0), Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, TextSize = 13, TextColor3 = AQUARIUS, Text = "(retreating...)", Visible = false, ZIndex = 4, Parent = f })
	local row = { frame = f, main = main, icon = icon, arrow = arrow, troops = troops, name = name, extra = extra, action = action, actionStroke = actionStroke, sword = sword, retreat = retreat, status = status }
	main.Activated:Connect(function()
		if row.onMain then
			row.onMain()
		end
	end)
	action.Activated:Connect(function()
		if row.onAction then
			row.onAction()
		end
	end)
	if MatchSkin.night then
		nightRow(row)
	end
	attacks.rows[key] = row
	return row
end

-- kind: "out" | "land" | "boat" | "in" | "inboat"
local function fillRow(row, kind: string, order: number, d)
	row.frame.LayoutOrder = order
	local incoming = kind == "in" or kind == "inboat"
	local color = if incoming then RED400 else AQUARIUS
	local boat = kind == "boat" or kind == "inboat"
	local hud=gui:FindFirstChild("CornerHud")
 local population=not boat and hud and hud:GetAttribute("InGameUILayout")=="Default"
 local iconName = if boat then "Boat" elseif population then "Population" else "Soldier"
	if row.iconName ~= iconName then
		row.iconName = iconName
		if population then
   row.icon.Image="rbxassetid://112831062230992";row.icon.ImageRectOffset=Vector2.zero;row.icon.ImageRectSize=Vector2.zero
  else IconKit.set(row.icon, iconName) end
	end
	if boat then
		local owner = ctx.roster[d.owner]
		row.icon.ImageColor3 = if owner then Color3.fromRGB(owner.r or 255, owner.g or 255, owner.b or 255) else WHITE
		row.icon.Size = UDim2.fromOffset(18, 18)
	else
		row.icon.ImageColor3 = if population then WHITE elseif incoming then RED_ICON else AQUARIUS
		row.icon.Size = UDim2.fromOffset(if population then 18 else 16, if population then 18 else 16)
	end
 row.arrow.Visible=not population
	row.arrow.Text = if boat then "" elseif incoming then "↓" else "↑"
	row.arrow.Size = UDim2.fromOffset(if boat or population then 0 else 9, 16)
	row.arrow.TextColor3 = color
	row.troops.Text = (ctx.fmtTroops or ctx.fmt)(d.troops) -- renderTroops
	row.troops.TextColor3 = color
	row.name.Text = d.name
	row.name.TextColor3 = color
	row.name.TextSize = if boat then 12 else 14
	row.troops.AutomaticSize = Enum.AutomaticSize.None
	row.troops.Size = UDim2.fromOffset(65,16)
	row.name.Size = UDim2.new(1, -(if boat then 150 else 112), 0, 16)
	row.extra.AutomaticSize = Enum.AutomaticSize.None
	row.extra.Size = UDim2.fromOffset(if boat then 44 else 0,16)
	row.extra.Text = d.extra or ""
	row.onMain = d.onMain
	row.onAction = d.onAction
	local retreating = d.retreating == true
	row.status.Visible = retreating
	row.action.Visible = d.onAction ~= nil and not retreating
	row.sword.Visible = kind == "in"
	row.action.Text = ""
	row.retreat.Visible = kind ~= "in"
	row.action.BackgroundTransparency = if kind == "in" then 0.5 else 1
	row.actionStroke.Enabled = kind == "in"
	row.action.Selectable = row.action.Visible
	row.main.Selectable = d.onMain ~= nil
	if MatchSkin.night and row.accent then
		local K = MatchSkin.Kit.C
		local accent = if incoming then K.PINK else K.CYAN
		row.accent.BackgroundColor3 = accent
		row.arrow.TextColor3 = accent
		row.troops.TextColor3 = accent
		row.troops.AutomaticSize, row.troops.Size = Enum.AutomaticSize.X, UDim2.fromOffset(0, 18)
		row.name.TextColor3, row.name.TextSize = K.TEXT, 13
		row.name.Size = UDim2.new(0, 0, 0, 18)
		row.extra.AutomaticSize, row.extra.Size = Enum.AutomaticSize.X, UDim2.fromOffset(0, 18)
		row.extra.Visible = row.extra.Text ~= ""
		if not boat and not population then
			row.icon.ImageColor3 = accent
		end
		row.action.BackgroundTransparency = 0
		row.action.BackgroundColor3 = if kind == "in" then Color3.fromRGB(122, 48, 74) else K.RAISED
		row.actionStroke.Enabled = false
		row.retreat.ImageColor3 = K.TEXT
		row.main.Size = UDim2.new(1, if row.action.Visible or row.status.Visible then -34 else 0, 1, 0)
	end
end

local function refreshAttacks()
	local frame = attacks.frame
	if not frame then
		return
	end
	local myId = ctx.getMyId()
	local mine = ctx.roster[myId]
	local me = ctx.getMe()
	local show = ctx.getPhase() == "Play" and mine ~= nil and mine.stats.alive
	local seen = {}
	local order = 0
	local function put(key: string, kind: string, d)
		order += 1
		seen[key] = true
		local row = attacks.rows[key] or makeRow(key)
		fillRow(row, kind, order, d)
	end
	if show then
		local function focus(id: number)
			return function()
				ctx.focusPlayer(id)
			end
		end
		-- Outgoing attacks on players, then on the wilderness.
		for _, a in me.attacks or {} do
			local target, troops, retreating = a[1], a[2], a[3]
			if target ~= 0 then
				put("out" .. target, "out", {
					troops = troops,
					name = nameOf(target),
					retreating = retreating,
					onMain = focus(target),
					onAction = function()
						ctx.net:FireServer("retreat", target)
						if ctx.onRetreat then ctx.onRetreat() end
					end,
				})
			end
		end
		for _, a in me.attacks or {} do
			if a[1] == 0 then
				put("land", "land", {
					troops = a[2],
					name = "Wilderness",
					retreating = a[3],
					onAction = function()
						ctx.net:FireServer("retreat", 0)
						if ctx.onRetreat then ctx.onRetreat() end
					end,
				})
			end
		end
		-- Our boats at sea.
		for _, b in me.boatList or {} do
			local id, troops, targetOwner, secs, retreating = b[1], b[2], b[3], b[4], b[5]
			put("boat" .. id, "boat", {
				owner = myId,
				troops = troops,
				name = if retreating then nameOf(myId) else nameOf(targetOwner),
				extra = eta(secs),
				retreating = retreating,
				onMain = focus(targetOwner),
				onAction = function()
					ctx.net:FireServer("boatRetreat", id)
				end,
			})
		end
		-- Incoming attacks (not from bots) with a retaliate button, then incoming boats.
		for _, a in me.incoming or {} do
			local attacker, troops, retreating = a[1], a[2], a[3]
			put("in" .. attacker, "in", {
				troops = troops,
				name = nameOf(attacker) .. (if retreating then " (retreating...)" else ""),
				retreating = false,
				onMain = focus(attacker),
				onAction = if retreating then nil else function()
					ctx.net:FireServer("retaliate", attacker, ctx.getRatio())
				end,
			})
		end
		for _, b in me.boatsIn or {} do
			local id, troops, owner, secs = b[1], b[2], b[3], b[4]
			put("inboat" .. id, "inboat", {
				owner = owner,
				troops = troops,
				name = nameOf(owner),
				extra = eta(secs),
				onMain = focus(owner),
			})
		end
	end
	for key, row in attacks.rows do
		if not seen[key] then
			local sel = GuiService.SelectedObject
			if sel and sel:IsDescendantOf(row.frame) then
				GuiService.SelectedObject = nil
			end
			row.frame:Destroy()
			attacks.rows[key] = nil
		end
	end
	local rows = order
	local layout = frame:FindFirstChildWhichIsA("UIGridLayout")
	local rowHeight = if layout then layout.CellSize.Y.Offset else ROW_H
	local h = rows * rowHeight + math.max(0, rows - 1) * 4
	frame.Visible = order > 0
	local available = if frame.Parent and frame.Parent:IsA("GuiObject") and frame.Parent.Name~="Stack" then frame.Parent.AbsoluteSize.Y else MAX_H
	frame.Size = UDim2.new(1, 0, 0, math.min(h, MAX_H, math.max(0,available)))
	frame.CanvasSize = UDim2.fromOffset(0, h)
end

local function buildAttacks(parent: Instance)
	local frame = make("ScrollingFrame", {
		Name = "AttacksDisplay",
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		LayoutOrder = 1,
		Selectable = false,
		Parent = parent,
	})
	attacks.frame = frame
	attacks.grid = frame
	if MatchSkin.night then
		frame.ScrollBarImageColor3 = MatchSkin.Kit.C.LINE
	end
	make("UIGridLayout", {
		CellSize = UDim2.new(1, -4, 0, ROW_H),
		CellPadding = UDim2.fromOffset(4, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = frame,
	})
end

-- Spawn timer + heads-up message + toast
local phaseInfo = { phase = "Lobby", ticksLeft = 0, at = 0, winnerId = 0, winner = nil :: string?, winnerTeam = nil :: string? }
local spawnBar: Frame
local spawnFill: Frame
local headsUp: TextLabel
local toastFrame: Frame
local toastText: TextLabel
local toastToken = 0

local function buildTop()
	spawnBar = make("Frame", { Name = "SpawnTimer", Size = UDim2.new(1, 0, 0, 9), BackgroundTransparency = 1, Visible = false, ZIndex = 30, Parent = gui })
	spawnFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = BRIGHT_BLUE, BackgroundTransparency = 0.15, BorderSizePixel = 0, ZIndex = 30, Parent = spawnBar })
	-- border-b-3 / border-r-2 black
	make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 31, Parent = spawnFill })
	make("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 31, Parent = spawnFill })

	headsUp = label({
		Name = "HeadsUpMessage",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5,0,0,180),
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0.3,
		BackgroundColor3 = GRAY800,
		TextSize = 20,
		Text = "",
		Visible = false,
		ZIndex = 29,
		Parent = gui,
	})
	corner(headsUp, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), Parent = headsUp })
	make("UISizeConstraint", { MaxSize = Vector2.new(900, 200), Parent = headsUp })

	toastFrame = make("Frame", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 86),
		Size = UDim2.fromOffset(520, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(34, 197, 94),
		BackgroundTransparency = 0.85,
		Visible = false,
		ZIndex = 35,
		Parent = gui,
	})
	corner(toastFrame, 12)
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = toastFrame })
	make("UIStroke", { Name = "Border", Color = Color3.fromRGB(34, 197, 94), Transparency = 0.5, Parent = toastFrame })
	toastText = label({ Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped=true, FontFace = FONT, TextSize = 16, Text = "", ZIndex = 36, Parent = toastFrame })
end

-- Keep transient messages beneath the actual top HUD rectangles, including scaled layouts.
local function layoutToast()
 if not toastFrame or not gui then return end
 local origin=gui.AbsolutePosition;local size=gui.AbsoluteSize
 local width=math.min(520,math.max(160,size.X-24))
 toastFrame.Size=UDim2.fromOffset(width,0)
 local left=origin.X+(size.X-width)/2;local right=left+width
 local top=math.max(12,GuiService.TopbarInset.Max.Y+6)
 local function avoid(v)
  if not v or not v:IsA("GuiObject") or not v.Visible then return end
  local p,s=v.AbsolutePosition,v.AbsoluteSize
  if s.X>0 and s.Y>0 and p.Y<origin.Y+size.Y*.55 and p.X<right and p.X+s.X>left then
   top=math.max(top,p.Y-origin.Y+s.Y+10)
  end
 end
 local corner=gui:FindFirstChild("CornerHud")
 if corner and corner.Visible then
  avoid(corner:FindFirstChild("RoundStatus"));avoid(corner:FindFirstChild("Resources"))
  local utilities=corner:FindFirstChild("Utilities")
  if utilities then for _,v in utilities:GetChildren() do if v:IsA("GuiButton") then avoid(v) end end end
 end
 -- Toasts own the message lane; hover and spawn prompts resume when the toast expires.
 local banner=gui:FindFirstChild("Banner");if banner and toastFrame.Visible then banner.Visible=false end
 if headsUp and toastFrame.Visible then headsUp.Visible=false end
 toastFrame.Position=UDim2.new(.5,0,0,top)
end

function MatchHud.toast(text: string, color: string?, seconds: number?)
	if not toastFrame then
		return
	end
	-- (tutorial: only warnings; info notices would cover the step's target, the feed still lists them)
	local tutorialPg = gui:FindFirstAncestorWhichIsA("PlayerGui")
	if color ~= "red" and tutorialPg and tutorialPg:GetAttribute("FrontlinesTutorial") == true then
		return
	end
	local c = if color == "red" then Color3.fromRGB(239, 68, 68) else Color3.fromRGB(34, 197, 94)
	toastFrame.BackgroundColor3 = MatchSkin.C.panel
	local border = toastFrame:FindFirstChild("Border") :: UIStroke?
	if border then
		border.Color = c
	end
	toastText.Text = text
	toastFrame.Visible = true
	layoutToast()
	toastToken += 1
	local token = toastToken
	task.delay(seconds or 2, function()
		if toastToken == token then
			toastFrame.Visible = false
		end
	end)
end

local function refreshTop()
	local ph = ctx.getPhase()
	local inSpawn = ph == "Spawn"
 local banner=gui:FindFirstChild("Banner");if banner then headsUp.Position=UDim2.new(.5,0,0,banner.AbsolutePosition.Y-gui.AbsolutePosition.Y) end
	spawnBar.Visible = inSpawn
	if inSpawn then
		local total = Config.SPAWN_PHASE_TICKS
		local left = phaseInfo.ticksLeft - (os.clock() - phaseInfo.at) / Config.TICK
		spawnFill.Size = UDim2.fromScale(math.clamp((total - left) / total, 0, 1), 1)
	end
	-- (Overtime: "Overtime! ..." for its first 5 seconds, HeadsUpMessage.isOvertimeNotice.)
	local overtime = not inSpawn and ClockPanels.overtimeNotice()
	-- (the tutorial's own bubble says where to start, and the banner would cover its ring)
	local hudPg = gui:FindFirstAncestorWhichIsA("PlayerGui")
	local tutorialOn = hudPg ~= nil and hudPg:GetAttribute("FrontlinesTutorial") == true
	headsUp.Visible = ((inSpawn and not tutorialOn) or overtime) and not toastFrame.Visible
	if inSpawn then
		local mine = ctx.roster[ctx.getMyId()]
		headsUp.Text = if MatchSkin.night then (if ctx.getMyId() ~= 0 and mine then "Pick your starting spot" else "Everyone is picking a starting spot")
		elseif ctx.getMyId() ~= 0 and mine then "Choose a starting location" else "Players are choosing starting locations"
	elseif overtime then
		headsUp.Text = "Overtime! The territory needed to win is now dropping."
	end
end

-- Win modal
local win = { card = nil :: any, title = nil :: any, body = nil :: any, keep = nil :: any, shownFor = "" }

local function hideWin()
	if win.card and win.card.Visible then
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(win.card) then
			GuiService.SelectedObject = nil
		end
		win.card.Visible = false
	end
end

local function buildWin()
	local c = make("Frame", {
		Name = "WinModal",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 60,
		Parent = gui,
	})
	corner(c, 8)
	make("UISizeConstraint", { MaxSize = Vector2.new(700, math.huge), Parent = c })
	-- p-4 md:p-6
	make("UIPadding", { PaddingLeft = UDim.new(0, 24), PaddingRight = UDim.new(0, 24), PaddingTop = UDim.new(0, 24), PaddingBottom = UDim.new(0, 24), Parent = c })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 16), HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = c })
	local kicker=label({Size=UDim2.new(1,0,0,16),TextSize=11,TextColor3=MatchSkin.C.cyan,Text="MATCH COMPLETE",LayoutOrder=0,ZIndex=61,Parent=c})
	kicker.Visible=not MatchSkin.night
	if MatchSkin.night then
		-- Night: trophy when you win, torn flag when you don't.
		win.art = require(script.Parent:WaitForChild("NightMenu"):WaitForChild("Art")).image("YouWon", { Size = UDim2.fromOffset(96, 96), LayoutOrder = 0, Visible = false, ZIndex = 61, Parent = c })
	end
 win.title = label({ Size = UDim2.new(1, 0, 0, 58), TextSize = 42, TextColor3=MatchSkin.C.gold,TextWrapped = true, Text = "", LayoutOrder = 1, ZIndex = 61, Parent = c })
 win.result=label({Size=UDim2.new(1,0,0,24),TextSize=14,Text=" ",LayoutOrder=2,ZIndex=61,Parent=c})
 win.metrics=label({Size=UDim2.new(1,0,0,40),TextWrapped=true,TextSize=12,TextColor3=MatchSkin.C.cyan,Text="",LayoutOrder=3,ZIndex=61,Parent=c})
	local box = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.7, LayoutOrder = 4, ZIndex = 61, Parent = c })
	corner(box, 2) -- rounded-sm
	if MatchSkin.night then
		-- Night: rewards earned (Meta "reward") and today's missions under the result.
		local K = MatchSkin.Kit.C
		box.BackgroundColor3, box.BackgroundTransparency = K.CARD, 0
		box:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 12)
		win.rewards = Instance.new("Frame")
		win.rewards.Name = "Rewards"
		win.rewards.BackgroundTransparency = 1
		win.rewards.Size = UDim2.new(1, 0, 0, 30)
		win.rewards.LayoutOrder = 3
		win.rewards.Visible = false
		win.rewards.ZIndex = 61
		win.rewards.Parent = c
		MatchSkin.Kit.list(win.rewards, true, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
		win.missions = MatchSkin.Kit.card({ Name = "Missions", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Visible = false, ZIndex = 61, Parent = c })
		MatchSkin.Kit.pad(win.missions, 14, 14, 10, 10)
		MatchSkin.Kit.list(win.missions, false, 6)
		box.LayoutOrder = 5
	end
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = box })
	win.body = label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, FontFace = FONT_BOLD, TextSize = 20, TextWrapped = true, Text = "", ZIndex = 62, Parent = box }) -- h3 text-xl font-semibold
	local buttons = make("Frame", { Size = UDim2.new(1, 0, 0, 48), BackgroundTransparency = 1, LayoutOrder = 6, ZIndex = 61, Parent = c })
	win.buttonFrame=buttons
 win.buttonGrid=make("UIGridLayout",{CellSize=UDim2.new(.5,-5,0,48),CellPadding=UDim2.fromOffset(10,10),FillDirectionMaxCells=4,SortOrder=Enum.SortOrder.LayoutOrder,Parent=buttons})
	-- o-button primary block: bg-malibu-blue hover:bg-aquarius, rounded-xl, bold uppercase.
	local function oButton(text: string, order: number, onClick: () -> ())
		local malibu = if text=="KEEP PLAYING" then MatchSkin.C.cyan else MatchSkin.C.raised
		if MatchSkin.night then
			malibu = if text=="KEEP PLAYING" then MatchSkin.C.gold else MatchSkin.C.raised
		end
		local b = make("TextButton", {
			Size = UDim2.new(0.5, -5, 1, 0),
			BackgroundColor3 = malibu,
			AutoButtonColor = false,
			FontFace = FONT_BOLD,
			TextSize = 16,
			TextColor3 = WHITE,
			Text = text,
			LayoutOrder = order,
			ZIndex = 62,
			Parent = buttons,
		})
		corner(b, 12)
		if MatchSkin.night then
			b.Text = ({ ["KEEP PLAYING"] = "Play again", ["EXIT GAME"] = "Leave", ["WATCH REPLAY"] = "Watch replay", STATS = "Stats" })[text] or text
			b.FontFace = MatchSkin.Kit.F.TITLE
			b.TextSize = 18
			b.TextColor3 = if text == "KEEP PLAYING" then MatchSkin.Kit.C.YELLOW_TEXT elseif text == "EXIT GAME" then MatchSkin.Kit.C.PINK else WHITE
			b:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
		end
		-- Night: Leave has pink text and turns red on hover, like the other Leave buttons.
		local leave = MatchSkin.night and text == "EXIT GAME"
		local idleText = b.TextColor3
		local hoverColor = if leave then Color3.fromRGB(214, 64, 86) elseif MatchSkin.night then malibu:Lerp(WHITE, 0.12) else AQUARIUS
		local function lit(on: boolean)
			b.BackgroundColor3 = if on then hoverColor else malibu
			if leave then
				b.TextColor3 = if on then WHITE else idleText
			end
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
	win.exitBtn = oButton("EXIT GAME", 1, function()
		hideWin()
		if ctx.exitGame then
			ctx.exitGame()
		end
	end)
	win.keep = oButton("KEEP PLAYING", 3, function()
		if ctx.getPhase() ~= "Ended" then return end
		hideWin()
		ctx.net:FireServer("requeue")
	end)
	-- War Front: the round can be watched again right away (Replay.lua); OpenFront lists replays
	-- in the player's game history instead.
	win.replay = oButton("WATCH REPLAY", 2, function()
		hideWin()
		Replay.start()
	end)
	win.replay.Visible = false
	-- OpenFront GameStatsModal: this round's stats (server "matchStats", GameStatsView).
	win.stats = oButton("STATS", 4, function()
		if win.matchStats then
			require(script.Parent:WaitForChild("GameStatsView")).open(gui, win.matchStats)
		end
	end)
	win.stats.Visible = false
	win.card = c
 local mobileScale=Instance.new("UIScale");mobileScale.Name="MobileDialogScale";mobileScale.Parent=c
 local fitting=false
 local function fitMobile()
  if fitting then return end;fitting=true
  task.defer(function()
   if c.Parent then
    local st=require(script.Parent.DeviceLayout).state
    local height=c.AbsoluteSize.Y/math.max(.01,mobileScale.Scale)
    -- phones: fit between Roblox's top bar and the bottom edge (this screen covers the top bar)
    local touchPhone=st.touch and (st.profile=="phone" or st.profile=="tablet")
    local inset=if touchPhone and gui:IsA("ScreenGui") and gui.IgnoreGuiInset then game:GetService("GuiService").TopbarInset.Height else 0
    local target=if touchPhone then math.min(1,(gui.AbsoluteSize.Y-inset-24)/math.max(1,height)) else 1
    if math.abs(mobileScale.Scale-target)>.002 then mobileScale.Scale=target end
    c.Position=UDim2.new(.5,0,.5,inset/2)
   end
   fitting=false
  end)
 end
 local resize=gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitMobile)
 local contentResize=c:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitMobile)
 c.Destroying:Connect(function()resize:Disconnect();contentResize:Disconnect()end);fitMobile()
end

-- Night results extras: reward pills (Meta "reward", sent when the round's rewards are saved) and
-- today's missions (MetaFn "missions"), refreshed each time the results show.
local lastReward: any = nil
local function nightRewards()
	if not win.rewards then
		return
	end
	local Kit = MatchSkin.Kit
	for _, v in win.rewards:GetChildren() do
		if v:IsA("GuiObject") then
			v:Destroy()
		end
	end
	local r = lastReward
	win.rewards.Visible = r ~= nil
	if not r then
		return
	end
	Kit.chip("+" .. tostring(r.coins or 0) .. " medals", { icon = "Medal", textColor = Kit.C.YELLOW, height = 30, layoutOrder = 1, parent = win.rewards })
	Kit.chip("+" .. tostring(r.xp or 0) .. " XP", { textColor = Kit.C.CYAN, height = 30, layoutOrder = 2, parent = win.rewards })
	if r.vip then
		Kit.chip("VIP bonus", { icon = "Star", iconColor = Kit.C.YELLOW, height = 30, layoutOrder = 3, parent = win.rewards })
	end
	if r.friend then
		Kit.chip("Friend bonus", { icon = "Friends", iconColor = Kit.C.GREEN, height = 30, layoutOrder = 4, parent = win.rewards })
	end
end
local missionsAsk = 0
function MatchHud.nightResults(_won: boolean)
	nightRewards()
	if not win.missions then
		return
	end
	missionsAsk += 1
	local my = missionsAsk
	task.spawn(function()
		task.wait(2) -- the server saves the round's mission progress first
		local fn = Shared:FindFirstChild("MetaFn")
		local ok, success, data
		for _ = 1, 3 do -- MetaFn calls can be briefly rate limited right after a round
			ok, success, data = pcall(function()
				if not fn then
					return false
				end
				return fn:InvokeServer("missions") -- both results (an `and` here would keep only the first)
			end)
			if (ok and success and type(data) == "table") or my ~= missionsAsk then
				break
			end
			task.wait(1.5)
		end
		if my ~= missionsAsk or not win.missions.Parent then
			return
		end
		local Kit = MatchSkin.Kit
		local Art = require(script.Parent:WaitForChild("NightMenu"):WaitForChild("Art"))
		for _, v in win.missions:GetChildren() do
			if v:IsA("GuiObject") then
				v:Destroy()
			end
		end
		local list = ok and success and type(data) == "table" and data.daily
		win.missions.Visible = type(list) == "table" and #list > 0
		if not win.missions.Visible then
			return
		end
		Kit.text({ Text = "Today's missions", FontFace = Kit.F.TITLE, TextSize = 15, TextColor3 = Kit.C.MUTED, LayoutOrder = 0, Parent = win.missions })
		for i, m in list do
			local n, goal = tonumber(m.n) or 0, math.max(1, tonumber(m.goal) or 1)
			local done = n >= goal
			local row = Kit.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = i, ZIndex = 62, Parent = win.missions })
			Kit.list(row, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
			if done then
				Kit.icon("CheckCircle", { Size = UDim2.fromOffset(20, 20), ImageColor3 = Kit.C.GREEN, LayoutOrder = 1, Parent = row })
			else
				Art.image(Art.mission(m.id), { Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = row })
			end
			local t = Kit.text({ Text = tostring(m.text or ""), FontFace = Kit.F.BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -110, 1, 0), AutomaticSize = Enum.AutomaticSize.None, LayoutOrder = 2, Parent = row })
			t.TextTruncate = Enum.TextTruncate.AtEnd
			Kit.text({ Text = if m.claimed then "Collected" elseif done then "Done!" else n .. "/" .. goal, FontFace = Kit.F.TITLE, TextSize = 15, TextColor3 = if done then Kit.C.GREEN else Kit.C.MUTED, LayoutOrder = 3, Parent = row })
		end
	end)
end

if MatchSkin.night then
	task.spawn(function()
		Shared:WaitForChild("Meta").OnClientEvent:Connect(function(kind, data)
			if kind == "reward" and type(data) == "table" then
				lastReward = data
				nightRewards()
			end
		end)
	end)
end

local function refreshWin()
	if ctx.getPhase() ~= "Ended" then
		hideWin()
		win.shownFor = ""
		lastReward = nil
		return
	end
	local myId = ctx.getMyId()
	local key = tostring(phaseInfo.winnerId) .. ":" .. tostring(phaseInfo.winner) .. ":" .. tostring(phaseInfo.winnerTeam)
	if win.shownFor ~= key then
		win.shownFor = key
		local wid = phaseInfo.winnerId or 0
		local w = ctx.roster[wid]
		local title
		local mineP = ctx.roster[myId]
		if phaseInfo.winnerTeam then
			-- win_modal.your_team / other_team
			title = if mineP and mineP.team == phaseInfo.winnerTeam then "Your team won!" else phaseInfo.winnerTeam .. " team has won!"
		elseif wid ~= 0 and wid == myId then
			title = "You Won!"
		elseif w and w.kind == "Nation" then
			title = "Nation " .. w.name .. " has won!"
		elseif w or phaseInfo.winner then
			title = (if w then w.name else phaseInfo.winner) .. " has won!"
		else
			title = "Round over"
		end
		local won=wid==myId and myId~=0 or (phaseInfo.winnerTeam~=nil and mineP and mineP.team==phaseInfo.winnerTeam)
 win.title.Text=if won then "VICTORY" elseif myId~=0 then "DEFEAT" else "MATCH OVER"
 win.title.TextColor3=if won then MatchSkin.C.gold else MatchSkin.C.red
 win.result.Text=title
		local mine = ctx.roster[myId]
		win.keep.Text = "KEEP PLAYING"
		if MatchSkin.night then
			win.title.Text = if won then "You won!" else "Battle over"
			win.title.TextColor3 = if won then MatchSkin.C.gold else MatchSkin.C.white
			win.title.FontFace = MatchSkin.Kit.F.TITLE
			if win.art then
				require(script.Parent:WaitForChild("NightMenu"):WaitForChild("Art")).set(win.art, if won then "YouWon" else "Defeated")
				win.art.Visible = won or myId ~= 0
			end
			win.result.Text = string.gsub(title, "^You Won!$", "You took the most land")
			win.keep.Text = "Play again"
			MatchHud.nightResults(won)
		end
		win.card.Visible = true
		if UserInputService.GamepadEnabled and string.find(UserInputService:GetLastInputType().Name, "Gamepad") then
			GuiService.SelectedObject = win.keep
		end
	end
	local st=win.matchStats
 win.metrics.Visible=st~=nil
 if st then win.metrics.Text=string.format("PEAK LAND %.1f%%  /  ELIMINATIONS %d  /  TIME %d:%02d",tonumber(st.peakPercent) or 0,tonumber(st.kills) or 0,(tonumber(st.seconds) or 0)//60,(tonumber(st.seconds) or 0)%60) end
 if st and MatchSkin.night then
  win.metrics.Text=string.format("Most land %.0f%%  ·  Beat %d  ·  %d:%02d long",tonumber(st.peakPercent) or 0,tonumber(st.kills) or 0,(tonumber(st.seconds) or 0)//60,(tonumber(st.seconds) or 0)%60)
  win.metrics.TextColor3=MatchSkin.C.muted;win.metrics.TextSize=14
 end
 local secs = math.max(0, math.ceil((phaseInfo.ticksLeft - (os.clock() - phaseInfo.at) / Config.TICK) * Config.TICK))
	win.body.Text = string.format("Next round starts in %ds", secs)
	if workspace:GetAttribute("WFPlaceRole") == "match" then
		win.body.Text = string.format("Back to the lobby in %ds", secs)
	end
	-- flex-1 buttons: share the row between the visible ones
	local canReplay = Replay.available()
	local hasStats = win.matchStats ~= nil
 local n=2+(if canReplay then 1 else 0)+(if hasStats then 1 else 0)
 local cols=if ctx.gui.AbsoluteSize.X<600 then 2 else n
 -- Whole-pixel cells leave a rounding margin so the last button cannot wrap.
 local available=math.max(1,win.buttonFrame.AbsoluteSize.X)
 local cellWidth=math.max(1,math.floor((available-10*(cols-1)-2)/cols))
 win.buttonGrid.FillDirectionMaxCells=cols
 win.buttonGrid.CellSize=UDim2.fromOffset(cellWidth,48)
 local rows=math.ceil(n/cols)
 win.buttonFrame.Size=UDim2.new(1,0,0,math.max(rows*48+(rows-1)*10,win.buttonGrid.AbsoluteContentSize.Y))
 win.title.TextSize=math.min(42,math.max(26,ctx.gui.AbsoluteSize.X*.08))
	if win.replay.Visible ~= canReplay or win.stats.Visible ~= hasStats then
		win.replay.Visible = canReplay
		win.stats.Visible = hasStats
		local n = 2 + (if canReplay then 1 else 0) + (if hasStats then 1 else 0)
		for _, b in { win.keep, win.replay, win.exitBtn, win.stats } do
			if b then
				b.Size = UDim2.new(1 / n, -(10 * (n - 1)) / n, 1, 0)
			end
		end
	end
end

-- Emoji messages
local bubbles: { any } = {}

local function onEmoji(data)
	local from, to, index = data.from, data.to, data.i
	local emoji = Emojis.LIST[index]
	if not emoji then
		return
	end
	local myId = ctx.getMyId()
	local sender = ctx.roster[from]
	if not sender then
		return
	end
	-- Feed line (EventsDisplay.onEmojiMessageEvent): to us, or sent by us to one player.
	if to == myId and myId ~= 0 then
		ctx.pushFeed(sender.name .. ": " .. emoji, "info", from)
	elseif from == myId and to ~= 0 then
		ctx.pushFeed("Sent " .. nameOf(to) .. ": " .. emoji, "info", to)
	end
	-- Over the sender's territory for everyone it was meant for (NameLayer shows emojis sent to
	-- us or to all players).
	-- Settings "Emojis" off hides them over the map.
	local showEmojis = require(script.Parent:WaitForChild("Settings")).values.emojis ~= false
	if showEmojis and (to == myId or to == 0) and ctx.labelLayer and sender.stats and sender.stats.tiles > 0 then
		local b = label({
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.fromOffset(34, 34),
			TextSize = 28,
			Text = emoji,
			ZIndex = 8,
			Parent = ctx.labelLayer,
		})
		bubbles[#bubbles + 1] = { label = b, owner = from, untilT = os.clock() + Emojis.DURATION }
	end
end

local function stepBubbles()
	local now = os.clock()
	local i = 1
	while i <= #bubbles do
		local b = bubbles[i]
		local p = ctx.roster[b.owner]
		if now >= b.untilT or not p or not p.stats.alive then
			b.label:Destroy()
			table.remove(bubbles, i)
		else
			local W, H = ctx.mapSize()
			-- Just above the territory's centre (where the name plate sits).
			b.label.Position = UDim2.new((p.stats.cx + 0.5) / W, 0, (p.stats.cy + 0.5) / H, -18)
			i += 1
		end
	end
end

-- Setup
function MatchHud.setup(c)
	ctx = c
	gui = c.gui
	buildAttacks(c.stack)
	buildTop()
	buildWin()

	c.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "init" then
			for _, b in bubbles do
				b.label:Destroy()
			end
			table.clear(bubbles)
		end
		if kind == "matchStats" and type(data) == "table" then
			win.matchStats = data -- shown by the win modal's STATS button
		elseif (kind == "phase" and type(data) == "table" and data.phase == "Spawn") or kind == "init" then
			if not (kind == "init" and type(data) == "table" and type(data.phase) == "table" and data.phase.phase == "Ended") then
				win.matchStats = nil -- a new round
			end
		end
		if (kind == "phase" or kind == "init") and type(data) == "table" then
			local ph = if kind == "init" then data.phase else data
			if type(ph) == "table" then
				phaseInfo.phase = ph.phase
				phaseInfo.ticksLeft = ph.ticksLeft or 0
				phaseInfo.at = os.clock()
				phaseInfo.winnerId = ph.winnerId or 0
				phaseInfo.winner = ph.winner
				phaseInfo.winnerTeam = ph.winnerTeam
			end
		elseif kind == "emoji" and type(data) == "table" then
			onEmoji(data)
		end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		stepBubbles()
		acc += dt
		if acc < 0.2 then
			return
		end
		acc = 0
		refreshAttacks()
		refreshTop()
		if toastFrame.Visible then layoutToast() end
		refreshWin()
	end)
end

return MatchHud

