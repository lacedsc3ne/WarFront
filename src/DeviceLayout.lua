--[[
	Frontlines (working title) - device / input detection and per-device HUD layout.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.DeviceLayout (ModuleScript), used by GameClient and MetaClient.
-- DeviceLayout.state (live, shared by every client script):
--   input   "KeyboardMouse" | "Touch" | "Gamepad"   (last input actually used)
--   size    "Phone" | "Tablet" | "Desktop"           (from the screen size)
--   tv      GuiService:IsTenFootInterface()
--   profile "phone" | "tablet" | "console" | "desktop" (what the layouts switch on)
--   scale   UIScale factor for 10-foot UI (1 elsewhere)
--   screen  full screen size in points
-- DeviceLayout.Changed fires (with state) whenever any of these change.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local DeviceLayout = {}

local changedEvent = Instance.new("BindableEvent")
DeviceLayout.Changed = changedEvent.Event

-- Compact profile chip size on phones (MetaClient draws it, GameClient lays out around it).
DeviceLayout.PHONE_CHIP_WIDTH = 236
DeviceLayout.PHONE_CHIP_HEIGHT = 50

local state = {
	input = "KeyboardMouse",
	size = "Desktop",
	tv = false,
	touch = false,
	gamepad = false,
	profile = "desktop",
	scale = 1,
	screen = Vector2.new(1280, 720),
}
DeviceLayout.state = state

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Gamepad selection highlight for every button: OpenFront's focus ring (ring in
-- --default-ring-color = malibu blue, with a ring-offset gap so it also shows on blue buttons).
-- Roblox draws only the SelectionImageObject itself (not its child frames), so the ring is the
-- frame's own UIStroke. Objects with their own SelectionImageObject (the radial menu) keep theirs.
do
	local ring = Instance.new("Frame")
	ring.Name = "WarFrontSelection"
	ring.BackgroundTransparency = 1
	ring.Size = UDim2.new(1, 8, 1, 8) -- ring-offset: 4 px gap around the button
	ring.Position = UDim2.fromOffset(-4, -4)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = ring
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(0, 132, 209) -- --color-malibu-blue
	st.Thickness = 3
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = ring
	playerGui.SelectionImageObject = ring
end

-- An empty full-screen ScreenGui used to measure the real screen rect, whatever insets the
-- visible ScreenGuis use.
local probe = Instance.new("ScreenGui")
probe.Name = "FrontlinesProbe"
probe.IgnoreGuiInset = true
probe.ResetOnSpawn = false
pcall(function()
	probe.ScreenInsets = Enum.ScreenInsets.None
end)
probe.Parent = playerGui
DeviceLayout.probe = probe

local KBM_TYPES = {
	[Enum.UserInputType.Keyboard] = true,
	[Enum.UserInputType.MouseMovement] = true,
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
	[Enum.UserInputType.MouseWheel] = true,
	[Enum.UserInputType.TextInput] = true,
}

local function inputKind(t: Enum.UserInputType): string?
	if t == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.sub(t.Name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif KBM_TYPES[t] then
		return "KeyboardMouse"
	end
	return nil
end

local function screenSize(): Vector2
	local s = probe.AbsoluteSize
	if s.X < 2 or s.Y < 2 then
		local cam = workspace.CurrentCamera
		if cam then
			s = cam.ViewportSize
		end
	end
	return s
end

local function recompute(force: boolean?)
	local s = screenSize()
	local tv = GuiService:IsTenFootInterface()
	local touch = UserInputService.TouchEnabled
	local short = math.min(s.X, s.Y)

	local size
	if short < 500 or s.X < 700 then
		size = "Phone"
	elseif touch and not UserInputService.MouseEnabled and short < 1100 then
		size = "Tablet"
	else
		size = "Desktop"
	end

	local profile
	if tv then
		profile = "console"
	elseif size == "Phone" then
		profile = "phone"
	elseif size == "Tablet" then
		profile = "tablet"
	else
		profile = "desktop"
	end
	local scale = if profile == "console" then math.clamp(s.Y / 800, 1.15, 1.5) else 1

	local changed = force
		or state.size ~= size
		or state.tv ~= tv
		or state.touch ~= touch
		or state.profile ~= profile
		or math.abs(state.scale - scale) > 0.01
		or (state.screen - s).Magnitude > 0.5
	state.size, state.tv, state.touch, state.profile, state.scale, state.screen = size, tv, touch, profile, scale, s
	state.gamepad = UserInputService.GamepadEnabled
	if changed then
		changedEvent:Fire(state)
	end
end

local function setInput(kind: string?)
	if kind and kind ~= state.input then
		state.input = kind
		changedEvent:Fire(state)
	end
end

do
	local initial = inputKind(UserInputService:GetLastInputType())
	if not initial then
		if GuiService:IsTenFootInterface() then
			initial = "Gamepad"
		elseif UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			initial = "Touch"
		else
			initial = "KeyboardMouse"
		end
	end
	state.input = initial
	recompute(false)
end

UserInputService.LastInputTypeChanged:Connect(function(t)
	setInput(inputKind(t))
end)
UserInputService.GamepadConnected:Connect(function()
	recompute(true)
end)
UserInputService.GamepadDisconnected:Connect(function()
	recompute(true)
end)
probe:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	recompute(false)
end)

-- Helpers
function DeviceLayout.usingGamepad(): boolean
	return state.input == "Gamepad"
end

-- First words of "<verb> the map / your land ..." prompts.
function DeviceLayout.verb(): string
	if state.input == "Gamepad" then
		return "Press A on"
	elseif state.input == "Touch" then
		return "Tap"
	end
	return "Click"
end

function DeviceLayout.cancelHint(): string
	if state.input == "Gamepad" then
		return "(B to cancel)"
	elseif state.input == "Touch" then
		return "(tap the button again to cancel)"
	end
	return "(right-click / Esc to cancel)"
end

-- One reusable UIScale per GuiObject.
function DeviceLayout.scaleOf(obj: Instance): UIScale
	local s = obj:FindFirstChild("DeviceScale")
	if not s then
		s = Instance.new("UIScale")
		s.Name = "DeviceScale"
		s.Parent = obj
	end
	return s :: UIScale
end

function DeviceLayout.setScale(obj: Instance, v: number)
	DeviceLayout.scaleOf(obj).Scale = v
end

local function textMax(obj: Instance, max: number, min: number?)
	local c = obj:FindFirstChild("DeviceTextSize") :: UITextSizeConstraint?
	if not c then
		local n = Instance.new("UITextSizeConstraint")
		n.Name = "DeviceTextSize"
		n.Parent = obj
		c = n
	end
	(c :: UITextSizeConstraint).MaxTextSize = max;
	(c :: UITextSizeConstraint).MinTextSize = min or 1
end
DeviceLayout.textMax = textMax

-- Insets of a ScreenGui relative to the full screen (left, top, right, bottom).
function DeviceLayout.insets(gui: ScreenGui): (number, number, number, number)
	local fp, fs = probe.AbsolutePosition, probe.AbsoluteSize
	local gp, gs = gui.AbsolutePosition, gui.AbsoluteSize
	if fs.X < 2 or gs.X < 2 then
		return 0, 0, 0, 0
	end
	local l = math.max(0, gp.X - fp.X)
	local t = math.max(0, gp.Y - fp.Y)
	local r = math.max(0, (fp.X + fs.X) - (gp.X + gs.X))
	local b = math.max(0, (fp.Y + fs.Y) - (gp.Y + gs.Y))
	return l, t, r, b
end

-- Keeps a ScreenGui's ScreenInsets in sync with the device: phones/tablets avoid notches
-- (DeviceSafeInsets), TVs keep to the TV-safe area (CoreUISafeInsets), desktop is untouched.
function DeviceLayout.attachScreenGui(gui: ScreenGui)
	local origIgnore = gui.IgnoreGuiInset
	local origInsets = gui.ScreenInsets
	local function apply()
		pcall(function()
			if state.profile == "console" then
				gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
			elseif state.profile == "phone" or state.profile == "tablet" then
				gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
			else
				gui.IgnoreGuiInset = origIgnore
				gui.ScreenInsets = origInsets
			end
		end)
	end
	apply()
	DeviceLayout.Changed:Connect(apply)
end

-- In-match HUD layout (GameClient's FrontlinesUI)
local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local PANEL = Color3.fromRGB(10, 22, 40)

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

local function place(obj: GuiObject, anchor: Vector2, pos: UDim2, size: UDim2)
	obj.AnchorPoint = anchor
	obj.Position = pos
	obj.Size = size
end

local boardOpen = false -- phone: leaderboard table shown (collapsed by default)
local boardOpenWide = true -- other devices (expanded by default)
local matchRefs = nil
local queued = false
local layoutMatch
local alertsHeight = 0 -- phone: last laid-out height of the alerts panel (the stack sits above it)

local function queueLayout()
	if queued then
		return
	end
	queued = true
	task.defer(function()
		queued = false
		if matchRefs then
			layoutMatch()
		end
	end)
end
DeviceLayout.relayout = queueLayout

-- Closes the phone leaderboard if it's open. Returns true if something was closed.
function DeviceLayout.closePopups(): boolean
	if matchRefs and state.profile == "phone" and boardOpen then
		boardOpen = false
		queueLayout()
		return true
	end
	return false
end

-- The leaderboard header's stats button collapses / expands the table (per device class).
function DeviceLayout.toggleBoard()
	if state.profile == "phone" then
		boardOpen = not boardOpen
	else
		boardOpenWide = not boardOpenWide
	end
	queueLayout()
end

-- Player settings (Settings.lua): interface size multiplier for the match HUD, and whether the
-- leaderboard table starts expanded (phones always start collapsed).
DeviceLayout.userScale = 1
function DeviceLayout.setUserScale(v: number)
	DeviceLayout.userScale = math.clamp(v, 0.5, 2)
	queueLayout()
end

function DeviceLayout.setBoardDefault(open: boolean)
	boardOpenWide = open
	if not open then
		boardOpen = false
	end
	queueLayout()
end

local PAD_HELP = table.concat({
	"<b>A</b>  Attack / place",
	"<b>X</b>  Player menu",
	"<b>B</b>  Cancel",
	"<b>Y</b>  Build bar",
	"<b>LB / RB</b>  Attack ratio",
	"<b>LT / RT</b>  Zoom",
	"<b>R stick</b>  Pan map",
	"<b>R3</b>  Fit map",
	"<b>View</b>  Pause menu",
}, "\n")

-- Lays out the inside of the bottom control panel (OpenFront ControlPanel.ts + UnitDisplay.ts)
-- for width w; returns the panel height. `mobile` = OpenFront's < lg layout.
--   desktop: [notification] / troop rate (5.5rem) | troop bar | gold / ratio box (8rem) | slider /
--            unit display (border-t white/10, one row of small boxes)
--   mobile:  [notification] / gold (1/5) | troop bar (40%) | sword + ratio | slider
--            (the unit display only shows on mobile while a gamepad is used)
DeviceLayout.panelCompact = false
DeviceLayout.topOffset = 0 -- spawn / immunity bars at the very top (HudSidebars)

-- Roblox's top-bar buttons (menu, chat, voice) own the top-left corner, so the leaderboard
-- starts just below them.
local function boardTop(): number
	local topbar = game:GetService("GuiService").TopbarInset
	return DeviceLayout.topOffset + (if topbar.Height > 0 then topbar.Max.Y + 4 else 0)
end
local function layoutPanel(r, w: number, mobile: boolean): number
	DeviceLayout.panelCompact = mobile
	local px, py = 8, 4
	local y = py
	if r.notice and r.notice.Visible then
		place(r.notice, Vector2.zero, UDim2.fromOffset(px, y), UDim2.new(1, -2 * px, 0, 22))
		y += 26
	end
	local ratioStroke = r.ratioBox and r.ratioBox:FindFirstChildOfClass("UIStroke")
	local sword = r.ratioBox and r.ratioBox:FindFirstChildWhichIsA("ImageLabel")
	if not mobile then
		local h1, growW, goldW, gap = 26, 88, 96, 6
		place(r.growthPill, Vector2.zero, UDim2.fromOffset(px, y), UDim2.fromOffset(growW, h1))
		place(r.goldPill, Vector2.new(1, 0), UDim2.new(1, -px, 0, y), UDim2.fromOffset(goldW, h1))
		place(r.troopBox, Vector2.zero, UDim2.fromOffset(px + growW + gap, y), UDim2.new(1, -(2 * px + growW + goldW + 2 * gap), 0, h1))
		r.growthPill.Visible = true
		y += h1 + 4
		local h2, ratioW = 24, 128
		local hintW = if r.hudHint.Visible then 92 else 0
		place(r.ratioBox, Vector2.zero, UDim2.fromOffset(px, y), UDim2.fromOffset(ratioW, h2))
		place(r.slider, Vector2.zero, UDim2.fromOffset(px + ratioW + gap, y), UDim2.new(1, -(2 * px + ratioW + gap + hintW), 0, h2))
		place(r.hudHint, Vector2.new(1, 0), UDim2.new(1, -px, 0, y), UDim2.fromOffset(math.max(0, hintW - 6), h2))
		r.ratioText.TextSize = 14
		r.ratioText.TextWrapped = false
		r.ratioText.Position = UDim2.fromOffset(21, 0)
		r.ratioText.Size = UDim2.new(1, -23, 1, 0)
		if ratioStroke then
			ratioStroke.Enabled = true
		end
		if sword then
			sword.Size = UDim2.fromOffset(12, 12)
		end
		y += h2 + py
	else
		local h, gap = 28, 8
		local inner = w - 2 * px
		local goldW = math.floor(inner * 0.2)
		local troopW = math.floor(inner * 0.4)
		local ratioW = 66
		local hintW = if r.hudHint.Visible then 80 else 0
		r.growthPill.Visible = false
		place(r.goldPill, Vector2.zero, UDim2.fromOffset(px, y + 2), UDim2.fromOffset(goldW, h - 4))
		place(r.troopBox, Vector2.zero, UDim2.fromOffset(px + goldW + gap, y + 2), UDim2.fromOffset(troopW, h - 4))
		place(r.ratioBox, Vector2.zero, UDim2.fromOffset(px + goldW + troopW + 2 * gap, y), UDim2.fromOffset(ratioW, h))
		local sx = px + goldW + troopW + ratioW + 3 * gap
		place(r.slider, Vector2.zero, UDim2.fromOffset(sx, y), UDim2.new(1, -(sx + px + hintW), 0, h))
		place(r.hudHint, Vector2.new(1, 0), UDim2.new(1, -px, 0, y), UDim2.fromOffset(math.max(0, hintW - 6), h))
		r.ratioText.TextSize = 11
		r.ratioText.TextWrapped = true
		r.ratioText.Position = UDim2.fromOffset(13, 0)
		r.ratioText.Size = UDim2.new(1, -13, 1, 0)
		if ratioStroke then
			ratioStroke.Enabled = false
		end
		if sword then
			sword.Size = UDim2.fromOffset(10, 10)
		end
		y += h + py
	end
	r.hudHint.TextSize = 11
	for _, t in r.panelTexts do
		t.TextSize = if mobile then 12 else 14
	end
	r.panelTexts[2].TextSize = if mobile then 12 else 18 -- troop count (text-lg on desktop)

	-- Unit display
	local showUnits = (not mobile) or state.input == "Gamepad"
	r.buildBar.Visible = showUnits
	if r.unitSep then
		r.unitSep.Visible = showUnits
	end
	if showUnits then
		local n = #r.actionButtons
		local bw, bh, bgap = 50, 28, 2
		local perRow = math.max(1, math.floor((w - 4 + bgap) / (bw + bgap)))
		local rows = math.max(1, math.ceil(n / perRow))
		local rowH = rows * bh + (rows - 1) * bgap
		if r.unitSep then
			place(r.unitSep, Vector2.zero, UDim2.fromOffset(0, y), UDim2.new(1, 0, 0, 1))
		end
		place(r.buildBar, Vector2.zero, UDim2.fromOffset(2, y + 2), UDim2.new(1, -4, 0, rowH))
		local list = r.buildBar:FindFirstChildOfClass("UIListLayout")
		if list then
			list.Padding = UDim.new(0, bgap)
			pcall(function()
				list.Wraps = rows > 1
			end)
		end
		y += 2 + rowH + 2
	end
	r.hud.Size = UDim2.fromOffset(w, y)
	return y
end

function layoutMatch()
	local r = matchRefs
	local gui: ScreenGui = r.gui
	local X, Y = gui.AbsoluteSize.X, gui.AbsoluteSize.Y
	if X < 2 or Y < 2 then
		return
	end
	local p = state.profile
	local pad = state.input == "Gamepad"
	local phone = p == "phone"
	local us = DeviceLayout.userScale
	local s = (if p == "console" then state.scale else 1) * us

	-- Map backdrop always covers the whole screen, even outside the safe area.
	local il, it, ir, ib = DeviceLayout.insets(gui)
	r.backdrop.Position = UDim2.fromOffset(-il, -it)
	r.backdrop.Size = UDim2.new(1, il + ir, 1, it + ib)

	r.hudHint.Visible = pad
	r.padHelp.Visible = pad and not phone
	r.zoomIn.Visible = not pad
	r.zoomOut.Visible = not pad
	r.setBoardOpen(if phone then boardOpen else boardOpenWide)

	if phone then
		local m = 6
		local chipW, chipH = DeviceLayout.PHONE_CHIP_WIDTH, DeviceLayout.PHONE_CHIP_HEIGHT
		local boardS = 0.85 * us
		local headW, headH = 40 * boardS, 32 * boardS

		-- Top row: leaderboard (GameLeftSidebar, flush top-left) | banner | profile chip (top-right)
		if r.setBoardDensity then
			r.setBoardDensity(24, 12)
		end
		place(r.board, Vector2.zero, UDim2.fromOffset(0, boardTop()), r.board.Size)
		DeviceLayout.setScale(r.board, boardS)
		local bannerX = m + headW + 8
		local bannerW = X - bannerX - (chipW + m + 8)
		local feedY = m + math.max(chipH, headH) + 8
		if bannerW >= 150 then
			place(r.banner, Vector2.new(0, 0), UDim2.fromOffset(bannerX, m + 2), UDim2.fromOffset(math.min(bannerW, 420), 28))
		else
			-- Very narrow (portrait): banner goes on its own row under the chip.
			place(r.banner, Vector2.new(0, 0), UDim2.fromOffset(m, m + chipH + 4), UDim2.new(1, -2 * m, 0, 26))
			feedY += 32
		end
		DeviceLayout.setScale(r.banner, 1)
		r.bannerText.TextScaled = true
		textMax(r.bannerText, 14, 9)

		-- Bottom: credits strip, control panel, attack line + tutorial
		local creditsH = 22
		place(r.credits, Vector2.new(0, 1), UDim2.new(0, 8, 1, -2), UDim2.new(1, -16, 0, creditsH))
		DeviceLayout.setScale(r.credits, 1)
		r.credits.Text = r.creditsShort
		r.credits.TextScaled = true
		textMax(r.credits, 10, 6)

		local hudBottom = 2 + creditsH + 4
		local hudW = math.min((X - 2 * m) / us, 460)
		local hudH = layoutPanel(r, hudW, true)
		place(r.hud, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -hudBottom), r.hud.Size)
		DeviceLayout.setScale(r.hud, us)

		-- Alerts panel (events + alliance requests) right above the control panel, as wide as it,
		-- with the attack line / tutorial stacked above the alerts (OpenFront's mobile order).
		local alertsBottom = hudBottom + hudH * us + 4
		if r.alerts then
			r.alerts.setCompact(true)
		end
		place(r.feedFrame, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -alertsBottom), UDim2.fromOffset(hudW, 0))
		DeviceLayout.setScale(r.feedFrame, us)
		r.feedFrame.ClipsDescendants = false
		local alertsH = r.feedFrame.AbsoluteSize.Y
		alertsHeight = alertsH
		local stackBottom = alertsBottom + (if alertsH > 1 then alertsH + 4 else 0)
		place(r.stack, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -stackBottom), UDim2.fromOffset(hudW, 300))
		DeviceLayout.setScale(r.stack, us)
		r.attacksText.TextSize = 11
		r.attacksText.Size = UDim2.new(1, 0, 0, 16)

		-- Zoom buttons on the right edge, vertically centred.
		place(r.zoomIn, Vector2.new(1, 1), UDim2.new(1, -m, 0.5, -4), UDim2.fromOffset(44, 44))
		place(r.zoomOut, Vector2.new(1, 0), UDim2.new(1, -m, 0.5, 4), UDim2.fromOffset(44, 44))
		DeviceLayout.setScale(r.zoomIn, 1)
		DeviceLayout.setScale(r.zoomOut, 1)

		r.barHint.Visible = false
		DeviceLayout.setScale(r.tooltip, 0.85)
		DeviceLayout.setScale(r.buildTip, 0.9)
		DeviceLayout.setScale(r.overlay, 0.75)
		return
	end

	-- Desktop / tablet / console (console: everything scaled by `s`).
	local m = 12
	-- Banner centred at the top, between the leaderboard (left) and the profile chip (right);
	-- on narrow screens it drops under the chip instead.
	local boardRight = m + (r.boardWidth or 340) * s + 8
	local centreW = math.min(420, (X / 2 - boardRight) * 2 / s)
	local feedY = m + 92 * s + 12
	if centreW >= 240 then
		place(r.banner, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, m), UDim2.fromOffset(centreW, 30))
	else
		local w = math.clamp((X - boardRight - m) / s, 160, 420)
		place(r.banner, Vector2.new(1, 0), UDim2.new(1, -m, 0, feedY - 4), UDim2.fromOffset(w, 30))
		feedY += 38 * s
	end
	DeviceLayout.setScale(r.banner, s)
	r.bannerText.TextScaled = p ~= "desktop"
	textMax(r.bannerText, 15, 10)

	-- Leaderboard: GameLeftSidebar, flush in the top-left corner under the spawn / immunity bars;
	-- StatsTable rows h-6 / md:h-8 / lg:h-9, text-xs / lg:text-sm.
	if r.setBoardDensity then
		if X >= 1024 then
			r.setBoardDensity(36, 14)
		elseif X >= 768 then
			r.setBoardDensity(32, 12)
		else
			r.setBoardDensity(24, 12)
		end
	end
	place(r.board, Vector2.zero, UDim2.fromOffset(0, boardTop()), r.board.Size)
	DeviceLayout.setScale(r.board, s)

	local credW = if p == "tablet" then 200 else 300
	place(r.credits, Vector2.new(0, 1), UDim2.new(0, 10, 1, -6), UDim2.fromOffset(credW, if p == "tablet" then 72 else 60))
	DeviceLayout.setScale(r.credits, s)
	r.credits.Text = r.creditsFull
	r.credits.TextScaled = false
	r.credits.TextSize = if p == "tablet" then 10 else 11

	local hudW = 500
	if p == "tablet" then
		hudW = math.clamp(X - 2 * (credW + 20), 400, 500)
	end
	local hudH = layoutPanel(r, hudW, X < 1024)
	-- index.html bottom HUD: flush with the bottom edge (rounded top corners)
	place(r.hud, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, 0), r.hud.Size)
	DeviceLayout.setScale(r.hud, s)

	place(r.stack, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -((hudH + 4) * s)), UDim2.fromOffset(hudW, 320))
	DeviceLayout.setScale(r.stack, s)
	r.attacksText.TextSize = 14
	r.attacksText.Size = UDim2.new(1, 0, 0, 20)

	-- Controller prompt to the right of the control panel (hidden if it would leave the screen).
	local hintW = 130
	r.barHint.Visible = pad and (X / 2 + (hudW / 2 + 10 + hintW) * s) <= X - m
	place(r.barHint, Vector2.new(0, 1), UDim2.new(0.5, (hudW / 2 + 10) * s, 1, -m), UDim2.fromOffset(hintW, 40))
	DeviceLayout.setScale(r.barHint, s)

	place(r.zoomOut, Vector2.new(1, 1), UDim2.new(1, -12, 1, -18), UDim2.fromOffset(44, 44))
	place(r.zoomIn, Vector2.new(1, 1), UDim2.new(1, -12, 1, -(18 + 52 * s)), UDim2.fromOffset(44, 44))
	DeviceLayout.setScale(r.zoomIn, s)
	DeviceLayout.setScale(r.zoomOut, s)

	place(r.padHelp, Vector2.new(1, 1), UDim2.new(1, -m, 1, -m), UDim2.fromOffset(190, 158))
	DeviceLayout.setScale(r.padHelp, s)

	-- Alerts panel (events + alliance requests), bottom-right like OpenFront: beside the control
	-- panel when there's room, otherwise stacked above the zoom buttons / controller help.
	if r.alerts then
		r.alerts.setCompact(false)
	end
	local alertsW = if X >= 1200 then 384 else 340
	local hudRight = X / 2 + (hudW / 2 + 10) * s
	local cornerW = if pad then 0 else (44 + 8) * s -- zoom buttons
	local alertsRight, alertsBottom
	if pad then
		alertsRight, alertsBottom = m, m + 158 * s + 8 -- above the controller help
	elseif X - m - cornerW - alertsW * s >= hudRight then
		alertsRight, alertsBottom = m + cornerW, m
	else
		alertsRight, alertsBottom = m, 18 + (52 + 44) * s + 8 -- above the zoom buttons
	end
	alertsW = math.min(alertsW, (X - 2 * m) / s)
	place(r.feedFrame, Vector2.new(1, 1), UDim2.new(1, -alertsRight, 1, -alertsBottom), UDim2.fromOffset(alertsW, 0))
	DeviceLayout.setScale(r.feedFrame, s)
	r.feedFrame.ClipsDescendants = false

	DeviceLayout.setScale(r.tooltip, s)
	DeviceLayout.setScale(r.buildTip, s)
	DeviceLayout.setScale(r.overlay, s)

	-- While a replay plays, its 44 px control bar takes the bottom edge: lift the corner widgets.
	if playerGui:GetAttribute("WFReplay") == true then
		for _, o in { r.zoomIn, r.zoomOut, r.feedFrame, r.padHelp } do
			o.Position -= UDim2.fromOffset(0, 48)
		end
	end
