--[[
	Frontlines (working title) - map colour theme (terrain, player palettes, territory fill/borders).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Colours and colour rules ported from OpenFront (AGPL-3.0): src/client/render/gl/default-theme.json,
	colorblind-theme.json, render-settings.json, utils/ColorUtils.ts (terrain), theme/ThemeProvider.ts
	and theme/ColorAllocator.ts (palettes, borders), shaders/map-overlay/territory.frag.glsl and
	shaders/day-night/border-stamp.frag.glsl (fill alpha/saturation, border tints).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ReplicatedStorage.Shared.Theme (ModuleScript), used by GameServer (player colours) and the
-- client renderer (GameClient paint, NameLabels).
-- Server:  Theme.newRoundColors() -> pools; pools:take(kind) -> packed 0xRRGGBB colour.
--          Humans / nations draw distinct colours from their own palette, bots all share the flat
--          OpenFront "Bot" colour. Call newRoundColors() once per round.
-- Client:  Theme.terrainRGB(byte) / Theme.flatTerrainRGB(byte) -> r, g, b (terrain shading on/off)
--          Theme.resetClient()                     forget colour-blind remaps (new round)
--          Theme.applyPlayerColors(p, colorblind)  sets p.r, p.g, p.b (display colour) and
--                                                  p.paint = { fillR, fillG, fillB, borderR, borderG, borderB }
--                                                  from p.serverColor (packed) and p.kind / p.id
--          Theme.falloutRGB(x, y), Theme.FOCUSED_BORDER, Theme.TERRITORY_ALPHA, Theme.FRIENDLY_TINT,
--          Theme.FRIENDLY_TINT_RATIO, Theme.BACKGROUND (Color3), Theme.NAME_SHADE[kind]

local Theme = {}

-- Palettes (hex lists from OpenFront's theme JSON files)
local function parse(s: string): { { number } }
	local out = {}
	for hex in string.gmatch(s, "%x%x%x%x%x%x") do
		local n = tonumber(hex, 16) :: number
		out[#out + 1] = { n // 65536, (n // 256) % 256, n % 256 }
	end
	return out
end

local HUMAN = parse([[
a3e635 84cc16 10b981 34d399 2dd4bf 4ade80 6ee7b7 86efac 97ffbb baffc9 e6fad2 22c55e
43be54 52b788 30b2b4 e6fffa dcf0fa e9d5ff ccccff dcdcff cae1ff 93c5fd 7dd3fc 63cafd
38bdf8 60a5fa 3b82f6 4f46e5 7c3aed 9333ea b388ff a78bfa d946ef a855f7 be5cfb c084fc
f0abfc f472b6 ec4899 dc2626 ef4444 eb4b4b f56565 f87171 fb7185 fda4af fca5a5 ffcce5
fad7e1 fbebf5 f0f0c8 fafad2 fff0c8 ffdfba fcd34d fbbf24 eab308 ca8a04 f59e0b fb923c
f97316 ea580c 854d0e
]])

local NATION = parse([[
d2d264 b4d278 aabe64 50c878 82c882 8cb48c a0bea0 a0b48c 64a050 648c6e 64b4a0 82b4aa
aabeb4 648296 78a0c8 8c96b4 64d2d2 8cb4dc 82aabe 64b4e6 5082be 7878be 966ebe a078a0
aa8cbe b482b4 be8c96 b464e6 b4a0b4 aa96aa 968296 e6b4b4 d2a0c8 e682b4 d264a0 be6482
dc7878 c8826e e68c8c e66464 e69664 d28c50 e6b450 c8a06e be9682 b4aa8c c8c88c beaa64
]])

-- Used once a palette is exhausted (shared by both themes).
local FALLBACK = parse([[
230000 2d0000 370000 410000 4b0000 550000 5f0000 690000 730000 7d0000 870000 910000
9b0000 a50000 af0000 b90000 c30005 cd000a d7000f e10014 eb0019 f5001e ff0023 ff0a2d
ff1437 ff1e41 ff284b ff3255 ff3c5f ff4669 ff5073 ff5a7d ff6487 ff6e91 ff789b ff82a5
ff8caf ff96b9 ffa0c3 ffaacd ffb4d7 ffbee1 ffc8eb 002d00 003700 004100 004b00 005500
005f00 006900 007300 007d00 008700 009100 009b00 00a500 00af00 00b900 00c305 00cd0a
00d70f 00e114 00eb19 00f51e 00ff23 0aff2d 14ff37 1eff41 28ff4b 32ff55 3cff5f 46ff69
50ff73 5aff7d 64ff87 6eff91 78ff9b 82ffa5 8cffaf 96ffb9 a0ffc3 aaffcd b4ffd7 beffe1
c8ffeb 000023 00002d 000037 000041 00004b 000055 00005f 000069 000073 00007d 000087
000091 00009b 0000a5 0000af 0000b9 0500c3 0a00cd 0f00d7 1400e1 1900eb 1e00f5 2300ff
2d0aff 3714ff 411eff 4b28ff 5532ff 5f3cff 6946ff 7350ff 7d5aff 8764ff 916eff 9b78ff
a582ff af8cff b996ff c3a0ff cdaaff d7b4ff e1beff ebc8ff 230023 2d002d 370037 410041
4b004b 550055 5f005f 690069 730073 7d007d 870087 910091 9b009b a500a5 af00af b900b9
c305c3 cd0acd d70fd7 e114e1 eb19eb f51ef5 ff23ff ff2dff ff37ff ff41ff ff4bff ff55ff
ff5fff ff69ff ff73ff ff7dff ff87ff ff91ff ff9bff ffa5ff ffafff ffb9ff ffc3ff ffcdff
ffd7ff 002323 002d2d 003737 004141 004b4b 005555 005f5f 006969 007373 007d7d 008787
009191 009b9b 00a5a5 00afaf 00b9b9 05c3c3 0acdcd 0fd7d7 14e1e1 19ebeb 1ef5f5 23ffff
2dffff 37ffff 41ffff 4bffff 55ffff 5fffff 69ffff 73ffff 7dffff 87ffff 91ffff 9bffff
a5ffff afffff b9ffff c3ffff cdffff d7ffff 232300 2d2d00 373700 414100 4b4b00 555500
5f5f00 696900 737300 7d7d00 878700 919100 9b9b00 a5a500 afaf00 b9b900 c3c305 cdcd0a
d7d70f e1e114 ebeb19 f5f51e ffff23 ffff2d ffff37 ffff41 ffff4b ffff55 ffff5f ffff69
ffff73 ffff7d ffff87 ffff91 ffff9b ffffa5 ffffaf ffffb9 ffffc3 ffffcd ffffd7 d7ffc8
e1ffaf f0faa0 f5f5af 96c8ff a0d7ff aae1ff b4ebfa bef5f0 d2fff5 dcffff e6faff f0f0ff
fae6ff aabeff b4b4ff c8aaff be8cc3 c391c8 c896cd cd9bd2 d2a0d7 d7a5dc dcaae1 e1afe6
e6b4eb ebb9f0 f0bef5 f5c3fa fac8ff ffcdff ffd2ff ffd2fa ffcdf5 ffd7f5 dca0ff eb96ff
f5a0f0 ffaae1 ffb9d7 ffc3eb ffc8dc ffd2e6 ffdceb ffdcfa ffe1ff ffe6f5 ffebeb ffd7c3
ffe1b4 ffe6be ffebc8 fff5d2 fff0dc
]])

-- colorblind-theme.json uses one 32-colour list for humans, nations and classic bots.
local COLORBLIND = parse([[
b60056 007700 0076fb db5f11 00b8ae ff75f9 b6c706 00e8ff c7003b 008b3a 7e72ff cf8400
00c8ee ff75dd 90e448 0069e0 cd331d 009e79 cb6af6 b9a600 00d4ff ff83bd 007100 0069ef
c76000 00afb8 ff64e0 9ac407 00dcff ba0025 008445 8f62ef
]])

-- teamColors.Bot: every tribe/bot is drawn in this one flat colour (both themes).
local BOT_COLOR = { 209, 205, 199 }

-- Border derivation per theme: HSL lightness * scale, then darken by an absolute amount.
local BORDER = {
	default = { scale = 1, darken = 0.125 },
	colorblind = { scale = 0.6, darken = 0 },
}

Theme.FOCUSED_BORDER = { 230, 230, 230 } -- focusedBorderColor: the local player's border
Theme.TERRITORY_ALPHA = 0.588 -- mapOverlay.territoryAlpha (fill over terrain)
Theme.TERRITORY_SATURATION = 0.85 -- mapOverlay.territorySaturation
Theme.FRIENDLY_TINT = { 0, 255, 0 } -- border tint where an allied territory touches ours
Theme.FRIENDLY_TINT_RATIO = 0.35
Theme.NAME_SHADE = { Human = 0, Nation = 0.3, Bot = 0.4 } -- name.nameShade*: grey level of name text

-- Terrain (OpenFront ColorUtils.encodeTerrainTile + render-settings.json terrain colours)
local BACKGROUND = { 60, 60, 60 } -- #3c3c3c: outside the map and impassable peaks
local OCEAN = { 71, 133, 181 } -- #4785b5
local SAND = { 204, 203, 158 } -- #CCCB9E
local PLAINS = { 190, 220, 138 } -- #BEDC8A
local HIGHLAND = { 220, 203, 158 } -- #DCCB9E
local MOUNTAIN = { 230, 230, 230 } -- #e6e6e6
Theme.BACKGROUND = Color3.fromRGB(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3])

-- Terrain byte: bit7 land, bit6 shoreline, bit5 ocean, bits0-4 magnitude (31 = impassable).
function Theme.terrainRGB(b: number): (number, number, number)
	local mag = bit32.band(b, 31)
	local shore = bit32.band(b, 64) ~= 0
	if b >= 128 then
		if mag == 31 then
			return BACKGROUND[1], BACKGROUND[2], BACKGROUND[3]
		elseif shore then
			return SAND[1], SAND[2], SAND[3]
		elseif mag < 10 then
			return PLAINS[1], PLAINS[2] - 2 * mag, PLAINS[3]
		elseif mag < 20 then
			local m = 2 * (mag - 10)
			return math.min(255, HIGHLAND[1] + m), math.min(255, HIGHLAND[2] + m), math.min(255, HIGHLAND[3] + m)
		end
		local m = mag // 2
		return math.min(255, MOUNTAIN[1] + m), math.min(255, MOUNTAIN[2] + m), math.min(255, MOUNTAIN[3] + m)
	end
	if shore then
		-- shoreline water: 70% ocean + 30% white
		return math.floor(0.7 * OCEAN[1] + 76.5 + 0.5), math.floor(0.7 * OCEAN[2] + 76.5 + 0.5), math.floor(0.7 * OCEAN[3] + 76.5 + 0.5)
	end
	-- deep water (lakes too) darkens with depth
	local m = math.min(mag, 10)
	return math.max(0, OCEAN[1] - m), math.max(0, OCEAN[2] - m), math.max(0, OCEAN[3] - m)
end

-- Terrain shading off: one land colour, one water colour (impassable peaks stay background).
function Theme.flatTerrainRGB(b: number): (number, number, number)
	if b >= 128 then
		if bit32.band(b, 31) == 31 then
			return BACKGROUND[1], BACKGROUND[2], BACKGROUND[3]
		end
		return PLAINS[1], PLAINS[2], PLAINS[3]
	end
	return OCEAN[1], OCEAN[2], OCEAN[3]
end

-- Fallout ground (staleNuke* in render-settings.json): dark green with a little per-tile noise.
function Theme.falloutRGB(x: number, y: number): (number, number, number)
	local h = math.sin(x * 12.9898 + y * 78.233) * 43758.5453
	h -= math.floor(h)
	local noise = h * 0.05
	return math.floor((0.05 + noise) * 255 + 0.5), math.floor((0.55 + noise) * 255 + 0.5), math.floor((0.07 + noise) * 255 + 0.5)
end

-- Colour math (HSL for borders, CIE Lab + CIEDE2000 for picking distinct colours)
local function rgbToHsl(r: number, g: number, b: number): (number, number, number)
	r, g, b = r / 255, g / 255, b / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local l = (mx + mn) / 2
	if mx == mn then
		return 0, 0, l
	end
	local d = mx - mn
	local s = if l > 0.5 then d / (2 - mx - mn) else d / (mx + mn)
	local h
	if mx == r then
		h = (g - b) / d + (if g < b then 6 else 0)
	elseif mx == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	return h / 6, s, l
end

local function hue2rgb(p: number, q: number, t: number): number
	if t < 0 then
		t += 1
	elseif t > 1 then
		t -= 1
	end
	if t < 1 / 6 then
		return p + (q - p) * 6 * t
	elseif t < 1 / 2 then
		return q
	elseif t < 2 / 3 then
		return p + (q - p) * (2 / 3 - t) * 6
	end
	return p
end

local function hslToRgb(h: number, s: number, l: number): (number, number, number)
	if s == 0 then
		local v = math.floor(l * 255 + 0.5)
		return v, v, v
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	return math.floor(hue2rgb(p, q, h + 1 / 3) * 255 + 0.5),
		math.floor(hue2rgb(p, q, h) * 255 + 0.5),
		math.floor(hue2rgb(p, q, h - 1 / 3) * 255 + 0.5)
end

-- ThemeProvider.borderColor: lightness * borderLightnessScale, then darken(borderDarken).
function Theme.borderRGB(r: number, g: number, b: number, colorblind: boolean?): (number, number, number)
	local cfg = if colorblind then BORDER.colorblind else BORDER.default
	local h, s, l = rgbToHsl(r, g, b)
	l = math.clamp(l * cfg.scale - cfg.darken, 0, 1)
	return hslToRgb(h, s, l)
end

local function toLab(c: { number }): { number }
	local function lin(v: number): number
		v /= 255
		return if v <= 0.04045 then v / 12.92 else ((v + 0.055) / 1.055) ^ 2.4
	end
	local r, g, b = lin(c[1]), lin(c[2]), lin(c[3])
	local x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
	local y = r * 0.2126 + g * 0.7152 + b * 0.0722
	local z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
	local function f(t: number): number
		return if t > 0.008856 then t ^ (1 / 3) else 7.787 * t + 16 / 116
	end
	local fx, fy, fz = f(x), f(y), f(z)
	return { 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz) }
end

-- CIEDE2000 colour difference (what colord's .delta() uses in ColorAllocator).
local function deltaE2000(a: { number }, b: { number }): number
	local L1, a1, b1 = a[1], a[2], a[3]
	local L2, a2, b2 = b[1], b[2], b[3]
	local rad, deg = math.pi / 180, 180 / math.pi
	local C1, C2 = math.sqrt(a1 * a1 + b1 * b1), math.sqrt(a2 * a2 + b2 * b2)
	local Cm = (C1 + C2) / 2
	local G = 0.5 * (1 - math.sqrt(Cm ^ 7 / (Cm ^ 7 + 25 ^ 7)))
	local a1p, a2p = a1 * (1 + G), a2 * (1 + G)
	local C1p, C2p = math.sqrt(a1p * a1p + b1 * b1), math.sqrt(a2p * a2p + b2 * b2)
	local h1p = if C1p == 0 then 0 else (math.atan2(b1, a1p) * deg) % 360
	local h2p = if C2p == 0 then 0 else (math.atan2(b2, a2p) * deg) % 360
	local dLp, dCp = L2 - L1, C2p - C1p
	local dhp = 0
	if C1p * C2p ~= 0 then
		dhp = h2p - h1p
		if dhp > 180 then
			dhp -= 360
		elseif dhp < -180 then
			dhp += 360
		end
	end
	local dHp = 2 * math.sqrt(C1p * C2p) * math.sin(dhp / 2 * rad)
	local Lpm, Cpm = (L1 + L2) / 2, (C1p + C2p) / 2
	local hpm = h1p + h2p
	if C1p * C2p ~= 0 then
		if math.abs(h1p - h2p) > 180 then
			hpm = if h1p + h2p < 360 then (h1p + h2p + 360) / 2 else (h1p + h2p - 360) / 2
		else
			hpm = (h1p + h2p) / 2
		end
	end
	local T = 1 - 0.17 * math.cos((hpm - 30) * rad) + 0.24 * math.cos(2 * hpm * rad)
		+ 0.32 * math.cos((3 * hpm + 6) * rad) - 0.2 * math.cos((4 * hpm - 63) * rad)
	local dTheta = 30 * math.exp(-(((hpm - 275) / 25) ^ 2))
	local Rc = 2 * math.sqrt(Cpm ^ 7 / (Cpm ^ 7 + 25 ^ 7))
	local Sl = 1 + 0.015 * (Lpm - 50) ^ 2 / math.sqrt(20 + (Lpm - 50) ^ 2)
	local Sc = 1 + 0.045 * Cpm
	local Sh = 1 + 0.015 * Cpm * T
	local Rt = -math.sin(2 * dTheta * rad) * Rc
	local tl, tc, th = dLp / Sl, dCp / Sc, dHp / Sh
	return math.sqrt(tl * tl + tc * tc + th * th + Rt * tc * th)
end

-- ColorAllocator: stable, maximally distinct colours from a pool, then a fallback pool
local Allocator = {}
Allocator.__index = Allocator

local function newAllocator(colors: { { number } }, fallback: { { number } }, rng: Random)
	local all = table.clone(colors)
	for _, c in fallback do
		all[#all + 1] = c
	end
	return setmetatable({ available = table.clone(colors), refill = all, assigned = {}, labs = {}, count = 0, rng = rng }, Allocator)
end

-- Returns { r, g, b } for key (any value; nil = always a new colour).
function Allocator:assign(key: any): { number }
	if key ~= nil and self.assigned[key] then
		return self.assigned[key]
	end
	if #self.available == 0 then
		self.available = table.clone(self.refill)
	end
	local index
	if self.count == 0 or self.count > 50 then
		index = self.rng:NextInteger(1, #self.available)
	else
		-- the available colour whose nearest assigned colour is farthest away
		local best = -1
		index = 1
		for i, c in self.available do
			local lab = toLab(c)
			local nearest = math.huge
			for _, other in self.labs do
				local d = deltaE2000(lab, other)
				if d < nearest then
					nearest = d
				end
			end
			if nearest > best then
				best, index = nearest, i
			end
		end
	end
	local c = table.remove(self.available, index) :: { number }
	self.count += 1
	self.labs[#self.labs + 1] = toLab(c)
	if key ~= nil then
		self.assigned[key] = c
	end
	return c
end

local function pack(c: { number }): number
	return c[1] * 65536 + c[2] * 256 + c[3]
end

-- Server: one set of pools per round.
function Theme.newRoundColors()
	local rng = Random.new()
	local pools = {
		Human = newAllocator(HUMAN, FALLBACK, rng),
		Nation = newAllocator(NATION, NATION, rng),
	}
	function pools.take(_self, kind: string): number
		local pool = pools[kind]
		if not pool then
			return pack(BOT_COLOR)
		end
		return pack(pool:assign(nil))
	end
	return pools
end

-- Client: display colours (colour-blind remap) and precomputed paint colours
-- Colours the server hands out from the default palettes. A human colour outside this set is a
-- cosmetic (Progression) colour, which OpenFront keeps even in the colour-blind palette.
local THEMED: { [number]: boolean } = {}
for _, list in { HUMAN, NATION, FALLBACK } do
	for _, c in list do
		THEMED[pack(c)] = true
	end
end

local clientRng = Random.new(1)
local cbPools: { [string]: any } = {}

-- Team colours (ThemeProvider.teamColorForPlayer / generateTeamColors, render/gl/*-theme.json)
local TEAM_COLORS = {
	Red = "#eb3333", Blue = "#2962ff", Teal = "#06b6d4", Purple = "#9234ea", Yellow = "#e7b008",
	Orange = "#ff7f0e", Green = "#41be52", Bot = "#d1cdc7", Humans = "#2962ff", Nations = "#eb3333",
}
local TEAM_COLORS_CB = {
	Red = "#d55e00", Blue = "#0072b2", Teal = "#009e73", Purple = "#cc79a7", Yellow = "#f0e442",
	Orange = "#e69f00", Green = "#56b4e9", Bot = "#d1cdc7", Humans = "#0072b2", Nations = "#d55e00",
}
Theme.TEAM_ORDER = { "Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Teal" }

local function hexRGB(h: string): { number }
	return { tonumber(h:sub(2, 3), 16) :: number, tonumber(h:sub(4, 5), 16) :: number, tonumber(h:sub(6, 7), 16) :: number }
end

local function labToRgb(L: number, A: number, B: number): { number }
	local fy = (L + 16) / 116
	local fx, fz = fy + A / 500, fy - B / 200
	local function finv(t: number): number
		return if t ^ 3 > 0.008856 then t ^ 3 else (t - 16 / 116) / 7.787
	end
	local x, y, z = finv(fx) * 0.95047, finv(fy), finv(fz) * 1.08883
	local r = x * 3.2406 + y * -1.5372 + z * -0.4986
	local g = x * -0.9689 + y * 1.8758 + z * 0.0415
	local b = x * 0.0557 + y * -0.2040 + z * 1.0570
	local function gam(v: number): number
		v = if v <= 0.0031308 then 12.92 * v else 1.055 * v ^ (1 / 2.4) - 0.055
		return math.clamp(math.floor(v * 255 + 0.5), 0, 255)
	end
	return { gam(r), gam(g), gam(b) }
end

-- simpleHash (Util.ts): Java-style string hash, absolute value.
local function simpleHash(s: string): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 4294967296
	end
	if h >= 2147483648 then
		h -= 4294967296
	end
	return math.abs(h)
end

-- generateTeamColors: 64 variations around the base (hue +-6, chroma +-10 %, lightness +-18),
-- index 0 is the base; tribes ("Bot") stay one flat colour.
local function teamVariation(team: string, index: number, colorblind: boolean?): { number }
	local base = hexRGB((if colorblind then TEAM_COLORS_CB else TEAM_COLORS)[team] or TEAM_COLORS.Bot)
	if team == "Bot" or index == 0 then
		return base
	end
	local lab = toLab(base)
	local c0 = math.sqrt(lab[2] ^ 2 + lab[3] ^ 2)
	local h0 = math.deg(math.atan2(lab[3], lab[2])) % 360
	local golden = 137.508
	local h = (h0 + ((index * golden) % 12) - 6 + 360) % 360
	local c = math.clamp(c0 * (1 + 0.1 * math.sin(index * 0.7)), 10, 130)
	local l = math.clamp(lab[1] + 18 * math.sin(index * golden * math.pi / 180), 25, 80)
	return labToRgb(l, c * math.cos(math.rad(h)), c * math.sin(math.rad(h)))
end

-- Packed colour for one player on a team (stable per player, like teamColorForPlayer).
function Theme.teamPlayerColor(team: string, playerKey: string, colorblind: boolean?): number
	local c = teamVariation(team, simpleHash(playerKey) % 64, colorblind)
	return math.floor(c[1]) * 65536 + math.floor(c[2]) * 256 + math.floor(c[3])
end

-- Base team colour (team stats rows, "Your team" label).
function Theme.teamColor(team: string, colorblind: boolean?): Color3
	local c = teamVariation(team, 0, colorblind)
	return Color3.fromRGB(c[1], c[2], c[3])
end

function Theme.resetClient()
	clientRng = Random.new(1)
	cbPools = {
		Human = newAllocator(COLORBLIND, FALLBACK, clientRng),
		Nation = newAllocator(COLORBLIND, COLORBLIND, clientRng),
	}
end
Theme.resetClient()

function Theme.applyPlayerColors(p: any, colorblind: boolean?)
	local packed = p.serverColor or 0xc8c8c8
	local r, g, b = packed // 65536, (packed // 256) % 256, packed % 256
	if colorblind and p.team and p.team ~= "" and p.teamKey then
		-- Team games: the same variation of the colour-blind team palette.
		local c = Theme.teamPlayerColor(p.team, p.teamKey, true)
		r, g, b = c // 65536, (c // 256) % 256, c % 256
	elseif colorblind and THEMED[packed] and cbPools[p.kind] then
		local c = cbPools[p.kind]:assign(p.id)
		r, g, b = c[1], c[2], c[3]
	end
	p.r, p.g, p.b = r, g, b
	-- fill: territory colour pulled toward its luminance (territorySaturation)
	local luma = 0.299 * r + 0.587 * g + 0.114 * b
	local s = Theme.TERRITORY_SATURATION
	local br, bg, bb = Theme.borderRGB(r, g, b, colorblind)
	p.paint = { luma + (r - luma) * s, luma + (g - luma) * s, luma + (b - luma) * s, br, bg, bb }
end

Theme.DEFAULT_PAINT = { 200, 200, 200, 175, 175, 175 }

return Theme
