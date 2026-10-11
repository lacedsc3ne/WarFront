--[[
	War Front - favourite the game (part of the group rewards).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- StarterPlayer.StarterPlayerScripts.FavoriteGame (ModuleScript), used by MetaClient and the Night shop.
-- Roblox only lets the player's own client check a favourite (AvatarEditorService:GetFavoriteAsync),
-- so the server trusts the client's report ("favorited"); group membership is still checked on the server.
-- FavoriteGame.isFavorite() -> boolean?   nil when Roblox couldn't answer
-- FavoriteGame.prompt() -> boolean?       Roblox's favourite prompt, then the same check
-- FavoriteGame.report(metaFn) -> (ok, message?)   tells the server (only when it is a favourite)

local AvatarEditorService = game:GetService("AvatarEditorService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local FavoriteGame = {}

-- The experience's start place (the lobby); favouriting it favourites the game.
local function placeId(): number
	local id = tonumber(Config.LOBBY_PLACE_ID) or 0
	return if id ~= 0 then id else game.PlaceId
end

function FavoriteGame.isFavorite(): boolean?
	local ok, result = pcall(function()
		return AvatarEditorService:GetFavoriteAsync(placeId(), Enum.AvatarItemType.Asset)
	end)
	if not ok then
		ok, result = pcall(function()
			return (AvatarEditorService :: any):GetFavorite(placeId(), Enum.AvatarItemType.Asset)
		end)
	end
	if ok and type(result) == "boolean" then
		return result
	end
	return nil
end

function FavoriteGame.prompt(): boolean?
	local done = false
	local conn = AvatarEditorService.PromptSetFavoriteCompleted:Connect(function()
		done = true
	end)
	local ok = pcall(function()
		AvatarEditorService:PromptSetFavorite(placeId(), Enum.AvatarItemType.Asset, true)
	end)
	if ok then
		local t0 = os.clock()
		while not done and os.clock() - t0 < 60 do
			task.wait(0.2)
		end
	end
	conn:Disconnect()
	return FavoriteGame.isFavorite()
end

function FavoriteGame.report(metaFn: RemoteFunction): (boolean, string?)
	if FavoriteGame.isFavorite() ~= true then
		return false, nil
	end
	local ok, result, message = pcall(function()
		return metaFn:InvokeServer("favorited")
	end)
	return ok and result == true, if ok then message else nil
end

return FavoriteGame
