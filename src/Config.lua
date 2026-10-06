--[[
	War Front - a Roblox port of OpenFront's core gameplay.
	Copyright (C) 2026 Liam (lacedsc3ne)
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO

	This program is free software: you can redistribute it and/or modify it under the terms of the
	GNU Affero General Public License as published by the Free Software Foundation, either version 3
	of the License, or (at your option) any later version. This program is distributed WITHOUT ANY
	WARRANTY; see the GNU Affero General Public License for details: <https://www.gnu.org/licenses/>.

	Modified version: gameplay rules re-implemented in Luau for Roblox. Not affiliated with or
	endorsed by OpenFront.
]]

local Config = {}

Config.GAME_TITLE = "War Front"
Config.CREDIT = "© OpenFront and Contributors"
Config.ASSET_CREDIT = "Map data, flags & icons © OpenFront and Contributors, CC BY-SA 4.0"
-- AGPL-3.0 requires offering players the source of this modified version.
-- Put the public repository link here once the code is published.
Config.SOURCE_URL = "github.com/lacedsc3ne/WarFront"

Config.TICK = 0.1 -- seconds per simulation tick (10 tps)

-- Matchmaking (Shared.Place, ServerScriptService.Matchmaker). The root place is the lobby (menu,
-- public queue, private lobbies, ranked queue); matches run in reserved servers of the match place.
-- Both places hold this same project; the place id decides the role. MATCH_PLACE_ID = 0 keeps the
-- old single-place behaviour (rounds play in the server you join).
Config.LOBBY_PLACE_ID = 87826104198202
Config.MATCH_PLACE_ID = 113898874348705 -- "War Front" match subplace (reserved match servers)
Config.PUBLIC_LOBBY_SECONDS = 60 -- countdown once the first player is in the public lobby
Config.PUBLIC_MAX_PLAYERS = 50 -- Roblox server size of the match place (Max Players setting)
Config.PRIVATE_MAX_PLAYERS = 50
Config.MATCH_WAIT_SECONDS = 20 -- match server: wait this long for everyone teleported in
Config.MATCH_END_SECONDS = 60 -- match server: end screen, then everyone goes back to the lobby
Config.RANKED_START_ELO = 1000
Config.RANKED_K = 32
Config.RANKED_TIMER_MINUTES = 15 -- MapPlaylist.get1v1Config maxTimerValue (normal size)

-- The Roblox map uses the 1/4-scale terrain, so one tile here covers 16 tiles of the
-- full-size map. Formulas are evaluated in full-size units so the balance stays the same.
Config.AREA_SCALE = 16
Config.LINEAR_SCALE = 4

Config.LOBBY_SECONDS = 10
-- Map vote (maps feature): lobby length when a vote runs, and how many maps are offered.
Config.MAP_VOTE_LOBBY_SECONDS = 15
Config.MAP_VOTE_OPTIONS = 3
Config.SPAWN_PHASE_TICKS = 200 -- OpenFront numSpawnPhaseTurns(): 20 s in multiplayer (non-random spawn)
Config.END_SCREEN_SECONDS = 20
Config.WIN_FRACTION = 0.80
-- Tribes: OpenFront public lobbies spawn 400 (normal) / 100 (compact) tribes. Our maps are 1/16
-- of the area, so we use the compact count; GameServer scales it by land vs Europe.
Config.NUM_BOTS = 100
-- SpawnExecution.getSpawnTiles: every tile within Euclidean distance 4 (full-size) of the click,
-- i.e. 1 of our tiles: a small round blob (MapRender rounds its corners), not a square.
Config.SPAWN_RADIUS = 4 / Config.LINEAR_SCALE
Config.MIN_SPAWN_DISTANCE = 8
-- Game flow (rules_flow, OpenFront parity; public FFA lobby values from MapPlaylist.ts).
Config.SPAWN_IMMUNITY_TICKS = 50 -- DEFAULT_SPAWN_IMMUNITY_TICKS: 5 s of PVP immunity after the spawn phase
Config.NATION_DIFFICULTY = "Medium" -- public FFA lobbies (Easy | Medium | Hard | Impossible)
Config.NATION_SPAWN_DELTA = math.floor(25 / 4) -- NationExecution.randomSpawnLand delta 25, / LINEAR_SCALE
Config.OVERTIME_START_MINUTES = 30 -- public FFA: overtime on; win % drops after 30 min...
Config.OVERTIME_DROP_PER_MINUTE = 2 -- ...by 2 whole points a minute, no floor
Config.HARD_TIME_LIMIT_SECONDS = 170 * 60 -- WinCheckExecution: force a winner after 170 min
Config.TARGET_DURATION_TICKS = 100 -- targetDuration(): 10 s
Config.TARGET_COOLDOWN_TICKS = 150 -- targetCooldown(): 15 s
Config.EMBARGO_ALL_COOLDOWN_TICKS = 100 -- embargoAllCooldown(): 10 s
Config.TEMP_EMBARGO_TICKS = 3000 -- temporaryEmbargoDuration(): 5 min (auto embargo when attacked)

