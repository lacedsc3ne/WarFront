--[[
	War Front - client renderer and UI.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local Replay = require(script.Parent:WaitForChild("Replay")) -- last-round replay (records the net stream)
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local Theme = require(Shared:WaitForChild("Theme")) -- OpenFront map colours (terrain, palettes, borders)
local net = Shared:WaitForChild("Net")
local ContextMenu = require(script.Parent:WaitForChild("ContextMenu"))
local Settings = require(script.Parent:WaitForChild("Settings")) -- player settings (see the hook before the frame loop)
local MapRender = require(script.Parent:WaitForChild("MapRender")) -- map image: terrain, territory, thin borders (2-3 px per tile)
local MapFx = require(script.Parent:WaitForChild("MapFx")) -- map effects: explosions, shockwaves, target rings, spawn ring, glows

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

local mapsFolder = Shared:WaitForChild("Maps")
local currentMapId = "Europe"
local map = MapUtil.load(mapsFolder:WaitForChild(currentMapId))
local W, H, SIZE = map.width, map.height, map.size
local NB = table.create(4)
local FALLOUT_OWNER = 65535

-- Helpers
-- OpenFront Utils.renderNumber (truncating, not rounding): 999, 1.23K, 12.3K, 123K, 1.23M, 12.3M, 1.23B
local function fmt(n: number): string
	n = math.max(0, n)
	local function trunc(v: number, digits: number): string
		local k = 10 ^ digits
		return string.format("%." .. digits .. "f", math.floor(v * k + 1e-9) / k)
	end
	if n >= 1e10 then
		return trunc(n / 1e9, 1) .. "B"
	elseif n >= 1e9 then
		return trunc(n / 1e9, 2) .. "B"
	elseif n >= 1e7 then
		return trunc(n / 1e6, 1) .. "M"
	elseif n >= 1e6 then
		return trunc(n / 1e6, 2) .. "M"
	elseif n >= 1e5 then
		return math.floor(n / 1e3) .. "K"
	elseif n >= 1e4 then
		return trunc(n / 1e3, 1) .. "K"
	elseif n >= 1e3 then
		return trunc(n / 1e3, 2) .. "K"
	end
	return tostring(math.floor(n))
end

-- OpenFront renderTroops: troops are stored x10 (like OpenFront), shown divided by 10.
local function fmtTroops(n: number): string
	return fmt(n / 10)
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

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

local function serverNow(): number
	if Replay.active() then
		return Replay.now() -- animations follow the replay clock
	end
	return SimClock.now()
end

-- Terrain colours (recomputed when the map changes)
-- The per-tile terrain colours live in MapRender (rebuilt by MapRender.setMap / buildBase).
local function buildBaseColors()
	if MapRender.scale() > 0 then
		MapRender.buildBase()
	end
end

-- Client game state
local owners = buffer.create(SIZE * 2) -- wire owner (65535 = fallout)
local roster: { [number]: any } = {}
local myId = 0
local phase = { phase = "Lobby", ticksLeft = 0 }
local me = { attacks = {}, costs = {}, boats = 0, hasSilo = false, siloReady = false }
local structureList = {}
local boats: { [number]: any } = {}
local nukes: { [number]: any } = {}
local units: { [number]: any } = {} -- warships by id (from "units" snapshots)
local selectedUnit: number? = nil -- one of our selected warships (nil = none selected)
-- Warship selection (OpenFront: click one, F selects all, Shift + drag box-selects several).
-- ids: set of selected warship ids; rings: selection ring per id; box / boxStart: drag rectangle.
local selection: any = { ids = {}, rings = {}, box = nil, boxStart = nil }
local attackRatio = math.clamp((tonumber(Settings.values.attackRatio) or 20) / 100, 0.01, 1) -- OpenFront settings.attackRatio
local mode: { type: string, kind: string }? = nil -- build / nuke placement mode
-- Pointer in GUI space, from mouse input events (the same space clicks use). GetMouseLocation()
-- counts the top bar inset and can sit ~50 px below the cursor on this IgnoreGuiInset GUI.
local mouseAbs = Vector2.new(-1e4, -1e4)
local ghost: any = { state = nil, shown = false, tile = nil, kind = nil, checkAt = 0 } -- build ghost (one table: GameClient is near the 200-local limit)
-- Counters the tutorial watches to notice the player doing things.
local tutorialCounters = { attacksSent = 0, playerAttacksSent = 0, ratioMoves = 0 }

local function ownerOf(t: number): number
	local o = buffer.readu16(owners, t * 2)
	return if o == FALLOUT_OWNER then 0 else o
end

-- Tiles are drawn by MapRender.lua (OpenFront look: translucent fill over the terrain, a thin
-- darker border line, light grey border for our own land, green-tinted border next to allies).
local function paint(t: number)
	MapRender.markTile(t)
end

local function repaintAll()
	MapRender.markAll()
end

-- OpenFront "Hidden Names": other humans show a random tribe-style name on our screen.
local function rosterName(p): string
	if Settings.values.anonymousNames and p.id ~= myId and p.anon and p.anon ~= "" then
		return p.anon
	end
	return p.realName or p.name or ""
end

local function applyRoster(list)
	for _, e in list do
		local id = e[1]
		local p = roster[id] or { stats = { alive = true, troops = 0, maxTroops = 1, gold = 0, tiles = 0, cx = 0, cy = 0, cities = 0, kills = 0 } }
		p.id, p.realName, p.anon, p.kind, p.userId = id, e[2], e[11] or "", e[3], e[5]
		p.name = rosterName(p)
		p.level, p.vip = e[6] or 0, e[7] or false
		p.serverColor, p.flag = e[4], e[8] or "" -- flag: OpenFront flag code (nations), "" = none
		p.team, p.teamKey = e[10] or "", tostring(id) -- team games: team name ("" = none)
		Theme.applyPlayerColors(p, Settings.values.borderContrast) -- sets p.r, p.g, p.b and p.paint
		roster[id] = p
	end
end

local function applyStats(b: buffer)
	local n = buffer.len(b) // 31
	for i = 0, n - 1 do
		local o = i * 31
		local id = buffer.readu16(b, o)
		local p = roster[id]
		if p then
			local s = p.stats
			s.alive = buffer.readu8(b, o + 2) == 1
			s.troops = buffer.readu32(b, o + 3)
			s.maxTroops = buffer.readu32(b, o + 7)
			s.gold = buffer.readu32(b, o + 11)
			s.tiles = buffer.readu32(b, o + 15)
			s.cx = buffer.readu16(b, o + 19) / 10
			s.cy = buffer.readu16(b, o + 21) / 10
			s.cities = buffer.readu16(b, o + 23)
			s.kills = buffer.readu16(b, o + 25)
			s.attacking = buffer.readu32(b, o + 27) -- troops in outgoing attacks (hover panel)
		end
	end
end

local touched = {}
local function applyTiles(b: buffer)
	local off, len = 0, buffer.len(b)
	table.clear(touched)
	while off < len do
		local o = buffer.readu16(b, off)
		local count = buffer.readu32(b, off + 2)
		off += 6
		for _ = 1, count do
			local t = buffer.readu32(b, off)
			off += 4
			buffer.writeu16(owners, t * 2, o)
			touched[t] = true
			local n = MapUtil.neighbors(map, t, NB)
			for i = 1, n do
				touched[NB[i]] = true
			end
		end
	end
	if Settings.values.borderContrast then
		Settings.growTouched(map, touched)
	end
	for t in touched do
		paint(t)
	end
end

local function applyOwnersSnapshot(b: buffer)
	local t = 0
	for off = 0, buffer.len(b) - 1, 6 do
		local o = buffer.readu16(b, off)
		local run = buffer.readu32(b, off + 2)
		for i = t, t + run - 1 do
			buffer.writeu16(owners, i * 2, o)
		end
		t += run
	end
end

-- GUI
local gui = make("ScreenGui", {
	Name = "FrontlinesUI",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = localPlayer:WaitForChild("PlayerGui"),
})
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local DeviceLayout = require(playerScripts:WaitForChild("DeviceLayout"))
local GamepadControls = require(playerScripts:WaitForChild("GamepadControls"))
local Tutorial = require(playerScripts:WaitForChild("Tutorial"))
local Leaderboard = require(playerScripts:WaitForChild("Leaderboard"))
local IconKit = require(playerScripts:WaitForChild("IconKit"))
local HoverPanel = require(playerScripts:WaitForChild("HoverPanel"))
local DefeatScreen = require(playerScripts:WaitForChild("DefeatScreen"))
local NameLabels = require(playerScripts:WaitForChild("NameLabels")) -- OpenFront-style name plates
local SoundKit = require(playerScripts:WaitForChild("SoundKit")) -- OpenFront sound cues + ambience
local MapMarkers = require(playerScripts:WaitForChild("MapMarkers")) -- structure / SAM / nuke markers
local AttackLabels = require(playerScripts:WaitForChild("AttackLabels")) -- troop counts on attack fronts
local SpriteKit = require(playerScripts:WaitForChild("SpriteKit")) -- OpenFront unit sprites (boats, warships, nukes)
local UnitFx = require(playerScripts:WaitForChild("UnitFx")) -- railroads, trains, MIRV warheads, SAM missiles
local Ballistics = require(Shared:WaitForChild("Ballistics")) -- OpenFront nuke arcs (shared with the server)
local Perf = require(Shared:WaitForChild("Perf")) -- built-in profiler (PlayerGui attribute FrontlinesPerf)
local AlertsPanel = require(playerScripts:WaitForChild("AlertsPanel")) -- bottom-right events + alliance requests
local Interact = require(playerScripts:WaitForChild("Interact")) -- radial menu, player panel, attacks display, keybinds
local KeybindData = require(playerScripts:WaitForChild("KeybindData")) -- rebindable keys (modifier keys for clicks)

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local PANEL = Color3.fromRGB(10, 22, 40)
local ACCENT = Color3.fromRGB(0, 132, 209)

local function corner(parent, r)
	make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function panel(props)
	props.BackgroundColor3 = props.BackgroundColor3 or PANEL
	props.BackgroundTransparency = props.BackgroundTransparency or 0.15
	props.BorderSizePixel = 0
	if props.Active == nil then
		props.Active = true
	end
	local f = make("Frame", props)
	corner(f)
	return f
end

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.TextSize = props.TextSize or 16
	return make("TextLabel", props)
end

local backdrop = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Theme.BACKGROUND,
	BorderSizePixel = 0,
	Parent = gui,
})

local holder = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = backdrop,
})

local mapImage = make("ImageLabel", {
	Name = "Map",
	BackgroundTransparency = 1,
	ResampleMode = Enum.ResamplerMode.Pixelated,
	Size = UDim2.fromOffset(W, H),
	Parent = holder,
})
local structureLayer = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 2, Parent = mapImage })
local unitLayer = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 3, Parent = mapImage })
local labelLayer = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 4, Parent = mapImage })
local fxLayer = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 5, Parent = mapImage })
AttackLabels.init({
	layer = labelLayer,
	mapSize = function()
		return W, H
	end,
	fmtTroops = fmtTroops,
})

MapMarkers.init({
	layer = structureLayer,
	fxLayer = fxLayer,
	roster = roster,
	getMyId = function()
		return myId
	end,
	isAlly = ContextMenu.isAlly,
	mapSize = function()
		return W, H
	end,
	samRange = Config.SAM_RANGE,
	nukes = Config.NUKES,
})

MapRender.init({
	parent = mapImage,
	holder = holder,
	map = map,
	getOwners = function()
		return owners
	end,
	roster = roster,
	getMyId = function()
		return myId
	end,
	getPhase = function()
		return phase.phase
	end,
	getStructures = function()
		return structureList
	end,
})
MapFx.init({
	parent = mapImage,
	layer = fxLayer,
	roster = roster,
	getMyId = function()
		return myId
	end,
	getPhase = function()
		return phase.phase
	end,
	getStructures = function()
		return structureList
	end,
	mapSize = function()
		return W, H
	end,
	landTiles = function()
		return map.landTiles
	end,
	fmt = fmt,
})
UnitFx.init({
	unitLayer = unitLayer,
	fxLayer = fxLayer,
	roster = roster,
	map = map,
	getMyId = function()
		return myId
	end,
	isAlly = ContextMenu.isAlly,
	mapSize = function()
		return W, H
	end,
	markTile = function(t: number)
		MapRender.markTile(t)
	end,
})

