--[[
	War Front - the editable player name in the main menu (OpenFront's UsernameInput).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(src/client/components/UsernameInput, core/validations/username.ts, resources/lang/en.json
	"username.*"). Modified version re-implemented in Luau for Roblox; not affiliated with or
	endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.NameInput (ModuleScript), used by MainMenu.
-- NameInput.attach(box: TextBox, toast(msg))
--   The box shows your in-game name (your Roblox display name until you type one). On focus
--   lost the name is checked here (3-20 letters, numbers, spaces, _ - .) and sent to the server
--   (Net "setName"), which runs it through Roblox text filtering and answers "nameResult".
--   An accepted name is saved in Settings "playerName" and re-sent when you join; an empty box
--   goes back to your display name. Names apply from the next round (or right away before the
--   fighting starts).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local net = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")
local Settings = require(script.Parent:WaitForChild("Settings"))

local NameInput = {}

local MIN, MAX = 3, 20 -- MIN_USERNAME_LENGTH / MAX_USERNAME_LENGTH

local function validate(name: string): string?
	if #name > MAX then
		return string.format("Username must not exceed %d characters.", MAX)
	elseif #name < MIN then
		return string.format("Username must be at least %d characters long.", MIN)
	elseif string.find(name, "[^%w _%-%.]") then
		return "Username can only contain letters, numbers, spaces, underscores, hyphens, and periods."
	end
	return nil
end

function NameInput.attach(box: TextBox, toast: (string) -> ())
	local player = Players.LocalPlayer
	local current = player.DisplayName -- last accepted name
	local pending: string? = nil
	box.PlaceholderText = "Enter your username" -- username.enter_username
	box.ClearTextOnFocus = false
	box.Text = current

	local sentSaved = false
	local function send(name: string)
		sentSaved = true
		pending = name
		net:FireServer("setName", name)
	end

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > MAX then
			box.Text = string.sub(box.Text, 1, MAX)
		end
	end)

	box.FocusLost:Connect(function()
		local name = string.gsub(string.gsub(box.Text, "^%s+", ""), "%s+$", "")
		name = string.gsub(name, "%s+", " ")
		if name == current then
			box.Text = current
			return
		end
		if name == "" then
			send("") -- back to the Roblox display name
			return
		end
		local err = validate(name)
		if err then
			toast(err)
			box.Text = current
			return
		end
		send(name)
	end)

	net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind ~= "nameResult" or type(data) ~= "table" then
			return
		end
		if data.ok and type(data.name) == "string" then
			current = data.name
			if not box:IsFocused() then
				box.Text = current
			end
			Settings.set("playerName", if pending == "" then "" else current)
		else
			if type(data.error) == "string" and pending ~= nil then
				toast(data.error)
			end
			if not box:IsFocused() then
				box.Text = current
			end
		end
		pending = nil
	end)

	-- The saved name arrives with the profile: send it once so the server uses it.
	local function sendSaved()
		local saved = Settings.values.playerName
		if not sentSaved and type(saved) == "string" and saved ~= "" then
			sentSaved = true
			box.Text = saved
			send(saved)
		end
	end
	Settings.Changed:Connect(function(key: string)
		if key == "playerName" then
			sendSaved()
		end
	end)
	sendSaved()
end

return NameInput
