--[[
	War Front - map markers: structures, SAM ranges, nuke targets and trails.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Marker art © OpenFront, CC BY-SA 4.0 (resources/atlases/icon-atlas.png, rasterized by
	gen_icons.py). Modified version re-implemented in Luau for Roblox; not affiliated with or
	endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MapMarkers (ModuleScript), used by GameClient.
-- Mirrors OpenFront's StructurePass / SamRadiusPass / NukeTelegraphPass / TrailPass looks:
--   * Structures: a per-type shape (City circle, Port pentagon, Defense octagon, SAM square,
--     Silo triangle) filled with the owner's colour darkened (HSV value x0.65), a near-black
--     border of the same hue (x0.1) and OpenFront's white glyph. Under construction: grey fill
--     (198) with grey border (127). Zoomed out they shrink to plain dots without the glyph.
--   * SAM ranges: rotating dashed rings around every SAM while a build / nuke mode is active,
--     green (ours), yellow (ally), red (enemy).
--   * Nukes: rotating dashed ring at the blast's outer radius, a translucent filled disc with a
--     solid edge at the inner radius (gently pulsing), coloured by relation like the SAM rings,
--     plus the missile's trail in the launcher's colour.
-- Markers are pooled by structure id: refresh() only adds / removes / restyles what changed,
-- and zoom changes just resize the existing instances.
-- MapMarkers.init(ctx)   ctx = { layer, fxLayer, roster, getMyId(), isAlly(id), mapSize() -> W, H }
-- MapMarkers.refresh(structureList, zoom)   list rows { id, kind, tile, owner, done,
--                                            buildStart, buildEnd, reloadStart, reloadEnd } (server
--                                            times, 0 = none) -> OpenFront BarPass progress bars
-- MapMarkers.addNuke(data) -> Frame          data = server "nuke" payload; Destroy() removes it
-- MapMarkers.step(serverNow, zoom, mode)     every frame (mode = GameClient's build/nuke mode or nil)
-- MapMarkers.setGhost(g, zoom)               build ghost under the cursor (see setGhost), nil hides

local IconKit = require(script.Parent:WaitForChild("IconKit"))
local Ballistics = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Ballistics"))
local SharedConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local DELETION_SECONDS = SharedConfig.DELETION_MARK_TICKS * SharedConfig.TICK

local MapMarkers = {}

-- OpenFront render-settings.json "structure" (their zoom = screen px per tile on a map 4x wider
-- than ours, so their zoom = our zoom / ZOOM_EQUIV).
local ZOOM_EQUIV = 4
local ICON_SIZE = 60
local DOTS_ZOOM = 1.2
local DOT_SCALE = 0.3
local SCALE_FACTOR = 3
local GROW_ZOOM = 7
local FILL_DARKEN = 0.65
local BORDER_DARKEN = 0.1
local BUILD_FILL = Color3.fromRGB(198, 198, 198)
local BUILD_BORDER = Color3.fromRGB(127, 127, 127)
-- render-settings.json "bar" colours
local BAR_RED = Color3.new(0.91, 0.098, 0.098)
local BAR_ORANGE = Color3.new(0.941, 0.478, 0.098)
local BAR_YELLOW = Color3.new(0.792, 0.906, 0.059)
local BAR_GREEN = Color3.new(0.173, 0.937, 0.071)
local HIGHLIGHT_DIM = 0.7 -- transparency of other structure types while placing one (OpenFront dims to 0.3 alpha)

-- Config structure kind -> marker art (shape scale and glyph fill from render-settings.json).
local SHAPES = {
	City = { art = "City", scale = 1, fill = 0.85 },
	Port = { art = "Port", scale = 1.08, fill = 0.85 },
	DefensePost = { art = "Defense", scale = 1, fill = 0.8 },
	SAM = { art = "SAM", scale = 1.4, fill = 1 },
	MissileSilo = { art = "Silo", scale = 1.55, fill = 0.85 },
	Factory = { art = "Factory", scale = 1.08, fill = 0.85 },
}

-- Dashed rings (OpenFront world units / 4 = our tiles): dash 12, gap 6, stroke 2 x 1.5.
local DASH_PERIOD = 4.5
local DASH_FRACTION = 12 / 18
local RING_STROKE = 0.75 -- tiles
local NUKE_SPIN = 5 -- tiles of arc per second (OpenFront 20)
local SAM_SPIN = 3.5 -- (OpenFront 14)
local SAM_ALPHA = 0.8
local RELATION_COLORS = {
	self = Color3.fromRGB(0, 255, 0),
	ally = Color3.fromRGB(255, 255, 0),
	enemy = Color3.fromRGB(255, 0, 0),
}
local TRAIL_TRANSPARENCY = 1 - 0.588
local TRAIL_SEGMENTS = 16

local ctx: any = nil
local markers: { [number]: any } = {} -- structure id -> marker
local bars: { [number]: any } = {} -- structure id -> marker with a progress bar to animate
local samRings: { [number]: any } = {} -- structure id -> ring
local nukeFx: { [number]: any } = {} -- nuke id -> fx
local lastZoom = -1
local lastW, lastH = 0, 0
local lastModeKey = ""
local showSam = false
local fallback = false -- EditableImage unavailable: plain frames instead of shape images

local function darken(c: Color3, f: number): Color3
	local h, s, v = c:ToHSV()
	return Color3.fromHSV(h, s, v * f)
end

local function ownerColor(owner: number): Color3
	local p = ctx.roster[owner]
	if p then
		return Color3.fromRGB(p.r, p.g, p.b)
	end
	return Color3.fromRGB(110, 110, 110)
end

local function relationColor(owner: number): Color3
	local myId = ctx.getMyId()
	if myId ~= 0 and owner == myId then
		return RELATION_COLORS.self
	elseif myId ~= 0 and ctx.isAlly(owner) then
		return RELATION_COLORS.ally
	end
	return RELATION_COLORS.enemy
end

local function tileScale(t: number): UDim2
	local W, H = ctx.mapSize()
	return UDim2.fromScale((t % W + 0.5) / W, (t // W + 0.5) / H)
end

local function xyScale(x: number, y: number): UDim2
	local W, H = ctx.mapSize()
	return UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
end

-- Tinted shape image (or a plain frame when icons can't be drawn).
local function shapeImage(name: string, props): ImageLabel
	local img = IconKit.image(name, props)
	local glyph = img:FindFirstChild("IconGlyph")
	if glyph then
		fallback = true
		glyph:Destroy()
		img.BackgroundTransparency = 0
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(if string.find(name, "City") then 1 else 0.2, 0)
		c.Parent = img
	end
	return img
end

local function tint(img: ImageLabel, c: Color3)
	img.ImageColor3 = c
	if fallback then
		img.BackgroundColor3 = c
	end
end

local function sizeFor(zoom: number): (number, boolean)
	local z = zoom / ZOOM_EQUIV
	local iconScale
	if z <= DOTS_ZOOM then
		return ICON_SIZE * DOT_SCALE, false
	elseif z >= GROW_ZOOM then
		iconScale = z / GROW_ZOOM
	else
		iconScale = math.min(1, z / SCALE_FACTOR)
	end
	return ICON_SIZE * iconScale, true
end

-- Dashed ring: a rotating holder with dashes laid around its edge (sizes by scale, so it follows
-- the map's zoom on its own).
local function dashedRing(parent: Instance, radius: number, color: Color3, zIndex: number): Frame
	local W, H = ctx.mapSize()
	local holder = Instance.new("Frame")
	holder.Name = "DashedRing"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromScale(radius * 2 / W, radius * 2 / H)
	holder.BackgroundTransparency = 1
	holder.ZIndex = zIndex
	local n = math.max(8, math.floor(2 * math.pi * radius / DASH_PERIOD + 0.5))
	local dashLen = 2 * math.pi * radius / n * DASH_FRACTION / (radius * 2)
	local thick = RING_STROKE / (radius * 2)
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * 2 * math.pi
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = UDim2.fromScale(0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a))
		d.Size = UDim2.new(dashLen, 0, thick, 1)
		d.Rotation = math.deg(a) + 90
		d.BackgroundColor3 = color
		d.BorderSizePixel = 0
		d.ZIndex = zIndex
		d.Parent = holder
	end
	holder.Parent = parent
	return holder
end

local function setRingColor(ring: Frame, color: Color3)
	for _, d in ring:GetChildren() do
		if d:IsA("Frame") then
			d.BackgroundColor3 = color
		end
	end
end

local function setRingTransparency(ring: Frame, tr: number)
	for _, d in ring:GetChildren() do
		if d:IsA("Frame") then
			d.BackgroundTransparency = tr
		end
	end
end

-- Structures
-- Red X over a structure marked for deletion (structure.frag: rgb 1, 0.25, 0.25 at 95%).
local function setDeleteMark(m, on: boolean)
	if on and not m.xMark then
		local holder = Instance.new("Frame")
		holder.Name = "DeleteMark"
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromScale(1, 1)
		holder.ZIndex = 4
		for _, rot in { 45, -45 } do
			local line = Instance.new("Frame")
			line.AnchorPoint = Vector2.new(0.5, 0.5)
			line.Position = UDim2.fromScale(0.5, 0.5)
			line.Size = UDim2.new(1.1, 0, 0.09, 0)
			line.Rotation = rot
			line.BorderSizePixel = 0
			line.BackgroundColor3 = Color3.new(1, 0.25, 0.25)
			line.BackgroundTransparency = 0.05
			line.ZIndex = 4
			line.Parent = holder
		end
		holder.Parent = m.outer
		m.xMark = holder
	elseif m.xMark then
		m.xMark.Visible = on
	end
end

local function newMarker(kind: string)
	local shape = SHAPES[kind] or SHAPES.City
	local art = shape.art
	local outer = shapeImage("Mk" .. art, {
		Name = "Structure",
		AnchorPoint = Vector2.new(0.5, 0.5),
		ScaleType = Enum.ScaleType.Stretch,
		ZIndex = 2,
	})
	local inner = shapeImage("Mk" .. art .. "In", {
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Stretch,
		ZIndex = 2,
		Parent = outer,
	})
	if fallback then
		inner.Size = UDim2.new(1, -2, 1, -2)
		inner.AnchorPoint = Vector2.new(0.5, 0.5)
		inner.Position = UDim2.fromScale(0.5, 0.5)
	end
	local iconName = if SHAPES[kind] then "MkIcon" .. art else (IconKit.KIND[kind] or kind)
	local f = shape.fill / shape.scale
	local icon = IconKit.image(iconName, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(f, f),
		ZIndex = 2,
		Parent = outer,
	})
	if icon:FindFirstChild("IconGlyph") and SHAPES[kind] then
		IconKit.set(icon, IconKit.KIND[kind] or "City")
	end
	return { outer = outer, inner = inner, icon = icon, kind = kind, scale = shape.scale }
end

-- StructureLevelPass: the level number (level > 1) in white with a dark outline, just above the
-- icon (offsetY -0.4 of half an icon, text about half an icon tall); hidden in dots mode.
local function layoutLevel(m, px: number, showIcon: boolean)
	local l = m.levelLabel
	if not l then
		return
	end
	l.Visible = showIcon and (m.level or 1) > 1
	l.TextSize = math.max(8, math.floor(px * 0.62 + 0.5))
	l.Position = UDim2.new(0.5, 0, 0.5, -math.floor(px * 0.62 + 0.5))
end

local function setLevel(m, level: number, px: number, showIcon: boolean)
	if m.level == level then
		return
	end
	m.level = level
	if level > 1 and not m.levelLabel then
		local l = Instance.new("TextLabel")
		l.Name = "Level"
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.Size = UDim2.fromOffset(0, 0)
		l.AutomaticSize = Enum.AutomaticSize.XY
		l.BackgroundTransparency = 1
		l.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
		l.TextColor3 = Color3.new(1, 1, 1)
		l.ZIndex = 5
		local st = Instance.new("UIStroke")
		st.Color = Color3.fromRGB(20, 20, 20)
		st.Thickness = 1.5
		st.Parent = l
		l.Parent = m.outer
		m.levelLabel = l
	end
	if m.levelLabel then
		m.levelLabel.Text = tostring(level)
		layoutLevel(m, px, showIcon)
	end
end

local function sizeMarker(m, px: number, showIcon: boolean)
	local s = math.floor(px * m.scale + 0.5)
	m.outer.Size = UDim2.fromOffset(s, s)
	m.icon.Visible = showIcon
	layoutLevel(m, px, showIcon)
end

-- Border band colour (structure.frag.glsl): the owner's border colour, except the local player's
-- own structures, which use the territory colour.
local function borderColor(owner: number): Color3
	local p = ctx.roster[owner]
	if p and p.paint and owner ~= ctx.getMyId() then
		return Color3.fromRGB(p.paint[4], p.paint[5], p.paint[6])
	end
	return ownerColor(owner)
end

local function styleMarker(m, owner: number, done: boolean)
	if done then
		local c = ownerColor(owner)
		tint(m.inner, darken(c, FILL_DARKEN))
		tint(m.outer, darken(borderColor(owner), BORDER_DARKEN))
	else
		tint(m.inner, BUILD_FILL)
		tint(m.outer, BUILD_BORDER)
	end
end

local function dimMarker(m, dim: boolean)
	local tr = if dim then HIGHLIGHT_DIM else 0
	if m.dim ~= tr then
		m.dim = tr
		m.outer.ImageTransparency = tr
		m.inner.ImageTransparency = tr
		m.icon.ImageTransparency = tr
		if fallback then
			m.outer.BackgroundTransparency = tr
			m.inner.BackgroundTransparency = tr
		end
	end
end

local function modeDims(mode, kind: string): boolean
	return mode ~= nil and mode.type == "build" and mode.kind ~= kind
end

local currentMode = nil

-- Drops every marker (new round / map switch); the next refresh rebuilds them.
function MapMarkers.clear()
	for id, m in markers do
		m.outer:Destroy()
		if m.bar then
			m.bar:Destroy()
		end
		markers[id] = nil
	end
	table.clear(bars)
	for id, ring in samRings do
		ring.frame:Destroy()
		samRings[id] = nil
	end
end

function MapMarkers.refresh(list, zoom: number)
	if not ctx then
		return
	end
	local W, H = ctx.mapSize()
	if W ~= lastW or H ~= lastH then
		-- New map: positions and ring sizes are map-relative, so start over.
		lastW, lastH = W, H
		MapMarkers.clear()
	end
	local px, showIcon = sizeFor(zoom)
	local zoomChanged = zoom ~= lastZoom
	lastZoom = zoom
	local seen = {}
	for _, s in list do
		local id, kind, t, o, done = s[1], s[2], s[3], s[4], s[5] == true
		seen[id] = true
		local m = markers[id]
		if m and m.kind ~= kind then
			m.outer:Destroy()
			if m.bar then
				m.bar:Destroy()
			end
			bars[id] = nil
			markers[id] = nil
			m = nil
		end
		if not m then
			m = newMarker(kind)
			markers[id] = m
			m.outer.Parent = ctx.layer
			sizeMarker(m, px, showIcon)
			dimMarker(m, modeDims(currentMode, kind))
		elseif zoomChanged then
			sizeMarker(m, px, showIcon)
		end
		if m.tile ~= t then
			m.tile = t
			m.outer.Position = tileScale(t)
		end
		-- Colours are cheap to reapply and the owner's colour can change between rounds.
		m.owner, m.done = o, done
		styleMarker(m, o, done)
		setLevel(m, tonumber(s[10]) or 1, px, showIcon)
		-- Progress bar (BarPass): construction first, else Silo / SAM reload. Times are server
		-- times appended to the row by GameServer (0 = none); older servers send no times.
		local b0, b1 = 0, 0
		if not done and (tonumber(s[7]) or 0) > 0 then
			b0, b1 = s[6], s[7]
		elseif done and (kind == "MissileSilo" or kind == "SAM") and (tonumber(s[9]) or 0) > 0 then
			b0, b1 = s[8], s[9]
		end
		-- Deletion mark (BarPass reverse countdown, takes priority) + StructurePass red X.
		local delAt = tonumber(s[11]) or 0
		m.reverse = false
		if delAt > 0 then
			b0, b1 = delAt - DELETION_SECONDS, delAt
			m.reverse = true
		end
		setDeleteMark(m, delAt > 0)
		m.bar0, m.bar1 = b0, b1
		if b1 > 0 then
			bars[id] = m
		elseif m.bar then
			m.bar.Visible = false
		end

		-- SAM range ring (shown while placing something, like OpenFront's ghost preview).
		local ring = samRings[id]
		if kind == "SAM" and done then
			if not ring then
				ring = { frame = dashedRing(ctx.layer, ctx.samRange, relationColor(o), 1) }
				setRingTransparency(ring.frame, 1 - SAM_ALPHA)
				ring.frame.Visible = showSam
				samRings[id] = ring
			end
			ring.frame.Position = tileScale(t)
			local rc = relationColor(o)
			if ring.color ~= rc then
				ring.color = rc
				setRingColor(ring.frame, rc)
			end
		elseif ring then
			ring.frame:Destroy()
			samRings[id] = nil
		end
	end
	for id, m in markers do
		if not seen[id] then
			m.outer:Destroy()
			if m.bar then
				m.bar:Destroy()
			end
			bars[id] = nil
			markers[id] = nil
		end
	end
	for id, ring in samRings do
		if not seen[id] then
			ring.frame:Destroy()
			samRings[id] = nil
		end
	end
end

-- Nukes
function MapMarkers.addNuke(data): Frame
	local W, H = ctx.mapSize()
	local def = ctx.nukes[data.kind] or { inner = 3, outer = 7.5 }
	local color = relationColor(data.owner or 0)
	local holder = Instance.new("Frame")
	holder.Name = "NukeTarget"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 5
	holder.Parent = ctx.fxLayer

	local tx, ty = data.to % W, data.to // W
	local fx, fy = data.from % W, data.from // W

	-- Trail (launcher's colour), drawn under everything else of this nuke. Arc flights (OpenFront
	-- parabola, Shared.Ballistics) draw it as a polyline of TRAIL_SEGMENTS pieces.
	local curve = if data.arc then Ballistics.curve(fx + 0.5, fy + 0.5, tx + 0.5, ty + 0.5, H, nil, data.down == true) else nil
	local segments = {}
	for i = 1, if curve then TRAIL_SEGMENTS else 1 do
		local seg = Instance.new("Frame")
		seg.Name = "Trail"
		seg.AnchorPoint = Vector2.new(0.5, 0.5)
		seg.BackgroundColor3 = ownerColor(data.owner or 0)
		seg.BackgroundTransparency = TRAIL_TRANSPARENCY
		seg.BorderSizePixel = 0
		seg.Size = UDim2.fromOffset(0, 0)
		seg.ZIndex = 5
		seg.Parent = holder
		segments[i] = seg
	end
	local trail = segments[1]
	if def.mirv then
		-- OpenFront draws no target telegraph for the MIRV carrier (only for its warheads).
		nukeFx[data.id] = {
			holder = holder, trail = trail, segments = segments, curve = curve, speed = data.speed or 0,
			fx = fx, fy = fy, tx = tx, ty = ty, start = data.start, duration = data.duration,
			owner = data.owner or 0, strokeZoom = -1,
		}
		return holder
	end

	-- Inner blast radius: translucent disc with a solid edge.
	local disc = Instance.new("Frame")
	disc.Name = "Inner"
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = xyScale(tx, ty)
	disc.Size = UDim2.fromScale(def.inner * 2 / W, def.inner * 2 / H)
	disc.BackgroundColor3 = color
	disc.BackgroundTransparency = 0.75
	disc.BorderSizePixel = 0
	disc.ZIndex = 5
	disc.Parent = holder
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = disc
	local edge = Instance.new("UIStroke")
	edge.Color = color
	edge.Thickness = 1.5
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = disc

	-- Outer blast radius: rotating dashed ring.
	local ring = dashedRing(holder, def.outer, color, 5)
	ring.Position = xyScale(tx, ty)

	nukeFx[data.id] = {
		holder = holder,
		trail = trail,
		segments = segments,
		curve = curve,
		speed = data.speed or 0,
		disc = disc,
		edge = edge,
		ring = ring,
		outer = def.outer,
		fx = fx,
		fy = fy,
		tx = tx,
		ty = ty,
		start = data.start,
		duration = data.duration,
		owner = data.owner or 0,
		strokeZoom = -1,
	}
	return holder
end

-- Per frame
function MapMarkers.step(st: number, zoom: number, mode)
	if not ctx then
		return
	end
	local t = os.clock()

	-- Build-mode highlight + SAM ranges follow the placement mode.
	local key = if mode then (mode.type .. ":" .. tostring(mode.kind)) else ""
	if key ~= lastModeKey then
		lastModeKey = key
		currentMode = mode
		for _, m in markers do
			dimMarker(m, modeDims(mode, m.kind))
		end
		showSam = mode ~= nil
		for _, ring in samRings do
			ring.frame.Visible = showSam
		end
	end
	if showSam then
		local deg = math.deg(t * SAM_SPIN / ctx.samRange) % 360
		for _, ring in samRings do
			ring.frame.Rotation = deg
		end
	end

	-- Progress bars (BarPass): 14x3 full-res tiles (3.5 x 0.75 of ours), black 1-tile border,
	-- top edge 6 full-res tiles below the structure centre; colour by progress thresholds.
	for id, m in bars do
		local span = m.bar1 - m.bar0
		local f = if span > 0 then (st - m.bar0) / span else 1
		if m.bar1 <= 0 or f >= 1 or not m.outer.Parent then
			if m.bar then
				m.bar.Visible = false
			end
			bars[id] = nil
			continue
		end
		f = math.clamp(f, 0, 1)
		if m.reverse then
			f = 1 - f
		end
		local bar = m.bar
		if not bar then
			bar = Instance.new("Frame")
			bar.Name = "Progress"
			bar.AnchorPoint = Vector2.new(0.5, 0)
			bar.BackgroundColor3 = Color3.new(0, 0, 0)
			bar.BorderSizePixel = 0
			bar.ZIndex = 2
			local fill = Instance.new("Frame")
			fill.Name = "Fill"
			fill.Position = UDim2.fromScale(1 / 14, 1 / 3)
			fill.BorderSizePixel = 0
			fill.ZIndex = 2
			fill.Parent = bar
			bar.Parent = ctx.layer
			m.bar = bar
		end
		bar.Visible = true
		bar.Position = tileScale(m.tile) + UDim2.fromOffset(0, 1.5 * zoom)
		bar.Size = UDim2.fromOffset(3.5 * zoom, 0.75 * zoom)
		local fill = bar:FindFirstChild("Fill") :: Frame
		fill.Size = UDim2.fromScale(f * 12 / 14, 1 / 3)
		fill.BackgroundColor3 = if f < 0.25 then BAR_RED elseif f < 0.5 then BAR_ORANGE elseif f < 0.75 then BAR_YELLOW else BAR_GREEN
	end

	-- Nukes: spin, pulse, trail.
	local pulse = 0.85 + 0.1 * math.sin(t * 3)
	for id, n in nukeFx do
		if not n.holder.Parent then
			nukeFx[id] = nil
			continue
		end
		if n.ring then
			n.ring.Rotation = math.deg(t * NUKE_SPIN / n.outer) % 360
			setRingTransparency(n.ring, 1 - pulse)
			n.disc.BackgroundTransparency = 1 - math.max(0, pulse - 0.6)
			n.edge.Transparency = 1 - pulse
			if n.strokeZoom ~= zoom then
				n.strokeZoom = zoom
				n.edge.Thickness = math.max(1.5, RING_STROKE * zoom)
			end
		end
		if n.curve then
			-- Polyline along the arc from the silo to the missile's current point.
			local dist = math.clamp((st - n.start) * n.speed, 0, Ballistics.length(n.curve))
			local count = #n.segments
			local px, py = n.fx + 0.5, n.fy + 0.5
			for k = 1, count do
				local x, y = Ballistics.at(n.curve, dist * k / count)
				local seg = n.segments[k]
				local dx, dy = x - px, y - py
				seg.Position = xyScale((px + x) / 2 - 0.5, (py + y) / 2 - 0.5)
				seg.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) * zoom + 1, math.max(1.5, zoom * 0.3))
				seg.Rotation = math.deg(math.atan2(dy, dx))
				px, py = x, y
			end
			continue
		end
		local f = math.clamp((st - n.start) / math.max(n.duration, 0.01), 0, 1)
		local cx = n.fx + (n.tx - n.fx) * f
		local cy = n.fy + (n.ty - n.fy) * f
		local dx, dy = cx - n.fx, cy - n.fy
		local len = math.sqrt(dx * dx + dy * dy) * zoom
		n.trail.Position = xyScale((n.fx + cx) / 2, (n.fy + cy) / 2)
		n.trail.Size = UDim2.fromOffset(len, math.max(1.5, zoom * 0.3))
		n.trail.Rotation = math.deg(math.atan2(dy, dx))
	end
end

-- Build ghost (BuildPreviewController + StructurePass ghost + WorldTextPass ghost cost)
-- g = { kind, x, y (tile coords, float: follows the cursor), owner, canPlace, canUpgrade,
--       upgradeTile, cost, canAfford, showCost } or nil.
-- Icon: the structure's marker at 50 % alpha with the owner's colours; outline tinted green
-- (upgrade), red (can't build here) or left as is (valid). The existing structure being upgraded
-- gets a green outline too. Cost: renderNumber text 18 px, 25 px under the icon, 1.4 px black
-- outline; red when unaffordable, grey when it can't be placed, else white.
local GHOST_ALPHA = 0.5
local GHOST_RED = Color3.new(0.8, 0.2, 0.2)
local GHOST_GREEN = Color3.new(0, 0.8, 0)
local COST_SIZE = 18
local COST_OFFSET = 25
local ghost: any = nil
local ghostCost: TextLabel? = nil
local upgradeMark: any = nil
-- Build-mode extras (BuildPreviewController): the icon of a bomb / warship under the cursor (they
-- have no structure ghost) and RangeCirclePass, the white circle showing a nuke's blast radius,
-- a SAM's / defense post's range or a factory's rail range.
local ghostExtra: { icon: ImageLabel?, kind: string?, circle: Frame? } = {}
local function rangeFor(kind: string): number
	local L = SharedConfig.LINEAR_SCALE or 4
	if kind == "AtomBomb" or kind == "HydrogenBomb" then
		return SharedConfig.NUKES[kind].outer -- nukeMagnitudes(type).outer
	elseif kind == "SAM" then
		return (150 - 480 / (1 + 5)) / L -- samRange(level 1)
	elseif kind == "Factory" then
		return 110 / L -- trainStationMaxRange
	elseif kind == "DefensePost" then
		return SharedConfig.DEFENSE_RADIUS or 30 / L -- defensePostRange
	end
	return 0
end

local function renderNumber(n: number): string
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

local function ghostAlpha(m, tr: number)
	m.outer.ImageTransparency = tr
	m.inner.ImageTransparency = tr
	m.icon.ImageTransparency = tr
	if fallback then
		m.outer.BackgroundTransparency = tr
		m.inner.BackgroundTransparency = tr
	end
end

function MapMarkers.setGhost(g, zoom: number)
	if not ctx then
		return
	end
	if not g then
		if ghostExtra.icon then
			ghostExtra.icon:Destroy()
			ghostExtra.icon, ghostExtra.kind = nil, nil
		end
		if ghostExtra.circle then
			ghostExtra.circle.Visible = false
		end
		if ghost then
			ghost.outer:Destroy()
			ghost = nil
		end
		if ghostCost then
			ghostCost.Visible = false
		end
		if upgradeMark then
			upgradeMark.outer:Destroy()
			upgradeMark = nil
		end
		return
	end
	if ghost and ghost.kind ~= g.kind then
		ghost.outer:Destroy()
		ghost = nil
	end
	-- Structures have a ghost marker (StructurePass atlas); bombs and warships get their build-bar
	-- icon under the cursor instead.
	local hasIcon = SHAPES[g.kind] ~= nil
	local px = math.max(sizeFor(zoom), ICON_SIZE * 0.5)
	if ghostExtra.icon and (hasIcon or ghostExtra.kind ~= g.kind) then
		ghostExtra.icon:Destroy()
		ghostExtra.icon, ghostExtra.kind = nil, nil
	end
	if not hasIcon then
		local icon = ghostExtra.icon
		if not icon then
			icon = IconKit.image(g.kind, { Name = "BuildGhostIcon", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(26, 26), ImageTransparency = 0.15, ZIndex = 4, Parent = ctx.layer })
			ghostExtra.icon, ghostExtra.kind = icon, g.kind
		end
		icon.Position = xyScale(g.x - 0.5, g.y - 0.5)
		icon.ImageColor3 = if g.canPlace == false and g.canAfford == false then Color3.new(1, 0.45, 0.45) else Color3.new(1, 1, 1)
	elseif not ghost then
		ghost = newMarker(g.kind)
		ghost.outer.Name = "BuildGhost"
		ghost.outer.ZIndex = 3
		ghost.inner.ZIndex = 3
		ghost.icon.ZIndex = 3
		ghostAlpha(ghost, GHOST_ALPHA)
		ghost.outer.Parent = ctx.layer
	end
	if ghost then
		sizeMarker(ghost, px, true)
		ghost.outer.Position = xyScale(g.x - 0.5, g.y - 0.5)
		styleMarker(ghost, g.owner, true)
		if g.canUpgrade then
			tint(ghost.outer, GHOST_GREEN)
		elseif not g.canPlace then
			tint(ghost.outer, GHOST_RED)
		end
	end

	-- Green outline on the structure that would be upgraded.
	if hasIcon and g.canUpgrade and g.upgradeTile then
		if upgradeMark and upgradeMark.kind ~= g.kind then
			upgradeMark.outer:Destroy()
			upgradeMark = nil
		end
		if not upgradeMark then
			upgradeMark = newMarker(g.kind)
			upgradeMark.outer.Name = "UpgradeTarget"
			upgradeMark.outer.ZIndex = 3
			upgradeMark.inner.ZIndex = 3
			upgradeMark.icon.ZIndex = 3
			ghostAlpha(upgradeMark, 0.4)
			upgradeMark.outer.Parent = ctx.layer
		end
		local spx, showIcon = sizeFor(zoom)
		sizeMarker(upgradeMark, spx, showIcon)
		upgradeMark.outer.Position = tileScale(g.upgradeTile)
		styleMarker(upgradeMark, g.owner, true)
		tint(upgradeMark.outer, GHOST_GREEN)
	elseif upgradeMark then
		upgradeMark.outer:Destroy()
		upgradeMark = nil
	end

	-- Range circle: 20 % white fill and a white edge, centred on the tile (or the structure that
	-- would be upgraded).
	local range = rangeFor(g.kind)
	if range > 0 then
		local c = ghostExtra.circle
		if not c then
			c = Instance.new("Frame")
			c.Name = "BuildRange"
			c.AnchorPoint = Vector2.new(0.5, 0.5)
			c.BackgroundColor3 = Color3.new(1, 1, 1)
			c.BackgroundTransparency = 0.8
			c.BorderSizePixel = 0
			c.ZIndex = 2
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = c
			local edge = Instance.new("UIStroke")
			edge.Color = Color3.new(1, 1, 1)
			edge.Transparency = 0.5
			edge.Thickness = 1.5
			edge.Parent = c
			c.Parent = ctx.layer
			ghostExtra.circle = c
		end
		local W, H = ctx.mapSize()
		c.Visible = true
		c.Size = UDim2.fromScale(range * 2 / W, range * 2 / H)
		if g.canUpgrade and g.upgradeTile then
			c.Position = tileScale(g.upgradeTile)
		else
			c.Position = xyScale(g.x - 0.5, g.y - 0.5)
		end
	elseif ghostExtra.circle then
		ghostExtra.circle.Visible = false
	end

	if g.showCost and (g.cost or 0) > 0 then
		local l = ghostCost
		if not l then
			l = Instance.new("TextLabel")
			l.Name = "GhostCost"
			l.AnchorPoint = Vector2.new(0.5, 0.5)
			l.BackgroundTransparency = 1
			l.Size = UDim2.fromOffset(90, COST_SIZE + 4)
			l.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
			l.TextSize = COST_SIZE
			l.ZIndex = 4
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 1.4
			stroke.Color = Color3.new(0, 0, 0)
			stroke.Parent = l
			l.Parent = ctx.layer
			ghostCost = l
		end
		l.Visible = true
		l.Text = renderNumber(g.cost)
		l.TextColor3 = if not g.canAfford then Color3.new(1, 0.3, 0.3)
			elseif not (g.canPlace or g.canUpgrade) then Color3.new(0.6, 0.6, 0.6)
			else Color3.new(1, 1, 1)
		l.Position = xyScale(g.x - 0.5, g.y - 0.5) + UDim2.fromOffset(0, COST_OFFSET)
	elseif ghostCost then
		ghostCost.Visible = false
	end
end

--[[
	ctx = {
		layer, fxLayer,          -- structure layer and effects layer (children of the map image)
		roster,                  -- live roster table (id -> { r, g, b, ... })
		getMyId(), isAlly(id), mapSize() -> (W, H),
		samRange, nukes,         -- Config.SAM_RANGE, Config.NUKES
	}
]]
function MapMarkers.init(c)
	ctx = c
end

return MapMarkers
