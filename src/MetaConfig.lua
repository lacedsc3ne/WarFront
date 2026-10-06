--[[
	Frontlines (working title) - progression, rewards and shop settings.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.

	Nothing sold here affects the match itself (no troops, gold or buildings for Robux):
	competitive conquest games lose players fast when matches can be bought.
]]

local MetaConfig = {}

-- Fill these in after creating them on the Creator Hub (Monetization tab). 0 = disabled.
MetaConfig.GAMEPASS = {
	VIP = 0, -- x1.5 XP and coins, gold name, VIP tag
	AllColors = 0, -- unlocks every territory colour
}
MetaConfig.PRODUCTS = {
	{ id = 0, coins = 500, label = "500 coins" },
	{ id = 0, coins = 1500, label = "1,500 coins" },
	{ id = 0, coins = 5000, label = "5,000 coins" },
}

MetaConfig.VIP_MULT = 1.5

-- Rewards at the end of a round.
MetaConfig.REWARDS = {
	playXP = 40,
	playCoins = 10,
	winXP = 400,
	winCoins = 120,
	podiumCoins = { 60, 35, 20 }, -- placements 1-3 (added to win bonus for 1st)
	podiumXP = { 150, 90, 50 },
	eliminationXP = 30,
	eliminationCoins = 8,
	landXPPerPercent = 6, -- per % of the map at your peak
	minSecondsForReward = 60, -- must have been in the round this long
}

-- Daily login streak (coins). The 7th day repeats.
MetaConfig.DAILY = { 25, 35, 50, 75, 100, 150, 250 }

-- XP needed to go from level L to L+1.
function MetaConfig.xpToNext(level: number): number
	return 150 + 75 * (level - 1)
end

function MetaConfig.levelFromXP(xp: number): (number, number, number)
	local level = 1
	while xp >= MetaConfig.xpToNext(level) do
		xp -= MetaConfig.xpToNext(level)
		level += 1
	end
	return level, xp, MetaConfig.xpToNext(level)
end

-- Territory colours. price = coins; level = minimum level to buy.
MetaConfig.COLORS = {
	{ id = "crimson", name = "Crimson", rgb = { 214, 48, 64 }, price = 0, level = 1 },
	{ id = "royal", name = "Royal Blue", rgb = { 52, 92, 230 }, price = 0, level = 1 },
	{ id = "emerald", name = "Emerald", rgb = { 32, 180, 110 }, price = 250, level = 1 },
	{ id = "sunset", name = "Sunset", rgb = { 255, 140, 40 }, price = 250, level = 2 },
	{ id = "violet", name = "Violet", rgb = { 150, 70, 230 }, price = 400, level = 3 },
	{ id = "gold", name = "Gold", rgb = { 240, 196, 40 }, price = 600, level = 5 },
	{ id = "ice", name = "Ice", rgb = { 140, 220, 255 }, price = 600, level = 5 },
	{ id = "rose", name = "Rose", rgb = { 255, 120, 190 }, price = 800, level = 8 },
	{ id = "obsidian", name = "Obsidian", rgb = { 40, 40, 52 }, price = 1200, level = 12 },
	{ id = "snow", name = "Snow", rgb = { 245, 245, 250 }, price = 1500, level = 15 },
}

function MetaConfig.color(id: string?)
	for _, c in MetaConfig.COLORS do
		if c.id == id then
			return c
		end
	end
	return nil
end

-- Badge ids (create them on the Creator Hub). 0 = disabled.
MetaConfig.BADGES = {
	FirstGame = 0,
	FirstWin = 0,
	FirstNuke = 0,
	Level10 = 0,
}

return MetaConfig
