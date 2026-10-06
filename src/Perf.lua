--[[
	War Front - tiny built-in profiler (per-section time per frame / tick).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- ReplicatedStorage.Shared.Perf (ModuleScript), used by GameClient and GameServer.
-- Perf.start(name) / Perf.stop(name)   time a section (os.clock); nesting different names is fine
-- Perf.wrap(name, fn) -> fn            the same around a function call
-- Every 5 s the totals are written as text to an attribute and reset:
--   client: PlayerGui attribute "FrontlinesPerf", server: workspace attribute "FrontlinesPerfServer"
--   one line per section, slowest first: "name  total ms / 5 s  (calls, worst ms)"
-- Costs two os.clock() calls per section, so it can stay on.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Perf = {}

local started: { [string]: number } = {}
local total: { [string]: number } = {}
local calls: { [string]: number } = {}
local worst: { [string]: number } = {}
local clock = os.clock

function Perf.start(name: string)
	started[name] = clock()
end

function Perf.stop(name: string)
	local t0 = started[name]
	if not t0 then
		return
	end
	local d = clock() - t0
	total[name] = (total[name] or 0) + d
	calls[name] = (calls[name] or 0) + 1
	if d > (worst[name] or 0) then
		worst[name] = d
	end
end

function Perf.wrap(name: string, fn: (...any) -> ...any): (...any) -> ...any
	return function(...)
		local t0 = clock()
		local a, b, c, d = fn(...)
		local dt = clock() - t0
		total[name] = (total[name] or 0) + dt
		calls[name] = (calls[name] or 0) + 1
		if dt > (worst[name] or 0) then
			worst[name] = dt
		end
		return a, b, c, d
	end
end

-- Network handler: time per message kind ("net:<kind>").
function Perf.wrapNet(fn: (string, any) -> ()): (string, any) -> ()
	return function(kind: string, data: any)
		local t0 = clock()
		fn(kind, data)
		local name = "net:" .. tostring(kind)
		local dt = clock() - t0
		total[name] = (total[name] or 0) + dt
		calls[name] = (calls[name] or 0) + 1
		if dt > (worst[name] or 0) then
			worst[name] = dt
		end
	end
end

local WINDOW = 5
task.spawn(function()
	while true do
		task.wait(WINDOW)
		local rows = {}
		for name, t in total do
			rows[#rows + 1] = { name, t }
		end
		table.sort(rows, function(a, b)
			return a[2] > b[2]
		end)
		local lines = {}
		for i = 1, math.min(#rows, 30) do
			local name = rows[i][1]
			lines[i] = string.format("%-22s %7.1f ms  (%d, worst %.1f)", name, rows[i][2] * 1000, calls[name] or 0, (worst[name] or 0) * 1000)
		end
		local text = table.concat(lines, "\n")
		table.clear(total)
		table.clear(calls)
		table.clear(worst)
		if RunService:IsServer() then
			workspace:SetAttribute("FrontlinesPerfServer", text)
		else
			local plr = Players.LocalPlayer
			local pg = plr and plr:FindFirstChild("PlayerGui")
			if pg then
				pg:SetAttribute("FrontlinesPerf", text)
			end
		end
	end
end)

return Perf
