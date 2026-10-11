--[[
	War Front - compact public matchmaking bar on the main menu.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.QueueBar (ModuleScript), used by LobbyPages.
-- setup(ctx): parent, preview(id, width, cutout), leave(), changed().
-- show(lobby, connecting?), teleport(), clear(), active(), height().
-- Uses the existing public lobby messages; the clock is anchored when each view arrives.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local queued, motion = false, nil

local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make
local QueueBar = {}
local ctx: any = nil
local ui: any = {}
local function slide(visible)
	if motion then local previous = motion; motion = nil; previous:Cancel() end
	if visible and not ui.root.Visible then ui.root.Position = UDim2.new(0.5, 0, 1, ui.root.Size.Y.Offset + 12) end
	ui.root.Visible = true
	local tween = TweenService:Create(ui.root, TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 1, if visible then -18 else ui.root.Size.Y.Offset + 12) })
	motion = tween
	tween.Completed:Connect(function()
		if motion ~= tween then return end
		motion = nil
		if not queued then ui.root.Visible = false end
	end)
	tween:Play()
end
local state: any = { lobby = nil, deadline = nil, connecting = false, teleportAt = nil, map = nil }

local function place(o, x, y, w, h)
	o.Position = UDim2.fromOffset(x, y)
	o.Size = UDim2.fromOffset(w, h)
end

local function duration(seconds: number): string
	local n = math.max(0, math.ceil(seconds))
	return if n >= 60 then (n // 60) .. "m " .. (n % 60) .. "s" else n .. "s"
end

-- Draw the parallelogram locally: no uploaded image or additional asset is needed.
local function background(fill, border, w: number?, h: number?, slant: number?)
	w, h, slant = w or 1024, h or 128, slant or 64
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	if not image then
		return nil
	end
	local pixels = buffer.create(w * h * 4)
	for y = 0, h - 1 do
		local left = slant * (1 - y / (h - 1))
		local right = w - 1 - slant * y / (h - 1)
		for x = math.ceil(left), math.floor(right) do
			local edge = math.min(y, h - 1 - y, (x - left) / 1.12, (right - x) / 1.12)
			local c = if edge < 2.5 then border else fill
			local off = (y * w + x) * 4
			buffer.writeu8(pixels, off, math.round(c.R * 255))
			buffer.writeu8(pixels, off + 1, math.round(c.G * 255))
			buffer.writeu8(pixels, off + 2, math.round(c.B * 255))
			buffer.writeu8(pixels, off + 3, 255)
		end
	end
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), pixels)
	return image
end

local function label(name: string, font, colour, outlined: boolean?)
	local l = MenuKit.text({ Name = name, FontFace = font, TextColor3 = colour, Text = "", Parent = ui.root })
	if outlined then
		make("UIStroke", { Color = C.BLACK, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual, Parent = l })
	end
	return l
end

local function layout()
	if not ui.root then
		return
	end
	local scale = ctx.parent:FindFirstChildWhichIsA("UIScale")
	local s = if scale then scale.Scale else 1
	local width = math.min(960, math.max(0, ctx.parent.AbsoluteSize.X / s - 32))
	local compact = width < 600
	local h = 112
	local previous = ui.root.Size
	ui.root.Size = UDim2.fromOffset(width, h)
	local pad = math.max(12, width * 0.07)
	local inner = width - 2 * pad
	local mapW = inner * (if compact then 0.18 else 0.19)
	local infoW = inner * (if compact then 0.32 else 0.25)
	local statusW = inner * (if compact then 0.20 else 0.30)
	local timerW = inner - mapW - infoW - statusW
	local infoX, statusX = pad + mapW, pad + mapW + infoW
	place(ui.preview, pad, 12, mapW - (if compact then 4 else 12), h - 24)
	place(ui.country, infoX, 14, infoW, if compact then 25 else 27)
	place(ui.mode, infoX, if compact then 39 else 44, infoW, 15)
	place(ui.count, infoX, if compact then 57 else 64, infoW, 34)
	place(ui.status, statusX + 5, 10, statusW - 10, h - 20)
	local timerX = statusX + statusW
	place(ui.timer, timerX, 12, timerW, 52)
	local buttonW = math.min(if compact then 94 else 128, timerW)
	place(ui.leave, timerX + (timerW - buttonW) / 2, 67, buttonW, 36)
	ui.country.TextSize = if compact then math.clamp(width / 26, 10, 18) else 23
	ui.mode.TextSize = if compact then 9 else 11
	ui.count.TextSize = if compact then 25 else 34
	ui.status.TextSize = if compact then 10 else 14
	ui.timer.TextSize = if compact then math.clamp(width / 16, 18, 32) else 48
	ui.leaveText.TextSize = if compact then 9 else 11
	if previous ~= ui.root.Size and ui.root.Visible and ctx.changed then
		ctx.changed()
	end
end

