--[[
	War Front - build menu grid (OpenFront's BuildMenu) and build / upgrade rules shared by the HUD.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.BuildMenu (ModuleScript), used by GameClient (via Interact),
-- RadialMenu and the unit display.
--
-- Mirrors src/client/hud/layers/BuildMenu.ts: Ctrl + click on the map opens a centred #1e1e1e
-- card with one 120x140 button per buildable (buildTable order: Atom Bomb, MIRV, Hydrogen Bomb,
-- Warship, Port, Missile Silo, SAM Launcher, Defense Post, City, Factory - kinds missing from
-- Config are skipped). Each button: 40 px icon, bold name, build_menu.desc text, cost + coin, and
-- (countable kinds) a count chip with the player's total levels of that kind. A button is enabled
-- when the player can build there OR upgrade an own structure of that kind near the tile
-- (PlayerImpl.buildableUnits: canUpgrade wins over canBuild). Clicking sends "upgrade" (tile) or
-- the build intent and closes. Closes on Esc / gamepad B / a click outside / any map press.
--
-- BuildMenu.setup(ctx)  ctx: gui, net, roster, fmt(n), getMyId(), getMe(), getMap(),
--                       getStructures(), getUnits(), ownerOf(tile), getPhase()
-- BuildMenu.show(tile), BuildMenu.hide(), BuildMenu.isOpen()
-- Shared rules (used by RadialMenu / GameClient):
--   BuildMenu.TABLE                ordered list of kinds (buildTable)
--   BuildMenu.TEXT[kind]           { name, description } (en.json unit_type.* / build_menu.desc.*)
--   BuildMenu.isAttack(kind)       nukes + warship (BuildableAttacks)
--   BuildMenu.cost(kind)           current cost for us
--   BuildMenu.levels(kind)         our total levels of that kind (totalUnitLevels)
--   BuildMenu.upgradeTarget(kind, tile) -> structure row?   own, finished, upgradable, in range
--   BuildMenu.canBuild(kind, tile) -> boolean               a new one could go there
--   BuildMenu.canBuildOrUpgrade(kind, tile) -> boolean
--   BuildMenu.ghostInfo(kind, tile) -> canPlace, canUpgrade, upgradeTile?, cost, canAfford
--   BuildMenu.perform(kind, tile)  sends "upgrade" or the build / nuke / unit intent
--   BuildMenu.fireNuke(tile, kind) sends a nuke with the rocket direction (KeybindData.rocketUp),
--                                  held back once if it would hit a brand-new ally (Settings
--                                  "nukeAllySafety", BuildPreviewController.shouldBlockRecentAllyNuke)

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local SimClock = require(Shared:WaitForChild("SimClock"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local KeybindData = require(script.Parent:WaitForChild("KeybindData"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))

local BuildMenu = {}

BuildMenu.TABLE = { "AtomBomb", "MIRV", "HydrogenBomb", "Warship", "Port", "MissileSilo", "SAM", "DefensePost", "City", "Factory" }
BuildMenu.TEXT = {
	AtomBomb = { "Atom Bomb", "Small explosion" },
	MIRV = { "MIRV", "Huge explosion, only targets selected player" },
	HydrogenBomb = { "Hydrogen Bomb", "Large explosion" },
	Warship = { "Warship", "Captures trade ships, destroys ships and boats" },
	Port = { "Port", "Sends trade ships to generate gold" },
	MissileSilo = { "Missile Silo", "Used to launch nukes" },
	SAM = { "SAM Launcher", "Defends against incoming nukes" },
	DefensePost = { "Defense Post", "Increases defenses of nearby borders" },
	City = { "City", "Increases max population" },
	Factory = { "Factory", "Creates railroads and spawns trains" },
}
-- Config.ts unitInfo(...).upgradable (used when Config.STRUCTURES[kind].upgradable isn't set).
local UPGRADABLE = { City = true, Port = true, MissileSilo = true, SAM = true, Factory = true }
-- structureMinDist() is 15 full-size tiles; the map is 1/4 scale per axis (Config.LINEAR_SCALE).
local UPGRADE_RANGE = 15 / Config.LINEAR_SCALE

local ctx: any = nil
local NB = table.create(4)

local function defOf(kind: string)
	return Config.STRUCTURES[kind] or Config.NUKES[kind] or Config.UNITS[kind]
end

function BuildMenu.exists(kind: string): boolean
	return defOf(kind) ~= nil
end

function BuildMenu.isAttack(kind: string): boolean
	return Config.NUKES[kind] ~= nil or Config.UNITS[kind] ~= nil
end

function BuildMenu.cost(kind: string): number
	local me = ctx and ctx.getMe() or {}
	if me.costs and me.costs[kind] then
		return me.costs[kind]
	end
	local def = defOf(kind)
	if not def then
		return 0
	end
	if type(def.cost) == "function" then
		return def.cost(0)
	end
	return def.cost or 0
end

-- Structure rows: id, kind, tile, owner, done, 4 timing fields, then level (rules_core, [10]).
local function levelOf(s): number
	local l = s[10]
	return if type(l) == "number" and l > 0 then l else 1
end
BuildMenu.levelOf = levelOf

function BuildMenu.levels(kind: string): number
	if not ctx then
		return 0
	end
	local myId = ctx.getMyId()
	local n = 0
	if Config.UNITS[kind] then
		for _, u in ctx.getUnits() do
			if u.owner == myId and (u.kind == nil or u.kind == kind) then
				n += 1
			end
		end
		return n
	end
	for _, s in ctx.getStructures() do
		if s[4] == myId and s[2] == kind then
			n += levelOf(s)
		end
	end
	return n
end

local function isUpgradable(kind: string): boolean
	local def = Config.STRUCTURES[kind]
	if not def then
		return false
	end
	if def.upgradable ~= nil then
		return def.upgradable == true
	end
	return UPGRADABLE[kind] == true
end

function BuildMenu.upgradeTarget(kind: string, tile: number)
	if not ctx or not isUpgradable(kind) then
		return nil
	end
	local map = ctx.getMap()
	local W = map.width
	local myId = ctx.getMyId()
	local x, y = tile % W, tile // W
	local best, bestD = nil, UPGRADE_RANGE * UPGRADE_RANGE
	for _, s in ctx.getStructures() do
		if s[2] == kind and s[4] == myId and s[5] then
			local d = (s[3] % W - x) ^ 2 + (s[3] // W - y) ^ 2
			if d <= bestD then
				best, bestD = s, d
			end
		end
	end
	return best
end

-- Could a new structure go at (or, for coastal kinds, snap near) the tile? Mirrors canPlace.
local function placeable(map, tile: number, kind: string): boolean
	local W, H = map.width, map.height
	local myId = ctx.getMyId()
	local structures = ctx.getStructures()
	local def = Config.STRUCTURES[kind]
	local function ok(t: number): boolean
		if ctx.ownerOf(t) ~= myId or not MapUtil.isOwnable(map, t) then
			return false
		end
		local x, y = t % W, t // W
		for _, s in structures do
			if math.abs(s[3] % W - x) + math.abs(s[3] // W - y) < Config.MIN_STRUCTURE_DISTANCE then
				return false
			end
		end
		if def.coastal then
			local n = MapUtil.neighbors(map, t, NB)
			for i = 1, n do
				if not MapUtil.isLand(map, NB[i]) then
					return true
				end
			end
			return false
		end
		return true
	end
	if ok(tile) then
		return true
	end
	if def.coastal then
		local cx, cy = tile % W, tile // W
		for dy = -6, 6 do
			for dx = -6, 6 do
				local x, y = cx + dx, cy + dy
				if x >= 0 and y >= 0 and x < W and y < H and dx * dx + dy * dy <= 36 and ok(y * W + x) then
					return true
				end
			end
		end
	end
	return false
end

local function alive(): boolean
	local mine = ctx and ctx.roster[ctx.getMyId()]
	return mine ~= nil and mine.stats.alive and ctx.getPhase() == "Play"
end

local function gold(): number
	local mine = ctx.roster[ctx.getMyId()]
	return if mine then mine.stats.gold else 0
end

function BuildMenu.canBuild(kind: string, tile: number?): boolean
	if not alive() or not defOf(kind) or gold() < BuildMenu.cost(kind) or MatchRules.unitDisabled(kind) then
		return false
	end
	local me = ctx.getMe()
	if Config.NUKES[kind] then
		return me.siloReady == true
	elseif Config.UNITS[kind] then
		return me.hasPort == true
	end
	if tile == nil then
		return true
	end
	return placeable(ctx.getMap(), tile, kind)
end

-- disabledUnits for this round (MatchRules): the build bar and menus leave these out.
function BuildMenu.disabled(kind: string): boolean
	return MatchRules.unitDisabled(kind)
end

function BuildMenu.canBuildOrUpgrade(kind: string, tile: number?): boolean
	if MatchRules.unitDisabled(kind) then
		return false
	end
	if tile and alive() and gold() >= BuildMenu.cost(kind) and BuildMenu.upgradeTarget(kind, tile) then
		return true
	end
	return BuildMenu.canBuild(kind, tile)
end

-- Build ghost state for the cursor tile (BuildPreviewController.buildGhostPreviewData):
-- canPlace, canUpgrade, upgradeTile, cost, canAfford.
function BuildMenu.ghostInfo(kind: string, tile: number?): (boolean, boolean, number?, number, boolean)
	if not ctx or not defOf(kind) then
		return false, false, nil, 0, false
	end
	local cost = BuildMenu.cost(kind)
	local afford = gold() >= cost
	if not alive() or tile == nil then
		return false, false, nil, cost, afford
	end
	local up = BuildMenu.upgradeTarget(kind, tile)
	if up then
		return false, true, up[3], cost, afford
	end
	local me = ctx.getMe()
	if Config.NUKES[kind] then
		return me.siloReady == true, false, nil, cost, afford
	elseif Config.UNITS[kind] then
		return me.hasPort == true, false, nil, cost, afford
	end
	return placeable(ctx.getMap(), tile, kind), false, nil, cost, afford
end

-- Alliances already "spent" on the safety (ally id .. ":" .. formed-at), like usedSafetyAllies.
local usedSafety: { [string]: boolean } = {}

local function blockedByAllySafety(tile: number, kind: string): boolean
	local duration = tonumber(Settings.values.nukeAllySafety) or 0
	if duration <= 0 or not (kind == "AtomBomb" or kind == "HydrogenBomb" or kind == "MIRV") then
		return false
	end
	local CM = ctx.contextMenu
	if not CM or not CM.allyExpiry then
		return false
	end
	local now = SimClock.now()
	local fresh = {}
	local any = false
	for id in ctx.roster do
		local exp = CM.allyExpiry(id)
		if exp then
			local created = exp - MatchRules.allianceTicks() * Config.TICK
			local key = id .. ":" .. math.floor(created / 10) -- (expiries jitter slightly between messages)
			if not usedSafety[key] and now - created <= duration * Config.TICK then
				fresh[id] = key
				any = true
			end
		end
	end
	if not any then
		return false
	end
	-- Which alliances the nuke would break (MIRV: the target's owner; bombs: an ally's land at the
	-- target, or NUKE_ALLY_BREAK_TILES of it in the blast).
	local hits = {}
	local o = ctx.ownerOf(tile)
	if fresh[o] then
		hits[o] = Config.NUKE_ALLY_BREAK_TILES
	end
	if kind ~= "MIRV" then
		local map = ctx.getMap()
		local W, H = map.width, map.height
		local r = Config.NUKES[kind].outer
		local cx, cy = tile % W, tile // W
		local R = math.ceil(r)
		for dy = -R, R do
			for dx = -R, R do
				local x, y = cx + dx, cy + dy
				if dx * dx + dy * dy <= r * r and x >= 0 and x < W and y >= 0 and y < H then
					local id = ctx.ownerOf(y * W + x)
					if fresh[id] then
						hits[id] = (hits[id] or 0) + 1
					end
				end
			end
		end
	end
	local blocked = false
	for id, n in hits do
		if n >= Config.NUKE_ALLY_BREAK_TILES then
			usedSafety[fresh[id]] = true
			blocked = true
		end
	end
	if blocked and ctx.toast then
		ctx.toast("Nuke held back: it would hit a new ally. Fire again to launch anyway.", "red", 3)
	end
	return blocked
end

function BuildMenu.fireNuke(tile: number, kind: string)
	if not ctx or blockedByAllySafety(tile, kind) then
		return
	end
	ctx.net:FireServer("nuke", tile, kind, KeybindData.rocketUp == false)
end

function BuildMenu.perform(kind: string, tile: number)
	if not ctx then
		return
	end
	local net = ctx.net
	if alive() and gold() >= BuildMenu.cost(kind) and BuildMenu.upgradeTarget(kind, tile) then
		net:FireServer("upgrade", tile, kind) -- kind: extra arg so the server can pick the type (OpenFront sends it)
	elseif BuildMenu.canBuild(kind, tile) then
		if Config.NUKES[kind] then
			BuildMenu.fireNuke(tile, kind)
		elseif Config.UNITS[kind] then
			net:FireServer("buildUnit", tile, kind)
		else
			net:FireServer("build", tile, kind)
		end
	end
end

--------------------------------------------------------------------------------
-- The grid
--------------------------------------------------------------------------------
local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local BG = Color3.fromHex("#1e1e1e")
local BTN = Color3.fromHex("#2c2c2c")
local BTN_HOVER = Color3.fromHex("#3a3a3a")
local BTN_DISABLED = Color3.fromHex("#1a1a1a")
local BORDER = Color3.fromHex("#444444")
local BORDER_HOVER = Color3.fromHex("#666666")
local BORDER_DISABLED = Color3.fromHex("#333333")
local COST_RED = Color3.fromHex("#ff4444")
local YELLOW = Color3.fromRGB(250, 204, 21)

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

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	return make("TextLabel", props)
end

local ui: any = nil
local openTile: number? = nil

local function build()
	local gui = ctx.gui
	local blocker = make("TextButton", { Name = "BuildMenuBlocker", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Selectable = false, Visible = false, ZIndex = 80, Parent = gui })
	local card = make("Frame", {
		Name = "BuildMenu",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = BG,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 81,
		Parent = gui,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 10), Parent = card })
	make("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.5, Thickness = 2, Parent = card }) -- box-shadow stand-in
	local padding = make("UIPadding", { Parent = card })
	local scroll = make("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		ZIndex = 81,
		Parent = card,
	})
	local grid = make("UIGridLayout", {
		CellSize = UDim2.fromOffset(120, 140),
		CellPadding = UDim2.fromOffset(16, 16),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroll,
	})
	make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = scroll })

	local buttons = {}
	for i, kind in BuildMenu.TABLE do
		if defOf(kind) then
			local b = make("TextButton", { Name = kind, BackgroundColor3 = BTN, AutoButtonColor = false, Text = "", LayoutOrder = i, ZIndex = 82, Parent = scroll })
			make("UICorner", { CornerRadius = UDim.new(0, 12), Parent = b })
			local stroke = make("UIStroke", { Color = BORDER, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
			local scale = make("UIScale", { Parent = b })
			local content = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 82, Parent = b })
			make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = content })
			make("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = content })
			local icon = IconKit.image(IconKit.KIND[kind] or kind, { Size = UDim2.fromOffset(40, 40), LayoutOrder = 1, ZIndex = 83, Parent = content })
			local text = BuildMenu.TEXT[kind] or { kind, "" }
			local name = label({ Size = UDim2.new(1, 0, 0, 16), FontFace = FONT_BOLD, TextSize = 14, TextWrapped = true, Text = text[1], LayoutOrder = 2, ZIndex = 83, Parent = content })
			local desc = label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 10, TextWrapped = true, Text = text[2], LayoutOrder = 3, ZIndex = 83, Parent = content })
			local costRow = make("Frame", { Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = 4, ZIndex = 83, Parent = content })
			make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = costRow })
			local cost = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, TextSize = 14, Text = "", LayoutOrder = 1, ZIndex = 83, Parent = costRow })
			local coin = IconKit.image("Gold", { Size = UDim2.fromOffset(12, 12), ImageColor3 = YELLOW, LayoutOrder = 2, ZIndex = 83, Parent = costRow })
			local chip, chipText, chipStroke = nil, nil, nil
			if not Config.NUKES[kind] then
				-- .build-count-chip: absolute top -10 / right -10 (outside the padding)
				chip = make("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 10, 0, -10), Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = BTN, ZIndex = 84, Parent = b })
				make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = chip })
				chipStroke = make("UIStroke", { Color = BORDER, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = chip })
				make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = chip })
				chipText = label({ Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, Text = "0", ZIndex = 85, Parent = chip })
			end
			local e = { kind = kind, button = b, stroke = stroke, scale = scale, icon = icon, name = name, desc = desc, cost = cost, coin = coin, chip = chip, chipText = chipText, chipStroke = chipStroke, enabled = false, hover = false }
			local function look()
				local bg = if not e.enabled then BTN_DISABLED elseif e.hover then BTN_HOVER else BTN
				b.BackgroundColor3 = bg
				stroke.Color = if not e.enabled then BORDER_DISABLED elseif e.hover then BORDER_HOVER else BORDER
				scale.Scale = if e.enabled and e.hover then 1.05 else 1
				b.BackgroundTransparency = if e.enabled then 0 else 0.3 -- opacity 0.7
				icon.ImageTransparency = if e.enabled then 0 else 0.5
				name.TextTransparency = if e.enabled then 0 else 0.3
				desc.TextTransparency = if e.enabled then 0 else 0.3
				cost.TextColor3 = if e.enabled then WHITE else COST_RED
				if chip then
					chip.BackgroundColor3 = bg
					chipStroke.Color = stroke.Color
				end
			end
			e.look = look
			b.MouseEnter:Connect(function()
				e.hover = true
				look()
			end)
			b.MouseLeave:Connect(function()
				e.hover = false
				look()
			end)
			b.SelectionGained:Connect(function()
				e.hover = true
				look()
			end)
			b.SelectionLost:Connect(function()
				e.hover = false
				look()
			end)
			b.Activated:Connect(function()
				if e.enabled and openTile then
					BuildMenu.perform(kind, openTile)
					BuildMenu.hide()
				end
			end)
			buttons[#buttons + 1] = e
		end
	end
	ui = { blocker = blocker, card = card, padding = padding, scroll = scroll, grid = grid, buttons = buttons }
	blocker.Activated:Connect(function()
		BuildMenu.hide()
	end)
end

local function layout()
	local X, Y = ctx.gui.AbsoluteSize.X, ctx.gui.AbsoluteSize.Y
	local cellW, cellH, gap, pad = 120, 140, 16, 15
	if X <= 480 then
		pad, gap = 8, 6
		cellW, cellH = math.floor((X * 0.8 - 2 * pad - gap) / 2), 100
	elseif X <= 768 then
		cellW, cellH, gap, pad = 140, 120, 8, 10
	end
	-- BuildMenu.filteredBuildTable: disabled units (Nukes / SAMs Disabled) are left out.
	local n = 0
	for _, e in ui.buttons do
		e.button.Visible = not MatchRules.unitDisabled(e.kind)
		if e.button.Visible then
			n += 1
		end
	end
	n = math.max(1, n)
	local maxW = (if X <= 768 then X * 0.8 else X * 0.95) - 2 * pad
	local cols = math.clamp(math.floor((maxW + gap) / (cellW + gap)), 1, n)
	local rows = math.ceil(n / cols)
	local w = cols * (cellW + gap) - gap + 2 * pad + 12
	local contentH = rows * (cellH + gap) - gap + 20 + 2 * pad
	local maxH = Y * (if X <= 480 then 0.7 elseif X <= 768 then 0.8 else 0.95)
	ui.grid.CellSize = UDim2.fromOffset(cellW, cellH)
	ui.grid.CellPadding = UDim2.fromOffset(gap, gap)
	ui.padding.PaddingLeft, ui.padding.PaddingRight = UDim.new(0, pad), UDim.new(0, pad)
	ui.padding.PaddingTop, ui.padding.PaddingBottom = UDim.new(0, pad), UDim.new(0, pad)
	ui.card.Size = UDim2.fromOffset(w, math.min(contentH, maxH))
	local small = X <= 768
	for _, e in ui.buttons do
		e.icon.Size = if X <= 480 then UDim2.fromOffset(24, 24) else UDim2.fromOffset(40, 40)
		e.name.TextSize = if X <= 480 then 10 elseif small then 12 else 14
		e.desc.TextSize = if X <= 480 then 8 else 10
		e.cost.TextSize = if X <= 480 then 9 elseif small then 11 else 14
		if e.chipText then
			e.chipText.TextSize = if X <= 480 then 8 elseif small then 10 else 14
		end
	end
end

local function refresh()
	if not openTile then
		return
	end
	for _, e in ui.buttons do
		e.enabled = BuildMenu.canBuildOrUpgrade(e.kind, openTile)
		e.cost.Text = ctx.fmt(BuildMenu.cost(e.kind))
		if e.chipText then
			e.chipText.Text = tostring(BuildMenu.levels(e.kind))
		end
		e.look()
	end
end

function BuildMenu.isOpen(): boolean
	return openTile ~= nil
end

function BuildMenu.hide()
	if not ui or openTile == nil then
		return
	end
	openTile = nil
	ui.card.Visible = false
	ui.blocker.Visible = false
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(ui.card) then
		GuiService.SelectedObject = nil
	end
end

function BuildMenu.show(tile: number)
	if not ui or not alive() then
		return
	end
	if openTile ~= nil then
		return -- OpenFront ignores the event while the menu is already open
	end
	openTile = tile
	layout()
	refresh()
	ui.blocker.Visible = true
	ui.card.Visible = true
	if UserInputService:GetLastInputType().Name:sub(1, 7) == "Gamepad" then
		for _, e in ui.buttons do
			if e.enabled then
				GuiService.SelectedObject = e.button
				break
			end
		end
		if GuiService.SelectedObject == nil and ui.buttons[1] then
			GuiService.SelectedObject = ui.buttons[1].button
		end
	end
end

function BuildMenu.setup(c)
	ctx = c
	build()
	UserInputService.InputBegan:Connect(function(input)
		if openTile and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
			BuildMenu.hide()
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 or not openTile then
			return
		end
		acc = 0
		if not alive() then
			BuildMenu.hide()
			return
		end
		refresh()
	end)
	ctx.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if openTile then
			layout()
		end
	end)
end

return BuildMenu