local HC = { -- OpenFront-style palette for the in-match HUD
	NAVY = Color3.fromRGB(10, 22, 40),
	GRAY400 = Color3.fromRGB(156, 163, 175),
	GRAY600 = Color3.fromRGB(75, 85, 99),
	GRAY800 = Color3.fromRGB(31, 41, 55),
	GRAY900 = Color3.fromRGB(17, 24, 39),
	SLATE = Color3.fromRGB(51, 65, 85),
	MALIBU = Color3.fromRGB(0, 132, 209),
	AQUARIUS = Color3.fromRGB(63, 169, 245),
	YELLOW = Color3.fromRGB(250, 204, 21),
	GREEN = Color3.fromRGB(74, 222, 128),
}

local function stroke(parent, color: Color3, thickness: number?)
	return make("UIStroke", { Color = color, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = parent })
end

-- Small HUD icons (OpenFront icons, see IconKit.lua).
local hudDraw = {}
function hudDraw.coinIcon(parent, order: number?)
	return IconKit.image("Gold", { Size = UDim2.fromOffset(15, 15), ImageColor3 = HC.YELLOW, LayoutOrder = order or 0, Parent = parent })
end

function hudDraw.personIcon(parent, order: number?)
	return IconKit.image("Troops", { Size = UDim2.fromOffset(15, 15), LayoutOrder = order or 0, Parent = parent })
end

-- Top banner (slim pill)
local banner = make("Frame", {
	Name = "Banner",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 12),
	Size = UDim2.fromOffset(420, 30),
	BackgroundColor3 = HC.NAVY,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Parent = gui,
})
make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = banner })
stroke(banner, HC.SLATE).Transparency = 0.3
local bannerText = label({ Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0), FontFace = FONT_BOLD, TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = banner })

-- Leaderboard (top-left), see Leaderboard.lua
local leaderboard = Leaderboard.create({
	gui = gui,
	roster = roster,
	fmt = fmt,
	fmtTroops = fmtTroops,
	contextMenu = ContextMenu,
	getMyId = function()
		return myId
	end,
	getLandTiles = function()
		return map.landTiles
	end,
	getStructures = function()
		return structureList
	end,
	getUnits = function()
		return units
	end,
})
local board = leaderboard.frame

-- Alerts panel (bottom-right): event feed + alliance requests, see AlertsPanel.lua / DeviceLayout.
local feedFrame = AlertsPanel.create({
	gui = gui,
	roster = roster,
	getMyId = function()
		return myId
	end,
	usingGamepad = DeviceLayout.usingGamepad,
})

-- Bottom-centre control panel, OpenFront ControlPanel.ts + UnitDisplay.ts (bg-gray-800/92, rounded):
--   desktop (>= 1024 px): [notification] / troop rate | troop bar | gold / sword ratio | slider /
--                         unit display (border-t white/10, one small box per actionList entry)
--   mobile: [notification] / gold | troop bar (rate inside) | sword ratio | slider (no unit display
--           unless a gamepad is used: touch players build from the radial menu, like OpenFront)
-- DeviceLayout.layoutPanel places these; refreshHud fills them. `cp` holds the extra pieces.
local cp = { gainToken = 0, lastRate = 0, increasing = true }
local hud = panel({ Name = "ControlPanel", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.fromOffset(500, 122), BackgroundColor3 = HC.GRAY800, BackgroundTransparency = 0.08, Parent = gui })
HC.ORANGE = Color3.fromRGB(251, 146, 60) -- orange-400
HC.GREEN400 = Color3.fromRGB(74, 222, 128)

function hudDraw.pill(parent, borderColor: Color3)
	local f = make("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Parent = parent })
	corner(f, 6)
	stroke(f, borderColor).Name = "Border"
	local row = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = f })
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
		Parent = row,
	})
	return f, row
end

-- Notification line (computeNotification: low troops warning).
cp.notice = make("Frame", { Name = "Notification", BackgroundColor3 = HC.ORANGE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Visible = false, Parent = hud })
corner(cp.notice, 6)
stroke(cp.notice, HC.ORANGE).Transparency = 0.4
cp.noticeText = label({ Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -12, 1, 0), TextSize = 12, TextColor3 = Color3.fromRGB(253, 186, 116), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "⚠  You are very low on troops - You should always keep some troops for defense.", Parent = cp.notice })

local growthPill, growthText
do
	local row
	growthPill, row = hudDraw.pill(hud, HC.GREEN400)
	cp.growthIcon = IconKit.image("Soldier", { Size = UDim2.fromOffset(13, 13), ImageColor3 = HC.GREEN400, LayoutOrder = 0, Parent = row })
	growthText = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = HC.GREEN400, Text = "+0/s", LayoutOrder = 1, Parent = row })
end

-- Troop bar: malibu-blue = troops, aquarius = troops out attacking (calculateTroopBar).
local troopBox = make("Frame", { BackgroundColor3 = HC.GRAY900, BackgroundTransparency = 0.4, BorderSizePixel = 0, ClipsDescendants = true, Parent = hud })
corner(troopBox, 6)
stroke(troopBox, HC.GRAY600)
local troopBar = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = HC.MALIBU, BorderSizePixel = 0, Parent = troopBox })
cp.attackBar = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = HC.AQUARIUS, BorderSizePixel = 0, Parent = troopBox })
local troopsText
do
	-- desktop: "troops / max [soldier]" (text-lg)
	cp.troopDesktop = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 2, Parent = troopBox })
	troopsText = label({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(0.5, -6, 0, 0), Size = UDim2.new(0.5, -6, 1, 0), FontFace = FONT_BOLD, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 0.5, Text = "", ZIndex = 2, Parent = cp.troopDesktop })
	label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 10, 1, 0), FontFace = FONT_BOLD, TextSize = 18, TextStrokeTransparency = 0.5, Text = "/", ZIndex = 2, Parent = cp.troopDesktop })
	cp.maxText = label({ Position = UDim2.new(0.5, 6, 0, 0), Size = UDim2.fromOffset(60, 24), FontFace = FONT_BOLD, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.5, Text = "", ZIndex = 2, Parent = cp.troopDesktop })
	cp.maxIcon = IconKit.image("Soldier", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0.5, 72, 0.5, 0), Size = UDim2.fromOffset(22, 22), ZIndex = 2, Parent = cp.troopDesktop })
	-- mobile: troops left, max right, soldier + rate in the middle
	cp.troopMobile = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 2, Parent = troopBox })
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = cp.troopMobile })
	cp.mTroops = label({ Size = UDim2.fromScale(0.5, 1), FontFace = FONT_BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.5, Text = "", ZIndex = 2, Parent = cp.troopMobile })
	cp.mMax = label({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.5, 1), FontFace = FONT_BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, TextStrokeTransparency = 0.5, Text = "", ZIndex = 2, Parent = cp.troopMobile })
	local mid = make("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, ZIndex = 3, Parent = cp.troopMobile })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2), Parent = mid })
	IconKit.image("Soldier", { Size = UDim2.fromOffset(12, 12), LayoutOrder = 1, ZIndex = 3, Parent = mid })
	cp.mRate = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 10, TextColor3 = HC.GREEN400, TextStrokeTransparency = 0.5, Text = "", LayoutOrder = 2, ZIndex = 3, Parent = mid })
end

local goldPill, goldText
do
	local row
	goldPill, row = hudDraw.pill(hud, HC.YELLOW)
	hudDraw.coinIcon(row, 1)
	goldText = label({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = HC.YELLOW, Text = "0", LayoutOrder = 2, Parent = row })
	-- "+gold" pip above the box for 2 s (BonusEvent / ConquestEvent / DonateEvent)
	cp.goldGain = label({ AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -5, 0, -2), Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = HC.GREEN400, TextStrokeTransparency = 0.3, Text = "", Visible = false, ZIndex = 5, Parent = goldPill })
end

-- Attack ratio box: sword + "20% (1.2K)" (border-gray-600, w-[8rem])
cp.ratioBox = make("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Parent = hud })
corner(cp.ratioBox, 6)
cp.ratioStroke = stroke(cp.ratioBox, HC.GRAY600)
cp.sword = IconKit.image("Sword", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 5, 0.5, 0), Size = UDim2.fromOffset(12, 12), Parent = cp.ratioBox })
local ratioText = label({ Position = UDim2.fromOffset(21, 0), Size = UDim2.new(1, -23, 1, 0), FontFace = FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = cp.ratioBox })
-- `slider` is the (transparent) hit area; the track, fill and knob are drawn inside it.
local slider = make("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Active = true, Parent = hud })
local sliderFill, sliderKnob
do
	local sliderTrack = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = Color3.fromRGB(229, 231, 235), BorderSizePixel = 0, Parent = slider })
	corner(sliderTrack, 99)
	sliderFill = make("Frame", { Size = UDim2.fromScale(attackRatio, 1), BackgroundColor3 = HC.AQUARIUS, BorderSizePixel = 0, Parent = sliderTrack })
	corner(sliderFill, 99)
	sliderKnob = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(attackRatio, 0.5), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = HC.AQUARIUS, BorderSizePixel = 0, ZIndex = 2, Parent = sliderTrack })
	corner(sliderKnob, 99)
end

-- Unit display (UnitDisplay.ts): border-t white/10, one box per actionList entry.
cp.unitSep = make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = hud })
local buildBar = make("Frame", { Name = "BuildBar", BackgroundTransparency = 1, Parent = hud })
make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Top,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 2),
	Parent = buildBar,
})
local actionButtons = {}
local actionList = {}
for _, kind in Config.STRUCTURE_ORDER do
	actionList[#actionList + 1] = { type = "build", kind = kind, def = Config.STRUCTURES[kind] }
end
for _, kind in Config.NUKE_ORDER do
	actionList[#actionList + 1] = { type = "nuke", kind = kind, def = Config.NUKES[kind] }
end
for _, kind in Config.UNIT_ORDER do
	actionList[#actionList + 1] = { type = "unit", kind = kind, def = Config.UNITS[kind] }
end
for i, a in actionList do
	local b = make("TextButton", {
		Name = "Action_" .. a.kind,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(148, 163, 184),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = Interact.keys.order(a.kind) or (20 + i), -- OpenFront's unit-display order
		Parent = buildBar,
	})
	corner(b, 3)
	local bStroke = stroke(b, Color3.fromRGB(100, 116, 139)) -- border-slate-500
	make("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 3), Parent = b })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2), Parent = b })
	local hotkey = label({ Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, TextSize = 10, TextColor3 = HC.GRAY400, TextYAlignment = Enum.TextYAlignment.Top, Text = "", LayoutOrder = 1, Parent = b })
	local icon = make("Frame", { Size = UDim2.fromOffset(20, 20), BackgroundTransparency = 1, LayoutOrder = 2, Parent = b })
	local glyph = IconKit.image(IconKit.KIND[a.kind] or a.kind, { Size = UDim2.fromScale(1, 1), Parent = icon })
	local count = label({ Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, TextSize = 12, Text = "", LayoutOrder = 3, Parent = b })
	local costText = label({ Size = UDim2.fromOffset(0, 0), Text = "", Visible = false, Parent = b }) -- cost lives in the tooltip
	actionButtons[i] = { button = b, stroke = bStroke, action = a, icon = icon, glyph = glyph, hotkey = hotkey, count = count, cost = costText }
end

-- Attack / mode line and the tutorial box, stacked just above the control panel.
local hudStack = make("Frame", { Name = "HudStack", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -140), Size = UDim2.fromOffset(500, 320), BackgroundTransparency = 1, Parent = gui })
make("UIListLayout", {
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 6),
	Parent = hudStack,
})
local attacksText = label({ Size = UDim2.new(1, 0, 0, 20), TextSize = 14, FontFace = FONT_BOLD, TextStrokeTransparency = 0.4, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Visible = false, LayoutOrder = 0, Parent = hudStack }) -- mode hint; attack rows: MatchHud (LayoutOrder 1)

-- Build-bar tooltip (hover / gamepad selection)
local buildTip = panel({ Name = "BuildTip", AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(210, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = HC.GRAY800, BackgroundTransparency = 0.05, Visible = false, ZIndex = 20, Active = false, Parent = gui })
stroke(buildTip, HC.GRAY600)
make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = buildTip })
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2), Parent = buildTip })
local tip = { text = {}, entry = nil } -- build-bar tooltip state
-- UnitDisplay hover card: bold "Name [key]", description, (warship hint), coin + cost (yellow-300).
tip.text.name = label({ Size = UDim2.new(1, 0, 0, 18), FontFace = FONT_BOLD, TextSize = 14, TextColor3 = Color3.fromRGB(229, 231, 235), ZIndex = 21, LayoutOrder = 1, Text = "", Parent = buildTip })
tip.text.info = label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 12, TextColor3 = Color3.fromRGB(229, 231, 235), TextWrapped = true, ZIndex = 21, LayoutOrder = 2, Text = "", Parent = buildTip })
tip.text.hint = label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 10, TextColor3 = Color3.fromRGB(103, 232, 249), TextWrapped = true, ZIndex = 21, LayoutOrder = 3, Visible = false, Text = "⇧ Hold Shift and drag to select multiple warships at once", Parent = buildTip })
do
	local row = make("Frame", { Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, ZIndex = 21, LayoutOrder = 4, Parent = buildTip })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = row })
	IconKit.image("Gold", { Size = UDim2.fromOffset(13, 13), ImageColor3 = HC.YELLOW, LayoutOrder = 1, ZIndex = 22, Parent = row })
	tip.text.cost = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, TextSize = 12, TextColor3 = Color3.fromRGB(253, 224, 71), ZIndex = 22, LayoutOrder = 2, Text = "", Parent = row })
