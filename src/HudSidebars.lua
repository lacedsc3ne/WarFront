--[[
	War Front - top-right game sidebar, game timer, immunity timer and the in-game menu.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.HudSidebars (ModuleScript), used by GameClient (via Interact).
-- Mirrors these OpenFront layers (src/client/hud/layers):
--   GameRightSidebar.ts  top-right bar (bg-gray-800/92, rounded-bl-lg): game timer (mm:ss or
--                        hh:mm:ss), settings button, exit button. Timer: spawn-phase countdown,
--                        then a countdown when the match has a time limit (phase.timeLeft) -
--                        red in the last minute, flashing red/white in the last 30 s, the whole
--                        bar flashing red in the last 10 s, "One minute remaining!" red toast -
--                        otherwise the elapsed match time. Exit asks "Are you sure you want to
--                        exit the game?" while alive, then leaves (Net "leave") and shows the menu.
--   ImmunityTimer.ts     7 px orange bar across the top filling up while spawn immunity lasts
--                        (me.immunityEndsIn / phase.spawnImmunity from the shared contract).
--   SettingsModal.ts     the in-game "Menu": Settings (opens the settings page, Settings.lua),
--                        Toggle Terrain (alternate view, MapRender.setAltView), Exit Game.
-- Bars at the top push the sidebars down (SpawnBarVisibleEvent / ImmunityBarVisibleEvent offsets,
-- 7 px each): HudSidebars.topOffset() and DeviceLayout.topOffset.
-- The War Front profile chip / MENU button (MetaClient / MainMenu) also live top-right; while they
-- are visible the bar sits under them.
--
--   ReplayPanel.ts       solo rounds (only player in the server, like OpenFront single player):
--                        fast-forward button -> "Game speed" panel (x0.5 / x1 / x2 / Max) and a
--                        pause / play button (also the P key) - Net "gameSpeed" / "pause".
-- The timer counts game time (phase.elapsed + SimClock), so it follows the speed and pauses.
-- Hidden while a replay is playing (PlayerGui attribute "WFReplay").
--
-- HudSidebars.setup(ctx)  ctx: gui, net, roster, getMyId(), toast(text, color)?
-- HudSidebars.openMenu(), HudSidebars.closeMenu(), HudSidebars.topOffset()

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SimClock = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SimClock"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local MapRender = require(script.Parent:WaitForChild("MapRender"))
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local ClockPanels = require(script.Parent:WaitForChild("ClockPanels")) -- Doomsday Clock / Overtime

local HudSidebars = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(31, 41, 55)
local RED400 = Color3.fromRGB(248, 113, 113)
local RED700 = Color3.fromRGB(185, 28, 28)
local SLATE800 = Color3.fromRGB(30, 41, 59)
local SLATE700 = Color3.fromRGB(51, 65, 85)
local SLATE600 = Color3.fromRGB(71, 85, 105)
local SLATE400 = Color3.fromRGB(148, 163, 184)
local ORANGE = Color3.fromRGB(255, 165, 0)

local LAST_MINUTE_SECONDS = 60
local FLASH_TIMER_SECONDS = 30
local FLASH_SIDEBAR_SECONDS = 10

local ctx: any = nil
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local info = {
	phase = "Lobby",
	ticksLeft = 0,
	at = 0,
	timeLeft = nil :: number?,
	spawnImmunity = nil :: number?,
	playStart = 0,
	elapsed = 0, -- seconds of play at atGame (game clock)
	atGame = 0,
	solo = false,
	paused = false,
	speedChoice = 1,
	immunityEnds = 0, -- os.clock() time
	immunityLen = 0,
	warned = false,
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

local function corner(o: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = o })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextSize = props.TextSize or 16
	return make("TextLabel", props)
end

local function usingGamepad(): boolean
	return DeviceLayout.usingGamepad()
end

-- GameRightSidebar.secondsToHms
local function hms(d: number): string
	d = math.max(0, math.floor(d))
	local h, m, s = d // 3600, (d % 3600) // 60, d % 60
	if h ~= 0 then
		return string.format("%02d:%02d:%02d", h, m, s)
	end
	return string.format("%02d:%02d", m, s)
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local ui: any = {}

local function iconButton(parent: Instance, icon: string, order: number)
	local b = make("TextButton", { Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1, Text = "", LayoutOrder = order, ZIndex = 41, Parent = parent })
	IconKit.image(icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), ZIndex = 42, Parent = b })
	return b
