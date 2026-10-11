--[[
	War Front - terrain colours for the approved playable World map.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- ReplicatedStorage.Shared.WorldStyle. Other maps retain Shared.Theme's palette.
local WorldStyle = {}

function WorldStyle.terrainRGB(byte: number): (number, number, number)
	local m = bit32.band(byte, 31)
	if byte < 128 then
		local shallow = math.max(0, 1 - m / 5)
		return math.floor(9 + shallow * 5), math.floor(35 + shallow * 12), math.floor(62 + shallow * 12)
	end
	if m >= 28 then return 237, 240, 234 end -- snow / ice
	if m >= 20 then return 218, 220, 213 end -- highlands
	if m >= 10 then return 220, 197, 150 end -- dry terrain
	return 173, 194, 113 -- plains
end

-- Render-only detail: stable broad terrain shading with a little fine grain.
-- Tile magnitudes and all gameplay data stay unchanged.
function WorldStyle.tileRGB(byte: number, x: number, y: number): (number, number, number)
	local r, g, b = WorldStyle.terrainRGB(byte)
	local m = bit32.band(byte, 31)
	local variation = 0
	if byte >= 128 then
		local strength = if m >= 20 and m < 28 then 12 else 8
		variation = math.noise(x * 0.12, y * 0.12) * strength
			+ math.noise(x * 0.71, y * 0.71, 4) * 3
	else
		variation = math.noise(x * 0.025, y * 0.025, 8) * 2
	end
	return math.clamp(math.floor(r + variation + 0.5), 0, 255),
		math.clamp(math.floor(g + variation + 0.5), 0, 255),
		math.clamp(math.floor(b + variation + 0.5), 0, 255)
end

function WorldStyle.flatTerrainRGB(byte: number): (number, number, number)
	if byte < 128 then return WorldStyle.terrainRGB(byte) end
	return 173, 194, 113
end

WorldStyle.pixels = table.create(256)
for byte = 0, 255 do
	local r, g, b = WorldStyle.terrainRGB(byte)
	WorldStyle.pixels[byte + 1] = r + g * 256 + b * 65536 + 255 * 16777216
end

return WorldStyle
