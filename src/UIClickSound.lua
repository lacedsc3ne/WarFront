--[[
	War Front - main menu click sound.
	Copyright (C) 2026 Liam (lacedsc3ne).
]]

-- StarterPlayer.StarterPlayerScripts.UIClickSound (LocalScript)
-- While the main menu is open (PlayerGui attribute FrontlinesMenuOpen, set by MainMenu), every
-- button the player activates (mouse, touch or gamepad) plays SoundKit's "click" cue on the
-- Interface channel, so its volume setting applies. Battle UI stays as it was. Silent: full-screen
-- catchers / backdrops (click outside to close) and buttons with the attribute NoClickSound = true.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local SoundKit = require(script.Parent:WaitForChild("SoundKit"))
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local hooked: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isCatcher(b: GuiButton): boolean
	local cam = Workspace.CurrentCamera
	local view = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local size = b.AbsoluteSize
	return size.X * size.Y > view.X * view.Y * 0.25
end

local function hook(b: Instance)
	if not b:IsA("GuiButton") or hooked[b] then
		return
	end
	hooked[b] = true
	b.Activated:Connect(function()
		if playerGui:GetAttribute("FrontlinesMenuOpen") ~= true then
			return
		end
		if b:GetAttribute("NoClickSound") == true or isCatcher(b) then
			return
		end
		SoundKit.play("click")
	end)
end

for _, d in playerGui:GetDescendants() do
	hook(d)
end
playerGui.DescendantAdded:Connect(hook)
