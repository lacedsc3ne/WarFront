--[[
	War Front - the main menu's inline pages (settings, help, release notes, language, profile,
	inventory, leaderboard, clans).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Layout and English text follow OpenFront's UserSettingModal.ts, HelpModal.ts, NewsModal.ts,
	LanguageModal.ts, PlayerProfileModal.ts, InventoryModal.ts, LeaderboardModal.ts, ClanModal.ts
	and resources/lang/en.json (AGPL-3.0). Modified version re-implemented in Luau for Roblox;
	not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MenuPages (ModuleScript), used by MainMenu.
-- MenuPages.TITLES[kind]                       page title (kind = "settings" | "help" | "news" |
--                                              "language" | "profile" | "inventory" |
--                                              "leaderboard" | "clans" | "store")
-- MenuPages.render(kind, page, ctx)            fills a MenuKit page
--   ctx.toast(msg), ctx.startTutorial(), ctx.getProfile() -> profile?, ctx.close()
-- Settings are read/written through Settings.values / Settings.set (the same store the in-match
-- settings use), so both stay in sync.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local FlagKit = require(script.Parent:WaitForChild("FlagKit"))
local MapCatalog = require(Shared:WaitForChild("MapCatalog"))

local C, F = MenuKit.C, MenuKit.F
local make = MenuKit.make
local localPlayer = Players.LocalPlayer

local MenuPages = {}

MenuPages.TITLES = {
	settings = "Settings", -- user_setting.title
	help = "Help", -- main.help
	news = "Release Notes", -- news.title
	language = "Select Language", -- select_lang.title
	profile = "Player Profile", -- player_profile.title
	inventory = "Inventory", -- inventory.title
	leaderboard = "Leaderboard", -- main.leaderboard
	clans = "Clans", -- main.clans
	store = "Store", -- store.title
}

local function touchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

-- Settings (UserSettingModal: tabs Gameplay / Graphics / Audio / Keybinds)
local function boolSetter(key: string)
	return function(): boolean
		return Settings.values[key] == true
	end, function(v: boolean)
		Settings.set(key, v)
	end
end

local function numSetter(key: string)
	return function(): number
		return tonumber(Settings.values[key]) or 0
	end, function(v: number)
		Settings.set(key, v)
	end
end

local function percent(v: number): string
	return tostring(math.floor(v + 0.5)) .. "%"
end

local KEYBINDS = {
	{ "Build City", "Build a City under your cursor.", "1" },
	{ "Build Port", "Build a Port under your cursor.", "3" },
	{ "Build Defense Post", "Build a Defense Post under your cursor.", "4" },
	{ "Build Missile Silo", "Build a Missile Silo under your cursor.", "5" },
	{ "Build SAM Launcher", "Build a SAM Launcher under your cursor.", "6" },
	{ "Build Warship", "Build a Warship under your cursor.", "7" },
	{ "Build Atom Bomb", "Build an Atom Bomb under your cursor.", "8" },
	{ "Build Hydrogen Bomb", "Build a Hydrogen Bomb under your cursor.", "9" },
	{ "Boat Attack", "Send a boat attack to the tile under your cursor.", "B" },
	{ "Ground Attack", "Send a ground attack to the tile under your cursor.", "G" },
	{ "Retaliate", "Send a retaliation attack to blunt/negate the force of the most recent active attacker. Only available when you are being attacked.", "Shift + R" },
	{ "Request Alliance", "Send an alliance request to the player whose tile is under your cursor.", "K" },
	{ "Break Alliance (Betray)", "Break alliance with the player whose tile is under your cursor.", "L" },
	{ "Decrease Attack Ratio", "Decrease attack ratio by 10%", "T" },
	{ "Increase Attack Ratio", "Increase attack ratio by 10%", "Y" },
	{ "Center Camera", "Center camera on player", "C" },
	{ "Zoom Out", "Zoom out the map", "Q" },
	{ "Zoom In", "Zoom in the map", "E" },
	{ "Move Camera", "Move the camera", "W A S D" },
}

local function renderSettingsTab(page: any, tab: string)
	page:clear()
	local body = page.body
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	if tab == "gameplay" then
		local g, s = boolSetter("boardOpen")
		MenuKit.toggleRow(body, nextOrder(), "Leaderboard open by default", "Show the full leaderboard table instead of just its header.", g, s)
		g, s = boolSetter("eventFeed")
		MenuKit.toggleRow(body, nextOrder(), "Event feed", "Show the latest events, requests and Quick Chat messages on the right side of the screen.", g, s)
		g, s = boolSetter("nameLabels")
		MenuKit.toggleRow(body, nextOrder(), "Name labels", "Player names and troop counts over territories.", g, s)
		g, s = boolSetter("attackingTroopsOverlay")
		MenuKit.toggleRow(body, nextOrder(), "Attacking Troops Overlay", "Show attacker vs defender troop counts on active front lines.", g, s)
		g, s = boolSetter("cursorCostLabel")
		MenuKit.toggleRow(body, nextOrder(), "Cursor Build Cost", "Show a cost pill under the build cursor icon", g, s)
	elseif tab == "graphics" then
		local g, s = boolSetter("terrainShading")
		MenuKit.toggleRow(body, nextOrder(), "Terrain shading", "Coloured hills, beaches and deep water. Off: flat land and water.", g, s)
		g, s = boolSetter("structureIcons")
		MenuKit.toggleRow(body, nextOrder(), "Structure icons", "Cities, ports, silos and defences on the map.", g, s)
		g, s = boolSetter("borderContrast")
		MenuKit.toggleRow(body, nextOrder(), "Colour-blind mode", "Colour-blind player palette and a thicker border around your land.", g, s)
		-- user_setting.special_effects_*: on = effects shown (our reducedMotion off).
		MenuKit.toggleRow(body, nextOrder(), "Special effects", "Toggle special effects. Deactivate to improve performances", function()
			return Settings.values.reducedMotion ~= true
		end, function(v)
			Settings.set("reducedMotion", not v)
		end)
		g, s = boolSetter("lowDetail")
		MenuKit.toggleRow(body, nextOrder(), "Low detail", "Map drawn at 1 pixel per tile and redrawn less often. Helps slower devices.", g, s)
		local gn, sn = numSetter("uiScale")
		MenuKit.sliderRow(body, nextOrder(), "UI scale", "Makes the in-game HUD larger or smaller.", 80, 130, 5, gn, sn, percent)
	elseif tab == "audio" then
		local refreshers = {}
		local gn, sn = numSetter("masterVolume")
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, nextOrder(), "Master Volume", "Overall volume for everything below.", 0, 100, 5, gn, sn, percent)
		gn, sn = numSetter("musicVolume")
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, nextOrder(), "Music", "The menu theme and the in-game soundtrack.", 0, 100, 5, gn, sn, percent)
		gn, sn = numSetter("effectsVolume")
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, nextOrder(), "Sound Effects", "Builds, launches, impacts and end-of-game stings.", 0, 100, 5, gn, sn, percent)
		gn, sn = numSetter("alertsVolume")
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, nextOrder(), "Alerts & Notifications", "Incoming nuke warnings, alliance requests and chat pings.", 0, 100, 5, gn, sn, percent)
		gn, sn = numSetter("ambienceVolume")
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, nextOrder(), "Ambience", "Background loops from cities, factories and silos you zoom in on.", 0, 100, 5, gn, sn, percent)
		gn, sn = numSetter("interfaceVolume")
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, nextOrder(), "Interface", "Clicks, ticks and other menu sounds.", 0, 100, 5, gn, sn, percent)
		local g, s = boolSetter("muted")
		refreshers[#refreshers + 1] = MenuKit.toggleRow(body, nextOrder(), "Mute all", "Silence every sound.", g, s)
		local row = make("Frame", { LayoutOrder = nextOrder(), BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = body })
		local reset = MenuKit.button("gray", {
			Name = "AudioReset",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 32),
			TextSize = 14,
			Text = "Reset to defaults",
			Parent = row,
		})
		reset.BackgroundTransparency = 0.95
		reset.BackgroundColor3 = C.WHITE
		MenuKit.stroke(reset, 0.9)
		MenuKit.pad(reset, 12, 12, 0, 0)
		reset.Activated:Connect(function()
			Settings.set("masterVolume", Settings.DEFAULTS.masterVolume)
			Settings.set("effectsVolume", Settings.DEFAULTS.effectsVolume)
			Settings.set("alertsVolume", Settings.DEFAULTS.alertsVolume)
			Settings.set("ambienceVolume", Settings.DEFAULTS.ambienceVolume)
			Settings.set("interfaceVolume", Settings.DEFAULTS.interfaceVolume)
			Settings.set("musicVolume", Settings.DEFAULTS.musicVolume)
			Settings.set("muted", Settings.DEFAULTS.muted)
			for _, r in refreshers do
				r()
			end
		end)
	elseif tab == "keybinds" then
		MenuKit.paragraph(body, nextOrder(), "Default OpenFront keybinds. Rebinding is not available yet.", { TextColor3 = C.WHITE, TextTransparency = 0.5 })
		for _, k in KEYBINDS do
			local card = make("Frame", { LayoutOrder = nextOrder(), BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
			MenuKit.corner(card, 12)
			MenuKit.stroke(card, 0.9)
			MenuKit.pad(card, 16, 16, 14, 14)
			local col = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -120, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card })
			MenuKit.list(col, false, 4)
			MenuKit.paragraph(col, 1, k[1], { FontFace = F.BOLD, TextSize = 16, TextColor3 = C.WHITE })
			MenuKit.paragraph(col, 2, k[2], { TextSize = 14, TextColor3 = C.WHITE, TextTransparency = 0.5 })
			local key = MenuKit.keycap(card, k[3])
			key.AnchorPoint = Vector2.new(1, 0.5)
			key.Position = UDim2.fromScale(1, 0.5)
		end
	end
