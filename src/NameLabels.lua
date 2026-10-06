--[[
	War Front - player name labels on the map (flag, name, troops, status icons).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Placement and sizing ported from OpenFront (AGPL-3.0): src/client/hud/NameBoxCalculator.ts
	(largest inscribed rectangle, font size), src/client/render/gl/shaders/name/name.vert.glsl,
	name.frag.glsl, icon.vert.glsl, status-icon.vert.glsl and render-settings.json "name" (size
	pipeline, troop line, flag, status row, colours, culling), status-icon.frag.glsl (alliance
	drain, traitor / alliance-expiry flash) and src/client/hud/PlayerIcons.ts (which icons show).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.NameLabels (ModuleScript), used by GameClient.
-- NameLabels.setup(ctx)  ctx = { layer: Frame (inside the map image, scale-positioned),
--                                roster: table (id -> player, stable table), fmt(n) -> string,
--                                zoom() -> px per tile, map() -> GameMap, owners() -> buffer,
--                                isAlly(id), isTraitor(id), isShielded(id), tagColor(id) -> Color3,
--                                net: RemoteEvent?, getMyId()?, nukeState(id) -> nil|"white"|"red" }
-- NameLabels.refresh()   update text / colours / visibility of every label (after stats, zoom, ...)
-- NameLabels.step(now)   per frame: incremental placement search + smooth movement
-- NameLabels.clear()     destroy all labels and placements (new round / map)
-- Like OpenFront, a name sits in the centre of the largest rectangle inside the player's bounding
-- box made of their own tiles (plus shore, shallow water and fallout), and its size comes from that
-- rectangle: fontSize = min(width / #name * 2, height / 3). The owner grid is sampled in slices
-- across frames so the cost stays small.
-- Everything is laid out in OpenFront "em" (their atlas font size): flag 0.9 em tall
-- (base 36/48 x 1.2) right against the name, troops 0.6 em one line (0.825 em) below, status row
-- 1.05 em above. Roblox sizes text by the font's whole glyph bounding box, not by em, so the
-- Roblox TextSize is em x `fit`, where `fit` is measured at runtime so a reference sentence is
-- exactly as wide in Builder Sans as in OpenFront's Overpass Bold. That keeps the flag / name /
-- icon proportions OpenFront's whatever the font metrics.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local playerScripts = script.Parent
local FlagKit = require(playerScripts:WaitForChild("FlagKit"))
local IconKit = require(playerScripts:WaitForChild("IconKit"))
local SpriteKit = require(playerScripts:WaitForChild("SpriteKit"))
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)

local NameLabels = {}

-- Overpass Bold in OpenFront; Builder Sans Bold is the closest Roblox family.
local FONT = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)

local FALLOUT = 65535
local MAP_SCALE = 4 -- our maps are OpenFront's map16x (1/4 per axis); sizes are tuned for full res
local NAME_SCALE_FACTOR = 0.4 -- name.nameScaleFactor
local NAME_SCALE_CAP = 3 -- name.nameScaleCap
local TROOP_SIZE = 0.6 -- name.troopSizeMultiplier
local OUTLINE = 1.4 -- name.outlineWidth (screen px, in the player's territory colour)
-- name.frag.glsl caps the outline to the MSDF margin: min(1.4, em_px / 6 - 1) (distanceRange 16
-- atlas px at size 48), so small names have a thinner (or no) outline.
local OUTLINE_PER_EM = 1 / 6
local FLAG_H = 1.2 -- flag height in line heights (icon.vert.glsl)
local ICON = 1.1 -- status icon size in line heights (status-icon.vert.glsl)
local TROOP_LINE = 1.1 -- troop line offset in line heights (name.vert.glsl)
-- Width calibration: Overpass Bold advance width of REF_TEXT, in em (resources/atlases/msdf-atlas.json).
local REF_TEXT = "The quick brown fox jumps over the lazy dog 0123456789"
local REF_EM = 26.5
local TRAITOR_FLASH = 15 -- seconds of traitor time left when its icon starts flashing
local ALLIANCE_FLASH = (Config.ALLIANCE_RENEW_TICKS or 300) * (Config.TICK or 0.1) -- renewal window
local MatchRulesMod = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MatchRules"))
local function allianceLen(): number
	return MatchRulesMod.allianceTicks() * (Config.TICK or 0.1) -- custom alliance duration aware
end
local CULL = 0.004 -- name.cullThreshold 0.008 (clip space) as a fraction of the viewport width
local BASE = 0.75 -- atlas base / font size (36 / 48): line height per em
local LERP_SPEED = 10 -- name.lerpSpeed
local STATUS_ROW = 1.4 -- name.statusRowOffset (line heights above the name centre)
local RESCAN = 0.5 -- seconds between placement passes
local SAMPLES_PER_FRAME = 16000
local CELLS_PER_FRAME = 24000

local ctx: any = nil
local entries: { [number]: any } = {}
local fit = 1 -- Roblox TextSize per OpenFront em (see calibrate)
local crownId = 0

-- Diplomacy as the status row needs it (expiry times for the drain / flash effects), read from
-- the same server messages ContextMenu uses.
local allyExpiry: { [number]: number } = {}
local traitorUntil: { [number]: number } = {}
local requestUntil: { [number]: number } = {} -- incoming alliance request from id -> expiry
-- Doomsday Clock skulls (server "clock"): id -> { stage, warn countdown end (SimClock) }.
-- Stage 1 blinks (faster as the drain nears), 2 is steady, 3 is red (territory rotting).
local doomState: { [number]: { stage: number, warnEnd: number } } = {}

-- Placement search state
local scanMap: any = nil
local scanRow = -1 -- -1 = idle
local lastScanEnd = 0
local minX, minY, maxX, maxY = {}, {}, {}, {}
local queue: { number } = {}
local queueBoxes: { [number]: { number } } = {}

local function myId(): number
	return if ctx and ctx.getMyId then ctx.getMyId() else 0
end

local function onNet(kind: string, data: any)
	if kind == "diplomacy" and type(data) == "table" then
		local me = myId()
		table.clear(allyExpiry)
		for _, e in data.alliances or {} do
			if e[1] == me then
				allyExpiry[e[2]] = e[3]
			elseif e[2] == me then
				allyExpiry[e[1]] = e[3]
			end
		end
		table.clear(traitorUntil)
		for _, e in data.traitors or {} do
			traitorUntil[e[1]] = e[2]
		end
	elseif kind == "allyRequests" and type(data) == "table" then
		table.clear(requestUntil)
		for _, r in data.incoming or {} do
			requestUntil[r[1]] = r[2]
		end
	elseif kind == "init" then
		table.clear(allyExpiry)
		table.clear(traitorUntil)
		table.clear(requestUntil)
	end
end

-- Measures Builder Sans against Overpass Bold (see the header) once the font has loaded.
local function calibrate(layer: Instance)
	local probe = Instance.new("TextLabel")
	probe.Name = "NameFontProbe"
	probe.BackgroundTransparency = 1
	probe.TextTransparency = 1
	probe.FontFace = FONT
	probe.TextSize = 100
	probe.Text = REF_TEXT
	probe.Size = UDim2.fromOffset(0, 0)
	probe.AutomaticSize = Enum.AutomaticSize.XY
	probe.Active = false
	local function measure()
		local w = probe.TextBounds.X
		if w > 200 then
			local f = math.clamp(REF_EM * 100 / w, 0.6, 1.6)
			if math.abs(f - fit) > 0.005 then
				fit = f
				for _, e in entries do
					e.layoutKey = ""
				end
			end
		end
	end
	probe:GetPropertyChangedSignal("TextBounds"):Connect(measure)
	probe.Parent = layer
	measure()
end

function NameLabels.setup(c)
	ctx = c
	if c.net then
		c.net.OnClientEvent:Connect(onNet)
	end
	calibrate(c.layer)
end

-- Placement (NameBoxCalculator.placeName)
local heights: { number } = {}
local stack: { number } = {}

-- Largest rectangle under a histogram; returns x, width, height (cells).
local function largestInHistogram(n: number): (number, number, number)
	table.clear(stack)
	local best, bx, bw, bh = 0, 0, 0, 0
	for i = 0, n do
		local h = if i == n then 0 else heights[i + 1]
		while #stack > 0 and h < heights[stack[#stack] + 1] do
			local top: number = table.remove(stack) :: any
			local height = heights[top + 1]
			local width = if #stack == 0 then i else i - stack[#stack] - 1
			if height * width > best then
				best = height * width
				bx = if #stack == 0 then 0 else stack[#stack] + 1
				bw, bh = width, height
			end
		end
		stack[#stack + 1] = i
	end
	return bx, bw, bh
end

local function nameLength(name: string): number
	return math.max(1, utf8.len(name) or #name)
end

-- Returns centre x, y (tiles) and font size (tiles), plus the number of grid cells visited.
local function placeName(id: number, box: { number }, name: string): (number, number, number, number)
	local map = ctx.map()
	local owners = ctx.owners()
	local terrain = map.terrain
	local W = map.width
	local x0, y0, x1, y1 = box[1], box[2], box[3], box[4]
	-- OpenFront's grid step, picked from the full-resolution box size, converted to our tiles.
	local size = math.min(x1 - x0, y1 - y0) * MAP_SCALE
	local sfFull = if size < 25 then 1 elseif size < 50 then 2 elseif size < 100 then 4 elseif size < 250 then 8 elseif size < 500 then 16 else 32
	local sf = math.max(1, sfFull // MAP_SCALE)
	local gx0, gy0 = x0 // sf, y0 // sf
	local cols = x1 // sf - gx0 + 1
	local rows = y1 // sf - gy0 + 1
	for i = 1, cols do
		heights[i] = 0
	end
	local readu16, readu8 = buffer.readu16, buffer.readu8
	local best, rx, ry, rw, rh = 0, 0, 0, 0, 0
	for gy = 0, rows - 1 do
		local y = (gy0 + gy) * sf
		for gx = 0, cols - 1 do
			local t = y * W + (gx0 + gx) * sf
			local o = readu16(owners, t * 2)
			local ok = o == id or o == FALLOUT
			if not ok then
				local b = readu8(terrain, t)
				if b >= 128 then
					ok = bit32.band(b, 64) ~= 0 -- shore
				else
					ok = bit32.band(b, 32) ~= 0 and bit32.band(b, 31) < 10 -- shallow ocean
				end
			end
			heights[gx + 1] = if ok then heights[gx + 1] + 1 else 0
		end
		local hx, hw, hh = largestInHistogram(cols)
		if hw * hh > best then
			best = hw * hh
			rx, ry, rw, rh = hx, gy - hh + 1, hw, hh
		end
	end
	rx, ry, rw, rh = rx * sf, ry * sf, rw * sf, rh * sf
	local fontSize = math.min(rw / nameLength(name) * 2, rh / 3)
	local cx = math.floor(rx + rw / 2 + gx0 * sf)
	local cy = math.floor(ry + rh / 2 + gy0 * sf)
	return cx, cy - fontSize / 3, fontSize, rows * cols
end

local function startScan()
	scanMap = ctx.map()
	scanRow = 0
	table.clear(minX)
	table.clear(minY)
	table.clear(maxX)
	table.clear(maxY)
end

-- Bounding boxes from every second row/column of the owner grid, a slice per frame.
local function scanSlice(): boolean
	local map = ctx.map()
	if map ~= scanMap then
		startScan()
	end
	local owners = ctx.owners()
	local W, H = map.width, map.height
	local readu16 = buffer.readu16
	local budget = SAMPLES_PER_FRAME
	local y = scanRow
	while y < H and budget > 0 do
		local rowOff = y * W
		for x = 0, W - 1, 2 do
			local o = readu16(owners, (rowOff + x) * 2)
			if o ~= 0 and o ~= FALLOUT then
				local mx = minX[o]
				if mx == nil then
					minX[o], maxX[o], minY[o], maxY[o] = x, x, y, y
				else
					if x < mx then
						minX[o] = x
					end
					if x > maxX[o] then
						maxX[o] = x
					end
					maxY[o] = y
				end
			end
		end
		budget -= W // 2
		y += 2
	end
	scanRow = y
	if y < H then
		return false
	end
	-- Done: queue every player with land (boxes widened by the sampling step).
	table.clear(queue)
	table.clear(queueBoxes)
	for o, mx in minX do
		queue[#queue + 1] = o
		queueBoxes[o] = { math.max(0, mx - 1), math.max(0, minY[o] - 1), math.min(W - 1, maxX[o] + 1), math.min(H - 1, maxY[o] + 1) }
	end
	scanRow = -1
	return true
end

-- Labels
local function newText(parent: Instance, z: number): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Size = UDim2.fromOffset(0, 0)
	t.AutomaticSize = Enum.AutomaticSize.XY
	t.FontFace = FONT
	t.TextStrokeTransparency = 1
	t.ZIndex = z
	t.Text = ""
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Thickness = OUTLINE
	s.Parent = t
	t.Parent = parent
	return t
end

local function newFlag(code: string?, parent: Instance): ImageLabel?
	-- Right edge on the name's left edge, vertically centred on the name line (icon.vert.glsl).
	return FlagKit.image(code, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0, 0.5), ZIndex = 4, Parent = parent })
end

local function newEntry(id: number, p: any)
	local frame = Instance.new("Frame")
	frame.Name = "Name" .. id
	frame.Visible = false -- layout() shows it once it is big enough (e.vis mirrors this)
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromOffset(0, 0)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.ZIndex = 4
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	local name = newText(frame, 4)
	local troops = newText(frame, 4)
	local flag = newFlag(p.flag, name)
	local status = Instance.new("Frame")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.AnchorPoint = Vector2.new(0.5, 0.5)
	status.AutomaticSize = Enum.AutomaticSize.X
	status.ZIndex = 4
	status.Parent = frame
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = status
	local e = {
		frame = frame,
		scale = scale,
		name = name,
		troops = troops,
		flag = flag,
		flagCode = p.flag,
		status = status,
		list = list,
		icons = {},
		flashing = {},
		x = nil,
		y = nil,
		s = nil,
		tx = nil,
		ty = nil,
		ts = nil,
		layoutKey = "",
		vis = false,
	}
	frame.Parent = ctx.layer
	entries[id] = e
	return e
end

-- Status row (PlayerIcons.ts / status-icon.vert.glsl). Slots in OpenFront's order; target (players
-- we target: me.targets - allies' targets aren't sent) and embargo (players we embargo:
-- me.embargoes) come from ctx.isTarget / ctx.hasEmbargo; "shield" (spawn protection) is ours.
local STATUS = {
	{ key = "crown", sprite = "StCrown", icon = "Crown" },
	{ key = "doom", sprite = "StDoomsday", icon = "Skull", color = Color3.new(1, 1, 1) },
	{ key = "traitor", sprite = "StTraitor", icon = "Traitor" },
	{ key = "disconnected", sprite = "StDisconnected", icon = "Info" },
	{ key = "alliance", sprite = "StAlliance", faded = "StAllianceFaded", icon = "Alliance" },
	{ key = "allianceReq", sprite = "StAllianceRequest", icon = "Alliance" },
	{ key = "target", sprite = "StTarget", icon = "Target" },
	{ key = "embargo", sprite = "StEmbargo", icon = "Embargo" },
	{ key = "nuke", sprite = "StNukeWhite", red = "StNukeRed", icon = "AtomBomb" },
	{ key = "shield", icon = "Defense", color = Color3.fromRGB(140, 200, 255) },
}
-- The alliance art carries its dark outline in an extra margin (gen_sprites.py: 67 px for 64).
local OUTLINE_MARGIN = 67 / 64

-- One status icon: a square slot sized by the layout; the art fills it.
local function newIcon(s, order: number, parent: Instance)
	local slot = Instance.new("Frame")
	slot.Name = s.key
	slot.BackgroundTransparency = 1
	slot.LayoutOrder = order
	slot.ZIndex = 4
	local function art(name: string, holder: Instance): ImageLabel?
		local scale = if s.faded then OUTLINE_MARGIN else 1
		return SpriteKit.image(name, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(scale, scale),
			ZIndex = 4,
			Parent = holder,
		})
	end
	local icon = { slot = slot, images = {} }
	local main = s.sprite and art(s.sprite, slot)
	if s.faded and main then
		-- Alliance drain: faded icon underneath, the coloured one clipped to the part below topCut.
		main.Parent = nil
		local faded = art(s.faded, slot)
		local clip = Instance.new("Frame")
		clip.Name = "Clip"
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clip.Size = UDim2.fromScale(1, 1)
		clip.ZIndex = 4
		clip.Parent = slot
		local content = Instance.new("Frame")
		content.Name = "Content"
		content.BackgroundTransparency = 1
		content.Size = UDim2.fromScale(1, 1)
		content.ZIndex = 4
		content.Parent = clip
		main.Parent = content
		icon.clip, icon.content, icon.faded = clip, content, faded
		if faded then
			icon.images[#icon.images + 1] = faded
		end
	elseif not main then
		-- No EditableImage sprites: OpenFront's white icon from IconKit, tinted.
		main = IconKit.image(s.icon, { Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = slot })
		icon.tinted = true
	end
	icon.main = main
	icon.images[#icon.images + 1] = main
	slot.Parent = parent
	return icon
end

local function setDrain(icon, frac: number)
	if not icon.clip then
		return
	end
	-- status-icon.frag.glsl: topCut = 0.20 + (1 - fraction) * 0.624, faded above, coloured below
	local cut = if frac > 0 and frac < 1 then 0.2 + (1 - frac) * 0.624 else 0
	icon.clip.Position = UDim2.fromScale(0, cut)
	icon.clip.Size = UDim2.fromScale(1, 1 - cut)
	icon.content.Position = UDim2.fromScale(0, -cut / (1 - cut))
	icon.content.Size = UDim2.fromScale(1, 1 / (1 - cut))
	if icon.faded then
		icon.faded.Visible = cut > 0
	end
end

local function setIconAlpha(icon, a: number)
	for _, img in icon.images do
		img.ImageTransparency = 1 - a
	end
end

local function isDisconnected(p): boolean
	local uid = p.userId
	return p.kind == "Human" and type(uid) == "number" and uid ~= 0 and Players:GetPlayerByUserId(uid) == nil
end

local function updateStatus(e, id: number, p)
	local now = SimClock.now()
	local allyUntil = allyExpiry[id]
	local isAlly = allyUntil ~= nil or ctx.isAlly(id)
	local tUntil = traitorUntil[id]
	local isTraitor = (tUntil ~= nil and tUntil > now) or (tUntil == nil and ctx.isTraitor(id))
	local nuke = if ctx.nukeState then ctx.nukeState(id) else nil
	local flags = {
		crown = id == crownId,
		traitor = isTraitor,
		disconnected = isDisconnected(p),
		alliance = isAlly,
		allianceReq = (requestUntil[id] or 0) > now,
		nuke = nuke ~= nil,
		target = ctx.isTarget ~= nil and ctx.isTarget(id),
		embargo = ctx.hasEmbargo ~= nil and ctx.hasEmbargo(id),
		shield = ctx.isShielded(id),
		doom = doomState[id] ~= nil,
	}
	table.clear(e.flashing)
	for i, s in STATUS do
		local on = flags[s.key]
		local icon = e.icons[s.key]
		if on and not icon then
			icon = newIcon(s, i, e.status)
			e.icons[s.key] = icon
			e.layoutKey = "" -- size the new icon
		end
		if icon then
			if icon.shown ~= (on == true) then
				icon.shown = on == true
				icon.slot.Visible = icon.shown
			end
			if on then
				if icon.tinted then
					icon.main.ImageColor3 = s.color or (if s.key == "crown" then Color3.new(1, 1, 1) else ctx.tagColor(id))
				end
				if s.red and not icon.tinted then
					local want = if nuke == "red" then s.red else s.sprite
					if icon.art ~= want then
						icon.art = want
						SpriteKit.set(icon.main, want)
					end
				end
				if s.key == "doom" then
					-- Decaying: the RED skull.
					icon.main.ImageColor3 = if doomState[id].stage == 3 then Color3.fromRGB(255, 70, 70) else Color3.new(1, 1, 1)
				end
				-- flashing windows (seconds left) and the alliance drain
				if s.key == "doom" and doomState[id].stage == 1 then
					local d = doomState[id]
					e.flashing[icon] = { until_ = d.warnEnd, window = 30, k = 0.05 }
				elseif s.key == "traitor" and tUntil and tUntil - now <= TRAITOR_FLASH then
					e.flashing[icon] = { until_ = tUntil, window = TRAITOR_FLASH, k = 0.1 }
				elseif s.key == "alliance" and allyUntil then
					local left = allyUntil - now
					setDrain(icon, math.clamp(left / allianceLen(), 0, 1))
					if left <= ALLIANCE_FLASH then
						e.flashing[icon] = { until_ = allyUntil, window = ALLIANCE_FLASH, k = 1.5 / ALLIANCE_FLASH }
					end
				end
				if not e.flashing[icon] then
					setIconAlpha(icon, 1)
				end
			end
		end
	end
end

-- Traitor / alliance-expiry pulse: 0.3 + 0.7 * (0.5 + 0.5 cos(2 pi phase)), speeding up
-- (phase = t * 2 + elapsed^2 * k) as the time runs out.
local function stepFlash(e, now: number)
	for icon, f in e.flashing do
		local left = f.until_ - now
		if left > 0 and left <= f.window then
			local elapsed = f.window - left
			local phase = os.clock() * 2 + elapsed * elapsed * f.k
			setIconAlpha(icon, 0.3 + 0.7 * (0.5 + 0.5 * math.cos(phase * 2 * math.pi)))
		else
			setIconAlpha(icon, 1)
		end
	end
end

-- Positions and sizes one label from its current (lerped) placement and the zoom.
local function layout(e, p)
	local W, H = ctx.map().width, ctx.map().height
	local zoom = ctx.zoom()
	-- size pipeline from name.vert.glsl, in full-resolution tiles
	local baseSize = math.max(1, math.floor(e.s * MAP_SCALE))
	local nameSize = math.max(4, math.floor(baseSize * NAME_SCALE_FACTOR))
	local nameScale = math.min(baseSize * 0.25, NAME_SCALE_CAP)
	local emPx = nameSize * nameScale / MAP_SCALE * zoom -- OpenFront em on screen
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1000
	if emPx * BASE < vw * CULL or e.s <= 0 then
		if e.vis then
			e.vis = false
			e.frame.Visible = false
		end
		return
	end
	if not e.vis then
		-- hidden labels skip troop-count updates (refresh); catch up when one shows again
		e.vis = true
		e.frame.Visible = true
		local troops = (ctx.fmtTroops or ctx.fmt)(p.stats.troops)
		if e.troopsText ~= troops then
			e.troopsText = troops
			e.troops.Text = troops
		end
	end
	-- Property writes cost far more than the maths: only write what changed.
	if e.px ~= e.x or e.py ~= e.y then
		e.px, e.py = e.x, e.y
		e.frame.Position = UDim2.fromScale((e.x + 0.5) / W, (e.y + 0.5) / H)
	end
	-- TextSize tops out at 100: draw at <= ~96 and scale the whole plate up beyond that.
	local k = math.max(1, emPx * math.max(fit, 1) / 96)
	local em = math.floor(emPx / k * 2 + 0.5) / 2
	if e.k ~= k then
		e.k = k
		e.scale.Scale = k
	end
	local outline = math.clamp(emPx * OUTLINE_PER_EM - 1, 0, OUTLINE)
	local key = string.format("%.1f|%.2f|%.3f", em, outline, fit)
	if key == e.layoutKey then
		return
	end
	e.layoutKey = key
	local lineH = em * BASE
	e.name.TextSize = em * fit
	e.troops.TextSize = em * TROOP_SIZE * fit
	e.troops.Position = UDim2.fromOffset(0, lineH * TROOP_LINE)
	local nameStroke: any, troopStroke: any = e.name:FindFirstChildOfClass("UIStroke"), e.troops:FindFirstChildOfClass("UIStroke")
	nameStroke.Enabled = outline > 0.05
	troopStroke.Enabled = outline > 0.05
	nameStroke.Thickness = outline / k
	troopStroke.Thickness = outline / k
	if e.flag then
		local fh = lineH * FLAG_H
		e.flag.Size = UDim2.fromOffset(fh * FlagKit.ASPECT, fh)
	end
	local iconSize = lineH * ICON
	e.status.Size = UDim2.fromOffset(0, iconSize)
	-- top edge STATUS_ROW line heights above the name centre
	e.status.Position = UDim2.fromOffset(0, -lineH * STATUS_ROW + iconSize / 2)
	e.list.Padding = UDim.new(0, iconSize * 0.15)
	for _, icon in e.icons do
		icon.slot.Size = UDim2.fromOffset(iconSize, iconSize)
	end
end

local function fallbackPlacement(p): (number, number, number)
	local s = p.stats
	local side = math.sqrt(math.max(s.tiles, 1))
	local size = math.min(side * 2 / nameLength(p.name), side / 3)
	return s.cx, s.cy - size / 3, size
end

function NameLabels.refresh()
	if not ctx then
		return
	end
	local roster = ctx.roster
	for id, e in entries do
		local p = roster[id]
		if not p or not p.stats.alive or p.stats.tiles <= 0 then
			e.frame:Destroy()
			entries[id] = nil
		end
	end
	-- PlayerIcons.getFirstPlacePlayer: most tiles owned
	crownId = 0
	local most = 0
	for id, p in roster do
		if p.stats.alive and p.stats.tiles > most then
			crownId, most = id, p.stats.tiles
		end
	end
	for id, p in roster do
		local s = p.stats
		if s.alive and s.tiles > 0 then
			local e = entries[id] or newEntry(id, p)
			if e.flagCode ~= p.flag then
				e.flagCode = p.flag
				if e.flag then
					FlagKit.set(e.flag, p.flag)
				else
					e.flag = newFlag(p.flag, e.name)
				end
				e.layoutKey = ""
			end
			if not e.placed then
				-- until the first placement pass has seen this player: centre of mass, size from area
				local x, y, size = fallbackPlacement(p)
				if e.x == nil then
					e.x, e.y, e.s = x, y, size
					e.t0 = os.clock()
				end
				e.tx, e.ty, e.ts = x, y, size
			end
			if e.nameText ~= p.name then
				e.nameText = p.name
				e.name.Text = p.name
			end
			if e.vis then
				local troops = (ctx.fmtTroops or ctx.fmt)(s.troops) -- renderTroops
				if e.troopsText ~= troops then
					e.troopsText = troops
					e.troops.Text = troops
				end
			end
			-- name.frag: grey fill by player type, outline in the territory colour
			local shade = Theme.NAME_SHADE[p.kind] or 0
			local r, g, b = p.r or 200, p.g or 200, p.b or 200
			local colourKey = shade * 16777216 + r * 65536 + g * 256 + b
			if e.colourKey ~= colourKey then -- property writes are the cost here: only on change
				e.colourKey = colourKey
				local fill = Color3.new(shade, shade, shade)
				local outline = Color3.fromRGB(r, g, b)
				e.name.TextColor3 = fill
				e.troops.TextColor3 = fill
				local ns: any, ts: any = e.name:FindFirstChildOfClass("UIStroke"), e.troops:FindFirstChildOfClass("UIStroke")
				ns.Color = outline
				ts.Color = outline
			end
			updateStatus(e, id, p)
			layout(e, p)
		end
	end
end

function NameLabels.step(now: number)
	if not ctx or not ctx.layer.Visible then
		return
	end
	-- 1. placement search
	if scanRow >= 0 then
		scanSlice()
	elseif #queue > 0 then
		local budget = CELLS_PER_FRAME
		while budget > 0 and #queue > 0 do
			local id = table.remove(queue) :: number
			local box = queueBoxes[id]
			local e = entries[id]
			local p = ctx.roster[id]
			if e and p and box then
				local x, y, size, cost = placeName(id, box, p.name)
				budget -= cost
				if size > 0 then
					e.placed = true
					e.tx, e.ty, e.ts = x, y, size
				end
			end
		end
		if #queue == 0 then
			lastScanEnd = now
		end
	elseif now - lastScanEnd > RESCAN then
		startScan()
	end
	-- 2. glide toward the target (exponential, like name.vert.glsl)
	for id, e in entries do
		if e.x and (e.x ~= e.tx or e.y ~= e.ty or e.s ~= e.ts) then
			local dt = now - (e.t0 or now)
			local f = 1 - math.exp(-LERP_SPEED * math.min(dt, 0.25))
			e.x += (e.tx - e.x) * f
			e.y += (e.ty - e.y) * f
			e.s += (e.ts - e.s) * f
			if math.abs(e.tx - e.x) < 0.05 and math.abs(e.ty - e.y) < 0.05 and math.abs(e.ts - e.s) < 0.02 then
				e.x, e.y, e.s = e.tx, e.ty, e.ts
			end
			local p = ctx.roster[id]
			if p then
				layout(e, p)
			end
		end
		e.t0 = now
		if next(e.flashing) and e.vis then
			stepFlash(e, SimClock.now())
		end
	end
end

-- Doomsday Clock status from the server: { { id, stage, secondsUnder } }.
function NameLabels.setDoom(list: any)
	table.clear(doomState)
	if type(list) ~= "table" then
		return
	end
	local now = SimClock.now()
	for _, d in list do
		if type(d) == "table" and type(d[1]) == "number" then
			doomState[d[1]] = { stage = tonumber(d[2]) or 1, warnEnd = now + math.max(0, 30 - (tonumber(d[3]) or 0)) }
		end
	end
end

function NameLabels.clear()
	for _, e in entries do
		e.frame:Destroy()
	end
	table.clear(entries)
	table.clear(queue)
	table.clear(queueBoxes)
	scanRow = -1
	scanMap = nil
	lastScanEnd = 0
end

return NameLabels