end

-- Zoom buttons (useful on touch screens)
local zoomIn = make("TextButton", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -70), Size = UDim2.fromOffset(44, 44), BackgroundColor3 = PANEL, BackgroundTransparency = 0.15, FontFace = FONT_BOLD, TextSize = 24, TextColor3 = Color3.new(1, 1, 1), Text = "+", Parent = gui })
local zoomOut = make("TextButton", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -18), Size = UDim2.fromOffset(44, 44), BackgroundColor3 = PANEL, BackgroundTransparency = 0.15, FontFace = FONT_BOLD, TextSize = 24, TextColor3 = Color3.new(1, 1, 1), Text = "-", Parent = gui })
corner(zoomIn)
corner(zoomOut)

-- Credits / licence notice (required by OpenFront's AGPL additional terms)
local creditsText = label({
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 10, 1, -6),
	Size = UDim2.fromOffset(300, 60),
	TextSize = 11,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Bottom,
	TextTransparency = 0.15,
	TextStrokeTransparency = 0.5,
	Text = Config.GAME_TITLE .. " is a modified port of OpenFront. " .. Config.CREDIT .. ". AGPL-3.0 · " .. Config.ASSET_CREDIT .. "\nSource: " .. Config.SOURCE_URL,
	Parent = gui,
})

-- Hover tooltip
local tooltip = panel({ Size = UDim2.fromOffset(210, 44), BackgroundColor3 = HC.GRAY800, BackgroundTransparency = 0.08, Visible = false, ZIndex = 10, Active = false, Parent = gui })
stroke(tooltip, HC.GRAY600)
local tooltipText = label({ Size = UDim2.new(1, -12, 1, 0), Position = UDim2.fromOffset(6, 0), TextSize = 13, ZIndex = 11, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = tooltip })

-- End-of-round overlay
local overlay = panel({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromOffset(420, 100), Visible = false, Parent = gui })
stroke(overlay, Color3.fromRGB(255, 215, 0), 2)
local overlayText = label({ Size = UDim2.fromScale(1, 1), FontFace = FONT_BOLD, TextSize = 26, TextWrapped = true, Text = "", Parent = overlay })

-- Lobby map vote (o-modal look like every menu window: MenuKit tokens)
local MK = require(playerScripts:WaitForChild("MenuKit"))
local vote: any = { cards = {}, ids = {}, key = "", mine = nil } -- lobby map vote state (one table: 200-local limit)
vote.preview = require(playerScripts:WaitForChild("MapPreview")) -- terrain thumbnails of the options
vote.panel = panel({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.92, 0, 0, 300), BackgroundColor3 = MK.C.GRAY900, BackgroundTransparency = 0.08, Visible = false, Parent = gui })
vote.panel:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 16)
MK.stroke(vote.panel, 0.9)
make("UISizeConstraint", { MaxSize = Vector2.new(720, 300), Parent = vote.panel })
label({ Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 26), FontFace = MK.F.BOLD, TextSize = 20, Text = "VOTE FOR THE NEXT MAP", Parent = vote.panel })
vote.row = make("Frame", { Position = UDim2.fromOffset(16, 52), Size = UDim2.new(1, -32, 1, -68), BackgroundTransparency = 1, Parent = vote.panel })
make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	Padding = UDim.new(0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = vote.row,
})
for i = 1, Config.MAP_VOTE_OPTIONS do
	local card = make("TextButton", {
		Name = "VoteCard" .. i,
		LayoutOrder = i,
		Size = UDim2.new(1 / Config.MAP_VOTE_OPTIONS, -10, 1, 0),
		BackgroundColor3 = MK.C.WHITE,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Visible = false,
		Parent = vote.row,
	})
	corner(card, 12)
	local stroke = MK.stroke(card, 0.9)
	local nameText = label({ Position = UDim2.fromOffset(8, 12), Size = UDim2.new(1, -16, 0, 26), FontFace = MK.F.BOLD, TextSize = 18, TextScaled = false, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = card })
	-- Terrain preview of the map (MapPreview), like the main menu's map cards.
	local img = make("ImageLabel", { Position = UDim2.fromOffset(8, 42), Size = UDim2.new(1, -16, 1, -98), BackgroundColor3 = MK.C.BLACK, BackgroundTransparency = 0.6, ScaleType = Enum.ScaleType.Fit, ResampleMode = Enum.ResamplerMode.Pixelated, Parent = card })
	corner(img, 6)
	local sizeText = label({ Position = UDim2.new(0, 8, 1, -52), Size = UDim2.new(1, -16, 0, 18), FontFace = MK.F.MEDIUM, TextSize = 13, TextTransparency = 0.5, Text = "", Parent = card })
	local countText = label({ Position = UDim2.new(0, 8, 1, -32), Size = UDim2.new(1, -16, 0, 24), FontFace = MK.F.BOLD, TextSize = 16, TextColor3 = MK.C.AQUARIUS, Text = "", Parent = card })
	vote.cards[i] = { button = card, stroke = stroke, name = nameText, size = sizeText, count = countText, img = img }
	MK.hover(card, function(st)
		local mine = vote.ids[i] ~= nil and vote.ids[i] == vote.mine
		card.BackgroundColor3 = if mine then MK.C.MALIBU else MK.C.WHITE
		card.BackgroundTransparency = if mine then 0.75 elseif st == "idle" then 0.95 else 0.9
	end)
	card.Activated:Connect(function()
		local id = vote.ids[i]
		if id then
			vote.mine = id
			net:FireServer("vote", id)
			for j, c in vote.cards do
				local mine = vote.ids[j] == vote.mine
				c.stroke.Color = if mine then MK.C.MALIBU else MK.C.WHITE
				c.stroke.Transparency = if mine then 0 else 0.9
				c.stroke.Thickness = if mine then 2 else 1
				c.button.BackgroundColor3 = if mine then MK.C.MALIBU else MK.C.WHITE
				c.button.BackgroundTransparency = if mine then 0.75 else 0.95
			end
		end
	end)
end

local refreshVotePanel
vote.preview.onReady(function()
	if vote.panel.Visible then
		refreshVotePanel()
	end
end)

function refreshVotePanel()
	local pv = if phase.phase == "Lobby" then phase.vote else nil
	local show = pv ~= nil and #pv.options > 0
	vote.panel.Visible = show
	if not show then
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(vote.panel) then
			GuiService.SelectedObject = nil
		end
		return
	end
	local ids = {}
	for i, o in pv.options do
		ids[i] = o.id
	end
	local key = table.concat(ids, ",")
	if key ~= vote.key then
		vote.key = key
		vote.mine = nil
	end
	vote.ids = ids
	for i, c in vote.cards do
		local o = pv.options[i]
		c.button.Visible = o ~= nil
		if o then
			local mine = o.id == vote.mine
			c.name.Text = o.name
			c.size.Text = string.format("%d × %d", o.width, o.height)
			c.count.Text = if o.votes == 1 then "1 vote" else (o.votes .. " votes")
			c.name.Text = string.upper(o.name)
			local e = vote.preview.get(o.id, 220)
			if e and c.imgFor ~= o.id then
				c.imgFor = o.id
				c.img.ImageContent = Content.fromObject(e)
			elseif not e and c.imgFor ~= o.id then
				c.img.ImageContent = Content.none
			end
			c.stroke.Color = if mine then MK.C.MALIBU else MK.C.WHITE
			c.stroke.Transparency = if mine then 0 else 0.9
			c.stroke.Thickness = if mine then 2 else 1
			c.button.BackgroundColor3 = if mine then MK.C.MALIBU else MK.C.WHITE
			c.button.BackgroundTransparency = if mine then 0.75 else 0.95
		end
	end
	if UserInputService.GamepadEnabled and GuiService.SelectedObject == nil then
		GuiService.SelectedObject = vote.cards[1].button
	end
end

-- Camera (pan / zoom of the map image)
local zoom, panX, panY = 1, 0, 0
local camAnim = nil -- smooth "Go to" camera move (tutorial)

local function minZoom()
	local vs = holder.AbsoluteSize
	return math.min(vs.X / W, vs.Y / H) * 0.9
end

local function applyCamera()
	mapImage.Size = UDim2.fromOffset(W * zoom, H * zoom)
	mapImage.Position = UDim2.fromOffset(panX, panY)
end

local function fitMap()
	local vs = holder.AbsoluteSize
	zoom = math.min(vs.X / W, vs.Y / H)
	panX = (vs.X - W * zoom) / 2
	panY = (vs.Y - H * zoom) / 2
	applyCamera()
end

local function zoomAt(factor: number, sx: number, sy: number)
	camAnim = nil
	local newZoom = math.clamp(zoom * factor, minZoom(), 14)
	local hp = holder.AbsolutePosition
	local mx, my = sx - hp.X, sy - hp.Y
	panX = mx - (mx - panX) * (newZoom / zoom)
	panY = my - (my - panY) * (newZoom / zoom)
	zoom = newZoom
	applyCamera()
end

-- Smoothly centres the camera on map point (x, y), zoomed so about `span` tiles fit on screen.
local function focusCamera(x: number, y: number, span: number)
	local vs = holder.AbsoluteSize
	if vs.X < 2 or vs.Y < 2 then
		return
	end
	camAnim = {
		t0 = os.clock(),
		z0 = zoom,
		z1 = math.clamp(math.min(vs.X, vs.Y) / math.max(span, 30), minZoom(), 14),
		wx0 = (vs.X / 2 - panX) / zoom,
		wy0 = (vs.Y / 2 - panY) / zoom,
		wx1 = x + 0.5,
		wy1 = y + 0.5,
	}
end

-- Advances the camera move; returns true on the frame it finishes.
local function stepCamera(now: number): boolean
	local a = camAnim
	if not a then
		return false
	end
	local f = if Settings.values.reducedMotion then 1 else math.clamp((now - a.t0) / 0.5, 0, 1)
	local e = 1 - (1 - f) ^ 3
	local vs = holder.AbsoluteSize
	zoom = lerp(a.z0, a.z1, e)
	panX = vs.X / 2 - lerp(a.wx0, a.wx1, e) * zoom
	panY = vs.Y / 2 - lerp(a.wy0, a.wy1, e) * zoom
	applyCamera()
	if f >= 1 then
		camAnim = nil
		return true
	end
	return false
