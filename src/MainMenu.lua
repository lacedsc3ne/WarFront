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
-- inline modals (MenuPages / MenuKit). Matchmaking buttons open LobbyPages (lobby role only).
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
local MapStyles = require(Shared:WaitForChild("MapStyles"))
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
local MenuStyle = require(script.Parent:WaitForChild("MenuStyle"))
local MapMenu = require(script.Parent:WaitForChild("MapMenu"))
local MenuPages = require(script.Parent:WaitForChild("MenuPages"))
local LobbyPages = require(script.Parent:WaitForChild("LobbyPages")) -- Create / Join Lobby, Ranked
-- "lobby" | "match" | "standalone" (Shared.Place): the lobby place runs the matchmaking pages, a
-- match server skips the menu and drops the player straight into the round.
local Place = require(Shared:WaitForChild("Place"))
-- Night menu redesign (test experience only, Workspace attribute WFNightMenu = true): the new
-- NightMenu.Home screen replaces the home view; pages still open in this menu until they move too.
-- Default since 11 Oct 2026; set Workspace attribute WFNightMenu = false to bring the old menu back.
local NIGHT = workspace:GetAttribute("WFNightMenu") ~= false
local night: any = nil

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

-- OpenFront duration formatting; countdown badges always show seconds and use "m".
local function formatTime(sec: number, countdown: boolean?): string
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
		parts[#parts + 1] = m .. (if countdown then "m" else "min")
	end
	if countdown or s > 0 or #parts == 0 then
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
	-- The lobby place only sends the background map; "Available" lists every map the server has.
	local available = folder and folder:GetAttribute("Available")
	local listed = if type(available) == "string" then string.split(available, ",") else nil
	local out = {}
	for _, m in MapCatalog do
		if not folder or folder:FindFirstChild(m.id) or (listed and table.find(listed, m.id)) then
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
	local mod = folder and folder:FindFirstChild(id)
	local thumbFn = Shared:FindFirstChild("MapThumb")
	if not mod and thumbFn and thumbFn:IsA("RemoteFunction") then
		-- Lobby place: the map stays on the server; it sends a small terrain thumbnail
		-- ({ width, height, terrain }), which renderPreview draws like a map.
		local ok, thumb = pcall(function()
			return thumbFn:InvokeServer(id)
		end)
		if ok and type(thumb) == "table" and typeof(thumb.terrain) == "buffer" then
			thumb.name = id -- Thumbnail replies omit the name; retain the map-specific palette.
			mapData[id] = thumb
			return thumb
		end
	end
	mod = mod or (folder and folder:WaitForChild(id, 5))
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

local function renderPreview(map, targetW: number, cutout: boolean?)
	local w, h = map.width, map.height
	local tw = math.clamp(math.floor(targetW), 16, 1024)
	local th = math.clamp(math.floor(tw * h / w + 0.5), 8, 1024)
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(tw, th) })
	if not img then
		return nil
	end
	local buf = buffer.create(tw * th * 4)
	local terrain = map.terrain
	local pixels = MapStyles.previewPixels(map.name) or PIXEL
	local pixelAt = MapStyles.palette(map.name).pixelAt
	local xs = table.create(tw, 0)
	for x = 0, tw - 1 do
		xs[x + 1] = math.min(w - 1, math.floor((x + 0.5) * w / tw))
	end
	local o = 0
	for y = 0, th - 1 do
		local row = math.min(h - 1, math.floor((y + 0.5) * h / th)) * w
		for x = 1, tw do
			local byte = buffer.readu8(terrain, row + xs[x])
			buffer.writeu32(buf, o, if cutout and byte < 128 and bit32.band(byte, 32) ~= 0 then 0 else (if pixelAt then pixelAt(byte, xs[x], row // w, w, h) else pixels[byte + 1]))
			o += 4
		end
		if y % 48 == 47 then
			task.wait()
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(tw, th), buf)
	return img
end

local function requestPreview(id: string, width: number, cutout: boolean?)
	local key = id .. "@" .. width .. (if cutout then "@cutout" else "")
	if previews[key] ~= nil or previewPending[key] then
		return
	end
	previewPending[key] = true
	table.insert(previewQueue, { id = id, width = width, key = key, cutout = cutout })
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
				local ok, res = pcall(renderPreview, map, job.width, job.cutout)
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

-- Main-menu button feedback, including buttons added by its inline pages.
-- Activated also covers touch and gamepad; background click-catchers stay silent.
do
	local SoundKit = require(script.Parent:WaitForChild("SoundKit"))
	local wired = setmetatable({}, { __mode = "k" })
	local silent = { Backdrop = true, DrawerBackdrop = true, AccountCatcher = true }
	local function bindButton(o)
		if not o:IsA("GuiButton") or silent[o.Name] or wired[o] then
			return
		end
		wired[o] = true
		o.Activated:Connect(function()
			SoundKit.play("slider", 1.5)
		end)
	end
	gui.DescendantAdded:Connect(bindButton)
	for _, o in gui:GetDescendants() do
		bindButton(o)
	end
end

-- body bg-neutral-800 with the map background at 30% opacity: here the live match shows
-- through at 30%. Swallows clicks so they don't reach the map.
local backdrop = make("TextButton", {
	Name = "Backdrop",
	Text = "",
	AutoButtonColor = false,
	Selectable = false,
	BackgroundColor3 = C.SURFACE,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
	Parent = gui,
})

local screen = make("Frame", { Name = "Screen", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
local screenScale = make("UIScale", { Parent = screen })
setSelectionGroup(screen)

local VERSION = "v" .. tostring(game.PlaceVersion)

-- Original cut-letter wordmark, shared by desktop, mobile and drawer.
local function wordmark(parent: Instance, name: string)
	return MapMenu.wordmark(parent, name)
end

local function versionLabel(parent: Instance): TextLabel
	return text({ Name = "Version", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MALIBU, Text = VERSION, Parent = parent })
end

-- Page links (DesktopNavBar / MobileNavBar order).
local NAV = {
	{ key = "play", label = "Play" },
	{ key = "store", label = "Shop" },
	{ key = "inventory", label = "Inventory" },
	{ key = "leaderboard", label = "Leaderboard" },
	{ key = "friends", label = "Friends" },
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
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		TextSize = if drawer then 24 else 24,
		Text = string.upper(label),
		TextColor3 = WHITE,
		TextTransparency = 0.3,
		TextXAlignment = if drawer then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
		Parent = parent,
	})
	local pad = if drawer then MenuKit.pad(b, 0, 0, 0, 0) else nil
	if not drawer then
		MenuKit.pad(b, 12, 12, 0, 0)
		corner(b, 8)
		make("Frame", { Name = "ActiveLine", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = C.AQUARIUS, BorderSizePixel = 0, Visible = false, Parent = b })
	end
	local state = "idle"
	local function paint()
		local lit = state ~= "idle" or b:GetAttribute("Active") == true
		local hi = if drawer then C.BLUE600 else C.MALIBU
		b.TextColor3 = if drawer and lit then hi else WHITE
		if not drawer then
			b.BackgroundColor3 = C.MALIBU
			b.BackgroundTransparency = if state ~= "idle" then 0.9 else 1
			local line = b:FindFirstChild("ActiveLine")
			if line then line.Visible = b:GetAttribute("Active") == true end
		end
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

-- NavAccountMenu trigger: avatar, optional clan tag, level and custom name.
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
	local identity=text({Name="Identity",Position=UDim2.fromOffset(44,0),Size=UDim2.new(1,-66,1,0),FontFace=F.BOLD,TextSize=14,RichText=true,Text="",TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center,TextTruncate=Enum.TextTruncate.AtEnd,Parent=b})
 local caret = MenuKit.icon("Caret", { AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-6,0,14), Size = UDim2.fromOffset(12, 12), ImageColor3 = WHITE, ImageTransparency = 0.1, Parent = b })
 local xpTip=text({Name="XpTooltip",AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,0,1,8),Size=UDim2.fromOffset(188,34),BackgroundColor3=Color3.fromRGB(5,22,40),BackgroundTransparency=0,FontFace=F.BOLD,TextSize=13,TextColor3=Color3.fromRGB(155,184,219),Text="Loading XP...",Visible=false,ZIndex=30,Parent=b})
 xpTip.BackgroundTransparency=0
 corner(xpTip,6);MenuKit.stroke(xpTip,.2,Color3.fromRGB(71,145,197),1)
 MenuKit.hover(b, function(s)
  b.BackgroundTransparency = if s == "idle" then 1 else 0.92
  caret.ImageTransparency = if s == "idle" then 0.1 else 0
  xpTip.Visible=s=="hover"
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
local nav = make("Frame", { Name = "NavBar", BackgroundColor3 = Color3.fromRGB(3, 20, 37), BackgroundTransparency = 0.05, BorderSizePixel = 0, ZIndex = 5, Parent = screen })
local navRow = make("Frame", {
	Name = "Row",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	AutomaticSize = Enum.AutomaticSize.X,
	Size = UDim2.fromOffset(0, 52),
	BackgroundColor3 = Color3.fromRGB(3, 17, 32),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = nav,
})
corner(navRow, 26)
MenuKit.pad(navRow, 12, 12, 0, 0)
local navRowScale = make("UIScale", { Parent = navRow })
MenuKit.list(navRow, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
do
	local logo = make("Frame", { Name = "Logo", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 190, 0.5, 0), Size = UDim2.fromOffset(210, 34), Parent = nav })
	local w = wordmark(logo, "Wordmark")
	w.Size = UDim2.fromScale(1, 1)
	for i, item in NAV do
		if item.key ~= "friends" and item.key ~= "leaderboard" then
			navLink(navRow, item.key, item.label, i, false)
		end
	end
	local util = make("Frame", { Name = "Utility", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0), BackgroundColor3 = Color3.fromRGB(3, 17, 32), BackgroundTransparency = 0.05, BorderSizePixel = 0, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 52), Parent = nav })
	corner(util, 24)
	MenuKit.list(util, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
	-- ml-1 border-l border-white/10 pl-5
	MenuKit.pad(util, 12, 12, 0, 0)
	local friends = MenuKit.iconButton("People", 36, { Name = "Nav_friends", LayoutOrder = 1, Parent = util })
	navButtons.friends = { friends }
	local settings = MenuKit.iconButton("Gear", 36, { Name = "Util_settings", LayoutOrder = 2, Parent = util })
	utilButtons.settings = { settings }
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
	{ id = "lobbies", type = "announcement", title = "FFA, Teams and Special games", desc = "Pick a game card to join. Special games add modifiers like Water Nukes and the Doomsday Clock." },
	{ id = "tutorial", type = "tutorial", title = "New Player Tutorial", desc = "Press Tutorial to play your first game with a step-by-step guide." },
	{ id = "alliances", type = "announcement", title = "Alliances, trade and warships", desc = "Right-click a player (long-press on touch, X on a controller) to ally." },
	{ id = "daily", type = "announcement", title = "Daily rewards", desc = "Play every day to grow your streak." },
}
local newsDismissed: { [string]: boolean } = {}
local newsIndex = 1

