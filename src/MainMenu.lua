--[[
	War Front - main menu shown when a player joins (OpenFront's home screen).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Map data © OpenFront and Contributors, CC BY-SA 4.0
	Layout ported from OpenFront's index.html, components/DesktopNavBar.ts, MobileNavBar.ts,
	MainLayout.ts, PlayPage.ts, NewsBox.ts, UsernameInput.ts, GameModeSelector.ts, LobbyCard.ts,
	NavUtilityIcons.ts, NavAccountMenu.ts, Footer.ts and LangSelector.ts (AGPL-3.0).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MainMenu (LocalScript)
-- Desktop (>= 1024 px, OpenFront's lg): nav bar (WAR FRONT wordmark + version, PLAY / STORE /
-- INVENTORY / LEADERBOARD / CLANS, news bell, help, settings, account menu), then the play page:
-- news banner, identity row, featured round card + UPCOMING column, PLAY / TUTORIAL, CREATE LOBBY /
-- RANKED / JOIN LOBBY, footer. Narrower screens get OpenFront's mobile top bar + slide-in drawer
-- and the phone stacking order. Pages (settings, help, release notes, language, profile,
-- inventory, leaderboard, clans, upcoming maps) open inline in the main area like OpenFront's
-- inline modals (MenuPages / MenuKit). Matchmaking buttons say "Coming Soon".
-- Talks to:
--   Shared.Net        "play", "vote" (client -> server); "init", "phase", "roster", "joined" (server -> client)
--   Shared.Meta/MetaFn profile (level, xp, coins, games...)
--   PlayerGui.FrontlinesMeta.Open (BindableEvent) to open the store window
--   PlayerGui attributes FrontlinesMenuOpen (gamepad controls pause on it) and FrontlinesTutorial.
--   PlayerGui.FrontlinesMenuShow (BindableEvent, created here):
--     :Fire()        the player left the match (defeat screen / in-match Exit): show the menu
--     :Fire("open")  show the menu over the running match without leaving it
-- While a match is being played and the menu is closed, the MetaClient profile chip and the
-- MENU button are hidden, so the in-match top-right bar (HudSidebars) owns that corner.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local net = Shared:WaitForChild("Net")

-- Round state (listen as early as possible so the first "init"/"phase" isn't missed)
local state = {
	phase = nil :: string?,
	phaseEnd = 0, -- os.clock() when the current phase timer runs out
	playStart = nil :: number?, -- os.clock() when we saw Play begin (unknown if we joined mid-round)
	mapId = nil :: string?,
	options = {} :: { any }, -- vote options while in Lobby
	myVote = nil :: string?,
	humans = 0,
	inRound = false,
	hasPlayed = false,
	-- Lobby place: the three public lobbies { ffa, team, special } (Matchmaker views + endAt).
	lobbies = nil :: any,
}

local refresh: (() -> ())? = nil
local onJoined: ((any) -> ())? = nil
local refreshQueued = false
local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		if refresh then
			refresh()
		end
	end)
end

local TICK = 0.1 -- replaced by Config.TICK below; init/phase can arrive before Config loads

local function countHumans(list: any): number
	local n = 0
	if type(list) == "table" then
		for _, e in list do
			if type(e) == "table" and (e.kind or e[3]) == "Human" then
				n += 1
			end
		end
	end
	return n
end

local function applyPhase(p: any)
	if type(p) == "string" then
		p = { phase = p }
	end
	if type(p) ~= "table" or type(p.phase) ~= "string" then
		return
	end
	local newPhase = p.phase
	if newPhase ~= state.phase then
		if newPhase == "Play" then
			state.playStart = if state.phase == "Spawn" then os.clock() else nil
		else
			state.playStart = nil
		end
		if newPhase == "Lobby" then
			state.myVote = nil
		end
	end
	state.phase = newPhase
	state.phaseEnd = os.clock() + (tonumber(p.ticksLeft) or 0) * TICK
	if type(p.lobbies) == "table" then
		for _, l in p.lobbies do
			l.endAt = if type(l.secs) == "number" then os.clock() + l.secs else nil
		end
		state.lobbies = p.lobbies
	elseif p.phase ~= "Lobby" then
		state.lobbies = nil
	end
	-- Lobby place: players in the shared public lobby / its size.
	state.queue = if type(p.queue) == "table" then p.queue else nil
	-- Mode of the round being played / voted into ("Free for All", "4 teams", "Duos", ...).
	state.mode = if type(p.mode) == "string" then string.upper(p.mode) else "FREE FOR ALL"
	if type(p.vote) == "table" and type(p.vote.options) == "table" then
		state.options = p.vote.options
		-- vote.current is the map the server has loaded right now (the last round's map).
		if type(p.vote.current) == "string" then
			state.mapId = p.vote.current
		end
	elseif newPhase ~= "Lobby" then
		state.options = {}
	end
	if state.myVote then
		local found = false
		for _, o in state.options do
			if o.id == state.myVote then
				found = true
			end
		end
		if not found then
			state.myVote = nil
		end
	end
	queueRefresh()
end

net.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "init" then
		if type(data) ~= "table" then
			return
		end
		if type(data.map) == "string" then
			state.mapId = data.map
		end
		state.inRound = (tonumber(data.myId) or 0) ~= 0
		state.humans = countHumans(data.roster)
		applyPhase(data.phase)
		queueRefresh()
	elseif kind == "phase" then
		applyPhase(data)
	elseif kind == "roster" then
		state.humans = countHumans(data)
		queueRefresh()
	elseif kind == "joined" then
		if type(data) == "table" then
			state.inRound = data.inRound == true
			if onJoined then
				onJoined(data)
			end
		end
	end
end)

local Config = require(Shared:WaitForChild("Config"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local MapCatalog = require(Shared:WaitForChild("MapCatalog"))
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))
local PauseMenu = require(script.Parent:WaitForChild("PauseMenu")) -- MENU / Start open it during a round
TICK = Config.TICK


local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local MenuPages = require(script.Parent:WaitForChild("MenuPages"))
local LobbyPages = require(script.Parent:WaitForChild("LobbyPages")) -- Create / Join Lobby, Ranked
-- "lobby" | "match" | "standalone" (Shared.Place): the lobby place runs the matchmaking pages, a
-- match server skips the menu and drops the player straight into the round.
local Place = require(Shared:WaitForChild("Place"))

-- Style (MenuKit holds OpenFront's colour tokens and component looks)
local C, F = MenuKit.C, MenuKit.F
local WHITE = C.WHITE
local BLACK = C.BLACK
local make = MenuKit.make
local corner = MenuKit.corner
local round = MenuKit.round
local text = MenuKit.text

local function padding(o: Instance, x: number, y: number?)
	MenuKit.pad(o, x, x, y or 0, y or 0)
end

local function place(o: GuiObject, x: number, y: number, w: number, h: number)
	o.AnchorPoint = Vector2.zero
	o.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	o.Size = UDim2.fromOffset(math.max(0, math.floor(w + 0.5)), math.max(0, math.floor(h + 0.5)))
end

-- OpenFront Utils.renderDuration: "1h 2min 3s", trailing zero parts dropped.
local function formatTime(sec: number): string
	local whole = math.floor(sec)
	if whole <= 0 then
		return "0s"
	end
	local h, m, s = whole // 3600, (whole % 3600) // 60, whole % 60
	local parts = {}
	if h > 0 then
		parts[#parts + 1] = h .. "h"
	end
	if m > 0 then
		parts[#parts + 1] = m .. "min"
	end
	if s > 0 or #parts == 0 then
		parts[#parts + 1] = s .. "s"
	end
	return table.concat(parts, " ")
end

local function setSelectionGroup(o: GuiObject)
	pcall(function()
		(o :: any).SelectionGroup = true
	end)
end

-- Maps
local function catalogInfo(id: string?)
	if not id then
		return nil
	end
	for _, m in MapCatalog do
		if m.id == id then
			return m
		end
	end
	return nil
end

local function mapName(id: string?): string
	local m = catalogInfo(id)
	return if m then m.name else (id or "War Front")
end

local function mapPool()
	local folder = Shared:FindFirstChild("Maps")
	local out = {}
	for _, m in MapCatalog do
		if not folder or folder:FindFirstChild(m.id) then
			out[#out + 1] = m
		end
	end
	if #out == 0 then
		for _, m in MapCatalog do
			out[#out + 1] = m
		end
	end
	return out
end

-- Terrain colours for previews: index = terrain byte, value = RGBA packed little-endian.
local PIXEL = table.create(256, 0)
do
	local function lerp(a: number, b: number, t: number): number
		return math.floor(a + (b - a) * t + 0.5)
	end
	local function pack(r: number, g: number, b: number): number
		return r + g * 256 + b * 65536 + 255 * 16777216
	end
	for byte = 0, 255 do
		local r, g, b
		if byte < 128 then
			if bit32.band(byte, 64) ~= 0 then
				r, g, b = 26, 52, 84 -- water next to the coast
			elseif bit32.band(byte, 32) ~= 0 then
				r, g, b = 14, 30, 52 -- open ocean
			else
				r, g, b = 20, 42, 68 -- lakes
			end
		else
			local m = bit32.band(byte, 31)
			if m >= 20 then
				local t = math.min(1, (m - 20) / 11)
				r, g, b = lerp(214, 246, t), lerp(214, 246, t), lerp(204, 242, t) -- mountains
			elseif m >= 10 then
				local t = (m - 10) / 10
				r, g, b = lerp(214, 194, t), lerp(196, 172, t), lerp(148, 126, t) -- highlands
			else
				local t = m / 10
				r, g, b = lerp(184, 158, t), lerp(222, 204, t), lerp(140, 118, t) -- plains
			end
		end
		PIXEL[byte + 1] = pack(r, g, b)
	end
end

local mapData: { [string]: any } = {} -- id -> GameMap | false
local previews: { [string]: any } = {} -- "id@width" -> EditableImage | false
local previewPending: { [string]: boolean } = {}
local previewQueue = {}
local previewWorker = false

local function loadMapData(id: string)
	if mapData[id] ~= nil then
		return mapData[id]
	end
	local folder = Shared:FindFirstChild("Maps") or Shared:WaitForChild("Maps", 5)
	local mod = folder and (folder:FindFirstChild(id) or folder:WaitForChild(id, 5))
	local result = false
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(MapUtil.load, mod)
		if ok and m then
			result = m
		else
			warn("[MainMenu] could not load map " .. id .. ": " .. tostring(m))
		end
	end
	mapData[id] = result
	return result
end

local function renderPreview(map, targetW: number)
	local w, h = map.width, map.height
	local tw = math.clamp(math.floor(targetW), 16, 1024)
	local th = math.clamp(math.floor(tw * h / w + 0.5), 8, 1024)
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(tw, th) })
	if not img then
		return nil
	end
	local buf = buffer.create(tw * th * 4)
	local terrain = map.terrain
	local xs = table.create(tw, 0)
	for x = 0, tw - 1 do
		xs[x + 1] = math.min(w - 1, math.floor((x + 0.5) * w / tw))
	end
	local o = 0
	for y = 0, th - 1 do
		local row = math.min(h - 1, math.floor((y + 0.5) * h / th)) * w
		for x = 1, tw do
			buffer.writeu32(buf, o, PIXEL[buffer.readu8(terrain, row + xs[x]) + 1])
			o += 4
		end
		if y % 48 == 47 then
			task.wait()
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(tw, th), buf)
	return img
end

local function requestPreview(id: string, width: number)
	local key = id .. "@" .. width
	if previews[key] ~= nil or previewPending[key] then
		return
	end
	previewPending[key] = true
	table.insert(previewQueue, { id = id, width = width, key = key })
	if previewWorker then
		return
	end
	previewWorker = true
	task.spawn(function()
		while #previewQueue > 0 do
			local job = table.remove(previewQueue, 1)
			local img = nil
			local map = loadMapData(job.id)
			if map then
				local ok, res = pcall(renderPreview, map, job.width)
				if ok then
					img = res
				else
					warn("[MainMenu] map preview failed: " .. tostring(res))
				end
			end
			previews[job.key] = img or false
			previewPending[job.key] = nil
			queueRefresh()
			task.wait()
		end
		previewWorker = false
	end)
end

-- Avatars
local thumbs: { [number]: string | boolean } = {}
local function setAvatar(img: ImageLabel, initial: TextLabel, userId: number, name: string)
	initial.Text = string.upper(string.sub(name, 1, 1))
	local cached = thumbs[userId]
	if type(cached) == "string" then
		img.Image = cached
		initial.Visible = false
		return
	end
	img.Image = ""
	initial.Visible = true
	if cached == nil and userId > 0 then
		thumbs[userId] = true -- pending
		task.spawn(function()
			local ok, url = pcall(function()
				return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
			end)
			thumbs[userId] = if ok and type(url) == "string" then url else false
			queueRefresh()
		end)
	end
end

-- GUI
local gui = make("ScreenGui", {
	Name = "FrontlinesMenu",
	DisplayOrder = 10,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = false,
	Parent = playerGui,
})

-- body bg-neutral-800 with the map background at 30% opacity: here the live match shows
-- through at 30%. Swallows clicks so they don't reach the map.
local backdrop = make("TextButton", {
	Name = "Backdrop",
	Text = "",
	AutoButtonColor = false,
	Selectable = false,
	BackgroundColor3 = C.NEUTRAL800,
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
	Parent = gui,
})

local screen = make("Frame", { Name = "Screen", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
local screenScale = make("UIScale", { Parent = screen })
setSelectionGroup(screen)

local VERSION = "v" .. tostring(game.PlaceVersion)

-- "WAR FRONT" wordmark in place of OpenFront's logo image: malibu-blue heavy type with the
-- white outline of OpenFront's .l-header__logo.
local function wordmark(parent: Instance, name: string): TextLabel
	local w = text({
		Name = name,
		FontFace = F.LOGO,
		Text = Config.GAME_TITLE and string.upper(Config.GAME_TITLE) or "WAR FRONT",
		TextColor3 = C.MALIBU,
		TextScaled = true,
		Parent = parent,
	})
	make("UIStroke", { Color = WHITE, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual, Parent = w })
	return w
end

local function versionLabel(parent: Instance): TextLabel
	return text({ Name = "Version", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MALIBU, Text = VERSION, Parent = parent })
end

-- Page links (DesktopNavBar / MobileNavBar order).
local NAV = {
	{ key = "play", label = "Play" },
	{ key = "store", label = "Store" },
	{ key = "inventory", label = "Inventory" },
	{ key = "leaderboard", label = "Leaderboard" },
	{ key = "clans", label = "Clans" },
}
local navButtons: { [string]: { TextButton } } = {} -- key -> buttons (desktop + drawer)
local utilButtons: { [string]: { TextButton } } = {} -- "news" | "help" | "settings" -> icon buttons
local currentPage: string? = nil -- nil = play page

local function paintNav()
	for key, list in navButtons do
		local active = (currentPage or "play") == key
		for _, b in list do
			b:SetAttribute("Active", active)
		end
	end
	for key, list in utilButtons do
		for _, b in list do
			b:SetAttribute("Active", currentPage == key)
		end
	end
end

local function navLink(parent: Instance, key: string, label: string, order: number, drawer: boolean): TextButton
	local b = make("TextButton", {
		Name = "Nav_" .. key,
		LayoutOrder = order,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		AutomaticSize = if drawer then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Size = if drawer then UDim2.new(1, 0, 0, 44) else UDim2.fromOffset(0, 40),
		FontFace = if drawer then F.BOLD else F.MEDIUM,
		TextSize = if drawer then 24 else 16,
		Text = string.upper(label),
		TextColor3 = WHITE,
		TextTransparency = 0.3,
		TextXAlignment = if drawer then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
		Parent = parent,
	})
	local pad = if drawer then MenuKit.pad(b, 0, 0, 0, 0) else nil
	local state = "idle"
	local function paint()
		local lit = state ~= "idle" or b:GetAttribute("Active") == true
		local hi = if drawer then C.BLUE600 else C.MALIBU
		b.TextColor3 = if lit then hi else WHITE
		b.TextTransparency = if lit then 0 else 0.3
		if pad then
			-- hover:translate-x-2.5 on the drawer items
			pad.PaddingLeft = UDim.new(0, if lit then 10 else 0)
		end
	end
	MenuKit.hover(b, function(s)
		state = s
		paint()
	end)
	b:GetAttributeChangedSignal("Active"):Connect(paint)
	navButtons[key] = navButtons[key] or {}
	table.insert(navButtons[key], b)
	return b
end

-- NavAccountMenu trigger: round avatar + caret.
local accountButtons: { TextButton } = {}
local function accountButton(parent: Instance, order: number): TextButton
	local b = make("TextButton", {
		Name = "Account",
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(56, 40),
		Parent = parent,
	})
	round(b)
	local img = make("ImageLabel", {
		Name = "Avatar",
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		ScaleType = Enum.ScaleType.Crop,
		Parent = b,
	})
	round(img)
	local caret = MenuKit.icon("Caret", { Position = UDim2.fromOffset(40, 14), Size = UDim2.fromOffset(12, 12), ImageColor3 = WHITE, ImageTransparency = 0.1, Parent = b })
	MenuKit.hover(b, function(s)
		b.BackgroundTransparency = if s == "idle" then 1 else 0.92
		caret.ImageTransparency = if s == "idle" then 0.1 else 0
	end)
	table.insert(accountButtons, b)
	return b
end

local function utility(parent: Instance, size: number, order0: number): { [string]: TextButton }
	local out = {}
	for i, it in { { "news", "Bell" }, { "help", "Help" }, { "settings", "Gear" } } do
		local b = MenuKit.iconButton(it[2], size, { Name = "Util_" .. it[1], LayoutOrder = order0 + i, Parent = parent })
		utilButtons[it[1]] = utilButtons[it[1]] or {}
		table.insert(utilButtons[it[1]], b)
		out[it[1]] = b
	end
	return out
end

-- Desktop nav bar -------------------------------------------------------------------
local nav = make("Frame", { Name = "NavBar", BackgroundColor3 = C.ZINC900, BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 5, Parent = screen })
local navRow = make("Frame", {
	Name = "Row",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	AutomaticSize = Enum.AutomaticSize.X,
	Size = UDim2.fromOffset(0, 52),
	BackgroundTransparency = 1,
	Parent = nav,
})
local navRowScale = make("UIScale", { Parent = navRow })
MenuKit.list(navRow, true, 32, { VerticalAlignment = Enum.VerticalAlignment.Center })
do
	local logo = make("Frame", { Name = "Logo", LayoutOrder = 0, BackgroundTransparency = 1, Size = UDim2.fromOffset(170, 52), Parent = navRow })
	local w = wordmark(logo, "Wordmark")
	w.Size = UDim2.fromOffset(170, 32)
	local v = versionLabel(logo)
	v.Position = UDim2.fromOffset(0, 34)
	v.Size = UDim2.fromOffset(170, 18)
	for i, item in NAV do
		navLink(navRow, item.key, item.label, i, false)
	end
	local util = make("Frame", { Name = "Utility", LayoutOrder = 10, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 40), Parent = navRow })
	MenuKit.list(util, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
	-- ml-1 border-l border-white/10 pl-5
	MenuKit.pad(util, 4, 0, 0, 0)
	make("Frame", { Name = "Divider", LayoutOrder = -2, Size = UDim2.fromOffset(1, 40), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = util })
	make("Frame", { Name = "Gap", LayoutOrder = -1, Size = UDim2.fromOffset(12, 40), BackgroundTransparency = 1, Parent = util })
	utility(util, 40, 0)
	accountButton(util, 10)
end

-- Mobile top bar --------------------------------------------------------------------
local topBar = make("Frame", { Name = "TopBar", BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, ZIndex = 5, Visible = false, Parent = screen })
make("Frame", { Name = "Border", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = topBar })
local hamburger = make("TextButton", { Name = "Hamburger", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BackgroundColor3 = WHITE, Size = UDim2.fromOffset(53, 40), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Parent = topBar })
corner(hamburger, 6)
MenuKit.icon("Menu", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(32, 32), ImageColor3 = WHITE, ImageTransparency = 0.1, Parent = hamburger })
MenuKit.hover(hamburger, function(s)
	hamburger.BackgroundTransparency = if s == "idle" then 1 else 0.92
end)
local topLogo = wordmark(topBar, "Wordmark")
topLogo.AnchorPoint = Vector2.new(0.5, 0.5)
topLogo.Position = UDim2.fromScale(0.5, 0.5)
local topRight = make("Frame", { Name = "Right", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 40), BackgroundTransparency = 1, Parent = topBar })
MenuKit.list(topRight, true, 2, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Right })
utility(topRight, 36, 0)
accountButton(topRight, 10)

-- Scrolling main area (main-layout + footer) ------------------------------------------
local scroll = make("ScrollingFrame", {
	Name = "Main",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = WHITE,
	ScrollBarImageTransparency = 0.7,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Selectable = false,
	Parent = screen,
})
local playPage = make("Frame", { Name = "PlayPage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = scroll })

-- News box ----------------------------------------------------------------------------
-- (NewsBox: type label, title, description, dots, dismiss; cycles every 5 s.)
local NEWS_TYPES = {
	announcement = { "NEWS", C.EMERALD500, C.EMERALD300 },
	tutorial = { "TUTORIAL", C.SKY300, C.SKY300 },
	tournament = { "TOURNAMENT", C.AMBER500, C.AMBER300 },
	warning = { "WARNING", C.RED500, C.RED300 },
}
local NEWS = {
	{ id = "maps", type = "announcement", title = #MapCatalog .. " maps and map voting", desc = "Vote for the next map in the Upcoming column between rounds." },
	{ id = "tutorial", type = "tutorial", title = "New Player Tutorial", desc = "Press Tutorial to play your first game with a step-by-step guide." },
	{ id = "alliances", type = "announcement", title = "Alliances, trade and warships", desc = "Right-click a player (long-press on touch, X on a controller) to ally." },
	{ id = "daily", type = "announcement", title = "Daily rewards", desc = "Play every day to grow your streak." },
}
local newsDismissed: { [string]: boolean } = {}
local newsIndex = 1

local news = make("Frame", { Name = "News", BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = playPage })
local newsCorner = corner(news, 12)
local newsBorderT = make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = news })
local newsBorderB = make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = news })
local newsTag = text({ Name = "Type", AnchorPoint = Vector2.new(0, 0.5), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 18), BackgroundTransparency = 0.8, FontFace = F.BOLD, TextSize = 10, Parent = news })
corner(newsTag, 4)
padding(newsTag, 8)
local newsTitle = text({ Name = "Title", FontFace = F.MEDIUM, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = news })
local newsDesc = text({ Name = "Desc", TextSize = 12, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = news })
local newsDots = make("Frame", { Name = "Dots", AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 6), AutomaticSize = Enum.AutomaticSize.X, Parent = news })
MenuKit.list(newsDots, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
local newsClose = make("TextButton", { Name = "Dismiss", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Size = UDim2.fromOffset(24, 24), Parent = news })
local newsCloseIcon = MenuKit.icon("X", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 14), ImageTransparency = 0.7, Parent = newsClose })
MenuKit.hover(newsClose, function(s)
	newsCloseIcon.ImageTransparency = if s == "idle" then 0.7 else 0.3
end)
local newsDotButtons: { TextButton } = {}

local function visibleNews()
	local out = {}
	for _, n in NEWS do
		if not newsDismissed[n.id] then
			out[#out + 1] = n
		end
	end
	return out
end

local renderNews: () -> ()
renderNews = function()
	local items = visibleNews()
	news.Visible = #items > 0 and news:GetAttribute("LayoutVisible") ~= false
	if #items == 0 then
		return
	end
	if newsIndex > #items then
		newsIndex = 1
	end
	local item = items[newsIndex]
	local t = NEWS_TYPES[item.type] or NEWS_TYPES.announcement
	newsTag.Text = t[1]
	newsTag.BackgroundColor3 = t[2]
	newsTag.TextColor3 = t[3]
	newsTitle.Text = item.title
	newsDesc.Text = item.desc
	if #newsDotButtons ~= #items then
		for _, d in newsDotButtons do
			d:Destroy()
		end
		table.clear(newsDotButtons)
		if #items > 1 then
			for i = 1, #items do
				local d = make("TextButton", { Name = "Dot" .. i, LayoutOrder = i, Text = "", AutoButtonColor = false, Selectable = false, Size = UDim2.fromOffset(6, 6), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = newsDots })
				round(d)
				d.Activated:Connect(function()
					newsIndex = i
					renderNews()
				end)
				newsDotButtons[i] = d
			end
		end
	end
	for i, d in newsDotButtons do
		d.BackgroundTransparency = if i == newsIndex then 0.4 else 0.8
	end
end

-- Identity row (UsernameInput over the cosmetic background) ------------------------
-- The name field is editable (NameInput); the clan tag picker needs OpenFront's clan servers and
-- says "Coming Soon".
local identity = make("Frame", { Name = "Identity", BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = playPage })
local identityCorner = corner(identity, 12)
local idInner = make("Frame", { Name = "Inner", BackgroundColor3 = C.SURFACE, BackgroundTransparency = 0.2, BorderSizePixel = 0, Parent = identity })
corner(idInner, 12)
local tagBtn = make("TextButton", { Name = "ClanTag", Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BackgroundTransparency = 1, Size = UDim2.fromOffset(116, 44), Parent = idInner })
corner(tagBtn, 8)
text({ Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -24, 1, 0), FontFace = F.SEMIBOLD, TextSize = 16, TextTransparency = 0.55, TextXAlignment = Enum.TextXAlignment.Left, Text = "TAG", Parent = tagBtn })
MenuKit.icon("Caret", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(12, 12), ImageTransparency = 0.55, Parent = tagBtn })
MenuKit.hover(tagBtn, function(s)
	tagBtn.BackgroundTransparency = if s == "idle" then 1 else 0.95
end)
-- UsernameInput: an editable name (NameInput.lua checks it and the server filters it).
local myName = make("TextBox", {
	Name = "Name",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	FontFace = F.MEDIUM,
	TextSize = 24,
	TextColor3 = WHITE,
	PlaceholderColor3 = C.GRAY400,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	ClearTextOnFocus = false,
	Text = localPlayer.DisplayName,
	Parent = idInner,
})
make("UIStroke", { Color = BLACK, Transparency = 0.6, Thickness = 1, Parent = myName }) -- text-shadow

