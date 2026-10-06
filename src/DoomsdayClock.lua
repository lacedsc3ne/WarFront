--[[
	War Front - the Doomsday Clock (OpenFront core/execution/DoomsdayClockExecution.ts).

	Once armed, every side must hold a rising share of the whole map: each player in FFA, each whole
	team in team modes. The leading side is never doomed. A side below the bar is marked (skull) and,
	after the warn window, bleeds troops (and warship health) down to a decaying floor; climbing back
	above the bar clears the mark. Once the floor bottoms out, territory ROT takes land until the side
	is gone (rotDeathSeconds after the skull appeared). Tribes (bots) are not subject to it.
	Runs once per second during play. The threshold math lives in Shared.Doomsday.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.DoomsdayClock (ModuleScript), used by GameServer.
--
-- DoomsdayClock.init(ctx)       ctx: players(), teamGame(), elapsed() (game seconds), land() (land
--                               minus fallout), getOwner(t), relinquish(t) (to nobody + fallout),
--                               map(), tick(), kill(p), net
-- DoomsdayClock.start(speed)    arm it for this round (nil = off)
-- DoomsdayClock.step(tick)      every play tick (acts every 10th)
-- DoomsdayClock.status()        { { id, stage, secondsUnder } } stage 1 warn, 2 draining, 3 decaying

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Math = require(Shared:WaitForChild("Doomsday"))
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local Warships = require(ServerScriptService:WaitForChild("Warships"))

local DoomsdayClock = {}

local CFG = Math.CFG
local DECAY_CUE_GRACE_TICKS = 30

local ctx: any = nil
local speed: string? = nil
local active = false
-- Per marked player: the tick they went below the bar, and when rot last took a tile.
local marked: { [number]: number } = {}
local rottedAt: { [number]: number } = {}
-- Per rotting player: when rot began, the territory then, and the next tiles to eat mapped to how
-- many of their neighbours have already rotted.
local rotState: { [number]: { since: number, held: number, front: { [number]: number } } } = {}

function DoomsdayClock.init(c)
	ctx = c
end

local function clear(id: number)
	marked[id] = nil
	rottedAt[id] = nil
	rotState[id] = nil
	Warships.noHeal[id] = nil
end

function DoomsdayClock.start(s: string?)
	speed = s
	active = s ~= nil
	table.clear(marked)
	table.clear(rottedAt)
	table.clear(rotState)
	table.clear(Warships.noHeal)
end

function DoomsdayClock.enabled(): boolean
	return speed ~= nil
end

local function secondsUnder(id: number): number
	local since = marked[id]
	return if since then math.floor((ctx.tick() - since) / 10) else 0
end

--------------------------------------------------------------------------------
-- Territory rot
--------------------------------------------------------------------------------
local NB = {}

-- Rot one tile: hand the land to nobody (as wasteland: fallout) and queue its neighbours.
local function consume(p, tile: number, front: { [number]: number }): boolean
	if ctx.getOwner(tile) ~= p.id then
		return false
	end
	ctx.relinquish(tile)
	rottedAt[p.id] = ctx.tick()
	front[tile] = nil
	local map = ctx.map()
	local n = MapUtil.neighbors(map, tile, NB)
	for i = 1, n do
		local nt = NB[i]
		if ctx.getOwner(nt) == p.id then
			front[nt] = (front[nt] or 0) + 1
		end
	end
	return true
end

-- Every tile of the player (one map pass).
local function tilesOf(id: number): { number }
	local out = {}
	local map = ctx.map()
	for t = 0, map.size - 1 do
		if ctx.getOwner(t) == id then
			out[#out + 1] = t
		end
	end
	return out
end

-- Open `count` holes, preferring the interior (lowest R2 noise first so they land spread out).
local function speckle(p, count: number, front: { [number]: number }, tiles: { number }): number
	if count <= 0 then
		return 0
	end
	local w = ctx.map().width
	local interior, edge = {}, {}
	for _, t in tiles do
		local key = Math.speckleNoise(t % w, t // w, p.id) * 16777216 + t
		if p.border[t] then
			edge[#edge + 1] = key
		else
			interior[#interior + 1] = key
		end
	end
	table.sort(interior)
	local picked = interior
	if #interior < count then
		table.sort(edge)
		picked = table.clone(interior)
		for _, k in edge do
			picked[#picked + 1] = k
		end
	end
	local opened = 0
	for _, key in picked do
		if opened >= count then
			break
		end
		if consume(p, key % 16777216, front) then
			opened += 1
		end
	end
	return opened
end

-- Grow the holes by up to `count` tiles, tips first (fewest rotted neighbours), noise breaking ties.
local function spread(p, count: number, front: { [number]: number }): number
	if count <= 0 or next(front) == nil then
		return 0
	end
	local keys = {}
	for tile, rotted in front do
		keys[#keys + 1] = (rotted * Math.NOISE_SCALE + Math.frontNoise(tile, p.id)) * 16777216 + tile
	end
	table.sort(keys)
	local taken = 0
	for _, key in keys do
		if taken >= count then
			break
		end
		if consume(p, key % 16777216, front) then
			taken += 1
		end
	end
	return taken
end

local function rot(p, under: number)
	local owned = p.tiles
	if owned <= 0 then
		return
	end
	local state = rotState[p.id]
	if not state then
		state = { since = ctx.tick(), held = owned, front = {} }
		rotState[p.id] = state
	end
	local evenQuota = Math.rotQuota(owned, under)
	-- Grainy opening, sized off the territory held when rot began.
	local grainy = ctx.tick() - state.since < CFG.rotGrainSeconds * 10
	local specks = if grainy then math.max(1, math.ceil(state.held * CFG.rotSpecklePercent / 100 / CFG.rotGrainSeconds)) else 0
	local budget = math.min(owned, math.max(evenQuota, specks))
	-- Drop front tiles the player no longer holds.
	local front = state.front
	for tile in front do
		if ctx.getOwner(tile) ~= p.id then
			front[tile] = nil
		end
	end
	local tiles: { number }? = nil
	local function all(): { number }
		if not tiles then
			tiles = tilesOf(p.id)
		end
		return tiles :: { number }
	end
	if specks > 0 then
		budget -= speckle(p, math.min(specks, budget), front, all())
	end
	budget -= spread(p, budget, front)
	if budget > 0 then
		-- Front exhausted (no holes yet, or walled in on an island).
		tiles = nil
		speckle(p, budget, front, all())
	end
	if p.tiles <= 0 then
		ctx.kill(p)
	end
end

--------------------------------------------------------------------------------
-- Once a second
--------------------------------------------------------------------------------
local function sides(contenders: { any }, ffa: boolean): { { any } }
	if ffa then
		local out = {}
		for _, p in contenders do
			out[#out + 1] = { p }
		end
		return out
	end
	local byTeam, order = {}, {}
	for _, p in contenders do
		if p.team then
			if not byTeam[p.team] then
				byTeam[p.team] = {}
				order[#order + 1] = p.team
			end
			table.insert(byTeam[p.team], p)
		end
	end
	local out = {}
	for _, team in order do
		out[#out + 1] = byTeam[team]
	end
	return out
end

function DoomsdayClock.step(tick: number)
	if not active or tick % 10 ~= 0 then
		return
	end
	local contenders = {}
	for _, p in ctx.players() do
		if p.alive and p.kind ~= "Bot" and p.tiles > 0 then
			contenders[#contenders + 1] = p
		end
	end
	local ffa = not ctx.teamGame()
	local list = sides(contenders, ffa)
	if #list < 2 then
		-- A winner is inevitable: idle for the rest of the round.
		for id in marked do
			clear(id)
		end
		active = false
		return
	end
	local required = Math.requiredTiles(speed :: string, not ffa, ctx.land(), ctx.elapsed())
	local sideTiles = {}
	local leader = 1
	for i, members in list do
		local n = 0
		for _, m in members do
			n += m.tiles
		end
		sideTiles[i] = n
		if n > sideTiles[leader] then
			leader = i
		end
	end
	for i, members in list do
		if i ~= leader and sideTiles[i] < required then
			for _, m in members do
				if not marked[m.id] then
					marked[m.id] = tick
				end
				Warships.noHeal[m.id] = true
				local under = secondsUnder(m.id)
				if under >= CFG.warnSeconds then
					local past = under - CFG.warnSeconds
					local maxTroops = m.maxTroops or 0
					local floor = Math.troopFloor(maxTroops, past)
					local chunk = Math.drain(maxTroops, past)
					m.troops -= math.min(chunk, math.max(0, m.troops - floor))
					if CFG.rotDeathSeconds > 0 and past >= CFG.floorDecaySeconds and m.troops <= floor then
						rot(m, under)
					end
					Warships.drainOwner(m.id, function(maxHealth: number, health: number): number
						local shipFloor = math.floor(maxHealth * CFG.drainFloorPercent / 100)
						local removable = math.max(0, health - shipFloor)
						if removable <= 0 then
							return 0
						end
						return math.min(removable, Math.drain(maxHealth, past, CFG.warshipDrainStartPercent, CFG.warshipDrainMaxPercent, CFG.warshipDrainCurveExponent))
					end)
				end
			end
		else
			for _, m in members do
				if marked[m.id] then
					clear(m.id) -- recovered: any rot starts over
				end
			end
		end
	end
	-- Dead players lose their mark.
	for id in marked do
		local p = ctx.players()[id]
		if not p or not p.alive then
			clear(id)
		end
	end
end

-- Skull states for the clients: 1 = blinking (warn countdown), 2 = steady (draining),
-- 3 = red (territory rotting).
function DoomsdayClock.status(): { any }
	local out = {}
	local now = ctx and ctx.tick() or 0
	for id, since in marked do
		local under = math.floor((now - since) / 10)
		local stage = 1
		if under >= CFG.warnSeconds then
			stage = if rottedAt[id] and now - rottedAt[id] <= DECAY_CUE_GRACE_TICKS then 3 else 2
		end
		out[#out + 1] = { id, stage, under }
	end
	return out
end

return DoomsdayClock