end

local function buildSidebar()
	local gui = ctx.gui
	local bar = make("Frame", {
		Name = "GameRightSidebar",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 40,
		Parent = gui,
	})
	corner(bar, 8) -- rounded-bl-lg
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = bar })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = bar })
	ui.timer = label({ Name = "GameTimer", Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Text = "00:00", LayoutOrder = 1, ZIndex = 41, Parent = bar })
	-- maybeRenderReplayButtons: fast-forward (speed panel) and pause / play, solo rounds only
	ui.speedBtn = iconButton(bar, "FastForward", 2)
	ui.speedBtn.Name = "GameSpeedButton"
	ui.speedBtn.Visible = false
	ui.pauseBtn = iconButton(bar, "Pause", 3)
	ui.pauseBtn.Name = "PauseButton"
	ui.pauseBtn.Visible = false
	ui.pauseIcon = ui.pauseBtn:FindFirstChildWhichIsA("GuiObject")
	ui.boosts = iconButton(bar, "Crown", 4) -- one-use boosts (BoostsPanel), not OpenFront
	ui.boosts.Name = "BoostsButton"
	ui.boosts.Visible = false
	ui.settings = iconButton(bar, "Settings", 5)
	ui.settings.Name = "SettingsButton"
	ui.exit = iconButton(bar, "Exit", 6)
	ui.exit.Name = "ExitButton"
	ui.bar = bar

	-- ReplayPanel: p-2 bg-gray-800/92 rounded-l-lg, "Game speed", 4 buttons (py-0.5 px-1 text-sm
	-- rounded-sm border-gray-500, the chosen one bg-malibu-blue, hover:border-gray-200).
	local panel = make("Frame", {
		Name = "GameSpeedPanel",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 40,
		Parent = gui,
	})
	corner(panel, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = panel })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = panel })
	label({ Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, Text = "Game speed", TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, ZIndex = 41, Parent = panel }) -- replay_panel.game_speed
	local row = make("Frame", { Size = UDim2.fromOffset(4 * 44 + 3 * 8, 24), BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 41, Parent = panel })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = row })
	ui.speedButtons = {}
	for i, opt in { { 0.5, "×0.5" }, { 1, "×1" }, { 2, "×2" }, { 6, "Max" } } do -- replay_panel.fastest_game_speed
		local b = make("TextButton", { Size = UDim2.fromOffset(44, 24), BackgroundColor3 = MenuKit.C.MALIBU, BackgroundTransparency = 1, AutoButtonColor = false, FontFace = FONT, TextSize = 14, TextColor3 = WHITE, Text = opt[2], LayoutOrder = i, ZIndex = 42, Parent = row })
		corner(b, 2)
		local st = make("UIStroke", { Color = Color3.fromRGB(107, 114, 128), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		b.MouseEnter:Connect(function()
			st.Color = Color3.fromRGB(229, 231, 235)
		end)
		b.MouseLeave:Connect(function()
			st.Color = Color3.fromRGB(107, 114, 128)
		end)
		b.SelectionGained:Connect(function()
			st.Color = Color3.fromRGB(229, 231, 235)
		end)
		b.SelectionLost:Connect(function()
			st.Color = Color3.fromRGB(107, 114, 128)
		end)
		b.Activated:Connect(function()
			ctx.net:FireServer("gameSpeed", opt[1])
		end)
		ui.speedButtons[opt[1]] = b
	end
	ui.speedPanel = panel

	-- Doomsday Clock / Overtime panels, stacked under the timer (GameRightSidebar).
	ui.clocks = make("Frame", { Name = "ClockPanels", AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, BackgroundTransparency = 1, ZIndex = 40, Parent = gui })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 4), Parent = ui.clocks })
	ClockPanels.build(ui.clocks)

	-- ImmunityTimer: 7 px, rgba(255,165,0,0.9), full width at the top
	ui.immunity = make("Frame", { Name = "ImmunityTimer", Size = UDim2.new(1, 0, 0, 7), BackgroundTransparency = 1, Visible = false, ZIndex = 45, Parent = gui })
	ui.immunityFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ORANGE, BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 45, Parent = ui.immunity })
