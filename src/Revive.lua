--[[
	War Front - free comeback after defeat (revive / new country / leave).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.Revive (ModuleScript), driven by GameServer.
--
-- Client -> server kinds: "revive", "newCountry", "leave" (no arguments).
-- Server -> client kinds:
--   "defeated" (personal) { by = killer name?, canRevive, reason?, reviveTroops, reviveGold,
--                           shieldSeconds, revivesLeft }
--   "revived"  (personal) { tile, shieldSeconds }
--   "reviveDenied" (personal) { reason }
--   "left"     (personal) {}
--   "shields"  (all)      { { playerId, endsAt (workspace:GetServerTimeNow() time) }, ... }
--
-- REVIVE respawns near the old spawn (random if nothing free nearby); NEW COUNTRY always picks a
-- random spawn far from the old one. Both use the same per-round allowance
-- (Config.REVIVES_PER_ROUND), so a player gets one comeback per round either way.
-- A revived player is shielded for Config.REVIVE_SHIELD_SECONDS: land attacks and boat landings
-- by other players are refused (boats bring their troops home); nukes still hit. Attacking another
-- non-bot player drops your own shield.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)

local Revive = {}

local ctx: any = nil
local used: { [number]: number } = {} -- userId -> comebacks used this round
local shields: { [number]: number } = {} -- player id -> tick the shield ends
local shieldsDirty = false

local KINDS = { revive = true, newCountry = true, leave = true }

function Revive.init(c)
	ctx = c
end

function Revive.handles(kind: string): boolean
	return KINDS[kind] == true
end

local function revivesLeft(p): number
	local extra = if ctx.extraRevives then ctx.extraRevives(p) else 0 -- Perks: Second Chance
	return math.max(0, Config.REVIVES_PER_ROUND + extra - (used[p.userId or 0] or 0))
end

-- Returns nil if the player may come back now, else a short reason for the UI.
local function denyReason(plr: Player, p): string?
	if ctx.phase() ~= "Play" then
		return "The round is over"
	end
	if not p or p.alive then
		return "You are still in the fight"
	end
	if not ctx.wantsPlay[plr.UserId] then
		return "You left this battle"
	end
	if revivesLeft(p) <= 0 then
		return "Revive already used this round"
	end
	return nil
end

function Revive.reset()
	table.clear(used)
	table.clear(shields)
	shieldsDirty = true
end

-- Shield p until untilTick (keeps a longer shield it already has). Used by Perks (Safe Landing,
-- Shield boost); the same rules as the revive shield apply.
function Revive.addShield(p, untilTick: number)
	if (shields[p.id] or 0) < untilTick then
		shields[p.id] = untilTick
		shieldsDirty = true
	end
end

function Revive.shielded(id: number): boolean
	local untilTick = shields[id]
	return untilTick ~= nil and ctx.tick() < untilTick
end

-- Called before a land attack or boat launch by p against targetId. Returns true if it must be
-- refused because the target is shielded. Attacking another real player drops p's own shield.
function Revive.blocks(p, targetId: number): boolean
	if targetId ~= 0 and targetId ~= p.id and Revive.shielded(targetId) then
		return true
	end
	if targetId ~= 0 and shields[p.id] then
		local target = ctx.players()[targetId]
		if target and target.kind ~= "Bot" then
			shields[p.id] = nil
			shieldsDirty = true
		end
	end
	return false
end

local function shieldsPayload()
	local list = {}
	local now = SimClock.now()
	local t = ctx.tick()
	for id, untilTick in shields do
		if untilTick > t then
			list[#list + 1] = { id, now + (untilTick - t) * Config.TICK }
		end
	end
	return list
end

function Revive.sendInit(plr: Player)
	ctx.net:FireClient(plr, "shields", shieldsPayload())
end

-- Every simulation tick (any phase): expire shields and broadcast changes.
function Revive.step()
	local t = ctx.tick()
	for id, untilTick in shields do
		if t >= untilTick then
			shields[id] = nil
			shieldsDirty = true
		end
	end
	if shieldsDirty then
		shieldsDirty = false
		ctx.net:FireAllClients("shields", shieldsPayload())
	end
end

-- GameServer.killPlayer hook.
function Revive.onKilled(p, killer)
	if shields[p.id] then
		shields[p.id] = nil
		shieldsDirty = true
	end
	if p.kind ~= "Human" then
		return
	end
	local plr = ctx.playerOf(p)
	if not plr then
		return
	end
	local reason = denyReason(plr, p)
	ctx.net:FireClient(plr, "defeated", {
		by = if killer and killer ~= p then killer.name else nil,
		canRevive = reason == nil,
		reason = reason,
		reviveTroops = Config.START_TROOPS.Human,
		reviveGold = Config.REVIVE_GOLD,
		shieldSeconds = Config.REVIVE_SHIELD_SECONDS,
		revivesLeft = revivesLeft(p),
	})
end

-- Free ownable tiles in the 5x5 block around t (a spawn needs some room to start from).
local function roomAround(t: number): number
	local W, H = ctx.size()
	local cx, cy = t % W, t // W
	local n = 0
	for dy = -2, 2 do
		for dx = -2, 2 do
			local x, y = cx + dx, cy + dy
			if x >= 0 and x < W and y >= 0 and y < H then
				local tt = y * W + x
				if ctx.ownable(tt) and ctx.getOwner(tt) == 0 then
					n += 1
				end
			end
		end
	end
	return n
end

local function freeSpawn(t: number): boolean
	return ctx.ownable(t) and ctx.getOwner(t) == 0 and roomAround(t) >= 9
end

local function findSpawn(p, near: boolean): number?
	local W = ctx.size()
	local old = p.spawnTile
	if near and old then
		local t = ctx.nearestTile(old % W, old // W, Config.REVIVE_SEARCH_RADIUS, freeSpawn)
		if t then
			return t
		end
	end
	-- Random spawn; for a new country prefer the candidate farthest from the old spawn.
	local best, bestD = nil, -1
	for _ = 1, (if near or not old then 4 else 16) do
		local t = ctx.randomSpawnTile(Config.MIN_SPAWN_DISTANCE)
		if t and roomAround(t) >= 9 then
			local d = 0
			if old then
				local dx, dy = t % W - old % W, t // W - old // W
				d = dx * dx + dy * dy
			end
			if d > bestD then
				best, bestD = t, d
			end
			if near or not old then
				break
			end
		end
	end
	return best or ctx.randomSpawnTile(Config.MIN_SPAWN_DISTANCE) or ctx.randomSpawnTile(0)
end

local function comeBack(plr: Player, p, near: boolean)
	local reason = denyReason(plr, p)
	if reason then
		ctx.net:FireClient(plr, "reviveDenied", { reason = reason })
		return
	end
	local t = findSpawn(p, near)
	if not t then
		ctx.net:FireClient(plr, "reviveDenied", { reason = "No free land left" })
		return
	end

	-- Clear per-round state left over from the old country.
	for a in pairs(p.outgoing) do
		ctx.endAttack(a, false)
	end
	for _, a in table.clone(ctx.attacks()) do
		if a.target == p.id and not a.dead then
			ctx.endAttack(a, true)
		end
	end
	for _, b in table.clone(ctx.boats()) do
		if b.owner == p.id and b.kind == "transport" then
			ctx.removeBoat(b)
		end
	end
	p.boats = 0
	local order = ctx.eliminationOrder()
	local i = table.find(order, p)
	if i then
		table.remove(order, i)
	end
	local spawns = ctx.spawnTiles()
	local si = p.spawnTile and table.find(spawns, p.spawnTile)
	if si then
		table.remove(spawns, si)
	end

	used[p.userId or 0] = (used[p.userId or 0] or 0) + 1
	p.alive = true
	p.deathTick = nil
	p.troops = Config.START_TROOPS.Human
	p.gold += Config.REVIVE_GOLD
	ctx.claimSpawn(p, t)
	p.maxTroops = Config.maxTroops(p.kind, p.tiles, p.cities)
	shields[p.id] = ctx.tick() + math.floor(Config.REVIVE_SHIELD_SECONDS / Config.TICK)
	shieldsDirty = true
	ctx.markRoster()
	ctx.feed(p.name .. (if near then " is back in the fight" else " founded a new country"), "info", p.id)
	ctx.net:FireClient(plr, "revived", { tile = t, shieldSeconds = Config.REVIVE_SHIELD_SECONDS })
end

function Revive.handle(plr: Player, p, kind: string)
	if kind == "leave" then
		ctx.wantsPlay[plr.UserId] = nil
		ctx.net:FireClient(plr, "left", {})
	elseif kind == "revive" or kind == "newCountry" then
		comeBack(plr, p, kind == "revive")
	end
end

return Revive
