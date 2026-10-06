--[[
	Frontlines (working title) - map loading helpers.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
]]

local MapUtil = {}

local DECODE = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		DECODE[string.byte(alphabet, i)] = i - 1
	end
end

local function decodeBase64(s: string, expectedLen: number): buffer
	local out = buffer.create(expectedLen)
	local o = 0
	for i = 1, #s, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = DECODE[a] * 262144 + DECODE[b] * 4096 + (DECODE[c] or 0) * 64 + (DECODE[d] or 0)
		if o < expectedLen then buffer.writeu8(out, o, bit32.rshift(v, 16)); o += 1 end
		if o < expectedLen and c ~= 61 then buffer.writeu8(out, o, bit32.band(bit32.rshift(v, 8), 255)); o += 1 end
		if o < expectedLen and d ~= 61 then buffer.writeu8(out, o, bit32.band(v, 255)); o += 1 end
	end
	return out
end

export type GameMap = {
	name: string,
	width: number,
	height: number,
	size: number,
	terrain: buffer, -- one byte per tile
	nations: { any },
	landTiles: number,
	compact: boolean?, -- MapUtil.compact
}

function MapUtil.load(mapModule: ModuleScript): GameMap
	local def = require(mapModule)
	local size = def.width * def.height
	local terrain = decodeBase64(def.data, size)
	local land = 0
	for t = 0, size - 1 do
		local b = buffer.readu8(terrain, t)
		if b >= 128 and bit32.band(b, 31) ~= 31 then
			land += 1
		end
	end
	return {
		name = def.name,
		width = def.width,
		height = def.height,
		size = size,
		terrain = terrain,
		nations = def.nations,
		landTiles = land,
	}
end

function MapUtil.isLand(map: GameMap, t: number): boolean
	return buffer.readu8(map.terrain, t) >= 128
end

-- Land that can be owned (not impassable).
function MapUtil.isOwnable(map: GameMap, t: number): boolean
	local b = buffer.readu8(map.terrain, t)
	return b >= 128 and bit32.band(b, 31) ~= 31
end

function MapUtil.magnitude(map: GameMap, t: number): number
	return bit32.band(buffer.readu8(map.terrain, t), 31)
end

-- Terrain byte: bit 7 = land, bit 6 = shoreline, bit 5 = ocean, low 5 bits = magnitude
-- (31 on land = impassable).
local LAND, SHORE, OCEAN, MAG = 128, 64, 32, 31

local function impassableByte(b: number): boolean
	return b >= LAND and bit32.band(b, MAG) == MAG
end

-- Shoreline bit: a passable tile next to a passable tile of the other kind (land / water).
local function fixShore(terrain: buffer, w: number, size: number, t: number)
	local b = buffer.readu8(terrain, t)
	if impassableByte(b) then
		if bit32.band(b, SHORE) ~= 0 then
			buffer.writeu8(terrain, t, b - SHORE)
		end
		return
	end
	local land = b >= LAND
	local x = t % w
	local opposite = false
	local function check(n: number)
		local nb = buffer.readu8(terrain, n)
		if not impassableByte(nb) and (nb >= LAND) ~= land then
			opposite = true
		end
	end
	if x > 0 then check(t - 1) end
	if x < w - 1 then check(t + 1) end
	if t >= w then check(t - w) end
	if t < size - w then check(t + w) end
	local has = bit32.band(b, SHORE) ~= 0
	if opposite and not has then
		buffer.writeu8(terrain, t, b + SHORE)
	elseif not opposite and has then
		buffer.writeu8(terrain, t, b - SHORE)
	end
end

local function countLand(terrain: buffer, size: number): number
	local land = 0
	for t = 0, size - 1 do
		local b = buffer.readu8(terrain, t)
		if b >= LAND and bit32.band(b, MAG) ~= MAG then
			land += 1
		end
	end
	return land
end