end

-- Confirm dialog (InGameModal.showInGameConfirm)
local function buildConfirm()
	local gui = ctx.gui
	local dim = make("TextButton", { Name = "ConfirmDim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, AutoButtonColor = false, Text = "", Selectable = false, Visible = false, ZIndex = 96, Parent = gui })
	-- Same o-modal look as every other window (MenuKit): gray-900 / black-70 panel, rounded-2xl,
	-- white/10 border.
	local card = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.9, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = MenuKit.C.GRAY900, BackgroundTransparency = 0.05, Active = true, Visible = false, ZIndex = 97, Parent = gui })
	corner(card, 16)
	make("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge), Parent = card })
	MenuKit.stroke(card, 0.9)
	make("UIPadding", { PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20), PaddingTop = UDim.new(0, 20), PaddingBottom = UDim.new(0, 20), Parent = card })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 16), Parent = card })
	local text = label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, FontFace = MenuKit.F.BOLD, TextSize = 18, Text = "", LayoutOrder = 1, ZIndex = 98, Parent = card })
	local row = make("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 98, Parent = card })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = row })
	local cancel = MenuKit.button("gray", { Size = UDim2.fromOffset(120, 40), FontFace = MenuKit.F.BOLD, TextSize = 15, Text = "Cancel", LayoutOrder = 1, ZIndex = 99, Parent = row })
	local ok = MenuKit.button("gray", { Size = UDim2.fromOffset(120, 40), FontFace = MenuKit.F.BOLD, TextSize = 15, Text = "Confirm", LayoutOrder = 2, ZIndex = 99, Parent = row })
	MenuKit.hover(ok, function(st)
		ok.BackgroundColor3 = if st == "idle" then RED700 else MenuKit.C.RED600
	end)
	ui.confirm = { dim = dim, card = card, text = text, cancel = cancel, ok = ok, onOk = nil :: any }
	local function close()
		dim.Visible = false
		card.Visible = false
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(card) then
			GuiService.SelectedObject = nil
		end
	end
	ui.confirm.close = close
	dim.Activated:Connect(close)
	cancel.Activated:Connect(close)
	ok.Activated:Connect(function()
		close()
		local f = ui.confirm.onOk
		if f then
			f()
		end
	end)
end

local function confirm(text: string, onOk: () -> ())
	local c = ui.confirm
	c.text.Text = text
	c.onOk = onOk
	c.dim.Visible = true
	c.card.Visible = true
	if usingGamepad() then
		GuiService.SelectedObject = c.cancel
	end
end

local function exitGame()
	ctx.net:FireServer("leave")
	local ev = playerGui:FindFirstChild("FrontlinesMenuShow")
	if ev and ev:IsA("BindableEvent") then
		ev:Fire()
	elseif ctx.exitGame then
		ctx.exitGame()
	end
end

local function onExitClicked()
	local mine = ctx.roster[ctx.getMyId()]
	if mine and mine.stats.alive and (info.phase == "Spawn" or info.phase == "Play") then
		confirm("Are you sure you want to exit the game?", exitGame)
	else
		exitGame()
	end
end

-- In-game menu (SettingsModal.ts) with the settings page inside it.
local function menuRow(parent: Instance, order: number, icon: string, title: string, desc: string, red: boolean?)
	local b = make("TextButton", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = if red then Color3.fromRGB(220, 38, 38) else SLATE700, BackgroundTransparency = 1, AutoButtonColor = false, Text = "", LayoutOrder = order, ZIndex = 93, Parent = parent })
	corner(b, 4)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), Parent = b })
	IconKit.image(icon, { Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(20, 20), ZIndex = 94, Parent = b })
	local col = make("Frame", { Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -80, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, ZIndex = 94, Parent = b })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = col })
	label({ Size = UDim2.new(1, 0, 0, 20), TextSize = 16, TextColor3 = if red then RED400 else WHITE, TextXAlignment = Enum.TextXAlignment.Left, Text = title, LayoutOrder = 1, ZIndex = 94, Parent = col })
	label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 14, TextColor3 = SLATE400, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = desc, LayoutOrder = 2, ZIndex = 94, Parent = col })
	local value = label({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(40, 20), TextSize = 14, TextColor3 = SLATE400, TextXAlignment = Enum.TextXAlignment.Right, Text = "", ZIndex = 94, Parent = b })
	local function lit(on: boolean)
		b.BackgroundTransparency = if on then (if red then 0.8 else 0) else 1
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
	return b, value