Config.START_TROOPS = { Human = 25000, Nation = 18750, Bot = 10000 }
-- Defeat screen (free comeback): REVIVE and NEW COUNTRY share this per-round allowance.
Config.REVIVES_PER_ROUND = 1
Config.REVIVE_GOLD = 50000
Config.REVIVE_SHIELD_SECONDS = 60
Config.REVIVE_SEARCH_RADIUS = 40 -- tiles around the old spawn searched for free land

Config.CITY_TROOP_BONUS = 250000 -- per city level (OpenFront cityTroopIncrease)
-- OpenFront City / Port / Factory price: min(1M, 2^n * 125K).
function Config.cityCost(citiesOwned: number): number
	return math.min(1000000, (2 ^ citiesOwned) * 125000)
end

-- Structures (OpenFront Config.unitInfo). cost(n) gets n = sum over the kinds in `shares` (default:
-- just this kind) of min(levels owned incl. 1 per site under construction, levels ever built or
-- upgraded by this player) - OpenFront's costWrapper. `build` = construction ticks, `upgradable` =
-- building the same kind next to one you own raises its level instead (UpgradeStructureExecution).
Config.STRUCTURE_ORDER = { "City", "Factory", "Port", "DefensePost", "MissileSilo", "SAM" }
Config.STRUCTURES = {
	City = { name = "City", glyph = "C", build = 20, cost = Config.cityCost, upgradable = true, info = "Increases max population" },
	Port = { name = "Port", glyph = "P", build = 50, cost = Config.cityCost, coastal = true, upgradable = true, shares = { "Port", "Factory" }, info = "Sends trade ships to generate gold" },
	Factory = { name = "Factory", glyph = "F", build = 20, cost = Config.cityCost, upgradable = true, shares = { "Factory", "Port" }, info = "Creates railroads and spawns trains" },
	DefensePost = {
		name = "Defense Post",
		glyph = "D",
		build = 50,
		cost = function(n) return math.min(250000, (n + 1) * 50000) end,
		info = "Increases defenses of nearby borders",
	},
	MissileSilo = { name = "Missile Silo", glyph = "M", build = 100, cost = function() return 1000000 end, upgradable = true, info = "Used to launch nukes" },
	SAM = {
		name = "SAM Launcher",
		glyph = "S",
		build = 300, -- OpenFront SAM_CONSTRUCTION_TICKS (30 s)
		cost = function(n) return math.min(3000000, (n + 1) * 1500000) end,
		upgradable = true,
		info = "Defends against incoming nukes",
	},
}
-- Placement (OpenFront structureMinDist 15, validStructureSpawnTiles radius 15, radiusPortSpawn 20),
-- divided by LINEAR_SCALE. Spacing is Euclidean between any two structures (any owner); a click
-- snaps to the nearest valid own tile within the search radius, ports to the nearest own shore tile.
Config.MIN_STRUCTURE_DISTANCE = 15 / Config.LINEAR_SCALE
Config.STRUCTURE_SEARCH_RADIUS = 15 / Config.LINEAR_SCALE
Config.PORT_SPAWN_RADIUS = 20 / Config.LINEAR_SCALE -- Manhattan
Config.MAX_UPGRADE_AMOUNT = 50 -- bulk upgrade cap (OpenFront MAX_UPGRADE_AMOUNT)
-- Delete Unit (OpenFront): 30 s cooldown, then the structure is marked and removed 30 s later.
Config.DELETE_UNIT_COOLDOWN = 300 -- ticks
Config.DELETION_MARK_TICKS = 300
-- Donations (OpenFront): one per recipient every 10 s, default a third of what you have.
Config.DONATE_COOLDOWN = 100 -- ticks
-- A defender left with fewer than this many full-size tiles is conquered outright (AttackExecution).
Config.DEAD_DEFENDER_TILES = 100
-- Encircled territory check cadence (PlayerExecution removeClusters).
Config.CLUSTER_CALC_TICKS = 20