end

local function renderSettings(page: any)
	local tabs = {
		{ key = "gameplay", label = "Gameplay" },
		{ key = "graphics", label = "Graphics" },
		{ key = "audio", label = "Audio" },
	}
	-- Keybinds is about having keys: a touch-only device doesn't get the tab (as in OpenFront).
	if not touchOnly() then
		tabs[#tabs + 1] = { key = "keybinds", label = "Keybinds" }
	end
	page:setTabs(tabs, "gameplay", function(key)
		renderSettingsTab(page, key)
	end)
end

-- Help (HelpModal)
local HOTKEYS = {
	{ "Esc", "Closes menu. Cancels unit build preview." },
	{ "Space (hold)", "Alternate view" },
	{ "M", "Coordinate grid" },
	{ "1 - 9", "Build the unit under the cursor (City 1, Port 3, Defense Post 4, Missile Silo 5, SAM 6, Warship 7, Atom Bomb 8, Hydrogen Bomb 9)" },
	{ "B", "Send a boat attack to the tile under your cursor." },
	{ "G", "Send a ground attack to the tile under your cursor." },
	{ "Shift + R", "Retaliate against the most recent active attacker." },
	{ "K", "Send an alliance request to the player whose tile is under your cursor." },
	{ "L", "Break alliance with the player whose tile is under your cursor." },
	{ "C", "Center camera on player" },
	{ "Q / E", "Zoom out/in" },
	{ "W A S D", "Move camera" },
	{ "T / Y", "Decrease/Increase attack ratio" },
	{ "Shift + Wheel", "Decrease/Increase attack ratio" },
}

local PAD_KEYS = {
	{ "Left stick", "Move the cursor" },
	{ "Right stick", "Move camera" },
	{ "LT / RT", "Zoom out/in" },
	{ "A", "Attack / build at the cursor" },
	{ "X", "Open the radial menu" },
	{ "B", "Closes menu. Cancels unit build preview." },
	{ "LB / RB", "Decrease/Increase attack ratio" },
	{ "D-pad", "Choose a build action" },
	{ "View", "Opens the menu" },
	{ "R3", "Fit the map to the screen" },
}

local TOUCH_KEYS = {
	{ "Tap", "Pick your start, attack or expand into a tile, place the selected building" },
	{ "Hold", "Open the radial menu (tap its centre to attack)" },
	{ "Drag", "Move camera" },
	{ "Pinch", "Zoom out/in" },
	{ "Build bar", "Tap a building or bomb, then tap the map. Tap it again to cancel" },
	{ "Ratio slider", "Choose how many troops each attack sends" },
}

local function keyTable(parent: Instance, order: number, rows: { { string } })
	local box = make("Frame", { LayoutOrder = order, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	MenuKit.corner(box, 12)
	MenuKit.stroke(box, 0.9)
	MenuKit.pad(box, 16, 16, 8, 16)
	MenuKit.list(box, false, 0)
	local head = make("Frame", { LayoutOrder = 0, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = box })
	MenuKit.text({ Size = UDim2.fromOffset(120, 28), FontFace = F.BOLD, TextSize = 12, TextTransparency = 0.6, TextXAlignment = Enum.TextXAlignment.Left, Text = "KEY", Parent = head })
	MenuKit.text({ Position = UDim2.fromOffset(150, 0), Size = UDim2.new(1, -150, 0, 28), FontFace = F.BOLD, TextSize = 12, TextTransparency = 0.6, TextXAlignment = Enum.TextXAlignment.Left, Text = "ACTION", Parent = head })
	for i, r in rows do
		local row = make("Frame", { LayoutOrder = i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = box })
		MenuKit.pad(row, 0, 0, 12, 12)
		local k = MenuKit.keycap(row, r[1])
		k.Position = UDim2.fromOffset(0, 0)
		MenuKit.paragraph(row, 0, r[2], { Position = UDim2.fromOffset(150, 2), Size = UDim2.new(1, -150, 0, 0), TextColor3 = C.WHITE, TextTransparency = 0.3 })
	end
end

local function subTitle(parent: Instance, order: number, str: string)
	MenuKit.paragraph(parent, order, str, { FontFace = F.SEMIBOLD, TextSize = 18, TextColor3 = C.BLUE100 })
end

local function bullets(parent: Instance, order: number, items: { string })
	local f = make("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	MenuKit.list(f, false, 4)
	for i, s in items do
		local p = MenuKit.paragraph(f, i, "•  " .. s)
		MenuKit.pad(p, 20, 0, 0, 0)
	end
end

-- Row with an icon then a description (HelpModal's radial / info / player-icon lists).
local function iconLine(parent: Instance, order: number, iconName: string, str: string, fromIconKit: boolean?)
	local row = make("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	if fromIconKit then
		IconKit.image(iconName, { Size = UDim2.fromOffset(28, 28), Parent = row })
	else
		MenuKit.icon(iconName, { Size = UDim2.fromOffset(28, 28), Parent = row })
	end
	MenuKit.paragraph(row, 0, str, { Position = UDim2.fromOffset(40, 4), Size = UDim2.new(1, -40, 0, 0) })
	make("UISizeConstraint", { MinSize = Vector2.new(0, 28), Parent = row })
end

local BUILDINGS = {
	{ "City", "City", "Increases your max population. Useful when you can't expand your territory or you're about to hit your population limit." },
	{ "Defense Post", "Defense", "Increases defenses around nearby borders, which show a checkered pattern. Attacks from enemies are slower and have more casualties." },
	{ "Port", "Port", "Can only be built near water. Allows building Warships. Automatically sends trade ships between ports of your country and other countries (except when trade is stopped), giving gold to both sides." },
	{ "Factory", "Factory", "Automatically builds railroads to nearby cities, ports and other factories, and can also link up with friendly neighbors. Trains spawn regularly and give you a fixed amount of gold for each building they visit along the route, with extra gold for visiting your neighbors' buildings." },
	{ "Warship", "Warship", "Patrols in an area, capturing enemy trade ships and destroying their Boats (transport ships) and Warships. Spawns from the nearest Port and patrols the area you first clicked to build it." },
	{ "Missile Silo", "Silo", "Allows launching missiles." },
	{ "SAM Launcher", "SAM", "Can intercept enemy missiles in its range. The SAM has a 7.5 second cooldown." },
	{ "Atom Bomb", "AtomBomb", "Small explosive bomb that destroys territory, buildings, ships and boats. Spawns from the nearest Missile Silo and lands in the area you first clicked to build it." },
	{ "Hydrogen Bomb", "HBomb", "Large explosive bomb. Spawns from the nearest Missile Silo and lands in the area you first clicked to build it." },
	{ "MIRV", "MIRV", "The most powerful bomb in the game. Splits up into smaller bombs that will cover a huge range of territory. Only damages the player that you first clicked on to build it." },
}

local function renderHelp(page: any, ctx: any)
	page:setTabs({})
	page:clear()
	local body = page.body
	local o = 0
	local function n(): number
		o += 1
		return o
	end
	local Icons = require(Shared:WaitForChild("Icons"))

	-- In-game tutorial card.
	local tut = MenuKit.card(body, n(), 20, 16, 12)
	MenuKit.paragraph(tut, 1, "In-Game Tutorial", { FontFace = F.SEMIBOLD, TextSize = 18, TextColor3 = C.BLUE100 })
	MenuKit.paragraph(tut, 2, "Learn by playing: join a game with a step-by-step guide that walks you through spawning, attacking, building and nukes.", { TextSize = 14 })
	local start = MenuKit.button("accent", { Name = "StartTutorial", LayoutOrder = 3, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 34), FontFace = F.BOLD, TextSize = 12, Text = "START TUTORIAL", Parent = tut })
	MenuKit.pad(start, 24, 24, 0, 0)
	start.Activated:Connect(ctx.startTutorial)

	MenuKit.heading(body, n(), "Keyboard", "Hotkeys")
	keyTable(body, n(), HOTKEYS)
	MenuKit.heading(body, n(), "Keyboard", "Controller")
	keyTable(body, n(), PAD_KEYS)
	if UserInputService.TouchEnabled then
		MenuKit.heading(body, n(), "Keyboard", "Touch")
		keyTable(body, n(), TOUCH_KEYS)
	end

	MenuKit.heading(body, n(), "Layout", "Game UI")
	subTitle(body, n(), "Leaderboard")
	MenuKit.paragraph(body, n(), "Shows the top players of the game and their names, % owned land, gold and troops. Using Show All shows all players in the game. If you don't want to see the leaderboard, click Hide.")
	subTitle(body, n(), "Control panel")
	MenuKit.paragraph(body, n(), "The control panel contains the following elements:")
	bullets(body, n(), {
		"Gold - The amount of gold you have and the rate at which you gain it.",
		"Attack ratio - The amount of troops that will be used when you attack. You can adjust the attack ratio using the slider. Having more attacking troops than defending troops will make you lose fewer troops in the attack, while having less will increase the damage dealt to your attacking troops. The effect doesn't go beyond ratios of 2:1.",
	})
	subTitle(body, n(), "Event panel")
	MenuKit.paragraph(body, n(), "The Event panel displays the latest events, requests and Quick Chat messages. Some examples are:")
	bullets(body, n(), {
		"Alliance - Alliance requests can be accepted or rejected. Allies can share resources and troops, but can't attack each other. Clicking Focus moves the view to the player who sent the request.",
		"Attacks - Incoming attacks and your outgoing attacks are shown. Click the message to center the view on the attack, nuke or Boat (transport ship). You can retreat troops by clicking the red X button. This will cost the lives of 25% of your attacking troops. Nukes can't be retreated once launched.",
		"Quick Chat - You can see sent and received chat messages here. Send a message to a player by clicking the Quick Chat icon in their Info menu.",
	})
	subTitle(body, n(), "Options")
	MenuKit.paragraph(body, n(), "The following elements can be found inside:")
	bullets(body, n(), {
		"Timer - Time passed since the start of the game.",
		"Settings - Open the settings menu.",
		"Exit button.",
	})
	subTitle(body, n(), "Player info overlay")
	MenuKit.paragraph(body, n(), "When you hover over a country, the Player info overlay appears. It shows the player type (Human, Nation, or Tribe), a Nation's attitude toward you (Hostile to Friendly), defending troops, gold, and the number of Warships and buildings they have.")

	MenuKit.heading(body, n(), "Radial", "Radial menu")
	MenuKit.paragraph(body, n(), "Right clicking (long-press on touch, X on a controller) opens the Radial menu. Right click outside it to close it. From the menu you can:")
	iconLine(body, n(), "Build", "Open the Build menu.", true)
	iconLine(body, n(), "Info", "Open the Info menu.", true)
	iconLine(body, n(), "Boat", "Send a Boat (transport ship) to attack at the selected location. Only available if you have access to water.", true)
	iconLine(body, n(), "Alliance", "Send an alliance request to the player. Allies can share resources and troops, but can't attack each other.", true)
	iconLine(body, n(), "DonateTroops", "Donate troops equivalent to your attack ratio slider percentage to the ally you opened the radial menu on.", true)
	iconLine(body, n(), "DonateGold", "Opens the gold donation slider menu so you can quickly send allies gold.", true)

	MenuKit.heading(body, n(), "Info", "Info menu")
	subTitle(body, n(), "Enemy info panel")
	MenuKit.paragraph(body, n(), "Contains information such as the selected player's name, gold, troops, stopped trading with you, nukes sent to you, and if the player is a traitor. The icons below represent the following interactions:")
	iconLine(body, n(), "Target", "Place a target mark on the player, marking it for all allies, used to coordinate attacks.", true)
	iconLine(body, n(), "Alliance", "Send an alliance request to the player. Allies can share resources and troops, but can't attack each other.", true)
	iconLine(body, n(), "Emoji", "Send an emoji to the player.", true)
	iconLine(body, n(), "Embargo", "Use \"Stop trading\" to stop giving the player gold and receiving their gold via trade ships. If you both click \"Start trading\" it will start again.", true)
	subTitle(body, n(), "Ally info panel")
	MenuKit.paragraph(body, n(), "When you ally with a player, the following new icons become available:")
	iconLine(body, n(), "Traitor", "Betray your ally, ending the alliance, halting trade, and weakening your defense. Unless the other player was a traitor themselves, you'll be marked a traitor for 30 seconds with a 50% defense debuff.", true)
	iconLine(body, n(), "DonateTroops", "Donate some of your troops to your ally. Used when they're low on troops and are being attacked, or when they need that extra power to crush an enemy.", true)
	iconLine(body, n(), "DonateGold", "Donate some of your gold to your ally. Used when they're low on gold and need it for buildings, or when your team member is saving for that MIRV.", true)

	MenuKit.heading(body, n(), "Building", "Build menu")
	MenuKit.paragraph(body, n(), "Build these or see how many of each you already build:")
	local tbl = MenuKit.card(body, n(), 16, 8, 0)
	for i, b in BUILDINGS do
		if Icons.has(b[2]) then
			local row = make("Frame", { LayoutOrder = i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = tbl })
			MenuKit.pad(row, 0, 0, 10, 10)
			MenuKit.text({ Size = UDim2.fromOffset(120, 28), FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, Text = b[1], Parent = row })
			IconKit.image(b[2], { Position = UDim2.fromOffset(128, 0), Size = UDim2.fromOffset(28, 28), Parent = row })
			MenuKit.paragraph(row, 0, b[3], { Position = UDim2.fromOffset(170, 2), Size = UDim2.new(1, -170, 0, 0), TextSize = 13 })
		end
	end

	MenuKit.heading(body, n(), "User", "Player icons")
	MenuKit.paragraph(body, n(), "Examples of some of the ingame icons you will encounter and what they mean:")
	iconLine(body, n(), "Crown", "Crown - Number 1. This is the top player in the leaderboard.", true)
	iconLine(body, n(), "Traitor", "Broken shield - Traitor. This player attacked an ally.", true)
	iconLine(body, n(), "Alliance", "Handshake - Ally. This player is your ally.", true)
	iconLine(body, n(), "Embargo", "Dollar stop sign - Embargo. This player has stopped trading with you automatically or manually.", true)
	if Icons.has("AllianceRequest") then
		iconLine(body, n(), "AllianceRequest", "Envelope - Alliance request. This player has sent you an alliance request.", true)
	end
end

-- Release notes (NewsModal renders changelog.md: h1 / h2 / bullets)
local CHANGELOG = {
	{ "h1", "War Front Changelog" },
	{ "p", "War Front is a Roblox port of OpenFront. These notes list what has been ported so far." },
	{ "h2", "Major Features" },
	{ "li", "Main menu rebuilt to match the OpenFront home screen: nav bar, news, upcoming games and pages for settings, help and release notes." },
	{ "li", "Map voting between rounds - pick the next map from the Upcoming column." },
	{ "li", "Alliances, betrayal, embargoes, targets, emojis and quick chat." },
	{ "li", "Warships, transport boats, trade ships, nukes, SAM launchers and missile silos." },
	{ "li", "Structure upgrades and the Factory with trains and railroads." },
	{ "h2", "Game Improvements" },
	{ "li", "Map renderer with OpenFront's terrain colours, borders, name labels and flags." },
	{ "li", "Radial menu, player panel, build menu and keyboard shortcuts from OpenFront." },
	{ "li", "Controller and touch support for every menu." },
	{ "h2", "Known Limitations" },
	{ "li", "Matchmaking (Create Lobby, Ranked, Join Lobby), clans, global leaderboards and cosmetics are coming soon." },
}

local function renderNews(page: any)
	page:setTabs({})
	page:clear()
	for i, line in CHANGELOG do
		local kind, s = line[1], line[2]
		if kind == "h1" then
			MenuKit.paragraph(page.body, i, s, { FontFace = F.BOLD, TextSize = 24, TextColor3 = C.WHITE })
			make("Frame", { LayoutOrder = i, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = page.body })
		elseif kind == "h2" then
			local h = MenuKit.paragraph(page.body, i, s, { FontFace = F.BOLD, TextSize = 20, TextColor3 = C.BLUE200 })
			MenuKit.pad(h, 0, 0, 16, 4)
		elseif kind == "li" then
			local p = MenuKit.paragraph(page.body, i, "•  " .. s)
			MenuKit.pad(p, 20, 0, 0, 0)
		else
			MenuKit.paragraph(page.body, i, s)
		end
	end
end

-- Language (LanguageModal: grid of flag + native + English name; English only here)
local function renderLanguage(page: any, ctx: any)
	page:setTabs({})
	page:clear()
	local b = make("TextButton", {
		Name = "en",
		LayoutOrder = 1,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.MALIBU,
		BackgroundTransparency = 0.8,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 60),
		Parent = page.body,
	})
	MenuKit.corner(b, 12)
	MenuKit.stroke(b, 0.5, C.MALIBU)
	make("UISizeConstraint", { MaxSize = Vector2.new(260, 60), Parent = b })
	MenuKit.icon("LangFlag", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(32, 24), Parent = b })
	MenuKit.text({ Position = UDim2.fromOffset(56, 12), Size = UDim2.new(1, -96, 0, 18), FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Text = "ENGLISH", Parent = b })
	MenuKit.text({ Position = UDim2.fromOffset(56, 32), Size = UDim2.new(1, -96, 0, 14), TextSize = 12, TextTransparency = 0.6, TextXAlignment = Enum.TextXAlignment.Left, Text = "ENGLISH", Parent = b })
	MenuKit.icon("CheckCircle", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(20, 20), ImageColor3 = C.BLUE400, Parent = b })
	b.Activated:Connect(ctx.close)
	MenuKit.paragraph(page.body, 2, "More languages coming soon.", { TextColor3 = C.WHITE, TextTransparency = 0.6 })
end

-- Player profile (PlayerProfileModal: tabs Stats / Games / Clans)
local function statCard(parent: Instance, order: number, label: string, value: string)
	local c = make("Frame", { LayoutOrder = order, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Parent = parent })
	MenuKit.corner(c, 12)
	MenuKit.stroke(c, 0.9)
	MenuKit.text({ Position = UDim2.fromOffset(16, 14), Size = UDim2.new(1, -32, 0, 16), FontFace = F.BOLD, TextSize = 12, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, Text = string.upper(label), Parent = c })
	MenuKit.text({ Position = UDim2.fromOffset(16, 36), Size = UDim2.new(1, -32, 0, 30), FontFace = F.BOLD, TextSize = 26, TextXAlignment = Enum.TextXAlignment.Left, Text = value, Parent = c })
end

local function renderProfileTab(page: any, ctx: any, tab: string)
	page:clear()
	local body = page.body
	-- Identity strip: avatar, display name, level.
	local head = make("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64), Parent = body })
	local av = make("ImageLabel", { Size = UDim2.fromOffset(56, 56), Position = UDim2.fromOffset(0, 4), BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = head })
	MenuKit.round(av)
	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(localPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and av.Parent then
			av.Image = url
		end
	end)
	local profile = ctx.getProfile()
	MenuKit.text({ Position = UDim2.fromOffset(72, 8), Size = UDim2.new(1, -72, 0, 28), FontFace = F.BOLD, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = localPlayer.DisplayName, Parent = head })
	MenuKit.text({ Position = UDim2.fromOffset(72, 38), Size = UDim2.new(1, -72, 0, 18), TextSize = 14, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, Text = "@" .. localPlayer.Name .. (if profile then "  ·  Level " .. tostring(profile.level or 1) else ""), Parent = head })

	if tab == "stats" then
		if not profile or (tonumber(profile.games) or 0) == 0 then
			MenuKit.paragraph(body, 2, "No stats available yet. Play some games to start tracking.", { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.WHITE, TextTransparency = 0.6 })
			if not profile then
				return
			end
		end
		local grid = make("Frame", { LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
		local layout = make("UIGridLayout", { CellPadding = UDim2.fromOffset(12, 12), CellSize = UDim2.new(1 / 3, -8, 0, 84), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
		local function fitGrid()
			local w = grid.AbsoluteSize.X
			local cols = if w < 360 then 1 elseif w < 560 then 2 else 3
			layout.CellSize = UDim2.new(1 / cols, -(12 * (cols - 1)) / cols, 0, 84)
		end
		grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitGrid)
		fitGrid()
		local games, wins = tonumber(profile.games) or 0, tonumber(profile.wins) or 0
		local rows = {
			{ "Games played", numberText(games) },
			{ "Wins", numberText(wins) },
			{ "Win rate", if games > 0 then string.format("%.0f%%", wins / games * 100) else "-" },
			{ "Players eliminated", numberText(profile.eliminations) },
			{ "Level", tostring(profile.level or 1) },
			{ "Daily streak", tostring(profile.streak or 0) },
		}
		for i, r in rows do
			statCard(grid, i, r[1], r[2])
		end
	else
		MenuKit.comingSoon(body, 2, if tab == "games" then "PlayTri" else "People", if tab == "games" then "Game history needs OpenFront's account servers." else "Clans need OpenFront's account servers.")
	end
end

local function renderProfile(page: any, ctx: any)
	page:setTabs({
		{ key = "stats", label = "Stats" },
		{ key = "games", label = "Games" },
		{ key = "clans", label = "Clans" },
	}, "stats", function(key)
		renderProfileTab(page, ctx, key)
	end)
end

-- Inventory (skins / territory patterns, flags, crowns, effects): locked, coming soon
local function lockedTile(parent: Instance, order: number, fill: (Frame) -> ())
	local t = make("TextButton", { LayoutOrder = order, Text = "", AutoButtonColor = false, BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = parent })
	MenuKit.corner(t, 12)
	local st = MenuKit.stroke(t, 0.9)
	MenuKit.hover(t, function(s)
		st.Color = if s == "idle" then C.WHITE else C.MALIBU
		st.Transparency = if s == "idle" then 0.9 else 0
	end)
	local art = make("Frame", { Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 1, -40), BackgroundTransparency = 1, ClipsDescendants = true, Parent = t })
	MenuKit.corner(art, 8)
	fill(art)
	local shade = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.BLACK, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = art })
	MenuKit.corner(shade, 8)
	MenuKit.icon("Lock", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), ImageTransparency = 0.2, Parent = shade })
	MenuKit.text({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -8), Size = UDim2.new(1, 0, 0, 16), FontFace = F.BOLD, TextSize = 11, TextTransparency = 0.4, Text = "COMING SOON", Parent = t })
	return t