end

local altView = false

local function buildMenu()
	local gui = ctx.gui
	local dim = make("TextButton", { Name = "GameMenuDim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, AutoButtonColor = false, Text = "", Selectable = false, Visible = false, ZIndex = 90, Parent = gui })
	local card = make("Frame", { Name = "GameMenu", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -32, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = SLATE800, Active = true, Visible = false, ZIndex = 91, Parent = gui })
	corner(card, 8)
	make("UIStroke", { Color = SLATE600, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = card })
	local sizeC = make("UISizeConstraint", { MaxSize = Vector2.new(448, math.huge), Parent = card })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = card })

	local head = make("Frame", { Size = UDim2.new(1, 0, 0, 60), BackgroundTransparency = 1, LayoutOrder = 1, ZIndex = 92, Parent = card })
	make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = SLATE600, BorderSizePixel = 0, ZIndex = 92, Parent = head })
	local headIcon = IconKit.image("Settings", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 16, 0.5, 0), Size = UDim2.fromOffset(24, 24), ZIndex = 93, Parent = head })
	local title = label({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 48, 0.5, 0), Size = UDim2.new(1, -110, 0, 28), FontFace = FONT_BOLD, TextSize = 20, TextXAlignment = Enum.TextXAlignment.Left, Text = "Menu", ZIndex = 93, Parent = head })
	local close = make("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(36, 36), BackgroundTransparency = 1, FontFace = FONT_BOLD, TextSize = 26, TextColor3 = SLATE400, Text = "×", ZIndex = 93, Parent = head })
	local back = make("TextButton", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(32, 32), BackgroundTransparency = 1, Text = "", Visible = false, ZIndex = 94, Parent = head })
	IconKit.image("Back", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), ZIndex = 95, Parent = back })

	local body = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 92, Parent = card })
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16), Parent = body })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = body })
	local settingsRow = menuRow(body, 1, "Settings", "Settings", "Gameplay, graphics, audio and keybind settings")
	local terrainRow, terrainValue = menuRow(body, 2, "Tree", "Toggle Terrain", "Alternate view (terrain/countries)")
	make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = SLATE600, BorderSizePixel = 0, LayoutOrder = 3, ZIndex = 92, Parent = body })
	local exitRow = menuRow(body, 4, "Exit", "Exit Game", "Return to main menu", true)

	-- Settings page (Settings.lua builds the same rows as the pause menu's settings page)
	local page = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 420),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		Visible = false,
		LayoutOrder = 3,
		ZIndex = 92,
		Parent = card,
	})
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 12), Parent = page })
	local okUI, settingsUI = pcall(Settings.buildUI, page)
	if not okUI then
		warn("[War Front] in-game settings page failed: " .. tostring(settingsUI))
		settingsUI = nil
	end

	local m = { dim = dim, card = card, body = body, page = page, title = title, back = back, headIcon = headIcon, sizeC = sizeC, settingsRow = settingsRow, terrainValue = terrainValue }
	ui.menu = m

	local function showBody()
		page.Visible = false
		body.Visible = true
		back.Visible = false
		headIcon.Visible = true
		title.Position = UDim2.new(0, 48, 0.5, 0)
		title.Text = "Menu"
		sizeC.MaxSize = Vector2.new(448, math.huge)
		terrainValue.Text = if altView then "On" else "Off"
		if usingGamepad() then
			GuiService.SelectedObject = settingsRow
		end
	end
	m.showBody = showBody
	settingsRow.Activated:Connect(function()
		if not settingsUI then
			return
		end
		body.Visible = false
		page.Visible = true
		back.Visible = true
		headIcon.Visible = false
		title.Position = UDim2.new(0, 48, 0.5, 0)
		title.Text = "Settings"
		sizeC.MaxSize = Vector2.new(560, math.huge)
		page.Size = UDim2.new(1, 0, 0, math.min(460, ctx.gui.AbsoluteSize.Y * 0.8 - 70))
		pcall(settingsUI.refresh)
		page.CanvasPosition = Vector2.zero
		if usingGamepad() and settingsUI.first then
			GuiService.SelectedObject = settingsUI.first
		end
	end)
	back.Activated:Connect(showBody)
	terrainRow.Activated:Connect(function()
		altView = not altView
		pcall(MapRender.setAltView, altView)
		terrainValue.Text = if altView then "On" else "Off"
	end)
	exitRow.Activated:Connect(function()
		HudSidebars.closeMenu()
		exitGame()
	end)
	close.Activated:Connect(HudSidebars.closeMenu)
	dim.Activated:Connect(HudSidebars.closeMenu)