-- Gold a conqueror receives (OpenFront conquerGoldAmount): all of a bot's or nation's gold, half
-- of a human's, nothing from a human who never attacked anyone (conquered_no_gold).
function Config.conquerGold(kind: string, gold: number, everAttacked: boolean): number
	if kind == "Bot" or kind == "Nation" then
		return gold
	end
	if not everAttacked then
		return 0
	end
	return math.floor(gold / 2)
end

-- OpenFront renderNumber (client/Utils.ts), used for event texts.
function Config.renderNumber(num: number): string
	num = math.max(num, 0)
	if num >= 10000000000 then
		return string.format("%.1fB", math.floor(num / 100000000) / 10)
	elseif num >= 1000000000 then
		return string.format("%.2fB", math.floor(num / 10000000) / 100)
	elseif num >= 10000000 then
		return string.format("%.1fM", math.floor(num / 100000) / 10)
	elseif num >= 1000000 then
		return string.format("%.2fM", math.floor(num / 10000) / 100)
	elseif num >= 100000 then
		return tostring(math.floor(num / 1000)) .. "K"
	elseif num >= 10000 then
		return string.format("%.1fK", math.floor(num / 100) / 10)
	elseif num >= 1000 then
		return string.format("%.2fK", math.floor(num / 10) / 100)
	end
	return tostring(math.floor(num))
end
-- OpenFront shows troops divided by 10 (renderTroops). Set to 1 if the HUD shows raw troop counts.
Config.TROOP_DISPLAY_DIVISOR = 10
function Config.renderTroops(troops: number): string
	return Config.renderNumber(troops / Config.TROOP_DISPLAY_DIVISOR)
end

-- OpenFront defensePostRange 30, divided by LINEAR_SCALE.
Config.DEFENSE_RADIUS = 30 / Config.LINEAR_SCALE -- tiles
Config.DEFENSE_LOSS_MULT = 5
Config.DEFENSE_SPEED_MULT = 3
-- OpenFront falloutDefenseModifier = 5 - 2 x (share of land tiles carrying fallout), applied to both
-- the loss and the time of taking a fallout tile (5 on a clean map, 3 if all land had fallout).
function Config.falloutMult(falloutRatio: number): number
	return 5 - falloutRatio * 2
end
-- Attack front jitter: OpenFront adds random.nextInt(0, 5) = 0..4 full-size tiles to the attack's
-- border size each tick (divided by LINEAR_SCALE in GameServer).
Config.ATTACK_BORDER_JITTER = 4
-- Delete Unit selection: OpenFront DELETE_SELECTION_RADIUS 5 full-size tiles (Manhattan), / LINEAR_SCALE
-- rounded up so a click on the structure's own tile or next to it still finds it.
Config.DELETE_SELECTION_RADIUS = math.ceil(5 / Config.LINEAR_SCALE)
-- Nation difficulty multipliers (Config.maxTroops / troopIncreaseRate). Config.NATION_DIFFICULTY
-- (rules_flow) picks the row; public lobbies use Medium.
Config.NATION_MAX_TROOPS_MULT = { Easy = 0.5, Medium = 0.75, Hard = 1, Impossible = 1.25 }
Config.NATION_TROOP_GROWTH_MULT = { Easy = 0.9, Medium = 0.95, Hard = 1, Impossible = 1.05 }