end

local PATTERN_COLORS = {
	{ 0x0084d1, 0x3fa9f5 },
	{ 0xef4444, 0xfca5a5 },
	{ 0x10b981, 0x6ee7b7 },
	{ 0xf59e0b, 0xfcd34d },
	{ 0x8b5cf6, 0xc4b5fd },
	{ 0xec4899, 0xf9a8d4 },
	{ 0x64748b, 0xcbd5e1 },
	{ 0x0ea5e9, 0x0a1628 },
}

local function renderInventoryTab(page: any, ctx: any, tab: string)
	page:clear()
	local body = page.body
	MenuKit.paragraph(body, 1, "Cosmetics are coming soon. Your territory colour can be picked in the Store.", { TextColor3 = C.WHITE, TextTransparency = 0.5 })
	local grid = make("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
	make("UIGridLayout", { CellPadding = UDim2.fromOffset(12, 12), CellSize = UDim2.fromOffset(128, 128), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local function onTap()
		ctx.toast("Coming Soon")
	end
	if tab == "skins" then
		-- Territory patterns: two-tone checker previews of how a pattern fills your land.
		for i, pc in PATTERN_COLORS do
			local t = lockedTile(grid, i, function(art)
				art.BackgroundTransparency = 0
				art.BackgroundColor3 = Color3.fromHex(string.format("%06x", pc[1]))
				for y = 0, 5 do
					for x = 0, 5 do
						if (x + y + i) % 2 == 0 then
							make("Frame", { Position = UDim2.fromScale(x / 6, y / 6), Size = UDim2.fromScale(1 / 6, 1 / 6), BackgroundColor3 = Color3.fromHex(string.format("%06x", pc[2])), BorderSizePixel = 0, Parent = art })
						end
					end
				end
			end)
			t.Activated:Connect(onTap)
		end
	elseif tab == "flags" then
		local shown = 0
		local seen = {}
		for _, m in MapCatalog do
			for _, nation in m.nations or {} do
				local code = nation[4]
				if shown < 12 and type(code) == "string" and code ~= "" and not seen[code] and FlagKit.has(code) then
					seen[code] = true
					shown += 1
					local t = lockedTile(grid, shown, function(art)
						FlagKit.image(code, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.9, 0.9), Parent = art })
					end)
					t.Activated:Connect(onTap)
				end
			end
		end
	else
		MenuKit.comingSoon(body, 3, if tab == "crowns" then "User" else "Radial")
	end
end

local function renderInventory(page: any, ctx: any)
	page:setTabs({
		{ key = "skins", label = "Skins" },
		{ key = "flags", label = "Flags" },
		{ key = "crowns", label = "Crowns" },
		{ key = "effects", label = "Effects" },
	}, "skins", function(key)
		renderInventoryTab(page, ctx, key)
	end)
end

-- Store (Store.ts layout: modalHeader with the currency on the right, tab strip, grid of
-- cosmetic cards with a full-width action; owned = emerald status box). Our store sells
-- territory colours for coins, passes and coin packs (MetaConfig); purchases go through
-- Shared.MetaFn like MetaClient did.
local MarketplaceService = game:GetService("MarketplaceService")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))
local metaFn = Shared:WaitForChild("MetaFn")
local metaEvent = Shared:WaitForChild("Meta")

