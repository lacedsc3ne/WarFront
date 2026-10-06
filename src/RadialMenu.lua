--[[
	War Front - radial context menu (OpenFront's MainRadialMenu / RadialMenu).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.RadialMenu (ModuleScript), used by GameClient (via Interact).
-- Right-click (mouse), long-press (touch) or X (gamepad) on the map opens a ring of four actions
-- around the pointer, like OpenFront (src/client/hud/layers/RadialMenuElements.ts):
--   centre   attack the territory (or send troops to an ally)
--   top      info (player panel)
--   others   own land: delete structure / alliance (disabled) / build sub-menu
--            other land: boat (or break alliance) / alliance request (or renew) / attack sub-menu
--            (nukes + warship; send gold instead for allies)
-- Sub-menus open as a bigger outer ring; the centre turns into a back button.
-- The ring is drawn into an EditableImage (annular sectors with OpenFront's gaps and colours);
-- without EditableImage each sector falls back to a coloured disc.
-- RadialMenu.setup(ctx)
--   ctx.gui, ctx.net, ctx.roster, ctx.getMap(), ctx.getMyId(), ctx.getRatio(), ctx.getMe(),
--   ctx.getPhase(), ctx.ownerOf(tile), ctx.fmt(n), ctx.getStructures(), ctx.act(tile),
--   ctx.contextMenu (ContextMenu: diplomacy state), ctx.playerPanel (PlayerPanel)
-- RadialMenu.open(sx, sy, tile, startIn?)   startIn = "build" | "attack" opens straight in that
--                                          sub-menu (Ctrl+click, like OpenFront's build menu)
-- RadialMenu.close(), RadialMenu.isOpen()

local AssetService = game:GetService("AssetService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local RadialMenu = {}

-- Look (OpenFront RadialMenu defaults and RadialMenuElements COLORS)
local TAU = math.pi * 2
local CENTER_R = 30
local ICON = 32
local CENTER_ICON = 48
local PAD_ANGLE = 0.03
local TRANSITION = 0.3
local REOPEN_COOLDOWN = 0.3
local RADII = { [0] = { 40, 95 }, [1] = { 75, 140 } } -- inner, outer per level

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

local COLORS = {
	build = hex("#e6c74a"),
	building = hex("#1e3a5f"),
	boat = hex("#2a82c9"),
	disabled = hex("#94a3b8"),
	ally = hex("#4ade80"),
	breakAlly = hex("#dc2626"),
	breakAllyNoDebuff = hex("#d97706"),
	delete = hex("#ef4444"),
	info = hex("#475569"),
	attack = hex("#ef4444"),
	donateGold = hex("#f59e0b"),
	tooltipCost = hex("#f59e0b"),
	tooltipCount = hex("#94a3b8"),
}
local DISABLED_FILL = Color3.fromRGB(128, 128, 128)
local CENTER_DEFAULT = hex("#0f2744")
local CENTER_FRIENDLY = hex("#22d3ee")
local CENTER_DISABLED = hex("#999999")
local TOOLTIP_BG = Color3.fromRGB(12, 35, 64)
local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)

-- OpenFront names / descriptions (resources/lang/en.json: unit_type.*, build_menu.desc.*).
local UNIT_TEXT = {
	City = { "City", "Increases max population" },
	Port = { "Port", "Sends trade ships to generate gold" },
	DefensePost = { "Defense Post", "Increases defenses of nearby borders" },
	MissileSilo = { "Missile Silo", "Used to launch nukes" },
	SAM = { "SAM Launcher", "Defends against incoming nukes" },
	AtomBomb = { "Atom Bomb", "Small explosion" },
	HydrogenBomb = { "Hydrogen Bomb", "Large explosion" },
	Warship = { "Warship", "Captures trade ships, destroys ships and boats" },
	Factory = { "Factory", "Creates railroads and spawns trains" },
	MIRV = { "MIRV", "Huge explosion, only targets selected player" },
}
RadialMenu.UNIT_TEXT = UNIT_TEXT
-- OpenFront's build table order (kinds missing from Config, e.g. Factory / MIRV before the rules
-- lanes add them, are skipped by unitItems).
local BUILD_ORDER = { "Port", "MissileSilo", "SAM", "DefensePost", "City", "Factory" }
local ATTACK_ORDER = { "AtomBomb", "MIRV", "HydrogenBomb", "Warship" }

-- State
local ctx: any = nil
local P: any = nil -- params for the tile the menu was opened on
local isOpen = false
local level = 0
local menuStack: { any } = {} -- item lists of the levels below the current one
local currentItems: { any } = {}
local selectedId: string? = nil -- level-0 item whose sub-menu is open
local hover: any = nil -- { level, index } | "center"
local anchor = Vector2.zero
local lastHide = 0
local centerState = "default" -- "default" | "back"

local gui: ScreenGui
local blocker: TextButton
local root: Frame
local centerButton: TextButton
local centerScale: UIScale
local centerIcon: ImageLabel
local tooltip: Frame
local tooltipList: Frame
local noSelection: Frame
local levels: { [number]: any } = {}

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
	return SimClock.now()
end

local function usingMouse(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseWheel or t == Enum.UserInputType.Keyboard
end

local function usingGamepad(): boolean
	return string.find(UserInputService:GetLastInputType().Name, "Gamepad") ~= nil
end

-- Game checks (what OpenFront's PlayerActions answer on the worker)
local NB = table.create(4)

-- Coast of `ownerId` within 20 tiles of `tile` (mirrors the server's boat landing search).
local function coastNear(map, tile: number, ownerId: number): boolean
	local W, H = map.width, map.height
	local cx, cy = tile % W, tile // W
	for dy = -20, 20 do
		local y = cy + dy
		if y >= 0 and y < H then
			for dx = -20, 20 do
				local x = cx + dx
				if x >= 0 and x < W then
					local t = y * W + x
					if ctx.ownerOf(t) == ownerId and MapUtil.isOwnable(map, t) then
						local n = MapUtil.neighbors(map, t, NB)
						for i = 1, n do
							if not MapUtil.isLand(map, NB[i]) then
								return true
							end
						end
					end
				end
			end
		end
	end
	return false
end

local function costOf(kind: string): number
	local me = ctx.getMe()
	if ctx.buildMenu then
		return ctx.buildMenu.cost(kind)
	end
	if Config.NUKES[kind] then
		return Config.NUKES[kind].cost
	end
	local def = Config.STRUCTURES[kind] or Config.UNITS[kind]
	return (me.costs and me.costs[kind]) or (def and def.cost(0)) or 0
end

local function ownedCount(kind: string): number
	local myId = ctx.getMyId()
	local n = 0
	if kind == "Warship" then
		for _, u in ctx.getUnits() do
			if u.owner == myId then
				n += 1
			end
		end
		return n
	end
	for _, s in ctx.getStructures() do
		if s[4] == myId and s[2] == kind then
			n += 1
		end
	end
	return n
end

-- Could a structure go at (or, for ports, snap near) the tile? Mirrors the server's canPlace.
local function placeable(map, tile: number, kind: string): boolean
	local W, H = map.width, map.height
	local myId = ctx.getMyId()
	local structures = ctx.getStructures()
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
		if Config.STRUCTURES[kind].coastal then
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
	if Config.STRUCTURES[kind].coastal then
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

local function canBuild(kind: string): boolean
	local mine = P.mine
	if not mine or not mine.stats.alive then
		return false
	end
	local gold = mine.stats.gold
	local me = ctx.getMe()
	if gold < costOf(kind) then
		return false
	end
	if Config.NUKES[kind] then
		return me.siloReady == true
	elseif kind == "Warship" then
		return me.hasPort == true
	end
	return P.isOwn and placeable(P.map, P.tile, kind)
end

-- OpenFront canBuildOrUpgrade: an own finished structure of that kind near the tile can be
-- upgraded instead (BuildMenu.upgradeTarget; "upgrade" (tile) in the shared contract).
local function canUpgrade(kind: string): boolean
	local mine = P.mine
	if not ctx.buildMenu or not mine or not mine.stats.alive or P.spawn then
		return false
	end
	return mine.stats.gold >= costOf(kind) and ctx.buildMenu.upgradeTarget(kind, P.tile) ~= nil
end

local function canBuildOrUpgrade(kind: string): boolean
	return canUpgrade(kind) or canBuild(kind)
end

-- Builds the params for `tile` (refreshed every half second while the menu is open).
local function buildParams(tile: number)
	local map = ctx.getMap()
	local myId = ctx.getMyId()
	local roster = ctx.roster
	local ownerId = ctx.ownerOf(tile)
	local target = if ownerId ~= 0 then roster[ownerId] else nil
	local CM = ctx.contextMenu
	local mine = roster[myId]
	local p = {
		tile = tile,
		map = map,
		myId = myId,
		mine = mine,
		alive = mine ~= nil and mine.stats.alive,
		ownerId = ownerId,
		target = target,
		isLand = MapUtil.isLand(map, tile),
		ownable = MapUtil.isOwnable(map, tile),
		isOwn = ownerId ~= 0 and ownerId == myId,
		allied = target ~= nil and CM.isAlly(ownerId),
		incoming = target ~= nil and CM.hasIncoming(ownerId),
		outgoing = target ~= nil and CM.hasOutgoing(ownerId),
		spawn = ctx.getPhase() ~= "Play",
	}
	local expiry = if p.allied then CM.allyExpiry(ownerId) else nil
	p.allyLeft = if expiry then expiry - serverNow() else nil
	p.inExtensionWindow = p.allyLeft ~= nil and p.allyLeft <= Config.ALLIANCE_RENEW_TICKS * Config.TICK
	p.teammate = target ~= nil and CM.isTeammate(ownerId)
	-- canDonate*: friendly, and humans only receive donations in team games.
	p.canDonate = p.allied and target ~= nil and (target.kind ~= "Human" or CM.teamGame())
	p.canRequest = target ~= nil and p.alive and not p.isOwn and not p.allied and not p.outgoing and target.kind ~= "Bot" and target.stats.alive
		and not MatchRules.alliancesOff() -- disableAlliances: PlayerImpl.canSendAllianceRequest
	p.canAttack = p.alive and p.isLand and not p.isOwn and not p.allied and ((ownerId == 0 and p.ownable) or (target ~= nil and target.stats.alive))
	return p
end

-- Menu elements (RadialMenuElements.ts)
local function fire(kind: string, a1: number, a2: any)
	ctx.net:FireServer(kind, a1, a2)
end

local function tooltipFor(kind: string, countable: boolean)
	local text = UNIT_TEXT[kind] or { kind, "" }
	local items = {
		{ text = text[1], class = "title" },
		{ text = text[2], class = "description" },
		{ text = ctx.fmt(costOf(kind)) .. " Gold", class = "cost" },
	}
	if countable then
		local n = if ctx.buildMenu then ctx.buildMenu.levels(kind) else ownedCount(kind) -- totalUnitLevels
		items[#items + 1] = { text = n .. "x", class = "count" }
	end
	return items
end

-- Bulk upgrade totals (Game.ts bulkCost / maxBulkAmount): each further level costs the next
-- step of the structure's cost ladder, starting from the current price.
local STRUCTURE_BULK_STEPS = { 5, 10 }

local function bulkCost(kind: string, amount: number): number
	local def = Config.STRUCTURES[kind]
	local now = costOf(kind)
	if not def or type(def.cost) ~= "function" then
		return now * amount
	end
	local n0 = 0
	for n = 0, 60 do
		if def.cost(n) >= now then
			n0 = n
			break
		end
	end
	local total = 0
	for i = 0, amount - 1 do
		total += def.cost(n0 + i)
	end
	return total
end

local function maxBulkAmount(kind: string): number
	local mine = P.mine
	local gold = if mine then mine.stats.gold else 0
	local max = 0
	for n = 1, Config.MAX_UPGRADE_AMOUNT or 50 do
		if bulkCost(kind, n) > gold then
			break
		end
		max = n
	end
	return max
end

local function upgradeSubMenu(kind: string)
	if not canUpgrade(kind) then
		return nil
	end
	local maxAmount = maxBulkAmount(kind)
	if maxAmount <= 1 then
		return nil
	end
	local slots = { 1, STRUCTURE_BULK_STEPS[1], STRUCTURE_BULK_STEPS[2], maxAmount }
	local out = {}
	for i, amount in slots do
		local executable = amount <= maxAmount
		local cost = bulkCost(kind, amount)
		out[#out + 1] = {
			id = if i == #slots then "upgrade_" .. kind .. "_max" else "upgrade_" .. kind .. "_" .. amount,
			text = "x" .. amount,
			fontSize = 20,
			color = function()
				return if executable then COLORS.building else COLORS.disabled
			end,
			disabled = function()
				return not executable
			end,
			tooltip = function()
				return {
					{ text = "Upgrade x" .. amount, class = "title" },
					{ text = ctx.fmt(cost) .. " Gold", class = "cost" },
				}
			end,
			action = function()
				ctx.net:FireServer("upgrade", P.tile, kind, amount)
			end,
		}
	end
	return out
end

local function unitItems(kinds: { string }, attack: boolean)
	local list = {}
	for _, kind in kinds do
		local def = Config.STRUCTURES[kind] or Config.NUKES[kind] or Config.UNITS[kind]
		if def and not MatchRules.unitDisabled(kind) then -- (RadialMenuElements: disabled units left out)
			list[#list + 1] = {
				id = (if attack then "attack_" else "build_") .. kind,
				icon = IconKit.KIND[kind] or kind,
				color = function()
					return if canBuildOrUpgrade(kind) then (if attack then COLORS.attack else COLORS.building) else COLORS.building
				end,
				disabled = function()
					return not canBuildOrUpgrade(kind)
				end,
				tooltip = function()
					return tooltipFor(kind, not Config.NUKES[kind])
				end,
				subMenu = if Config.STRUCTURES[kind] then function()
					return upgradeSubMenu(kind)
				end else nil,
				action = function()
					if canUpgrade(kind) then
						fire("upgrade", P.tile, kind)
						return
					end
					if not canBuild(kind) then
						return
					end
					if Config.NUKES[kind] then
						fire("nuke", P.tile, kind)
					elseif Config.UNITS[kind] then
						fire("buildUnit", P.tile, kind)
					else
						fire("build", P.tile, kind)
					end
				end,
			}
		end
	end
	return list
end

local infoItem = {
	id = "info",
	icon = "Info",
	color = COLORS.info,
	disabled = function()
		return P.target == nil or P.spawn
	end,
	action = function()
		if ctx.playerPanel then
			ctx.playerPanel.show(P.ownerId)
		end
	end,
}

local function nearbyStructure(): boolean
	local W = P.map.width
	local x, y = P.tile % W, P.tile // W
	for _, s in ctx.getStructures() do
		if s[4] == P.myId and s[5] and math.abs(s[3] % W - x) + math.abs(s[3] // W - y) <= 5 then
			return true
		end
	end
	return false
end

local deleteItem = {
	id = "delete",
	icon = "Close",
	color = COLORS.delete,
	cooldown = function()
		return ctx.getMe().deleteCooldown or 0
	end,
	disabled = function()
		return not P.isOwn or not P.isLand or P.spawn or (ctx.getMe().deleteCooldown or 0) > 0 or not nearbyStructure()
	end,
	tooltip = function()
		return { { text = "Delete Unit", class = "title" }, { text = "Click to delete the nearest unit", class = "description" } }
	end,
	action = function()
		fire("deleteStructure", P.tile)
	end,
}

local allyRequestItem = {
	id = "ally_request",
	icon = "Alliance",
	color = COLORS.ally,
	disabled = function()
		return not P.canRequest
	end,
	action = function()
		-- They already asked us: answering with a request is accepting (OpenFront does the same).
		fire(if P.incoming then "allyAccept" else "allyRequest", P.ownerId)
	end,
}

local allyExtendItem = {
	id = "ally_extend",
	icon = "Alliance",
	color = COLORS.ally,
	renderType = "allyExtend",
	disabled = function()
		return not P.allied or P.outgoing
	end,
	timerFraction = function(): number
		if not P.allyLeft then
			return 1
		end
		return math.clamp(P.allyLeft / (Config.ALLIANCE_RENEW_TICKS * Config.TICK), 0, 1)
	end,
	action = function()
		fire(if P.incoming then "allyAccept" else "allyRequest", P.ownerId)
	end,
}

local allyBreakItem = {
	id = "ally_break",
	icon = "Traitor",
	color = function()
		return if ctx.contextMenu.isTraitor(P.ownerId) then COLORS.breakAllyNoDebuff else COLORS.breakAlly
	end,
	disabled = function()
		return not P.allied or P.teammate -- canBreakAlliance: real alliances only
	end,
	action = function()
		fire("allyBreak", P.ownerId)
	end,
}

local boatItem = {
	id = "boat",
	icon = "Boat",
	color = COLORS.boat,
	disabled = function()
		local me = ctx.getMe()
		return not P.alive or P.spawn or not P.isLand or P.isOwn or P.allied or (me.boats or 0) >= Config.MAX_BOATS
			or not ((P.ownerId == 0 and P.ownable) or P.target ~= nil)
			or not coastNear(P.map, P.tile, P.ownerId)
	end,
	action = function()
		fire("boat", P.tile, ctx.getRatio())
	end,
}

local donateGoldItem = {
	id = "attack",
	icon = "DonateGold",
	color = COLORS.donateGold,
	disabled = function()
		return P.spawn or not P.canDonate or not P.alive or P.mine.stats.gold < 1
	end,
	action = function()
		if ctx.playerPanel then
			ctx.playerPanel.openSendModal(P.ownerId, "gold")
		end
	end,
}

local attackItem = {
	id = "attack",
	icon = "Sword",
	color = COLORS.attack,
	disabled = function()
		return P.spawn
	end,
	subMenu = function()
		return unitItems(ATTACK_ORDER, true)
	end,
}

local buildItem = {
	id = "build",
	icon = "Build",
	color = COLORS.build,
	disabled = function()
		return P.spawn
	end,
	subMenu = function()
		return unitItems(BUILD_ORDER, false)
	end,
}

local function rootItems()
	if P.isOwn then
		return { infoItem, deleteItem, allyRequestItem, buildItem }
	end
	return {
		infoItem,
		if P.allied then allyBreakItem else boatItem,
		if P.inExtensionWindow then allyExtendItem else allyRequestItem,
		if P.allied then donateGoldItem else attackItem,
	}
end

-- Centre button: attack, or send troops (attack ratio) to an ally.
local function friendlyTarget(): boolean
	return P.allied
end

local function centerDisabled(): boolean
	if not P.isLand or P.spawn then
		return true
	end
	if friendlyTarget() then
		return not P.alive or P.mine.stats.troops * ctx.getRatio() < 1
	end
	return not P.canAttack
end

local function centerAction()
	if friendlyTarget() then
		fire("donateTroops", P.ownerId, ctx.getRatio())
	else
		ctx.act(P.tile) -- the shared primary action (tutorial counters, warships, attack)
	end
end

-- Ring geometry (d3.pie / d3.arc with padAngle 0.03) and drawing
local geomCache: { [number]: any } = {}

local function geometry(lvl: number, n: number)
	local key = lvl * 64 + n
	local g = geomCache[key]
	if g then
		return g
	end
	local inner, outer = RADII[lvl][1], RADII[lvl][2]
	local S = math.ceil(outer * 2 + 4)
	local c = S / 2
	local padW = PAD_ANGLE * math.sqrt(inner * inner + outer * outer)
	local step = TAU / n
	local offset = -math.pi / n
	local idx = buffer.create(S * S)
	local cov = buffer.create(S * S)
	buffer.fill(idx, 0, 255)
	local minY, maxY = table.create(n, math.huge), table.create(n, -math.huge)
	local rin2, rout2 = (inner - 1) ^ 2, (outer + 1) ^ 2
	local halfPad = padW / 2
	for py = 0, S - 1 do
		local dy = py + 0.5 - c
		for px = 0, S - 1 do
			local dx = px + 0.5 - c
			local r2 = dx * dx + dy * dy
			if r2 >= rin2 and r2 <= rout2 then
				local r = math.sqrt(r2)
				local radial = math.min(r - inner, outer - r) + 0.5
				if radial > 0 then
					local rel = (math.atan2(dx, -dy) - offset) % TAU
					local i = math.min(n - 1, math.floor(rel / step))
					local within = rel - i * step
					local ang = math.min(within, step - within, math.pi / 2)
					local a = math.min(radial, 1) * math.clamp(r * math.sin(ang) - halfPad + 0.5, 0, 1)
					if a > 0 then
						local o = py * S + px
						buffer.writeu8(idx, o, i)
						buffer.writeu8(cov, o, math.floor(a * 255 + 0.5))
						if py < minY[i + 1] then
							minY[i + 1] = py
						end
						if py > maxY[i + 1] then
							maxY[i + 1] = py
						end
					end
				end
			end
		end
	end
	local centroids = {}
	local rm = (inner + outer) / 2
	for i = 0, n - 1 do
		local th = offset + (i + 0.5) * step
		centroids[i + 1] = Vector2.new(rm * math.sin(th), -rm * math.cos(th))
	end
	g = { S = S, n = n, idx = idx, cov = cov, minY = minY, maxY = maxY, centroids = centroids, step = step, offset = offset, inner = inner, outer = outer }
	geomCache[key] = g
	return g
end

local function isDisabled(item): boolean
	return P == nil or P.spawn or item.disabled()
end

local function colorOf(item): Color3
	local c = item.color
	if type(c) == "function" then
		return c()
	end
	return c or COLORS.building
end

-- RGBA (0-255 each, alpha 0-1) for sector `i` of a level.
local function fillOf(lvl: number, item, i: number)
	local disabled = isDisabled(item)
	local col = if disabled then DISABLED_FILL else colorOf(item)
	local alpha = if disabled then 0.4 * 0.5 else 0.82
	if lvl == 0 and level > 0 and item.id == selectedId then
		alpha = 1 -- the item whose sub-menu is open keeps its full colour
	end
	local r, g, b = col.R * 255, col.G * 255, col.B * 255
	local hovered = type(hover) == "table" and hover.level == lvl and hover.index == i and level == lvl and not disabled
	if hovered then
		r, g, b = math.min(255, r * 1.5), math.min(255, g * 1.5), math.min(255, b * 1.5)
	end
	local fill = { r, g, b, alpha }
	if item.timerFraction and not disabled then
		-- Alliance renewal: the elapsed part of the window fades towards white (top down).
		fill.cut = 1 - item.timerFraction()
		fill[5], fill[6], fill[7] = r + (255 - r) * 0.4, g + (255 - g) * 0.4, b + (255 - b) * 0.4
	end
	return fill
end

local editableOk = true

local function ensureEditable(L, S: number): boolean
	if not editableOk then
		return false
	end
	if L.editable and L.size == S then
		return true
	end
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(S, S) })
	end)
	if not ok or not img then
		editableOk = false
		warn("[War Front] Radial menu falls back to discs (EditableImage unavailable): " .. tostring(img))
		return false
	end
	if L.editable then
		L.editable:Destroy()
	end
	L.editable, L.size = img, S
	L.pixels = buffer.create(S * S * 4)
	L.image.ImageContent = Content.fromObject(img)
	return true
end

local function paintLevel(lvl: number)
	local L = levels[lvl]
	local items = L.items
	local n = #items
	if n == 0 then
		return
	end
	local g = geometry(lvl, n)
	local fills = table.create(n)
	for i, item in items do
		fills[i] = fillOf(lvl, item, i)
	end
	if ensureEditable(L, g.S) then
		L.image.Visible = true
		local S = g.S
		local px = L.pixels
		local idx, cov = g.idx, g.cov
		for o = 0, S * S - 1 do
			local i = buffer.readu8(idx, o)
			if i == 255 then
				buffer.writeu32(px, o * 4, 0)
			else
				local f = fills[i + 1]
				local r, gg, b = f[1], f[2], f[3]
				if f.cut then
					local y = o // S
					local top, bottom = g.minY[i + 1], g.maxY[i + 1]
					if (y - top) / math.max(1, bottom - top + 1) < f.cut then
						r, gg, b = f[5], f[6], f[7]
					end
				end
				local a = math.floor(f[4] * buffer.readu8(cov, o) + 0.5)
				buffer.writeu32(px, o * 4, math.floor(r + 0.5) + math.floor(gg + 0.5) * 256 + math.floor(b + 0.5) * 65536 + a * 16777216)
			end
		end
		L.editable:WritePixelsBuffer(Vector2.zero, Vector2.new(S, S), px)
	else
		L.image.Visible = false
		for i, e in L.entries do
			local f = fills[i]
			e.disc.Visible = true
			e.disc.BackgroundColor3 = Color3.fromRGB(math.floor(f[1]), math.floor(f[2]), math.floor(f[3]))
			e.disc.BackgroundTransparency = 1 - f[4]
		end
	end
	-- Icons / text follow the disabled state.
	for i, item in items do
		local e = L.entries[i]
		local disabled = isDisabled(item)
		local t = if disabled then 0.5 else 0
		if e.icon then
			e.icon.ImageTransparency = t
		end
		if e.icon2 then
			e.icon2.ImageTransparency = t
		end
		if e.text then
			e.text.TextTransparency = t
		end
		e.button.Selectable = not disabled and lvl == level
		if e.cooldown then
			local cd = if item.cooldown then math.ceil(item.cooldown()) else 0
			e.cooldown.Visible = cd > 0
			e.cooldown.Text = cd .. "s"
		end
	end
end

-- Building the level frames
local function clearLevel(lvl: number)
	local L = levels[lvl]
	for _, e in L.entries do
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(e.holder) then
			GuiService.SelectedObject = nil
		end
		e.holder:Destroy()
	end
	table.clear(L.entries)
	L.items = {}
	L.frame.Visible = false
end

local onItemClick: (lvl: number, i: number) -> ()
local showTooltip: (items: { any }?, at: Vector2?) -> ()
local setHover: (h: any) -> ()

local function buildLevel(lvl: number, items: { any })
	clearLevel(lvl)
	local L = levels[lvl]
	L.items = items
	local n = #items
	if n == 0 then
		return
	end
	local g = geometry(lvl, n)
	L.frame.Size = UDim2.fromOffset(g.S, g.S)
	L.frame.Visible = true
	for i, item in items do
		local c = g.centroids[i]
		local holder = make("Frame", {
			Name = "Item_" .. item.id,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, c.X, 0.5, c.Y),
			Size = UDim2.fromOffset(46, 46),
			BackgroundTransparency = 1,
			ZIndex = 44,
			Parent = L.frame,
		})
		local disc = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset((g.outer - g.inner) * 0.95, (g.outer - g.inner) * 0.95),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 43,
			Parent = holder,
		})
		make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = disc })
		local e = { holder = holder, disc = disc }
		if item.renderType == "allyExtend" then
			-- Two handshakes: left = us, right = them; each blinks until that side has agreed.
			local w = ICON * 0.8
			e.icon = IconKit.image(item.icon, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0.5, -1, 0.5, 0), Size = UDim2.fromOffset(w, w), ZIndex = 45, Parent = holder })
			e.icon2 = IconKit.image(item.icon, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0.5, 1, 0.5, 0), Size = UDim2.fromOffset(w, w), ZIndex = 45, Parent = holder })
		elseif item.text then
			e.text = make("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(44, 44),
				BackgroundTransparency = 1,
				FontFace = FONT,
				TextSize = item.fontSize or 12,
				TextColor3 = Color3.new(1, 1, 1),
				Text = item.text,
				ZIndex = 45,
				Parent = holder,
			})
		else
			e.icon = IconKit.image(item.icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(ICON, ICON), ZIndex = 45, Parent = holder })
			if item.cooldown then
				e.cooldown = make("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.new(0.5, 0, 0.5, ICON / 2 + 1),
					Size = UDim2.fromOffset(40, 14),
					BackgroundTransparency = 1,
					FontFace = FONT_BOLD,
					TextSize = 14,
					TextColor3 = Color3.new(1, 1, 1),
					Text = "",
					Visible = false,
					ZIndex = 45,
					Parent = holder,
				})
			end
		end
		-- Invisible button on the sector: controller selection and taps.
		local button = make("TextButton", {
			Name = "Hit",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			SelectionImageObject = noSelection,
			ZIndex = 46,
			Parent = holder,
		})
		button.Activated:Connect(function()
			onItemClick(lvl, i)
		end)
		button.SelectionGained:Connect(function()
			setHover({ level = lvl, index = i })
			local abs = holder.AbsolutePosition + holder.AbsoluteSize
			showTooltip(if item.tooltip then item.tooltip() else nil, abs)
		end)
		button.SelectionLost:Connect(function()
			if type(hover) == "table" and hover.level == lvl and hover.index == i then
				setHover(nil)
				showTooltip(nil)
			end
		end)
		e.button = button
		L.entries[i] = e
	end
	paintLevel(lvl)