local function refresh()
	if not ui.root or not queued then
		return
	end
	local l = state.lobby or {}
	ui.country.Text = string.upper(tostring(l.name or l.map or "JOINING LOBBY"))
	ui.mode.Text = string.upper(tostring(l.sub or ""))
	ui.count.Text = tostring(l.count or 0) .. " / " .. tostring(l.max or "?")
	local left = if state.deadline then math.max(0, state.deadline - os.clock()) else nil
	if state.teleportAt then
		ui.status.Text = "Teleporting..."
		ui.timer.Text = "0s"
	elseif state.connecting then
		ui.status.Text = "Connecting..."
		ui.timer.Text = if left then duration(left) else "—"
	elseif l.started or (left and left <= 0) then
		ui.status.Text = "Beginning..."
		ui.timer.Text = "0s"
	else
		ui.status.Text = "Waiting for players..."
		ui.timer.Text = duration(left or l.default or 60)
	end
	ui.leave.Visible = state.teleportAt == nil
	if l.map and state.map ~= l.map then
		ui.preview.Visible = false
		local img = ctx.preview(l.map, 180, true)
		if img and pcall(function()
			ui.preview.ImageContent = Content.fromObject(img)
		end) then
			state.map = l.map
			ui.preview.Visible = true
		end
	end
end

function QueueBar.setup(c)
	ctx = c
	ui.root = make("Frame", { Name = "QueueBar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.fromOffset(960, 112), BackgroundTransparency = 1, Visible = false, ZIndex = 20, Parent = ctx.parent })
	ui.background = make("ImageLabel", { Name = "Shape", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = ui.root })
	local ok, img = pcall(background, C.SURFACE, C.MALIBU)
	if ok and img then
		ui.shapeImage = img
		ui.background.ImageContent = Content.fromObject(img)
	else
		-- Keep the queue usable on devices that have exhausted their EditableImage budget.
		ui.background.BackgroundTransparency = 0
		ui.background.BackgroundColor3 = C.SURFACE
		MenuKit.stroke(ui.background, 0, C.MALIBU, 2)
	end
	ui.preview = make("ImageLabel", { Name = "Map", BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Visible = false, ZIndex = 2, Parent = ui.root })
	ui.country = label("Country", F.BOLD, C.WHITE, true)
	ui.country.TextTruncate = Enum.TextTruncate.AtEnd
	ui.mode = label("Mode", F.MEDIUM, C.GRAY400)
	ui.mode.TextTruncate = Enum.TextTruncate.AtEnd
	ui.count = label("PlayerCount", F.BOLD, C.WHITE, true)
	ui.status = label("Status", F.MEDIUM, C.GRAY400)
	ui.status.TextWrapped = true
	ui.timer = label("Countdown", F.BLACK, C.WHITE, true)
	for _, l in { ui.country, ui.mode, ui.count, ui.status, ui.timer } do
		l.ZIndex = 2
	end
	ui.leave = make("ImageButton", { Name = "LeaveQueue", BackgroundTransparency = 1, AutoButtonColor = false, Selectable = true, ZIndex = 3, Parent = ui.root })
	local buttonOK, buttonImage = pcall(background, C.RED500, C.RED400, 256, 96, 32)
	if buttonOK and buttonImage then
		ui.buttonImage = buttonImage
		ui.leave.ImageContent = Content.fromObject(buttonImage)
	else
		ui.leave.BackgroundTransparency = 0
		ui.leave.BackgroundColor3 = C.RED500
	end
	ui.leaveText = MenuKit.text({ Name = "Label", Size = UDim2.fromScale(1, 1), FontFace = F.BOLD, Text = "LEAVE QUEUE", ZIndex = 4, Parent = ui.leave })
	MenuKit.hover(ui.leave, function(s)
		ui.leave.ImageColor3 = if s == "press" then Color3.fromRGB(190, 190, 190) elseif s == "hover" then Color3.fromRGB(225, 225, 225) else C.WHITE
	end)
	ui.leave.Activated:Connect(function()
		ctx.leave()
	end)
	ctx.parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc >= 0.1 then
			acc = 0
			refresh()
			if state.teleportAt and os.clock() - state.teleportAt > 30 then
				QueueBar.clear()
				ctx.leave()
				if ctx.toast then
					ctx.toast("Couldn't join the match. Please try again.")
				end
			end
		end
	end)
	layout()
end

function QueueBar.show(lobby, connecting: boolean?)
	if state.teleportAt and not connecting then
		return -- late lobby views must not replace the teleport status
	end
	state.lobby = lobby
	state.deadline = if lobby and type(lobby.secs) == "number" then os.clock() + lobby.secs elseif lobby then lobby.endAt else nil
	state.connecting = connecting == true
	state.teleportAt = nil
	local wasVisible = queued
	queued = true
	layout()
	if not wasVisible then slide(true) end
	refresh()
	if not wasVisible and ctx.changed then
		ctx.changed()
	end
end

function QueueBar.teleport()
	state.teleportAt = os.clock()
	refresh()
end

function QueueBar.clear()
	state.lobby, state.deadline, state.teleportAt, state.map = nil, nil, nil, nil
	if ui.root and queued then
		queued = false
		slide(false)
		if ctx.changed then
			ctx.changed()
		end
	end
end

function QueueBar.active(): boolean
	return ui.root ~= nil and queued
end

function QueueBar.teleporting(): boolean
	return state.teleportAt ~= nil
end

function QueueBar.height(): number
	return if QueueBar.active() then ui.root.Size.Y.Offset + 30 else 0
end

return QueueBar
