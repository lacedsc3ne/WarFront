--[[
	War Front - client sprite helper: OpenFront unit sprites and name-plate status
	icons drawn with shared EditableImages.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Unit look ported from OpenFront (AGPL-3.0): src/client/render/gl/passes/UnitPass.ts,
	shaders/unit/unit.vert.glsl + unit.frag.glsl and render-settings.json "unit" (13-tile cell,
	grey-band recolouring, hot-colour flicker for missiles, hydrogen bomb glow).
	Sprites © OpenFront, CC BY-SA 4.0 (see Shared.Sprites / gen_sprites.py). Modified version
	re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.SpriteKit (ModuleScript), used by GameClient and NameLabels.
--
-- SpriteKit.image(name, props) -> ImageLabel?   one Shared.Sprites image (nil if unavailable);
--   every label showing the same name shares ONE EditableImage.
-- SpriteKit.set(imageLabel, name) -> boolean     switch such a label to another sprite
-- SpriteKit.unit(kind, props) -> Frame          a unit sprite: a holder Frame (AnchorPoint 0.5)
--   with one tinted layer per colour band. kind: "Transport" | "TradeShip" | "Warship" |
--   "AtomBomb" | "HydrogenBomb" | "SAMMissile" | "MIRV" | "Shell" | "MIRVWarhead" | "TrainEngine" |
--   "TrainCarriage" | "TrainCarriageLoaded". Size it with SpriteKit.cellPx(zoom).
-- SpriteKit.paint(holder, territory: Color3, border: Color3)   owner colours (UnitPass bands)
-- SpriteKit.flicker(holder, serverTime, hash)   missiles: cycle red/orange/yellow/white
-- SpriteKit.cellPx(zoom) -> number              on-screen size of the 13-tile unit cell
-- SpriteKit.owner(p) -> (territory, border)     a roster entry's colours (Theme.applyPlayerColors)

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sprites = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sprites"))

local SpriteKit = {}

local CELL = 13 -- UnitPass atlas cell / render-settings unit.unitSize (full-resolution tiles)
local MAP_SCALE = 4 -- one of our tiles = 4 OpenFront tiles per axis
local FLICKER_SPEED = 0.3 -- unit.flickerSpeed (per game tick)
local TICK_RATE = 10 -- OpenFront ticks per second
local GLOW_SCALE = 2.2 -- unit.hBombGlowScale
local GLOW_COLOR = Color3.new(1, 0.72, 0.15)
local GLOW_STRENGTH = 0.5
local FLICKER = {
	Color3.new(1, 0, 0),
	Color3.new(1, 0.5, 0),
	Color3.new(1, 1, 0),
	Color3.new(1, 1, 1),
}
local BANDS = { "B", "M", "C", "A", "W" } -- drawn in this order (dark band first)

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = table.create(256, 0)
for i = 1, 64 do
	DEC[string.byte(B64, i)] = i - 1
end

local function decode(s: string): buffer
	local n = #s
	local pad = 0
	if string.sub(s, -2) == "==" then
		pad = 2
	elseif string.sub(s, -1) == "=" then
		pad = 1
	end
	local len = n // 4 * 3 - pad
	local out = buffer.create(len)
	local o = 0
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = DEC[a] * 262144 + DEC[b] * 4096 + DEC[c or 61] * 64 + DEC[d or 61]
		if o < len then
			buffer.writeu8(out, o, v // 65536)
		end
		if o + 1 < len then
			buffer.writeu8(out, o + 1, (v // 256) % 256)
		end
		if o + 2 < len then
			buffer.writeu8(out, o + 2, v % 256)
		end
		o += 3
	end
	return out
end

local cache: { [string]: any } = {} -- name -> EditableImage | false
local unavailable = false

local function editableFor(name: string): any
	local cached = cache[name]
	if cached ~= nil then
		return cached or nil
	end
	cache[name] = false
	if unavailable then
		return nil
	end
	local format, size, data = Sprites.get(name)
	if not format or not size or not data then
		return nil
	end
	local ok, img = pcall(function()
		local raw = decode(data)
		local px = raw
		if format == "A" then
			px = buffer.create(size * size * 4)
			buffer.fill(px, 0, 255)
			for i = 0, size * size - 1 do
				buffer.writeu8(px, i * 4 + 3, buffer.readu8(raw, i))
			end
		end
		local ei = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
		if not ei then
			error("CreateEditableImage returned nil")
		end
		ei:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), px)
		return ei
	end)
	if ok and img then
		cache[name] = img
		return img
	end
	unavailable = true
	warn("[War Front] Map sprites unavailable (EditableImage): " .. tostring(img))
	return nil
end

local function apply(inst: Instance, props: { [string]: any }?): Instance?
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(inst :: any)[k] = v
			end
		end
	end
	return parent
end

function SpriteKit.has(name: string): boolean
	return Sprites.has(name) and editableFor(name) ~= nil
end

function SpriteKit.image(name: string, props: { [string]: any }?): ImageLabel?
	local ei = editableFor(name)
	if not ei then
		return nil
	end
	local img = Instance.new("ImageLabel")
	img.Name = name
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.ScaleType = Enum.ScaleType.Stretch
	img.Size = UDim2.fromOffset(16, 16)
	img.ImageContent = Content.fromObject(ei)
	local parent = apply(img, props)
	if parent then
		img.Parent = parent
	end
	return img
end

-- Switches an image made by SpriteKit.image to another sprite (false if unavailable).
function SpriteKit.set(label: ImageLabel, name: string): boolean
	local ei = editableFor(name)
	if ei then
		label.ImageContent = Content.fromObject(ei)
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Units
--------------------------------------------------------------------------------
function SpriteKit.cellPx(zoom: number): number
	return CELL / MAP_SCALE * zoom
end

function SpriteKit.owner(p: any): (Color3, Color3)
	if not p then
		return Color3.fromRGB(200, 200, 200), Color3.fromRGB(175, 175, 175)
	end
	local territory = Color3.fromRGB(p.r or 200, p.g or 200, p.b or 200)
	local paint = p.paint
	local border = if paint then Color3.fromRGB(paint[4], paint[5], paint[6]) else territory:Lerp(Color3.new(0, 0, 0), 0.3)
	return territory, border
end

function SpriteKit.unit(kind: string, props: { [string]: any }?): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Unit_" .. kind
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromOffset(8, 8)
	local parent = apply(holder, props)
	local z = holder.ZIndex
	if kind == "HydrogenBomb" then
		local glow = SpriteKit.image("UGlow", {
			Name = "Glow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(GLOW_SCALE, GLOW_SCALE),
			ImageColor3 = GLOW_COLOR,
			ImageTransparency = 1 - GLOW_STRENGTH,
			ZIndex = z,
			Parent = holder,
		})
		if glow then
			glow.ResampleMode = Enum.ResamplerMode.Default
		end
	end
	local any = false
	for i, band in BANDS do
		local name = "U" .. kind .. band
		if Sprites.has(name) then
			local img = SpriteKit.image(name, {
				Name = band,
				Size = UDim2.fromScale(1, 1),
				ResampleMode = Enum.ResamplerMode.Pixelated,
				ZIndex = z,
				Parent = holder,
			})
			any = any or img ~= nil
		end
	end
	if not any then
		-- EditableImage unavailable: a small diamond-ish dot in the territory band's place.
		local dot = Instance.new("Frame")
		dot.Name = "A"
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		local s = if kind == "Warship" then 11 / CELL elseif kind == "HydrogenBomb" then 9 / CELL else 5 / CELL
		dot.Size = UDim2.fromScale(s, s)
		dot.Rotation = 45
		dot.BorderSizePixel = 0
		dot.ZIndex = z
		dot.Parent = holder
	end
	if parent then
		holder.Parent = parent
	end
	return holder
end

local function setBand(holder: Instance, band: string, c: Color3)
	local layer = holder:FindFirstChild(band)
	if layer then
		if layer:IsA("ImageLabel") then
			layer.ImageColor3 = c
		elseif layer:IsA("Frame") then
			layer.BackgroundColor3 = c
		end
	end
end

-- unit.frag.glsl four-band replacement: 180 -> territory, 130 -> mix, 100 -> centre, 70 -> border.
function SpriteKit.paint(holder: Instance, territory: Color3, border: Color3)
	setBand(holder, "A", territory)
	setBand(holder, "C", territory)
	setBand(holder, "M", territory:Lerp(border, 0.5))
	setBand(holder, "B", border)
	setBand(holder, "W", territory) -- shell / MIRV warhead (255 reads as the light band)
end

-- Missiles cycle through hot colours, phase-offset per unit (hash 0..1).
function SpriteKit.flicker(holder: Instance, serverTime: number, hash: number)
	local phase = (serverTime * TICK_RATE * FLICKER_SPEED + hash) % 1
	local idx = math.floor(phase * 4) % 4
	SpriteKit.paint(holder, FLICKER[idx + 1], FLICKER[(idx + 2) % 4 + 1])
end

return SpriteKit