end

-- Centre button, tooltip, hover
local function centerEnabled(): boolean
	if level > 0 then
		return true -- back button
	end
	return P ~= nil and not centerDisabled()
end

local function refreshCenter()
	local back = centerState == "back"
	local friendly = P ~= nil and friendlyTarget()
	local enabled = centerEnabled()
	local radius = if back then CENTER_R * 0.8 else CENTER_R
	centerButton.Size = UDim2.fromOffset(radius * 2, radius * 2)
	local iconSize = if back then CENTER_ICON * 0.8 elseif friendly then CENTER_ICON * 0.75 else CENTER_ICON
	IconKit.set(centerIcon, if back then "Back" elseif friendly then "DonateTroops" else "Sword")
	centerIcon.Size = UDim2.fromOffset(iconSize, iconSize)
	local color = if back then CENTER_DEFAULT elseif friendly then CENTER_FRIENDLY else CENTER_DEFAULT
	centerButton.BackgroundColor3 = if enabled then color else CENTER_DISABLED
	centerIcon.ImageTransparency = if enabled then 0 else 0.5
	centerButton.Selectable = enabled
end

local tooltipKey = ""

-- `at` is an absolute screen point; the tooltip sits 10 px right / below it.
function showTooltip(items: { any }?, at: Vector2?)
	if not items or #items == 0 then
		tooltip.Visible = false
		return
	end
	if at then
		local rel = at - gui.AbsolutePosition
		tooltip.Position = UDim2.fromOffset(rel.X + 10, rel.Y + 10)
	end
	local parts = table.create(#items)
	for i, it in items do
		parts[i] = it.text
	end
	local key = table.concat(parts, "\n")
	if key == tooltipKey and tooltip.Visible then
		return
	end
	tooltipKey = key
	for _, c in tooltipList:GetChildren() do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	for i, it in items do
		local cls = it.class
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = if cls == "title" then FONT_BOLD else FONT,
			TextSize = if cls == "title" then 14 else 12,
			TextColor3 = if cls == "cost" then COLORS.tooltipCost elseif cls == "count" then COLORS.tooltipCount else Color3.new(1, 1, 1),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = it.text,
			LayoutOrder = i,
			ZIndex = 51,
			Parent = tooltipList,
		})
	end
	tooltip.Visible = true
