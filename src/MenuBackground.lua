--[[
	War Front - original-resolution menu artwork.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under GNU AGPL v3 or later.
]]

-- Exact RGBA pixels from assets/menu/river-background.png, split at Roblox's image limit.
local tiles = nil
local Background = {}
function Background.load()
	if tiles then return tiles end
	local chunks = {}
	for i = 1, 20 do chunks[i] = require(script.Parent:WaitForChild("MenuBackgroundData" .. i)) end
	local encoding = game:GetService("EncodingService")
	local pixels = encoding:DecompressBuffer(encoding:Base64Decode(buffer.fromstring(table.concat(chunks))), Enum.CompressionAlgorithm.Zstd)
	local result = {}
	for _, x in {0, 1024} do
		local width = math.min(1024, 1673 - x)
		local image = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(width, 940) })
		if not image then
			for _, t in result do t.image:Destroy() end
			-- On devices with a lower image-memory budget, retain a usable background.
			image = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(1024, 574) })
			if not image then return nil end
			local small = buffer.create(1024 * 574 * 4)
			for sy = 0, 573 do
				for sx = 0, 1023 do
					local at = (math.min(939, math.floor((sy + 0.5) * 940 / 574)) * 1673 + math.min(1674, math.floor((sx + 0.5) * 1673 / 1024))) * 4
					buffer.copy(small, (sy * 1024 + sx) * 4, pixels, at, 4)
				end
			end
			image:WritePixelsBuffer(Vector2.zero, image.Size, small)
			tiles = {{image=image, x=0, width=1673, quality="Standard"}}
			return tiles
		end
		local block = buffer.create(width * 940 * 4)
		for y = 0, 939 do buffer.copy(block, y * width * 4, pixels, (y * 1673 + x) * 4, width * 4) end
		image:WritePixelsBuffer(Vector2.zero, image.Size, block)
		table.insert(result, {image=image, x=x, width=width, quality="Original"})
	end
	tiles = result
	return tiles
end
return Background
