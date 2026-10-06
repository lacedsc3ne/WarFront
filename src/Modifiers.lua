--[[
	War Front - public game modifiers (OpenFront MapPlaylist special lobbies + Utils
	getActiveModifiers badge labels).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
]]

local Modifiers = {}

-- SPECIAL_MODIFIER_POOL: one entry per ticket; more tickets = more likely.
local TICKETS = {
	{ "isRandomSpawn", 4 },
	{ "isCompact", 4 },
	{ "isCrowded", 2 },
	{ "isHardNations", 1 },
	{ "startingGold1M", 2 },
	{ "startingGold5M", 4 },
	{ "startingGold25M", 3 },
	{ "goldMultiplier", 6 },
	{ "isAlliancesDisabled", 1 },
	{ "isNukesDisabled", 1 },
	{ "isSAMsDisabled", 1 },
	{ "isPeaceTime", 1 },
	{ "isWaterNukes", 4 },
	{ "isDoomsdayClock", 4 },
}
local POOL = {}
for _, e in TICKETS do
	for _ = 1, e[2] do
		POOL[#POOL + 1] = e[1]
	end
end

-- MUTUALLY_EXCLUSIVE_MODIFIERS
local EXCLUSIVE = {
	{ "startingGold5M", "startingGold25M" },
	{ "startingGold5M", "startingGold1M" },
	{ "startingGold25M", "startingGold1M" },
	{ "isHardNations", "startingGold25M" },
	{ "isNukesDisabled", "isSAMsDisabled" },
	{ "isNukesDisabled", "isWaterNukes" },
}

-- DOOMSDAY_ROTATION_SPEEDS
Modifiers.SPEEDS = { "slow", "normal", "fast", "veryfast" }
Modifiers.SPEED_NAMES = { slow = "Slow", normal = "Normal", fast = "Fast", veryfast = "Very Fast" }

-- getRandomSpecialGameModifiers: roll 1 (30 %), 2 (50 %) or 3 (20 %) modifiers, minus
-- `reduction`, from the shuffled pool, skipping excluded and mutually exclusive ones.
-- Returns the set of picked keys.
function Modifiers.pick(rng: Random, excluded: { [string]: boolean }, count: number?, reduction: number?): { [string]: boolean }
	local COUNTS = { 1, 1, 1, 2, 2, 2, 2, 2, 3, 3 }
	local k = math.max(0, (count or COUNTS[rng:NextInteger(1, #COUNTS)]) - (reduction or 0))
	local pool = {}
	for _, key in POOL do
		if not excluded[key] then
			pool[#pool + 1] = key
		end
	end
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local selected, n = {}, 0
	for _, key in pool do
		if n >= k then
			break
		end
		if not selected[key] then
			local blocked = false
			for _, pair in EXCLUSIVE do
				if (key == pair[1] and selected[pair[2]]) or (key == pair[2] and selected[pair[1]]) then
					blocked = true
					break
				end
			end
			if not blocked then
				selected[key] = true
				n += 1
			end
		end
	end
	return selected
end

-- PublicGameModifiers from a picked key set (+ a Doomsday speed when the clock was rolled).
function Modifiers.fromKeys(keys: { [string]: boolean }, rng: Random)
	local m = {}
	m.randomSpawn = keys.isRandomSpawn or nil
	m.compact = keys.isCompact or nil
	m.crowded = keys.isCrowded or nil
	m.hardNations = keys.isHardNations or nil
	m.startingGold = if keys.startingGold25M then 25000000
		elseif keys.startingGold5M then 5000000
		elseif keys.startingGold1M then 1000000
		else nil
	m.goldMultiplier = if keys.goldMultiplier then 2 else nil
	m.alliancesDisabled = keys.isAlliancesDisabled or nil
	m.nukesDisabled = keys.isNukesDisabled or nil
	m.samsDisabled = keys.isSAMsDisabled or nil
	m.peaceTime = keys.isPeaceTime or nil
	m.waterNukes = keys.isWaterNukes or nil
	m.doomsday = if keys.isDoomsdayClock then Modifiers.SPEEDS[rng:NextInteger(1, #Modifiers.SPEEDS)] else nil
	return m
end

-- True when the set holds anything besides `except`.
function Modifiers.any(m, except: string?): boolean
	for k, v in m do
		if k ~= except and v then
			return true
		end
	end
	return false
end

-- getActiveModifiers badge labels, in OpenFront's order (the lobby card sorts them longest first).
function Modifiers.labels(m): { string }
	local out = {}
	if not m then
		return out
	end
	local function add(s)
		out[#out + 1] = s
	end
	if m.randomSpawn then add("Random Spawn") end
	if m.compact then add("Compact Map") end
	if m.crowded then add("Crowded") end
	if m.hardNations then add("Hard Nations") end
	if m.startingGold then
		local millions = m.startingGold / 1000000
		add((if millions == math.floor(millions) then string.format("%d", millions) else tostring(millions)) .. "M Starting Gold")
	end
	if m.goldMultiplier then add("x" .. tostring(m.goldMultiplier) .. " Gold Multiplier") end
	if m.alliancesDisabled then add("Alliances Disabled") end
	if m.portsDisabled then add("Ports Disabled") end
	if m.nukesDisabled then add("Nukes Disabled") end
	if m.samsDisabled then add("SAMs Disabled") end
	if m.peaceTime then add("4min Peace") end
	if m.waterNukes then add("Water Nukes") end
	if m.doomsday then
		local speed = Modifiers.SPEED_NAMES[m.doomsday]
		add(if speed then "Doomsday Clock: " .. speed else "Doomsday Clock")
	end
	return out
end

-- disabledUnits built from the modifiers (our unit kind names).
function Modifiers.disabledUnits(m): { string }
	local out = {}
	if m and m.nukesDisabled then
		for _, k in { "MissileSilo", "AtomBomb", "HydrogenBomb", "MIRV", "SAM" } do
			out[#out + 1] = k
		end
	end
	if m and m.samsDisabled and not table.find(out, "SAM") then
		out[#out + 1] = "SAM"
	end
	return out
end

-- getSpawnImmunityDuration (seconds); 4min peace overrides it.
function Modifiers.immunitySeconds(m, hvn: boolean): number
	if m and m.peaceTime then
		return 240
	end
	if hvn then
		return 5
	end
	local gold = m and m.startingGold
	if gold and gold >= 25000000 then
		return 150
	elseif gold and gold >= 5000000 then
		return 30 + 15 -- SAM_CONSTRUCTION_TICKS + 15 s
	end
	return 5
end

return Modifiers