end

function setHover(h: any)
	local old = hover
	local same = (old == h) or (type(old) == "table" and type(h) == "table" and old.level == h.level and old.index == h.index)
	if same then
		return
	end
	hover = h
	local scale = if h == "center" and centerEnabled() then 1.2 else 1
	if level == 0 and h == nil then
		scale = 1
	end
	TweenService:Create(centerScale, TweenInfo.new(0.2), { Scale = scale }):Play()
	if type(old) == "table" and levels[old.level] and #levels[old.level].items > 0 then
		paintLevel(old.level)
	end
	if type(h) == "table" and (type(old) ~= "table" or old.level ~= h.level) then
		paintLevel(h.level)
	end
end

-- Pointer -> "center" | { level, index } | nil (only the current level takes clicks).
local function hitTest(pos: Vector2): any
	local d = pos - anchor
	local r = d.Magnitude
	local centerR = (if centerState == "back" then CENTER_R * 0.8 else CENTER_R) * centerScale.Scale
	if r <= centerR then
		return "center"
	end
	local L = levels[level]
	local n = #L.items
	if n == 0 then
		return nil
	end
	local g = geometry(level, n)
	if r < g.inner or r > g.outer then
		return nil
	end
	local rel = (math.atan2(d.X, -d.Y) - g.offset) % TAU
	return { level = level, index = math.min(n - 1, math.floor(rel / g.step)) + 1 }
