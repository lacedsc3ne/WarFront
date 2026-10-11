--!strict
-- War Front Night menu icons. Copyright (C) 2026 Liam (lacedsc3ne).
-- Pixel data: Tabler Icons (MIT licence), rendered by gen_night_icons.js into NightMenu.IconsData1..N.
-- Icons.SIZE                       pixel size of every icon (square)
-- Icons.has(name) -> boolean
-- Icons.image(name, props) -> ImageLabel   white icon (tint with ImageColor3), Fit, transparent
-- Icons.set(label, name)                   switch an Icons.image label to another icon
-- Each name is decoded once into ONE EditableImage shared by every label. Without EditableImage
-- (Studio: Game Settings > Security > Allow Mesh / Image APIs off) a label shows a small dot.

local AssetService = game:GetService("AssetService")

local Icons = {}
Icons.SIZE = 48

local data: { [string]: string } = {}
for _, child in script.Parent:GetChildren() do
	if child:IsA("ModuleScript") and string.match(child.Name, "^IconsData%d+$") then
		for name, encoded in require(child) :: any do
			data[name] = encoded
		end
	end
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = table.create(256, 0)
for i = 1, 64 do
	DEC[string.byte(B64, i)] = i - 1
end

local function base64(s: string): buffer
	local n = #s
	local pad = if string.sub(s, -2) == "==" then 2 elseif string.sub(s, -1) == "=" then 1 else 0
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

-- Run-length coding from gen_night_icons.js: 0,n = n clear pixels, 255,n = n solid pixels,
-- any other byte = one pixel with that alpha.
function Icons.alpha(name: string): buffer?
	local encoded = data[name]
	if not encoded then
		return nil
	end
	local rle = base64(encoded)
	local size = Icons.SIZE
	local out = buffer.create(size * size)
	local o, i, n = 0, 0, buffer.len(rle)
	while i < n do
		local v = buffer.readu8(rle, i)
		if v == 0 or v == 255 then
			local count = buffer.readu8(rle, i + 1)
			if v == 255 then
				buffer.fill(out, o, 255, count)
			end
			o += count
			i += 2
		else
			buffer.writeu8(out, o, v)
			o += 1
			i += 1
		end
	end
	return out
end

function Icons.has(name: string): boolean
	return data[name] ~= nil
end

local cache: { [string]: EditableImage } = {}
local unavailable = false

local function editable(name: string): EditableImage?
	local hit = cache[name]
	if hit or unavailable then
		return hit
	end
	local alpha = Icons.alpha(name)
	if not alpha then
		warn("[War Front] unknown Night menu icon: " .. name)
		return nil
	end
	local size = Icons.SIZE
	local ok, result = pcall(function()
		local px = buffer.create(size * size * 4)
		buffer.fill(px, 0, 255)
		for p = 0, size * size - 1 do
			buffer.writeu8(px, p * 4 + 3, buffer.readu8(alpha, p))
		end
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
		if not img then
			error("CreateEditableImage returned nil")
		end
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), px)
		return img
	end)
	if ok and result then
		cache[name] = result
		return result
	end
	unavailable = true
	warn("[War Front] Night menu icons fall back to dots (EditableImage unavailable): " .. tostring(result))
	return nil
end

function Icons.set(label: ImageLabel, name: string)
	local img = editable(name)
	local dot = label:FindFirstChild("Fallback")
	if img then
		label.ImageContent = Content.fromObject(img)
		if dot then
			dot:Destroy()
		end
		return
	end
	if not dot then
		local f = Instance.new("Frame")
		f.Name = "Fallback"
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromScale(0.35, 0.35)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = label.ImageColor3
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = f
		f.Parent = label
		label:GetPropertyChangedSignal("ImageColor3"):Connect(function()
			f.BackgroundColor3 = label.ImageColor3
		end)
	end
end

function Icons.image(name: string, props: { [string]: any }?): ImageLabel
	local label = Instance.new("ImageLabel")
	label.Name = "Icon_" .. name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.ScaleType = Enum.ScaleType.Fit
	label.Size = UDim2.fromOffset(20, 20)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(label :: any)[k] = v
			end
		end
	end
	Icons.set(label, name)
	if parent then
		label.Parent = parent
	end
	return label
end

return Icons
