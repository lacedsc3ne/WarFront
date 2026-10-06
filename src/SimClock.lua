--[[
	War Front - the game clock (server time scaled by the game speed).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ReplicatedStorage.Shared.SimClock (ModuleScript), used by the server and the client.
--
-- In a solo round the player can pause or change the game speed (OpenFront's single-player
-- ReplayPanel: x0.5, x1, x2, Max). Everything that is timed in seconds (boats, nukes, trains,
-- build bars, alliance / shield countdowns) uses SimClock.now() instead of
-- workspace:GetServerTimeNow(), so it follows the game speed and stops while paused.
--
--   SimClock.now()        game-clock seconds (equal to server time until the speed first changes)
--   SimClock.speed()      current speed (0 while paused)
--   SimClock.set(speed)   server only: re-anchor the clock at a new speed (0 = paused)
--
-- The anchor (game time, server time, speed) replicates as the workspace attribute "WFSimClock"
-- ("anchorGame,anchorServer,speed" as text, so the doubles keep their precision).

local RunService = game:GetService("RunService")

local SimClock = {}

local ATTR = "WFSimClock"
local anchorGame, anchorServer, speed = 0, 0, 1 -- identity: now() == server time

local function serverTime(): number
	return workspace:GetServerTimeNow()
end

function SimClock.now(): number
	if speed == 1 and anchorGame == anchorServer then
		return serverTime()
	end
	return anchorGame + (serverTime() - anchorServer) * speed
end

function SimClock.speed(): number
	return speed
end

local function parse(v: any)
	if type(v) ~= "string" then
		return
	end
	local a, s, k = string.match(v, "^([%-%d%.e]+),([%-%d%.e]+),([%-%d%.e]+)$")
	if a then
		anchorGame, anchorServer, speed = tonumber(a) or 0, tonumber(s) or 0, tonumber(k) or 1
	end
end

if RunService:IsServer() then
	function SimClock.set(newSpeed: number)
		local nowGame = SimClock.now()
		anchorGame, anchorServer, speed = nowGame, serverTime(), math.max(0, newSpeed)
		workspace:SetAttribute(ATTR, string.format("%.6f,%.6f,%.6f", anchorGame, anchorServer, speed))
	end
else
	function SimClock.set(_newSpeed: number) end
	parse(workspace:GetAttribute(ATTR))
	workspace:GetAttributeChangedSignal(ATTR):Connect(function()
		parse(workspace:GetAttribute(ATTR))
	end)
end

return SimClock
