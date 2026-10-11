-- War Front Night menu: Settings. Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). Same settings, reads and writes as the old page
-- (MenuPages.renderSettings / renderSettingsTab / renderKeybinds): Settings.values / Settings.set,
-- Settings.DEFAULTS, KeybindData for the Controls tab.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local playerScripts = script.Parent.Parent.Parent
local Settings = require(playerScripts:WaitForChild("Settings"))

local function touchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function percent(v: number): string
	return tostring(math.floor(v + 0.5)) .. "%"
end

local function playSound(name: string)
	pcall(function()
		require(playerScripts:WaitForChild("SoundKit")).play(name)
	end)
end

-- Rebinding state (same as MenuPages.renderKeybinds): one action listens for a key at a time.
local rebinding: { action: string?, conn: RBXScriptConnection?, err: string? } = { action = nil, conn = nil, err = nil }

local function stopRebinding()
	if rebinding.conn then
		rebinding.conn:Disconnect()
	end
	rebinding.action, rebinding.conn = nil, nil
	local ok, KeybindData = pcall(require, playerScripts:WaitForChild("KeybindData"))
	if ok then
		task.defer(function()
			KeybindData.capturing = rebinding.action ~= nil -- let this key press finish first
		end)
	end
end

local function keybindDesc(action: string): string
	local KeybindData = require(playerScripts:WaitForChild("KeybindData"))
	local d = KeybindData.INFO[action].desc
	d = string.gsub(d, "{amount}", tostring(Settings.values.attackRatioIncrement or 10))
	d = string.gsub(d, "{key}", KeybindData.label("resetGfx"))
	return d
end

local TABS = {
	{ "game", "Game", "Flag" },
	{ "sound", "Sound", "Volume" },
	{ "screen", "Screen", "Screen" },
	{ "controls", "Controls", "Keyboard" },
	{ "language", "Language", "Language" },
}

local SOUND_KEYS = { "masterVolume", "effectsVolume", "alertsVolume", "ambienceVolume", "interfaceVolume", "musicVolume", "muted" }

-- Remembered while the menu is open, so coming back opens the same tab.
local lastTab = "game"

local function wrapText(props: { [string]: any }): TextLabel
	props.TextWrapped = true
	props.TextXAlignment = Enum.TextXAlignment.Left
	props.Size = props.Size or UDim2.new(1, 0, 0, 0)
	props.AutomaticSize = Enum.AutomaticSize.Y
	return Kit.text(props)
end

local function smallButton(text: string, order: number, onActivated: () -> ()): TextButton
	return Kit.button("secondary", text, { height = 32, textSize = 14, padX = 12, layoutOrder = order, onActivated = onActivated })
end