local storeProfile: any = nil
local storePages: { [any]: boolean } = {}
local renderStoreTab: (any, string) -> ()

local function refreshStores()
	for page in storePages do
		if page.storeShowing and page.frame.Parent and page.active then
			renderStoreTab(page, page.active)
		end
	end
end
metaEvent.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "profile" and type(data) == "table" then
		storeProfile = data
		refreshStores()
	end
end)
local function fetchProfile()
	task.spawn(function()
		local ok, success, p = pcall(function()
			return metaFn:InvokeServer("get")
		end)
		if ok and success and type(p) == "table" then
			storeProfile = p
			refreshStores()
		end
	end)
end

-- The profile (level, coins, stats) as last sent by the server; fetched once at start.
function MenuPages.getProfile(): any
	return storeProfile
end
fetchProfile()

local function storeStatus(page: any, msg: string)
	page.storeMsg = msg
	local l = page.body:FindFirstChild("StoreStatus")
	if l and l:IsA("TextLabel") then
		l.Text = msg
		l.Visible = msg ~= ""
	end
end

local function storeInvoke(page: any, action: string, arg: any)
	task.spawn(function()
		local ok, success, msg = pcall(function()
			return metaFn:InvokeServer(action, arg)
		end)
		if not ok then
			storeStatus(page, "Something went wrong, try again.")
		else
			storeStatus(page, if typeof(msg) == "string" then msg else "")
		end
		if ok and success then
			fetchProfile()
		end
	end)