-- Lobby cards (LobbyCard.ts) ----------------------------------------------------------
local cards = {}

local function lobbyPill(parent: Instance, order: number?): TextLabel
	local p = text({
		Name = "Pill",
		LayoutOrder = order or 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.MALIBU,
		FontFace = F.BOLD,
		TextSize = 12,
		Parent = parent,
	})
	corner(p, 4)
	padding(p, 8)
	return p
end

local function makeCard()
	local c: any = { previewSize = 360 }
	c.button = make("TextButton", { Name = "LobbyCard", Text = "", AutoButtonColor = false, BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = playPage })
	corner(c.button, 16)
	local glow = MenuKit.stroke(c.button, 1, C.MALIBU, 2)
	-- CanvasGroup so the image and the bottom bar get the rounded corners too.
	local okCanvas, canvas = pcall(Instance.new, "CanvasGroup")
	if not okCanvas then
		canvas = Instance.new("Frame")
	end
	canvas.Name = "Clip"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundColor3 = C.SURFACE
	canvas.BorderSizePixel = 0
	canvas.Parent = c.button
	corner(canvas, 16)
	c.image = make("ImageLabel", { Name = "Map", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.05, 1.05), ScaleType = Enum.ScaleType.Crop, Visible = false, Parent = canvas })
	MenuKit.hover(c.button, function(s)
		glow.Transparency = if s == "idle" then 1 else 0
		c.image.Size = if s == "idle" then UDim2.fromScale(1.05, 1.05) else UDim2.fromScale(1.12, 1.12)
	end)
	local pills = make("Frame", { Name = "Pills", Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -110, 0, 84), BackgroundTransparency = 1, Parent = canvas })
	MenuKit.list(pills, false, 4)
	c.pill1 = lobbyPill(pills, 1)
	c.pill2 = lobbyPill(pills, 2)
	c.pill3 = lobbyPill(pills, 3) -- (public lobbies: up to three modifiers)
	c.timer = lobbyPill(canvas)
	c.timer.AnchorPoint = Vector2.new(1, 0)
	c.timer.Position = UDim2.new(1, -8, 0, 8)
	local bar = make("Frame", { Name = "Bar", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = BLACK, BackgroundTransparency = 0.35, BorderSizePixel = 0, Parent = canvas })
	c.bar = bar
	c.title = text({ Position = UDim2.fromOffset(12, 7), Size = UDim2.new(1, -24, 0, 18), FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = bar })
	c.sub = text({ Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -24, 0, 15), TextSize = 12, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = bar })
	c.badge = make("Frame", { Name = "Count", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -8, 1, -52), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), BackgroundColor3 = BLACK, BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = canvas })
	corner(c.badge, 4)
	padding(c.badge, 8)
	MenuKit.list(c.badge, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
	c.count = text({ LayoutOrder = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), FontFace = F.BOLD, TextSize = 12, Parent = c.badge })
	c.countIcon = MenuKit.icon("People", { LayoutOrder = 2, Size = UDim2.fromOffset(16, 16), Parent = c.badge })
	cards[#cards + 1] = c
	return c
end

local featured = makeCard()
local small = { makeCard(), makeCard() }

-- "Upcoming" heading: also the way into the full list (GameModeSelector.renderUpcomingHeading).
local upHeader = make("TextButton", { Name = "Upcoming", Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BackgroundTransparency = 0.96, BorderSizePixel = 0, Parent = playPage })
corner(upHeader, 8)
local upStroke = MenuKit.stroke(upHeader, 0.9)
local upLabel = text({ Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -140, 1, 0), FontFace = F.BOLD, TextSize = 14, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "UPCOMING", Parent = upHeader })
local seeAll = make("Frame", { Name = "SeeAll", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), BackgroundColor3 = C.MALIBU, BorderSizePixel = 0, Parent = upHeader })
corner(seeAll, 4)
MenuKit.pad(seeAll, 8, 4, 0, 0)
MenuKit.list(seeAll, true, 2, { VerticalAlignment = Enum.VerticalAlignment.Center })
local seeAllText = text({ LayoutOrder = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), FontFace = F.BOLD, TextSize = 12, Text = "SEE ALL", Parent = seeAll })
MenuKit.icon("Chevron", { LayoutOrder = 2, Size = UDim2.fromOffset(16, 16), Parent = seeAll })
MenuKit.hover(upHeader, function(s)
	local on = s ~= "idle"
	upStroke.Color = if on then C.MALIBU else WHITE
	upStroke.Transparency = if on then 0.5 else 0.9
	upHeader.BackgroundColor3 = if on then C.MALIBU else WHITE
	upHeader.BackgroundTransparency = if on then 0.85 else 0.96
	upLabel.TextTransparency = if on then 0 else 0.3
	seeAll.BackgroundColor3 = if on then C.AQUARIUS else C.MALIBU
end)

