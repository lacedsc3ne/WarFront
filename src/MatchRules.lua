--[[
	War Front - the active round's game rules that both server and clients need (public lobby
	modifiers and host options): disabled units, alliances off, water nukes, Doomsday Clock,
	overtime, gold multiplier, compact map.
	The server writes them as JSON to the workspace attribute "WFMatchRules" at the start of every
	round (attributes replicate), every script reads them through MatchRules.get().
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
]]

local HttpService = game:GetService("HttpService")

local MatchRules = {}

export type Rules = {
	mods: { string }, -- modifier badge labels, in OpenFront's order (lobby card / end screen)
	disabled: { [string]: boolean }, -- unit kinds that can't be built or launched (disabledUnits)
	noAlliances: boolean, -- disableAlliances
	waterNukes: boolean, -- nukes turn land into water instead of fallout
	doomsday: string?, -- Doomsday Clock speed ("slow" | "normal" | "fast" | "veryfast"), nil = off
	overtime: boolean, -- the win share sinks after 30 minutes (public FFA)
	goldMult: number, -- goldMultiplier
	compact: boolean, -- compact map (half size)
}

local EMPTY: Rules = {
	mods = {},
	disabled = {},
	noAlliances = false,
	waterNukes = false,
	doomsday = nil,
	overtime = false,
	goldMult = 1,
	compact = false,
}

local ATTR = "WFMatchRules"
local lastRaw: string? = nil
local cached: Rules = EMPTY

local function normalize(t: any): Rules
	if type(t) ~= "table" then
		return EMPTY
	end
	local disabled = {}
	if type(t.disabled) == "table" then
		for k, v in t.disabled do
			if type(k) == "string" and v == true then
				disabled[k] = true
			elseif type(v) == "string" then
				disabled[v] = true
			end
		end
	end
	local mods = {}
	if type(t.mods) == "table" then
		for _, m in t.mods do
			if type(m) == "string" then
				mods[#mods + 1] = m
			end
		end
	end
	return {
		mods = mods,
		disabled = disabled,
		noAlliances = t.noAlliances == true,
		waterNukes = t.waterNukes == true,
		doomsday = if type(t.doomsday) == "string" then t.doomsday else nil,
		overtime = t.overtime == true,
		goldMult = if type(t.goldMult) == "number" and t.goldMult > 0 then t.goldMult else 1,
		compact = t.compact == true,
	}
end

function MatchRules.get(): Rules
	local raw = workspace:GetAttribute(ATTR)
	if raw ~= lastRaw then
		lastRaw = raw
		cached = EMPTY
		if type(raw) == "string" and raw ~= "" then
			local ok, t = pcall(HttpService.JSONDecode, HttpService, raw)
			if ok then
				cached = normalize(t)
			end
		end
	end
	return cached
end

-- Server: publish the rules of the round that is starting (nil = none).
function MatchRules.set(t: any)
	local rules = normalize(t)
	local list = {}
	for k in rules.disabled do
		list[#list + 1] = k
	end
	table.sort(list)
	workspace:SetAttribute(ATTR, HttpService:JSONEncode({
		mods = rules.mods,
		disabled = list,
		noAlliances = rules.noAlliances,
		waterNukes = rules.waterNukes,
		doomsday = rules.doomsday,
		overtime = rules.overtime,
		goldMult = rules.goldMult,
		compact = rules.compact,
	}))
	return MatchRules.get()
end

function MatchRules.unitDisabled(kind: string): boolean
	return MatchRules.get().disabled[kind] == true
end

function MatchRules.alliancesOff(): boolean
	return MatchRules.get().noAlliances
end

-- Fires fn whenever the rules change.
function MatchRules.changed(fn: () -> ())
	return workspace:GetAttributeChangedSignal(ATTR):Connect(fn)
end

return MatchRules
