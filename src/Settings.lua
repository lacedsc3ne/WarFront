--[[
	War Front - player settings (values, persistence, audio groups) and the settings page.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Settings (ModuleScript), used by GameClient and PauseMenu.
--
-- Settings.values[key]            current value (read freely; write only through Settings.set)
-- Settings.set(key, value)        validates, applies, fires Changed, saves ~2 s after the last change
-- Settings.Changed(key, value)    RBXScriptSignal
-- Settings.DEFAULTS, Settings.reset()
-- Settings.buildUI(parent) -> { first: GuiObject, refresh() }   the settings page (PauseMenu hosts it)
-- Helpers for GameClient's renderer: flatTerrainRGB(byte), nearOtherOwner(map, owners, t, o),
-- growTouched(map, touched).
--
-- Persistence: loaded once from MetaFn "get" (profile.settings), saved with MetaFn "saveSettings".
-- Progression.lua (server) validates against its own copy of the keys below - keep them in sync.
--
-- Applied here directly: UI scale (DeviceLayout.setUserScale), leaderboard default
-- (DeviceLayout.setBoardDefault) and audio: SoundService.Master (SoundGroup) holds the
-- SoundGroup "Effects"; future sounds should use SoundGroup = SoundService.Master.Effects.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))

local Settings = {}

local DEFAULTS = {
	terrainShading = true,
	nameLabels = true,
	structureIcons = true,
	eventFeed = true,
	boardOpen = true,
	reducedMotion = false,
	lowDetail = false,
	borderContrast = false,
	attackingTroopsOverlay = true, -- OpenFront settings.attackingTroopsOverlay
	cursorCostLabel = true, -- OpenFront settings.cursorCostLabel
	leaderboardColumns = "tiles,gold,maxtroops", -- ⚙️ column picker (comma-separated column ids)
	playerName = "", -- custom in-game name ("" = Roblox display name), filtered by the server
	uiScale = 100,
	masterVolume = 90, -- OpenFront UserSettings defaults (master 0.9, effects 0.7, alerts 0.8,
	effectsVolume = 70, -- ambience 0.4, interface 0.5)
	alertsVolume = 80,
	ambienceVolume = 40,
	interfaceVolume = 50,
	musicVolume = 50, -- OpenFront default music 0.5
	muted = false,
	-- OpenFront UserSettings (UserSettingModal Gameplay / Graphics / Audio tabs)
	alertFrame = true, -- red / orange screen frame when betrayed or attacked over land
	leftClickMenu = false, -- left click opens the radial menu (the sword item attacks)
	anonymousNames = false, -- "Hidden Names": other players get fake names on your screen
	hiddenLobbyIds = false, -- private lobby ID hidden until clicked
	lobbyStartAlerts = false, -- start chime when your lobby / ranked match starts
	goToPlayer = true, -- zoom to your land when the spawn phase ends
	attackRatio = 20, -- % of troops per attack (remembered between games)
	attackRatioIncrement = 10, -- % per T / Y press and Shift + wheel step
	nukeAllySafety = 5, -- ticks: a nuke that would hit an alliance this new is held back once
	emojis = true, -- show emojis in game
	perfOverlay = false, -- performance overlay (Shift + D)
	muteOnBlur = false, -- silence the game while the window is not focused
	alertsWhenUnfocused = true, -- ... but keep alerts audible
	keybinds = "", -- JSON action -> key overrides (KeybindData)
}
Settings.DEFAULTS = DEFAULTS

-- Number ranges (min, max, step). Everything else is a boolean.
local RANGES = {
	uiScale = { 80, 130, 5 },
	masterVolume = { 0, 100, 5 },
	effectsVolume = { 0, 100, 5 },
	alertsVolume = { 0, 100, 5 },
	ambienceVolume = { 0, 100, 5 },
	interfaceVolume = { 0, 100, 5 },
	musicVolume = { 0, 100, 5 },
	attackRatio = { 1, 100, 1 },
	attackRatioIncrement = { 1, 20, 1 },
	nukeAllySafety = { 0, 30, 1 },
}

local values = table.clone(DEFAULTS)
Settings.values = values

local changedEvent = Instance.new("BindableEvent")
Settings.Changed = changedEvent.Event

