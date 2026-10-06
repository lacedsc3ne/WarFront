--[[
	War Front - performance overlay (FPS, frame time, ping, slowest client sections).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.PerfOverlay (ModuleScript), used by GameClient.
-- OpenFront PerformanceOverlay: Settings "Performance Overlay" or Shift + D shows a small panel
-- with the current / 60 s average FPS, frame time, ping and the slowest client sections (Perf.lua
-- writes them to the PlayerGui attribute "FrontlinesPerf" every 5 s).
-- PerfOverlay.mount(gui)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent:WaitForChild("Settings"))

local PerfOverlay = {}

local panel: Frame? = nil
local text: TextLabel? = nil
local frames: { number } = {} -- frame timestamps of the last 60 s
local lastFrame = os.clock()
local frameMs = 0
local nextDraw = 0

local function apply()
	if panel then
		panel.Visible = Settings.values.perfOverlay == true
	end
end

local function draw(now: number)
	if not text then
		return
	end
	local n, oneSec = #frames, 0
	for i = n, 1, -1 do
		if now - frames[i] > 1 then
			break
		end
		oneSec += 1
	end
	local span = if n > 1 then frames[n] - frames[1] else 0
	local avg = if span > 0 then (n - 1) / span else 0
	local player = Players.LocalPlayer
	local ping = math.floor(player:GetNetworkPing() * 1000 + 0.5)
	local lines = {
		string.format("FPS: %d  (60 s avg %d)", oneSec, math.floor(avg + 0.5)),
		string.format("Frame: %.1f ms", frameMs),
		string.format("Ping: %d ms", ping),
	}
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local perf = pg and pg:GetAttribute("FrontlinesPerf")
	if type(perf) == "string" and perf ~= "" then
		local k = 0
		for line in string.gmatch(perf, "[^\n]+") do
			k += 1
			if k > 5 then
				break
			end
			lines[#lines + 1] = line
		end
	end
	text.Text = table.concat(lines, "\n")
end

function PerfOverlay.mount(gui: Instance)
	local f = Instance.new("Frame")
	f.Name = "PerfOverlay"
	f.AnchorPoint = Vector2.new(0.5, 0)
	f.Position = UDim2.new(0.5, 0, 0, 56)
	f.AutomaticSize = Enum.AutomaticSize.XY
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BackgroundTransparency = 0.3
	f.ZIndex = 60
	f.Visible = false
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = f
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.Parent = f
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.AutomaticSize = Enum.AutomaticSize.XY
	t.Size = UDim2.fromOffset(0, 0)
	t.Font = Enum.Font.Code
	t.TextSize = 12
	t.TextColor3 = Color3.fromRGB(134, 239, 172)
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.ZIndex = 61
	t.Text = ""
	t.Parent = f
	f.Parent = gui
	panel, text = f, t
	apply()
	Settings.Changed:Connect(function(key: string)
		if key == "perfOverlay" then
			apply()
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= Enum.KeyCode.D then
			return
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
			Settings.set("perfOverlay", not Settings.values.perfOverlay)
		end
	end)
	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		frameMs = (now - lastFrame) * 1000
		lastFrame = now
		if not f.Visible then
			table.clear(frames)
			return
		end
		frames[#frames + 1] = now
		while #frames > 0 and now - frames[1] > 60 do
			table.remove(frames, 1)
		end
		if now >= nextDraw then
			nextDraw = now + 0.25
			draw(now)
		end
	end)
end

return PerfOverlay
