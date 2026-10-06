--[[
	Frontlines (working title) - gamepad controls: virtual cursor, map pan/zoom, button actions.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.GamepadControls (ModuleScript), used by GameClient.
--
-- There is no character in a match, so the controller drives our own UI:
--   left stick   virtual cursor          right stick  pan the map
--   LT / RT      zoom out / in at cursor A            act(tile under cursor)
--   B            leave build bar / cancel mode / close popups
--   X            openContextMenuAt(cursor)            Y  focus / leave the build bar
--   LB / RB      attack ratio -10% / +10%             D-pad L/R  cycle build/nuke action
--   R3 (right stick click)  re-fit the map  (View/Select and Start open the menu: MainMenu)
--
-- Screen points passed to ctx callbacks are in the same space as GuiObject.AbsolutePosition
-- (the space screenToTile uses).

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local GamepadControls = {}

local DEAD_ZONE = 0.15
local TRIGGER_DEAD_ZONE = 0.08
local ACTION_NAME = "FrontlinesGamepad"

local function applyDeadZone(v: Vector2): (Vector2, number)
	local m = v.Magnitude
	if m < DEAD_ZONE then
		return Vector2.zero, 0
	end
	local k = math.min((m - DEAD_ZONE) / (1 - DEAD_ZONE), 1)
	return v / m, k * k -- quadratic response: fine control near the centre
end

local function isGamepadType(t: Enum.UserInputType): boolean
	return string.sub(t.Name, 1, 7) == "Gamepad"
end

-- ctx: {
--   gui: ScreenGui, deviceLayout, buildBar: GuiObject,
--   act(tile), tileAt(sx, sy) -> tile?, contextMenu(sx, sy), cancel() -> boolean,
--   adjustRatio(delta), cycleAction(dir), zoomAt(factor, sx, sy), pan(dx, dy), fitMap(),
--   overlaysChanged(), focusTarget() -> GuiObject?, modeActive() -> boolean,
-- }
function GamepadControls.start(ctx)
	local api = { active = false }
	local gui: ScreenGui = ctx.gui
	local DeviceLayout = ctx.deviceLayout

	GuiService.AutoSelectGuiEnabled = false -- View/Select opens our menu instead of toggling GUI selection
	GuiService.GuiNavigationEnabled = true

	-- Crosshair
	local cursor = Instance.new("Frame")
	cursor.Name = "GamepadCursor"
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.Size = UDim2.fromOffset(34, 34)
	cursor.BackgroundTransparency = 1
	cursor.ZIndex = 60
	cursor.Visible = false
	cursor.Active = false
	cursor.Parent = gui
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 60
	ring.Parent = cursor
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 2.5
	ringStroke.Color = Color3.new(1, 1, 1)
	ringStroke.Parent = ring
	local function mark(x, y, w, h)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.new(0.5, x, 0.5, y)
		f.Size = UDim2.fromOffset(w, h)
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BorderSizePixel = 0
		f.ZIndex = 61
		f.Parent = cursor
		return f
	end
	local dot = mark(0, 0, 4, 4)
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot
	local ticks = { dot, mark(0, -13, 2, 8), mark(0, 13, 2, 8), mark(-13, 0, 8, 2), mark(13, 0, 8, 2) }

	local cursorLocal = Vector2.zero -- in gui offset space
	local placed = false
	local lastPad = Enum.UserInputType.Gamepad1
	local holdTime = 0
	local zooming = false
	local lastOverlayRefresh = 0

	local function screenRect(): Vector2
		return gui.AbsoluteSize
	end

	local function cursorAbs(): Vector2
		return gui.AbsolutePosition + cursorLocal
	end

	local function selecting(): boolean
		return GuiService.SelectedObject ~= nil
	end

	-- The MainMenu script sets this attribute on PlayerGui while the menu covers the match.
	local menuGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local function menuOpen(): boolean
		return menuGui:GetAttribute("FrontlinesMenuOpen") == true
	end

	local function selectionInBuildBar(): boolean
		local sel = GuiService.SelectedObject
		return sel ~= nil and ctx.buildBar ~= nil and sel:IsDescendantOf(ctx.buildBar)
	end

	local function setActive(on: boolean)
		if on == api.active then
			return
		end
		api.active = on
		if on then
			if not placed then
				local s = screenRect()
				cursorLocal = Vector2.new(s.X / 2, s.Y / 2)
				placed = true
			end
			UserInputService.MouseIconEnabled = false
		else
			UserInputService.MouseIconEnabled = true
			if selectionInBuildBar() then
				GuiService.SelectedObject = nil
			end
		end
	end

	-- Returns (abs, local) cursor positions, or nil when the gamepad isn't the active input.
	function api.pointer(): (Vector2?, Vector2?)
		if not api.active then
			return nil, nil
		end
		return cursorAbs(), cursorLocal
	end

	DeviceLayout.Changed:Connect(function(st)
		setActive(st.input == "Gamepad")
	end)
	setActive(DeviceLayout.state.input == "Gamepad")

	UserInputService.InputBegan:Connect(function(input)
		if isGamepadType(input.UserInputType) then
			lastPad = input.UserInputType
		end
	end)

	-- Buttons -------------------------------------------------------------------------------
	local K = Enum.KeyCode
	local PASS = Enum.ContextActionResult.Pass
	local SINK = Enum.ContextActionResult.Sink
	local ANALOG = { [K.Thumbstick1] = true, [K.Thumbstick2] = true, [K.ButtonL2] = true, [K.ButtonR2] = true }

	local function handle(_name: string, inputState: Enum.UserInputState, input: InputObject)
		if menuOpen() then
			return PASS -- the main menu handles the controller
		end
		local k = input.KeyCode
		if isGamepadType(input.UserInputType) then
			lastPad = input.UserInputType
		end
		-- While a GUI button is selected, let Roblox's GUI navigation have sticks, D-pad and A.
		if ANALOG[k] then
			return if selecting() then PASS else SINK
		end
		if inputState ~= Enum.UserInputState.Begin then
			return PASS
		end
		setActive(true)

		if k == K.ButtonA then
			if selecting() then
				return PASS
			end
			local a = cursorAbs()
			local tile = ctx.tileAt(a.X, a.Y)
			if tile then
				ctx.act(tile)
			end
			return SINK
		elseif k == K.ButtonB then
			if selectionInBuildBar() then
				GuiService.SelectedObject = nil
				return SINK
			elseif selecting() then
				return PASS -- someone else's popup owns the selection
			elseif ctx.cancel() then
				return SINK
			end
			return PASS
		elseif k == K.ButtonX then
			if selecting() then
				return PASS
			end
			local a = cursorAbs()
			ctx.contextMenu(a.X, a.Y)
			return SINK
		elseif k == K.ButtonY then
			if selectionInBuildBar() then
				GuiService.SelectedObject = nil
			elseif not selecting() then
				local target = ctx.focusTarget()
				if target then
					GuiService.SelectedObject = target
				end
			else
				return PASS
			end
			return SINK
		elseif k == K.ButtonL1 then
			ctx.adjustRatio(-0.1)
			return SINK
		elseif k == K.ButtonR1 then
			ctx.adjustRatio(0.1)
			return SINK
		elseif k == K.DPadLeft or k == K.DPadRight then
			if selecting() then
				return PASS
			end
			ctx.cycleAction(if k == K.DPadRight then 1 else -1)
			return SINK
		elseif k == K.ButtonR3 then
			ctx.fitMap()
			return SINK
		end
		return PASS
	end

	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		handle,
		false,
		Enum.ContextActionPriority.High.Value,
		K.ButtonA,
		K.ButtonB,
		K.ButtonX,
		K.ButtonY,
		K.ButtonL1,
		K.ButtonR1,
		K.ButtonL2,
		K.ButtonR2,
		K.DPadLeft,
		K.DPadRight,
		K.ButtonR3,
		K.Thumbstick1,
		K.Thumbstick2
	)

	-- Build bar focus: leaving it after a button is chosen, so the cursor can place it.
	if ctx.buildBar then
		for _, b in ctx.buildBar:GetChildren() do
			if b:IsA("GuiButton") then
				b.Activated:Connect(function()
					if api.active and selectionInBuildBar() then
						GuiService.SelectedObject = nil
					end
				end)
			end
		end
	end

	-- Analog: sticks and triggers polled every frame ----------------------------------------
	RunService.RenderStepped:Connect(function(dt)
		local show = api.active and not selecting() and not menuOpen()
		cursor.Visible = show
		if not api.active or menuOpen() then
			return
		end
		local col = if ctx.modeActive() then Color3.fromRGB(255, 190, 80) else Color3.new(1, 1, 1)
		ringStroke.Color = col
		for _, t in ticks do
			t.BackgroundColor3 = col
		end
		cursor.Position = UDim2.fromOffset(cursorLocal.X, cursorLocal.Y)
		if not show then
			holdTime = 0
			return
		end

		local ok, padState = pcall(function()
			return UserInputService:GetGamepadState(lastPad)
		end)
		if not ok or not padState then
			return
		end
		local left, right, lt, rt = Vector2.zero, Vector2.zero, 0, 0
		for _, io in padState do
			local k = io.KeyCode
			if k == Enum.KeyCode.Thumbstick1 then
				left = Vector2.new(io.Position.X, io.Position.Y)
			elseif k == Enum.KeyCode.Thumbstick2 then
				right = Vector2.new(io.Position.X, io.Position.Y)
			elseif k == Enum.KeyCode.ButtonL2 then
				lt = io.Position.Z
			elseif k == Enum.KeyCode.ButtonR2 then
				rt = io.Position.Z
			end
		end

		local s = screenRect()
		local short = math.max(200, math.min(s.X, s.Y))

		-- Cursor: dead zone, quadratic response, speed scaled by screen size, accelerates while held.
		local dir, amt = applyDeadZone(left)
		if amt > 0 then
			holdTime += dt
			local accel = 1 + math.min(holdTime / 0.7, 1) * 1.4
			local speed = short * 0.6 * accel * amt
			local want = cursorLocal + Vector2.new(dir.X, -dir.Y) * speed * dt
			local clamped = Vector2.new(math.clamp(want.X, 0, s.X), math.clamp(want.Y, 0, s.Y))
			-- Pushing past the screen edge pans the map instead.
			local over = want - clamped
			if over.Magnitude > 0 then
				ctx.pan(-over.X, -over.Y)
			end
			cursorLocal = clamped
			cursor.Position = UDim2.fromOffset(cursorLocal.X, cursorLocal.Y)
		else
			holdTime = 0
		end

		-- Right stick pans.
		local pdir, pamt = applyDeadZone(right)
		if pamt > 0 then
			local speed = short * 1.1 * pamt
			ctx.pan(-pdir.X * speed * dt, pdir.Y * speed * dt)
		end

		-- Triggers zoom around the cursor.
		local z = (if rt > TRIGGER_DEAD_ZONE then rt else 0) - (if lt > TRIGGER_DEAD_ZONE then lt else 0)
		local now = os.clock()
		if z ~= 0 then
			local a = cursorAbs()
			ctx.zoomAt(math.exp(z * 1.8 * dt), a.X, a.Y)
			zooming = true
			if now - lastOverlayRefresh > 0.15 then
				lastOverlayRefresh = now
				ctx.overlaysChanged()
			end
		elseif zooming then
			zooming = false
			lastOverlayRefresh = now
			ctx.overlaysChanged()
		end
	end)

	return api
end

return GamepadControls
