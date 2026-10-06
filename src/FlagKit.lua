--[[
	Frontlines (working title) - client flag helper (OpenFront nation flags drawn with EditableImage).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Flags © OpenFront, CC BY-SA 4.0. Modified version re-implemented in Luau for Roblox; not
	affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.FlagKit (ModuleScript), used by NameLabels.
-- FlagKit.has(code) -> boolean            true if Shared.Flags has pixels for this code
-- FlagKit.image(code, props) -> ImageLabel?
--   A transparent, ScaleType.Fit ImageLabel showing flag `code` (see Shared.Flags / gen_flags.py),
--   or nil if the code is unknown or EditableImage is unavailable. `props` are applied to it.
--   Each code is decoded lazily into ONE EditableImage shared by every label.
-- FlagKit.set(imageLabel, code) -> boolean  switch a label to another flag (false = hidden).
-- FlagKit.ASPECT                            width / height of a flag image.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Flags = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Flags"))

local FlagKit = {}
FlagKit.ASPECT = Flags.WIDTH / Flags.HEIGHT

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

local cache: { [string]: any } = {} -- code -> EditableImage | false
local unavailable = false

local function editableFor(code: string): any
	local cached = cache[code]
	if cached ~= nil then
		return cached or nil
	end
	cache[code] = false
	if unavailable then
		return nil
	end
	local data = Flags.get(code)
	if not data then
		return nil
	end
	local w, h = Flags.WIDTH, Flags.HEIGHT
	local ok, img = pcall(function()
		local px = decode(data)
		-- The source SVGs carry a transparent margin; crop to the opaque area so the
		-- flag fills its label box like OpenFront's.
		local x0, y0, x1, y1 = w, h, -1, -1
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				if buffer.readu8(px, (y * w + x) * 4 + 3) > 24 then
					if x < x0 then x0 = x end
					if x > x1 then x1 = x end
					if y < y0 then y0 = y end
					if y > y1 then y1 = y end
				end
			end
		end
		if x1 >= x0 and y1 >= y0 and (x1 - x0 + 1 < w or y1 - y0 + 1 < h) then
			local cw, ch = x1 - x0 + 1, y1 - y0 + 1
			local cropped = buffer.create(cw * ch * 4)
			for y = 0, ch - 1 do
				buffer.copy(cropped, y * cw * 4, px, ((y0 + y) * w + x0) * 4, cw * 4)
			end
			px, w, h = cropped, cw, ch
		end
		local ei = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		if not ei then
			error("CreateEditableImage returned nil")
		end
		ei:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), px)
		return ei
	end)
	if ok and img then
		cache[code] = img
		return img
	end
	unavailable = true
	warn("[Frontlines] Flags hidden (EditableImage unavailable): " .. tostring(img))
	return nil
end

function FlagKit.has(code: string?): boolean
	return code ~= nil and code ~= "" and Flags.has(code)
end

function FlagKit.set(label: ImageLabel, code: string?): boolean
	local ei = if FlagKit.has(code) then editableFor(code :: string) else nil
	if ei then
		label.ImageContent = Content.fromObject(ei)
		label.Visible = true
		label:SetAttribute("Flag", code)
		return true
	end
	label.Visible = false
	label:SetAttribute("Flag", nil)
	return false
end

function FlagKit.image(code: string?, props: { [string]: any }?): ImageLabel?
	if not FlagKit.has(code) or not editableFor(code :: string) then
		return nil
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Flag"
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.ScaleType = Enum.ScaleType.Fit
	img.Size = UDim2.fromOffset(18, 12)
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
	FlagKit.set(img, code)
	if parent then
		img.Parent = parent
	end
	return img
end

return FlagKit
