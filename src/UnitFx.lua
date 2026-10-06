--[[
	War Front - client drawing for railroads, trains, MIRV warheads and SAM missiles.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Look ported from OpenFront (AGPL-3.0): src/client/render/gl/passes/RailroadPass.ts +
	shaders/railroad/railroad.frag.glsl (rail orientation, 3x3 detail sprite, rail colours, bridge
	colour), passes/UnitPass.ts + shaders/unit/unit.frag.glsl (train / warhead / SAM missile sprites
	from resources/atlases/unit-atlas.png, flicker, untargetable alpha), src/core/execution/
	TrainExecution.ts (car spacing). Sprites © OpenFront, CC BY-SA 4.0.
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.UnitFx (ModuleScript), used by GameClient.
-- UnitFx.init(ctx)    ctx = { unitLayer, fxLayer, roster, getMyId(), isAlly(id), mapSize() -> W, H,
--                             markTile(t), map }
-- UnitFx.setMap(map)  new map: rail buffers are rebuilt and handed to MapRender.setRails
-- UnitFx.reset()      new round: drops rails, trains, warheads, missiles
-- UnitFx.handle(kind, data) -> boolean   "rails", "trains", "warheads", "warheadEnd", "samMissile"
-- UnitFx.step(serverTime, zoom)          every frame
-- Rails are painted into the map image by MapRender (one of our tiles = 3 x 3 pixels, which is
-- exactly OpenFront's detailed 3 x 3 rail sprite). OpenFront hides rails below zoom 3 and fades
-- them in; our map image is static, so they are always drawn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local SpriteKit = require(script.Parent:WaitForChild("SpriteKit"))
local MapRender = require(script.Parent:WaitForChild("MapRender"))
local MapFx = require(script.Parent:WaitForChild("MapFx"))

local UnitFx = {}

local L = Config.LINEAR_SCALE
local OPAQUE = 4278190080
local RAIL_GREY = { 191, 191, 191 } -- unowned rails (vec3(0.75))
local BRIDGE = { 197, 69, 72 } -- vec3(0.773, 0.271, 0.282)
local TARGETABLE_RANGE = 150 / L
local UNTARGETABLE_ALPHA = 0.6 -- render-settings.json unit.untargetableAlpha
local CAR_GAP = 2 / L -- TrainExecution.spacing (full-size tiles) in our tiles
local FLICKER = {
	Color3.new(1, 0, 0),
	Color3.new(1, 0.5, 0),
	Color3.new(1, 1, 0),
	Color3.new(1, 1, 1),
}
local WARHEAD_FX_PER_SECOND = 30 -- full nuke explosions per second before falling back to small ones
local TELEGRAPH_SELF = Color3.fromRGB(0, 255, 0)
local TELEGRAPH_ALLY = Color3.fromRGB(255, 255, 0)
local TELEGRAPH_ENEMY = Color3.fromRGB(255, 0, 0)

local ctx: any = nil
local map: any = nil
local W, H = 0, 0

local railType = buffer.create(0)
local railCount = buffer.create(0)
local railsById: { [number]: { number } } = {}
local trains: { [number]: any } = {}
local warheads: { [number]: any } = {}
local missiles: { any } = {}
local fxBudget = WARHEAD_FX_PER_SECOND
local lastBudget = os.clock()

local function scalePos(x: number, y: number): UDim2
	return UDim2.fromScale(x / W, y / H)
end

-- Rails (RailroadPass orientation codes + 1: 1 vertical, 2 horizontal, 3 top-left, 4 top-right,
-- 5 bottom-left, 6 bottom-right)
local VERTICAL, HORIZONTAL, TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT = 0, 1, 2, 3, 4, 5

local function railExtremity(tile: number, nxt: number): number
	local dx = nxt % W - tile % W
	local dy = nxt // W - tile // W
	if dx == 0 then
		return VERTICAL
	end
	if dy == 0 then
		return HORIZONTAL
	end
	return VERTICAL
end

local function railDirection(prev: number, cur: number, nxt: number): number
	local x1, y1 = prev % W, prev // W
	local x2, y2 = cur % W, cur // W
	local x3, y3 = nxt % W, nxt // W
	local dx1, dy1 = x2 - x1, y2 - y1
	local dx2, dy2 = x3 - x2, y3 - y2
	if dx1 == dx2 and dy1 == dy2 then
		return if dx1 ~= 0 then HORIZONTAL else VERTICAL
	end
	if (dx1 == 0 and dx2 ~= 0) or (dx1 ~= 0 and dx2 == 0) then
		if dx1 == 0 and dx2 == 1 and dy1 == -1 then return BOTTOM_RIGHT end
		if dx1 == 0 and dx2 == -1 and dy1 == -1 then return BOTTOM_LEFT end
		if dx1 == 0 and dx2 == 1 and dy1 == 1 then return TOP_RIGHT end
		if dx1 == 0 and dx2 == -1 and dy1 == 1 then return TOP_LEFT end
		if dx1 == 1 and dx2 == 0 and dy2 == -1 then return TOP_LEFT end
		if dx1 == -1 and dx2 == 0 and dy2 == -1 then return TOP_RIGHT end
		if dx1 == 1 and dx2 == 0 and dy2 == 1 then return BOTTOM_LEFT end
		if dx1 == -1 and dx2 == 0 and dy2 == 1 then return BOTTOM_RIGHT end
	end
	return VERTICAL
end

-- railDetailCoverage on a 3 x 3 grid (i = column, j = row, y down).
local function covered(rt: number, i: number, j: number): boolean
	if i == 1 and j == 1 then
		return true
	end
	if rt == 1 then
		return i == 0 or i == 2
	elseif rt == 2 then
		return j == 0 or j == 2
	elseif rt == 3 then
		return j == 0 or i == 0
	elseif rt == 4 then
		return j == 0 or i == 2
	elseif rt == 5 then
		return j == 2 or i == 0
	elseif rt == 6 then
		return j == 2 or i == 2
	end
	return false
end

local function railColor(o: number): (number, number, number)
	if o == 0 or o == 65535 then
		return RAIL_GREY[1], RAIL_GREY[2], RAIL_GREY[3]
	end
	local p = ctx.roster[o]
	if o == ctx.getMyId() then
		-- uLocalRailColor: white, or black over light territory.
		local r, g, b = 200, 200, 200
		if p and p.r then
			r, g, b = p.r, p.g, p.b
		end
		if 0.299 * r + 0.587 * g + 0.114 * b > 170 then
			return 0, 0, 0
		end
		return 255, 255, 255
	end
	if p and p.paint then
		return p.paint[4], p.paint[5], p.paint[6] -- palette border row
	end
	return RAIL_GREY[1], RAIL_GREY[2], RAIL_GREY[3]
end

local function blend(buf: buffer, off: number, r: number, g: number, b: number, a: number)
	local c = buffer.readu32(buf, off)
	local br, bg, bb = c % 256, (c // 256) % 256, (c // 65536) % 256
	buffer.writeu32(buf, off, math.floor(br + (r - br) * a + 0.5) + math.floor(bg + (g - bg) * a + 0.5) * 256 + math.floor(bb + (b - bb) * a + 0.5) * 65536 + OPAQUE)
end

local function paintRail(owners: buffer, t: number, x: number, y: number, buf: buffer, off: number, stride: number, S: number)
	local rt = buffer.readu8(railType, t)
	local r, g, b = railColor(buffer.readu16(owners, t * 2))
	local col = r + g * 256 + b * 65536 + OPAQUE
	local water = not MapUtil.isLand(map, t)
	if water then
		local bc = BRIDGE[1] + BRIDGE[2] * 256 + BRIDGE[3] * 65536 + OPAQUE
		for j = 0, S - 1 do
			for i = 0, S - 1 do
				buffer.writeu32(buf, off + j * stride + i * 4, bc)
			end
		end
	end
	if S == 3 then
		for j = 0, 2 do
			for i = 0, 2 do
				if covered(rt, i, j) then
					buffer.writeu32(buf, off + j * stride + i * 4, col)
				end
			end
		end
	elseif S == 2 then
		-- line mode (2 px per tile): a translucent rail-coloured block
		for j = 0, 1 do
			for i = 0, 1 do
				blend(buf, off + j * stride + i * 4, r, g, b, 0.6)
			end
		end
	else
		blend(buf, off, r, g, b, 0.75)
	end
end

local function markRail(t: number)
	if ctx.markTile then
		ctx.markTile(t)
	end
end

local function removeRail(id: number)
	local tiles = railsById[id]
	if not tiles then
		return
	end
	railsById[id] = nil
	for _, t in tiles do
		if t < buffer.len(railType) then
			local c = buffer.readu16(railCount, t * 2)
			if c <= 1 then
				buffer.writeu16(railCount, t * 2, 0)
				buffer.writeu8(railType, t, 0)
			else
				buffer.writeu16(railCount, t * 2, c - 1)
			end
			markRail(t)
		end
	end
end

local function addRail(id: number, b: buffer)
	removeRail(id)
	local n = buffer.len(b) // 4
	local tiles = table.create(n)
	for i = 0, n - 1 do
		tiles[i + 1] = buffer.readu32(b, i * 4)
	end
	railsById[id] = tiles
	for i, t in tiles do
		if t >= buffer.len(railType) then
			continue
		end
		local o
		if n == 1 then
			o = VERTICAL
		elseif i == 1 then
			o = railExtremity(t, tiles[2])
		elseif i == n then
			o = railExtremity(t, tiles[n - 1])
		else
			o = railDirection(tiles[i - 1], t, tiles[i + 1])
		end
		buffer.writeu8(railType, t, o + 1)
		buffer.writeu16(railCount, t * 2, buffer.readu16(railCount, t * 2) + 1)
		markRail(t)
	end
end

local function clearRails()
	for id in railsById do
		removeRail(id)
	end
end

-- Trains
local function destroyTrain(id: number)
	local tr = trains[id]
	if tr then
		for _, part in tr.parts do
			part.holder:Destroy()
		end
		trains[id] = nil
	end
end

local function addTrain(d)
	destroyTrain(d.id)
	local n = buffer.len(d.path) // 4
	if n == 0 then
		return
	end
	local territory, border = SpriteKit.owner(ctx.roster[d.owner])
	local parts = {}
	-- engine first, then carriages, then the tail engine (cosmetic, TrainExecution)
	local cars = d.cars or 5
	for k = 0, cars + 1 do
		local kind = if k == 0 or k == cars + 1 then "TrainEngine" else "TrainCarriage"
		local holder = SpriteKit.unit(kind, { ZIndex = 3, Parent = ctx.unitLayer })
		SpriteKit.paint(holder, territory, border)
		-- distance behind the engine: carriages every 2 full-size tiles, the first one 1 tile back
		local behind = if k == 0 then 0 else (2 * k - 1) * CAR_GAP / 2
		parts[#parts + 1] = { holder = holder, behind = behind }
	end
	trains[d.id] = { path = d.path, n = n, start = d.start, speed = d.speed, parts = parts, owner = d.owner }
end

local function pathPos(tr, d: number): (number, number)
	-- d tiles along the path from its first tile (fractional: interpolate between tiles)
	local idx = math.clamp(d, 0, tr.n - 1)
	local i0 = math.floor(idx)
	local i1 = math.min(i0 + 1, tr.n - 1)
	local f = idx - i0
	local a = buffer.readu32(tr.path, i0 * 4)
	local b = buffer.readu32(tr.path, i1 * 4)
	local ax, ay = a % W + 0.5, a // W + 0.5
	local bx, by = b % W + 0.5, b // W + 0.5
	return ax + (bx - ax) * f, ay + (by - ay) * f
end

-- MIRV warheads and SAM missiles
local function relationColor(owner: number): Color3
	local me = ctx.getMyId()
	if me ~= 0 and owner == me then
		return TELEGRAPH_SELF
	elseif me ~= 0 and ctx.isAlly(owner) then
		return TELEGRAPH_ALLY
	end
	return TELEGRAPH_ENEMY
end

local function destroyWarhead(id: number)
	local w = warheads[id]
	if w then
		w.dot:Destroy()
		w.disc:Destroy()
		warheads[id] = nil
	end
end

local function addWarheads(d)
	local list = d.list
	local fx, fy = d.from % W, d.from // W
	local color = relationColor(d.owner)
	for o = 0, buffer.len(list) - 12, 12 do
		local id = buffer.readu32(list, o)
		local to = buffer.readu32(list, o + 4)
		local wait = buffer.readu16(list, o + 8)
		local speed = buffer.readu16(list, o + 10) / 64
		local tx, ty = to % W, to // W
		destroyWarhead(id)
		-- OpenFront MIRV warhead sprite: a 3 x 3 white square (flickers like every nuke).
		local dot = Instance.new("Frame")
		dot.Name = "Warhead"
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.BorderSizePixel = 0
		dot.ZIndex = 5
		dot.Parent = ctx.fxLayer
		-- Target telegraph (inner 12 / outer 18 full-size): a translucent disc at the outer radius.
		local disc = Instance.new("Frame")
		disc.Name = "WarheadTarget"
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.Position = scalePos(tx + 0.5, ty + 0.5)
		disc.Size = UDim2.fromScale(4.5 * 2 / W, 4.5 * 2 / H)
		disc.BackgroundColor3 = color
		disc.BackgroundTransparency = 0.82
		disc.BorderSizePixel = 0
		disc.Visible = false
		disc.ZIndex = 4
		disc.Parent = ctx.fxLayer
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = disc
		warheads[id] = {
			curve = Ballistics.curve(fx + 0.5, fy + 0.5, tx + 0.5, ty + 0.5, H),
			start = d.start,
			wait = wait,
			speed = speed,
			from = d.from,
			to = to,
			dot = dot,
			disc = disc,
			hash = (id * 0.618) % 1,
		}
		local w = warheads[id]
		-- Cleared on its own if "warheadEnd" never arrives (6 s past the planned impact).
		w.expire = d.start + (wait + Ballistics.length(w.curve) / math.max(speed, 0.001)) * Config.TICK + 6
	end
end

local function warheadFx(tile: number, exploded: boolean)
	if not exploded then
		MapFx.nukeEnd({ tile = tile, exploded = false, radius = 2 })
		return
	end
	if fxBudget >= 1 then
		fxBudget -= 1
		MapFx.nukeEnd({ tile = tile, exploded = true, radius = 4.5 })
	else
		MapFx.shellHit(tile)
	end
end

local function endWarheads(b: buffer)
	for o = 0, buffer.len(b) - 9, 9 do
		local id = buffer.readu32(b, o)
		local tile = buffer.readu32(b, o + 4)
		local exploded = buffer.readu8(b, o + 8) == 1
		destroyWarhead(id)
		warheadFx(tile, exploded)
	end
end

local function addMissile(d)
	local holder = SpriteKit.unit("SAMMissile", { ZIndex = 5, Parent = ctx.fxLayer })
	missiles[#missiles + 1] = {
		fx = d.from % W + 0.5,
		fy = d.from // W + 0.5,
		tx = d.to % W + 0.5,
		ty = d.to // W + 0.5,
		start = d.start,
		duration = math.max(0.05, d.duration),
		holder = holder,
		hash = math.random(),
	}
end

-- Public API
function UnitFx.handle(kind: string, data: any): boolean
	if kind == "rails" then
		if data.reset then
			clearRails()
		end
		for _, id in data.remove or {} do
			removeRail(id)
		end
		for _, e in data.add or {} do
			addRail(e[1], e[2])
		end
		return true
	elseif kind == "trains" then
		if data.reset then
			for id in trains do
				destroyTrain(id)
			end
		end
		for _, id in data.remove or {} do
			destroyTrain(id)
		end
		for _, d in data.add or {} do
			addTrain(d)
		end
		return true
	elseif kind == "warheads" then
		addWarheads(data)
		return true
	elseif kind == "warheadEnd" then
		endWarheads(data)
		return true
	elseif kind == "samMissile" then
		addMissile(data)
		return true
	end
	return false
end

function UnitFx.step(st: number, zoom: number)
	local now = os.clock()
	fxBudget = math.min(WARHEAD_FX_PER_SECOND, fxBudget + (now - lastBudget) * WARHEAD_FX_PER_SECOND)
	lastBudget = now
	local cell = SpriteKit.cellPx(zoom)
	local cellSize = UDim2.fromOffset(cell, cell)

	for _, tr in trains do
		local d = (st - tr.start) * tr.speed
		for _, part in tr.parts do
			local x, y = pathPos(tr, d - part.behind)
			part.holder.Position = scalePos(x, y)
			part.holder.Size = cellSize
		end
	end

	local hot = math.floor((st * 10 * 0.3) % 4) -- unit.flickerSpeed per tick
	local r2 = TARGETABLE_RANGE * TARGETABLE_RANGE
	local dotPx = math.max(1, cell * 3 / 13)
	for id, w in warheads do
		if st > w.expire then
			destroyWarhead(id)
			continue
		end
		local e = (st - w.start) / Config.TICK - w.wait
		local x, y
		if e < 0 then
			x, y = w.curve.x0, w.curve.y0
		else
			x, y = Ballistics.at(w.curve, e * w.speed)
		end
		w.dot.Position = scalePos(x, y)
		w.dot.Size = UDim2.fromOffset(dotPx, dotPx)
		w.dot.BackgroundColor3 = FLICKER[(hot + math.floor(w.hash * 4)) % 4 + 1]
		local tx, ty = w.to % W + 0.5, w.to // W + 0.5
		local fx, fy = w.from % W + 0.5, w.from // W + 0.5
		local targetable = (x - tx) ^ 2 + (y - ty) ^ 2 < r2 or (x - fx) ^ 2 + (y - fy) ^ 2 < r2
		w.dot.BackgroundTransparency = if targetable then 0 else 1 - UNTARGETABLE_ALPHA
		w.disc.Visible = e >= 0
	end

	local i = 1
	while i <= #missiles do
		local m = missiles[i]
		local f = (st - m.start) / m.duration
		if f >= 1 then
			m.holder:Destroy()
			table.remove(missiles, i)
		else
			f = math.max(0, f)
			m.holder.Position = scalePos(m.fx + (m.tx - m.fx) * f, m.fy + (m.ty - m.fy) * f)
			m.holder.Size = cellSize
			SpriteKit.flicker(m.holder, st, m.hash)
			i += 1
		end
	end
end

function UnitFx.reset()
	clearRails()
	for id in trains do
		destroyTrain(id)
	end
	for id in warheads do
		destroyWarhead(id)
	end
	for _, m in missiles do
		m.holder:Destroy()
	end
	table.clear(missiles)
end

function UnitFx.setMap(m)
	UnitFx.reset()
	map = m
	W, H = m.width, m.height
	railType = buffer.create(m.size)
	railCount = buffer.create(m.size * 2)
	railsById = {}
	MapRender.setRails(railType, paintRail)
end

function UnitFx.init(c)
	ctx = c
	UnitFx.setMap(c.map)
end

return UnitFx
