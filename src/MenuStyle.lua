--[[
	War Front - angular home screen styling.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- Opt-in styling for MainMenu only; other MenuKit pages retain their existing look.
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make
local Style = {}
local triangle = nil
do
	local ok, img = pcall(function()
		local image = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(64, 64) })
		if not image then return nil end
		local pixels = buffer.create(64 * 64 * 4)
		for y = 0, 63 do
			for x = 63 - y, 63 do buffer.writeu32(pixels, (y * 64 + x) * 4, 4294967295) end
		end
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(64, 64), pixels)
		return image
	end)
	if ok then triangle = img end
end

local function line(parent)
	return make("Frame", { BackgroundColor3 = C.MALIBU, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 3, Parent = parent })
end

local function segment(o, a, b)
	o.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	o.Size = UDim2.fromOffset((b - a).Magnitude, 1.5)
	o.Rotation = math.deg(math.atan2(b.Y - a.Y, b.X - a.X))
end

local function dimensions(parent)
	local scale, ancestor = 1, parent
	while ancestor and not ancestor:IsA("ScreenGui") do
		local uiScale = ancestor:FindFirstChildWhichIsA("UIScale")
		if uiScale then scale *= uiScale.Scale end
		ancestor = ancestor.Parent
	end
	return parent.AbsoluteSize.X / math.max(0.01, scale), parent.AbsoluteSize.Y / math.max(0.01, scale)
end

function Style.panel(parent, fill, cutSize)
	for _, child in parent:GetChildren() do
		if child:IsA("UICorner") or child:IsA("UIStroke") then child:Destroy() end
	end
	parent.BackgroundTransparency = 1
	local bg = make("Frame", { Name = "AngularShape", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 0, Parent = parent })
	local middle = make("Frame", { BackgroundColor3 = fill, BorderSizePixel = 0, ZIndex = 0, Parent = bg })
	local ends = {}
	if triangle then
		for i = 1, 2 do
			ends[i] = make("ImageLabel", { BackgroundTransparency = 1, ImageContent = Content.fromObject(triangle), ImageColor3 = fill, Rotation = if i == 2 then 180 else 0, ZIndex = 0, Parent = bg })
		end
	end
	if parent:IsA("TextLabel") then
		-- Text is drawn above child backgrounds, as with the home action buttons.
		local label = MenuKit.text({ Name = "Label", Size = UDim2.fromScale(1, 1), Text = parent.Text, FontFace = parent.FontFace, TextSize = parent.TextSize, TextColor3 = parent.TextColor3, ZIndex = 4, Parent = parent })
		parent.TextTransparency = 1
		for _, prop in { "Text", "TextSize", "TextColor3" } do
			parent:GetPropertyChangedSignal(prop):Connect(function() label[prop] = parent[prop] end)
		end
	end
	local edges = {}
	for i = 1, 4 do edges[i] = line(bg) end
	local function layout()
		local w, h = dimensions(parent)
		if w < 1 or h < 1 then return end
		local cut = math.min(cutSize or h * 0.5, w * 0.12)
		middle.Position = UDim2.fromOffset(cut, 0)
		middle.Size = UDim2.fromOffset(w - 2 * cut, h)
		if triangle then
			ends[1].Position = UDim2.fromOffset(0, 0)
			ends[2].Position = UDim2.fromOffset(w - cut, 0)
			for _, e in ends do e.Size = UDim2.fromOffset(cut, h) end
		else
			middle.Position = UDim2.new()
			middle.Size = UDim2.fromScale(1, 1)
		end
		local points = { Vector2.new(cut, 0), Vector2.new(w, 0), Vector2.new(w - cut, h), Vector2.new(0, h) }
		for i, e in edges do segment(e, points[i], points[i % 4 + 1]) end
	end
	parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	layout()
	return bg
end