-- Compact map (GameMapSize.Compact): half the width and height. Each 2x2 block becomes land when
-- at least two of its tiles are; water depth (magnitude) halves with the distances. Nation spawn
-- cells are halved too (TerrainMapLoader); the caller keeps 25 % of the nations.
function MapUtil.compact(src: GameMap): GameMap
	local w, h = src.width // 2, src.height // 2
	local size = w * h
	local terrain = buffer.create(size)
	local sw = src.width
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local base = (y * 2) * sw + x * 2
			local tiles = { base, base + 1, base + sw, base + sw + 1 }
			local landCount, impassable = 0, 0
			for _, t in tiles do
				local b = buffer.readu8(src.terrain, t)
				if b >= LAND then
					landCount += 1
					if bit32.band(b, MAG) == MAG then
						impassable += 1
					end
				end
			end
			local wantLand = landCount >= 2
			local pick = nil
			for _, t in tiles do
				local b = buffer.readu8(src.terrain, t)
				if (b >= LAND) == wantLand and (not wantLand or impassableByte(b) == (impassable * 2 > landCount)) then
					pick = b
					break
				end
			end
			if not pick then
				for _, t in tiles do
					local b = buffer.readu8(src.terrain, t)
					if (b >= LAND) == wantLand then
						pick = b
						break
					end
				end
			end
			local b = pick :: number
			b -= bit32.band(b, SHORE)
			if b >= LAND and not impassableByte(b) then
				-- Land height: the average of the block's passable land (no single-tile speckle).
				local sum, n = 0, 0
				for _, t in tiles do
					local tb = buffer.readu8(src.terrain, t)
					if tb >= LAND and not impassableByte(tb) then
						sum += bit32.band(tb, MAG)
						n += 1
					end
				end
				if n > 0 then
					b = b - bit32.band(b, MAG) + math.min(30, math.floor(sum / n + 0.5))
				end
			elseif b < LAND then
				local mag = bit32.band(b, MAG)
				b = b - mag + math.ceil(mag / 2)
			end
			buffer.writeu8(terrain, y * w + x, b)
		end
	end
	for t = 0, size - 1 do
		fixShore(terrain, w, size, t)
	end
	local nations = {}
	for i, n in src.nations do
		local c = table.clone(n)
		c[2] = math.floor((n[2] or 0) / 2)
		c[3] = math.floor((n[3] or 0) / 2)
		nations[i] = c
	end
	return {
		name = src.name,
		width = w,
		height = h,
		size = size,
		terrain = terrain,
		nations = nations,
		landTiles = countLand(terrain, size),
		compact = true,
	}
end