-- Action cards ----------------------------------------------------------------------
-- Our primary action joins the server's round (OpenFront's slot here is "Solo").
local playBtn = MenuKit.button("primary", { Name = "Play", Text = if Place.role() == "lobby" then "SOLO" else "PLAY", Parent = playPage })
local tutBtn = MenuKit.button("tutorial", { Name = "Tutorial", Text = "TUTORIAL", Parent = playPage })
local soonButtons = {}
for i, label in { "CREATE LOBBY", "RANKED", "JOIN LOBBY" } do
	soonButtons[i] = MenuKit.button("secondary", { Name = "Soon" .. i, Text = label, Parent = playPage })
end

-- Footer ----------------------------------------------------------------------------
local footer = make("Frame", { Name = "Footer", BackgroundColor3 = C.ZINC900, BackgroundTransparency = 0.1, BorderSizePixel = 0, Parent = scroll })
make("Frame", { Name = "Border", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = footer })
local githubBtn = make("TextButton", { Name = "GitHub", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Parent = footer })
local githubIcon = MenuKit.icon("Github", { Size = UDim2.fromScale(1, 1), ImageTransparency = 0.4, Parent = githubBtn })
MenuKit.hover(githubBtn, function(s)
	githubIcon.ImageTransparency = if s == "idle" then 0.4 else 0
end)
local footVersion = text({ Name = "Version", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.new(1, -32, 0, 16), TextSize = 12, TextTransparency = 0.5, Text = VERSION, Parent = footer })
local footLinks = make("Frame", { Name = "Links", AnchorPoint = Vector2.new(0.5, 0), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 16), BackgroundTransparency = 1, Parent = footer })
MenuKit.list(footLinks, true, 16, { VerticalAlignment = Enum.VerticalAlignment.Center })
local function footLink(label: string, order: number, onClick: (() -> ())?): GuiObject
	local props = { Name = label, LayoutOrder = order, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 16), TextSize = 12, TextTransparency = 0.5, Text = label, Parent = footLinks }
	if not onClick then
		return text(props)
	end
	props.AutoButtonColor = false
	props.BackgroundTransparency = 1
	props.FontFace = F.REGULAR
	props.TextColor3 = WHITE
	local b = make("TextButton", props)
	MenuKit.hover(b, function(s)
		b.TextTransparency = if s == "idle" then 0.5 else 0
	end)
	b.Activated:Connect(onClick)
	return b