local function clean(key: string, v: any): any
	local d = DEFAULTS[key]
	if d == nil then
		return nil
	end
	if type(d) == "boolean" then
		return if type(v) == "boolean" then v else nil
	end
	if type(d) == "string" then
		return if type(v) == "string" and #v <= (if key == "keybinds" then 2000 else 300) then v else nil
	end
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	local r = RANGES[key]
	return math.clamp(math.floor(v / r[3] + 0.5) * r[3], r[1], r[2])
end

--------------------------------------------------------------------------------
-- Applying (things not owned by GameClient)
--------------------------------------------------------------------------------
local master = SoundService:FindFirstChild("Master")
if not (master and master:IsA("SoundGroup")) then
	master = Instance.new("SoundGroup")
	master.Name = "Master"
	master.Parent = SoundService
end
local effects = master:FindFirstChild("Effects")
if not (effects and effects:IsA("SoundGroup")) then
	effects = Instance.new("SoundGroup")
	effects.Name = "Effects"
	effects.Parent = master
end

local function channel(name: string): SoundGroup
	local g = master:FindFirstChild(name)
	if not (g and g:IsA("SoundGroup")) then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = master
	end
	return g :: SoundGroup
end
local alerts, ambienceGroup, interface = channel("Alerts"), channel("Ambience"), channel("Interface")
local musicGroup = channel("Music")

-- AudioMixer.perceptualGain: the slider value is squared.
local function gain(v: number): number
	return (v / 100) ^ 2
end

-- AudioMixer mute-on-blur: everything but (optionally) the alerts goes quiet while the window
-- is not focused.
local focused = true
local function applyAudio()
	local blur = values.muteOnBlur and not focused
	master.Volume = if values.muted then 0 else gain(values.masterVolume)
	effects.Volume = if blur then 0 else gain(values.effectsVolume)
	alerts.Volume = if blur and not values.alertsWhenUnfocused then 0 else gain(values.alertsVolume)
	ambienceGroup.Volume = if blur then 0 else gain(values.ambienceVolume)
	interface.Volume = if blur then 0 else gain(values.interfaceVolume)
	musicGroup.Volume = if blur then 0 else gain(values.musicVolume)
end
UserInputService.WindowFocusReleased:Connect(function()
	focused = false
	applyAudio()
end)
UserInputService.WindowFocused:Connect(function()
	focused = true
	applyAudio()
end)

local function apply(key: string)
	if key == "masterVolume" or key == "effectsVolume" or key == "alertsVolume" or key == "ambienceVolume" or key == "interfaceVolume" or key == "musicVolume" or key == "muted" or key == "muteOnBlur" or key == "alertsWhenUnfocused" then
		applyAudio()
	elseif key == "uiScale" then
		if DeviceLayout.setUserScale then
			DeviceLayout.setUserScale(values.uiScale / 100)
		end
	elseif key == "boardOpen" then
		if DeviceLayout.setBoardDefault then
			DeviceLayout.setBoardDefault(values.boardOpen)
		end
	end
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------
local loaded = false
local dirty: { [string]: boolean } = {} -- keys the player changed before the profile arrived
local saveToken = 0
local SAVE_DELAY = 2

local function scheduleSave()
	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DELAY, function()
		if token ~= saveToken then
			return
		end
		local fn = Shared:FindFirstChild("MetaFn")
		if not fn then
			return
		end
		local ok, err = pcall(function()
			return fn:InvokeServer("saveSettings", table.clone(values))
		end)
		if not ok then
			warn("[War Front] Settings not saved: " .. tostring(err))
		end
	end)
end

local function setValue(key: string, v: any, save: boolean): boolean
	local c = clean(key, v)
	if c == nil or values[key] == c then
		return false
	end
	values[key] = c
	apply(key)
	changedEvent:Fire(key, c)
	if save then
		if not loaded then
			dirty[key] = true
		end
		scheduleSave()
	end
	return true
end

function Settings.set(key: string, v: any)
	setValue(key, v, true)
end

function Settings.reset()
	for k, d in DEFAULTS do
		setValue(k, d, true)
	end
end

local function applyLoaded(saved: any)
	if loaded then
		return
	end
	loaded = true
	if type(saved) == "table" then
		for k in DEFAULTS do
			if not dirty[k] and saved[k] ~= nil then
				setValue(k, saved[k], false)
			end
		end
	end
	if next(dirty) then
		scheduleSave() -- changes made before the profile arrived still need saving
	end
	table.clear(dirty)
