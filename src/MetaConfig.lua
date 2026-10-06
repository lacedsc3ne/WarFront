--[[
	War Front - progression, rewards and shop settings.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.

	Nothing sold here affects the match itself (no troops, gold or buildings for Robux):
	competitive conquest games lose players fast when matches can be bought.
]]

local MetaConfig = {}

-- Fill these in after creating them on the Creator Hub (Monetization tab). 0 = disabled.
MetaConfig.GAMEPASS = {
	VIP = 2008730377, -- x1.5 XP and coins, gold name, VIP tag (199 R$)
	AllColors = 2008508400, -- unlocks every territory colour (299 R$)
}
MetaConfig.PRODUCTS = {
	{ id = 3716869826, coins = 500, label = "500 coins" }, -- 35 R$
	{ id = 3716869865, coins = 1500, label = "1,500 coins" }, -- 89 R$
	{ id = 3716869917, coins = 5000, label = "5,000 coins" }, -- 249 R$
}

MetaConfig.VIP_MULT = 1.5

-- Gameplay perks (game passes). They work in solo, private and public games, never in ranked.
-- icon = IconKit name, shown when the pass has no icon on the Creator Hub yet.
MetaConfig.PERKS = {
	{ key = "startingArmy", id = 2005761784, name = "Starting Army", desc = "Start every match with 25% more troops", icon = "Soldier" }, -- 249 R$
	{ key = "warEconomy", id = 2005449754, name = "War Economy", desc = "15% more passive gold income", icon = "Gold" }, -- 299 R$
	{ key = "rapidGrowth", id = 2006697770, name = "Rapid Growth", desc = "Troops grow 10% faster", icon = "Troops" }, -- 299 R$
	{ key = "secondChance", id = 2005203824, name = "Second Chance", desc = "2 revives per round instead of 1", icon = "Land" }, -- 149 R$
	{ key = "safeLanding", id = 2008658396, name = "Safe Landing", desc = "Spawn shield lasts 10 s longer", icon = "Defense" }, -- 99 R$
}
MetaConfig.PERK_START_TROOPS = 1.25 -- Starting Army: troops x1.25 when the spawn phase ends
MetaConfig.PERK_GOLD = 1.15 -- War Economy: passive gold x1.15
MetaConfig.PERK_GROWTH = 1.10 -- Rapid Growth: troop growth x1.10
MetaConfig.PERK_EXTRA_REVIVES = 1 -- Second Chance
MetaConfig.PERK_SHIELD_SECONDS = 10 -- Safe Landing: personal shield after spawn immunity ends

-- One-use boosts (developer products, or coins). Used in a match from the Boosts button: each at
-- most once per match, not in the first BOOST_DELAY seconds of fighting, never in ranked.
MetaConfig.BOOSTS = {
	{ key = "goldCrate", id = 3716871545, coins = 400, name = "Gold Crate", desc = "+100K gold instantly", icon = "Gold" }, -- 25 R$
	{ key = "reinforcements", id = 3716871574, coins = 400, name = "Reinforcements", desc = "+25% of your troops (up to your max)", icon = "Soldier" }, -- 25 R$
	{ key = "shield", id = 3716871650, coins = 800, name = "Shield", desc = "30 s safe from land attacks (nukes still hit)", icon = "Defense" }, -- 49 R$
	{ key = "nukeVoucher", id = 3716871701, coins = 800, name = "Nuke Voucher", desc = "Your next Atom Bomb is free (needs a silo)", icon = "AtomBomb" }, -- 49 R$
}
MetaConfig.BOOST_DELAY = 30 -- seconds after the spawn phase before boosts can be used
MetaConfig.BOOST_GOLD = 100000
MetaConfig.BOOST_TROOPS = 0.25
MetaConfig.BOOST_SHIELD_SECONDS = 30

function MetaConfig.boost(key: string)
	for _, b in MetaConfig.BOOSTS do
		if b.key == key then
			return b
		end
	end
	return nil
end

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