Config.NUKE_ORDER = { "AtomBomb", "HydrogenBomb", "MIRV" }
Config.NUKES = {
	AtomBomb = { name = "Atom Bomb", glyph = "A", cost = 750000, inner = 3, outer = 7.5, speed = 2.5 },
	HydrogenBomb = { name = "H-Bomb", glyph = "H", cost = 5000000, inner = 20, outer = 25, speed = 2.5 },
	-- OpenFront MIRV: 25M + 15M per MIRV already launched this match (server adds costStep);
	-- splits into up to 350 warheads (inner 12 / outer 18 full-size = 3 / 4.5 here) over the target
	-- player's land. inner/outer here are the warhead's; the carrier itself never explodes.
	MIRV = { name = "MIRV", glyph = "V", cost = 25000000, costStep = 15000000, inner = 3, outer = 4.5, speed = 3.75, mirv = true },
}
Config.SILO_COOLDOWN = 90 -- ticks
Config.SAM_RANGE = 17 -- tiles
Config.SAM_COOLDOWN = 90
-- Defined before the warship values below, which are derived from it.
Config.BOAT_SPEED = 0.25 -- tiles per tick: OpenFront ships move 1 full-size tile per tick (1 / LINEAR_SCALE here)
-- Warships (OpenFront Warship/Shell rules). Full-size distances are divided by LINEAR_SCALE.
-- Speeds are relative to BOAT_SPEED, because in OpenFront warships and transports both move
-- one tile per tick and shells three.
Config.UNIT_ORDER = { "Warship" }
Config.UNITS = {
	Warship = {
		name = "Warship",
		glyph = "W",
		cost = function(n) return math.min(1000000, (n + 1) * 250000) end,
		info = "Patrols, sinks boats, captures trade",
	},
}
Config.WARSHIP_HEALTH = 1000
Config.WARSHIP_SPEED = Config.BOAT_SPEED -- tiles per tick (doubled while hunting a trade ship)
Config.WARSHIP_PATROL_RANGE = 100 / Config.LINEAR_SCALE -- tiles
Config.WARSHIP_TARGET_RANGE = 130 / Config.LINEAR_SCALE -- tiles
Config.WARSHIP_SHELL_RATE = 20 -- ticks between shells at warships (transports: no cooldown)
Config.WARSHIP_CAPTURE_RANGE = 2 -- Manhattan tiles to capture a trade ship (5 full-size)
Config.WARSHIP_HEAL_RANGE = 150 / Config.LINEAR_SCALE -- passive repair near own ports
Config.WARSHIP_HEAL_PER_TICK = 1
Config.SHELL_DAMAGE = 250 -- base; each shell rolls 200..300 at this base
Config.SHELL_SPEED = Config.BOAT_SPEED * 3 -- tiles per tick

Config.MAX_BOATS = 3
-- Alliances (OpenFront: 20 s requests, 5 min alliances, 30 s traitor with -50% defence losses
-- and 0.8x conquest time). Requests get a little longer here so gamepad/touch players can answer.
Config.ALLIANCE_REQUEST_TICKS = 300 -- 30 s to answer a request
Config.ALLIANCE_REQUEST_COOLDOWN = 300 -- before asking the same player again
Config.ALLIANCE_TICKS = 3000 -- 5 min
Config.ALLIANCE_RENEW_TICKS = 300 -- renewal can be requested in the last 30 s
Config.TRAITOR_TICKS = 300 -- 30 s
Config.TRAITOR_LOSS_MULT = 0.5 -- attacker losses against a traitor
Config.TRAITOR_SPEED_MULT = 0.8 -- tile cost against a traitor (lower = faster)
Config.NUKE_ALLY_BREAK_TILES = 6 -- a nuke hitting this many of an ally's tiles breaks the alliance
Config.NATION_MAX_ALLIES = 3
Config.NATION_BETRAY_RATIO = 3 -- nations may betray allies this many times weaker than them

-- Trade: each port periodically sends a trade ship to another player's port.
Config.TRADE_INTERVAL = 120 -- ticks between ship launches per port (randomised +-50%)
-- goldMultiplier (public "x2 Gold Multiplier" modifier): passive gold, trade ships and trains.
-- Set by the server at the start of each round.
Config.GOLD_MULTIPLIER = 1

function Config.tradeGold(pathLength: number): number
	-- Longer routes pay more (distance measured in full-size tiles).
	local d = pathLength * Config.LINEAR_SCALE
	return math.floor((75000 / (1 + math.exp(-0.03 * (d - 300))) + 50 * d) * Config.GOLD_MULTIPLIER)
end

function Config.goldPerTick(kind: string): number
	return math.floor((if kind == "Bot" then 50 else 100) * Config.GOLD_MULTIPLIER)
end