function Style.button(kind, props)
	props.FontFace = F.BOLD
	props.TextSize = props.TextSize or 18
	props.AutoButtonColor = false
	props.BorderSizePixel = 0
	props.TextColor3 = if kind == "tutorial" then C.GRAY900 else C.WHITE
	local b = make("TextButton", props)
	local fill = if kind == "primary" then C.MALIBU elseif kind == "tutorial" then C.CYBER else C.SURFACE
	local bg = Style.panel(b, fill)
	local label = MenuKit.text({ Name = "Label", Size = UDim2.fromScale(1, 1), FontFace = F.BOLD, TextColor3 = b.TextColor3, Text = b.Text, TextSize = b.TextSize, ZIndex = 4, Parent = b })
	b.TextTransparency = 1
	for _, prop in { "Text", "TextSize" } do
		b:GetPropertyChangedSignal(prop):Connect(function() label[prop] = b[prop] end)
	end
	MenuKit.hover(b, function(s)
		local colour = if s == "press" then fill:Lerp(C.BLACK, 0.2) elseif s == "hover" then fill:Lerp(C.WHITE, 0.12) else fill
		for _, o in bg:GetChildren() do
			if o:IsA("ImageLabel") then o.ImageColor3 = colour elseif o:IsA("Frame") and o.ZIndex == 0 then o.BackgroundColor3 = colour end
		end
	end)
	return b
end

-- Draw clipped terrain and its dark footer once per preview/size change.
function Style.card(button, canvas)
	for _, parent in { button, canvas } do
		local corner = parent:FindFirstChildWhichIsA("UICorner")
		if corner then corner:Destroy() end
	end
	button.BackgroundTransparency = 1
	canvas.BackgroundTransparency = 1
	local map = canvas:FindFirstChild("Map")
	local source, drawn, drawing = nil, nil, false
	local edges = {}
	for i = 1, 6 do edges[i] = line(button) end
	local function layout()
		local w, h = dimensions(button)
		if w < 1 or h < 1 then return end
		local cut = math.min(24, w * 0.08, h * 0.15)
		local points = { Vector2.new(cut, 0), Vector2.new(w, 0), Vector2.new(w, h - cut), Vector2.new(w - cut, h), Vector2.new(0, h), Vector2.new(0, cut) }
		for i, e in edges do segment(e, points[i], points[i % 6 + 1]) end
		if source and map and not drawing then
			drawing = true
			local ok = pcall(function()
				local tw = math.min(480, math.round(w))
				local th = math.max(1, math.round(tw * h / w))
				if drawn and drawn.Size ~= Vector2.new(tw, th) then drawn:Destroy(); drawn = nil end
				drawn = drawn or game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(tw, th) })
				if not drawn then return end
				local sw, sh = source.Size.X, source.Size.Y
				local input = source:ReadPixelsBuffer(Vector2.zero, source.Size)
				local pixels = buffer.create(tw * th * 4)
				local zoom = math.max(tw / sw, th / sh)
				local cropX, cropY = (sw - tw / zoom) / 2, (sh - th / zoom) / 2
				local cc = cut * tw / w
				for y = 0, th - 1 do
					for x = 0, tw - 1 do
						if x + y >= cc and (tw - 1 - x) + (th - 1 - y) >= cc then
							local sx = math.clamp(math.floor(cropX + x / zoom), 0, sw - 1)
							local sy = math.clamp(math.floor(cropY + y / zoom), 0, sh - 1)
							local at, to = (sy * sw + sx) * 4, (y * tw + x) * 4
							local shade = if y >= th - 48 * th / h then 0.35 else 1
							for channel = 0, 2 do buffer.writeu8(pixels, to + channel, math.round(buffer.readu8(input, at + channel) * shade)) end
							buffer.writeu8(pixels, to + 3, 255)
						end
					end
				end
				drawn:WritePixelsBuffer(Vector2.zero, drawn.Size, pixels)
				map.ImageContent = Content.fromObject(drawn)
			end)
			if not ok then map.ImageContent = Content.fromObject(source) end
			drawing = false
		end
	end
	button:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	if map then
		map:GetPropertyChangedSignal("ImageContent"):Connect(function()
			if drawing or map.ImageContent.Object == drawn then return end
			source = map.ImageContent.Object
			layout()
		end)
	end
	MenuKit.hover(button, function(state)
		for _, e in edges do e.BackgroundColor3 = if state == "idle" then C.MALIBU else C.AQUARIUS end
	end)
	layout()
end

return Style
