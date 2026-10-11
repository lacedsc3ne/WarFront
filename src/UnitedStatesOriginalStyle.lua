--[[
	War Front - original United States test map, generated from approved concept artwork.
	Copyright (C) 2026 Liam (lacedsc3ne). GNU AGPL v3 or later.
	No OpenFront map terrain or nation coordinates were used to build this map.
]]
local Style = {}
local colours = {{88,131,42},{101,143,41},{125,159,42},{144,171,41},{164,181,45},{194,190,61},{237,188,93},{252,199,100},{252,204,110},{114,153,121}}
function Style.terrainRGB(byte: number): (number, number, number)
    local m = bit32.band(byte, 31)
    if byte >= 128 then
        local c = colours[math.min(m, 9) + 1]
        return c[1], c[2], c[3]
    end
    if bit32.band(byte, 32) == 0 then return 18, 93, 151 end
    if m <= 1 then return 15, 86, 142 end
    if m <= 3 then return 9, 68, 119 end
    if m <= 6 then return 6, 48, 92 end
    return 3, 34, 69
end
Style.tileRGB = Style.terrainRGB
function Style.flatTerrainRGB(byte: number): (number, number, number)
    if byte < 128 then return Style.terrainRGB(byte) end
    return 151, 171, 55
end
Style.pixels = table.create(256)
for byte = 0, 255 do
    local r, g, b = Style.terrainRGB(byte)
    Style.pixels[byte + 1] = r + g * 256 + b * 65536 + 255 * 16777216
end
return Style