-- OpenFront Config.maxTroops. `cities` = summed levels of the player's finished cities.
function Config.maxTroops(kind: string, tiles: number, cities: number): number
	local realTiles = tiles * Config.AREA_SCALE
	local m = 2 * (realTiles ^ 0.6 * 1000 + 50000) + cities * Config.CITY_TROOP_BONUS
	if kind == "Bot" then
		return m / 3
	elseif kind == "Nation" then
		return m * (Config.NATION_MAX_TROOPS_MULT[Config.NATION_DIFFICULTY or "Medium"] or 0.75)
	end
	return m
end

function Config.troopGrowth(kind: string, troops: number, maxT: number): number
	local add = 10 + troops ^ 0.73 / 4
	add *= 1 - troops / maxT
	if kind == "Bot" then
		add *= 0.5
	elseif kind == "Nation" then
		add *= Config.NATION_TROOP_GROWTH_MULT[Config.NATION_DIFFICULTY or "Medium"] or 0.95
	end
	return math.min(troops + add, maxT) - troops
end

function Config.attackAmountFraction(kind: string): number
	return kind == "Bot" and 0.05 or 0.2
end

-- Terrain: bits0-4 of a land byte are its magnitude.
Config.PLAINS, Config.HIGHLAND, Config.MOUNTAIN = 1, 2, 3
function Config.terrainClass(magnitude: number): number
	if magnitude < 10 then
		return Config.PLAINS
	elseif magnitude < 20 then
		return Config.HIGHLAND
	end
	return Config.MOUNTAIN
end

local TERRAIN_MAG = { 80, 100, 120 }
local TERRAIN_COST = { 16.5, 20, 25 }

local function clamp(v, lo, hi)
	return if v < lo then lo elseif v > hi then hi else v
end

local LOG_MIDPOINT = math.log(300000)
local function largeTerritoryBonus(tiles: number, depth: number): number
	local real = math.max(1, tiles * Config.AREA_SCALE)
	local s = 1 / (1 + math.exp(-2.5 * (math.log(real) - LOG_MIDPOINT)))
	return 1 - depth * s
end

--[[
	Cost of conquering one tile.
	attacker = { kind, tiles }, defender = nil (neutral) or { kind, tiles, troops }
	fallout = nil (tile has no fallout) or the share of land tiles carrying fallout (OpenFront
	falloutRatio). Returns attackerLoss, defenderLoss, tickFraction (share of this tick the tile used up).
]]
function Config.attackTile(attacker, defender, attackTroops: number, terrain: number, borderSize: number, defended: boolean?, fallout: number?, traitor: boolean?)
	local mag = TERRAIN_MAG[terrain]
	local cost = TERRAIN_COST[terrain]
	local A, L = Config.AREA_SCALE, Config.LINEAR_SCALE
	borderSize = math.max(1, borderSize)
	if defended and defender ~= nil then
		mag *= Config.DEFENSE_LOSS_MULT
		cost *= Config.DEFENSE_SPEED_MULT
	end
	if fallout then
		local f = Config.falloutMult(fallout)
		mag *= f
		cost *= f
	end
	if traitor then
		mag *= Config.TRAITOR_LOSS_MULT
		cost *= Config.TRAITOR_SPEED_MULT
	end

	if defender == nil then
		local lossPerReal = mag / (attacker.kind == "Bot" and 10 or 5)
		local perReal = clamp(2000 * cost / math.max(1, attackTroops), 5, 100)
		-- full-size: perReal / (borderReal * 2), borderReal = borderSize * L, then x A tiles
		return lossPerReal * A, 0, perReal * A / (borderSize * L * 2)
	end

	if attacker.kind ~= "Bot" and defender.kind == "Bot" then
		mag *= 0.7
	end
	local bA = largeTerritoryBonus(attacker.tiles, 0.7)
	local bD = largeTerritoryBonus(defender.tiles, 0.3)
	local density = defender.troops / math.max(1, defender.tiles * A)
	local ratio = defender.troops / math.max(1, attackTroops)
	local lossReal = mag * clamp(ratio, 0.6, 2) * (0.463 * bA * bD + 0.0039 * density)
	local speed = clamp(ratio, 0.82, 7.5) * clamp(ratio / 20, 1, 50) / 8.55
	local bAs = largeTerritoryBonus(attacker.tiles, 0.73)
	local fracReal = speed * cost * bAs * bD / (borderSize * L)
	return lossReal * A, density * A, fracReal * A
end

return Config