end

-- refs: gui, backdrop, banner, bannerText, board, boardWidth, setBoardOpen(open), feedFrame (the alerts
-- panel frame), alerts (AlertsPanel module: setCompact), hud (control
-- panel), growthPill, troopBox, goldPill, panelTexts, ratioText, slider, buildBar (button row),
-- actionButtons, stack (attack line + tutorial), attacksText, buildTip, zoomIn, zoomOut,
-- credits (TextLabel), creditsFull, creditsShort, tooltip, overlay.
function DeviceLayout.bindMatchUI(refs)
	local gui = refs.gui

	refs.hudHint = make("TextLabel", {
		Name = "PadHint",
		BackgroundTransparency = 1,
		FontFace = FONT_BOLD,
		TextColor3 = Color3.fromRGB(200, 210, 235),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "LB / RB  ratio",
		Visible = false,
		Parent = refs.hud,
	})

	refs.barHint = make("TextLabel", {
		Name = "BuildBarPadHint",
		BackgroundTransparency = 1,
		FontFace = FONT,
		RichText = true,
		TextColor3 = Color3.fromRGB(220, 226, 240),
		TextStrokeTransparency = 0.4,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Text = "<b>Y</b>  build bar\n<b>D-pad</b>  cycle",
		Visible = false,
		Parent = gui,
	})

	refs.padHelp = make("Frame", {
		Name = "PadHelp",
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 8), Parent = refs.padHelp })
	make("TextLabel", {
		Position = UDim2.fromOffset(10, 6),
		Size = UDim2.new(1, -20, 1, -12),
		BackgroundTransparency = 1,
		FontFace = FONT,
		RichText = true,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 13,
		LineHeight = 1.05,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = PAD_HELP,
		Parent = refs.padHelp,
	})

	matchRefs = refs
	-- Phones stack the attack line above the alerts panel, so follow its height.
	refs.feedFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if state.profile == "phone" and math.abs(refs.feedFrame.AbsoluteSize.Y - alertsHeight) > 1 then
			queueLayout()
		end
	end)
	DeviceLayout.attachScreenGui(gui)
	DeviceLayout.Changed:Connect(queueLayout)
	playerGui:GetAttributeChangedSignal("WFReplay"):Connect(queueLayout)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)
	gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueLayout)
	probe:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueLayout)
	layoutMatch()
end

return DeviceLayout