end

task.spawn(function()
	local metaEvent = Shared:WaitForChild("Meta", 30)
	if metaEvent then
		metaEvent.OnClientEvent:Connect(function(kind: string, data: any)
			if kind == "profile" and type(data) == "table" and not loaded then
				applyLoaded(data.settings)
			end
		end)
	end
	local fn = Shared:WaitForChild("MetaFn", 30)
	for _ = 1, 6 do
		if loaded or not fn then
			return
		end
		local ok, success, p = pcall(function()
			return fn:InvokeServer("get")
		end)
		if ok and success and type(p) == "table" then
			applyLoaded(p.settings)
			return
		end
		task.wait(3)
	end
end)

applyAudio()

--------------------------------------------------------------------------------
-- Renderer helpers (used by GameClient)
--------------------------------------------------------------------------------
-- Terrain shading off: one land colour, one water colour (impassable mountains stay grey).
function Settings.flatTerrainRGB(b: number): (number, number, number)
	if b >= 128 then
		if bit32.band(b, 31) == 31 then
			return 92, 92, 98
		end
		return 146, 168, 104
	end
	return 64, 118, 178
end

local NB1, NB2 = table.create(4), table.create(4)

-- True if a tile within two steps of t has a different owner (thick border for colour-blind mode).
function Settings.nearOtherOwner(map, owners: buffer, t: number, o: number): boolean
	local n = MapUtil.neighbors(map, t, NB1)
	for i = 1, n do
		local m = MapUtil.neighbors(map, NB1[i], NB2)
		for j = 1, m do
			if buffer.readu16(owners, NB2[j] * 2) ~= o then
				return true
			end
		end
	end
	return false
end