end
local langBtn = make("TextButton", { Name = "Language", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Parent = footer })
local langFlag = MenuKit.icon("LangFlag", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.86), ImageTransparency = 0.4, Parent = langBtn })
MenuKit.hover(langBtn, function(s)
	langFlag.ImageTransparency = if s == "idle" then 0.4 else 0
	langFlag.Size = if s == "idle" then UDim2.fromScale(0.86, 0.86) elseif s == "press" then UDim2.fromScale(0.78, 0.78) else UDim2.fromScale(0.94, 0.94)
end)

-- Inline page (shared by every page) ----------------------------------------------------
local closePage: () -> ()
local page = MenuKit.page(scroll, "", function()
	closePage()
end)

-- Mobile drawer (MobileNavBar) --------------------------------------------------------
local drawerBackdrop = make("TextButton", { Name = "DrawerBackdrop", Text = "", AutoButtonColor = false, Selectable = false, BackgroundColor3 = BLACK, BackgroundTransparency = 0.4, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 20, Parent = screen })
local drawer = make("Frame", { Name = "Drawer", BackgroundColor3 = BLACK, BackgroundTransparency = 0.3, BorderSizePixel = 0, Visible = false, ZIndex = 21, Active = true, Parent = screen })
make("Frame", { Name = "Border", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, ZIndex = 21, Parent = drawer })
setSelectionGroup(drawer)
local drawerList = make("ScrollingFrame", { Name = "List", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0, Selectable = false, ZIndex = 21, Parent = drawer })
MenuKit.pad(drawerList, 20, 20, 16, 16)
MenuKit.list(drawerList, false, 16)
do
	local logo = make("Frame", { Name = "Logo", LayoutOrder = 0, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 80), Parent = drawerList })
	local w = wordmark(logo, "Wordmark")
	w.Size = UDim2.new(1, 0, 0, 48)
	make("UISizeConstraint", { MaxSize = Vector2.new(220, 48), Parent = w })
	w.AnchorPoint = Vector2.new(0.5, 0)
	w.Position = UDim2.fromScale(0.5, 0)
	local v = versionLabel(logo)
	v.Position = UDim2.fromOffset(0, 52)
	v.Size = UDim2.new(1, 0, 0, 18)
	for i, item in NAV do
		navLink(drawerList, item.key, item.label, i, true)
	end
end
for _, d in drawer:GetDescendants() do
	if d:IsA("GuiObject") then
		d.ZIndex = 22
	end
end

-- Account menu dropdown (NavAccountMenu) -------------------------------------------------
local accountCatcher = make("TextButton", { Name = "AccountCatcher", Text = "", AutoButtonColor = false, Selectable = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 30, Parent = screen })
local accountMenu = make("Frame", { Name = "AccountMenu", BackgroundColor3 = C.ZINC900, BorderSizePixel = 0, Size = UDim2.fromOffset(240, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, ZIndex = 31, Parent = screen })
corner(accountMenu, 12)
MenuKit.stroke(accountMenu, 0.9)
MenuKit.list(accountMenu, false, 0)
setSelectionGroup(accountMenu)
local accountItems: { TextButton } = {}
local function accountItem(order: number, iconName: string, label: string, onClick: () -> ())
	local b = make("TextButton", { Name = label, LayoutOrder = order, Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 44), ZIndex = 32, Parent = accountMenu })
	MenuKit.icon(iconName, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 16, 0.5, 0), Size = UDim2.fromOffset(16, 16), ImageTransparency = 0.2, ZIndex = 33, Parent = b })
	text({ Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -56, 1, 0), FontFace = F.MEDIUM, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Text = label, ZIndex = 33, Parent = b })
	MenuKit.hover(b, function(s)
		b.BackgroundTransparency = if s == "idle" then 1 else 0.95
	end)
	b.Activated:Connect(onClick)
	accountItems[#accountItems + 1] = b
end

-- Toasts (own ScreenGui so they also show over the match) ------------------------------
local toastGui = make("ScreenGui", { Name = "FrontlinesMenuToast", DisplayOrder = 25, IgnoreGuiInset = true, ResetOnSpawn = false, Parent = playerGui })
local toast = text({
	Name = "Toast",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.16, 0),
	AutomaticSize = Enum.AutomaticSize.X,
	Size = UDim2.fromOffset(0, 42),
	BackgroundTransparency = 0.05,
	BackgroundColor3 = C.ZINC900,
	FontFace = F.MEDIUM,
	TextSize = 15,
	Visible = false,
	Parent = toastGui,
})
corner(toast, 8)
MenuKit.stroke(toast, 0.9)
padding(toast, 18)
local toastSeq = 0
local function showToast(msg: string, seconds: number?)
	toastSeq += 1
	local mine = toastSeq
	toast.Text = msg
	toast.Visible = true
	task.delay(seconds or 2.5, function()
		if toastSeq == mine then
			toast.Visible = false
		end
	end)
end