end

-- The gear opens the shared in-match menu (PauseMenu: OpenFront modal look, same pages as the
-- main menu). The old slate SettingsModal below is kept only as a fallback.
local function pauseMenu(): any
	local ok, pm = pcall(require, script.Parent:WaitForChild("PauseMenu"))
	return if ok then pm else nil
end

function HudSidebars.openMenu()
	local pm = pauseMenu()
	if pm then
		pm.open()
		return
	end
	local m = ui.menu
	if not m then
		return
	end
	m.dim.Visible = true
	m.card.Visible = true
	m.showBody()
end

function HudSidebars.closeMenu()
	local pm = pauseMenu()
	if pm and pm.isOpen() then
		pm.close()
	end
	local m = ui.menu
	if not m or not m.dim.Visible then
		return
	end
	m.dim.Visible = false
	m.card.Visible = false
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(m.card) then
		GuiService.SelectedObject = nil
	end
end

function HudSidebars.menuOpen(): boolean
	local pm = pauseMenu()
	if pm and pm.isOpen() then
		return true
	end
	return ui.menu ~= nil and ui.menu.dim.Visible
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local function applyPhase(ph)
	if type(ph) ~= "table" then
		return
	end
	local prev = info.phase
	info.phase = ph.phase or info.phase
	info.ticksLeft = ph.ticksLeft or 0
	info.at = os.clock()
	info.timeLeft = if type(ph.timeLeft) == "number" then ph.timeLeft else nil
	info.spawnImmunity = if type(ph.spawnImmunity) == "number" then ph.spawnImmunity else nil
	if info.phase == "Play" and prev ~= "Play" then
		info.playStart = os.clock()
	end
	info.elapsed = if type(ph.elapsed) == "number" then ph.elapsed else 0
	info.atGame = SimClock.now()
	info.solo = ph.solo == true
	info.paused = ph.paused == true
	info.speedChoice = if type(ph.speedChoice) == "number" then ph.speedChoice else 1
	if info.phase ~= "Play" then
		info.warned = false
	end
end

local function applyMe(me)
	if type(me) ~= "table" then
		return
	end
	local left = if type(me.immunityEndsIn) == "number" then me.immunityEndsIn else 0
	if left > 0 then
		info.immunityEnds = os.clock() + left
		info.immunityLen = math.max(info.spawnImmunity or 0, info.immunityLen, left)
	else
		info.immunityEnds = 0
		info.immunityLen = 0
	end
end

local lastOffset = -1

function HudSidebars.topOffset(): number
	return (if info.phase == "Spawn" then 7 else 0) + (if ui.immunity and ui.immunity.Visible then 7 else 0)
