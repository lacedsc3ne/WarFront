--[[
	War Front - small terrain previews of maps (EditableImage), for the in-match map vote.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- StarterPlayer.StarterPlayerScripts.MapPreview (ModuleScript), used by GameClient.
-- Same colours as the main menu's map cards (MainMenu renderPreview): water shades, plains,
-- highlands, mountains from the terrain byte.
-- MapPreview.get(id, width) -> EditableImage?   nil until ready (rendered in the background)
-- MapPreview.onReady(fn)                         fn(id, width) when a preview finishes

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapUtil = require(Shared:WaitForChild("MapUtil"))

local MapPreview = {}

local PIXEL = table.create(256, 0)
do
	local function lerp(a: number, b: number, t: number): number
		return math.floor(a + (b - a) * t + 0.5)
	end
	local function pack(r: number, g: number, b: number): number
		return r + g * 256 + b * 65536 + 255 * 16777216
	end
	for byte = 0, 255 do
		local r, g, b
		if byte < 128 then
			if bit32.band(byte, 64) ~= 0 then
				r, g, b = 26, 52, 84 -- water next to the coast
			elseif bit32.band(byte, 32) ~= 0 then
				r, g, b = 14, 30, 52 -- open ocean
			else
				r, g, b = 20, 42, 68 -- lakes
			end
		else
			local m = bit32.band(byte, 31)
			if m >= 20 then
				local t = math.min(1, (m - 20) / 11)
				r, g, b = lerp(214, 246, t), lerp(214, 246, t), lerp(204, 242, t) -- mountains
			elseif m >= 10 then
				local t = (m - 10) / 10
				r, g, b = lerp(214, 194, t), lerp(196, 172, t), lerp(148, 126, t) -- highlands
			else
				local t = m / 10
				r, g, b = lerp(184, 158, t), lerp(222, 204, t), lerp(140, 118, t) -- plains
			end
		end
		PIXEL[byte + 1] = pack(r, g, b)
	end
end

local cache: { [string]: any } = {} -- "id@width" -> EditableImage | false
local pending: { [string]: boolean } = {}
local queue = {}
local working = false
local listeners: { (string, number) -> () } = {}

local function render(id: string, targetW: number)
	local folder = Shared:FindFirstChild("Maps")
	local mod = folder and folder:FindFirstChild(id)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local map = MapUtil.load(mod)
	local w, h = map.width, map.height
	local tw = math.clamp(math.floor(targetW), 16, 1024)
	local th = math.clamp(math.floor(tw * h / w + 0.5), 8, 1024)
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(tw, th) })
	if not img then
		return nil
	end
	local buf = buffer.create(tw * th * 4)
	local terrain = map.terrain
	local xs = table.create(tw, 0)
	for x = 0, tw - 1 do
		xs[x + 1] = math.min(w - 1, math.floor((x + 0.5) * w / tw))
	end
	local o = 0
	for y = 0, th - 1 do
		local row = math.min(h - 1, math.floor((y + 0.5) * h / th)) * w
		for x = 1, tw do
			buffer.writeu32(buf, o, PIXEL[buffer.readu8(terrain, row + xs[x]) + 1])
			o += 4
		end
		if y % 48 == 47 then
			task.wait()
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(tw, th), buf)
	return img
end

function MapPreview.onReady(fn: (string, number) -> ())
	listeners[#listeners + 1] = fn
end

function MapPreview.get(id: string, width: number): any?
	local key = id .. "@" .. width
	local v = cache[key]
	if v ~= nil then
		return v or nil
	end
	if not pending[key] then
		pending[key] = true
		table.insert(queue, { id = id, width = width, key = key })
		if not working then
			working = true
			task.spawn(function()
				while #queue > 0 do
					local job = table.remove(queue, 1)
					local ok, img = pcall(render, job.id, job.width)
					if not ok then
						warn("[MapPreview] " .. job.id .. ": " .. tostring(img))
					end
					cache[job.key] = if ok and img then img else false
					pending[job.key] = nil
					for _, fn in listeners do
						task.spawn(fn, job.id, job.width)
					end
					task.wait()
				end
				working = false
			end)
		end
	end
	return nil
end

return MapPreview