-- MENU button (only while the menu is closed outside a match, e.g. spectating) ---------------
local menuBtnGui = make("ScreenGui", { Name = "FrontlinesMenuButton", DisplayOrder = 9, IgnoreGuiInset = true, ResetOnSpawn = false, Enabled = false, Parent = playerGui })
local menuBtn = MenuKit.button("secondary", { Name = "Menu", Text = "MENU", TextSize = 14, FontFace = F.BOLD, Parent = menuBtnGui })
MenuKit.icon("Menu", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -20, 0.5, 0), Size = UDim2.fromOffset(18, 18), Parent = menuBtn })
MenuKit.pad(menuBtn, 30, 10, 0, 0)

-- Rendering
local profile: any = nil

local function setPreview(c)
	local id = c.mapId
	local key = if id then id .. "@" .. c.previewSize else nil
	if key ~= nil and key == c.shownKey then
		return
	end
	local img = if key then previews[key] else nil
	if img then
		local ok = pcall(function()
			c.image.ImageContent = Content.fromObject(img)
		end)
		if ok then
			c.shownKey = key
			c.image.Visible = true
			return
		end
		previews[key :: string] = false
	end
	c.shownKey = nil
	c.image.Visible = false
	if id and img == nil then
		requestPreview(id, c.previewSize)
	end
end

local function setPill(p: TextLabel, label: string?)
	p.Visible = label ~= nil
	if label then
		p.Text = label
	end
end

local function setCard(c, info)
	c.mapId = info.id
	c.mode = info.mode
	c.title.Text = string.upper(info.name or mapName(info.id))
	c.sub.Text = info.sub or "FREE FOR ALL"
	setPill(c.pill1, info.pill1)
	setPill(c.pill2, info.pill2)
	setPill(c.pill3, info.pill3)
	c.timerMode = info.timer
	c.lobby = info.lobby -- public lobby view (lobby place)
	c.badge.Visible = info.count ~= nil
	c.count.Text = info.count or ""
	c.countIcon.Visible = info.countIcon ~= false
	setPreview(c)
end

local function timerText(mode: string?, c: any?): string?
	if mode == "lobby" and c and c.lobby then
		-- GameModeSelector.renderLobbyCard: default lobby time, the countdown, then "Starting…".
		local l = c.lobby
		if l.started then
			return "STARTING…"
		elseif l.endAt then
			local left = l.endAt - os.clock()
			return if left > 0 then formatTime(math.ceil(left)) else "STARTING…"
		end
		return formatTime(l.default or 60)
	elseif mode == "remaining" then
		local left = state.phaseEnd - os.clock()
		return if left > 0 then formatTime(left) else "STARTING…"
	elseif mode == "elapsed" and state.playStart then
		return formatTime(os.clock() - state.playStart)
	end
	return nil
end

local upcomingRefresh: (() -> ())? = nil

local function updateTimers()
	for _, c in cards do
		local t = timerText(c.timerMode, c)
		c.timer.Visible = t ~= nil
		if t then
			c.timer.Text = t
		end
	end
	if upcomingRefresh then
		upcomingRefresh()
	end
end

local function leadingOption()
	local best = nil
	for _, o in state.options do
		if not best or (o.votes or 0) > (best.votes or 0) then
			best = o
		end
	end
	return best
end