end

-- Top of the bar: under the profile chip / MENU button when those are showing top-right.
local function placeBar(offset: number)
	local gui = ctx.gui
	local gp = gui.AbsolutePosition
	local y = offset
	local right = gp.X + gui.AbsoluteSize.X
	for _, path in { { "FrontlinesMeta", "ProfileChip" }, { "FrontlinesMenuButton", "Menu" } } do
		local sg = playerGui:FindFirstChild(path[1])
		local obj = sg and sg:FindFirstChild(path[2])
		if obj and obj:IsA("GuiObject") and obj.Visible and (not sg:IsA("ScreenGui") or sg.Enabled) then
			local a, s = obj.AbsolutePosition, obj.AbsoluteSize
			if a.X + s.X > right - 420 and s.Y > 0 then
				y = math.max(y, a.Y + s.Y - gp.Y + 6)
			end
		end
	end
	ui.bar.Position = UDim2.new(1, 0, 0, y)
end

local function step()
	local now = os.clock()
	local ph = info.phase
	local inGame = (ph == "Spawn" or ph == "Play" or ph == "Ended") and playerGui:GetAttribute("WFReplay") ~= true
	ui.bar.Visible = inGame
	-- Speed / pause controls (solo rounds)
	local solo = inGame and info.solo and ph ~= "Ended"
	ui.speedBtn.Visible = solo
	ui.pauseBtn.Visible = solo
	if not solo then
		ui.speedPanel.Visible = false
	end
	if ui.pauseIcon then
		IconKit.set(ui.pauseIcon, if info.paused then "Play" else "Pause")
	end
	for v, b in ui.speedButtons do
		b.BackgroundTransparency = if v == info.speedChoice then 0 else 1
	end
	-- Immunity bar
	local immune = ph == "Play" and info.immunityEnds > now and info.immunityLen > 0
	ui.immunity.Visible = immune
	if immune then
		local frac = 1 - (info.immunityEnds - now) / info.immunityLen
		ui.immunityFill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	end
	local offset = HudSidebars.topOffset()
	if offset ~= lastOffset then
		lastOffset = offset
		DeviceLayout.topOffset = offset
		DeviceLayout.relayout()
	end
	ui.clocks.Visible = inGame
	if not inGame then
		return
	end
	placeBar(offset)
	local below = ui.bar.Position.Y.Offset + ui.bar.AbsoluteSize.Y
	if ui.speedPanel.Visible then
		ui.speedPanel.Position = UDim2.new(1, 0, 0, below)
		below += ui.speedPanel.AbsoluteSize.Y
	end
	local boosts = ui.boostsPanel
	if boosts and boosts.Visible then
		-- Boosts strip (BoostsPanel) right under the bar / speed panel.
		boosts.Position = UDim2.new(1, 0, 0, below + 4)
		DeviceLayout.setScale(boosts, (if DeviceLayout.state.profile == "console" then DeviceLayout.state.scale else 1) * DeviceLayout.userScale)
		below += boosts.AbsoluteSize.Y + 4
	end
	ClockPanels.update(ctx)
	ui.clocks.Position = UDim2.new(1, 0, 0, below + 4)
	DeviceLayout.setScale(ui.clocks, (if DeviceLayout.state.profile == "console" then DeviceLayout.state.scale else 1) * DeviceLayout.userScale)
	DeviceLayout.setScale(ui.bar, (if DeviceLayout.state.profile == "console" then DeviceLayout.state.scale else 1) * DeviceLayout.userScale)

	-- Timer
	local timer, endTimer = 0, false
	local gameDt = SimClock.now() - info.atGame -- game seconds since the last phase update
	if ph == "Spawn" then
		timer = math.ceil(info.ticksLeft * Config.TICK - gameDt)
	elseif ph == "Play" then
		if info.timeLeft then
			timer = math.ceil(info.timeLeft - gameDt)
			endTimer = timer > 0
		else
			timer = info.elapsed + gameDt
		end
	else
		timer = ui.lastTimer or 0 -- hasWinner: the timer stops
	end
	timer = math.max(0, timer)
	if ph ~= "Ended" then
		ui.lastTimer = timer
	end
	ui.timer.Text = hms(timer)
	local reduced = Settings.values and Settings.values.reducedMotion
	local flashT = endTimer and timer <= FLASH_TIMER_SECONDS
	local lastMin = endTimer and timer <= LAST_MINUTE_SECONDS
	local wave = 0.5 + 0.5 * math.cos(now * 2 * math.pi) -- 1 s ease-in-out cycle
	if flashT and not reduced then
		ui.timer.TextColor3 = RED400:Lerp(WHITE, 1 - wave)
	elseif lastMin and not flashT then
		ui.timer.TextColor3 = RED400
	else
		ui.timer.TextColor3 = WHITE
	end
	if endTimer and timer <= FLASH_SIDEBAR_SECONDS then
		if reduced then
			ui.bar.BackgroundColor3, ui.bar.BackgroundTransparency = RED700, 0.04
		else
			ui.bar.BackgroundColor3 = Color3.new(0, 0, 0):Lerp(RED700, 1 - wave)
			ui.bar.BackgroundTransparency = 0.06
		end
	else
		ui.bar.BackgroundColor3, ui.bar.BackgroundTransparency = GRAY800, 0.08
	end
	if lastMin and not info.warned and ph == "Play" then
		info.warned = true
		if ctx.toast then
			ctx.toast("One minute remaining!", "red", 4)
		end
	end