local news = make("Frame", { Name = "News", BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = playPage })
MenuStyle.panel(news, C.SURFACE)
local newsTag = text({ Name = "Type", AnchorPoint = Vector2.new(0, 0.5), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 18), BackgroundTransparency = 0.8, FontFace = F.BOLD, TextSize = 10, Parent = news })
corner(newsTag, 4)
padding(newsTag, 8)
local newsTitle = text({ Name = "Title", FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = news })
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
-- The name field is editable (NameInput); the TAG button shows your clan tag (ClanPages sets the
-- PlayerGui attribute WFClanTag) and opens the Clans page.
local identity = make("Frame", { Name = "Identity", BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = playPage })
MenuStyle.panel(identity, C.SURFACE)
local idInner = make("Frame", { Name = "Inner", BackgroundColor3 = C.SURFACE, BackgroundTransparency = 0.2, BorderSizePixel = 0, Parent = identity })
idInner.BackgroundTransparency = 1
local tagBtn = make("TextButton", { Name = "ClanTag", Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BackgroundTransparency = 1, Size = UDim2.fromOffset(116, 44), Parent = idInner })
corner(tagBtn, 8)
text({ Name = "Label", Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -24, 1, 0), FontFace = F.SEMIBOLD, TextSize = 16, TextTransparency = 0.55, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "TAG", Parent = tagBtn })
MenuKit.icon("Caret", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(12, 12), ImageTransparency = 0.55, Parent = tagBtn })
MenuKit.hover(tagBtn, function(s)
	tagBtn.BackgroundTransparency = if s == "idle" then 1 else 0.95
end)
-- UsernameInput: an editable name (NameInput.lua checks it and the server filters it).
local myName = make("TextBox", {
	Name = "Name",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	FontFace = F.BOLD,
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
myName.TextEditable=false -- Customise the name in View Account.
local nameController: any=nil

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
	p.AutomaticSize = Enum.AutomaticSize.None
	local function fitPill()
		p.Size = UDim2.fromOffset(math.max(24, p.TextBounds.X + 24), 24)
	end
	p:GetPropertyChangedSignal("TextBounds"):Connect(fitPill)
	MenuStyle.panel(p, C.MALIBU)
	fitPill()
	return p
end

local function makeCard()
	local c: any = { previewSize = 360 }
	c.button = make("TextButton", { Name = "LobbyCard", Text = "", AutoButtonColor = false, BackgroundColor3 = C.SURFACE, BorderSizePixel = 0, Parent = playPage })
	-- Angular border and clip retain the existing card input.
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
	c.image = make("ImageLabel", { Name = "Map", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Stretch, Visible = false, Parent = canvas })
	local pills = make("Frame", { Name = "Pills", Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -110, 0, 84), BackgroundTransparency = 1, Parent = canvas })
	MenuKit.list(pills, false, 4)
	c.pill1 = lobbyPill(pills, 1)
	c.pill2 = lobbyPill(pills, 2)
	c.pill3 = lobbyPill(pills, 3) -- (public lobbies: up to three modifiers)
	c.timer = lobbyPill(canvas)
	c.timer.AnchorPoint = Vector2.new(1, 0)
	c.timer.Position = UDim2.new(1, -8, 0, 8)
	local bar = make("Frame", { Name = "Bar", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = BLACK, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = canvas })
	c.bar = bar
	c.title = text({ Position = UDim2.fromOffset(12, 7), Size = UDim2.new(1, -112, 0, 18), FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = bar })
	c.sub = text({ Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -112, 0, 15), TextSize = 12, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = bar })
	c.badge = make("Frame", { Name = "Count", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -24, 1, -14), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), BackgroundColor3 = BLACK, BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = canvas })
	corner(c.badge, 4)
	padding(c.badge, 8)
	MenuKit.list(c.badge, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
	c.count = text({ LayoutOrder = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), FontFace = F.BOLD, TextSize = 12, Parent = c.badge })
	c.countIcon = MenuKit.icon("People", { LayoutOrder = 2, Size = UDim2.fromOffset(16, 16), Parent = c.badge })
	MenuStyle.card(c.button, canvas)
	cards[#cards + 1] = c
	return c
end

local featured = makeCard()
local small = { makeCard(), makeCard() }

-- "Upcoming" heading: also the way into the full list (GameModeSelector.renderUpcomingHeading).
local upHeader = make("TextButton", { Name = "Upcoming", Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BackgroundTransparency = 0.96, BorderSizePixel = 0, Parent = playPage })
MenuStyle.panel(upHeader, C.SURFACE)
local upLabel = text({ Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -140, 1, 0), FontFace = F.BOLD, TextSize = 14, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "UPCOMING", Parent = upHeader })
local seeAll = make("Frame", { Name = "SeeAll", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), BackgroundColor3 = C.MALIBU, BorderSizePixel = 0, Parent = upHeader })
MenuStyle.panel(seeAll, C.MALIBU)
seeAll.AutomaticSize = Enum.AutomaticSize.None
seeAll.Size = UDim2.fromOffset(100, 24)
local seeAllText = text({ Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -26, 1, 0), FontFace = F.BOLD, TextSize = 12, Text = "SEE ALL", Parent = seeAll })
MenuKit.icon("Chevron", { Position = UDim2.new(1, -22, 0.5, -8), Size = UDim2.fromOffset(16, 16), Parent = seeAll })
MenuKit.hover(upHeader, function(s)
	local on = s ~= "idle"
	upHeader.BackgroundTransparency = 1
	upLabel.TextTransparency = if on then 0 else 0.1
	seeAll.BackgroundTransparency = 1
end)