-- Adds the neighbours of every tile in `touched` (a set), so 2-tile borders repaint correctly.
local growList = {}
function Settings.growTouched(map, touched: { [number]: boolean })
	table.clear(growList)
	for t in touched do
		growList[#growList + 1] = t
	end
	for _, t in growList do
		local n = MapUtil.neighbors(map, t, NB1)
		for i = 1, n do
			touched[NB1[i]] = true
		end
	end
end

--------------------------------------------------------------------------------
-- Settings page
--------------------------------------------------------------------------------
local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local FONT_BLACK = Font.fromEnum(Enum.Font.GothamBlack)
local ROW = Color3.fromRGB(22, 36, 58)
local ROW_HI = Color3.fromRGB(34, 54, 84)
local BLUE = Color3.fromRGB(0, 132, 209)
local BLUE_HI = Color3.fromRGB(63, 169, 245)
local YELLOW = Color3.fromRGB(255, 215, 0)
local OFF = Color3.fromRGB(51, 65, 85)
local MUTED = Color3.fromRGB(156, 163, 175)
local WHITE = Color3.new(1, 1, 1)

local PAGE = {
	{ section = "DISPLAY" },
	{ key = "terrainShading", label = "Terrain shading", desc = "Coloured hills, beaches and deep water. Off: flat land and water." },
	{ key = "nameLabels", label = "Name labels on map", desc = "Player names and troop counts over territories." },
	{ key = "structureIcons", label = "Structure icons on map", desc = "Cities, ports, silos and defences on the map." },
	{ key = "eventFeed", label = "Event feed", desc = "Battle messages on the right side of the screen." },
	{ key = "boardOpen", label = "Leaderboard open by default", desc = "Show the full leaderboard table instead of just its header." },
	{ key = "borderContrast", label = "Colour-blind friendly borders", desc = "Colour-blind player palette, thicker border around your land; allies outlined in blue." },
	{ key = "attackingTroopsOverlay", label = "Attacking Troops Overlay", desc = "Show attacker vs defender troop counts on active front lines." },
	{ key = "cursorCostLabel", label = "Cursor Build Cost", desc = "Show a cost pill under the build cursor icon" },
	{ key = "reducedMotion", label = "Reduced motion", desc = "No pulsing rings, camera glides or explosion animations." },
	{ key = "lowDetail", label = "Low detail", desc = "Map drawn at 1 pixel per tile and redrawn less often, fewer effects, boat troop labels hidden. Helps slower devices." },
	{ key = "uiScale", label = "Interface size", desc = "Size of the in-match panels.", suffix = "%" },
	{ section = "AUDIO" },
	{ key = "muted", label = "Mute all", desc = "Silence every sound." },
	{ key = "masterVolume", label = "Master Volume", desc = "Overall volume for everything below.", suffix = "%" },
	{ key = "musicVolume", label = "Music", desc = "The menu theme and the in-game soundtrack.", suffix = "%" },
	{ key = "effectsVolume", label = "Sound Effects", desc = "Builds, launches, impacts and end-of-game stings.", suffix = "%" },
	{ key = "alertsVolume", label = "Alerts & Notifications", desc = "Incoming nuke warnings, alliance requests and chat pings.", suffix = "%" },
	{ key = "ambienceVolume", label = "Ambience", desc = "Background loops from cities, factories and silos you zoom in on.", suffix = "%" },
	{ key = "interfaceVolume", label = "Interface", desc = "Clicks, ticks and other menu sounds.", suffix = "%" },
}

local function make(className: string, props: { [string]: any }): any
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

local function text(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.BorderSizePixel = 0
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextSize = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return make("TextLabel", props)
end

-- Row highlight for hover / gamepad selection (outline turns blue).
local function highlight(b: GuiButton, stroke: UIStroke)
	local function on()
		b.BackgroundColor3 = ROW_HI
		stroke.Color = BLUE_HI
		stroke.Transparency = 0
	end
	local function off()
		b.BackgroundColor3 = ROW
		stroke.Color = WHITE
		stroke.Transparency = 0.92
	end
	b.MouseEnter:Connect(on)
	b.MouseLeave:Connect(off)
	b.SelectionGained:Connect(on)
	b.SelectionLost:Connect(off)
	off()
end

local function rowButton(parent: Instance, order: number, h: number): (TextButton, UIStroke)
	local b = make("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, h),
		BackgroundColor3 = ROW,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = parent,
	})
	corner(b, 10)
	local s = make("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 1, Parent = b })
	highlight(b, s)
	return b, s
end

-- parent: a GuiObject (usually a ScrollingFrame) the rows are added to with a UIListLayout.
function Settings.buildUI(parent: GuiObject)
	local api = { first = nil :: GuiObject?, widgets = {} }
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = parent })

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	for _, e in PAGE do
		if e.section then
			local head = make("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Parent = parent })
			local bar = make("Frame", { Position = UDim2.fromOffset(2, 12), Size = UDim2.fromOffset(4, 16), BackgroundColor3 = YELLOW, BorderSizePixel = 0, Parent = head })
			corner(bar, 2)
			text({ Position = UDim2.fromOffset(14, 8), Size = UDim2.new(0.5, 0, 0, 24), FontFace = FONT_BLACK, TextSize = 15, TextColor3 = YELLOW, Text = e.section, Parent = head })
			text({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -4, 0, 10),
				Size = UDim2.new(0.5, -10, 0, 20),
				TextSize = 12,
				TextColor3 = MUTED,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = e.note or "Changes apply instantly",
				Parent = head,
			})
		elseif RANGES[e.key] then
			-- Slider: label + value, then [-] track [+]. The -/+ buttons are what a controller selects.
			local key = e.key
			local r = RANGES[key]
			local box = make("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, if e.desc then 84 else 70), BackgroundColor3 = ROW, BorderSizePixel = 0, Parent = parent })
			corner(box, 10)
			make("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = WHITE, Transparency = 0.92, Parent = box })
			text({ Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -100, 0, 20), FontFace = FONT_BOLD, TextSize = 15, Text = e.label, Parent = box })
			local valueText = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.fromOffset(80, 20), FontFace = FONT_BOLD, TextSize = 15, TextColor3 = BLUE_HI, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = box })
			if e.desc then
				text({ Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -28, 0, 16), TextSize = 12, TextColor3 = MUTED, TextTruncate = Enum.TextTruncate.AtEnd, Text = e.desc, Parent = box })
			end
			local y = if e.desc then 48 else 34
			local minus = rowButton(box, 0, 30)
			minus.Position = UDim2.fromOffset(10, y)
			minus.Size = UDim2.fromOffset(40, 30)
			minus.FontFace = FONT_BLACK
			minus.TextSize = 18
			minus.TextColor3 = WHITE
			minus.Text = "-"
			local plus = rowButton(box, 0, 30)
			plus.AnchorPoint = Vector2.new(1, 0)
			plus.Position = UDim2.new(1, -10, 0, y)
			plus.Size = UDim2.fromOffset(40, 30)
			plus.FontFace = FONT_BLACK
			plus.TextSize = 18
			plus.TextColor3 = WHITE
			plus.Text = "+"
			-- Track: a wide transparent hit area (not selectable) for mouse / touch dragging.
			local hit = make("TextButton", { Position = UDim2.fromOffset(60, y), Size = UDim2.new(1, -120, 0, 30), BackgroundTransparency = 1, Text = "", Selectable = false, AutoButtonColor = false, Parent = box })
			local track = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = OFF, BorderSizePixel = 0, Parent = hit })
			corner(track, 3)
			local fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = BLUE, BorderSizePixel = 0, Parent = track })
			corner(fill, 3)
			local knob = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, Parent = track })
			corner(knob, 8)
			make("UIStroke", { Color = BLUE, Thickness = 2, Parent = knob })

			local function update()
				local v = values[key]
				local f = (v - r[1]) / (r[2] - r[1])
				fill.Size = UDim2.fromScale(f, 1)
				knob.Position = UDim2.fromScale(f, 0.5)
				valueText.Text = tostring(v) .. (e.suffix or "")
			end
			local function setFromX(x: number)
				local f = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
				Settings.set(key, r[1] + f * (r[2] - r[1]))
			end
			minus.Activated:Connect(function()
				Settings.set(key, values[key] - r[3])
			end)
			plus.Activated:Connect(function()
				Settings.set(key, values[key] + r[3])
			end)
			local dragging: InputObject? = nil
			hit.InputBegan:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					dragging = input
					setFromX(input.Position.X)
				end
			end)
			UserInputService.InputChanged:Connect(function(input)
				if not dragging then
					return
				end
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and input == dragging) then
					setFromX(input.Position.X)
				end
			end)
			UserInputService.InputEnded:Connect(function(input)
				if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseButton1) then
					dragging = nil
				end
			end)
			api.widgets[key] = update
			api.first = api.first or minus
			update()
		else
			-- Toggle: the whole row is one button.
			local key = e.key
			local b = rowButton(parent, nextOrder(), if e.desc then 58 else 44)
			text({ Position = UDim2.fromOffset(14, if e.desc then 9 else 0), Size = UDim2.new(1, -90, 0, if e.desc then 20 else 44), FontFace = FONT_BOLD, TextSize = 15, Text = e.label, Parent = b })
			if e.desc then
				text({ Position = UDim2.fromOffset(14, 31), Size = UDim2.new(1, -90, 0, 16), TextSize = 12, TextColor3 = MUTED, TextTruncate = Enum.TextTruncate.AtEnd, Text = e.desc, Parent = b })
			end
			local switch = make("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(46, 26), BackgroundColor3 = OFF, BorderSizePixel = 0, Parent = b })
			corner(switch, 13)
			local knob = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(20, 20), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = switch })
			corner(knob, 10)
			local state = text({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -66, 0.5, 0), Size = UDim2.fromOffset(34, 20), FontFace = FONT_BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = b })
			local function update()
				local on = values[key] == true
				switch.BackgroundColor3 = if on then BLUE else OFF
				knob.Position = if on then UDim2.new(1, -23, 0.5, 0) else UDim2.new(0, 3, 0.5, 0)
				state.Text = if on then "ON" else "OFF"
				state.TextColor3 = if on then BLUE_HI else MUTED
			end
			b.Activated:Connect(function()
				Settings.set(key, not values[key])
			end)
			api.widgets[key] = update
			api.first = api.first or b
			update()
		end
	end

	-- Reset to defaults
	local reset = rowButton(parent, nextOrder(), 44)
	reset.FontFace = FONT_BOLD
	reset.TextSize = 14
	reset.TextColor3 = MUTED
	reset.Text = "RESET TO DEFAULTS"
	reset.Activated:Connect(Settings.reset)

	function api.refresh()
		for _, update in api.widgets do
			update()
		end
	end
	Settings.Changed:Connect(function(key)
		local update = api.widgets[key]
		if update then
			update()
		end
	end)
	return api
end

return Settings
