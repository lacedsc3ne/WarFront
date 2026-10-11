-- War Front Night menu: How to play. Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). Content rewritten in plain words from the old help page
-- (MenuPages.renderHelp: HOTKEYS / PAD_KEYS / TOUCH_KEYS, BUILDINGS, radial / info menu lists).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local playerScripts = script.Parent.Parent.Parent
local Art = require(script.Parent.Parent:WaitForChild("Art"))

-- Tutorial chapters and short lessons (Tutorial.CHAPTERS / Tutorial.LESSONS): play any of them again.
local function lessonGrid(body: Instance, order: number, ctx: any, phone: boolean)
	local okT, Tutorial = pcall(require, playerScripts:WaitForChild("Tutorial"))
	if not okT then
		return
	end
	local done = {}
	local p = ctx.profile and ctx.profile()
	if p and type(p.tutorialRewards) == "table" then
		done = p.tutorialRewards
	end
	local card = Kit.card({ Name = "Lessons", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = body })
	Kit.pad(card, 18, 18, 14, 16)
	Kit.list(card, false, 10)
	Kit.text({ Text = "Lessons", FontFace = F.TITLE, TextSize = 21, LayoutOrder = 0, Parent = card })
	local cols = if phone then 2 else 4
	local gap = 10
	local grid = make("Frame", { Name = "LessonGrid", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
	make("UIGridLayout", { CellSize = UDim2.new(1 / cols, -gap * (cols - 1) / cols, 0, 96), CellPadding = UDim2.fromOffset(gap, gap), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local nextShown = false
	local function tile(i: number, name: string, sub: string, artName: string?, icon: string?, color: Color3?, state: string?, onClick: () -> ())
		local b = make("TextButton", { Name = "Lesson_" .. name, Text = "", AutoButtonColor = false, BackgroundColor3 = C.RAISED, BorderSizePixel = 0, LayoutOrder = i, SelectionImageObject = Kit.ring, Parent = grid })
		Kit.corner(b, 12)
		Kit.stroke(b, if state == "next" then C.YELLOW else C.LINE, if state == "next" then 2 else 1.5)
		if artName then
			Art.image(artName, { Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(40, 40), Parent = b })
		else
			Kit.icon(icon or "Play", { Position = UDim2.fromOffset(16, 16), Size = UDim2.fromOffset(30, 30), ImageColor3 = color or C.YELLOW, Parent = b })
		end
		if state == "done" or state == "next" then
			local tag = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, Parent = b })
			Kit.list(tag, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
			Kit.icon(if state == "done" then "CheckCircle" else "Play", { Size = UDim2.fromOffset(16, 16), ImageColor3 = if state == "done" then C.GREEN else C.YELLOW, LayoutOrder = 1, Parent = tag })
			Kit.text({ Text = if state == "done" then "Done" else "Next", FontFace = F.BOLD, TextSize = 13, TextColor3 = if state == "done" then C.GREEN else C.YELLOW, LayoutOrder = 2, Parent = tag })
		end
		Kit.text({ Text = name, FontFace = F.TITLE, TextSize = 17, Position = UDim2.fromOffset(14, 56), Parent = b })
		Kit.text({ Text = sub, FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, Position = UDim2.fromOffset(14, 76), Parent = b })
		b.Activated:Connect(onClick)
	end
	for i, ch in Tutorial.CHAPTERS do
		local state = if done[ch.key] then "done" elseif not nextShown then "next" else nil
		if state == "next" then
			nextShown = true
		end
		tile(i, i .. ". " .. ch.name, ch.sub, ch.art, ch.icon, ch.color, state, function()
			ctx.startTutorial()
		end)
	end
	for i, l in Tutorial.LESSONS do
		tile(#Tutorial.CHAPTERS + i, l.name, l.time, l.art, nil, nil, nil, function()
			ctx.startTutorial(l.key)
		end)
	end
end

-- Picture cards: the whole game in eight steps.
local STEPS = {
	{ "MapPin", C.YELLOW, "Pick a start", "Click anywhere on the map to place your land" },
	{ "Grow", C.GREEN, "Grow", "Click empty land next to you to take it" },
	{ "Building", C.CYAN, "Build", "Cities give more troops. Ports earn more gold" },
	{ "Swords", C.PINK, "Attack", "Click an enemy to send troops at them" },
	{ "Handshake", C.PURPLE, "Make friends", "Ask others to be allies. Breaking it makes you a traitor!" },
	{ "Ship", C.CYAN, "Cross the sea", "Send boats to attack across water" },
	{ "Rocket", C.PINK, "Nukes", "Build a silo, then launch. SAM launchers shoot them down" },
	{ "Trophy", C.YELLOW, "Win", "Own 80% of the land to win the battle" },
}

-- Keyboard rows. `keys` is either text or a function (so rebound keys show the player's own key).
local function bound(KeybindData, action: string, suffix: string?): string
	local ok, label = pcall(KeybindData.label, action)
	if not ok or label == "" then
		return ""
	end
	return label .. (suffix or "")
end

local function pair(KeybindData, a: string, b: string): string
	local x, y = bound(KeybindData, a), bound(KeybindData, b)
	if x == "" or y == "" then
		return x .. y
	end
	return x .. " / " .. y
end

local function keyboardRows(KeybindData): { { string } }
	local function k(action: string, suffix: string?)
		return if KeybindData then bound(KeybindData, action, suffix) else ""
	end
	local function p(a: string, b: string)
		return if KeybindData then pair(KeybindData, a, b) else ""
	end
	local moves = ""
	if KeybindData then
		local parts = {}
		for _, a in { "moveUp", "moveLeft", "moveDown", "moveRight" } do
			local l = bound(KeybindData, a)
			if l ~= "" then
				table.insert(parts, l)
			end
		end
		moves = table.concat(parts, " ")
	end
	local rows = {
		{ "Esc", "Close a menu or stop placing a building" },
		{ k("toggleView", " (hold)"), "See the plain map without countries" },
		{ k("coordinateGrid"), "Show the map grid" },
		{ "1 - 0", "Build under your cursor: 1 City, 2 Factory, 3 Port, 4 Defense post, 5 Missile silo, 6 SAM, 7 Warship, 8 Atom bomb, 9 Hydrogen bomb, 0 MIRV" },
		{ k("boatAttack"), "Send boats to the spot under your cursor" },
		{ k("groundAttack"), "Attack the land under your cursor" },
		{ k("retaliateAttack"), "Hit back at whoever attacked you last" },
		{ k("requestAlliance"), "Ask the player under your cursor to be allies" },
		{ k("breakAlliance"), "Break your alliance with the player under your cursor" },
		{ k("centerCamera"), "Jump back to your land" },
		{ p("zoomOut", "zoomIn"), "Zoom out / in" },
		{ moves, "Move the camera" },
		{ p("attackRatioDown", "attackRatioUp"), "Send fewer / more troops per attack" },
		{ "Shift + Wheel", "Send fewer / more troops per attack" },
		{ k("buildMenuModifier", " + Click"), "Open the build menu" },
		{ "Shift + Click", "Place a building and keep placing more" },
		{ k("emojiMenuModifier", " + Click"), "Open the emoji menu" },
		{ k("boxSelectWarships", " + Drag"), "Pick several warships at once" },
		{ k("selectAllWarships"), "Pick all your warships" },
		{ k("swapDirection"), "Switch which way your rockets fly" },
		{ k("pauseGame"), "Pause or carry on (when playing alone)" },
		{ p("gameSpeedDown", "gameSpeedUp"), "Slower / faster game (when playing alone)" },
		{ "F3", "Show performance info" },
	}
	local out = {}
	for _, r in rows do
		if r[1] ~= "" then
			table.insert(out, r)
		end
	end
	return out
end

local PAD_KEYS = {
	{ "Left stick", "Move the pointer" },
	{ "Right stick", "Move the camera" },
	{ "LT / RT", "Zoom out / in" },
	{ "A", "Attack or build at the pointer" },
	{ "X", "Open the radial menu" },
	{ "B", "Close a menu or stop placing a building" },
	{ "LB / RB", "Send fewer / more troops per attack" },
	{ "D-pad", "Pick something to build" },
	{ "View", "Open the menu" },
	{ "R3", "Fit the whole map on the screen" },
}

local TOUCH_KEYS = {
	{ "Tap", "Pick your start, attack, take land or place a building" },
	{ "Hold", "Open the radial menu (tap the middle to attack)" },
	{ "Drag", "Move the camera" },
	{ "Pinch", "Zoom in and out" },
	{ "Build bar", "Tap a building or bomb, then tap the map. Tap it again to cancel" },
	{ "Troop slider", "Choose how many troops each attack sends" },
}

-- { name, IconKit sprite, plain description }
local BUILDINGS = {
	{ "City", "City", "Room for more troops. Build these when you can't grow any bigger." },
	{ "Defense post", "Defense", "Makes nearby borders tougher. Enemies attack slower and lose more troops." },
	{ "Port", "Port", "Build it by the water. Lets you build warships, and sends trade ships that earn gold for both sides." },
	{ "Factory", "Factory", "Lays railways to your nearby buildings. Trains earn gold at every stop, and more at friends' buildings." },
	{ "Warship", "Warship", "Guards the sea where you placed it. Catches enemy trade ships and sinks boats and warships." },
	{ "Missile silo", "Silo", "Lets you launch bombs." },
	{ "SAM launcher", "SAM", "Shoots down enemy bombs that fly close. Needs 7.5 seconds to reload." },
	{ "Atom bomb", "AtomBomb", "A small bomb that wrecks land, buildings and ships. Flies from your nearest silo." },
	{ "Hydrogen bomb", "HBomb", "A much bigger bomb. Flies from your nearest silo." },
	{ "MIRV", "MIRV", "The biggest bomb. Splits into lots of small bombs, but only hurts the player you aimed at." },
}

-- { heading, intro, { { IconKit sprite or false, text } } }
local MENUS = {
	{
		"Radial menu",
		"Right-click the map (hold on touch, X on a controller) to open it.",
		{
			{ "Build", "Build something here" },
			{ "Info", "See who owns this land" },
			{ "Boat", "Send boats here (you need a coast)" },
			{ "Alliance", "Ask this player to be allies" },
			{ "DonateTroops", "Give troops to an ally" },
			{ "DonateGold", "Give gold to an ally" },
		},
	},
	{
		"Player info",
		"Point at a country to see its troops, gold, ships and buildings.",
		{
			{ "Target", "Mark a target so your allies see it too" },
			{ "Emoji", "Send them an emoji" },
			{ "Embargo", "Stop or start trading with them" },
			{ "Crown", "The crown shows who is winning" },
		},
	},
	{
		"Alliances",
		"Friends are stronger together.",
		{
			{ "Alliance", "Allies can't attack each other, and can share troops and gold" },
			{ "Traitor", "Breaking an alliance makes you a traitor for 30 seconds, and your land gets easier to attack" },
			{ false, "The list on the right shows alliance asks, attacks and chat. Click an attack to look at it" },
			{ false, "The red X calls your troops back, but you lose a quarter of them" },
		},
	},
}

local function wrapText(props: { [string]: any }): TextLabel
	props.TextWrapped = true
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.Size = props.Size or UDim2.new(1, 0, 0, 0)
	props.AutomaticSize = Enum.AutomaticSize.Y
	return Kit.text(props)
end

local function sectionCard(body: Instance, order: number, title: string, icon: string, color: Color3): Frame
	local card = Kit.card({ Name = title, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = body })
	Kit.pad(card, 18, 18, 14, 16)
	Kit.list(card, false, 10)
	local head = make("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 0, Parent = card })
	Kit.list(head, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local badge = make("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(30, 30), LayoutOrder = 1, Parent = head })
	Kit.corner(badge, 9)
	Kit.icon(icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), ImageColor3 = C.BG, Parent = badge })
	Kit.text({ Text = title, FontFace = F.TITLE, TextSize = 21, LayoutOrder = 2, Parent = head })
	return card
end

local function subHeading(parent: Instance, order: number, str: string)
	Kit.text({ Text = str, FontFace = F.TITLE, TextSize = 17, TextColor3 = C.MUTED, LayoutOrder = order, Parent = parent })
end

local function keycap(parent: Instance, str: string)
	local cap = make("Frame", { Name = "Key", BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, Parent = parent })
	Kit.corner(cap, 8)
	Kit.stroke(cap)
	Kit.pad(cap, 10)
	Kit.text({ Text = str, FontFace = F.TITLE, TextSize = 15, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, Parent = cap })
	return cap
end

local function keyRows(parent: Instance, order: number, rows: { { string } }, keyWidth: number)
	local box = make("Frame", { Name = "Keys", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.list(box, false, 8)
	for i, r in rows do
		local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = box })
		make("UISizeConstraint", { MinSize = Vector2.new(0, 30), Parent = row })
		local holder = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(keyWidth, 30), Parent = row })
		keycap(holder, r[1])
		wrapText({ Text = r[2], FontFace = F.BODY, TextSize = 15, TextColor3 = C.TEXT, Position = UDim2.fromOffset(keyWidth + 12, 5), Size = UDim2.new(1, -(keyWidth + 12), 0, 0), Parent = row })
	end
end

local function stepGrid(body: Instance, order: number, phone: boolean)
	local cols = if phone then 2 else 4
	local gap = 12
	local grid = make("Frame", { Name = "Steps", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = body })
	make("UIGridLayout", {
		CellSize = UDim2.new(1 / cols, -gap * (cols - 1) / cols, 0, if phone then 146 else 142),
		CellPadding = UDim2.fromOffset(gap, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	for i, s in STEPS do
		local card = Kit.card({ Name = s[3], LayoutOrder = i, Parent = grid })
		Kit.pad(card, 14, 14, 14, 12)
		Kit.list(card, false, 6)
		local badge = make("Frame", { BackgroundColor3 = s[2], BackgroundTransparency = 0.82, BorderSizePixel = 0, Size = UDim2.fromOffset(48, 48), LayoutOrder = 1, Parent = card })
		Kit.corner(badge, 12)
		Kit.icon(s[1], { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(30, 30), ImageColor3 = s[2], Parent = badge })
		Kit.text({ Text = string.format("%d. %s", i, s[3]), FontFace = F.TITLE, TextSize = 18, LayoutOrder = 2, Parent = card })
		wrapText({ Text = s[4], FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = card })
	end
end

local function spriteRow(parent: Instance, order: number, IconKit, sprite: any, str: string)
	local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	make("UISizeConstraint", { MinSize = Vector2.new(0, 28), Parent = row })
	if sprite and IconKit then
		pcall(IconKit.image, sprite, { Size = UDim2.fromOffset(28, 28), Parent = row })
	else
		local dot = make("Frame", { BackgroundColor3 = C.YELLOW, BorderSizePixel = 0, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(8, 8), Parent = row })
		Kit.corner(dot)
	end
	wrapText({ Text = str, FontFace = F.BODY, TextSize = 15, Position = UDim2.fromOffset(40, 4), Size = UDim2.new(1, -40, 0, 0), Parent = row })
end

return {
	title = "How to play",
	headerRight = function()
		-- Wired up in render (headerRight gets no ctx).
		return Kit.button("primary", "Play the tutorial", { name = "PlayTutorial", icon = "Play", height = 40 })
	end,
	render = function(page, ctx)
		local phone = ctx.layout() == "phone"
		local tutorial = page.header:FindFirstChild("PlayTutorial")
		if tutorial then
			tutorial.Activated:Connect(function()
				ctx.startTutorial()
			end)
		end

		local okKeys, KeybindData = pcall(require, playerScripts:WaitForChild("KeybindData"))
		local okKit, IconKit = pcall(require, playerScripts:WaitForChild("IconKit"))
		local okIcons, Icons = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Icons"))
		if not okKit then
			IconKit = nil
		end
		local function has(name: string): boolean
			return IconKit ~= nil and (not okIcons or Icons.has(name))
		end

		local body = page.body
		Kit.list(body, false, 14)
		lessonGrid(body, 0, ctx, phone)
		stepGrid(body, 1, phone)

		-- Keys and buttons
		local keyWidth = if phone then 120 else 160
		local keys = sectionCard(body, 2, "Keys and buttons", "Keyboard", C.CYAN)
		subHeading(keys, 1, "Keyboard")
		keyRows(keys, 2, keyboardRows(if okKeys then KeybindData else nil), keyWidth)
		subHeading(keys, 3, "Controller")
		keyRows(keys, 4, PAD_KEYS, keyWidth)
		if UserInputService.TouchEnabled then
			subHeading(keys, 5, "Touch")
			keyRows(keys, 6, TOUCH_KEYS, keyWidth)
		end

		-- All buildings
		local builds = sectionCard(body, 3, "All buildings", "Building", C.GREEN)
		local n = 0
		for _, b in BUILDINGS do
			if has(b[2]) then
				n += 1
				local row = make("Frame", { Name = b[1], BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = n, Parent = builds })
				make("UISizeConstraint", { MinSize = Vector2.new(0, 36), Parent = row })
				local well = make("Frame", { BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.fromOffset(36, 36), Parent = row })
				Kit.corner(well, 10)
				pcall(IconKit.image, b[2], { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(26, 26), Parent = well })
				local col = make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(50, 0), Size = UDim2.new(1, -50, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = row })
				Kit.list(col, false, 2)
				Kit.text({ Text = b[1], FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = col })
				wrapText({ Text = b[3], FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = col })
			end
		end

		-- Menus in battle
		local menus = sectionCard(body, 4, "Menus in battle", "Menu", C.PURPLE)
		local o = 0
		for _, m in MENUS do
			o += 1
			subHeading(menus, o, m[1])
			o += 1
			wrapText({ Text = m[2], FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = o, Parent = menus })
			for _, r in m[3] do
				o += 1
				spriteRow(menus, o, IconKit, if r[1] and has(r[1]) then r[1] else nil, r[2])
			end
		end

		-- Credits and license (OpenFront's AGPL-3.0 and CC BY-SA 4.0 notices; text from Shared.Config).
		local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
		local credits = sectionCard(body, 5, "Credits and license", "Help", C.MUTED)
		local lines = {
			Config.GAME_TITLE .. " is a modified port of OpenFront (openfront.io). It is not affiliated with or endorsed by OpenFront.",
			"Based on OpenFront, " .. Config.CREDIT .. ". The game code is licensed under the GNU Affero General Public License, version 3 or later (AGPL-3.0), and comes with no warranty.",
			Config.ASSET_CREDIT .. ".",
			"Source code: " .. Config.SOURCE_URL,
			"License text: gnu.org/licenses/agpl-3.0",
		}
		for i, line in lines do
			wrapText({ Text = line, FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = i, Parent = credits })
		end
	end,
}
