--[[
	War Front - high-resolution map renderer (terrain, territory fill, thin borders).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Look ported from OpenFront (AGPL-3.0): src/client/render/gl/shaders/map-overlay/territory.frag.glsl
	(fill, hover contrast, defence darkening), shaders/border-compute/border-compute.frag.glsl and
	shaders/day-night/border-stamp.frag.glsl (borders, highlight thickening, ally tint, defence
	checkerboard, alt-view), shaders/spawn-overlay/spawn-overlay.frag.glsl (spawn-phase halos),
	shaders/map-overlay/trail.frag.glsl + frame/TrailManager.ts (transport wakes) and
	render-settings.json. Modified version re-implemented in Luau for Roblox; not affiliated with or
	endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MapRender (ModuleScript), used by GameClient and MapFx.
-- OpenFront draws one map tile per texel, and its tiles are 4x smaller than ours, so its borders
-- are a hair-thin line. To match that we draw every sim tile as an S x S pixel block (S = 3 on
-- desktop / console, 2 on phones, 1 with the "Low detail" setting) and draw borders as a 1-pixel
-- line along the tile edge facing a different owner, with the translucent territory fill inside.
-- EditableImages are limited to 1024 x 1024, so the map is split into a grid of chunk images
-- (ImageLabels laid side by side inside GameClient's map frame, sized by scale, so the camera code
-- and screenToTile keep working through the map frame's size / position).
-- Repaint is incremental: tiles are grouped into 8 x 8 cells; a changed tile marks its cell (and
-- the neighbouring cells it borders), dirty cells are repainted under a per-frame time budget into
-- each chunk's pixel buffer, and only the touched strips of rows are uploaded.
-- MapRender.init(ctx)  ctx = { parent = map frame, holder = viewport frame, map = MapUtil map,
--                              getOwners() -> buffer, roster, getMyId(), getPhase() -> string,
--                              getStructures() -> list }
-- MapRender.setMap(map)          after the map changed (rebuilds terrain and chunk images)
-- MapRender.buildBase()          recompute terrain colours (terrain shading setting)
-- MapRender.markTile(t)          tile t (owner) changed
-- MapRender.markAll()            repaint everything (palette / diplomacy / settings changes); skipped
--                                when nothing that affects the look changed, see invalidate()
-- MapRender.invalidate()         next markAll() repaints regardless (owners replaced wholesale)
-- MapRender.setHighlight(owner)  hovered player (0 = none): brighter fill, thicker brighter border
-- MapRender.setAltView(on)       OpenFront's alt view: territory recoloured by relation to us
-- MapRender.addTrail(id, path, start, speed, owner) / removeTrail(id) / clearTrails()
--                                transport wakes (path = buffer of u32 tiles, start = server time)
-- MapRender.setRails(buf, paint) per-tile rail types (u8, 0 = none) and the painter drawn over
--                                rail tiles: paint(owners, t, x, y, buf, off, stride, S) (UnitFx.lua)
-- MapRender.step(now, zoom)      every frame
-- MapRender.scale() -> S

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local Theme = require(Shared:WaitForChild("Theme"))
local MapStyles = require(Shared:WaitForChild("MapStyles"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))
local ContextMenu = require(script.Parent:WaitForChild("ContextMenu"))

local MapRender = {}
local CosmeticTestStyles = if game.GameId==10769671248 and workspace:GetAttribute("WFEnableCosmeticTesting")==true then require(script.Parent:WaitForChild("CosmeticTestStyles")) else nil
local cosmeticTiles = {}
local cosmeticCursor = nil
local cosmeticStyle = nil
local cosmeticTime = 0
local lastCosmeticUpdate = 0

local readu16, readu8, readu32 = buffer.readu16, buffer.readu8, buffer.readu32
local writeu32 = buffer.writeu32
local floor, min, max = math.floor, math.min, math.max

local FALLOUT_OWNER = 65535
local CELL = 8 -- tiles per cell side (repaint unit)
local MAX_IMAGE = 1024 -- EditableImage size limit per side
local MAX_PIXELS = 4_200_000 -- cap on total map pixels (memory), lowers S on huge maps
local OPAQUE = 4278190080 -- alpha 255 in the top byte

-- render-settings.json mapOverlay / affiliation / spawnOverlay
local HIGHLIGHT_BRIGHTEN = 0.25 -- border mixed toward white
local HIGHLIGHT_FILL = 0.15 -- fill contrast boost
local DEFENSE_DARKEN = 0.85 -- fill on tiles covered by an own defence post
local DEFENSE_CHECKER = 0.7 -- every other border pixel on covered tiles
local TRAIL_ALPHA = 0.588
local ALT_FILL_ALPHA = 0.15
local REL_SELF = { 0, 255, 0 }
local REL_ALLY = { 255, 255, 0 }
local REL_NEUTRAL = { 128, 128, 128 }
local CONTRAST_ALLY = { 80, 170, 255 } -- colour-blind mode ally border (Frontlines addition)
-- Enemy spawn halo: OpenFront highlights unowned tiles within 9 of a spawn (spawn radius 4).
local SPAWN_HALO = Config.SPAWN_RADIUS * 9 / 4

local ctx: any = nil
local map: any = nil
local W, H, SIZE = 0, 0, 0
local S = 0
local CX, CY = 0, 0 -- cells
local chunkCols, chunkRows, chunkTW, chunkTH = 0, 0, 0, 0
local chunks: { any } = {}
local failed = false
local errorLabel: TextLabel? = nil

local base = buffer.create(0) -- per-tile terrain colour (packed RGBA)
local cover = buffer.create(0) -- per-tile owner of a finished defence post covering it
local trailOwner = buffer.create(0) -- per-tile owner of the last wake stamped on it
local trailMask = buffer.create(0) -- per-tile wake directions (8 bits, see DIRS)
local trailCount = buffer.create(0) -- per-tile number of live wakes
local cellFlag = buffer.create(0) -- 1 = cell queued for a full repaint
local queue: { number } = {} -- dirty cells (big areas: full repaints, highlight, defence coverage)
local qHead = 1
local tileFlag = buffer.create(0) -- 1 = tile queued
local tileQueue: { number } = {} -- dirty tiles (owner changes and their neighbours)
local tHead = 1
local lowQueue: { number } = {} -- dirty cells painted after the tiles (hover highlight)
local lHead = 1
-- Dirty cells / tiles outside the view wait here (still flagged) and are painted right after the
-- work in view, in the same frame budget.
local offCells: { number } = {}
local ocHead = 1
local offTiles: { number } = {}
local otHead = 1
-- The map area on screen in tiles, with a margin (computed each frame in step).
local VIEW_MARGIN = 2 * CELL
local viewValid = false
local viewX0, viewY0, viewX1, viewY1 = 0, 0, -1, -1
-- Hover highlight scan (see applyHighlight)
local hlOwners: { [number]: boolean } = {} -- owners whose cells still need the repaint
local hlPhase = 0 -- 0 idle, 1 cells in view, 2 the rest of the map
local hlCursor = 0
local hlX0, hlY0, hlX1, hlY1 = 0, 0, -1, -1 -- cell rectangle scanned in phase 1

local highlight = 0
local wantHighlight, wantSince = 0, 0 -- hovered owner waiting to be applied (see setHighlight)
local altView = false
local spawnAt: { [number]: any } = {}
local spawnKey = ""
local lastSpawnCheck = 0
local lastStructures: any = nil
local trails: { [number]: any } = {}
local railBuf: buffer? = nil -- UnitFx rail types per tile
local railPaint: any = nil
-- RailroadPass: rails fade in between zoom 1 and 3 screen px per full-size tile
-- (render-settings railMinZoom 3, railFadeRange 2). The map image can't fade per pixel, so rails
-- appear at the middle of that range: 2 px per full-size tile = 2 * LINEAR_SCALE px per our tile.
local RAIL_SHOW_ZOOM = 2 * Config.LINEAR_SCALE
local railsShown = false
-- Capture visuals run between server batches; authoritative owners remain immediate.
local captureSteps: { [number]: any } = {}
local captureStepCount = 0
local captureNow = 0
local CAPTURE_SECONDS = 0.075
local MAX_CAPTURE_STEPS = 1024
-- Captures are cosmetic: none in Low detail (1 px tiles), offscreen, or while the tile repaint
-- backlog is already longer than this (the map would show them late anyway).
local CAPTURE_BACKLOG_LIMIT = 2000
local capturePool: { any } = {} -- finished capture records (and their S x S pixel buffers) to reuse
-- Upload unit: one cell row (strip) by BLOCK_CELLS cells, so far-apart changes in one strip upload
-- separately instead of everything between them.
local BLOCK_CELLS = 8

local lastUpload = 0
local uploadPending = false
local lastResample: Enum.ResamplerMode? = nil

local function pack(r: number, g: number, b: number): number
	return floor(r + 0.5) + floor(g + 0.5) * 256 + floor(b + 0.5) * 65536 + OPAQUE
end

local function unpackRGB(c: number): (number, number, number)
	return c % 256, (c // 256) % 256, (c // 65536) % 256
end

-- Dirty cells
local function markCell(ci: number)
	if readu8(cellFlag, ci) == 0 then
		buffer.writeu8(cellFlag, ci, 1)
		queue[#queue + 1] = ci
	end
end

local function markRect(x0: number, y0: number, x1: number, y1: number)
	if CX == 0 then
		return
	end
	local cx0, cy0 = max(0, x0) // CELL, max(0, y0) // CELL
	local cx1, cy1 = min(W - 1, x1) // CELL, min(H - 1, y1) // CELL
	for cy = cy0, cy1 do
		for cx = cx0, cx1 do
			markCell(cy * CX + cx)
		end
	end
end

local function markOne(t: number)
	if readu8(tileFlag, t) == 0 then
		buffer.writeu8(tileFlag, t, 1)
		tileQueue[#tileQueue + 1] = t
	end
end

-- Tile t changed: repaint it and the neighbours whose border pixels depend on it.
function MapRender.markTile(t: number)
	if CX == 0 or t < 0 or t >= SIZE then
		return
	end
	local x, y = t % W, t // W
	local r = if S == 1 and Settings.values.borderContrast then 2 else 1
	for yy = math.max(0, y - r), math.min(H - 1, y + r) do
		local row = yy * W
		for xx = math.max(0, x - r), math.min(W - 1, x + r) do
			markOne(row + xx)
		end
	end
end

-- Everything besides tile owners that changes how tiles look; markAll() skips the (costly) full
-- repaint when none of it changed, e.g. a roster update that only added stats.
local lastSignature = ""
local sigParts: { string } = {}
local function signature(): string
	table.clear(sigParts)
	sigParts[1] = string.format("#%s|%s|%s|%s", tostring(ctx.getMyId()), tostring(Settings.values.terrainShading), tostring(Settings.values.borderContrast), tostring(altView))
	for id, p in ctx.roster do
		local c = p.paint
		sigParts[#sigParts + 1] = if c
			then string.format("%s:%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f:%s", tostring(id), c[1], c[2], c[3], c[4], c[5], c[6], p.r or 0, p.g or 0, p.b or 0, tostring(ContextMenu.isAlly(id)))
			else string.format("%s:-:%s", tostring(id), tostring(ContextMenu.isAlly(id)))
	end
	table.sort(sigParts)
	return table.concat(sigParts, ";")
end

local function markEverything()
	if CX == 0 then
		return
	end
	lastSignature = signature()
	buffer.fill(cellFlag, 0, 0)
	table.clear(queue)
	qHead = 1
	table.clear(lowQueue)
	lHead = 1
	table.clear(offCells)
	ocHead = 1
	for ci = 0, CX * CY - 1 do
		markCell(ci)
	end
end

function MapRender.markAll()
	if CX == 0 or signature() == lastSignature then
		return
	end
	markEverything()
end

-- Forces the next markAll() to repaint (owners were replaced wholesale, e.g. a new round).
local function clearCaptures()
	for _, c in captureSteps do
		capturePool[#capturePool + 1] = c
	end
	table.clear(captureSteps)
	captureStepCount = 0
end

function MapRender.invalidate()
	clearCaptures()
	lastSignature = ""
end

-- Tile painting
-- Wake directions: bit -> (dx, dy)
local DIRS = { { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 } }

local function blendPixel(buf: buffer, off: number, r: number, g: number, b: number, a: number)
	local c = readu32(buf, off)
	local br, bg, bb = unpackRGB(c)
	writeu32(buf, off, pack(br + (r - br) * a, bg + (g - bg) * a, bb + (b - bb) * a))
end

-- Draws the wake line through the tile centre toward each connected neighbour.
local function paintTrail(t: number, buf: buffer, off: number, stride: number)
	local o = readu16(trailOwner, t * 2)
	local p = ctx.roster[o]
	local r, g, b = 200, 200, 200
	if p and p.r then
		r, g, b = p.r, p.g, p.b
	end
	if altView then
		local rel = if o == ctx.getMyId() then REL_SELF elseif ContextMenu.isAlly(o) then REL_ALLY else REL_NEUTRAL
		r, g, b = rel[1], rel[2], rel[3]
	end
	if S == 1 then
		blendPixel(buf, off, r, g, b, TRAIL_ALPHA)
		return
	end
	local c = S // 2
	blendPixel(buf, off + c * stride + c * 4, r, g, b, TRAIL_ALPHA)
	local mask = readu8(trailMask, t)
	for bit = 0, 7 do
		if bit32.btest(mask, bit32.lshift(1, bit)) then
			local d = DIRS[bit + 1]
			for k = 1, S do
				local i, j = c + d[1] * k, c + d[2] * k
				if i < 0 or j < 0 or i >= S or j >= S then
					break
				end
				blendPixel(buf, off + j * stride + i * 4, r, g, b, TRAIL_ALPHA)
			end
		end
	end
end

local function contrastBoost(v: number): number
	return math.clamp((v - 127.5) * (1 + HIGHLIGHT_FILL) + 127.5, 0, 255)
end

-- Rounded corners (Frontlines addition): our tiles are 4 x 4 OpenFront tiles, so plain square
-- blocks make spawns, coasts and fronts look boxy next to OpenFront's fine pixel edges. A tile
-- corner whose two side neighbours share an owner other than the tile's own goes to that owner:
-- its border colour when owned (the line cuts the corner diagonally), the bare ground when unowned
-- (a convex corner of territory is shaved). Territory edges become 45-degree steps, like OpenFront's.
local function borderRGB(q: number): number
	local myId = ctx.getMyId()
	local r, g, b
	if altView then
		local rel = if q == myId then REL_SELF elseif ContextMenu.isAlly(q) then REL_ALLY else REL_NEUTRAL
		return pack(rel[1], rel[2], rel[3])
	end
	if q == myId then
		r, g, b = Theme.FOCUSED_BORDER[1], Theme.FOCUSED_BORDER[2], Theme.FOCUSED_BORDER[3]
	else
		local p = ctx.roster[q]
		local c = if p and p.paint then p.paint else Theme.DEFAULT_PAINT
		r, g, b = c[4], c[5], c[6]
	end
	if q == highlight then
		r, g, b = r + (255 - r) * HIGHLIGHT_BRIGHTEN, g + (255 - g) * HIGHLIGHT_BRIGHTEN, b + (255 - b) * HIGHLIGHT_BRIGHTEN
	end
	if Settings.values.borderContrast and ContextMenu.isAlly(q) then
		r, g, b = CONTRAST_ALLY[1], CONTRAST_ALLY[2], CONTRAST_ALLY[3]
	end
	return pack(r, g, b)
end

local function cornerColour(o: number, a: number, t: number, px: number, py: number): number?
	if a ~= 0 and a ~= FALLOUT_OWNER then
		return borderRGB(a)
	elseif o == 0 then
		return nil
	elseif a == 0 then
		return readu32(base, t * 4)
	end
	local r, g, b = Theme.falloutRGB(px, py)
	return r + g * 256 + b * 65536 + OPAQUE
end

local function roundCorners(o: number, t: number, x: number, y: number, nN: number, nS: number, nW: number, nE: number, buf: buffer, off: number, stride: number)
	local SS = S
	if SS < 2 then
		return
	end
	local last = SS - 1
	local gx, gy = x * SS, y * SS
	if nN ~= o then
		if nN == nW then
			local c = cornerColour(o, nN, t, gx, gy)
			if c then
				writeu32(buf, off, c)
			end
		end
		if nN == nE then
			local c = cornerColour(o, nN, t, gx + last, gy)
			if c then
				writeu32(buf, off + last * 4, c)
			end
		end
	end
	if nS ~= o then
		if nS == nW then
			local c = cornerColour(o, nS, t, gx, gy + last)
			if c then
				writeu32(buf, off + last * stride, c)
			end
		end
		if nS == nE then
			local c = cornerColour(o, nS, t, gx + last, gy + last)
			if c then
				writeu32(buf, off + last * stride + last * 4, c)
			end
		end
	end
end

-- Paints tile t (at x, y) into buf; off = byte offset of the tile's top-left pixel.
local function drawTile(owners: buffer, t: number, x: number, y: number, buf: buffer, off: number, stride: number)
	local o = readu16(owners, t * 2)
	if CosmeticTestStyles then
		if o~=0 and o==ctx.getMyId() then cosmeticTiles[t]=true else cosmeticTiles[t]=nil end
	end
	local SS = S
	if o == 0 then
		local col = readu32(base, t * 4)
		local halo = spawnAt[t]
		if halo then
			-- Enemy spawn halo (only on unowned tiles), round at pixel resolution.
			for j = 0, SS - 1 do
				local py = y + (j + 0.5) / SS - halo.y
				local row = off + j * stride
				for i = 0, SS - 1 do
					local px = x + (i + 0.5) / SS - halo.x
					writeu32(buf, row + i * 4, if px * px + py * py <= halo.r2 then halo.col else col)
				end
			end
		else
			for j = 0, SS - 1 do
				local row = off + j * stride
				for i = 0, SS - 1 do
					writeu32(buf, row + i * 4, col)
				end
			end
		end
		if SS > 1 then
			local nN = if y > 0 then readu16(owners, (t - W) * 2) else 0
			local nS = if y < H - 1 then readu16(owners, (t + W) * 2) else 0
			if nN ~= 0 or nS ~= 0 then
				local nW = if x > 0 then readu16(owners, (t - 1) * 2) else 0
				local nE = if x < W - 1 then readu16(owners, (t + 1) * 2) else 0
				roundCorners(0, t, x, y, nN, nS, nW, nE, buf, off, stride)
			end
		end
		if readu8(trailCount, t) > 0 then
			paintTrail(t, buf, off, stride)
		end
		return
	end
	if o == FALLOUT_OWNER then
		-- Stale nuke ground with per-pixel noise (OpenFront's noise is per tile, 4x finer than ours).
		for j = 0, SS - 1 do
			local row = off + j * stride
			for i = 0, SS - 1 do
				local r, g, b = Theme.falloutRGB(x * SS + i, y * SS + j)
				writeu32(buf, row + i * 4, r + g * 256 + b * 65536 + OPAQUE)
			end
		end
		if SS > 1 then
			roundCorners(o, t, x, y,
				if y > 0 then readu16(owners, (t - W) * 2) else 0,
				if y < H - 1 then readu16(owners, (t + W) * 2) else 0,
				if x > 0 then readu16(owners, (t - 1) * 2) else 0,
				if x < W - 1 then readu16(owners, (t + 1) * 2) else 0,
				buf, off, stride)
		end
		return
	end

	-- Neighbours (outside the map counts as a different owner, like OpenFront).
	local nN = if y > 0 then readu16(owners, (t - W) * 2) else 0
	local nS = if y < H - 1 then readu16(owners, (t + W) * 2) else 0
	local nW = if x > 0 then readu16(owners, (t - 1) * 2) else 0
	local nE = if x < W - 1 then readu16(owners, (t + 1) * 2) else 0
	local bN, bS, bW, bE = nN ~= o, nS ~= o, nW ~= o, nE ~= o
	-- Inside corners are closed by the diagonal neighbour, which hands us its corner pixel
	-- (roundCorners), so no corner pixels here.
	local cNW, cNE, cSW, cSE = false, false, false, false
	local myId = ctx.getMyId()
	local contrast = Settings.values.borderContrast
	if SS == 1 and contrast and o == myId and not (bN or bS or bW or bE) then
		-- Colour-blind mode at 1 px per tile: our border is two tiles thick.
		if Settings.nearOtherOwner(map, owners, t, o) then
			bN = true
		end
	end
	local edge = bN or bS or bW or bE or cNW or cNE or cSW or cSE

	local p = ctx.roster[o]
	local c = if p and p.paint then p.paint else Theme.DEFAULT_PAINT
	local hl = o == highlight
	local defended = readu16(cover, t * 2) == o

	-- Fill: territory colour over the terrain (OpenFront territoryAlpha), or the alt-view relation tint.
	local br, bg, bb = unpackRGB(readu32(base, t * 4))
	local fr, fg, fb, a
	local rel = nil
	if altView then
		rel = if o == myId then REL_SELF elseif ContextMenu.isAlly(o) then REL_ALLY else REL_NEUTRAL
		fr, fg, fb, a = rel[1], rel[2], rel[3], ALT_FILL_ALPHA
	else
		fr, fg, fb, a = c[1], c[2], c[3], Theme.TERRITORY_ALPHA
		if CosmeticTestStyles and cosmeticStyle and o==myId then
			local stats=p and p.stats
			local radius=math.max(32,math.sqrt(stats and stats.tiles or 1)*2)
			local u=.5+(x-(stats and stats.cx or W*.5))/radius
			local v=.53+(y-(stats and stats.cy or H*.5))/radius
			fr,fg,fb=CosmeticTestStyles.sample(cosmeticStyle,u,v,cosmeticTime)
			a=.94
		end
		if hl then
			fr, fg, fb = contrastBoost(fr), contrastBoost(fg), contrastBoost(fb)
		end
		if defended then
			fr, fg, fb = fr * DEFENSE_DARKEN, fg * DEFENSE_DARKEN, fb * DEFENSE_DARKEN
		end
	end
	local fill = pack(br + (fr - br) * a, bg + (fg - bg) * a, bb + (fb - bb) * a)

	if not edge then
		for j = 0, SS - 1 do
			local row = off + j * stride
			for i = 0, SS - 1 do
				writeu32(buf, row + i * 4, fill)
			end
		end
		if readu8(trailCount, t) > 0 then
			paintTrail(t, buf, off, stride)
		end
		return
	end

	-- Border colour (OpenFront border-stamp: highlight, then relation tint, then defence checker).
	local r, g, b
	if rel then
		r, g, b = rel[1], rel[2], rel[3]
	else
		if o == myId then
			r, g, b = Theme.FOCUSED_BORDER[1], Theme.FOCUSED_BORDER[2], Theme.FOCUSED_BORDER[3]
		else
			r, g, b = c[4], c[5], c[6]
		end
		if hl then
			r, g, b = r + (255 - r) * HIGHLIGHT_BRIGHTEN, g + (255 - g) * HIGHLIGHT_BRIGHTEN, b + (255 - b) * HIGHLIGHT_BRIGHTEN
		end
		if contrast and ContextMenu.isAlly(o) then
			r, g, b = CONTRAST_ALLY[1], CONTRAST_ALLY[2], CONTRAST_ALLY[3]
		else
			local friendly = false
			for k = 1, 4 do
				local q = if k == 1 then nN elseif k == 2 then nS elseif k == 3 then nW else nE
				if q ~= o and q ~= 0 and q ~= FALLOUT_OWNER and ((o == myId and ContextMenu.isAlly(q)) or (q == myId and ContextMenu.isAlly(o))) then
					friendly = true
					break
				end
			end
			if friendly then
				local k, tint = Theme.FRIENDLY_TINT_RATIO, Theme.FRIENDLY_TINT
				r, g, b = r + (tint[1] - r) * k, g + (tint[2] - g) * k, b + (tint[3] - b) * k
			end
		end
	end
	local border = pack(r, g, b)
	local borderDark = if defended and not rel then pack(r * DEFENSE_CHECKER, g * DEFENSE_CHECKER, b * DEFENSE_CHECKER) else border

	-- Border band width in pixels: 1, thicker for the hovered player and (colour-blind mode) for us.
	local bw = 1
	if SS >= 3 and (hl or (contrast and o == myId)) then
		bw = 2
	elseif SS == 2 and contrast and o == myId then
		bw = 2
	end
	local gx, gy = x * SS, y * SS
	for j = 0, SS - 1 do
		local row = off + j * stride
		local top, bot = j < bw, j >= SS - bw
		for i = 0, SS - 1 do
			local left, right = i < bw, i >= SS - bw
			local isB = (bN and top) or (bS and bot) or (bW and left) or (bE and right)
				or (cNW and top and left) or (cNE and top and right) or (cSW and bot and left) or (cSE and bot and right)
			local col = fill
			if isB then
				col = if (gx + i + gy + j) % 2 == 1 then borderDark else border
			end
			writeu32(buf, row + i * 4, col)
		end
	end
	roundCorners(o, t, x, y, nN, nS, nW, nE, buf, off, stride)
	if readu8(trailCount, t) > 0 then
		paintTrail(t, buf, off, stride)
	end
end

-- Snapshot the currently displayed block before its authoritative owner changes.
function MapRender.captureTile(t: number, nextOwner: number)
	if not ctx or failed or S == 0 or t < 0 or t >= SIZE then return end
	local x, y = t % W, t // W
	local old = captureSteps[t]
	-- Cosmetic only: skip it in Low detail / 1 px tiles, offscreen, and when repaints are behind.
	if ctx.getPhase() ~= "Play" or nextOwner == 0 or nextOwner == FALLOUT_OWNER
		or S < 2 or Settings.values.lowDetail
		or (viewValid and (x < viewX0 or x > viewX1 or y < viewY0 or y > viewY1))
		or #tileQueue - tHead + 1 > CAPTURE_BACKLOG_LIMIT then
		if old then
			captureSteps[t] = nil
			captureStepCount -= 1
			capturePool[#capturePool + 1] = old
		end
		return
	end
	local owners = ctx.getOwners()
	local previous = readu16(owners, t * 2)
	if previous == nextOwner or previous == FALLOUT_OWNER then return end
	if captureStepCount >= MAX_CAPTURE_STEPS and not old then return end
	local ch = chunks[(y // chunkTH) * chunkCols + x // chunkTW + 1]
	if not ch then return end
	local rec = old or table.remove(capturePool) or {}
	local from = rec.from
	if not from or buffer.len(from) ~= S * S * 4 then
		from = buffer.create(S * S * 4)
	end
	local stride = ch.pw * 4
	local off = (y - ch.y0) * S * stride + (x - ch.x0) * S * 4
	for j = 0, S - 1 do buffer.copy(from, j * S * 4, ch.buf, off + j * stride, S * 4) end
	-- Enter from an existing friendly edge; row order varies without colour blending.
	local dir = if x > 0 and readu16(owners, (t - 1) * 2) == nextOwner then 1
		elseif x < W - 1 and readu16(owners, (t + 1) * 2) == nextOwner then 2
		elseif y > 0 and readu16(owners, (t - W) * 2) == nextOwner then 3
		else 4
	if not old then captureStepCount += 1 end
	rec.from, rec.dir, rec.reverse = from, dir, (x + y) % 2 == 1
	rec.start = os.clock() + ((t * 17) % 11) * 0.001
	captureSteps[t] = rec
end

local function paintTile(owners: buffer, t: number, x: number, y: number, buf: buffer, off: number, stride: number)
	drawTile(owners, t, x, y, buf, off, stride)
	local c = captureSteps[t]
	if not c then return end
	local progress = math.clamp((captureNow - c.start) / CAPTURE_SECONDS, 0, 1)
	for j = 0, S - 1 do
		for i = 0, S - 1 do
			local depth = if c.dir == 1 then i elseif c.dir == 2 then S - 1 - i
				elseif c.dir == 3 then j else S - 1 - j
			local across = if c.dir <= 2 then j else i
			if c.reverse then across = S - 1 - across end
			if progress < (depth * S + across + 0.5) / (S * S) then
				writeu32(buf, off + j * stride + i * 4, readu32(c.from, (j * S + i) * 4))
			end
		end
	end
end

local function paintCell(owners: buffer, ci: number)
	local cx, cy = ci % CX, ci // CX
	local x0, y0 = cx * CELL, cy * CELL
	local x1, y1 = min(x0 + CELL, W) - 1, min(y0 + CELL, H) - 1
	local ch = chunks[(y0 // chunkTH) * chunkCols + x0 // chunkTW + 1]
	if not ch then
		return
	end
	local buf, stride = ch.buf, ch.pw * 4
	local SS = S
	for y = y0, y1 do
		local rowOff = (y - ch.y0) * SS * stride
		local t = y * W + x0
		for x = x0, x1 do
			paintTile(owners, t, x, y, buf, rowOff + (x - ch.x0) * SS * 4, stride)
			if railsShown and railBuf and t < buffer.len(railBuf) and readu8(railBuf, t) ~= 0 then
				railPaint(owners, t, x, y, buf, rowOff + (x - ch.x0) * SS * 4, stride, SS)
			end
			t += 1
		end
	end
	local px0, px1 = (x0 - ch.x0) * SS, (x1 + 1 - ch.x0) * SS - 1
	local k = ((y0 - ch.y0) // CELL) * ch.nb + px0 // ch.blockPx -- strip x block (a cell never spans two blocks)
	local pmin = ch.pmin[k]
	if pmin == nil or px0 < pmin then
		ch.pmin[k] = px0
	end
	local pmax = ch.pmax[k]
	if pmax == nil or px1 > pmax then
		ch.pmax[k] = px1
	end
	ch.anyPending = true
end

local function paintOne(owners: buffer, t: number)
	local x, y = t % W, t // W
	local ch = chunks[(y // chunkTH) * chunkCols + x // chunkTW + 1]
	if not ch then
		return
	end
	local SS = S
	local stride = ch.pw * 4
	local lx = x - ch.x0
	paintTile(owners, t, x, y, ch.buf, (y - ch.y0) * SS * stride + lx * SS * 4, stride)
	if railsShown and railBuf and t < buffer.len(railBuf) and readu8(railBuf, t) ~= 0 then
		railPaint(owners, t, x, y, ch.buf, (y - ch.y0) * SS * stride + lx * SS * 4, stride, SS)
	end
	local px0 = lx * SS
	local k = ((y - ch.y0) // CELL) * ch.nb + px0 // ch.blockPx
	local pmin = ch.pmin[k]
	if pmin == nil or px0 < pmin then
		ch.pmin[k] = px0
	end
	local pmax = ch.pmax[k]
	if pmax == nil or px0 + SS - 1 > pmax then
		ch.pmax[k] = px0 + SS - 1
	end
	ch.anyPending = true
end

-- Chunk images
local scratch: { [number]: buffer } = {}
local scratchCount = 0
local function scratchOf(len: number): buffer
	local b = scratch[len]
	if not b then
		if scratchCount > 12 then
			table.clear(scratch)
			scratchCount = 0
		end
		b = buffer.create(len)
		scratch[len] = b
		scratchCount += 1
	end
	return b
end

local function showError()
	if errorLabel or not ctx.holder then
		return
	end
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.fromOffset(600, 80)
	l.BackgroundTransparency = 1
	l.TextWrapped = true
	l.TextSize = 18
	l.TextColor3 = Color3.new(1, 1, 1)
	l.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	l.Text = "Map rendering is disabled. In Studio: Game Settings > Security > enable 'Allow Mesh / Image APIs'."
	l.Parent = ctx.holder
	errorLabel = l
end

local function destroyChunks()
	for _, ch in chunks do
		ch.label:Destroy()
		if ch.img then
			ch.img:Destroy()
		end
	end
	table.clear(chunks)
	table.clear(scratch)
	scratchCount = 0
end

local function wantedScale(): number
	local s = if Settings.values.lowDetail then 1 elseif DeviceLayout.state.profile == "phone" then 2 else 3
	while s > 1 and W * H * s * s > MAX_PIXELS do
		s -= 1
	end
	return s
end

-- Builds the chunk grid at scale s. Returns false if an EditableImage couldn't be created.
local function buildChunks(s: number): boolean
	destroyChunks()
	S = s
	local cols = math.ceil(W * s / MAX_IMAGE)
	local tw
	repeat
		tw = math.ceil(math.ceil(W / cols) / CELL) * CELL
		if tw * s > MAX_IMAGE then
			cols += 1
		end
	until tw * s <= MAX_IMAGE
	local rows = math.ceil(H * s / MAX_IMAGE)
	local th
	repeat
		th = math.ceil(math.ceil(H / rows) / CELL) * CELL
		if th * s > MAX_IMAGE then
			rows += 1
		end
	until th * s <= MAX_IMAGE
	chunkTW, chunkTH = tw, th
	chunkCols, chunkRows = math.ceil(W / tw), math.ceil(H / th)
	for r = 0, chunkRows - 1 do
		for c = 0, chunkCols - 1 do
			local x0, y0 = c * tw, r * th
			local w, h = min(tw, W - x0), min(th, H - y0)
			local ok, img = pcall(function()
				return AssetService:CreateEditableImage({ Size = Vector2.new(w * s, h * s) })
			end)
			if not ok or not img then
				warn("[War Front] EditableImage unavailable at " .. s .. "x: " .. tostring(img))
				destroyChunks()
				return false
			end
			local label = Instance.new("ImageLabel")
			label.Name = "MapChunk"
			label.BackgroundTransparency = 1
			label.BorderSizePixel = 0
			label.ResampleMode = Enum.ResamplerMode.Pixelated
			label.Position = UDim2.fromScale(x0 / W, y0 / H)
			-- +1 px overlap so rounding never leaves a seam between chunks.
			label.Size = UDim2.new(w / W, if x0 + w < W then 1 else 0, h / H, if y0 + h < H then 1 else 0)
			label.ZIndex = 0 -- below MapFx glows (1) and the marker / label layers (2+)
			label.ImageContent = Content.fromObject(img)
			label.Parent = ctx.parent
			chunks[#chunks + 1] = {
				img = img,
				label = label,
				x0 = x0,
				y0 = y0,
				pw = w * s,
				ph = h * s,
				buf = buffer.create(w * s * h * s * 4),
				-- upload blocks: strip (one cell row) x BLOCK_CELLS cells; key = strip * nb + block
				blockPx = BLOCK_CELLS * CELL * s,
				nb = math.ceil(w / (BLOCK_CELLS * CELL)),
				pmin = {}, -- block key -> dirty pixel column range inside that block
				pmax = {},
				anyPending = false,
			}
		end
	end
	lastResample = nil
	return true
end

-- Is this tile rectangle (inclusive) in the current view? Everything counts as visible until the
-- first view is known.
local function inView(x0: number, y0: number, x1: number, y1: number): boolean
	return not viewValid or not (x1 < viewX0 or x0 > viewX1 or y1 < viewY0 or y0 > viewY1)
end

-- Uploads dirty blocks (one cell row by BLOCK_CELLS cells) of every chunk: blocks in view first,
-- then the rest while the budget lasts. The budget is checked before each write, so one call
-- does at most one write past it. Returns true when nothing is left to upload.
local uploadCursor = 1
local function upload(budget: number?)
	local started = os.clock()
	local count = #chunks
	if count == 0 then return true end
	local first = math.clamp(uploadCursor, 1, count)
	local stripH = CELL * S
	local wrote = 0
	for pass = 1, 2 do
		for offset = 0, count - 1 do
			local index = (first + offset - 1) % count + 1
			local ch = chunks[index]
			if ch.anyPending then
				local stride = ch.pw * 4
				local nb, blockPx = ch.nb, ch.blockPx
				local blockTiles = blockPx // S
				for key, px0 in ch.pmin do
					local k, b = key // nb, key % nb
					local tx0, ty0 = ch.x0 + b * blockTiles, ch.y0 + k * CELL
					if pass == 2 or inView(tx0, ty0, tx0 + blockTiles - 1, ty0 + CELL - 1) then
						if budget and wrote > 0 and os.clock() - started >= budget then
							uploadCursor = index
							return false
						end
						local px1 = ch.pmax[key]
						local py0 = k * stripH
						local rows = min(stripH, ch.ph - py0)
						local w = px1 - px0 + 1
						if rows > 0 and w > 0 then
							local rowLen = w * 4
							local out = scratchOf(rows * rowLen)
							for j = 0, rows - 1 do
								buffer.copy(out, j * rowLen, ch.buf, (py0 + j) * stride + px0 * 4, rowLen)
							end
							local ok, err = pcall(function()
								ch.img:WritePixelsBuffer(Vector2.new(px0, py0), Vector2.new(w, rows), out)
							end)
							if not ok then
								warn("[War Front] Map can't be drawn: " .. tostring(err))
								failed = true
								showError()
								return false
							end
							wrote += 1
						end
						ch.pmin[key], ch.pmax[key] = nil, nil
					end
				end
				ch.anyPending = next(ch.pmin) ~= nil
			end
		end
	end
	uploadCursor = 1
	return true
end

-- Paints from a cell list (from head), deferring cells outside the view to offCells (unless
-- `anywhere`). Returns the new head and whether the budget ran out.
local function drainCells(owners: buffer, list: { number }, head: number, t0: number, budget: number, anywhere: boolean): (number, boolean)
	local n = #list
	local i = head
	while i <= n do
		local ci = list[i]
		i += 1
		local x0, y0 = (ci % CX) * CELL, (ci // CX) * CELL
		if anywhere or inView(x0, y0, x0 + CELL - 1, y0 + CELL - 1) then
			buffer.writeu8(cellFlag, ci, 0)
			paintCell(owners, ci)
			if os.clock() - t0 >= budget then
				return i, true
			end
		else
			offCells[#offCells + 1] = ci -- stays flagged: painted once in view or when idle
		end
	end
	return i, false
end

local function drainTiles(owners: buffer, list: { number }, head: number, t0: number, budget: number, anywhere: boolean): (number, boolean)
	local n = #list
	local i = head
	while i <= n do
		local t = list[i]
		i += 1
		if anywhere or inView(t % W, t // W, t % W, t // W) then
			buffer.writeu8(tileFlag, t, 0)
			paintOne(owners, t)
		else
			offTiles[#offTiles + 1] = t -- stays flagged
		end
		if i % 32 == 0 and os.clock() - t0 >= budget then
			return i, true
		end
	end
	return i, false
end

-- Paints dirty cells, then dirty tiles, then highlight cells, for up to `budget` seconds; work
-- outside the view is deferred and done after that while the budget lasts.
local function drain(budget: number)
	local owners = ctx.getOwners()
	local t0 = os.clock()
	local out
	qHead, out = drainCells(owners, queue, qHead, t0, budget, false)
	if qHead > #queue then
		table.clear(queue)
		qHead = 1
	end
	if out then return end
	tHead, out = drainTiles(owners, tileQueue, tHead, t0, budget, false)
	if tHead > #tileQueue then
		table.clear(tileQueue)
		tHead = 1
	end
	if out then return end
	lHead, out = drainCells(owners, lowQueue, lHead, t0, budget, false)
	if lHead > #lowQueue then
		table.clear(lowQueue)
		lHead = 1
	end
	if out then return end
	-- Then the offscreen work, with the rest of the budget (the whole map stays current, so
	-- zooming out never shows stale areas catching up).
	ocHead, out = drainCells(owners, offCells, ocHead, t0, budget, true)
	if ocHead > #offCells then
		table.clear(offCells)
		ocHead = 1
	end
	if out then return end
	otHead = drainTiles(owners, offTiles, otHead, t0, budget, true)
	if otHead > #offTiles then
		table.clear(offTiles)
		otHead = 1
	end
end

local function rebuild()
	uploadPending = false
	uploadCursor = 1
	clearCaptures()
	table.clear(capturePool) -- the tile size may change
	table.clear(offTiles)
	otHead = 1
	hlPhase = 0
	table.clear(hlOwners)
	failed = false
	local s = wantedScale()
	while not buildChunks(s) do
		if s <= 1 then
			failed = true
			showError()
			return
		end
		s -= 1
	end
	if errorLabel then
		errorLabel:Destroy()
		errorLabel = nil
	end
	CX, CY = math.ceil(W / CELL), math.ceil(H / CELL)
	cellFlag = buffer.create(CX * CY)
	table.clear(queue)
	qHead = 1
	tileFlag = buffer.create(SIZE)
	table.clear(tileQueue)
	tHead = 1
	markEverything()
	-- First paint in one go so the map never shows up half drawn.
	drain(math.huge)
	upload()
end

-- Overlays computed from game state: defence coverage, spawn halos
local coverPosts: { [number]: boolean } = {} -- key tile * 65536 + owner of each covering post

local function refreshCoverage()
	local list = ctx.getStructures()
	if list == lastStructures then
		return
	end
	lastStructures = list
	local r = Config.DEFENSE_RADIUS
	local ri = math.ceil(r)
	local r2 = r * r
	local posts: { [number]: boolean } = {}
	for _, s in list do
		if s[2] == "DefensePost" and s[5] == true and s[3] < SIZE then
			posts[s[3] * 65536 + s[4]] = true
		end
	end
	local changed = false
	for k in posts do
		if not coverPosts[k] then
			changed = true
			local t = k // 65536
			markRect(t % W - ri, t // W - ri, t % W + ri, t // W + ri)
		end
	end
	for k in coverPosts do
		if not posts[k] then
			changed = true
			local t = k // 65536
			markRect(t % W - ri, t // W - ri, t % W + ri, t // W + ri)
		end
	end
	coverPosts = posts
	if not changed then
		return
	end
	buffer.fill(cover, 0, 0)
	for k in posts do
		local t, o = k // 65536, k % 65536
		local cx, cy = t % W, t // W
		for dy = -ri, ri do
			local y = cy + dy
			if y >= 0 and y < H then
				for dx = -ri, ri do
					local x = cx + dx
					if x >= 0 and x < W and dx * dx + dy * dy <= r2 then
						buffer.writeu16(cover, (y * W + x) * 2, o)
					end
				end
			end
		end
	end
end

local function refreshSpawnHalos()
	local myId = ctx.getMyId()
	local centers = {}
	local key = ""
	if ctx.getPhase() == "Spawn" then
		for id, p in ctx.roster do
			local st = p.stats
			if id ~= myId and p.kind == "Human" and st and st.tiles > 0 and p.r then
				centers[#centers + 1] = { x = st.cx + 0.5, y = st.cy + 0.5, col = pack(p.r, p.g, p.b), id = id }
				key ..= string.format("%d:%.1f,%.1f;", id, st.cx, st.cy)
			end
		end
	end
	if key == spawnKey then
		return
	end
	spawnKey = key
	for t in spawnAt do
		MapRender.markTile(t)
	end
	table.clear(spawnAt)
	local r = SPAWN_HALO
	for _, c in centers do
		c.r2 = r * r
		for y = math.floor(c.y - r), math.floor(c.y + r) do
			for x = math.floor(c.x - r), math.floor(c.x + r) do
				if x >= 0 and y >= 0 and x < W and y < H then
					local t = y * W + x
					spawnAt[t] = c
					MapRender.markTile(t)
				end
			end
		end
	end
end

-- Transport wakes (OpenFront TrailManager: stamped behind the boat, cleared when it's gone)
local function dirBit(a: number, b: number): number?
	local dx, dy = b % W - a % W, b // W - a // W
	for i, d in DIRS do
		if d[1] == dx and d[2] == dy then
			return i - 1
		end
	end
	return nil
end

local function stamp(tr, t: number)
	if not tr.tiles[t] then
		tr.tiles[t] = true
		buffer.writeu8(trailCount, t, min(255, readu8(trailCount, t) + 1))
	end
	buffer.writeu16(trailOwner, t * 2, tr.owner)
	MapRender.markTile(t)
end

local function link(a: number, b: number)
	local bit = dirBit(a, b)
	if bit then
		buffer.writeu8(trailMask, a, bit32.bor(readu8(trailMask, a), bit32.lshift(1, bit)))
		buffer.writeu8(trailMask, b, bit32.bor(readu8(trailMask, b), bit32.lshift(1, (bit + 4) % 8)))
	end
end

function MapRender.addTrail(id: number, path: buffer, start: number, speed: number, owner: number)
	trails[id] = { path = path, n = buffer.len(path) // 4, start = start, speed = speed, owner = owner, idx = -1, tiles = {} }
end

function MapRender.removeTrail(id: number)
	local tr = trails[id]
	if not tr then
		return
	end
	trails[id] = nil
	if buffer.len(trailCount) ~= SIZE * 1 then
		return
	end
	for t in tr.tiles do
		local n = readu8(trailCount, t)
		if n <= 1 then
			buffer.writeu8(trailCount, t, 0)
			buffer.writeu8(trailMask, t, 0)
			buffer.writeu16(trailOwner, t * 2, 0)
		else
			buffer.writeu8(trailCount, t, n - 1)
		end
		MapRender.markTile(t)
	end
end

function MapRender.clearTrails()
	for id in trails do
		MapRender.removeTrail(id)
	end
end

local function stepTrails()
	if next(trails) == nil then
		return
	end
	local st = SimClock.now()
	for _, tr in trails do
		local idx = math.clamp(floor((st - tr.start) * tr.speed), 0, tr.n - 1)
		if idx > tr.idx then
			for i = max(0, tr.idx), idx do
				local t = readu32(tr.path, i * 4)
				if t < SIZE then
					stamp(tr, t)
					if i > 0 then
						local prev = readu32(tr.path, (i - 1) * 4)
						if prev < SIZE then
							link(prev, t)
						end
					end
				end
			end
			tr.idx = idx
		end
	end
end

-- Public API
function MapRender.buildBase()
	local palette = MapStyles.palette(map.name)
	local rgb = if Settings.values.terrainShading then (palette.tileRGB or palette.terrainRGB) else palette.flatTerrainRGB
	local terrain = map.terrain
	base = buffer.create(SIZE * 4)
	for t = 0, SIZE - 1 do
		local r, g, b = rgb(buffer.readu8(terrain, t), t % W, t // W, W, H)
		writeu32(base, t * 4, r + g * 256 + b * 65536 + OPAQUE)
	end
end

-- Water nukes changed the terrain of these tiles (MapUtil.toWater): rebuild the terrain colours
-- around them (water depth changes up to 62 tiles away) and repaint.
function MapRender.repaintTerrain(tiles: { number })
	if not base or #tiles == 0 then
		return
	end
	local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
	for _, t in tiles do
		local x, y = t % W, t // W
		x0, x1 = min(x0, x), max(x1, x)
		y0, y1 = min(y0, y), max(y1, y)
	end
	x0, y0 = max(0, x0 - 64), max(0, y0 - 64)
	x1, y1 = min(W - 1, x1 + 64), min(H - 1, y1 + 64)
	local palette = MapStyles.palette(map.name)
	local rgb = if Settings.values.terrainShading then (palette.tileRGB or palette.terrainRGB) else palette.flatTerrainRGB
	local terrain = map.terrain
	for y = y0, y1 do
		for x = x0, x1 do
			local t = y * W + x
			local r, g, b = rgb(buffer.readu8(terrain, t), x, y, W, H)
			writeu32(base, t * 4, r + g * 256 + b * 65536 + OPAQUE)
		end
	end
	markRect(x0, y0, x1, y1)
end

function MapRender.setMap(m)
	table.clear(cosmeticTiles)
	cosmeticCursor=nil
	map = m
	W, H, SIZE = m.width, m.height, m.size
	cover = buffer.create(SIZE * 2)
	trailOwner = buffer.create(SIZE * 2)
	trailMask = buffer.create(SIZE)
	trailCount = buffer.create(SIZE)
	table.clear(trails)
	table.clear(spawnAt)
	spawnKey = ""
	lastStructures = nil
	coverPosts = {}
	highlight = 0
	wantHighlight = 0
	MapRender.buildBase()
	rebuild()
end

-- Hover changes are applied once the pointer has rested on an owner briefly (applyHighlight scans
-- the map, so sweeping the cursor across many countries shouldn't rescan on every frame).
function MapRender.setHighlight(owner: number)
	if owner == FALLOUT_OWNER then
		owner = 0
	end
	if owner ~= wantHighlight then
		wantHighlight, wantSince = owner, os.clock()
	end
end

-- Hover highlight: the cells holding the old or new highlighted player's tiles are found by a
-- scan spread over frames (cells in view first) and repainted after the tile updates, so a hover
-- never stalls a frame or delays captures. Tiles changing owner under the pointer repaint through
-- markTile with the current highlight.
local function markLow(ci: number)
	if readu8(cellFlag, ci) == 0 then
		buffer.writeu8(cellFlag, ci, 1)
		lowQueue[#lowQueue + 1] = ci
	end
end

local function cellHasOwner(owners: buffer, ci: number): boolean
	local x0, y0 = (ci % CX) * CELL, (ci // CX) * CELL
	local x1, y1 = min(x0 + CELL, W) - 1, min(y0 + CELL, H) - 1
	for pass = 0, 1 do -- even rows first, then odd rows
		for y = y0 + pass, y1, 2 do
			local t = y * W + x0
			for _ = x0, x1 do
				local o = readu16(owners, t * 2)
				if o ~= 0 and hlOwners[o] then
					return true
				end
				t += 1
			end
		end
	end
	return false
end

local function applyHighlight(owner: number)
	if owner == highlight then
		return
	end
	if highlight ~= 0 then
		hlOwners[highlight] = true
	end
	if owner ~= 0 then
		hlOwners[owner] = true
	end
	highlight = owner
	if next(hlOwners) == nil or CX == 0 then
		return
	end
	-- (Re)start the scan with the cells in view.
	if viewValid then
		hlX0, hlY0 = max(0, viewX0 // CELL), max(0, viewY0 // CELL)
		hlX1, hlY1 = min(CX - 1, viewX1 // CELL), min(CY - 1, viewY1 // CELL)
	else
		hlX0, hlY0, hlX1, hlY1 = 0, 0, CX - 1, CY - 1
	end
	hlPhase, hlCursor = 1, 0
end

local function scanHighlight(budget: number)
	if hlPhase == 0 then
		return
	end
	local owners = ctx.getOwners()
	local t0 = os.clock()
	if hlPhase == 1 then
		local rw, rh = hlX1 - hlX0 + 1, hlY1 - hlY0 + 1
		local total = if rw > 0 and rh > 0 then rw * rh else 0
		while hlCursor < total do
			local ci = (hlY0 + hlCursor // rw) * CX + hlX0 + hlCursor % rw
			hlCursor += 1
			if readu8(cellFlag, ci) == 0 and cellHasOwner(owners, ci) then
				markLow(ci)
			end
			if hlCursor % 8 == 0 and os.clock() - t0 >= budget then
				return
			end
		end
		hlPhase, hlCursor = 2, 0
	end
	local total = CX * CY
	while hlCursor < total do
		local ci = hlCursor
		hlCursor += 1
		local cx, cy = ci % CX, ci // CX
		if not (cx >= hlX0 and cx <= hlX1 and cy >= hlY0 and cy <= hlY1) and readu8(cellFlag, ci) == 0 and cellHasOwner(owners, ci) then
			markLow(ci)
		end
		if hlCursor % 8 == 0 and os.clock() - t0 >= budget then
			return
		end
	end
	hlPhase = 0
	table.clear(hlOwners)
end

-- The map area on screen (tiles, plus a margin): work there is painted and uploaded first.
local function updateView()
	local holder = ctx.holder
	local size, pos = ctx.parent.AbsoluteSize, ctx.parent.AbsolutePosition
	if not holder or size.X < 1 or size.Y < 1 then
		viewValid = false
		return
	end
	local hs, hp = holder.AbsoluteSize, holder.AbsolutePosition
	viewX0 = max(0, floor((hp.X - pos.X) / size.X * W) - VIEW_MARGIN)
	viewY0 = max(0, floor((hp.Y - pos.Y) / size.Y * H) - VIEW_MARGIN)
	viewX1 = min(W - 1, floor((hp.X + hs.X - pos.X) / size.X * W) + VIEW_MARGIN)
	viewY1 = min(H - 1, floor((hp.Y + hs.Y - pos.Y) / size.Y * H) + VIEW_MARGIN)
	viewValid = true
end

function MapRender.setAltView(on: boolean)
	if on ~= altView then
		altView = on
		markEverything()
	end
end

function MapRender.altView(): boolean
	return altView
end

function MapRender.setRails(buf: buffer?, paint: any)
	railBuf = buf
	railPaint = paint
end

function MapRender.scale(): number
	return S
end

function MapRender.step(now: number, zoom: number)
	if not ctx or failed or #chunks == 0 then
		return
	end
	updateView()
	if now - lastSpawnCheck > 0.25 then
		lastSpawnCheck = now
		refreshSpawnHalos()
		refreshCoverage()
	end
	stepTrails()
	local wantRails = zoom >= RAIL_SHOW_ZOOM
	if wantRails ~= railsShown then
		railsShown = wantRails
		if railBuf then
			markEverything()
		end
	end
	if wantHighlight ~= highlight and os.clock() - wantSince >= 0.06 then
		applyHighlight(wantHighlight)
	end
	if CosmeticTestStyles then
		local wanted=game:GetService("Players").LocalPlayer.PlayerGui:GetAttribute("WFTestTerritoryStyle")
		if not CosmeticTestStyles.valid(wanted) then wanted=nil end
		if wanted~=cosmeticStyle then
			cosmeticStyle=wanted
			for t in cosmeticTiles do markOne(t) end
		end
		if cosmeticStyle and not altView and now-lastCosmeticUpdate>=.125 then
			lastCosmeticUpdate=now;cosmeticTime=now
			local started=os.clock()
			local size,pos=ctx.parent.AbsoluteSize,ctx.parent.AbsolutePosition
			local hs,hp=ctx.holder.AbsoluteSize,ctx.holder.AbsolutePosition
			local x0=math.max(0,(hp.X-pos.X)/math.max(1,size.X)*W)
			local y0=math.max(0,(hp.Y-pos.Y)/math.max(1,size.Y)*H)
			local x1=math.min(W,(hp.X+hs.X-pos.X)/math.max(1,size.X)*W)
			local y1=math.min(H,(hp.Y+hs.Y-pos.Y)/math.max(1,size.Y)*H)
			if cosmeticCursor and not cosmeticTiles[cosmeticCursor] then cosmeticCursor=nil end
			for i=1,4096 do
				local t=next(cosmeticTiles,cosmeticCursor)
				cosmeticCursor=t
				if t==nil then break end
				local x,y=t%W,t//W
				if x>=x0 and x<=x1 and y>=y0 and y<=y1 then markOne(t) end
				if i%32==0 and os.clock()-started>.001 then break end
			end
		end
	end
	captureNow = os.clock()
	for t, c in captureSteps do
		markOne(t)
		if captureNow >= c.start + CAPTURE_SECONDS then
			captureSteps[t] = nil
			captureStepCount -= 1
			capturePool[#capturePool + 1] = c
		end
	end
	scanHighlight(0.001)
	debug.profilebegin("Capture.repaint")
	drain(0.003)
	debug.profileend()
	if uploadPending or now - lastUpload > (if captureStepCount > 0 then 0 elseif Settings.values.lowDetail then 0.2 else 0.033) then
		lastUpload = now
		debug.profilebegin("Capture.upload")
		uploadPending = not upload(0.001)
		debug.profileend()
	end
	-- Magnified: crisp pixels. Shrunk below one pixel per map pixel: smooth, so thin borders don't flicker.
	local mode = if zoom >= S then Enum.ResamplerMode.Pixelated else Enum.ResamplerMode.Default
	if mode ~= lastResample then
		lastResample = mode
		for _, ch in chunks do
			ch.label.ResampleMode = mode
		end
	end
end

function MapRender.init(c)
	ctx = c
	Settings.Changed:Connect(function(key: string)
		if key == "lowDetail" and map and wantedScale() ~= S then
			rebuild()
		end
	end)
	DeviceLayout.Changed:Connect(function()
		if map and not failed and #chunks > 0 and wantedScale() ~= S then
			rebuild()
		end
	end)
	MapRender.setMap(c.map)
end

return MapRender
