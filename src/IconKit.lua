--[[
	War Front - client icon helper (OpenFront icons drawn with EditableImage).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Icons © OpenFront, CC BY-SA 4.0. Modified version re-implemented in Luau for Roblox; not
	affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.IconKit (ModuleScript), used by GameClient, Leaderboard,
-- ContextMenu and HoverPanel.
-- IconKit.image(name, props) -> ImageLabel
--   A transparent, ScaleType.Fit ImageLabel showing icon `name` (see Shared.Icons / gen_icons.py).
--   `props` are applied to it (Size, Position, AnchorPoint, ImageColor3, LayoutOrder, ZIndex,
--   Parent, ...). White icons can be tinted with ImageColor3. Each icon name is decoded lazily into
--   ONE EditableImage that every ImageLabel shares (ImageContent = Content.fromObject(img)).
--   If EditableImage isn't available (Studio: Game Settings > Security > "Allow Mesh / Image
--   APIs"), the label gets a TextLabel child with a fallback glyph instead, which follows the
--   label's ImageColor3 / ImageTransparency.
-- IconKit.set(imageLabel, name) - switches an icon made by IconKit.image to another name.
-- IconKit.KIND[structureOrUnitKind] -> icon name (Config kinds: City, Port, DefensePost, ...).

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Icons = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Icons"))

local IconKit = {}

IconKit.KIND = {
	City = "City",
	Port = "Port",
	DefensePost = "Defense",
	MissileSilo = "Silo",
	SAM = "SAM",
	Factory = "Factory",
	MIRV = "MIRV",
	AtomBomb = "AtomBomb",
	HydrogenBomb = "HBomb",
	Warship = "Warship",
	Factory = "Factory",
	MIRV = "MIRV",
}

-- Text glyphs used when EditableImage can't be created (ASCII only: Gotham lacks most symbols).
local FALLBACK = {
	City = "C",
	Port = "P",
	Defense = "D",
	Silo = "M",
	SAM = "S",
	Factory = "F",
	MIRV = "V",
	AtomBomb = "A",
	HBomb = "H",
	Warship = "W",
	TradeShip = "T",
	Boat = "B",
	Gold = "$",
	Troops = "T",
	Alliance = "+",
	Traitor = "!",
	Embargo = "E",
	Target = "o",
	Sword = "x",
	Leaderboard = "#",
	Settings = "*",
	Info = "i",
	DonateGold = "$",
	DonateTroops = "T",
	Close = "X",
	Crown = "W",
	Explosion = "*",
	Land = "L",
	Build = "B",
	Emoji = ":)",
	Back = "<",
	Soldier = "T",
	Factory = "F",
	MIRV = "V",
	Chat = "...",
	Exit = ">",
	LeaderboardRegular = "#",
	Tree = "^",
	UpperLimit = "^",
	Profile = "@",
	Stop = "/",
	Play = ">",
	Pause = "||",
	FastForward = ">>",
}

local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)

-- base64 -> buffer
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
local unavailable = false -- set once EditableImage creation fails, so we stop trying

local function editableFor(name: string): any
	local cached = cache[name]
	if cached ~= nil then
		return cached or nil
	end
	cache[name] = false
	if unavailable then
		return nil
	end
	local format, data = Icons.get(name)
	if not format or not data then
		return nil
	end
	local size = Icons.SIZE
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
	warn("[War Front] Icons fall back to text (EditableImage unavailable): " .. tostring(img))
	return nil
end

local function fallbackGlyph(label: ImageLabel, name: string)
	local glyph = label:FindFirstChild("IconGlyph") :: TextLabel?
	if not glyph then
		local g = Instance.new("TextLabel")
		g.Name = "IconGlyph"
		g.BackgroundTransparency = 1
		g.Size = UDim2.fromScale(1, 1)
		g.FontFace = FONT_BOLD
		g.TextScaled = true
		g.ZIndex = label.ZIndex
		g.TextColor3 = label.ImageColor3
		g.TextTransparency = label.ImageTransparency
		g.Parent = label
		label:GetPropertyChangedSignal("ImageColor3"):Connect(function()
			g.TextColor3 = label.ImageColor3
		end)
		label:GetPropertyChangedSignal("ImageTransparency"):Connect(function()
			g.TextTransparency = label.ImageTransparency
		end)
		label:GetPropertyChangedSignal("ZIndex"):Connect(function()
			g.ZIndex = label.ZIndex
		end)
		glyph = g
	end
	(glyph :: TextLabel).Text = FALLBACK[name] or "?"
end

function IconKit.set(label: ImageLabel, name: string)
	local ei = editableFor(name)
	if ei then
		label.ImageContent = Content.fromObject(ei)
		local g = label:FindFirstChild("IconGlyph")
		if g then
			g:Destroy()
		end
	else
		fallbackGlyph(label, name)
	end
	label:SetAttribute("Icon", name)
end

function IconKit.image(name: string, props: { [string]: any }?): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = "Icon_" .. name
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.ScaleType = Enum.ScaleType.Fit
	img.Size = UDim2.fromOffset(16, 16)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(img :: any)[k] = v
			end
		end
	end
	IconKit.set(img, name)
	if parent then
		img.Parent = parent
	end
	return img
end

return IconKit