end

local function screenToTile(sx: number, sy: number): number?
	local ip = mapImage.AbsolutePosition
	local is = mapImage.AbsoluteSize
	local x = math.floor((sx - ip.X) / is.X * W)
	local y = math.floor((sy - ip.Y) / is.Y * H)
	if x < 0 or y < 0 or x >= W or y >= H then
		return nil
	end
	return y * W + x
end

local function tilePos(t: number): UDim2
	return UDim2.fromScale((t % W + 0.5) / W, (t // W + 0.5) / H)
end

local function xyPos(x: number, y: number): UDim2
	return UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
end

-- Labels, structures, HUD refresh
local nameLabels: { [number]: TextLabel } = {}

NameLabels.setup({
	layer = labelLayer,
	roster = roster,
	fmt = fmt,
	fmtTroops = fmtTroops,
	-- status icons from the shared contract: players we target / embargo
	isTarget = function(id: number): boolean
		return table.find(me.targets or {}, id) ~= nil
	end,
	hasEmbargo = function(id: number): boolean
		return table.find(me.embargoes or {}, id) ~= nil
	end,
	zoom = function()
		return zoom
	end,
	map = function()
		return map
	end,
	owners = function()
		return owners
	end,
	isAlly = ContextMenu.isAlly,
	isTraitor = ContextMenu.isTraitor,
	isShielded = DefeatScreen.isShielded,
	tagColor = ContextMenu.tagColor,
	net = net,
	getMyId = function()
		return myId
	end,
	-- PlayerIcons.ts nuke icon: nil, "white" (nukes in flight) or "red" (one is aimed at my land)
	nukeState = function(id: number): string?
		local state = nil
		for _, n in nukes do
			if n.owner == id and id ~= myId then
				state = "white"
				if myId ~= 0 and n.to and ownerOf(n.to) == myId then
					return "red"
				end
			end
		end
		return state
	end,
})

local function refreshNameLabels()
	NameLabels.refresh()
end

-- Structure markers (and SAM range rings) are pooled and drawn by MapMarkers.lua.
local function refreshStructures()
	MapMarkers.refresh(structureList, zoom)
end

local function refreshBoard()
	leaderboard.refresh()
end

local function actionCost(a): number
	return Interact.build.cost(a.kind) -- me.costs, else Config (BuildMenu.lua)
end

-- UnitDisplay.canBuild: gold, plus a Missile Silo for nukes and a Port for warships.
local function actionUsable(a, gold: number): boolean
	return gold >= actionCost(a) and (a.type ~= "nuke" or me.siloReady == true or me.hasSilo == true) and (a.type ~= "unit" or me.hasPort == true)
end

-- Our total levels of each structure / unit kind (UnitDisplay: totalUnitLevels).
local function ownedCounts(): { [string]: number }
	local counts = {}
	for _, a in actionList do
		counts[a.kind] = Interact.build.levels(a.kind)
	end
	return counts
end

function tip.update()
	local entry = tip.entry
	if not entry or not entry.button.Visible or not hud.Visible or not entry.button:IsDescendantOf(buildBar) or not buildBar.Visible then
		buildTip.Visible = false
		return
	end
	local a = entry.action
	local text = Interact.build.TEXT[a.kind] or { a.def.name, a.def.info or "" }
	local key = Interact.keys.hotkey(a.kind)
	tip.text.name.Text = text[1] .. (if key ~= "" then " [" .. key .. "]" else "")
	tip.text.info.Text = text[2]
	tip.text.hint.Visible = a.kind == "Warship"
	tip.text.cost.Text = fmt(actionCost(a))
	local sc = buildTip:FindFirstChild("DeviceScale") :: UIScale?
	local half = 105 * (if sc then sc.Scale else 1)
	local b = entry.button
	local pos = b.AbsolutePosition - gui.AbsolutePosition
	local x = math.clamp(pos.X + b.AbsoluteSize.X / 2, half + 4, math.max(half + 4, gui.AbsoluteSize.X - half - 4))
	buildTip.Position = UDim2.fromOffset(x, pos.Y - 4)
	buildTip.Visible = true
end

function tip.show(entry)
	tip.entry = entry
	tip.update()
end

function tip.hide(entry)
	if tip.entry == entry then
		tip.entry = nil
		buildTip.Visible = false
	end
end

local function refreshBuildBar()
	local mine = roster[myId]
	local gold = if mine then mine.stats.gold else 0
	local counts = ownedCounts()
	for _, entry in actionButtons do
		local a = entry.action
		local usable = actionUsable(a, gold)
		local selected = mode ~= nil and mode.type == a.type and mode.kind == a.kind
		local lit = usable or selected
		-- OpenFront always shows the key letter (gray-400, text-[10px])
		entry.hotkey.Text = Interact.keys.hotkey(a.kind)
		entry.count.Text = if a.type == "nuke" then "" else tostring(counts[a.kind] or 0)
		entry.count.Visible = a.type ~= "nuke"
		-- selected: bg-slate-400/20; disabled: opacity-40; disabledUnits: left out (UnitDisplay)
		entry.button.Visible = not Interact.build.disabled(a.kind)
		entry.button.BackgroundTransparency = if selected then 0.8 else 1
		entry.glyph.ImageTransparency = if lit then 0 else 0.6
		entry.count.TextTransparency = if lit then 0 else 0.6
		entry.hotkey.TextTransparency = if lit then 0 else 0.6
		entry.stroke.Transparency = if lit then 0 else 0.6
	end
	if tip.entry then
		tip.update()
	end
end

local function refreshHud()
	local mine = roster[myId]
	local pct = math.floor(attackRatio * 100 + 0.5)
	local compact = DeviceLayout.panelCompact == true
	cp.troopDesktop.Visible = not compact
	cp.troopMobile.Visible = compact
	if mine then
		local s = mine.stats
		-- Troops gained per second (config.troopIncreaseRate * 10 ticks), shown with renderTroops.
		local rate = 0
		if phase.phase == "Play" and s.alive then
			rate = Config.troopGrowth(mine.kind, s.troops, math.max(1, s.maxTroops)) / Config.TICK
		end
		rate = math.max(0, rate)
		-- _troopRateIsIncreasing: green while the rate keeps up, orange once it drops
		cp.increasing = rate >= cp.lastRate
		cp.lastRate = rate
		local rateColor = if cp.increasing then HC.GREEN400 else HC.ORANGE
		growthText.Text = "+" .. fmtTroops(rate) .. "/s"
		growthText.TextColor3 = rateColor
		cp.growthIcon.ImageColor3 = rateColor
		local border = growthPill:FindFirstChild("Border") :: UIStroke?
		if border then
			border.Color = rateColor
		end
		cp.mRate.Text = growthText.Text
		cp.mRate.TextColor3 = rateColor
		-- troops (malibu) + troops out attacking (aquarius)
		local attacking = 0
		for _, a in me.attacks or {} do
			attacking += tonumber(a[2]) or 0
		end
		local base = math.max(1, s.maxTroops)
		local green = math.clamp(s.troops / base, 0, 1)
		local orange = math.clamp(attacking / base, 0, 1 - green)
		troopBar.Size = UDim2.fromScale(green, 1)
		cp.attackBar.Position = UDim2.fromScale(green, 0)
		cp.attackBar.Size = UDim2.fromScale(orange, 1)
		troopsText.Text = fmtTroops(s.troops)
		cp.maxText.Text = fmtTroops(s.maxTroops)
		cp.mTroops.Text = troopsText.Text
		cp.mMax.Text = cp.maxText.Text
		goldText.Text = fmt(s.gold)
		ratioText.Text = if compact then string.format("%d%%\n(%s)", pct, fmtTroops(s.troops * attackRatio)) else string.format("%d%% (%s)", pct, fmtTroops(s.troops * attackRatio))
		-- computeNotification: low troops warning (< 1K shown troops)
		local low = s.alive and s.troops > 0 and s.troops < 10000 and phase.phase == "Play"
		if cp.notice.Visible ~= low then
			cp.notice.Visible = low
			DeviceLayout.relayout()
		end
	else
		growthText.Text = "+0/s"
		growthText.TextColor3 = HC.GRAY400
		troopsText.Text = "0"
		cp.maxText.Text = "0"
		cp.mTroops.Text, cp.mMax.Text, cp.mRate.Text = "0", "0", ""
		goldText.Text = "0"
		troopBar.Size = UDim2.fromScale(0, 1)
		cp.attackBar.Size = UDim2.fromScale(0, 1)
		ratioText.Text = string.format("%d%%", pct)
		if cp.notice.Visible then
			cp.notice.Visible = false
			DeviceLayout.relayout()
		end
	end
	-- ControlPanel.tick: hidden during the spawn phase and once we're dead / spectating
	local showPanel = mine ~= nil and mine.stats.alive and (phase.phase == "Play" or phase.phase == "Ended")
	if hud.Visible ~= showPanel then
		hud.Visible = showPanel
	end
	sliderFill.Size = UDim2.fromScale(attackRatio, 1)
	sliderKnob.Position = UDim2.fromScale(attackRatio, 0.5)

	local parts = {}
	if mode and mode.type == "unit" then
		parts[#parts + 1] = "Click near one of your ports (or the water to patrol) to launch a " .. Config.UNITS[mode.kind].name .. "  (right-click / Esc to cancel)"
	elseif mode then
		local def = if mode.type == "build" then Config.STRUCTURES[mode.kind] else Config.NUKES[mode.kind]
		parts[#parts + 1] = DeviceLayout.verb() .. (if mode.type == "build" then " your land to place a " else " a target for your ") .. def.name .. "  " .. DeviceLayout.cancelHint()
	else
		if selectedUnit then
			local count = 0
			for _ in selection.ids do
				count += 1
			end
			parts[#parts + 1] = (if count > 1 then count .. " warships selected" else "Warship selected") .. ": click water to move  (right-click / Esc to deselect)"
		end
		-- Attacks and boats are listed by MatchHud's attacks display (OpenFront AttacksDisplay).
	end
	attacksText.Text = table.concat(parts, "     ")
	attacksText.Visible = #parts > 0
	refreshBuildBar()
end

-- ControlPanel.addGoldGain: last-wins "+amount" above the gold box for 2 s, popping up 4 px.
function cp.showGain(amount: number)
	cp.gainToken += 1
	local token = cp.gainToken
	local g = cp.goldGain
	g.Text = "+" .. fmt(amount)
	g.Visible = true
	g.TextTransparency = 1
	g.Position = UDim2.new(1, -5, 0, 2)
	TweenService:Create(g, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.new(1, -5, 0, -2), TextTransparency = 0 }):Play()
	task.delay(2, function()
		if cp.gainToken == token then
			g.Visible = false
		end
	end)
end

local function refreshBanner()
	local ph = phase.phase
	local secs = math.ceil((phase.ticksLeft or 0) * Config.TICK)
	overlay.Visible = false
	if ph == "Lobby" then
		bannerText.Text = string.format("Next round starts in %ds", secs)
		if type(phase.waiting) == "table" then
			-- Match server: waiting for everyone the lobby sent (public_lobby.waiting_for_players).
			bannerText.Text = string.format("Waiting for players... %d/%d", phase.waiting.here or 0, phase.waiting.expected or 0)
		end
	elseif ph == "Spawn" then
		bannerText.Text = string.format("Starting in %ds", secs) -- "Choose a starting location": MatchHud heads-up
	elseif ph == "Play" then
		local mine = roster[myId]
		if myId == 0 then
			bannerText.Text = "Spectating - you'll join next round"
		elseif mine and not mine.stats.alive then
			bannerText.Text = "You were eliminated - spectating"
		else
			bannerText.Text = Config.GAME_TITLE .. " · " .. string.format("Win at %d%% of the land", Config.WIN_FRACTION * 100)
		end
	elseif ph == "Ended" then
		bannerText.Text = string.format(if phase.matchKind then "Game over - back to the lobby in %ds" else "Round over - next round in %ds", secs)
		overlayText.Text = if phase.winner then (phase.winner .. " wins!") else "Round over" -- shown by MatchHud's win modal
	end
	-- OpenFront has no status banner: in the spawn phase and while we play, the top-right sidebar
	-- (timer) and the heads-up message say it all. Lobby / spectating / round-over keep it.
	local mine = roster[myId]
	local wanted = not (ph == "Spawn" and myId ~= 0) and not (ph == "Play" and mine ~= nil and mine.stats.alive) and not Replay.active()
	if not wanted and banner.Visible then
		banner.Visible = false
		cp.bannerHidden = true
	elseif wanted and cp.bannerHidden then
		cp.bannerHidden = false
		banner.Visible = true
	end
	refreshVotePanel()
end

-- Event feed
local function pushFeed(text: string, kind: string, owner: number?)
	AlertsPanel.push(text, kind, owner)
end

-- Boats and nukes (drawn every frame from their start time)
local function addBoat(data)
	local path = data.path
	local n = buffer.len(path) // 4
	local p = roster[data.owner]
	local isTrade = data.kind == "trade"
	-- OpenFront UnitPass sprite in the owner's colours (OpenFront draws no troop label on boats).
	local dot = SpriteKit.unit(if isTrade then "TradeShip" else "Transport", { ZIndex = 3, Parent = unitLayer })
	SpriteKit.paint(dot, SpriteKit.owner(p))
	local troopsLabel = nil
	boats[data.id] = { path = path, n = n, start = data.start, speed = data.speed, dot = dot, label = troopsLabel, trade = isTrade }
	MapFx.boat(data) -- wake behind transports, red target ring for ours
end

local function removeBoat(id)
	local b = boats[id]
	if b then
		MapFx.boatEnd(id)
		b.dot:Destroy()
		if b.label then
			b.label:Destroy()
		end
		boats[id] = nil
	end
end

-- Seconds past a nuke's planned arrival before its outline is cleared without an end message
-- (a SAM missile can hold a nuke at its target for a few seconds).
local NUKE_GRACE = 6

local function dropNuke(id: number)
	local n = nukes[id]
	if n then
		n.dot:Destroy()
		n.ring:Destroy()
		nukes[id] = nil
	end
end

local function addNuke(data)
	dropNuke(data.id) -- never leave an older outline with the same id behind
	local fx, fy = data.from % W, data.from // W
	local tx, ty = data.to % W, data.to // W
	local def = Config.NUKES[data.kind]
	-- OpenFront sprite (atom / hydrogen bomb) flickering in hot colours, see the frame loop.
	local sprite = if data.kind == "HydrogenBomb" or data.kind == "MIRV" then data.kind else "AtomBomb"
	local dot = SpriteKit.unit(sprite, { ZIndex = 5, Parent = fxLayer })
	-- Target telegraph (dashed blast ring + inner disc) and trail, see MapMarkers.lua.
	local ring = MapMarkers.addNuke(data)
	-- OpenFront parabola (Shared.Ballistics): data.speed = tiles of arc per second.
	local curve = if data.arc then Ballistics.curve(fx + 0.5, fy + 0.5, tx + 0.5, ty + 0.5, H, nil, data.down == true) else nil
	nukes[data.id] = { fx = fx, fy = fy, tx = tx, ty = ty, start = data.start, duration = data.duration, dot = dot, ring = ring, owner = data.owner, to = data.to, hash = (data.id * 0.618) % 1, curve = curve, speed = data.speed, mirv = data.kind == "MIRV" }
end

-- OpenFront-style effects (MapFx.lua). Kept as one entry point for the warship code:
-- big = warship sunk (or a nuke when radius >= 4); small = move order (radius > 1.1) or shell hit.
local function explosion(tile: number, radius: number, big: boolean)
	if big then
		if radius >= 4 then
			MapFx.nukeEnd({ tile = tile, radius = radius, exploded = true })
		else
			MapFx.unitSunk(tile)
		end
	elseif radius > 1.1 then
		MapFx.moveIndicator(tile, myId)
	else
		MapFx.shellHit(tile)
	end
end

local function endNuke(data)
	dropNuke(data.id)
	if data.silent then
		return -- MIRV carrier separated into warheads (UnitFx)
	end
	MapFx.nukeEnd(data) -- nuke sprite, debris, shockwave and fallout glow / SAM interception
end

local function clearUnits()
	for id in boats do
		removeBoat(id)
	end
	for id, n in nukes do
		n.dot:Destroy()
		n.ring:Destroy()
		nukes[id] = nil
	end
	UnitFx.reset()
end

-- Warships (server sends "units" snapshots at ~5 Hz and "shot" effects)
local UNIT_LERP = 0.2 -- seconds between snapshots
local shots: { any } = {}


local function unitPos(u): (number, number)
	local f = math.clamp((os.clock() - u.t0) / UNIT_LERP, 0, 1)
	return lerp(u.fx, u.tx, f), lerp(u.fy, u.ty, f)
end

-- Replace the selection with the given warship ids (empty / nil = deselect).
local function selectUnits(ids: { number }?)
	table.clear(selection.ids)
	for id, ring in selection.rings do
		ring:Destroy()
		selection.rings[id] = nil
	end
	selectedUnit = nil
	for _, id in ids or {} do
		if units[id] then
			selection.ids[id] = true
			selectedUnit = selectedUnit or id
			local ring = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, ZIndex = 3, Parent = unitLayer })
			corner(ring, 9999)
			make("UIStroke", { Color = Color3.fromRGB(255, 220, 90), Thickness = 2, Parent = ring })
			selection.rings[id] = ring
		end
	end
	refreshHud()
end

local function selectUnit(id: number?)
	selectUnits(if id then { id } else nil)
end

local function destroyUnit(id: number, sunk: boolean)
	local u = units[id]
	if not u then
		return
	end
	if sunk then
		explosion(u.tile, 2.5, true)
	end
	u.marker:Destroy()
	u.bar:Destroy()
	units[id] = nil
	if selection.ids[id] then
		selection.ids[id] = nil
		selection.rings[id]:Destroy()
		selection.rings[id] = nil
		selectedUnit = next(selection.ids)
		refreshHud()
	end
end

local function applyUnits(b: buffer, fresh: boolean)
	local seen = {}
	local now = os.clock()
	for o = 0, buffer.len(b) - 16, 16 do
		local id = buffer.readu32(b, o)
		local ownerId = buffer.readu16(b, o + 4)
		local tile = buffer.readu32(b, o + 6)
		local health = buffer.readu16(b, o + 10)
		local flags = buffer.readu8(b, o + 12) -- bit0 in combat ("angry"), bit1 retreating / docked
		local maxHealth = math.max(1, buffer.readu16(b, o + 14))
		local x, y = tile % W, tile // W
		local u = units[id]
		if not u then
			-- OpenFront warship sprite + BarPass health bar (11x3 full-res tiles, 1-tile black border).
			local marker = SpriteKit.unit("Warship", { ZIndex = 3, Parent = unitLayer })
			local bar = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				BackgroundColor3 = Color3.new(0, 0, 0),
				BorderSizePixel = 0,
				Visible = false,
				ZIndex = 3,
				Parent = unitLayer,
			})
			local fill = make("Frame", { Position = UDim2.fromScale(1 / 11, 1 / 3), Size = UDim2.fromScale(9 / 11, 1 / 3), BorderSizePixel = 0, ZIndex = 3, Parent = bar })
			u = { marker = marker, bar = bar, fill = fill, fx = x, fy = y, tx = x, ty = y, t0 = now }
			units[id] = u
		else
			u.fx, u.fy = unitPos(u)
			u.tx, u.ty = x, y
			u.t0 = now
		end
		u.owner, u.tile, u.health = ownerId, tile, health
		u.angry, u.retreating = bit32.btest(flags, 1), bit32.btest(flags, 2)
		local p = roster[ownerId]
		SpriteKit.paint(u.marker, SpriteKit.owner(p))
		local frac = math.clamp(health / maxHealth, 0, 1)
		u.bar.Visible = frac < 1 and health > 0
		u.fill.Size = UDim2.fromScale(frac * 9 / 11, 1 / 3)
		-- render-settings.json "bar": red < 0.25 <= orange < 0.5 <= yellow < 0.75 <= green
		u.fill.BackgroundColor3 = if frac < 0.25 then Color3.new(0.91, 0.098, 0.098) elseif frac < 0.5 then Color3.new(0.941, 0.478, 0.098) elseif frac < 0.75 then Color3.new(0.792, 0.906, 0.059) else Color3.new(0.173, 0.937, 0.071)
		seen[id] = true
	end
	for id in units do
		if not seen[id] then
			destroyUnit(id, not fresh)
		end
	end
