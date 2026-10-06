--[[
	War Front - keybind table and rebinding (OpenFront core/game/UserSettings.ts getDefaultKeybinds,
	client/UserSettingModal.ts renderKeybindSettings, resources/lang/en.json user_setting.*).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.KeybindData (ModuleScript), used by Keybinds, HudSidebars,
-- GameClient (via Interact.keys) and MenuPages (the Keybinds settings tab).
--
-- A binding is a Roblox KeyCode name, optionally with "Shift+" in front ("R", "Shift+R", "One").
-- The player's changes are a JSON map action -> binding in Settings "keybinds"; "Null" = unbound
-- (OpenFront: an unbound default no longer works, so its key can go to another action).
--
-- KeybindData.SECTIONS                 { { title, actions = { action ids } } } in OpenFront's order
-- KeybindData.INFO[action]             { label, desc, default }
-- KeybindData.get(action) -> string?   current binding (nil = unbound)
-- KeybindData.matches(action, input)   InputBegan keyboard input is this action's key (+ Shift)
-- KeybindData.held(action) -> boolean  the action's key is held (pan / zoom / modifiers)
-- KeybindData.label(action) -> string  "Shift + R", "1", "Space", "Ctrl", "" when unbound
-- KeybindData.fromInput(input) -> string?   binding string for a key press (rebinding)
-- KeybindData.owner(binding, except?) -> action?   which action already uses a binding
-- KeybindData.set(action, binding | "Null"), KeybindData.reset(action), KeybindData.resetAll()

local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local Settings = require(script.Parent:WaitForChild("Settings"))

local KeybindData = {}
KeybindData.capturing = false -- true while the settings Keybinds tab waits for a key

local INFO = {
	toggleView = { "Toggle View", "Alternate view (terrain/countries)", "Space" },
	coordinateGrid = { "Coordinate Grid", "Toggle the alphanumeric grid overlay", "M" },
	altKey = { "Graphics refresh modifier", "Hold this key and {key} to refresh graphics", "LeftAlt" },
	resetGfx = { "Reset Graphics", "Press while holding the modifier to reset rendering when experiencing display issues.", "R" },
	buildCity = { "Build City", "Build a City under your cursor.", "One" },
	buildFactory = { "Build Factory", "Build a Factory under your cursor.", "Two" },
	buildPort = { "Build Port", "Build a Port under your cursor.", "Three" },
	buildDefensePost = { "Build Defense Post", "Build a Defense Post under your cursor.", "Four" },
	buildMissileSilo = { "Build Missile Silo", "Build a Missile Silo under your cursor.", "Five" },
	buildSamLauncher = { "Build SAM Launcher", "Build a SAM Launcher under your cursor.", "Six" },
	buildWarship = { "Build Warship", "Build a Warship under your cursor.", "Seven" },
	buildAtomBomb = { "Build Atom Bomb", "Build an Atom Bomb under your cursor.", "Eight" },
	buildHydrogenBomb = { "Build Hydrogen Bomb", "Build a Hydrogen Bomb under your cursor.", "Nine" },
	buildMIRV = { "Build MIRV", "Build a MIRV under your cursor.", "Zero" },
	buildMenuModifier = { "Build Menu Modifier", "Hold this key while clicking to open the build menu.", "LeftControl" },
	emojiMenuModifier = { "Emoji Menu Modifier", "Hold this key while clicking to open the emoji menu.", "LeftAlt" },
	boxSelectWarships = { "Box-Select Warships", "Hold this key and drag to select multiple warships.", "LeftShift" },
	selectAllWarships = { "Select All Warships", "Select all of your warships on the map.", "F" },
	pauseGame = { "Pause", "Pause or resume the game (single player and custom games for host).", "P" },
	gameSpeedUp = { "Game Speed Up", "Cycle to next game speed (0.5, 1, 2, max). Single player only.", "Period" },
	gameSpeedDown = { "Game Speed Down", "Cycle to previous game speed. Single player only.", "Comma" },
	attackRatioDown = { "Decrease Attack Ratio", "Decrease attack ratio by {amount}%", "T" },
	attackRatioUp = { "Increase Attack Ratio", "Increase attack ratio by {amount}%", "Y" },
	boatAttack = { "Boat Attack", "Send a boat attack to the tile under your cursor.", "B" },
	groundAttack = { "Ground Attack", "Send a ground attack to the tile under your cursor.", "G" },
	retaliateAttack = { "Retaliate", "Send a retaliation attack to blunt/negate the force of the most recent active attacker. Only available when you are being attacked.", "Shift+R" },
	swapDirection = { "Swap Rocket Direction", "Toggle rocket launch direction (up/down).", "U" },
	requestAlliance = { "Request Alliance", "Send an alliance request to the player whose tile is under your cursor.", "K" },
	breakAlliance = { "Break Alliance (Betray)", "Break alliance with the player whose tile is under your cursor.", "L" },
	zoomOut = { "Zoom Out", "Zoom out the map", "Q" },
	zoomIn = { "Zoom In", "Zoom in the map", "E" },
	centerCamera = { "Center Camera", "Center camera on player", "C" },
	moveUp = { "Move Camera Up", "Move the camera upward", "W" },
	moveLeft = { "Move Camera Left", "Move the camera to the left", "A" },
	moveDown = { "Move Camera Down", "Move the camera downward", "S" },
	moveRight = { "Move Camera Right", "Move the camera to the right", "D" },
}
KeybindData.INFO = {}
for id, t in INFO do
	KeybindData.INFO[id] = { label = t[1], desc = t[2], default = t[3] }
end

-- UserSettingModal.renderKeybindSettings sections.
KeybindData.SECTIONS = {
	{ title = "View Options", actions = { "toggleView", "coordinateGrid", "altKey", "resetGfx" } },
	{ title = "Build Controls", actions = { "buildCity", "buildFactory", "buildPort", "buildDefensePost", "buildMissileSilo", "buildSamLauncher", "buildWarship", "buildAtomBomb", "buildHydrogenBomb", "buildMIRV" } },
	{ title = "Menu Shortcuts", actions = { "buildMenuModifier", "emojiMenuModifier", "boxSelectWarships", "selectAllWarships", "pauseGame", "gameSpeedUp", "gameSpeedDown" } },
	{ title = "Attack Ratio Controls", actions = { "attackRatioDown", "attackRatioUp" } },
	{ title = "Attack Keybinds", actions = { "boatAttack", "groundAttack", "retaliateAttack", "swapDirection" } },
	{ title = "Ally Keybinds", actions = { "requestAlliance", "breakAlliance" } },
	{ title = "Zoom Controls", actions = { "zoomOut", "zoomIn" } },
	{ title = "Camera Movement", actions = { "centerCamera", "moveUp", "moveLeft", "moveDown", "moveRight" } },
}

-- Modifier-style actions are held while clicking / with another key; they may share a key with
-- each other (OpenFront: altKey and emojiMenuModifier are both Alt) without a conflict.
local MODIFIERS = { altKey = true, buildMenuModifier = true, emojiMenuModifier = true, boxSelectWarships = true }
KeybindData.MODIFIERS = MODIFIERS

--------------------------------------------------------------------------------
-- Saved overrides
--------------------------------------------------------------------------------
local lastRaw: string? = nil
local overrides: { [string]: string } = {}

local function load(): { [string]: string }
	local raw = Settings.values.keybinds
	if raw ~= lastRaw then
		lastRaw = raw
		overrides = {}
		if type(raw) == "string" and raw ~= "" then
			local ok, t = pcall(HttpService.JSONDecode, HttpService, raw)
			if ok and type(t) == "table" then
				for k, v in t do
					if type(k) == "string" and type(v) == "string" and INFO[k] then
						overrides[k] = v
					end
				end
			end
		end
	end
	return overrides
end

local function save(t: { [string]: string })
	local clean = {}
	for k, v in t do
		if INFO[k] and v ~= KeybindData.INFO[k].default then
			clean[k] = v
		end
	end
	Settings.set("keybinds", if next(clean) then HttpService:JSONEncode(clean) else "")
end

function KeybindData.get(action: string): string?
	local o = load()[action]
	local b = o or (KeybindData.INFO[action] and KeybindData.INFO[action].default)
	if b == nil or b == "Null" then
		return nil
	end
	return b
end

-- "Shift+R" -> Enum.KeyCode.R, true
local function parse(b: string?): (Enum.KeyCode?, boolean)
	if not b then
		return nil, false
	end
	local shift = false
	local name = b
	if string.sub(b, 1, 6) == "Shift+" then
		shift, name = true, string.sub(b, 7)
	end
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	return if ok then code else nil, shift
end
KeybindData.parse = parse

local function shiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- Left/right versions of a modifier count as the same key.
local TWIN = {
	[Enum.KeyCode.LeftShift] = Enum.KeyCode.RightShift,
	[Enum.KeyCode.LeftControl] = Enum.KeyCode.RightControl,
	[Enum.KeyCode.LeftAlt] = Enum.KeyCode.RightAlt,
	[Enum.KeyCode.LeftMeta] = Enum.KeyCode.RightMeta,
}

function KeybindData.matches(action: string, input: InputObject): boolean
	local code, shift = parse(KeybindData.get(action))
	if not code then
		return false
	end
	local k = input.KeyCode
	if k ~= code and TWIN[code] ~= k then
		return false
	end
	if code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift then
		return true
	end
	return shiftDown() == shift
end

function KeybindData.held(action: string): boolean
	local code = parse(KeybindData.get(action))
	if not code then
		return false
	end
	return UserInputService:IsKeyDown(code) or (TWIN[code] ~= nil and UserInputService:IsKeyDown(TWIN[code]))
end

local NAMES = {
	One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
	LeftControl = "Ctrl", RightControl = "Ctrl", LeftAlt = "Alt", RightAlt = "Alt", LeftShift = "Shift", RightShift = "Shift",
	LeftMeta = "Cmd", RightMeta = "Cmd", Period = ".", Comma = ",", Minus = "-", Equals = "=", Slash = "/", BackSlash = "\\",
	Semicolon = ";", Quote = "'", LeftBracket = "[", RightBracket = "]", Backquote = "`", Return = "Enter",
	Up = "↑", Down = "↓", Left = "←", Right = "→",
}

function KeybindData.keyName(b: string): string
	local code, shift = parse(b)
	if not code then
		return b
	end
	local name = NAMES[code.Name] or code.Name
	return if shift then "Shift + " .. name else name
end

function KeybindData.label(action: string): string
	local b = KeybindData.get(action)
	return if b then KeybindData.keyName(b) else ""
end

-- A key press as a binding string (Shift + key, or a lone modifier).
function KeybindData.fromInput(input: InputObject): string?
	local k = input.KeyCode
	if k == Enum.KeyCode.Unknown or k == Enum.KeyCode.Escape then
		return nil
	end
	if k == Enum.KeyCode.LeftShift or k == Enum.KeyCode.RightShift or TWIN[k] or k == Enum.KeyCode.RightControl or k == Enum.KeyCode.RightAlt then
		local base = k
		for l, r in TWIN do
			if r == k then
				base = l
			end
		end
		return base.Name
	end
	return (if shiftDown() then "Shift+" else "") .. k.Name
end

-- The action (other than `except`) already using this binding, if any.
function KeybindData.owner(b: string, except: string?): string?
	local exceptMod = except ~= nil and MODIFIERS[except] == true
	for id in INFO do
		if id ~= except and KeybindData.get(id) == b and not (exceptMod and MODIFIERS[id]) then
			return id
		end
	end
	return nil
end

function KeybindData.set(action: string, b: string)
	local t = table.clone(load())
	t[action] = b
	save(t)
end

function KeybindData.reset(action: string)
	local t = table.clone(load())
	t[action] = nil
	save(t)
end

function KeybindData.resetAll()
	save({})
end

return KeybindData
