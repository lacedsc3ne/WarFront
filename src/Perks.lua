--[[
	War Front - gameplay perks (game passes) and one-use boosts (developer products / coins).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- ServerScriptService.Perks (ModuleScript), driven by GameServer. Not part of OpenFront.
--
-- Perks (MetaConfig.PERKS), applied to human players, never in ranked:
--   startingArmy  troops x1.25 when the spawn phase ends
--   warEconomy    passive gold x1.15         (p.perkGold, read by GameServer's tick)
--   rapidGrowth   troop growth x1.10         (p.perkGrowth)
--   secondChance  one extra revive per round (Perks.extraRevives, read by Revive)
--   safeLanding   personal shield until spawn immunity + 10 s (Revive.addShield)
-- Boosts (MetaConfig.BOOSTS), client -> server "boost", key:
--   goldCrate +100K gold; reinforcements +25% of max troops now and max troops x1.25 for 60 s
--   (p.reinforceUntil, read by GameServer's tick); shield 30 s (Revive.addShield); nukeVoucher next
--   Atom Bomb free (p.nukeVoucher, read by Missiles.cost / launch).
--   As often as the player has them: from BOOST_DELAY seconds after the spawn phase, then
--   BOOST_COOLDOWN seconds between two of the same kind; never in ranked.
--   Server -> client "boostResult" { ok, key, text, cooldown? } and a feed line for everyone.
--
-- Perks.init(ctx)   ctx: net, feed(text, kind, ownerId), notify(id, text, kind), playerOf(p),
--                   isRanked(), tick(), roundStartTick(), phase(), players(), progression,
--                   addShield(p, untilTick)
-- Perks.onPlay()    the spawn phase just ended
-- Perks.extraRevives(p) -> number
-- Perks.useBoost(plr, p, key, bought?)   bought = just bought with Robux (kept if it can't be used)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))

local Perks = {}

local ctx: any = nil

function Perks.init(c)
	ctx = c
end

local function perksOf(p): { [string]: boolean }
	if p.kind ~= "Human" or ctx.isRanked() or not ctx.progression then
		return {}
	end
	local plr = ctx.playerOf(p)
	return if plr then ctx.progression.perksFor(plr) else {}
end

function Perks.onPlay()
	local immunityEnds = ctx.tick() + Config.SPAWN_IMMUNITY_TICKS
	for _, p in ctx.players() do
		local owned = perksOf(p)
		p.perkGold = if owned.warEconomy then MetaConfig.PERK_GOLD else nil
		p.perkGrowth = if owned.rapidGrowth then MetaConfig.PERK_GROWTH else nil
		p.boostReady = {}
		p.nukeVoucher = nil
		p.reinforceUntil = nil
		if p.alive and p.spawned then
			if owned.startingArmy then
				p.troops = math.floor(p.troops * MetaConfig.PERK_START_TROOPS)
			end
			if owned.safeLanding then
				ctx.addShield(p, immunityEnds + math.floor(MetaConfig.PERK_SHIELD_SECONDS / Config.TICK))
			end
		end
	end
end

function Perks.extraRevives(p): number
	return if perksOf(p).secondChance then MetaConfig.PERK_EXTRA_REVIVES else 0
end

local function reply(plr: Player, ok: boolean, key: string, text: string, cooldown: number?)
	ctx.net:FireClient(plr, "boostResult", { ok = ok, key = key, text = text, cooldown = cooldown })
end

function Perks.useBoost(plr: Player, p, key: any, bought: boolean?)
	local b = typeof(key) == "string" and MetaConfig.boost(key)
	if not b then
		return
	end
	local function refuse(text: string)
		reply(plr, false, b.key, if bought then b.name .. " is saved for later: " .. string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2) else text)
	end
	if ctx.isRanked() then
		return refuse("Boosts are off in ranked games.")
	end
	if ctx.phase() ~= "Play" or not p.alive then
		return refuse("Boosts can only be used while you're in the fight.")
	end
	local wait = MetaConfig.BOOST_DELAY - (ctx.tick() - ctx.roundStartTick()) * Config.TICK
	if wait > 0 then
		return refuse(string.format("Boosts unlock in %d s.", math.ceil(wait)))
	end
	p.boostReady = p.boostReady or {}
	local ready = p.boostReady[b.key] or 0
	if ctx.tick() < ready then
		return refuse(string.format("%s is ready again in %d s.", b.name, math.ceil((ready - ctx.tick()) * Config.TICK)))
	end
	if b.key == "nukeVoucher" and p.nukeVoucher then
		return refuse("You already have a free Atom Bomb waiting.")
	end
	if not ctx.progression or not ctx.progression.takeBoost(plr, b.key) then
		return reply(plr, false, b.key, "You don't have a " .. b.name .. ".")
	end
	local t = ctx.tick()
	p.boostReady[b.key] = t + math.floor(MetaConfig.BOOST_COOLDOWN / Config.TICK)
	local text = b.name .. " used!"
	if b.key == "goldCrate" then
		p.gold += MetaConfig.BOOST_GOLD
	elseif b.key == "reinforcements" then
		-- Extra troops above the normal cap: max troops x1.25 for a while (GameServer's tick), and
		-- the extra quarter right away, so it works even when you're already full.
		local base = math.max(1, p.maxTroops)
		p.reinforceUntil = t + math.floor(MetaConfig.BOOST_TROOPS_SECONDS / Config.TICK)
		p.reinforceMult = 1 + MetaConfig.BOOST_TROOPS
		p.maxTroops = math.floor(base * (1 + MetaConfig.BOOST_TROOPS))
		p.troops = math.min(p.maxTroops, p.troops + base * MetaConfig.BOOST_TROOPS)
		text = string.format("Reinforcements arrived: max troops +%d%% for %d s.", math.floor(MetaConfig.BOOST_TROOPS * 100), MetaConfig.BOOST_TROOPS_SECONDS)
	elseif b.key == "shield" then
		ctx.addShield(p, t + math.floor(MetaConfig.BOOST_SHIELD_SECONDS / Config.TICK))
		text = string.format("Shield up for %d s. Attacking a player ends it.", MetaConfig.BOOST_SHIELD_SECONDS)
	elseif b.key == "nukeVoucher" then
		p.nukeVoucher = true
		text = "Your next Atom Bomb is free."
	end
	ctx.feed(p.name .. " used a " .. b.name, "info", p.id)
	reply(plr, true, b.key, text, MetaConfig.BOOST_COOLDOWN)
end

return Perks