end

local function addShots(b: buffer)
	for o = 0, buffer.len(b) - 15, 15 do
		local from = buffer.readu32(b, o)
		local to = buffer.readu32(b, o + 4)
		local dur = buffer.readu16(b, o + 8) * Config.TICK
		local targetKind = buffer.readu8(b, o + 10) -- 1 warship, 2 boat (ShellExecution homes on it)
		local targetId = buffer.readu32(b, o + 11)
		local dot = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(255, 240, 170),
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = fxLayer,
		})
		-- OpenFront Shell: one full-res pixel (square) in flickering hot colours, see drawWarships.
		shots[#shots + 1] = { fx = from % W, fy = from // W, tx = to % W, ty = to // W, to = to, start = os.clock(), dur = math.max(0.1, dur), dot = dot, targetKind = targetKind, targetId = targetId }
	end
end

local function clearWarships()
	for id in units do
		destroyUnit(id, false)
	end
	for _, sh in shots do
		sh.dot:Destroy()
	end
	table.clear(shots)
	selectUnit(nil)
end

-- Our warship drawn within ~2 tiles (or ~10 px) of tile t, if any.
local function ownWarshipNear(t: number): number?
	local x, y = t % W, t // W
	local r = math.max(2, 10 / zoom)
	local best, bestD = nil, r * r
	for id, u in units do
		if u.owner == myId then
			local ux, uy = unitPos(u)
			local d = (ux - x) ^ 2 + (uy - y) ^ 2
			if d <= bestD then
				best, bestD = id, d
			end
		end
	end
	return best
end

-- Click handling for warships in normal mode. Returns true if the click was used.
local function warshipAct(t: number): boolean
	local hit = ownWarshipNear(t)
	if hit and (not selection.ids[hit] or next(selection.ids, next(selection.ids)) ~= nil) then
		selectUnit(hit)
		return true
	end
	if selectedUnit and not MapUtil.isLand(map, t) then
		for id in selection.ids do
			net:FireServer("moveWarship", t, id)
		end
		explosion(t, 1.2, false)
		return true
	end
	return false
end

local function drawWarships()
	local px = math.clamp(zoom * 2.4, 9, 24)
	local angryBlink = (serverNow() * 10 * 0.07) % 1 >= 0.5 -- unit.frag.glsl retreat blink
	for _, u in units do
		local x, y = unitPos(u)
		local pos = xyPos(x, y)
		u.marker.Position = pos
		-- UnitPass flags: attacking -> light band red (unit.angryR/G/B); retreating -> centre band
		-- blinks black.
		local territory, border = SpriteKit.owner(roster[u.owner])
		if u.angry then
			territory = Color3.new(0.784, 0, 0)
		end
		SpriteKit.paint(u.marker, territory, border)
		local centre = u.marker:FindFirstChild("C")
		if centre and centre:IsA("ImageLabel") and u.retreating and angryBlink then
			centre.ImageColor3 = Color3.new(0, 0, 0)
		end
		local cell = SpriteKit.cellPx(zoom)
		u.marker.Size = UDim2.fromOffset(cell, cell)
		if u.bar.Visible then
			-- BarPass: 11x3 full-res tiles, top edge 6 tiles above the unit centre
			u.bar.Position = pos - UDim2.fromOffset(0, 1.5 * zoom)
			u.bar.Size = UDim2.fromOffset(2.75 * zoom, 0.75 * zoom)
		end
	end
	for id, ring in selection.rings do
		local u = units[id]
		if u then
			ring.Position = xyPos(unitPos(u))
			ring.Size = UDim2.fromOffset(px * 1.6, px * 1.6)
		end
	end
	local now = os.clock()
	local dotPx = math.max(1, zoom * 0.25)
	local hot = math.floor((serverNow() * 3) % 4) -- unit.flickerSpeed 0.3 x 10 ticks/s
	local shellColor = if hot == 0 then Color3.new(1, 0, 0) elseif hot == 1 then Color3.new(1, 0.5, 0) elseif hot == 2 then Color3.new(1, 1, 0) else Color3.new(1, 1, 1)
	local i = 1
	while i <= #shots do
		local sh = shots[i]
		local f = (now - sh.start) / sh.dur
		if f >= 1 then
			sh.dot:Destroy()
			explosion(sh.to, 1, false)
			table.remove(shots, i)
		else
			-- Homing: the shell flies toward where its target is now.
			local tu = if sh.targetKind == 1 then units[sh.targetId] else nil
			local tb = if sh.targetKind == 2 then boats[sh.targetId] else nil
			if tu then
				sh.tx, sh.ty = unitPos(tu)
			elseif tb then
				local idx = math.clamp(math.floor((serverNow() - tb.start) * tb.speed), 0, tb.n - 1)
				local bt = buffer.readu32(tb.path, idx * 4)
				sh.tx, sh.ty, sh.to = bt % W, bt // W, bt
			end
			sh.dot.Position = xyPos(lerp(sh.fx, sh.tx, f), lerp(sh.fy, sh.ty, f))
			sh.dot.Size = UDim2.fromOffset(dotPx, dotPx)
			sh.dot.BackgroundColor3 = shellColor
			i += 1
		end
	end
end

-- Map switching (server picks the map each round; see 'init')
-- Loaded map (server mapKey: id, "@c" compact, "#" revision) and how many of the round's water
-- nuke edits we applied.
local mapSync = { key = "Europe#0", applied = 0 }

local function switchMap(id: string, compact: boolean?): boolean
	local mod = mapsFolder:WaitForChild(id, 10)
	if not mod then
		warn("[War Front] map module missing on client: " .. id)
		return false
	end
	local ok, result = pcall(MapUtil.load, mod)
	if not ok then
		warn("[War Front] map " .. id .. " failed to load: " .. tostring(result))
		return false
	end
	map = if compact then MapUtil.compact(result) else result
	W, H, SIZE = map.width, map.height, map.size
	currentMapId = id
	mapSync.applied = 0
	owners = buffer.create(SIZE * 2)
	MapRender.setMap(map)
	UnitFx.setMap(map)
	MapFx.reset()
	if ContextMenu and ContextMenu.setMap then
		ContextMenu.setMap(map)
	end
	fitMap()
	return true
end

-- Tutorial (PlayerGui attribute FrontlinesTutorial) and the pulsing ring on our territory
local tutorial, drawHomeRing
do
	local function liveTerritory(id: number)
		local p = roster[id]
		if p and p.stats.alive and p.stats.tiles > 0 then
			return p.stats
		end
		return nil
	end

	local function nearestEnemy()
		local home = liveTerritory(myId)
		if not home then
			return nil
		end
		local best, bestD = nil, math.huge
		for id, p in roster do
			if id ~= myId and not ContextMenu.isAlly(id) and p.stats.alive and p.stats.tiles > 0 then
				local d = (p.stats.cx - home.cx) ^ 2 + (p.stats.cy - home.cy) ^ 2
				if d < bestD then
					best, bestD = p.stats, d
				end
			end
		end
		return best
	end

	local function tutorialSnapshot()
		local mine = roster[myId]
		local s = if mine then mine.stats else nil
		local attacking, attackingPlayer = false, false
		for _, a in me.attacks or {} do
			attacking = true
			if a[1] ~= 0 then
				attackingPlayer = true
			end
		end
		return {
			inRound = myId ~= 0 and s ~= nil and (phase.phase == "Spawn" or phase.phase == "Play"),
			phase = phase.phase,
			spawned = s ~= nil and s.tiles > 0,
			alive = s ~= nil and (s.alive or phase.phase == "Spawn"),
			gold = if s then s.gold else 0,
			cityCost = (me.costs and me.costs.City) or Config.STRUCTURES.City.cost(0),
			counts = ownedCounts(),
			attacking = attacking,
			attackingPlayer = attackingPlayer,
			attacksSent = tutorialCounters.attacksSent,
			playerAttacksSent = tutorialCounters.playerAttacksSent,
			ratioMoves = tutorialCounters.ratioMoves,
		}
	end

	tutorial = Tutorial.create({
		parent = hudStack,
		layoutOrder = 2,
		deviceLayout = DeviceLayout,
		snapshot = tutorialSnapshot,
		canGoTo = function(kind: string): boolean
			if kind == "enemy" then
				return nearestEnemy() ~= nil
			end
			return liveTerritory(myId) ~= nil
		end,
		goTo = function(kind: string)
			local s = if kind == "enemy" then nearestEnemy() else liveTerritory(myId)
			if s then
				focusCamera(s.cx, s.cy, math.sqrt(s.tiles) * 3 + 20)
			end
		end,
	})

	-- OpenFront's breathing gold ring around our territory during the spawn phase and early
	-- tutorial steps (MapFx.spawnRing).
	function drawHomeRing(now: number)
		local s = liveTerritory(myId)
		local show = myId ~= 0 and s ~= nil and (phase.phase == "Spawn" or (phase.phase == "Play" and tutorial.wantsRing()))
		MapFx.spawnRing(if show then s else nil, now)
	end
end

-- Network
SoundKit.setup({
	myId = function()
		return myId
	end,
	roster = function()
		return roster
	end,
	structures = function()
		return structureList
	end,
})

local function onNet(kind: string, data: any, quiet: boolean?)
	if not quiet then
		pcall(SoundKit.onNet, kind, data) -- SoundEffectController cues
	end
	if kind == "init" then
		table.clear(roster)
		for _, l in nameLabels do
			l:Destroy()
		end
		table.clear(nameLabels)
		NameLabels.clear()
		NameLabels.setDoom(nil)
		Theme.resetClient()
		clearUnits()
		ContextMenu.reset()
		MapFx.reset()
		myId = data.myId
		me = { attacks = {}, costs = {}, boats = 0, hasSilo = false, siloReady = false }
		mode = nil
		AttackLabels.clear()
		require(playerScripts:WaitForChild("AlertFrame")).reset()
		tutorial.reset()
		if type(data.mapKey) == "string" then
			-- Compact maps and maps edited by water nukes reload whenever the server's copy changed.
			if data.mapKey ~= mapSync.key and switchMap(data.map, data.compact == true) then
				mapSync.key = data.mapKey
			end
		elseif data.map and data.map ~= currentMapId then
			switchMap(data.map)
		end
		if type(data.water) == "table" and #data.water > mapSync.applied then
			-- Water nukes from before we joined.
			local list = table.move(data.water, mapSync.applied + 1, #data.water, 1, {})
			mapSync.applied = #data.water
			MapRender.repaintTerrain(MapUtil.toWater(map, list))
		end
		applyRoster(data.roster)
		applyStats(data.stats)
		applyOwnersSnapshot(data.owners)
		structureList = data.structures
		phase = data.phase
		for _, b in data.boats do
			addBoat(b)
		end
		clearWarships()
		if data.units then
			applyUnits(data.units, true)
		end
		repaintAll()
		refreshStructures()
		refreshNameLabels()
		refreshBoard()
		refreshHud()
		refreshBanner()
	elseif kind == "tiles" then
		applyTiles(data)
	elseif kind == "roster" then
		applyRoster(data)
		repaintAll()
		refreshBoard()
	elseif kind == "stats" then
		applyStats(data)
		Perf.start("stats:names")
		refreshNameLabels()
		Perf.stop("stats:names")
		Perf.start("stats:board")
		refreshBoard()
		Perf.stop("stats:board")
		Perf.start("stats:hud")
		refreshHud()
		Perf.stop("stats:hud")
		refreshBanner()
	elseif kind == "structures" then
		structureList = data
		refreshStructures()
		refreshBuildBar()
	elseif kind == "phase" then
		local was = phase and phase.phase
		phase = data
		local mine = roster[myId]
		if was == "Spawn" and data.phase == "Play" and Settings.values.goToPlayer and mine and mine.stats.tiles > 0 then
			-- OpenFront "Go to player on start": zoom to our land when the spawn phase ends.
			focusCamera(mine.stats.cx, mine.stats.cy, math.sqrt(mine.stats.tiles) * 3 + 20)
		end
		refreshBanner()
		refreshHud()
	elseif kind == "me" then
		myId = data.id
		me = data
		local mine = roster[myId]
		require(playerScripts:WaitForChild("AlertFrame")).update(data, if mine then mine.stats.troops else 0, mine ~= nil and mine.stats.alive)
		AttackLabels.update(data)
		refreshHud()
	elseif kind == "betrayed" then
		require(playerScripts:WaitForChild("AlertFrame")).betrayed()
	elseif kind == "boat" then
		addBoat(data)
	elseif kind == "boatEnd" then
		removeBoat(data)
	elseif kind == "nuke" then
		addNuke(data)
	elseif kind == "nukeEnd" then
		endNuke(data)
	elseif kind == "event" then
		pushFeed(data.text, data.kind, data.owner)
	elseif kind == "diplomacy" then
		if ContextMenu.applyDiplomacy(data) then
			repaintAll()
		end
		refreshNameLabels()
		refreshBoard()
	elseif kind == "allyRequests" then
		ContextMenu.applyRequests(data)
	elseif kind == "units" then
		applyUnits(data, false)
		refreshBuildBar()
	elseif kind == "shot" then
		addShots(data)
	elseif kind == "water" then
		-- Water nukes: the same terrain edit as the server, then repaint.
		if type(data) == "table" then
			mapSync.applied += #data
			MapRender.repaintTerrain(MapUtil.toWater(map, data))
		end
	elseif kind == "clock" then
		NameLabels.setDoom(if type(data) == "table" then data.doom else nil)
		refreshNameLabels()
	elseif kind == "bonus" then
		-- Trade ship / train income (BonusEvent): "+ gold" over the port or station and the pip.
		if type(data) == "table" and tonumber(data.gold) and tonumber(data.tile) then
			MapFx.bonus(data.tile, data.gold)
			cp.showGain(data.gold)
		end
	elseif kind == "conquest" then
		MapFx.conquest(data) -- sword + "+ gold" where the player we conquered was
		if type(data) == "table" and data.killer == myId and myId ~= 0 and (tonumber(data.gold) or 0) > 0 then
			cp.showGain(data.gold) -- ControlPanel gold-gain pip (ConquestEvent)
		end
	elseif UnitFx.handle(kind, data) then
		-- rails / trains / warheads / warheadEnd / samMissile (UnitFx.lua)
	end
end

net.OnClientEvent:Connect(Perf.wrapNet(function(kind: string, data: any)
	Replay.record(kind, data)
	if Replay.blocks(kind, data) then
		return -- watching a replay: live map messages wait (the client resyncs afterwards)
	end
	onNet(kind, data)
end))

Replay.setup({
	dispatch = onNet,
	onStart = function()
		mode = nil
		refreshBuildBar()
		AlertsPanel.clear()
	end,
	onStop = function()
		AlertsPanel.clear()
		net:FireServer("ready") -- the server answers with the live round (init) or the lobby phase
	end,
})

ContextMenu.setup({
	gui = gui,
	net = net,
	map = map,
	roster = roster,
	getMyId = function()
		return myId
	end,
	getRatio = function()
		return attackRatio
	end,
	getMe = function()
		return me
	end,
	getPhase = function()
		return phase.phase
	end,
	ownerOf = ownerOf,
	fmt = fmt,
})

ContextMenu.onRequests = AlertsPanel.setRequests
leaderboard.focusPlayer = function(id: number) -- stats row click (GoToPlayerEvent)
	local p = roster[id]
	if p and p.stats and p.stats.tiles > 0 then
		focusCamera(p.stats.cx, p.stats.cy, math.sqrt(p.stats.tiles) * 3 + 20)
	end
end
AlertsPanel.bind({
	answer = ContextMenu.answerRequest,
	focusPlayer = function(id: number)
		local p = roster[id]
		if p and p.stats and p.stats.tiles > 0 then
			focusCamera(p.stats.cx, p.stats.cy, math.sqrt(p.stats.tiles) * 3 + 20)
		end
	end,
})

DefeatScreen.setup({
	net = net,
	focusTile = function(t: number)
		focusCamera(t % W, t // W, 40)
	end,
})

local function openContextMenuAt(sx: number, sy: number)
	local tile = screenToTile(sx, sy)
	if tile and phase.phase == "Play" then
		Interact.openMenu(sx, sy, tile) -- OpenFront radial menu (RadialMenu.lua)
	end
end

-- Input
local function setRatio(r: number)
	local old = attackRatio
	attackRatio = math.clamp(math.floor(r * 100 + 0.5) / 100, 0.01, 1)
	if attackRatio ~= old then
		tutorialCounters.ratioMoves += 1
		Settings.set("attackRatio", math.floor(attackRatio * 100 + 0.5)) -- remembered between games
	end
	refreshHud()
end

local function setMode(newMode)
	if newMode and mode and mode.type == newMode.type and mode.kind == newMode.kind then
		mode = nil
	else
		mode = newMode
	end
	refreshHud()
end

for _, entry in actionButtons do
	local b = entry.button
	b.Activated:Connect(function()
		-- UnitDisplay: a click deselects the selected kind, or selects one we can afford
		local a = entry.action
		local selected = mode ~= nil and mode.type == a.type and mode.kind == a.kind
		local mine = roster[myId]
		if selected or actionUsable(a, if mine then mine.stats.gold else 0) then
			setMode({ type = a.type, kind = a.kind })
		end
	end)
	b.MouseEnter:Connect(function()
		if DeviceLayout.state.input ~= "Touch" then
			tip.show(entry)
		end
	end)
	b.MouseLeave:Connect(function()
		tip.hide(entry)
	end)
	b.SelectionGained:Connect(function()
		tip.show(entry)
	end)
	b.SelectionLost:Connect(function()
		tip.hide(entry)
	end)
end

leaderboard.toggle.Activated:Connect(function()
	DeviceLayout.toggleBoard()
end)

local sliderDragging = false
slider.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		sliderDragging = true
		setRatio((input.Position.X - slider.AbsolutePosition.X) / slider.AbsoluteSize.X)
	end
end)

local function refreshOverlays()
	refreshNameLabels()
	refreshStructures()
end

zoomIn.Activated:Connect(function()
	local c = holder.AbsolutePosition + holder.AbsoluteSize / 2
	zoomAt(1.4, c.X, c.Y)
	refreshOverlays()
end)
zoomOut.Activated:Connect(function()
	local c = holder.AbsolutePosition + holder.AbsoluteSize / 2
	zoomAt(1 / 1.4, c.X, c.Y)
	refreshOverlays()
end)

local function act(t: number)
	local ph = phase.phase
	if ph == "Spawn" then
		net:FireServer("spawn", t)
		SoundKit.play("spawn") -- SendSpawnIntentEvent
	elseif ph == "Play" then
		if mode then
			-- BuildPreviewController.createStructure: upgrade the structure under the ghost when
			-- there is one, else build; atom / hydrogen bomb ghosts stay armed for the next target.
			local keep = mode.type == "nuke" and (mode.kind == "AtomBomb" or mode.kind == "HydrogenBomb")
			-- Hold Shift to keep placing the same building / unit (quick placement).
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
				keep = true
			end
			if mode.type == "build" then
				local _, canUpgrade = Interact.build.ghostInfo(mode.kind, t)
				if canUpgrade then
					net:FireServer("upgrade", t, mode.kind)
				else
					net:FireServer("build", t, mode.kind)
				end
			elseif mode.type == "unit" then
				net:FireServer("buildUnit", t, mode.kind)
			else
				Interact.build.fireNuke(t, mode.kind)
			end
			if not keep then
				mode = nil
			end
			refreshHud()
		elseif not warshipAct(t) then
			local o = ownerOf(t)
			if o ~= myId then
				tutorialCounters.attacksSent += 1
				if o ~= 0 then
					tutorialCounters.playerAttacksSent += 1
				end
			end
			net:FireServer("attack", t, attackRatio)
		end
	end
end

local pressPos: Vector2? = nil
local pressInput: InputObject? = nil
local dragging = false
local lastPointer = Vector2.zero
local LONG_PRESS = 0.45 -- seconds a touch must be held (without dragging) to open the context menu
local pressToken = 0
local longPressed = false

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local t = input.UserInputType
	if vote.panel.Visible and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
		return -- the map can't be dragged or clicked behind the map vote
	end
	if t == Enum.UserInputType.MouseButton1 and phase.phase == "Play" and not mode and KeybindData.held("boxSelectWarships") then
		-- OpenFront: hold Shift and drag to box-select warships.
		selection.boxStart = Vector2.new(input.Position.X, input.Position.Y)
		return
	end
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		pressPos = Vector2.new(input.Position.X, input.Position.Y)
		pressInput = input
		dragging = false
		lastPointer = pressPos
		pressToken += 1
		longPressed = false
		if t == Enum.UserInputType.Touch then
			local token = pressToken
			task.delay(LONG_PRESS, function()
				local at = pressPos
				if token == pressToken and at and pressInput == input and not dragging and (lastPointer - at).Magnitude <= 10 then
					longPressed = true
					openContextMenuAt(at.X, at.Y)
				end
			end)
		end
	elseif t == Enum.UserInputType.MouseButton2 then
		if mode then
			mode = nil
			refreshHud()
		elseif selectedUnit then
			selectUnit(nil) -- warships: right-click clears the selection
		else
			openContextMenuAt(input.Position.X, input.Position.Y)
		end
	elseif t == Enum.UserInputType.Keyboard then
		Interact.keys.keyDown(input) -- OpenFront keybinds (Keybinds.lua)
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseWheel and not processed then
		if vote.panel.Visible then
			return
		end
		if Interact.keys.wheel(input) then
			return -- Shift + wheel: attack ratio
		end
		zoomAt(if input.Position.Z > 0 then 1.2 else 1 / 1.2, input.Position.X, input.Position.Y)
		refreshOverlays()
	elseif t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		if t == Enum.UserInputType.MouseMovement then
			mouseAbs = pos
		end
		if sliderDragging then
			setRatio((pos.X - slider.AbsolutePosition.X) / slider.AbsoluteSize.X)
			return
		end
		local b0 = selection.boxStart
		if b0 then
			if not selection.box then
				selection.box = make("Frame", { BackgroundColor3 = Color3.fromRGB(255, 220, 90), BackgroundTransparency = 0.85, BorderSizePixel = 0, ZIndex = 50, Parent = gui })
				make("UIStroke", { Color = Color3.fromRGB(255, 220, 90), Thickness = 1, Parent = selection.box })
			end
			selection.box.Visible = true
			selection.box.Position = UDim2.fromOffset(math.min(b0.X, pos.X), math.min(b0.Y, pos.Y))
			selection.box.Size = UDim2.fromOffset(math.abs(pos.X - b0.X), math.abs(pos.Y - b0.Y))
			return
		end
		if pressPos and (t == Enum.UserInputType.MouseMovement or input == pressInput) then
			if not dragging and math.abs(pos.X - pressPos.X) + math.abs(pos.Y - pressPos.Y) >= 10 then -- OpenFront DRAG_THRESHOLD_PX
				dragging = true
			end
			if dragging then
				camAnim = nil
				local d = pos - lastPointer
				panX += d.X
				panY += d.Y
				applyCamera()
			end
			lastPointer = pos
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 and selection.boxStart then
		local a, b = selection.boxStart, Vector2.new(input.Position.X, input.Position.Y)
		local lo, hi = a:Min(b), a:Max(b)
		selection.boxStart = nil
		if selection.box then
			selection.box.Visible = false
		end
		local ids = {}
		for id, u in units do
			local c = u.marker.AbsolutePosition + u.marker.AbsoluteSize / 2
			if u.owner == myId and c.X >= lo.X and c.X <= hi.X and c.Y >= lo.Y and c.Y <= hi.Y then
				ids[#ids + 1] = id
			end
		end
		selectUnits(ids)
		return
	end
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		sliderDragging = false
		if pressPos and not dragging and not longPressed and (t == Enum.UserInputType.MouseButton1 or input == pressInput) then
			local tile = screenToTile(pressPos.X, pressPos.Y)
			local mods = t == Enum.UserInputType.MouseButton1 and phase.phase == "Play" and not mode
			local ctrl = mods and KeybindData.held("buildMenuModifier")
			local alt = mods and KeybindData.held("emojiMenuModifier")
			if tile and ctrl then
				-- OpenFront: Ctrl + click (buildMenuModifier) opens the build menu grid (BuildMenu.lua).
				Interact.openBuildMenu(tile)
			elseif tile and alt then
				-- Alt + click: emoji table for that player (ourselves = everyone).
				if ownerOf(tile) ~= 0 and roster[ownerOf(tile)] then
					Interact.panel.showEmojiTable(ownerOf(tile))
				end
			elseif tile and Settings.values.leftClickMenu and phase.phase == "Play" and not mode and not ownWarshipNear(tile) and not selectedUnit then
				openContextMenuAt(pressPos.X, pressPos.Y) -- OpenFront "Left Click to Open Menu"
			elseif tile then
				act(tile)
			end
		end
		pressPos = nil
		pressInput = nil
		dragging = false
	end
end)

local pinchLast = 1
UserInputService.TouchPinch:Connect(function(positions, scale, _velocity, state, processed)
	if processed or #positions < 2 or vote.panel.Visible then
		return
	end
	if state == Enum.UserInputState.Begin then
		pinchLast = scale
	elseif state == Enum.UserInputState.Change then
		local c = (positions[1] + positions[2]) / 2
		zoomAt(scale / pinchLast, c.X, c.Y)
		pinchLast = scale
		dragging = true
	else
		pinchLast = 1
		refreshOverlays()
	end
end)

-- Devices: per-device layout (phone / tablet / console / desktop) and gamepad controls
DeviceLayout.bindMatchUI({
	gui = gui,
	backdrop = backdrop,
	banner = banner,
	bannerText = bannerText,
	board = board,
	boardWidth = leaderboard.width,
	setBoardOpen = leaderboard.setExpanded,
	setBoardDensity = leaderboard.setDensity,
	feedFrame = feedFrame,
	alerts = AlertsPanel,
	hud = hud,
	growthPill = growthPill,
	troopBox = troopBox,
	goldPill = goldPill,
	panelTexts = { growthText, troopsText, goldText },
	ratioText = ratioText,
	ratioBox = cp.ratioBox,
	notice = cp.notice,
	unitSep = cp.unitSep,
	slider = slider,
	buildBar = buildBar,
	actionButtons = actionButtons,
	stack = hudStack,
	attacksText = attacksText,
	buildTip = buildTip,
	zoomIn = zoomIn,
	zoomOut = zoomOut,
	credits = creditsText,
	creditsFull = creditsText.Text,
	creditsShort = Config.GAME_TITLE .. " is a modified port of OpenFront · " .. Config.CREDIT .. " · AGPL-3.0 · " .. Config.ASSET_CREDIT .. " · Source: " .. Config.SOURCE_URL,
	tooltip = tooltip,
	overlay = overlay,
})
DeviceLayout.Changed:Connect(function()
	refreshHud()
	refreshBanner()
end)
HoverPanel.init({
	gui = gui,
	banner = banner,
	roster = roster,
	fmt = fmt,
	fmtTroops = fmtTroops,
	contextMenu = ContextMenu,
	deviceLayout = DeviceLayout,
	getMyId = function()
		return myId
	end,
	getStructures = function()
		return structureList
	end,
	getUnits = function()
		return units
	end,
})

local gamepad = GamepadControls.start({
	gui = gui,
	deviceLayout = DeviceLayout,
	buildBar = buildBar,
	act = act,
	tileAt = screenToTile,
	contextMenu = function(sx, sy)
		openContextMenuAt(sx, sy)
	end,
	cancel = function(): boolean
		if mode then
			mode = nil
			refreshHud()
			return true
		end
		if selectedUnit then
			selectUnit(nil)
			return true
		end
		return DeviceLayout.closePopups()
	end,
	adjustRatio = function(delta)
		setRatio(attackRatio + delta)
	end,
	cycleAction = function(dir)
		local n = #actionList
		local cur = 0
		if mode then
			for i, a in actionList do
				if a.type == mode.type and a.kind == mode.kind then
					cur = i
				end
			end
		end
		local nxt = (cur + dir) % (n + 1)
		if nxt == 0 then
			mode = nil
			refreshHud()
		else
			setMode({ type = actionList[nxt].type, kind = actionList[nxt].kind })
		end
	end,
	zoomAt = zoomAt,
	pan = function(dx, dy)
		panX += dx
		panY += dy
		applyCamera()
	end,
	fitMap = function()
		fitMap()
		refreshOverlays()
	end,
	overlaysChanged = refreshOverlays,
	focusTarget = function()
		local first = actionButtons[1]
		return first and first.button
	end,
	modeActive = function()
		return mode ~= nil
	end,
})

-- OpenFront interaction: radial menu, player panel / emojis, attacks display, win modal, keybinds.
Interact.setup({
	gui = gui,
	net = net,
	roster = roster,
	fmt = fmt,
	fmtTroops = fmtTroops,
	contextMenu = ContextMenu,
	stack = hudStack,
	labelLayer = labelLayer,
	actionList = actionList,
	act = act,
	setMode = setMode,
	setRatio = setRatio,
	zoomAt = zoomAt,
	pushFeed = pushFeed,
	ownerOf = ownerOf,
	overlaysChanged = refreshOverlays,
	getMap = function()
		return map
	end,
	mapSize = function()
		return W, H
	end,
	getMyId = function()
		return myId
	end,
	getRatio = function()
		return attackRatio
	end,
	getMe = function()
		return me
	end,
	getPhase = function()
		return phase.phase
	end,
	getStructures = function()
		return structureList
	end,
	getUnits = function()
		return units
	end,
	selectAllWarships = function()
		local ids = {}
		for id, u in units do
			if u.owner == myId then
				ids[#ids + 1] = id
			end
		end
		selectUnits(ids)
	end,
	pan = function(dx, dy)
		camAnim = nil
		panX += dx
		panY += dy
		applyCamera()
	end,
	fitMap = function()
		fitMap()
		refreshOverlays()
	end,
	viewCenter = function()
		return holder.AbsolutePosition + holder.AbsoluteSize / 2
	end,
	tileAtMouse = function()
		return screenToTile(mouseAbs.X, mouseAbs.Y)
	end,
	focusPlayer = function(id: number)
		local p = roster[id]
		if p and p.stats and p.stats.tiles > 0 then
			focusCamera(p.stats.cx, p.stats.cy, math.sqrt(p.stats.tiles) * 3 + 20)
		end
	end,
	centerCamera = function()
		-- OpenFront C: pan to our territory, keeping the zoom.
		local p = roster[myId]
		local vs = holder.AbsoluteSize
		if p and p.stats.tiles > 0 then
			focusCamera(p.stats.cx, p.stats.cy, math.min(vs.X, vs.Y) / zoom)
		end
	end,
	cancel = function()
		mode = nil
		refreshHud()
		if selectedUnit then
			selectUnit(nil)
		end
	end,
})

-- OpenFront AlertFrame (betrayal / land attack border) and PerformanceOverlay (Shift + D).
require(playerScripts:WaitForChild("AlertFrame")).mount(gui)
require(playerScripts:WaitForChild("PerfOverlay")).mount(gui)

-- Player settings (Settings.lua): display toggles; other settings are read where they're used.
do
	local function applyDisplaySettings()
		labelLayer.Visible = Settings.values.nameLabels
		structureLayer.Visible = Settings.values.structureIcons
		AlertsPanel.setFeedEnabled(Settings.values.eventFeed)
	end
	applyDisplaySettings()
	Settings.Changed:Connect(function(key: string)
		if key == "terrainShading" then
			buildBaseColors()
			repaintAll()
		elseif key == "attackRatio" then
			attackRatio = math.clamp((tonumber(Settings.values.attackRatio) or 20) / 100, 0.01, 1)
			refreshHud()
		elseif key == "anonymousNames" then
			for _, p in roster do
				p.name = rosterName(p)
			end
			refreshNameLabels()
			refreshBoard()
		elseif key == "borderContrast" then
			for _, p in roster do
				Theme.applyPlayerColors(p, Settings.values.borderContrast) -- colour-blind palette
			end
			repaintAll()
			refreshNameLabels()
			refreshBoard()
		end
		applyDisplaySettings()
	end)
end

-- Frame loop
local lastTutorialUpdate = 0
RunService.RenderStepped:Connect(function()
	local now = os.clock()
	Perf.start("frame")
	if stepCamera(now) then
		refreshOverlays()
	end
	if now - lastTutorialUpdate > 0.2 then
		lastTutorialUpdate = now
		tutorial.update()
	end
	drawHomeRing(now)
	Perf.start("names")
	NameLabels.step(now)
	Perf.stop("names")
	Perf.start("mapRender")
	MapRender.step(now, zoom)
	Perf.stop("mapRender")
	Perf.start("mapFx")
	MapFx.step(now, zoom)
	Perf.stop("mapFx")
	do -- AmbienceController: structure loops near the screen centre when zoomed in
		local hp, hs = holder.AbsolutePosition, holder.AbsoluteSize
		SoundKit.step(zoom, 14, screenToTile(hp.X + hs.X / 2, hp.Y + hs.Y / 2), W)
	end

	-- Boats
	local st = serverNow()
	local boatPx = SpriteKit.cellPx(zoom) -- OpenFront unit cell: 13 full-res tiles, scales with the map
	for _, b in boats do
		local idx = math.clamp(math.floor((st - b.start) * b.speed), 0, b.n - 1)
		local t = buffer.readu32(b.path, idx * 4)
		local pos = tilePos(t)
		b.dot.Position = pos
		b.dot.Size = UDim2.fromOffset(boatPx, boatPx)
		if b.label then
			b.label.Position = pos - UDim2.fromOffset(0, boatPx * 0.6)
			b.label.Visible = zoom > 1.5 and not Settings.values.lowDetail
		end
	end

	Perf.start("units")
	drawWarships()
	UnitFx.step(st, zoom) -- trains, MIRV warheads, SAM missiles
	Perf.stop("units")

	-- Nukes
	local nukePx = SpriteKit.cellPx(zoom)
	local targetR2 = (150 / Config.LINEAR_SCALE) ^ 2 -- defaultNukeTargetableRange
	for id, n in nukes do
		if st > n.start + n.duration + NUKE_GRACE then
			dropNuke(id) -- its end message never came (a lost or stale nuke): clear the outline
			continue
		end
		local x, y
		if n.curve then
			x, y = Ballistics.at(n.curve, math.max(0, st - n.start) * (n.speed or 0))
			x, y = x - 0.5, y - 0.5
		else
			local f = math.clamp((st - n.start) / n.duration, 0, 1)
			x = n.fx + (n.tx - n.fx) * f
			y = n.fy + (n.ty - n.fy) * f
		end
		n.dot.Position = xyPos(x, y)
		n.dot.Size = UDim2.fromOffset(nukePx, nukePx)
		SpriteKit.flicker(n.dot, st, n.hash or 0)
		-- Out of SAM reach (far from both launch and target): drawn translucent (unit.untargetableAlpha).
		local targetable = n.mirv or (x - n.tx) ^ 2 + (y - n.ty) ^ 2 < targetR2 or (x - n.fx) ^ 2 + (y - n.fy) ^ 2 < targetR2
		local tr = if targetable then 0 else 0.4
		if n.alpha ~= tr then
			n.alpha = tr
			for _, layer in n.dot:GetChildren() do
				if layer:IsA("ImageLabel") and layer.Name ~= "Glow" then
					layer.ImageTransparency = tr
				end
			end
		end
	end
	Perf.start("markers")
	MapMarkers.step(st, zoom, mode)
	Perf.stop("markers")

	-- Tooltip
	local mp = mouseAbs
	local tp = mp
	local padAbs, padLocal = gamepad.pointer()
	if padAbs and padLocal then
		mp, tp = padAbs, padLocal
	end
	local tile = screenToTile(mp.X, mp.Y)
	local o = if tile then ownerOf(tile) else 0
	-- Attack troop labels (AttackingTroopsController): hidden in the alternate view.
	AttackLabels.step(MapRender.altView() or phase.phase ~= "Play")
	-- Build ghost under the cursor (BuildPreviewController): validity re-checked every 50 ms,
	-- the icon follows the pointer every frame. Not on touch screens without a gamepad pointer.
	-- Warships and bombs can be aimed at water too, so only buildings hide their ghost there.
	if mode and tile and (padAbs or DeviceLayout.state.input ~= "Touch") and (mode.type ~= "build" or MapUtil.isLand(map, tile)) then
		if now - ghost.checkAt > 0.05 or ghost.tile ~= tile or ghost.kind ~= mode.kind then
			ghost.checkAt, ghost.tile, ghost.kind = now, tile, mode.kind
			local canPlace, canUpgrade, upTile, cost, afford = Interact.build.ghostInfo(mode.kind, tile)
			ghost.state = {
				kind = mode.kind,
				owner = myId,
				canPlace = canPlace,
				canUpgrade = canUpgrade,
				upgradeTile = upTile,
				cost = cost,
				canAfford = afford,
				showCost = Settings.values.cursorCostLabel ~= false,
			}
		end
		local ip, is = mapImage.AbsolutePosition, mapImage.AbsoluteSize
		ghost.state.x = (mp.X - ip.X) / is.X * W
		ghost.state.y = (mp.Y - ip.Y) / is.Y * H
		MapMarkers.setGhost(ghost.state, zoom)
		ghost.shown = true
	elseif ghost.shown then
		ghost.shown, ghost.kind = false, nil
		MapMarkers.setGhost(nil, zoom)
	end
	-- OpenFront hover highlight (land only, not on touch screens): brighter fill, thicker border.
	MapRender.setHighlight(if tile and DeviceLayout.state.input ~= "Touch" and MapUtil.isLand(map, tile) then o else 0)
	-- Top-centre hover panel (HoverPanel.lua); the floating tooltip is only a fallback now.
	if HoverPanel.update(o, padAbs ~= nil) then
		tooltip.Visible = false
	elseif tile and o ~= 0 and roster[o] and not buildTip.Visible and (padAbs or not UserInputService.TouchEnabled) then
		local p = roster[o]
		tooltip.Visible = true
		tooltip.Position = UDim2.fromOffset(tp.X + 16, tp.Y + 8)
		tooltipText.Text = string.format(
			"%s%s\nTroops %s · Land %.1f%%",
			p.name,
			if p.kind == "Bot" then " (bot)" elseif p.kind == "Human" then string.format(" · Lv %d", p.level or 1) else "",
			fmt(p.stats.troops),
			p.stats.tiles / map.landTiles * 100
		)
	else
		tooltip.Visible = false
	end
	Perf.stop("frame")
end)

task.defer(function()
	task.wait()
	fitMap()
	repaintAll()
	refreshHud()
	refreshBanner()
	net:FireServer("ready")
end)

holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if zoom < minZoom() then
		fitMap()
	end
end)
