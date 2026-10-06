--[[
	War Front - missile flight curves (shared by server and client).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Ported from OpenFront (AGPL-3.0): src/core/pathfinding/PathFinder.Parabola.ts
	(getParabolaControlPoints) and src/core/utilities/Line.ts (DistanceBasedBezierCurve).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ReplicatedStorage.Shared.Ballistics (ModuleScript).
-- OpenFront nukes, MIRVs and MIRV warheads fly a cubic Bezier arc that bows "up" the map
-- (toward y = 0) by max(distance / 3, 50 tiles), clamped to the map, and advance `speed` tiles
-- of arc length per tick. Our tiles are LINEAR_SCALE (4) times bigger, so the 50-tile minimum
-- height becomes 12.5 here and speeds are divided by 4 by the caller.
-- Ballistics.curve(fx, fy, tx, ty, mapHeight, ignoreBounds?) -> curve
-- Ballistics.length(curve) -> arc length in tiles
-- Ballistics.at(curve, dist) -> x, y          point after `dist` tiles of arc (clamped)
-- Ballistics.ticks(curve, speed) -> number    ticks of flight (>= 1)

local Ballistics = {}

Ballistics.MIN_HEIGHT = 50 / 4 -- PARABOLA_MIN_HEIGHT, full-size tiles / LINEAR_SCALE
local SAMPLES = 48

local function bez(p0, p1, p2, p3, t)
	local u = 1 - t
	return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
end

function Ballistics.curve(fx: number, fy: number, tx: number, ty: number, mapHeight: number, ignoreBounds: boolean?)
	local dx, dy = tx - fx, ty - fy
	local dist = math.sqrt(dx * dx + dy * dy)
	local h = math.max(dist / 3, Ballistics.MIN_HEIGHT)
	local p1y = fy + dy / 4 - h
	local p2y = fy + dy * 3 / 4 - h
	if not ignoreBounds then
		p1y = math.clamp(p1y, 0, mapHeight - 1)
		p2y = math.clamp(p2y, 0, mapHeight - 1)
	end
	local c = {
		x0 = fx, y0 = fy,
		x1 = fx + dx / 4, y1 = p1y,
		x2 = fx + dx * 3 / 4, y2 = p2y,
		x3 = tx, y3 = ty,
		cum = table.create(SAMPLES + 1, 0),
		px = table.create(SAMPLES + 1, 0),
		py = table.create(SAMPLES + 1, 0),
	}
	local total = 0
	local lx, ly = fx, fy
	for i = 0, SAMPLES do
		local t = i / SAMPLES
		local x = bez(c.x0, c.x1, c.x2, c.x3, t)
		local y = bez(c.y0, c.y1, c.y2, c.y3, t)
		total += math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2)
		c.cum[i + 1] = total
		c.px[i + 1] = x
		c.py[i + 1] = y
		lx, ly = x, y
	end
	c.len = total
	return c
end

function Ballistics.length(c): number
	return c.len
end

function Ballistics.at(c, dist: number): (number, number)
	if dist <= 0 or c.len <= 0 then
		return c.x0, c.y0
	end
	if dist >= c.len then
		return c.x3, c.y3
	end
	local cum = c.cum
	-- binary search the sample segment
	local lo, hi = 1, #cum
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] < dist then
			lo = mid
		else
			hi = mid
		end
	end
	local seg = cum[hi] - cum[lo]
	local f = if seg > 0 then (dist - cum[lo]) / seg else 0
	return c.px[lo] + (c.px[hi] - c.px[lo]) * f, c.py[lo] + (c.py[hi] - c.py[lo]) * f
end

function Ballistics.ticks(c, speed: number): number
	return math.max(1, math.ceil(c.len / math.max(speed, 0.001)))
end

return Ballistics