-- The language list (also used by the Language page).
local function languageCard(parent: Instance, order: number, onPick: () -> ())
	local holder = make("Frame", { Name = "Languages", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.list(holder, false, 10)
	local b = make("TextButton", {
		Name = "English",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.RAISED,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 64),
		LayoutOrder = 1,
		SelectionImageObject = Kit.ring,
		Parent = holder,
	})
	make("UISizeConstraint", { MaxSize = Vector2.new(320, 64), Parent = b })
	Kit.corner(b, 12)
	Kit.stroke(b, C.YELLOW, 2)
	Kit.pad(b, 14)
	Kit.list(b, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local badge = make("Frame", { BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.fromOffset(40, 40), LayoutOrder = 1, Parent = b })
	Kit.corner(badge, 10)
	Kit.text({ Text = "EN", FontFace = F.TITLE, TextSize = 16, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = badge })
	local col = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 40), LayoutOrder = 2, Parent = b })
	Kit.flex(col)
	Kit.list(col, false, 0, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.text({ Text = "English", FontFace = F.TITLE, TextSize = 18, LayoutOrder = 1, Parent = col })
	Kit.text({ Text = "Selected", FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = col })
	Kit.icon("CheckCircle", { Size = UDim2.fromOffset(24, 24), ImageColor3 = C.YELLOW, LayoutOrder = 3, Parent = b })
	Kit.hover(b, function(state)
		b.BackgroundColor3 = if state == "idle" then C.RAISED else C.RAISED:Lerp(C.WHITE, 0.08)
	end)
	b.Activated:Connect(onPick)
	Kit.text({ Text = "More languages coming soon.", FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = holder })
	return holder
end

local function render(page, ctx)
	local phone = ctx.layout() == "phone"
	local body = page.body
	local widgets: { [string]: (any) -> () } = {} -- key -> refresh(value) for the visible tab
	local tabs = {}
	for _, t in TABS do
		if not (t[1] == "controls" and touchOnly()) then -- no keys to bind on a touch-only device
			table.insert(tabs, t)
		end
	end
	local current = lastTab
	if current == "controls" and touchOnly() then
		current = "game"
	end

	Kit.list(body, phone == false, 16, { VerticalAlignment = Enum.VerticalAlignment.Top })

	-- Navigation: left column on desktop / console, pill tabs on phone.
	local content
	local showTab: (string) -> ()
	local navSet: (string) -> ()
	if phone then
		local strip = make("ScrollingFrame", {
			Name = "TabStrip",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 36),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 0,
			Selectable = false,
			LayoutOrder = 1,
			Parent = body,
		})
		local list = {}
		for _, t in tabs do
			table.insert(list, { t[1], t[2] })
		end
		local row, set = Kit.tabs(list, current, function(key)
			showTab(key)
		end)
		row.Parent = strip
		navSet = set
		content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = body })
	else
		local nav = make("Frame", { Name = "Nav", BackgroundTransparency = 1, Size = UDim2.fromOffset(200, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
		Kit.list(nav, false, 6)
		local buttons = {}
		local function paint()
			for key, b in buttons do
				local on = key == current
				b.BackgroundTransparency = if on then 0 else 1
				local label = b:FindFirstChild("Label") :: TextLabel
				local icon = b:FindFirstChild("Icon") :: ImageLabel
				label.TextColor3 = if on then C.YELLOW else C.MUTED
				icon.ImageColor3 = if on then C.YELLOW else C.MUTED
			end
		end
		for i, t in tabs do
			local b = make("TextButton", {
				Name = "Tab_" .. t[1],
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = C.RAISED,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 44),
				LayoutOrder = i,
				SelectionImageObject = Kit.ring,
				Parent = nav,
			})
			Kit.corner(b, 12)
			Kit.pad(b, 14)
			Kit.list(b, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
			Kit.icon(t[3], { Name = "Icon", Size = UDim2.fromOffset(20, 20), LayoutOrder = 1, Parent = b })
			Kit.text({ Name = "Label", Text = t[2], FontFace = F.TITLE, TextSize = 17, LayoutOrder = 2, Parent = b })
			buttons[t[1]] = b
			Kit.hover(b, function(state)
				if t[1] ~= current then
					b.BackgroundTransparency = if state == "idle" then 1 else 0.6
				end
			end)
			b.Activated:Connect(function()
				if current ~= t[1] then
					showTab(t[1])
				end
			end)
		end
		navSet = function(_key)
			paint()
		end
		paint()
		content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = body })
		Kit.flex(content)
	end
	Kit.list(content, false, 14)

	-- Row builders -------------------------------------------------------------------------------

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local function group(title: string?): Frame
		if title then
			Kit.text({ Text = title, FontFace = F.TITLE, TextSize = 19, LayoutOrder = nextOrder(), Parent = content })
		end
		local card = Kit.card({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = content })
		Kit.pad(card, 18, 18, 4, 4)
		Kit.list(card, false, 0)
		return card
	end

	-- A row: label + optional muted line on the left, `control` on the right.
	local function row(card: Frame, label: string, desc: string?, control: GuiObject?): Frame
		local n = (card:GetAttribute("Rows") or 0) + 1
		card:SetAttribute("Rows", n)
		if n > 1 then
			make("Frame", { Name = "Divider", BackgroundColor3 = C.LINE, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), LayoutOrder = n * 2, Parent = card })
		end
		local r = make("Frame", { Name = label, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = n * 2 + 1, Parent = card })
		Kit.pad(r, 0, 0, 12, 12)
		Kit.list(r, true, 16, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local col = make("Frame", { Name = "Text", BackgroundTransparency = 1, Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = r })
		Kit.flex(col)
		Kit.list(col, false, 3)
		wrapText({ Text = label, FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = col })
		if desc then
			wrapText({ Text = desc, FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = col })
		end
		if control then
			control.LayoutOrder = 2
			control.Parent = r
		end
		return r
	end

	-- boolSetter: Settings.values[key] == true / Settings.set(key, v). `invert` shows the opposite.
	local function toggleRow(card: Frame, key: string, label: string, desc: string?, invert: boolean?)
		local function get(): boolean
			local v = Settings.values[key] == true
			return if invert then not v else v
		end
		local t, set = Kit.toggle(get(), function(on)
			Settings.set(key, if invert then not on else on)
		end)
		widgets[key] = function()
			set(get())
		end
		row(card, label, desc, t)
	end

	-- numSetter: tonumber(Settings.values[key]) or 0 / Settings.set(key, v)
	local function sliderRow(card: Frame, key: string, label: string, desc: string?, min: number, max: number, step: number, fmt: (number) -> string)
		local function get(): number
			return tonumber(Settings.values[key]) or 0
		end
		local box = make("Frame", { Name = "Slider", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X })
		Kit.list(box, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local value = Kit.text({ Name = "Value", Text = fmt(get()), FontFace = F.TITLE, TextSize = 16, TextColor3 = C.CYAN, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(72, 26), LayoutOrder = 1, Parent = box })
		local s, set = Kit.slider(min, max, get(), step, function(v)
			value.Text = fmt(v)
			Settings.set(key, v)
		end)
		s.Size = UDim2.fromOffset(if phone then 150 else 200, 26)
		s.LayoutOrder = 2
		s.Parent = box
		widgets[key] = function()
			set(get())
			value.Text = fmt(get())
		end
		row(card, label, desc, box)
	end

	local function choiceRow(card: Frame, key: string, label: string, desc: string?, options: { any }, get: () -> any, width: number)
		local seg, set = Kit.segmented(options, get(), function(v)
			Settings.set(key, v)
		end, { fill = true })
		seg.Size = UDim2.fromOffset(width, 36)
		widgets[key] = function()
			set(get())
		end
		row(card, label, desc, seg)
	end

	-- Tabs ---------------------------------------------------------------------------------------

	local renderTab: (string) -> ()

	local function renderGame()
		local card = group("Battle")
		local ok, catalog = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("InGameLayoutCatalog"))
		if ok then
			local options = {}
			for _, entry in catalog.entries do
				table.insert(options, { entry.id, entry.label })
			end
			choiceRow(card, "inGameUILayout", "Battle screen layout", "How the buttons and panels are laid out in a battle.", options, function()
				return Settings.values.inGameUILayout
			end, math.max(200, #options * 110))
		end
		sliderRow(card, "attackRatio", "Troops sent per attack", "How many of your troops go in each attack.", 1, 100, 1, percent)
		choiceRow(card, "attackRatioIncrement", "Troop keys step", "How much the troop keys and Shift + wheel change it each time.", { { 1, "1%" }, { 2, "2%" }, { 5, "5%" }, { 10, "10%" }, { 20, "20%" } }, function()
			return tonumber(Settings.values.attackRatioIncrement) or 10
		end, 260)
		sliderRow(card, "nukeAllySafety", "Protect new allies from my bombs", "Holds back a bomb that would hit someone who only just became your ally.", 0, 30, 1, function(v)
			local n = math.floor(v + 0.5)
			if n == 0 then
				return "Off"
			end
			return string.format("%.1fs", n / 10)
		end)
		toggleRow(card, "leftClickMenu", "Left click opens the menu", "On: left click opens the radial menu and the sword attacks. Off: left click attacks.")
		toggleRow(card, "goToPlayer", "Zoom to my land at the start", nil)
		toggleRow(card, "alertFrame", "Flash the screen when attacked", "Red or orange edge when someone attacks or betrays you.")

		card = group("On the map")
		toggleRow(card, "nameLabels", "Show player names on the map", "Names and troop numbers over each country.")
		toggleRow(card, "attackingTroopsOverlay", "Show attacking troop numbers", "Attacker and defender troops where the fighting is.")
		toggleRow(card, "cursorCostLabel", "Show cost next to the cursor", "The price of what you are about to build.")
		toggleRow(card, "boardOpen", "Open the rankings list at the start", "Show the full list of players instead of just its top bar.")
		toggleRow(card, "eventFeed", "Show the message list", "Attacks, alliance asks and chat on the right of the screen.")

		card = group("Privacy")
		toggleRow(card, "anonymousNames", "Hide other players' names", "Shows fake names instead, good for streaming.")
		toggleRow(card, "hiddenLobbyIds", "Hide my battle code", "Keeps your private battle code hidden while you set it up.")
		toggleRow(card, "lobbyStartAlerts", "Play a sound when my battle starts", nil)
	end

	local function renderSound()
		local card = group("Volume")
		sliderRow(card, "masterVolume", "Everything", "Turns every sound below up or down.", 0, 100, 5, percent)
		sliderRow(card, "musicVolume", "Music", "Menu and battle music.", 0, 100, 5, percent)
		sliderRow(card, "effectsVolume", "Explosions and effects", "Building, launches and blasts.", 0, 100, 5, percent)
		sliderRow(card, "alertsVolume", "Warnings", "Incoming bombs, alliance asks and chat pings.", 0, 100, 5, percent)
		sliderRow(card, "ambienceVolume", "Background sounds", "Cities, factories and silos when you zoom in.", 0, 100, 5, percent)
		sliderRow(card, "interfaceVolume", "Button clicks", "Clicks and other menu sounds.", 0, 100, 5, percent)

		card = group("When to stay quiet")
		toggleRow(card, "muted", "Mute everything", nil)
		toggleRow(card, "muteOnBlur", "Mute when I switch windows", "Goes quiet while you use another window.")
		toggleRow(card, "alertsWhenUnfocused", "Still play warnings when muted", "Warnings and alliance asks still play while the game is in the background.")

		-- AudioMixer.previewCue: build-city / nuke-warning / click (same as the old Test buttons).
		local tests = make("Frame", { Name = "Tests", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = content })
		Kit.list(tests, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center, Wraps = true })
		Kit.text({ Text = "Try a sound:", FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, LayoutOrder = 0, Parent = tests })
		for i, t in { { "Effects", "build-city" }, { "Warning", "nuke-warning" }, { "Click", "click" } } do
			local b = smallButton(t[1], i, function()
				playSound(t[2])
			end)
			b.Parent = tests
		end
		local spacer = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 10, Parent = tests })
		Kit.flex(spacer)
		local reset = smallButton("Reset sound", 11, function()
			for _, k in SOUND_KEYS do
				Settings.set(k, Settings.DEFAULTS[k])
			end
		end)
		reset.Parent = tests
	end

	local function renderScreen()
		local card = group("Map")
		toggleRow(card, "terrainShading", "Map shading", "Hills, beaches and deep water. Off: flat land and sea.")
		toggleRow(card, "structureIcons", "Show building icons", "Cities, ports, silos and defenses on the map.")
		toggleRow(card, "borderContrast", "Stronger borders", "Colour-blind friendly colours and a thicker edge around your land.")
		toggleRow(card, "emojis", "Show emojis", nil)

		card = group("Speed and size")
		toggleRow(card, "reducedMotion", "Less motion", "Fewer effects and animations. Can help slower devices.")
		toggleRow(card, "lowDetail", "Low detail mode", "Simpler map that redraws less often. Helps slower devices.")
		sliderRow(card, "uiScale", "UI size", "Makes the battle buttons and panels bigger or smaller.", 80, 130, 5, percent)
		toggleRow(card, "perfOverlay", "Show performance info", "Frame rate and more. F3 in a battle.")
	end

	local function renderControls()
		local ok, KeybindData = pcall(require, playerScripts:WaitForChild("KeybindData"))
		if not ok then
			Kit.text({ Text = "Keys couldn't load. Try again in a moment.", FontFace = F.BOLD, TextColor3 = C.MUTED, LayoutOrder = nextOrder(), Parent = content })
			return
		end
		local function rerender()
			local y = body.CanvasPosition
			renderTab("controls")
			body.CanvasPosition = y
		end
		wrapText({ Text = "Click a key to change it. You can use one key, or Shift + a key. Esc cancels.", FontFace = F.BODY, TextSize = 15, TextColor3 = C.MUTED, LayoutOrder = nextOrder(), Parent = content })
		if rebinding.err then
			wrapText({ Text = rebinding.err, FontFace = F.BOLD, TextSize = 15, TextColor3 = C.PINK, LayoutOrder = nextOrder(), Parent = content })
		end
		for _, section in KeybindData.SECTIONS do
			local card = group(section.title)
			for _, action in section.actions do
				local info = KeybindData.INFO[action]
				local right = make("Frame", { Name = "Keys", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X })
				Kit.list(right, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
				local currentKey = KeybindData.label(action)
				local listening = rebinding.action == action
				local key = make("TextButton", {
					Name = "Key",
					Text = if listening then "Press a key" elseif currentKey == "" then "None" else currentKey,
					FontFace = F.TITLE,
					TextSize = 15,
					TextColor3 = if listening then C.YELLOW_TEXT elseif currentKey == "" then C.MUTED else C.TEXT,
					AutoButtonColor = false,
					BackgroundColor3 = if listening then C.YELLOW else C.DEEP,
					BorderSizePixel = 0,
					Size = UDim2.fromOffset(0, 34),
					AutomaticSize = Enum.AutomaticSize.X,
					LayoutOrder = 1,
					SelectionImageObject = Kit.ring,
					Parent = right,
				})
				make("UISizeConstraint", { MinSize = Vector2.new(70, 34), Parent = key })
				Kit.corner(key, 8)
				Kit.stroke(key, if listening then C.YELLOW_EDGE else C.LINE)
				Kit.pad(key, 12)
				key.Activated:Connect(function()
					stopRebinding()
					rebinding.err = nil
					rebinding.action = action
					KeybindData.capturing = true
					rebinding.conn = UserInputService.InputBegan:Connect(function(input)
						if input.UserInputType ~= Enum.UserInputType.Keyboard then
							return
						end
						local k = input.KeyCode
						if k == Enum.KeyCode.Escape then
							stopRebinding()
							rerender()
							return
						end
						if (k == Enum.KeyCode.LeftShift or k == Enum.KeyCode.RightShift) and not KeybindData.MODIFIERS[action] then
							return -- wait for the key that goes with Shift
						end
						local b = KeybindData.fromInput(input)
						if not b then
							return
						end
						stopRebinding()
						local other = KeybindData.owner(b, action)
						if other then
							rebinding.err = "The key " .. KeybindData.keyName(b) .. " is already used for something else."
							rerender()
							return
						end
						KeybindData.set(action, b)
						rerender()
					end)
					rerender()
				end)
				smallButton("Reset", 2, function()
					stopRebinding()
					rebinding.err = nil
					KeybindData.reset(action)
					rerender()
				end).Parent = right
				smallButton("Unbind", 3, function()
					stopRebinding()
					rebinding.err = nil
					KeybindData.set(action, "Null")
					rerender()
				end).Parent = right
				row(card, info.label, keybindDesc(action), right)
			end
		end
		local foot = make("Frame", { Name = "Footer", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = nextOrder(), Parent = content })
		Kit.list(foot, true, 0, { HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center })
		smallButton("Reset all keys", 1, function()
			stopRebinding()
			rebinding.err = nil
			KeybindData.resetAll()
			rerender()
		end).Parent = foot
	end

	renderTab = function(key: string)
		if key ~= "controls" then
			stopRebinding()
			rebinding.err = nil
		end
		table.clear(widgets)
		for _, c in content:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		order = 0
		if key == "game" then
			renderGame()
		elseif key == "sound" then
			renderSound()
		elseif key == "screen" then
			renderScreen()
		elseif key == "controls" then
			renderControls()
		elseif key == "language" then
			languageCard(content, nextOrder(), function() end)
		end
	end

	showTab = function(key: string)
		current = key
		lastTab = key
		navSet(key)
		body.CanvasPosition = Vector2.zero
		renderTab(key)
	end

	renderTab(current)

	-- Keep rows in step with changes made elsewhere (reset buttons, the in-battle settings).
	local changed = Settings.Changed:Connect(function(key)
		local refresh = widgets[key]
		if refresh then
			refresh()
		end
	end)

	-- "Reset all" in the header (headerRight gets no ctx, so it is wired up here).
	local resetAll = page.header:FindFirstChild("ResetAll")
	if resetAll then
		resetAll.Activated:Connect(function()
			local p
			p = ctx.popup({ width = 380 })
			Kit.list(p.card, false, 14, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
			Kit.text({ Text = "Reset all settings?", FontFace = F.TITLE, TextSize = 22, LayoutOrder = 1, ZIndex = 52, Parent = p.card })
			wrapText({ Text = "Everything goes back to how it was at the start, including your keys.", FontFace = F.BODY, TextSize = 15, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, ZIndex = 52, Parent = p.card })
			local buttons = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 3, ZIndex = 52, Parent = p.card })
			Kit.list(buttons, true, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
			Kit.button("secondary", "Cancel", { layoutOrder = 1, parent = buttons, onActivated = function()
				p.close()
			end })
			Kit.button("primary", "Reset", { layoutOrder = 2, parent = buttons, onActivated = function()
				p.close()
				stopRebinding()
				rebinding.err = nil
				-- Settings.reset() minus the player's chosen name (set on the profile page, not here).
				for k, d in Settings.DEFAULTS do
					if k ~= "playerName" then
						Settings.set(k, d)
					end
				end
				renderTab(current)
				ctx.toast("Settings reset", "ok")
			end })
		end)
	end

	return function()
		changed:Disconnect()
		stopRebinding()
		rebinding.err = nil
	end
end

return {
	title = "Settings",
	headerRight = function()
		return Kit.button("ghost", "Reset all", { name = "ResetAll", icon = "Refresh", height = 38, textSize = 16 })
	end,
	render = render,
	languageCard = languageCard,
}