local function poolAfter(current: string?, count: number)
	local pool = mapPool()
	local start = 0
	for i, m in pool do
		if m.id == current then
			start = i
		end
	end
	local out = {}
	for k = 1, #pool do
		local m = pool[(start + k - 1) % #pool + 1]
		if m.id ~= current then
			out[#out + 1] = m
			if #out >= count then
				break
			end
		end
	end
	return out
end

local function renderAccount()
	for _, b in accountButtons do
		local img = b:FindFirstChild("Avatar") :: ImageLabel
		local cached = thumbs[localPlayer.UserId]
		if type(cached) == "string" then
			img.Image = cached
		elseif cached == nil then
			-- setAvatar fetches and caches the headshot.
			local dummy = text({ Text = "" })
			setAvatar(img, dummy, localPlayer.UserId, localPlayer.DisplayName)
			dummy:Destroy()
		end
	end
end

local function tutorialShown(): boolean
	-- GameModeSelector TUTORIAL_CARD_MAX_GAMES: the card shows until 5 games are played.
	return profile == nil or (tonumber(profile.games) or 0) < 5
end

local function renderCards()
	local phase = state.phase
	local lobby = phase == "Lobby" and #state.options > 0
	if state.lobbies then
		-- Lobby place (GameModeSelector): FFA is the hero card, Teams and Special the column.
		local seen = 0
		for i, kind in { "ffa", "team", "special" } do
			local l = state.lobbies[kind]
			local c = if i == 1 then featured else small[i - 1]
			if l then
				seen += 1
				local mods = table.clone(l.mods or {})
				table.sort(mods, function(a, b)
					return #a > #b -- longest first, so the pills that say the most stay legible
				end)
				setCard(c, {
					id = l.map,
					name = l.name,
					mode = "public",
					sub = string.upper(tostring(l.sub or "")),
					pill1 = if mods[1] then string.upper(mods[1]) else nil,
					pill2 = if mods[2] then string.upper(mods[2]) else nil,
					pill3 = if mods[3] then string.upper(mods[3]) else nil,
					timer = "lobby",
					lobby = l,
					count = tostring(l.count or 0) .. "/" .. tostring(l.max or "?"),
				})
				c.lobbyType = kind
			end
			if i > 1 then
				c.button.Visible = l ~= nil and c.layoutVisible == true
			end
		end
		seeAllText.Text = if seen > 0 then "SEE ALL " .. seen else ""
		updateTimers()
		return
	end

	-- Featured: the round being played (or, in the lobby, the map currently leading the vote).
	local f: any = { mode = "play", sub = state.mode }
	if lobby then
		local lead = leadingOption()
		f.id = if lead then lead.id else state.mapId
		f.name = if lead then lead.name else nil
		f.pill1 = "NEXT MAP"
		if lead and state.myVote == lead.id then
			f.pill2 = "YOUR VOTE"
		end
		f.timer = "remaining"
	else
		f.id = state.mapId or (MapCatalog[1] and MapCatalog[1].id)
		if phase == "Play" then
			f.pill1 = "IN PROGRESS"
			f.timer = "elapsed"
		elseif phase == "Spawn" then
			f.pill1 = "SPAWNING"
			f.timer = "remaining"
		elseif phase == "Ended" then
			f.pill1 = "ENDED"
			f.timer = "remaining"
		elseif phase == "Lobby" then
			f.timer = "remaining"
		end
	end
	local n = if phase == "Spawn" or phase == "Play" then state.humans else #Players:GetPlayers()
	f.count = n .. "/" .. Players.MaxPlayers
	if state.queue then
		f.count = tostring(state.queue.count or 0) .. "/" .. tostring(state.queue.max or Players.MaxPlayers)
	end
	setCard(featured, f)

	-- Upcoming: vote options in the lobby, otherwise a peek at the map pool.
	local seeAllCount
	if lobby then
		seeAllCount = #state.options
		for i, c in small do
			local o = state.options[i]
			c.button.Visible = o ~= nil and c.layoutVisible == true
			if o then
				local votes = o.votes or 0
				setCard(c, {
					id = o.id,
					name = o.name,
					mode = "vote",
					pill1 = if state.myVote == o.id then "YOUR VOTE" else "VOTE",
					timer = "remaining",
					count = votes .. (if votes == 1 then " vote" else " votes"),
					countIcon = false,
					sub = state.mode or "FREE FOR ALL",
				})
			end
		end
	else
		local others = poolAfter(state.mapId, 2)
		seeAllCount = #mapPool()
		for i, c in small do
			local m = others[i]
			c.button.Visible = m ~= nil and c.layoutVisible == true
			if m then
				setCard(c, { id = m.id, name = m.name, mode = "pool", pill1 = "MAP POOL", sub = "FREE FOR ALL" })
			end
		end
	end
	seeAllText.Text = if seeAllCount > 0 then "SEE ALL " .. seeAllCount else ""
	updateTimers()
end

local updateFloating: () -> ()
local relayout: () -> ()
local tutorialWasShown = true

refresh = function()
	renderAccount()
	renderCards()
	if tutorialShown() ~= tutorialWasShown then
		tutorialWasShown = tutorialShown()
		relayout()
	end
	if updateFloating then
		updateFloating()
	end
end

-- Layout
local function layoutMenuButton()
	-- Top-right, next to the profile chip (the in-match leaderboard owns the top-left).
	local st = DeviceLayout.state
	local pad = DeviceLayout.usingGamepad()
	menuBtn.AnchorPoint = Vector2.new(1, 0)
	if st.profile == "phone" then
		menuBtn.Position = UDim2.new(1, -6, 0, 6 + DeviceLayout.PHONE_CHIP_HEIGHT + 6)
		menuBtn.Size = UDim2.fromOffset(if pad then 140 else 96, 34)
		DeviceLayout.setScale(menuBtn, 1)
	else
		local scale = if st.profile == "console" then st.scale else 1
		menuBtn.Position = UDim2.new(1, -12 - 250 * scale - 8, 0, 12)
		menuBtn.Size = UDim2.fromOffset(if pad then 150 else 108, 36)
		DeviceLayout.setScale(menuBtn, scale)
	end
	menuBtn.Text = if pad then "MENU (START)" else "MENU"
end

local function layoutFooter(LX: number, mobile: boolean): number
	local iconS = if mobile then 24 else 28
	local y = 4 + 8
	place(githubBtn, LX / 2 - iconS / 2, y, iconS, iconS)
	y += iconS + (if mobile then 4 else 8)
	footVersion.Position = UDim2.new(0.5, 0, 0, y)
	y += 16 + (if mobile then 4 else 8)
	footLinks.Position = UDim2.new(0.5, 0, 0, y)
	y += 16 + 12
	local ls = if mobile then 40 else 56
	langBtn.Size = UDim2.fromOffset(ls, ls)
	langBtn.AnchorPoint = if mobile then Vector2.new(1, 0) else Vector2.new(1, 0.5)
	langBtn.Position = if mobile then UDim2.new(1, -16, 0, 12) else UDim2.new(1, -16, 0.5, 0)
	return y
end

local function layoutCard(c, x: number, y: number, w: number, h: number)
	place(c.button, x, y, w, h)
	local compact = w < 320
	c.title.TextSize = if compact then 14 else 16
	c.previewSize = if w > 420 then 480 else 320
end

relayout = function()
	local X, Y = gui.AbsoluteSize.X, gui.AbsoluteSize.Y
	if X < 2 or Y < 2 then
		return
	end
	local st = DeviceLayout.state
	layoutMenuButton()
	toast.Position = if st.profile == "phone" then UDim2.new(0.5, 0, 0, 10) else UDim2.new(0.5, 0, 0.16, 0)
	DeviceLayout.setScale(toast, if st.profile == "console" then st.scale elseif st.profile == "phone" then 0.85 else 1)

	-- Backdrop covers the full screen even outside the safe area.
	local il, it, ir, ib = DeviceLayout.insets(gui)
	backdrop.Position = UDim2.fromOffset(-il, -it)
	backdrop.Size = UDim2.new(1, il + ir, 1, it + ib)

	local s = if st.profile == "console" then math.max(1, st.scale or 1) else 1
	screenScale.Scale = s
	local LX, LY = X / s, Y / s
	screen.Size = UDim2.fromOffset(LX, LY)
	local mobile = LX < 1024 -- Tailwind lg
	local sm = LX >= 640 -- Tailwind sm

	-- Bars.
	local navH
	nav.Visible = not mobile
	topBar.Visible = mobile
	if mobile then
		navH = 56
		place(topBar, 0, 0, LX, navH)
		topLogo.Size = UDim2.fromOffset(math.clamp(LX - 2 * 190, 90, 170), 26)
	else
		navH = 84
		place(nav, 0, 0, LX, navH)
		task.defer(function()
			local w = navRow.AbsoluteSize.X / math.max(0.01, navRowScale.Scale * s)
			if w > 0 then
				navRowScale.Scale = math.min(1, (LX - 24) / w)
			end
		end)
	end
	if not mobile then
		drawer.Visible = false
		drawerBackdrop.Visible = false
	end
	place(drawer, 0, 0, LX * 0.7, LY)
	place(scroll, 0, navH, LX, LY - navH)
	local viewH = LY - navH

	-- Main column (MainLayout: lg:max-w-[20cm] 2xl:max-w-[24cm], clamp() paddings).
	local mainX, W, pt, pb
	if not mobile then
		local px = math.clamp(0.03 * LX, 24, 48)
		pt = math.clamp(0.015 * LX, 12, 24)
		pb = math.clamp(0.0075 * LX, 6, 12)
		W = math.min(LX - 2 * px, if LX >= 1536 then 907 else 756)
		mainX = (LX - W) / 2
	else
		pt, pb = 0, 0
		mainX = if sm then 16 else 0
		W = LX - 2 * mainX
	end
	local footerH = if mobile then 88 else 100
	layoutFooter(LX, mobile)

	local y = pt
	if currentPage then
		playPage.Visible = false
		page.frame.Visible = true
		page:layout(mobile)
		local pageH = if mobile then viewH else math.max(320, viewH - pt - pb - footerH)
		local px = if mobile then 0 else mainX
		place(page.frame, px, y, if mobile then LX else W, pageH)
		y += pageH + pb
	else
		playPage.Visible = true
		page.frame.Visible = false
		-- PlayPage: lg:px-4 inside the main column; the top strip is full-bleed below lg.
		local playX = if mobile then mainX else mainX + 16
		local CW = if mobile then W else W - 32

		-- News + identity row.
		local stripX = if mobile then 0 else playX
		local stripW = if mobile then LX else CW
		local items = visibleNews()
		news:SetAttribute("LayoutVisible", #items > 0)
		renderNews()
		local rounded = not mobile
		newsCorner.CornerRadius = UDim.new(0, if rounded then 12 else 0)
		newsBorderT.Visible = not rounded
		newsBorderB.Visible = not rounded
		if #items > 0 then
			local p = if mobile then 8 else 12
			local h = p * 2 + 36
			place(news, stripX, y, stripW, h)
			newsTag.Position = UDim2.new(0, p, 0.5, 0)
			local tagW = newsTag.AbsoluteSize.X / s
			if tagW <= 0 then
				tagW = 64
			end
			local tx = p + tagW + 12
			local right = 24 + 8 + (if #newsDotButtons > 1 then #newsDotButtons * 10 + 8 else 0)
			place(newsTitle, tx, p, stripW - tx - right - p, 20)
			place(newsDesc, tx, p + 20, stripW - tx - right - p, 16)
			newsClose.Position = UDim2.new(1, -p, 0.5, 0)
			newsDots.Position = UDim2.new(1, -(p + 24 + 8), 0.5, 0)
			y += h + (if mobile then 16 else 8)
		end
		local idH = if mobile and not sm then 48 else 60
		place(identity, stripX, y, stripW, idH)
		identityCorner.CornerRadius = UDim.new(0, if mobile and not sm then 0 else 12)
		place(idInner, 4, 4, stripW - 8, idH - 8)
		local inH = idH - 8
		place(tagBtn, 4, (inH - math.min(44, inH)) / 2, 116, math.min(44, inH))
		place(myName, 128, 0, stripW - 8 - 140, inH)
		myName.TextSize = if mobile and not sm then 20 else 24
		y += idH + (if mobile then 16 + 8 else 8)

		-- Game mode selector.
		local tut = tutorialShown()
		tutBtn.Visible = tut
		local btnText = if mobile then 14 else 16
		local function actionRows(x: number, yy: number, w: number): number
			if tut then
				local w2 = (w - 16) * 2 / 3
				place(playBtn, x, yy, w2, 56)
				place(tutBtn, x + w2 + 16, yy, w - w2 - 16, 56)
			else
				place(playBtn, x, yy, w, 56)
			end
			yy += 56 + 16
			local w3 = (w - 32) / 3
			for i, b in soonButtons do
				place(b, x + (i - 1) * (w3 + 16), yy, w3, 56)
				b.TextSize = if w3 < 110 then 12 else btnText
			end
			playBtn.TextSize = btnText
			tutBtn.TextSize = btnText
			return yy + 56
		end
		for _, c in small do
			c.layoutVisible = true
		end
		if sm then
			y += 16 -- empty first grid row + row gap
			local heroH = math.min(384, 0.4 * LY)
			local c1 = math.floor((CW - 16) * 2 / 3)
			local c2 = CW - 16 - c1
			layoutCard(featured, playX, y, c1, heroH)
			local x2 = playX + c1 + 16
			place(upHeader, x2, y, c2, 32)
			local ch = (heroH - 32 - 32) / 2
			layoutCard(small[1], x2, y + 48, c2, ch)
			layoutCard(small[2], x2, y + 48 + ch + 16, c2, ch)
			y += heroH + 16
			y = actionRows(playX, y, CW)
		else
			-- Phone order: action rows, featured card, upcoming cards, heading.
			local x, w = 16, LX - 32
			y = actionRows(x, y, w) + 16
			layoutCard(featured, x, y, w, 176)
			y += 176 + 16
			layoutCard(small[1], x, y, w, 176)
			y += 176 + 16
			layoutCard(small[2], x, y, w, 176)
			y += 176 + 16
			place(upHeader, x, y, w, 32)
			y += 32 + 16
		end
		y += pb
		place(playPage, 0, 0, LX, y)
	end

	local footerY = math.max(y, viewH - footerH)
	place(footer, 0, footerY, LX, footerH)
	scroll.CanvasSize = UDim2.fromOffset(0, footerY + footerH)
	queueRefresh()
end

local layoutQueued = false
local function queueLayout()
	if layoutQueued then
		return
	end
	layoutQueued = true
	task.defer(function()
		layoutQueued = false
		relayout()
	end)
end

-- Show / hide, pages, actions
local menuVisible = false
local B_ACTION = "FrontlinesMainMenuB"
local START_ACTION = "FrontlinesMainMenuStart"
local lastMetaButton: GuiObject? = nil
local pageOpener: GuiObject? = nil

local function metaGui(): Instance?
	return playerGui:FindFirstChild("FrontlinesMeta")
end

local function setChipVisible(v: boolean)
	local meta = metaGui()
	local chip = meta and meta:FindFirstChild("ProfileChip")
	if chip and chip:IsA("GuiObject") then
		chip.Visible = v
	end
end

local function openMeta(tab: string)
	local meta = metaGui()
	local ev = meta and meta:FindFirstChild("Open")
	if ev and ev:IsA("BindableEvent") then
		ev:Fire(tab)
	end
end

local function selectIfGamepad(obj: GuiObject?)
	if obj and DeviceLayout.usingGamepad() then
		task.defer(function()
			if obj.Visible and obj:IsDescendantOf(playerGui) then
				GuiService.SelectedObject = obj
			end
		end)
	end
end

local function inMatch(): boolean
	return state.inRound and (state.phase == "Spawn" or state.phase == "Play")
end

-- During a match with the menu closed, the top-right corner belongs to the in-match bar.
updateFloating = function()
	-- (also hidden while a replay plays: its controls own the screen, Replay.lua)
	local show = not menuVisible and not inMatch() and playerGui:GetAttribute("WFReplay") ~= true
	menuBtnGui.Enabled = show
	setChipVisible(show)
end
playerGui:GetAttributeChangedSignal("WFReplay"):Connect(function()
	updateFloating()
end)

local function closeDrawer()
	if drawer.Visible then
		drawer.Visible = false
		drawerBackdrop.Visible = false
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(drawer) then
			GuiService.SelectedObject = nil
			selectIfGamepad(hamburger)
		end
	end
end

local function openDrawer()
	drawer.Visible = true
	drawerBackdrop.Visible = true
	selectIfGamepad(navButtons.play[#navButtons.play])
end

local accountOpener: GuiObject? = nil
local function closeAccountMenu()
	if accountMenu.Visible then
		accountMenu.Visible = false
		accountCatcher.Visible = false
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(accountMenu) then
			GuiService.SelectedObject = nil
			selectIfGamepad(accountOpener)
		end
	end
end

local function openAccountMenu(from: GuiObject)
	accountOpener = from
	local s = screenScale.Scale
	local a, sz = from.AbsolutePosition, from.AbsoluteSize
	local sp = screen.AbsolutePosition
	local right = (a.X + sz.X - sp.X) / s
	local bottom = (a.Y + sz.Y - sp.Y) / s
	accountMenu.AnchorPoint = Vector2.new(1, 0)
	accountMenu.Position = UDim2.fromOffset(right, bottom + 8)
	accountMenu.Visible = true
	accountCatcher.Visible = true
	selectIfGamepad(accountItems[1])
end

local openPage: (string, GuiObject?) -> ()

local function renderUpcoming()
	page:setTabs({})
	page:clear()
	local lobby = state.phase == "Lobby" and #state.options > 0
	local entries = {}
	if state.lobbies then
		-- Lobby place: every public lobby (the lobby browser).
		for _, kind in { "ffa", "team", "special" } do
			local l = state.lobbies[kind]
			if l then
				entries[#entries + 1] = { id = l.map, name = l.name or mapName(l.map), info = string.upper(tostring(l.sub)) .. " · " .. tostring(l.count or 0) .. "/" .. tostring(l.max or "?"), lobbyType = kind, lobby = l }
			end
		end
	elseif lobby then
		for _, o in state.options do
			local votes = o.votes or 0
			entries[#entries + 1] = { id = o.id, name = o.name or mapName(o.id), info = votes .. (if votes == 1 then " vote" else " votes"), mine = state.myVote == o.id }
		end
	else
		for _, m in mapPool() do
			entries[#entries + 1] = { id = m.id, name = m.name, info = if m.id == state.mapId then "PLAYING NOW" else (m.width .. " x " .. m.height), mine = m.id == state.mapId }
		end
	end
	local status = MenuKit.paragraph(page.body, 0, "", { TextColor3 = WHITE, TextTransparency = 0.4 })
	local rows = {}
	for i, e in entries do
		local b = make("TextButton", { Name = e.id, LayoutOrder = i, Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 56), Parent = page.body })
		corner(b, 12)
		local st = MenuKit.stroke(b, if e.mine then 0.2 else 0.9, if e.mine then C.MALIBU else WHITE)
		text({ Position = UDim2.fromOffset(16, 0), Size = UDim2.new(0.6, -16, 1, 0), FontFace = F.BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = string.upper(e.name), Parent = b })
		local info = lobbyPill(b)
		info.AnchorPoint = Vector2.new(1, 0.5)
		info.Position = UDim2.new(1, -12, 0.5, 0)
		info.Text = if e.mine and lobby then "YOUR VOTE · " .. e.info else e.info
		info.BackgroundColor3 = if e.mine then C.MALIBU else BLACK
		info.BackgroundTransparency = if e.mine then 0 else 0.3
		MenuKit.hover(b, function(s)
			b.BackgroundTransparency = if s == "idle" then 0.95 else 0.9
			if not e.mine then
				st.Color = if s == "idle" then WHITE else C.MALIBU
				st.Transparency = if s == "idle" then 0.9 else 0.4
			end
		end)
		local id = e.id
		b.Activated:Connect(function()
			if e.lobbyType then
				LobbyPages.joinPublic(e.lobbyType, e.lobby)
				openPage("public", b)
			elseif state.phase == "Lobby" and #state.options > 0 then
				state.myVote = id
				net:FireServer("vote", id)
				queueRefresh()
				task.defer(function()
					if currentPage == "upcoming" then
						renderUpcoming()
					end
				end)
			else
				showToast("Voting opens after this round")
			end
		end)
		rows[#rows + 1] = b
	end
	upcomingRefresh = function()
		if state.lobbies then
			status.Text = "Pick a game to join. Each starts when its countdown ends or it is full."
		elseif state.phase == "Lobby" then
			status.Text = "Vote for the next map. Round starts in " .. formatTime(state.phaseEnd - os.clock())
		else
			status.Text = "Map pool. Voting opens after this round."
		end
	end
	upcomingRefresh()
end

local upcomingSignature = ""
local function upcomingSig(): string
	local sig = (state.phase or "") .. ":" .. (state.myVote or "")
	for _, o in state.options do
		sig ..= o.id .. "=" .. tostring(o.votes or 0) .. ","
	end
	return sig
end

closePage = function()
	if not currentPage then
		return
	end
	if LobbyPages.handles(currentPage) then
		LobbyPages.closed(currentPage) -- leave the lobby / ranked queue
	end
	currentPage = nil
	upcomingRefresh = nil
	page:clear()
	page:setTabs({})
	paintNav()
	relayout()
	scroll.CanvasPosition = Vector2.zero
	local sel = GuiService.SelectedObject
	if sel == nil or not sel:IsDescendantOf(playerGui) or sel:IsDescendantOf(page.frame) then
		GuiService.SelectedObject = nil
		selectIfGamepad(if pageOpener and pageOpener.Visible then pageOpener else playBtn)
	end
end

local function startTutorial()
	playerGui:SetAttribute("FrontlinesTutorial", true)
	state.hasPlayed = true
	net:FireServer("play")
	closePage()
	-- hideMenu is defined below; deferred so the page closes first.
	task.defer(function()
		local ev = gui:FindFirstChild("HideRequest")
		if ev then
			(ev :: BindableEvent):Fire()
		end
	end)
end

local pageCtx = {
	toast = function(msg: string)
		showToast(msg)
	end,
	startTutorial = startTutorial,
	getProfile = function()
		return profile
	end,
	close = function()
		closePage()
	end,
}

openPage = function(kind: string, from: GuiObject?)
	closeDrawer()
	closeAccountMenu()
	if kind == "play" then
		closePage()
		return
	end
	-- The store / stats window (MetaClient) never stays open over a menu page.
	openMeta("close")
	pageOpener = from or pageOpener
	currentPage = kind
	paintNav()
	page.title.Text = ""
	if kind == "upcoming" then
		page.title.Text = "UPCOMING"
		upcomingSignature = upcomingSig()
		renderUpcoming()
	elseif LobbyPages.handles(kind) then
		upcomingRefresh = nil
		LobbyPages.render(kind, page)
	else
		upcomingRefresh = nil
		MenuPages.render(kind, page, pageCtx)
	end
	relayout()
	scroll.CanvasPosition = Vector2.zero
	selectIfGamepad(page.back)
end

local function showMenu()
	if menuVisible then
		return
	end
	PauseMenu.close()
	menuVisible = true
	gui.Enabled = true
	playerGui:SetAttribute("FrontlinesMenuOpen", true)
	updateFloating()
	ContextActionService:BindActionAtPriority(B_ACTION, function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			if accountMenu.Visible then
				closeAccountMenu()
			elseif drawer.Visible then
				closeDrawer()
			elseif currentPage then
				closePage()
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 20, Enum.KeyCode.ButtonB)
	relayout()
	refresh()
	selectIfGamepad(if currentPage then page.back else playBtn)
end

local function hideMenu()
	if not menuVisible then
		return
	end
	menuVisible = false
	closeDrawer()
	closeAccountMenu()
	gui.Enabled = false
	playerGui:SetAttribute("FrontlinesMenuOpen", false)
	updateFloating()
	ContextActionService:UnbindAction(B_ACTION)
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
end

do
	local hideReq = Instance.new("BindableEvent")
	hideReq.Name = "HideRequest"
	hideReq.Parent = gui
	hideReq.Event:Connect(hideMenu)
end

local function play(tutorial: boolean)
	if tutorial and Place.role() == "lobby" then
		-- Lobby place: the tutorial is a solo match server (the overlay shows while it starts).
		net:FireServer("play", "tutorial")
		closePage()
		return
	end
	if tutorial then
		playerGui:SetAttribute("FrontlinesTutorial", true)
	end
	state.hasPlayed = true
	net:FireServer("play")
	closePage()
	hideMenu()
end

onJoined = function(data)
	if data.inRound == false and Place.role() ~= "match" then
		if Place.role() == "lobby" then
			showToast("You're in - the game starts when the countdown ends", 4)
		elseif data.phase == "Lobby" then
			showToast("You're in - the round starts after the map vote", 4)
		else
			showToast("Round in progress - you'll join the next one", 4)
		end
	end
	queueRefresh()
end

local function vote(id: string)
	if state.phase ~= "Lobby" or #state.options == 0 then
		showToast("Voting opens after this round")
		return
	end
	state.myVote = id
	net:FireServer("vote", id)
	queueRefresh()
end

-- Lobby place: a lobby card joins that public lobby and opens its waiting page.
local function joinPublic(c)
	if not (state.lobbies and c.lobbyType) then
		return false
	end
	LobbyPages.joinPublic(c.lobbyType, c.lobby)
	openPage("public", c.button)
	return true
end

playBtn.Activated:Connect(function()
	if Place.role() == "lobby" then
		-- SOLO (GameModeSelector main.solo): a single-player game right away.
		net:FireServer("play", "solo")
		closePage()
		return
	end
	play(false)
end)
featured.button.Activated:Connect(function()
	if not joinPublic(featured) then
		play(false)
	end
end)
tutBtn.Activated:Connect(function()
	play(true)
end)
for i, b in soonButtons do
	b.Activated:Connect(function()
		if Place.role() == "lobby" then
			openPage(if i == 1 then "host" elseif i == 2 then "ranked" else "join", b)
		else
			showToast("Coming Soon")
		end
	end)
end
for _, c in small do
	c.button.Activated:Connect(function()
		if joinPublic(c) then
			return
		elseif c.mode == "vote" and c.mapId then
			vote(c.mapId)
		else
			showToast("Voting opens after this round")
		end
	end)
end
upHeader.Activated:Connect(function()
	openPage("upcoming", upHeader)
end)
tagBtn.Activated:Connect(function()
	showToast("Clan tags: Coming Soon")
end)
newsClose.Activated:Connect(function()
	local items = visibleNews()
	local item = items[newsIndex]
	if item then
		newsDismissed[item.id] = true
	end
	if GuiService.SelectedObject == newsClose then
		GuiService.SelectedObject = nil
		selectIfGamepad(playBtn)
	end
	relayout()
end)
githubBtn.Activated:Connect(function()
	showToast("Source: " .. tostring(Config.SOURCE_URL), 6)
end)
footLink("Source Code", 1, function()
	showToast("Source: " .. tostring(Config.SOURCE_URL), 6)
end)
footLink("© OpenFront and Contributors", 2, nil)
footLink("Licenses", 3, function()
	showToast("AGPL-3.0 · " .. tostring(Config.ASSET_CREDIT), 6)
end)
langBtn.Activated:Connect(function()
	openPage("language", langBtn)
end)
for key, list in navButtons do
	for _, b in list do
		b.Activated:Connect(function()
			openPage(key, b)
		end)
	end
end
for key, list in utilButtons do
	for _, b in list do
		b.Activated:Connect(function()
			if currentPage == key then
				closePage()
			else
				openPage(key, b)
			end
		end)
	end
end
for _, b in accountButtons do
	b.Activated:Connect(function()
		if accountMenu.Visible then
			closeAccountMenu()
		else
			openAccountMenu(b)
		end
	end)
end
accountItem(1, "User", "View account", function()
	openPage("profile", accountOpener)
end)
accountItem(2, "Gear", "Settings", function()
	openPage("settings", accountOpener)
end)
accountItem(3, "Layout", "Store", function()
	openPage("store", accountOpener)
end)
accountCatcher.Activated:Connect(closeAccountMenu)
hamburger.Activated:Connect(openDrawer)
drawerBackdrop.Activated:Connect(closeDrawer)

PauseMenu.init({
	showMainMenu = showMenu,
	isMainMenuOpen = function()
		return menuVisible
	end,
	onLeave = function()
		state.inRound = false
		if Place.role() == "match" and not RunService:IsStudio() then
			return -- the server sends us back to the lobby place
		end
		showMenu()
	end,
})
menuBtn.Activated:Connect(function()
	if inMatch() then
		PauseMenu.open()
	else
		showMenu()
	end
end)

-- Gamepad Start toggles the menu - the pause menu during a round (or closes the store window if it's open).
-- On consoles Roblox keeps Start (Menu) for its own menu, so View/Select does the same.
ContextActionService:BindActionAtPriority(START_ACTION, function(_name, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local meta = metaGui()
	local window = meta and meta:FindFirstChild("MetaWindow")
	if window and window:IsA("GuiObject") and window.Visible then
		openMeta("close")
	elseif menuVisible then
		if state.inRound or state.hasPlayed then
			hideMenu()
		end
	elseif PauseMenu.isOpen() then
		PauseMenu.close()
	elseif inMatch() then
		PauseMenu.open()
	else
		showMenu()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.ButtonStart, Enum.KeyCode.ButtonSelect)

-- Esc: account menu / drawer / page first (BaseModal closes on Escape), then the menu itself once
-- the player is playing (Roblox may keep Esc for its own menu).
UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode ~= Enum.KeyCode.Escape or not menuVisible or UserInputService:GetFocusedTextBox() then
		return
	end
	if accountMenu.Visible then
		closeAccountMenu()
	elseif drawer.Visible then
		closeDrawer()
	elseif currentPage then
		closePage()
	elseif state.inRound or state.hasPlayed then
		hideMenu()
	end
end)

-- Profile chip / store window live in MetaClient's ScreenGui, which may load after us.
local function hookMeta(meta: Instance)
	task.spawn(function()
		local chip = meta:WaitForChild("ProfileChip", 10)
		if chip and chip:IsA("GuiObject") then
			updateFloating()
		end
		local window = meta:WaitForChild("MetaWindow", 10)
		if window and window:IsA("GuiObject") then
			window:GetPropertyChangedSignal("Visible"):Connect(function()
				if not window.Visible and menuVisible then
					task.defer(function()
						if menuVisible and GuiService.SelectedObject == nil then
							selectIfGamepad(lastMetaButton or playBtn)
						end
					end)
				end
			end)
		end
	end)
end
playerGui.ChildAdded:Connect(function(child)
	if child.Name == "FrontlinesMeta" then
		hookMeta(child)
	end
end)
do
	local meta = metaGui()
	if meta then
		hookMeta(meta)
	end
end

-- Profile data.
local function applyProfile(p: any)
	if type(p) == "table" then
		profile = p
		queueRefresh()
	end
end
task.spawn(function()
	local metaEvent = Shared:WaitForChild("Meta")
	metaEvent.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "profile" then
			applyProfile(data)
		end
	end)
	local metaFn = Shared:WaitForChild("MetaFn")
	local ok, success, p = pcall(function()
		return metaFn:InvokeServer("get")
	end)
	if ok and success then
		applyProfile(p)
	end
end)

Players.PlayerAdded:Connect(queueRefresh)
Players.PlayerRemoving:Connect(function()
	task.defer(queueRefresh)
end)

DeviceLayout.attachScreenGui(gui)
DeviceLayout.attachScreenGui(menuBtnGui)
DeviceLayout.attachScreenGui(toastGui)
DeviceLayout.Changed:Connect(function()
	queueLayout()
	if menuVisible and DeviceLayout.usingGamepad() and GuiService.SelectedObject == nil then
		selectIfGamepad(if currentPage then page.back else playBtn)
	end
end)
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)
menuBtnGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)
newsTag:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)

-- News rotation (NewsBox CYCLE_INTERVAL_MS = 5000), timers, live upcoming page.
task.spawn(function()
	while true do
		task.wait(5)
		local items = visibleNews()
		if menuVisible and #items > 1 then
			newsIndex = newsIndex % #items + 1
			renderNews()
		end
	end
end)
task.spawn(function()
	while true do
		task.wait(0.25)
		if menuVisible then
			updateTimers()
			if currentPage == "upcoming" then
				local sig = upcomingSig()
				if sig ~= upcomingSignature then
					upcomingSignature = sig
					local sel = GuiService.SelectedObject
					local selName = if sel and sel:IsDescendantOf(page.body) then sel.Name else nil
					renderUpcoming()
					if selName then
						local again = page.body:FindFirstChild(selName)
						if again and again:IsA("GuiObject") then
							GuiService.SelectedObject = again
						end
					end
				end
			end
		end
	end
end)

-- Right stick scrolls the open page (or the play page): long text pages have nothing to select.
do
	local stickY = 0
	UserInputService.InputChanged:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stickY = if math.abs(input.Position.Y) > 0.2 then input.Position.Y else 0
		end
	end)
	RunService.Heartbeat:Connect(function(dt)
		if stickY == 0 or not menuVisible then
			return
		end
		local target: ScrollingFrame = if currentPage then page.body else scroll
		local maxY = math.max(0, target.AbsoluteCanvasSize.Y - target.AbsoluteWindowSize.Y)
		local y = math.clamp(target.CanvasPosition.Y - stickY * 900 * dt, 0, maxY)
		target.CanvasPosition = Vector2.new(0, y)
	end)
end

-- If GameClient already asked for the round state before we connected (so we missed "init"
-- during a running round), ask again. The server answers with init or phase.
task.delay(4, function()
	if state.mapId == nil then
		net:FireServer("ready")
	end
end)

-- PlayerGui.FrontlinesMenuShow: the defeat screen's leave button and the in-match Exit fire it
-- with no argument (the player left the match); "open" shows the menu over the running match.
do
	local ev = playerGui:FindFirstChild("FrontlinesMenuShow") or Instance.new("BindableEvent")
	ev.Name = "FrontlinesMenuShow"
	ev.Parent = playerGui
	ev.Event:Connect(function(mode: any)
		if mode ~= "open" then
			state.inRound = false
			if Place.role() == "match" and not RunService:IsStudio() then
				return -- leaving a match server: the server teleports us to the lobby place
			end
		end
		showMenu()
	end)
end

LobbyPages.init({
	net = net,
	toast = function(msg: string)
		showToast(msg, 4)
	end,
	preview = function(id: string, width: number)
		local img = previews[id .. "@" .. width]
		if img == nil then
			requestPreview(id, width)
		end
		return if img then img else nil
	end,
	mapPool = mapPool,
	close = function()
		closePage()
	end,
})

paintNav()
renderNews()
if Place.waitRole(5) == "match" then
	-- Match server: no main menu; join the round right away (the tutorial match turns the
	-- tutorial on).
	gui.Enabled = false
	task.spawn(function()
		local t0 = os.clock()
		while workspace:GetAttribute("WFMatchKind") == nil and os.clock() - t0 < 15 do
			task.wait(0.25)
		end
		if workspace:GetAttribute("WFMatchKind") == "tutorial" then
			playerGui:SetAttribute("FrontlinesTutorial", true)
		end
	end)
	state.hasPlayed = true
	net:FireServer("play")
	updateFloating()
else
	showMenu()
end

require(script.Parent:WaitForChild("NameInput")).attach(myName, function(msg: string)
	showToast(msg)
end)