end

-- GetMouseLocation() includes the top bar inset; on our IgnoreGuiInset GUI the cursor sits at
-- GetMouseLocation() - GetGuiInset() (the same space as InputObject.Position).
local function mouseGui(): Vector2
	return UserInputService:GetMouseLocation() - game:GetService("GuiService"):GetGuiInset()
end

local function pointerPos(input: InputObject?): Vector2
	if input and input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	return mouseGui()
end

-- Navigation (RadialMenu.ts)
local function tweenScale(L, target: number, transparency: number)
	local info = TweenInfo.new(if Settings.values.reducedMotion then 0 else TRANSITION * 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(L.scale, info, { Scale = target }):Play()
	TweenService:Create(L.image, info, { ImageTransparency = transparency }):Play()
end

-- Keeps the ring of the current level on screen (clampAndSetMenuPositionForLevel).
local function placeRoot()
	local outer = RADII[level][2]
	local margin = math.max(outer, CENTER_R) + 10
	local vs = gui.AbsoluteSize
	local x = if 2 * margin > vs.X then vs.X / 2 else math.clamp(anchor.X, margin, vs.X - margin)
	local y = if 2 * margin > vs.Y then vs.Y / 2 else math.clamp(anchor.Y, margin, vs.Y - margin)
	anchor = Vector2.new(x, y)
	root.Position = UDim2.fromOffset(x - gui.AbsolutePosition.X, y - gui.AbsolutePosition.Y)
end

local function selectFirst(lvl: number)
	if not usingGamepad() then
		return
	end
	task.defer(function()
		if not isOpen then
			return
		end
		for i, e in levels[lvl].entries do
			if e.button.Selectable and e.button.Parent then
				GuiService.SelectedObject = e.button
				return
			end
		end
		if centerButton.Selectable then
			GuiService.SelectedObject = centerButton
		end
	end)
end

local function navigateToSubMenu(item, children: { any })
	table.insert(menuStack, currentItems)
	selectedId = item.id
	level += 1
	currentItems = children
	centerState = "back"
	placeRoot()
	buildLevel(level, children)
	local L = levels[level]
	L.scale.Scale = 0.5
	tweenScale(L, 1, 0)
	tweenScale(levels[level - 1], 0.65, 0.2)
	for _, e in levels[level - 1].entries do
		e.button.Selectable = false
	end
	paintLevel(level - 1)
	refreshCenter()
	selectFirst(level)
end

local function navigateBack()
	if #menuStack == 0 then
		return
	end
	clearLevel(level)
	currentItems = table.remove(menuStack) :: any
	level -= 1
	if level == 0 then
		selectedId = nil
		centerState = "default"
	end
	placeRoot()
	tweenScale(levels[level], 1, 0)
	hover = nil
	showTooltip(nil)
	paintLevel(level)
	refreshCenter()
	selectFirst(level)
end

function RadialMenu.close()
	if not isOpen then
		return
	end
	isOpen = false
	local sel = GuiService.SelectedObject
	if sel and (sel:IsDescendantOf(root) or sel == centerButton) then
		GuiService.SelectedObject = nil
	end
	clearLevel(0)
	clearLevel(1)
	level, menuStack, currentItems, selectedId, hover = 0, {}, {}, nil, nil
	centerState = "default"
	root.Visible = false
	blocker.Visible = false
	tooltip.Visible = false
	lastHide = os.clock()
	P = nil
end

function RadialMenu.isOpen(): boolean
	return isOpen
end

function onItemClick(lvl: number, i: number)
	if not isOpen then
		return
	end
	if lvl ~= level then
		-- The shrunken main ring doesn't take clicks while a sub-menu is open (OpenFront closes).
		RadialMenu.close()
		return
	end
	local item = levels[lvl].items[i]
	if not item or isDisabled(item) then
		return
	end
	pcall(function()
		require(script.Parent:WaitForChild("SoundKit")).play("click") -- RadialMenu: PlaySoundEffectEvent("click")
	end)
	local children = if item.subMenu then item.subMenu() else nil
	if children and #children > 0 then
		navigateToSubMenu(item, children)
	else
		if item.action then
			item.action()
		end
		RadialMenu.close()
	end
end

local function onCenterClick()
	if not isOpen then
		return
	end
	if centerState == "back" then
		navigateBack()
		return
	end
	if P and centerEnabled() then
		centerAction()
		RadialMenu.close()
	end
end

function RadialMenu.open(sx: number, sy: number, tile: number, startIn: string?)
	if not ctx or os.clock() - lastHide < REOPEN_COOLDOWN then
		return
	end
	RadialMenu.close()
	local params = buildParams(tile)
	-- Spectators (dead / not in the round): straight to the read-only player panel.
	if not params.alive then
		if params.target and ctx.playerPanel then
			ctx.playerPanel.show(params.ownerId)
		end
		return
	end
	P = params
	isOpen = true
	-- The mouse opens it exactly under the cursor; touch / gamepad use the point they gave.
	anchor = if usingMouse() then mouseGui() else Vector2.new(sx, sy)
	level, menuStack, selectedId, hover = 0, {}, nil, nil
	centerState = "default"
	currentItems = rootItems()
	placeRoot()
	blocker.Visible = true
	root.Visible = true
	levels[0].scale.Scale = 1
	levels[0].image.ImageTransparency = 0
	buildLevel(0, currentItems)
	refreshCenter()
	centerScale.Scale = if centerEnabled() then 1.2 else 1 -- OpenFront opens with the centre "hovered"
	if startIn then
		for i, item in currentItems do
			if item.id == startIn and not isDisabled(item) then
				onItemClick(0, i)
				return
			end
		end
	end
	selectFirst(0)
end

-- Re-checks disabled states (OpenFront's tick() every 500 ms).
local function refresh()
	if not isOpen or not P then
		return
	end
	if ctx.getPhase() ~= "Play" then
		RadialMenu.close()
		return
	end
	P = buildParams(P.tile)
	for lvl = 0, level do
		if #levels[lvl].items > 0 then
			paintLevel(lvl)
		end
	end
	refreshCenter()
end

-- Setup
function RadialMenu.setup(c)
	ctx = c
	gui = c.gui
	noSelection = make("Frame", { Name = "RadialNoSelection", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })

	blocker = make("TextButton", {
		Name = "RadialMenuBlocker",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Visible = false,
		ZIndex = 40,
		Parent = gui,
	})
	root = make("Frame", { Name = "RadialMenu", Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 1, Visible = false, ZIndex = 41, Parent = gui })
	for lvl = 0, 1 do
		local frame = make("Frame", {
			Name = "Level" .. lvl,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(0, 0),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 42 + lvl * 10,
			Parent = root,
		})
		local scale = make("UIScale", { Parent = frame })
		local image = make("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 42, Parent = frame })
		levels[lvl] = { frame = frame, scale = scale, image = image, entries = {}, items = {} }
	end
	-- Sub-menus draw above the scaled-down main ring.
	levels[1].frame.ZIndex = 52

	centerButton = make("TextButton", {
		Name = "Center",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(CENTER_R * 2, CENTER_R * 2),
		BackgroundColor3 = CENTER_DEFAULT,
		AutoButtonColor = false,
		Text = "",
		SelectionImageObject = noSelection,
		ZIndex = 60,
		Parent = root,
	})
	make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = centerButton })
	centerScale = make("UIScale", { Parent = centerButton })
	centerIcon = IconKit.image("Sword", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(CENTER_ICON, CENTER_ICON), ZIndex = 61, Parent = centerButton })
	-- onCenterButtonHover grows only the circle (r x1.2), not the icon: undo the scale on it.
	local iconScale = make("UIScale", { Parent = centerIcon })
	centerScale:GetPropertyChangedSignal("Scale"):Connect(function()
		iconScale.Scale = 1 / math.max(0.01, centerScale.Scale)
	end)
	centerButton.Activated:Connect(onCenterClick)
	centerButton.SelectionGained:Connect(function()
		setHover("center")
	end)
	centerButton.SelectionLost:Connect(function()
		if hover == "center" then
			setHover(nil)
		end
	end)

	tooltip = make("Frame", {
		Name = "RadialTooltip",
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = TOOLTIP_BG,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 50,
		Parent = gui,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 6), Parent = tooltip })
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = tooltip })
	make("UISizeConstraint", { MaxSize = Vector2.new(250, math.huge), Parent = tooltip })
	tooltipList = make("Frame", { Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, BackgroundTransparency = 1, ZIndex = 50, Parent = tooltip })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = tooltipList })
	make("UISizeConstraint", { MaxSize = Vector2.new(230, math.huge), Parent = tooltipList })

	-- Clicks / taps on the overlay: the current ring, the centre, or outside (closes).
	local pressed = false
	blocker.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			pressed = true
		elseif t == Enum.UserInputType.MouseButton2 then
			RadialMenu.close()
		end
	end)
	blocker.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if not pressed or not (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
			return
		end
		pressed = false
		local hit = hitTest(pointerPos(input))
		if hit == "center" then
			onCenterClick()
		elseif type(hit) == "table" then
			onItemClick(hit.level, hit.index)
		else
			RadialMenu.close()
		end
	end)

	-- Esc / B: back out of a sub-menu, else close.
	UserInputService.InputBegan:Connect(function(input)
		if not isOpen then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.ButtonB then
			if level > 0 then
				navigateBack()
			else
				RadialMenu.close()
			end
		end
	end)

	-- Mouse hover (sector highlight + tooltip that follows the cursor) and the renewal blink.
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		if not isOpen then
			return
		end
		if usingMouse() then
			local m = mouseGui()
			local hit = hitTest(m)
			setHover(hit)
			if type(hit) == "table" then
				local item = levels[hit.level].items[hit.index]
				showTooltip(if item and item.tooltip then item.tooltip() else nil, m)
			else
				tooltip.Visible = false
			end
		end
		local L0 = levels[level]
		for i, item in L0.items do
			if item.renderType == "allyExtend" then
				local e = L0.entries[i]
				local base = if isDisabled(item) then 0.5 else 0
				local blink = 0.5 + 0.5 * math.cos(os.clock() / 1.5 * TAU) -- 1 -> 0 -> 1 over 1.5 s
				local faded = base + (1 - base) * (1 - blink) * 0.8
				if e and e.icon then
					e.icon.ImageTransparency = if P and P.outgoing then base else faded
				end
				if e and e.icon2 then
					e.icon2.ImageTransparency = if P and P.incoming then base else faded
				end
			end
		end
		acc += dt
		if acc >= 0.5 then
			acc = 0
			refresh()
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if isOpen then
			placeRoot()
		end
	end)

	-- Pre-compute the ring shapes used most (main ring, attack and build sub-menus) so the first
	-- right-click doesn't hitch.
	task.spawn(function()
		for _, k in { { 0, 4 }, { 1, #ATTACK_ORDER }, { 1, #BUILD_ORDER } } do
			task.wait()
			geometry(k[1], k[2])
		end
	end)
end

return RadialMenu