end

-- Action box under a card: o-button primary, or the emerald / muted status box.
local function cardAction(parent: Instance, text: string, style: string, onClick: (() -> ())?): GuiObject
	local b
	if style == "primary" or style == "gray" then
		b = MenuKit.button(style, { Name = "Action", LayoutOrder = 9, Size = UDim2.new(1, 0, 0, 40), FontFace = F.BOLD, TextSize = 14, Text = text, Parent = parent })
		if onClick then
			b.Activated:Connect(onClick)
		end
	else
		local owned = style == "owned"
		b = make("TextButton", {
			Name = "Status",
			LayoutOrder = 9,
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = if owned then C.EMERALD500 else C.WHITE,
			BackgroundTransparency = if owned then 0.85 else 0.95,
			FontFace = F.BOLD,
			TextSize = if owned then 15 else 12,
			TextColor3 = if owned then C.EMERALD300 else C.WHITE,
			TextTransparency = if owned then 0 else 0.4,
			Text = text,
			Parent = parent,
		})
		MenuKit.corner(b, 8)
		MenuKit.stroke(b, if owned then 0.6 else 0.85, if owned then C.EMERALD500 else C.WHITE)
		if onClick then
			b.Activated:Connect(onClick)
		end
	end
	return b
end

local function storeCard(grid: Instance, order: number, name: string, fillArt: (Frame) -> (), equipped: boolean?): Frame
	local card = make("Frame", { Name = "Card", LayoutOrder = order, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Parent = grid })
	MenuKit.corner(card, 12)
	MenuKit.stroke(card, if equipped then 0.2 else 0.9, if equipped then C.MALIBU else C.WHITE, if equipped then 2 else 1)
	MenuKit.pad(card, 12, 12, 12, 12)
	MenuKit.list(card, false, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local art = make("Frame", { Name = "Art", LayoutOrder = 1, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, -76), Parent = card })
	MenuKit.corner(art, 8)
	fillArt(art)
	MenuKit.text({ LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 20), FontFace = F.BOLD, TextSize = 14, Text = name, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	return card
end

local function storeGrid(parent: Instance, order: number, cellH: number): Frame
	local grid = make("Frame", { Name = "Grid", LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	local layout = make("UIGridLayout", { CellPadding = UDim2.fromOffset(16, 16), CellSize = UDim2.fromOffset(176, cellH), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local function fit()
		local w = grid.AbsoluteSize.X
		if w <= 0 then
			return
		end
		local cols = math.max(2, math.floor((w + 16) / (176 + 16)))
		layout.CellSize = UDim2.new(1 / cols, -16 * (cols - 1) / cols, 0, cellH)
	end
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	return grid
end

local function ownsColor(p: any, c: any): boolean
	return c.price == 0 or p.allColors == true or (type(p.ownedColors) == "table" and table.find(p.ownedColors, c.id) ~= nil)
end

renderStoreTab = function(page: any, tab: string)
	page:clear()
	local body = page.body
	local coins = page.header:FindFirstChild("StoreCoins")
	if coins and coins:IsA("TextLabel") then
		coins.Text = if storeProfile then numberText(storeProfile.coins) .. " coins" else ""
	end
	local status = MenuKit.paragraph(body, 0, page.storeMsg or "", { Name = "StoreStatus", TextColor3 = C.AMBER300, TextXAlignment = Enum.TextXAlignment.Center })
	status.Visible = (page.storeMsg or "") ~= ""
	local p = storeProfile
	if not p then
		MenuKit.paragraph(body, 1, "Loading your profile...", { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.WHITE, TextTransparency = 0.6 })
		fetchProfile()
		return
	end
	if tab == "colours" then
		MenuKit.paragraph(body, 1, "Your territory colour in every round from your next one.", { TextColor3 = C.WHITE, TextTransparency = 0.5 })
		local grid = storeGrid(body, 2, 220)
		for i, c in MetaConfig.COLORS do
			local owned = ownsColor(p, c)
			local equipped = p.color == c.id
			local locked = (tonumber(p.level) or 1) < c.level and not owned
			local card = storeCard(grid, i, c.name, function(art)
				local sw = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), BackgroundColor3 = Color3.fromRGB(c.rgb[1], c.rgb[2], c.rgb[3]), BorderSizePixel = 0, Parent = art })
				make("UIAspectRatioConstraint", { Parent = sw })
				MenuKit.round(sw)
				MenuKit.stroke(sw, 0.7)
				if not owned then
					-- Every colour you don't own yet (level-locked or still to buy) shows the lock, on a
					-- dark badge so it reads on light swatches too (Snow, Ice, Gold).
					local badge = make("Frame", { Name = "LockBadge", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(34, 34), BackgroundColor3 = C.BLACK, BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 3, Parent = art })
					MenuKit.round(badge)
					MenuKit.icon("Lock", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), ImageColor3 = C.WHITE, ZIndex = 4, Parent = badge })
				end
			end, equipped)
			if equipped then
				cardAction(card, "Equipped", "owned", function()
					storeInvoke(page, "clearColor")
				end)
			elseif owned then
				cardAction(card, "Equip", "primary", function()
					storeInvoke(page, "equipColor", c.id)
				end)
			elseif locked then
				cardAction(card, "Unlocks at level " .. c.level, "muted")
			else
				local afford = (tonumber(p.coins) or 0) >= c.price
				cardAction(card, numberText(c.price) .. " coins", if afford then "primary" else "gray", function()
					if afford then
						storeInvoke(page, "buyColor", c.id)
					else
						storeStatus(page, "Not enough coins.")
					end
				end)
			end
		end
	elseif tab == "passes" then
		local passes = {
			{ id = MetaConfig.GAMEPASS.VIP, name = "VIP", desc = "1.5x XP and coins, VIP tag on the leaderboard", owned = p.vip, icon = "User" },
			{ id = MetaConfig.GAMEPASS.AllColors, name = "All Colours", desc = "Unlock every territory colour", owned = p.allColors, icon = "Layout" },
		}
		local any = false
		local grid = storeGrid(body, 2, 240)
		for i, pass in passes do
			if pass.id ~= 0 then
				any = true
				local card = storeCard(grid, i, pass.name, function(art)
					MenuKit.icon(pass.icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromOffset(36, 36), ImageColor3 = C.AQUARIUS, Parent = art })
					MenuKit.paragraph(art, 0, pass.desc, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(1, -12, 0, 0), TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.WHITE, TextTransparency = 0.4 })
				end)
				if pass.owned then
					cardAction(card, "Owned", "owned")
				else
					cardAction(card, "Buy", "primary", function()
						MarketplaceService:PromptGamePassPurchase(localPlayer, pass.id)
					end)
				end
			end
		end
		if not any then
			grid:Destroy()
			MenuKit.comingSoon(body, 3, "Layout")
		end
	else
		local grid = storeGrid(body, 2, 200)
		local any = false
		for i, prod in MetaConfig.PRODUCTS do
			if prod.id ~= 0 then
				any = true
				local card = storeCard(grid, i, prod.label, function(art)
					MenuKit.text({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 0.5), FontFace = F.BOLD, TextSize = 26, TextColor3 = C.CYBER, Text = numberText(prod.coins), Parent = art })
				end)
				cardAction(card, "Buy", "primary", function()
					if not p.saving then
						storeStatus(page, "Purchases are paused: your progress can't be saved right now.")
						return
					end
					MarketplaceService:PromptProductPurchase(localPlayer, prod.id)
				end)
			end
		end
		if not any then
			grid:Destroy()
			MenuKit.comingSoon(body, 3, "Layout")
		end
	end
	MenuKit.paragraph(body, 20, "Everything here is cosmetic or a progress boost - nothing gives an advantage inside a match.", { TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.WHITE, TextTransparency = 0.6 })
