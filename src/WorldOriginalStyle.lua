--[[
	War Front - original World test map, generated from approved concept artwork.
	Copyright (C) 2026 Liam (lacedsc3ne). GNU AGPL v3 or later.
	No OpenFront map terrain or nation coordinates were used to build this map.
]]
local Style = {}
local colours = {{88,135,45},{92,141,119},{117,154,53},{138,168,49},{161,180,50},{178,188,60},{202,194,71},{249,198,95},{252,206,110},{145,171,106}}
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
-- Climate is a visual layer; terrain bytes and gameplay magnitudes are unchanged.
local climate = game:GetService("EncodingService"):Base64Decode(buffer.fromstring(require(script.Parent:WaitForChild("WorldClimateData"))))
local function climateRGB(byte: number, x: number?, y: number?, width: number?, height: number?, flat: boolean?): (number, number, number)
    if byte < 128 or x == nil or y == nil then return Style.terrainRGB(byte) end
    local gx = math.clamp(math.floor((x + 0.5) * 800 / (width or 800)), 0, 799)
    local gy = math.clamp(math.floor((y + 0.5) * 400 / (height or 400)), 0, 399)
    local t = gy * 800 + gx
    local kind = bit32.band(bit32.rshift(buffer.readu8(climate, t // 4), (t % 4) * 2), 3)
    if kind == 1 then return 242, 248, 246 end
    if kind == 2 then return 197, 226, 241 end
    local r, g, blue = Style.terrainRGB(byte)
    if gy < 82 and bit32.band(byte, 31) < 7 then
        return math.floor(r * 0.65 + 143 * 0.35), math.floor(g * 0.65 + 160 * 0.35), math.floor(blue * 0.65 + 124 * 0.35)
    end
    if flat then return 151, 171, 55 end
    return r, g, blue
end
function Style.tileRGB(byte: number, x: number?, y: number?, width: number?, height: number?): (number, number, number)
    return climateRGB(byte, x, y, width, height, false)
end
function Style.flatTerrainRGB(byte: number, x: number?, y: number?, width: number?, height: number?): (number, number, number)
    return climateRGB(byte, x, y, width, height, true)
end
function Style.pixelAt(byte: number, x: number, y: number, width: number, height: number): number
    local r, g, blue = Style.tileRGB(byte, x, y, width, height)
    return r + g * 256 + blue * 65536 + 255 * 16777216
end

return Style