-- Water nukes (WaterManager.finalizeWaterChanges): turns the given passable land tiles into
-- lake water, spreads the ocean bit from neighbouring ocean, recomputes water depth near the
-- craters and fixes the shoreline bits. Edits map.terrain in place and lowers map.landTiles.
-- Deterministic, so the server and every client apply the same list to the same result.
-- Returns the converted tiles.
function MapUtil.toWater(map: GameMap, list: { number }): { number }
	local terrain, w, size = map.terrain, map.width, map.size
	local converted = {}
	local isConv = {}
	for _, t in list do
		if t >= 0 and t < size and not isConv[t] then
			local b = buffer.readu8(terrain, t)
			if b >= LAND and bit32.band(b, MAG) ~= MAG then
				buffer.writeu8(terrain, t, 0)
				isConv[t] = true
				converted[#converted + 1] = t
			end
		end
	end
	if #converted == 0 then
		return converted
	end
	map.landTiles -= #converted
	local nb = {}
	-- 1. Ocean bit spreads from neighbouring ocean through the new (and any connected) water.
	local queue, head = {}, 1
	for _, t in converted do
		local k = MapUtil.neighbors(map, t, nb)
		for i = 1, k do
			local n = nb[i]
			local b = buffer.readu8(terrain, n)
			if not isConv[n] and b < LAND and bit32.band(b, OCEAN) ~= 0 then
				buffer.writeu8(terrain, t, buffer.readu8(terrain, t) + OCEAN)
				queue[#queue + 1] = t
				break
			end
		end
	end
	while head <= #queue do
		local t = queue[head]
		head += 1
		local k = MapUtil.neighbors(map, t, nb)
		for i = 1, k do
			local n = nb[i]
			local b = buffer.readu8(terrain, n)
			if b < LAND and bit32.band(b, OCEAN) == 0 then
				buffer.writeu8(terrain, n, b + OCEAN)
				queue[#queue + 1] = n
			end
		end
	end
	-- 2. Water depth: magnitude = ceil(distance to the nearest passable land / 2), capped at 31.
	-- Distances only change within 62 tiles of a crater; the BFS runs over a box twice as wide.
	local minX, maxX, minY, maxY = math.huge, -1, math.huge, -1
	for _, t in converted do
		local x, y = t % w, t // w
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minY, maxY = math.min(minY, y), math.max(maxY, y)
	end
	local REACH = 62
	local bx0, bx1 = math.max(0, minX - REACH * 2), math.min(w - 1, maxX + REACH * 2)
	local by0, by1 = math.max(0, minY - REACH * 2), math.min(map.height - 1, maxY + REACH * 2)
	local bw = bx1 - bx0 + 1
	local dist = buffer.create(bw * (by1 - by0 + 1) * 2)
	buffer.fill(dist, 0, 255)
	local q = {}
	for y = by0, by1 do
		for x = bx0, bx1 do
			local t = y * w + x
			local b = buffer.readu8(terrain, t)
			if b >= LAND and bit32.band(b, MAG) ~= MAG then
				-- Land next to water is a source (distance 0 at the coast).
				local k = MapUtil.neighbors(map, t, nb)
				for i = 1, k do
					if buffer.readu8(terrain, nb[i]) < LAND then
						buffer.writeu16(dist, ((y - by0) * bw + (x - bx0)) * 2, 0)
						q[#q + 1] = t
						break
					end
				end
			end
		end
	end
	head = 1
	while head <= #q do
		local t = q[head]
		head += 1
		local x, y = t % w, t // w
		local d = buffer.readu16(dist, ((y - by0) * bw + (x - bx0)) * 2)
		if d < REACH then
			local k = MapUtil.neighbors(map, t, nb)
			for i = 1, k do
				local n = nb[i]
				local nx, ny = n % w, n // w
				if nx >= bx0 and nx <= bx1 and ny >= by0 and ny <= by1 and buffer.readu8(terrain, n) < LAND then
					local o = ((ny - by0) * bw + (nx - bx0)) * 2
					if buffer.readu16(dist, o) > d + 1 then
						buffer.writeu16(dist, o, d + 1)
						q[#q + 1] = n
					end
				end
			end
		end
	end
	local ux0, ux1 = math.max(0, minX - REACH), math.min(w - 1, maxX + REACH)
	local uy0, uy1 = math.max(0, minY - REACH), math.min(map.height - 1, maxY + REACH)
	for y = uy0, uy1 do
		for x = ux0, ux1 do
			local t = y * w + x
			local b = buffer.readu8(terrain, t)
			if b < LAND then
				local d = buffer.readu16(dist, ((y - by0) * bw + (x - bx0)) * 2)
				local mag = math.min(MAG, math.ceil(math.min(d, 62) / 2))
				buffer.writeu8(terrain, t, b - bit32.band(b, MAG) + mag)
			end
		end
	end
	-- 3. Shoreline bits around the craters (two rings).
	local seen = {}
	for _, t in converted do
		local x, y = t % w, t // w
		for dy = -2, 2 do
			for dx = -2, 2 do
				local nx, ny = x + dx, y + dy
				if nx >= 0 and nx < w and ny >= 0 and ny < map.height then
					local n = ny * w + nx
					if not seen[n] then
						seen[n] = true
						fixShore(terrain, w, size, n)
					end
				end
			end
		end
	end
	return converted
end

-- Writes the 4-neighbours of tile t into out and returns how many there are.
function MapUtil.neighbors(map: GameMap, t: number, out: { number }): number
	local w = map.width
	local x = t % w
	local n = 0
	if x > 0 then n += 1; out[n] = t - 1 end
	if x < w - 1 then n += 1; out[n] = t + 1 end
	if t >= w then n += 1; out[n] = t - w end
	if t < map.size - w then n += 1; out[n] = t + w end
	return n
end

return MapUtil
