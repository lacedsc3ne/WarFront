-- War Front 1 vs 1 rank tiers. Copyright (C) 2026 Liam (lacedsc3ne).
-- READY BUT HIDDEN: ranked is a future update, so nothing in the Night menu requires this yet.
-- Turns the existing 1 vs 1 rating (profile.elo, starting at Config.RANKED_START_ELO = 1000) into
-- a friendlier name like "Silver II" plus progress to the next step.
--
-- RankTiers.of(elo) -> { name, tier, division, color, icon, from, to, progress (0..1), toNext }
--   elo nil (no ranked game yet) -> "Unranked"

local Kit = require(script.Parent:WaitForChild("Kit"))
local C = Kit.C

local RankTiers = {}

-- Each tier spans 150 rating, split into divisions III, II, I (50 each); Champion has no divisions.
RankTiers.TIERS = {
	{ name = "Bronze", from = 0, color = Color3.fromRGB(208, 138, 74) },
	{ name = "Silver", from = 1000, color = Color3.fromRGB(192, 201, 222) },
	{ name = "Gold", from = 1150, color = C.YELLOW },
	{ name = "Platinum", from = 1300, color = C.CYAN },
	{ name = "Diamond", from = 1450, color = C.PURPLE },
	{ name = "Champion", from = 1600, color = C.PINK },
}
local DIVISIONS = { "III", "II", "I" }

function RankTiers.of(elo: number?)
	if type(elo) ~= "number" then
		return { name = "Unranked", tier = "Unranked", color = C.MUTED, icon = "Shield", progress = 0, toNext = nil }
	end
	local index = 1
	for i, t in RankTiers.TIERS do
		if elo >= t.from then
			index = i
		end
	end
	local t = RankTiers.TIERS[index]
	local nextTier = RankTiers.TIERS[index + 1]
	if not nextTier then
		return { name = t.name, tier = t.name, color = t.color, icon = "Crown", from = t.from, progress = 1, toNext = nil }
	end
	-- Bronze runs from 0 to 1000, so its divisions are wider; the rest are 150 / 3.
	local span = nextTier.from - t.from
	local step = span / 3
	local d = math.clamp(math.floor((elo - t.from) / step) + 1, 1, 3)
	local from = t.from + (d - 1) * step
	local to = from + step
	return {
		name = t.name .. " " .. DIVISIONS[d],
		tier = t.name,
		division = DIVISIONS[d],
		color = t.color,
		icon = "Shield",
		from = math.floor(from),
		to = math.floor(to),
		progress = math.clamp((elo - from) / step, 0, 1),
		toNext = math.max(0, math.ceil(to - elo)),
	}
end

return RankTiers