end

-- keybinds.pauseGame (P): TogglePauseIntentEvent, single player only (Keybinds.lua calls this).
local function canControlSpeed(): boolean
	return ctx ~= nil and info.solo and playerGui:GetAttribute("WFReplay") ~= true and (info.phase == "Spawn" or info.phase == "Play")
end

function HudSidebars.togglePause()
	if canControlSpeed() then
		ctx.net:FireServer("pause", not info.paused)
	end
end

-- keybinds.gameSpeedUp / gameSpeedDown (. / ,): next / previous of x0.5, x1, x2, Max.
function HudSidebars.stepSpeed(dir: number)
	if not canControlSpeed() then
		return
	end
	local steps = { 0.5, 1, 2, 6 }
	local i = table.find(steps, info.speedChoice) or 2
	local n = math.clamp(i + dir, 1, #steps)
	if n ~= i then
		ctx.net:FireServer("gameSpeed", steps[n])
	end
end

function HudSidebars.setup(c)
	ctx = c
	buildSidebar()
	buildConfirm()
	buildMenu()
	local okBoosts, err = pcall(function()
		ui.boostsPanel = require(script.Parent:WaitForChild("BoostsPanel")).setup({ button = ui.boosts, gui = c.gui, net = c.net })
	end)
	if not okBoosts then
		warn("[War Front] BoostsPanel failed: " .. tostring(err))
	end
	ui.settings.Activated:Connect(HudSidebars.openMenu)
	ui.speedBtn.Activated:Connect(function() -- toggleReplayPanel
		ui.speedPanel.Visible = not ui.speedPanel.Visible
		step()
	end)
	ui.pauseBtn.Activated:Connect(function() -- onPauseButtonClick
		c.net:FireServer("pause", not info.paused)
	end)
	ui.exit.Activated:Connect(onExitClicked)
	c.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "init" and type(data) == "table" then
			applyPhase(data.phase)
			info.immunityEnds, info.immunityLen, info.warned = 0, 0, false
			HudSidebars.closeMenu()
		elseif kind == "phase" then
			applyPhase(data)
		elseif kind == "me" then
			applyMe(data)
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		local k = input.KeyCode
		if k ~= Enum.KeyCode.Escape and k ~= Enum.KeyCode.ButtonB then
			return
		end
		if ui.confirm.dim.Visible then
			ui.confirm.close()
		elseif HudSidebars.menuOpen() then
			if ui.menu.page.Visible then
				ui.menu.showBody()
			else
				HudSidebars.closeMenu()
			end
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.05 then
			return
		end
		acc = 0
		step()
	end)
end

return HudSidebars