-- Action cards ----------------------------------------------------------------------
-- Our primary action joins the server's round (OpenFront's slot here is "Solo").
local playBtn = MenuStyle.button("primary", { Name = "Play", Text = if Place.role() == "lobby" then "SOLO" else "PLAY", Parent = playPage })
local tutBtn = MenuStyle.button("tutorial", { Name = "Tutorial", Text = "TUTORIAL", Parent = playPage })
local soonButtons = {}
for i, label in { "CREATE LOBBY", "RANKED", "JOIN LOBBY" } do
	soonButtons[i] = MenuStyle.button("secondary", { Name = "Soon" .. i, Text = label, Parent = playPage })
end

-- Footer ----------------------------------------------------------------------------
local footer = make("Frame", { Name = "Footer", Visible = false, BackgroundColor3 = C.ZINC900, BackgroundTransparency = 0.1, BorderSizePixel = 0, Parent = scroll })
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
local accountMenu = make("Frame", { Name = "AccountMenu", BackgroundColor3 = Color3.fromRGB(5,22,40), BackgroundTransparency=0, BorderSizePixel = 0, Size = UDim2.fromOffset(264, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, ZIndex = 31, Parent = screen })
corner(accountMenu, 8)
MenuKit.stroke(accountMenu, 0.15,Color3.fromRGB(63,131,187),1.5)
MenuKit.pad(accountMenu,8,8,8,8)
MenuKit.list(accountMenu, false, 4)
text({Name="Heading",LayoutOrder=0,Text="YOUR ACCOUNT",FontFace=F.BOLD,TextSize=12,TextColor3=C.AQUARIUS,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,24),ZIndex=32,Parent=accountMenu})
setSelectionGroup(accountMenu)
local accountItems: { TextButton } = {}
local function accountItem(order: number, iconName: string, label: string, onClick: () -> ())
 local base=Color3.fromRGB(11,37,63)
 local b = make("TextButton", { Name = label, LayoutOrder = order, Text = "", AutoButtonColor = false, BackgroundColor3 = base, BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 44), ZIndex = 32, Parent = accountMenu })
 corner(b,6)
 local outline=MenuKit.stroke(b,0.6,Color3.fromRGB(63,131,187),1)
 local icon=MenuKit.icon(iconName, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(20, 20), ImageColor3=C.WHITE, ZIndex = 33, Parent = b })
 text({ Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -70, 1, 0), FontFace = F.BOLD, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Text = label, ZIndex = 33, Parent = b })
 MenuKit.icon("Chevron",{AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-12,0.5,0),Size=UDim2.fromOffset(12,12),ImageColor3=Color3.fromRGB(155,184,219),ZIndex=33,Parent=b})
 MenuKit.hover(b, function(s)
  b.BackgroundTransparency=0;b.BackgroundColor3=if s=="idle" then base else Color3.fromRGB(18,53,82)
  icon.ImageColor3=if s=="idle" then C.WHITE else C.AQUARIUS
  outline.Color=if s=="idle" then Color3.fromRGB(63,131,187) else C.AQUARIUS;outline.Transparency=if s=="idle" then 0.6 else 0.1
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
	if night and night.isVisible() then
		night.toast(msg)
		return
	end
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
	-- MapMenu requests only the selected terrain preview; legacy cards are hidden.
end

local function timerText(mode: string?, c: any?): string?
	if mode == "lobby" and c and c.lobby then
		-- GameModeSelector.renderLobbyCard: default lobby time, the countdown, then "Starting…".
		local l = c.lobby
		if l.started then
			return "STARTING…"
		elseif l.endAt then
			local left = l.endAt - os.clock()
			return if left > 0 then formatTime(math.ceil(left), true) else "STARTING…"
		end
		return formatTime(l.default or 60, true)
	elseif mode == "remaining" then
		local left = state.phaseEnd - os.clock()
		return if left > 0 then formatTime(math.ceil(left), true) else "STARTING…"
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
	MapMenu.update()
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
 local function escape(v)
  return tostring(v):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
 end
 local clan=playerGui:GetAttribute("WFClanTag")
 local tag=if type(clan)=="string" and clan~="" then "["..clan.."]" else ""
 local level="[Lvl "..tostring(math.max(1,math.floor(tonumber(profile and profile.level) or 1))).."]"
 local name=if myName.Text~="" then myName.Text else localPlayer.DisplayName
 local tagText=if tag~="" then '<font color="#00b1eb">'..escape(tag)..'</font> ' else ""
 local levelText='<font color="#ffd337">'..level..'</font>'
 for _, b in accountButtons do
  local mobile=b.Parent==topRight
  local plain=(if tag~="" then tag.." " else "")..level.." "..name
  local width=game:GetService("TextService"):GetTextSize(plain,14,Enum.Font.GothamBold,Vector2.new(2000,40)).X
  b.Size=UDim2.fromOffset(if mobile then 150 else math.clamp(width+72,150,280),40)
  local xpTip=b:FindFirstChild("XpTooltip")
  if xpTip then xpTip.Text=if profile and tonumber(profile.xpInto) and tonumber(profile.xpNeed) then string.format("%d / %d XP",math.max(0,math.floor(profile.xpInto)),math.max(1,math.floor(profile.xpNeed))) else "Loading XP..." end
  local identity=b:FindFirstChild("Identity")
  if identity then
   identity.TextSize=if mobile then 12 else 14
   identity.Text=tagText..levelText..(if mobile then "\n" else "  ")..escape(name)
  end
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

myName:GetPropertyChangedSignal("Text"):Connect(renderAccount)
playerGui:GetAttributeChangedSignal("WFClanTag"):Connect(renderAccount)

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

local function nightSnapshot()
	local queuedKind = nil
	for _, kind in { "ffa", "team", "special" } do
		if LobbyPages.queued(kind) then
			queuedKind = kind
		end
	end
	return {
		role = Place.role(),
		phase = state.phase,
		phaseLeft = state.phaseEnd - os.clock(),
		mapId = state.mapId,
		mode = state.mode,
		lobbies = state.lobbies,
		queue = state.queue,
		queuedKind = queuedKind,
		room = if night then LobbyPages.night.lobby() else nil,
		profile = profile,
		name = if myName.Text ~= "" then myName.Text else localPlayer.DisplayName,
	}
end

refresh = function()
	if night then
		night.update(nightSnapshot())
	end
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
	c.title.TextSize = if compact then 14 else 20
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
	local mobile = LX < 1200 -- use the floating desktop header where all controls fit
	local sm = LX >= 640 -- Tailwind sm

	-- Bars.
	local navH
	nav.Visible = not mobile
	topBar.Visible = mobile
	if mobile then
		navH = 56
		place(topBar, 0, 0, LX, navH)
		topLogo.Size = UDim2.fromOffset(math.clamp(LX - 2 * 190, 90, 140), 22)
	else
		navH = 88
		place(nav, 0, 0, LX, navH)
		local logo = nav:FindFirstChild("Logo")
		logo.AnchorPoint = Vector2.new(1, 0.5)
		logo.Position = UDim2.new(0.54, -navRow.AbsoluteSize.X / s / 2 - 24, 0.5, 0)
		logo.Size = UDim2.fromOffset(if LX < 1440 then 150 else 165, 24)
		navRowScale.Scale = if LX < 1440 then 0.88 else 1
		navRow.Position = UDim2.new(0.54, 0, 0.5, 0)
	end
	if not mobile then
		drawer.Visible = false
		drawerBackdrop.Visible = false
	end
	place(drawer, 0, 0, LX * 0.7, LY)
	local viewH = math.max(0, LY - navH - LobbyPages.queueHeight())
	place(scroll, 0, navH, LX, viewH)

	-- Main column (MainLayout: lg:max-w-[20cm] 2xl:max-w-[24cm], clamp() paddings).
	local mainX, W, pt, pb
	if not mobile then
		local px = math.clamp(0.03 * LX, 24, 48)
		pt = math.clamp(0.015 * LX, 12, 24)
		pb = math.clamp(0.0075 * LX, 6, 12)
		W = math.min(LX - 2 * px, if LX >= 1536 then 960 else 800)
		mainX = (LX - W) / 2
	else
		pt, pb = 0, 0
		mainX = if sm then 16 else 0
		W = LX - 2 * mainX
	end
	local footerH = 0 -- footer removed (Liam, Oct 2026); the attribution line stays
	layoutFooter(LX, mobile)

	local y = pt
	if currentPage then
		playPage.Visible = false
		page.frame.Visible = true
		page.storeShowing = currentPage == "store"
		page.inventoryShowing = currentPage == "inventory"
		page:layout(mobile)
		local pageH = if mobile then viewH else math.max(320, viewH - pt - pb - footerH)
		local px = if mobile then 0 else mainX
		if currentPage == "store" or currentPage == "inventory" or currentPage == "clans" then
			local pageW = if LX < 650 then LX - 24 else math.min(1440, LX * 0.80)
			local topGap = if mobile then 12 else 16
			pageH = math.max(0,viewH-topGap)
			place(page.frame, (LX-pageW)/2, topGap, pageW, pageH)
			page:layout(mobile)
		else
			place(page.frame, px, y, if mobile then LX else W, pageH)
		end
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
		if #items > 0 then
			local p = if mobile then 16 else 24
			local h = if mobile then 52 else 64
			place(news, stripX, y, stripW, h)
			newsTag.Position = UDim2.new(0, p, 0.5, 0)
			local tagW = newsTag.AbsoluteSize.X / s
			if tagW <= 0 then
				tagW = 64
			end
			local tx = p + tagW + 12
			local right = 24 + 8 + (if #newsDotButtons > 1 then #newsDotButtons * 10 + 8 else 0)
			place(newsTitle, tx, (h - 36) / 2, stripW - tx - right - p, 20)
			place(newsDesc, tx, (h - 36) / 2 + 20, stripW - tx - right - p, 16)
			newsClose.Position = UDim2.new(1, -p, 0.5, 0)
			newsDots.Position = UDim2.new(1, -(p + 24 + 8), 0.5, 0)
			y += h + (if mobile then 16 else 8)
		end
		local idH = if mobile and not sm then 48 else (if mobile then 60 else 64)
		place(identity, stripX, y, stripW, idH)
		place(idInner, 24, 4, stripW - 48, idH - 8)
		local inH = idH - 8
		place(tagBtn, 4, (inH - math.min(44, inH)) / 2, 116, math.min(44, inH))
		place(myName, 128, 0, stripW - 48 - 140, inH)
		myName.TextSize = if mobile and not sm then 20 else 24
		y += idH + (if mobile then 16 + 8 else 8)

		-- Game mode selector.
		local tut = tutorialShown()
		tutBtn.Visible = tut
		local btnText = if mobile then 14 else 19
		local actionH = if mobile then 56 else 60
		local function actionRows(x: number, yy: number, w: number): number
			if tut then
				local w2 = (w - 16) * 0.58
				place(playBtn, x, yy, w2, actionH)
				place(tutBtn, x + w2 + 16, yy, w - w2 - 16, actionH)
			else
				place(playBtn, x, yy, w, actionH)
			end
			yy += actionH + 16
			local w3 = (w - 32) / 3
			for i, b in soonButtons do
				place(b, x + (i - 1) * (w3 + 16), yy, w3, actionH)
				b.TextSize = if w3 < 110 then 12 else btnText
			end
			playBtn.TextSize = btnText
			tutBtn.TextSize = btnText
			return yy + actionH
		end
		for _, c in small do
			c.layoutVisible = true
		end
		if sm then
			y += 16 -- empty first grid row + row gap
			local heroH = math.min(408, 0.42 * LY, math.max(256, viewH - y - 168))
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
	MapMenu.show(currentPage == nil, LX, LY, navH, LobbyPages.queueHeight(), currentPage ~= nil)
	scroll.Visible = currentPage ~= nil
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
	-- Night: the old floating MENU button and profile chip are replaced (battle screen menu button).
	if NIGHT then
		show = false
	end
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
	local width=math.min(264,screen.AbsoluteSize.X/s-24)
	accountMenu.Size=UDim2.fromOffset(width,0)
	local right = math.clamp((a.X + sz.X - sp.X) / s,width+12,screen.AbsoluteSize.X/s-12)
	local bottom = (a.Y + sz.Y - sp.Y) / s
	accountMenu.AnchorPoint = Vector2.new(1, 0)
	accountMenu.Position = UDim2.fromOffset(right, bottom + 8)
	accountMenu.Visible = true
	accountCatcher.Visible = true
	selectIfGamepad(accountItems[1])
end

local openPage: (string, GuiObject?) -> ()

local function renderUpcoming()
 local ds=DeviceLayout.state
 local mobile=(ds.touch==true or ds.input=="Touch") and (ds.profile=="phone" or ds.profile=="tablet")
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
  if mobile then
   b.BackgroundColor3=Color3.fromRGB(5,32,54);b.BackgroundTransparency=0
   st.Color=Color3.fromRGB(89,123,160);st.Transparency=.12
   local angular=info:FindFirstChild("AngularShape");if angular then angular.Visible=false end
   info.BackgroundColor3=Color3.fromRGB(14,43,64);info.BackgroundTransparency=0
   corner(info,6)
  end
		MenuKit.hover(b, function(s)
   if mobile then
    b.BackgroundColor3=if s=="idle" then Color3.fromRGB(5,32,54) else Color3.fromRGB(14,43,64)
    b.BackgroundTransparency=0;return
   end
			b.BackgroundTransparency = if s == "idle" then 0.95 else 0.9
			if not e.mine then
				st.Color = if s == "idle" then WHITE else C.MALIBU
				st.Transparency = if s == "idle" then 0.9 else 0.4
			end
		end)
		local id = e.id
		b.Activated:Connect(function()
			if e.lobbyType then
				closePage()
				LobbyPages.joinPublic(e.lobbyType, e.lobby)
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
	if night then
		night.hidePage()
	end
	currentPage = nil
	upcomingRefresh = nil
	page:clear()
	page:setTabs({})
	paintNav()
	relayout()
	scroll.CanvasPosition = Vector2.zero
	if night and menuVisible then
		gui.Enabled = false
		night.setVisible(true)
	elseif night then
		night.setVisible(false) -- a page opened from the battle: back to the battle
	end
	local sel = GuiService.SelectedObject
	if sel == nil or not sel:IsDescendantOf(playerGui) or sel:IsDescendantOf(page.frame) then
		GuiService.SelectedObject = nil
		selectIfGamepad(if night then night.focus() elseif pageOpener and pageOpener.Visible then pageOpener else playBtn)
	end
end

local function startTutorial(lesson: string?)
	-- lesson: a short lesson key from the How to play page (Tutorial.LESSONS), nil = full tutorial.
	playerGui:SetAttribute("FrontlinesTutorialLesson", if type(lesson) == "string" then lesson else nil)
	if Place.role() == "lobby" then
		-- Lobby place: the tutorial is its own solo match server (as the Tutorial button does).
		LobbyPages.leavePublic()
		net:FireServer("play", "tutorial", if type(lesson) == "string" then lesson else nil)
		closePage()
		return
	end
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
	nameController=function() return nameController end,
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
	local nightPage = night ~= nil and night.hasPage(kind)
	if night and not nightPage then
		-- The old menu is retired: pages without a Night version (upcoming, ranked) stay closed.
		return
	end
	if LobbyPages.handles(kind) and not night then
		LobbyPages.leavePublic() -- old menu only: Night pages leave the queue when you make / join / start
	end
	-- The store / stats window (MetaClient) never stays open over a menu page.
	openMeta("close")
	pageOpener = from or pageOpener
	currentPage = kind
	if nightPage then
		upcomingRefresh = nil
		gui.Enabled = false
		night.showPage(kind)
		return
	end
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
	gui.Enabled = not night
	if night then
		night.setVisible(currentPage == nil)
	end
	playerGui:SetAttribute("FrontlinesMenuOpen", true)
	updateFloating()
	ContextActionService:BindActionAtPriority(B_ACTION, function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			if night and night.back() then
				-- closed a Night menu popup
			elseif accountMenu.Visible then
				closeAccountMenu()
			elseif drawer.Visible then
				closeDrawer()
			elseif currentPage then
				if currentPage ~= "ranked" then closePage() end
			elseif LobbyPages.queued() then
				-- Back navigation keeps the active queue; use Leave Queue explicitly.
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
	if night then
		night.setVisible(false)
	end
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
	LobbyPages.leavePublic()
	if tutorial then
		playerGui:SetAttribute("FrontlinesTutorialLesson", nil) -- the full tutorial
	end
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

-- Lobby place: premade games queue on the main screen, with a compact bottom bar.
local function joinPublic(c)
	if not (state.lobbies and c.lobbyType) then
		return false
	end
	closePage()
	LobbyPages.joinPublic(c.lobbyType, c.lobby)
	return true
end

playBtn.Activated:Connect(function()
	if Place.role() == "lobby" then
		-- SOLO (GameModeSelector main.solo): the single-player page (map, difficulty, options).
		openPage("solo", playBtn)
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
	openPage("clans", tagBtn)
end)
do
	local function showTag()
		local tag = playerGui:GetAttribute("WFClanTag")
		local label = tagBtn:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			local has = type(tag) == "string" and tag ~= ""
			label.Text = if has then "[" .. tag .. "]" else "TAG"
			label.TextTransparency = if has then 0 else 0.55
			label.TextColor3 = if has then C.AQUARIUS else WHITE
		end
	end
	playerGui:GetAttributeChangedSignal("WFClanTag"):Connect(showTag)
	require(script.Parent:WaitForChild("ClanPages")).refreshTag()
end
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
accountItem(3, "Layout", "Shop", function()
	openPage("store", accountOpener)
end)
accountItem(4, "Bars", "Leaderboard", function()
	openPage("leaderboard", accountOpener)
end)
accountItem(5, "Bell", "News", function()
	openPage("news", accountOpener)
end)
accountItem(6, "Help", "Help", function()
	openPage("help", accountOpener)
end)
accountCatcher.Activated:Connect(closeAccountMenu)
hamburger.Activated:Connect(openDrawer)
drawerBackdrop.Activated:Connect(closeDrawer)

PauseMenu.init({
	showMainMenu = showMenu,
	isMainMenuOpen = function()
		return menuVisible
	end,
	-- Night: the in-match Shop opens the Night shop page over the battle.
	openStore = function(): boolean
		if not night then
			return false
		end
		openPage("store")
		return true
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
	if night and night.back() then
		return
	elseif accountMenu.Visible then
		closeAccountMenu()
	elseif drawer.Visible then
		closeDrawer()
	elseif currentPage then
		if currentPage ~= "ranked" then closePage() end
	elseif LobbyPages.queued() or (LobbyPages.night and LobbyPages.night.lobby() ~= nil) then
		return -- Escape keeps queue and party membership.
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
		if p.saving==true and p.tutorialSeen~=true and (tonumber(p.games) or 0)==0 and not state.autoTutorialAttempted and Place.role()=="lobby" then
			state.autoTutorialAttempted=true
			playerGui:SetAttribute("FrontlinesTutorialAutoStarted",true)
			task.defer(function()
				if playerGui.Parent and not state.inRound and Place.role()=="lobby" and profile and profile.saving==true and profile.tutorialSeen~=true and (tonumber(profile.games) or 0)==0 then play(true) end
			end)
		end
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
navRow:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)

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
			if night and night.isVisible() then
				night.update(nightSnapshot())
			end
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

MapMenu.setup({
	parent = screen,
	cards = { featured, small[1], small[2] },
	play = playBtn, create = soonButtons[1], joinLobby = soonButtons[3], ranked = soonButtons[2], tutorial = tutBtn,
	identityInner = idInner, tag = tagBtn, name = myName,
	news = news, newsTitle = newsTitle, newsDesc = newsDesc, newsTag = newsTag, newsClose = newsClose,
	tutorialShown = tutorialShown,
	preview = function(id, width, cutout)
		local img = previews[id .. "@" .. width .. (if cutout then "@cutout" else "")]
		if img == nil then requestPreview(id, width, cutout) end
		return if img then img else nil
	end,
	isQueued = function(c)
		return c.lobbyType ~= nil and LobbyPages.queued(c.lobbyType)
	end,
	join = function(c)
		if joinPublic(c) then return end
		if c.mode == "vote" and c.mapId then vote(c.mapId)
		elseif c.mode == "pool" then showToast("Voting opens after this round")
		else play(false) end
	end,
	browse = function() openPage("upcoming") end,
})

LobbyPages.init({
	net = net,
	queueParent = screen,
	queueChanged = queueLayout,
	toast = function(msg: string)
		showToast(msg, 4)
	end,
	preview = function(id: string, width: number, cutout: boolean?)
		local img = previews[id .. "@" .. width .. (if cutout then "@cutout" else "")]
		if img == nil then
			requestPreview(id, width, cutout)
		end
		return if img then img else nil
	end,
	mapPool = mapPool,
	close = function()
		closePage()
	end,
	open = function(kind: string)
		if currentPage ~= kind then
			closePage()
			openPage(kind)
		end
	end,
	-- Studio: a match the lobby starts is played in this server (GameServer studioMatch).
	studioMatch = function(tutorial: boolean)
		if tutorial then
			playerGui:SetAttribute("FrontlinesTutorial", true)
		end
		state.hasPlayed = true
		closePage()
		hideMenu()
	end,
	studioLobby = function()
		playerGui:SetAttribute("FrontlinesTutorial", false)
		state.autoTutorialAttempted = true
		state.inRound = false
		showMenu()
	end,
})

if NIGHT then
	LobbyPages.nightMode = true
	LobbyPages.onNightChange(queueRefresh)
	local Home = require(script.Parent:WaitForChild("NightMenu"):WaitForChild("Home"))
	night = Home.create({
		open = function(kind: string)
			openPage(kind)
		end,
		play = function()
			-- A brand-new player (no games yet, tutorial never started) goes to the tutorial on their
			-- first Play, in case the automatic start on joining didn't happen (applyProfile).
			if profile and profile.saving == true and profile.tutorialSeen ~= true and (tonumber(profile.games) or 0) == 0 then
				play(true)
				return
			end
			if state.lobbies and state.lobbies.ffa then
				joinPublic({ lobbyType = "ffa", lobby = state.lobbies.ffa })
				queueRefresh()
			elseif Place.role() == "lobby" then
				showToast("Finding battles. Try again in a moment")
			else
				play(false)
			end
		end,
		joinLobby = function(kind: string)
			local l = state.lobbies and state.lobbies[kind]
			if l then
				joinPublic({ lobbyType = kind, lobby = l })
				queueRefresh()
			end
		end,
		leaveQueue = function()
			LobbyPages.leavePublic()
			queueRefresh()
		end,
		leaveRoom = function()
			LobbyPages.leaveCustom()
			queueRefresh()
		end,
		tutorial = function()
			play(true)
		end,
		preview = function(id: string, width: number, cutout: boolean?)
			local img = previews[id .. "@" .. width .. (if cutout then "@cutout" else "")]
			if img == nil then
				requestPreview(id, width, cutout)
			end
			return if img then img else nil
		end,
		snapshot = nightSnapshot,
		closePage = function()
			closePage()
		end,
		meta = function(op: string, arg: any)
			local fn = Shared:FindFirstChild("MetaFn")
			if not fn then
				return false, "Still connecting. Try again in a moment"
			end
			local ok, success, result = pcall(function()
				return fn:InvokeServer(op, arg)
			end)
			if not ok then
				return false, "Couldn't reach the server. Try again"
			end
			return success, result
		end,
		startTutorial = startTutorial,
		mapPool = mapPool,
		nameController = function()
			return nameController
		end,
	})
end

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
			playerGui:SetAttribute("FrontlinesTutorialLesson", workspace:GetAttribute("WFTutorialLesson"))
			playerGui:SetAttribute("FrontlinesTutorial", true)
		end
	end)
	state.hasPlayed = true
	net:FireServer("play")
	updateFloating()
else
	showMenu()
end

nameController=require(script.Parent:WaitForChild("NameInput")).attach(myName, function(msg: string)
	showToast(msg)
end)