end

local function renderStore(page: any)
	storePages[page] = true
	page.storeMsg = ""
	local coins = page.header:FindFirstChild("StoreCoins")
	if not coins then
		coins = MenuKit.text({
			Name = "StoreCoins",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -24, 0.5, 0),
			Size = UDim2.fromOffset(160, 24),
			FontFace = F.BOLD,
			TextSize = 16,
			TextColor3 = C.CYBER,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = page.header,
		})
	end
	coins.Visible = true
	if not storeProfile then
		fetchProfile()
	end
	page:setTabs({
		{ key = "colours", label = "Colours" },
		{ key = "passes", label = "Passes" },
		{ key = "coins", label = "Coins" },
	}, "colours", function(key)
		page.storeMsg = ""
		renderStoreTab(page, key)
	end)
end

function MenuPages.render(kind: string, page: any, ctx: any)
	page.title.Text = string.upper(MenuPages.TITLES[kind] or kind)
	page.storeShowing = kind == "store"
	local coins = page.header:FindFirstChild("StoreCoins")
	if coins and kind ~= "store" then
		coins.Visible = false
	end
	if kind == "store" then
		renderStore(page)
	elseif kind == "settings" then
		renderSettings(page)
	elseif kind == "help" then
		renderHelp(page, ctx)
	elseif kind == "news" then
		renderNews(page)
	elseif kind == "language" then
		renderLanguage(page, ctx)
	elseif kind == "profile" then
		renderProfile(page, ctx)
	elseif kind == "inventory" then
		renderInventory(page, ctx)
	else
		page:setTabs({})
		page:clear()
		local note = if kind == "leaderboard"
			then "Global leaderboards need OpenFront's account servers. The in-match leaderboard is in the top left during a game."
			else "Clans need OpenFront's account servers."
		MenuKit.comingSoon(page.body, 1, if kind == "leaderboard" then "Layout" else "People", note)
	end
end

return MenuPages
