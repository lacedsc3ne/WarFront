--[[
	War Front - which job this server does (lobby, match or the old single-place mode).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ReplicatedStorage.Shared.Place (ModuleScript), used by the server and the client.
-- Place.role() -> "lobby" | "match" | "standalone"
--   lobby       the root place: main menu, public lobby queue, private lobbies, ranked queue.
--               No rounds are played here; matches start in reserved servers of the match place.
--   match       a reserved server of the match place: one round with the settings the lobby chose,
--               then everyone is sent back to the lobby.
--   standalone  the old behaviour (rounds play in the server you joined). Used while
--               Config.MATCH_PLACE_ID is 0, and in Studio unless a role is picked for testing.
-- Studio testing: set the workspace attribute "WFRole" to "lobby" or "match" before pressing Play.
-- A Studio "match" reads its settings from the workspace attribute "WFMatchConfig" (JSON).
-- The server publishes the role as the workspace attribute "WFPlaceRole" for clients.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Place = {}

local cached: string? = nil

local function compute(): string
	if RunService:IsStudio() then
		local r = workspace:GetAttribute("WFRole")
		if r == "lobby" or r == "match" then
			return r
		end
		return "standalone"
	end
	if Config.MATCH_PLACE_ID == 0 then
		return "standalone"
	end
	if game.PlaceId == Config.MATCH_PLACE_ID then
		return "match"
	end
	return "lobby"
end

function Place.role(): string
	if RunService:IsClient() then
		local r = workspace:GetAttribute("WFPlaceRole")
		if type(r) == "string" then
			return r
		end
		return "standalone"
	end
	if not cached then
		cached = compute()
		workspace:SetAttribute("WFPlaceRole", cached)
	end
	return cached :: string
end

-- Clients: wait (briefly) for the server's role attribute to replicate.
function Place.waitRole(timeout: number?): string
	if RunService:IsClient() then
		local t0 = os.clock()
		while workspace:GetAttribute("WFPlaceRole") == nil and os.clock() - t0 < (timeout or 10) do
			task.wait(0.1)
		end
	end
	return Place.role()
end

function Place.isLobby(): boolean
	return Place.role() == "lobby"
end

function Place.isMatch(): boolean
	return Place.role() == "match"
end

return Place
