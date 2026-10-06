--[[
	War Front - team games: public-lobby mode rotation, team assignment and the team win check.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(server/MapPlaylist.ts TEAM_WEIGHTS, core/game/TeamAssignment.ts, WinCheckExecution.ts).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ServerScriptService.Teams (ModuleScript), used by GameServer.
-- Teams.rollMode(roundNumber, rng) -> mode   alternates FFA and Team rounds like OpenFront's public
--                                             lobby schedule; Team rounds roll TEAM_WEIGHTS
-- Teams.label(mode) -> string                 "Free for All", "4 Teams", "Duos", "Humans vs Nations"
-- Teams.assign(mode, humans, nations, rng)    sets p.team on every human and nation
-- Teams.checkWin(players, land, winPercent)   -> winning team name or nil
-- Teams.loadFriends(player)                   caches a player's Roblox friends (call on join);
--                                             Teams.assign puts friends on the same team
--                                             (OpenFront friends.team_info)

local Players = game:GetService("Players")

local Teams = {}

local friendsOf: { [number]: { [number]: boolean } } = {} -- userId -> set of friend userIds

function Teams.loadFriends(plr: Player)
	local uid = plr.UserId
	task.spawn(function()
		local set = {}
		local ok, pages = pcall(function()
			return Players:GetFriendsAsync(uid)
		end)
		if ok and pages then
			for _ = 1, 3 do -- up to ~150 friends is plenty for grouping
				for _, f in pages:GetCurrentPage() do
					set[f.Id] = true
				end
				if pages.IsFinished then
					break
				end
				if not pcall(function()
					pages:AdvanceToNextPageAsync()
				end) then
					break
				end
			end
		end
		friendsOf[uid] = set
	end)
end

function Teams.forget(uid: number)
	friendsOf[uid] = nil
end

local function areFriends(a, b): boolean
	if not a.userId or not b.userId then
		return false
	end
	local fa, fb = friendsOf[a.userId], friendsOf[b.userId]
	return (fa ~= nil and fa[b.userId] == true) or (fb ~= nil and fb[a.userId] == true)
end

local TEAM_ORDER = { "Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Teal" }

-- MapPlaylist.TEAM_WEIGHTS
local TEAM_WEIGHTS = {
	{ config = 2, weight = 10 },
	{ config = 3, weight = 10 },
	{ config = 4, weight = 10 },
	{ config = 5, weight = 10 },
	{ config = 6, weight = 10 },
	{ config = 7, weight = 10 },
	{ config = "Duos", weight = 5 },
	{ config = "Trios", weight = 7.5 },
	{ config = "Quads", weight = 7.5 },
	{ config = "Humans Vs Nations", weight = 20 },
}

function Teams.rollMode(round: number, rng: Random)
	-- Public lobbies alternate Free-for-All and Team games.
	if round % 2 == 1 then
		return { kind = "FFA" }
	end
	local total = 0
	for _, w in TEAM_WEIGHTS do
		total += w.weight
	end
	local roll = rng:NextNumber() * total
	for _, w in TEAM_WEIGHTS do
		roll -= w.weight
		if roll <= 0 then
			return { kind = "Team", teams = w.config }
		end
	end
	return { kind = "Team", teams = 2 }
end

-- MapPlaylist.getTeamCount: a TEAM_WEIGHTS roll.
function Teams.rollTeams(rng: Random)
	local total = 0
	for _, w in TEAM_WEIGHTS do
		total += w.weight
	end
	local roll = rng:NextNumber() * total
	for _, w in TEAM_WEIGHTS do
		roll -= w.weight
		if roll < 0 then
			return w.config
		end
	end
	return TEAM_WEIGHTS[1].config
end

-- GameModeSelector.getLobbyTitle: "Free for All", "4 teams of 5", "12 teams of 2",
-- "10 Humans vs 10 Nations".
function Teams.title(mode, maxPlayers: number?): string
	if not Teams.isTeam(mode) then
		return "Free for All"
	end
	local teams = mode.teams
	if teams == "Humans Vs Nations" then
		return if maxPlayers then string.format("%d Humans vs %d Nations", maxPlayers, maxPlayers) else "Humans vs Nations"
	end
	local per = if teams == "Duos" then 2 elseif teams == "Trios" then 3 elseif teams == "Quads" then 4 else nil
	local count = if per then (if maxPlayers then maxPlayers // per else nil) else teams
	if type(count) ~= "number" or count <= 0 then
		return Teams.label(mode)
	end
	if not per and maxPlayers and count > 0 then
		per = maxPlayers // count
	end
	if per and per > 0 then
		return string.format("%d teams of %d", count, per)
	end
	return string.format("%d teams", count)
end

function Teams.isTeam(mode): boolean
	return mode ~= nil and mode.kind == "Team"
end

function Teams.isHvN(mode): boolean
	return Teams.isTeam(mode) and mode.teams == "Humans Vs Nations"
end

-- Lobby card text (public_lobby.teams / teams_hvn, game_mode.ffa, Duos/Trios/Quads).
function Teams.label(mode): string
	if not Teams.isTeam(mode) then
		return "Free for All"
	elseif Teams.isHvN(mode) then
		return "Humans vs Nations"
	elseif type(mode.teams) == "string" then
		return mode.teams
	end
	return mode.teams .. " teams"
end

-- resolveTeamsList
local function teamsList(config, totalPlayers: number): { string }
	if config == "Humans Vs Nations" then
		return { "Humans", "Nations" }
	end
	local n
	if type(config) == "string" then
		local divisor = if config == "Duos" then 2 elseif config == "Trios" then 3 else 4
		n = math.max(2, math.ceil(totalPlayers / divisor))
	else
		n = config
	end
	local out = {}
	for i = 1, n do
		out[i] = if i <= #TEAM_ORDER then TEAM_ORDER[i] else "Team " .. i
	end
	return out
end

local function shuffle(list, rng: Random)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

-- assignTeams: humans first, then the (shuffled) nations. Each goes to the smallest team that isn't
-- full; Duos / Trios / Quads fill the fullest open team first so groups complete. Over-full players
-- (only possible with odd numbers) go to the smallest team anyway.
function Teams.assign(mode, humans: { any }, nations: { any }, rng: Random)
	if not Teams.isTeam(mode) then
		for _, p in humans do
			p.team = nil
		end
		for _, p in nations do
			p.team = nil
		end
		return {}
	end
	if Teams.isHvN(mode) then
		for _, p in humans do
			p.team = "Humans"
		end
		for _, p in nations do
			p.team = "Nations"
		end
		return { "Humans", "Nations" }
	end
	local total = #humans + #nations
	local list = teamsList(mode.teams, total)
	local maxSize = math.ceil(total / #list)
	local fillUp = type(mode.teams) == "string"
	local size = {}
	for _, t in list do
		size[t] = 0
	end
	local function place(p)
		local best, bestSize = nil, if fillUp then -1 else math.huge
		for _, t in list do
			local s = size[t]
			if s < maxSize and (if fillUp then s > bestSize else s < bestSize) then
				best, bestSize = t, s
			end
		end
		if not best then
			best = list[1]
			for _, t in list do
				if size[t] < size[best] then
					best = t
				end
			end
		end
		p.team = best
		size[best] += 1
	end
	local shuffledHumans = table.clone(humans)
	shuffle(shuffledHumans, rng)
	-- Friends are placed on the same team: humans go in friend groups (connected by Roblox
	-- friendships), each group into the team with the most room for it.
	local groupOf, groups = {}, {}
	for _, p in shuffledHumans do
		if not groupOf[p] then
			local g = { p }
			groupOf[p] = g
			local i = 1
			while i <= #g do
				for _, q in shuffledHumans do
					if not groupOf[q] and areFriends(g[i], q) then
						groupOf[q] = g
						g[#g + 1] = q
					end
				end
				i += 1
			end
			groups[#groups + 1] = g
		end
	end
	for _, g in groups do
		if #g == 1 then
			place(g[1])
		else
			local best = list[1]
			for _, t in list do
				if size[t] < size[best] then
					best = t
				end
			end
			for _, p in g do
				if size[best] < maxSize then
					p.team = best
					size[best] += 1
				else
					place(p) -- the team is full: the rest of the group goes elsewhere
				end
			end
		end
	end
	local shuffledNations = table.clone(nations)
	shuffle(shuffledNations, rng)
	for _, p in shuffledNations do
		place(p)
	end
	return list
end

-- WinCheckExecution.checkWinnerTeam: the team with the most land wins once it holds more than the
-- win share; tribes ("Bot") never win.
function Teams.checkWin(players, land: number, winPercent: number): string?
	local tiles = {}
	for _, p in players do
		if p.alive and p.team then
			tiles[p.team] = (tiles[p.team] or 0) + p.tiles
		end
	end
	local best, bestTiles = nil, -1
	for team, n in tiles do
		if n > bestTiles then
			best, bestTiles = team, n
		end
	end
	if best and best ~= "Bot" and bestTiles * 100 > land * winPercent then
		return best
	end
	return nil
end

-- The leading team (hard time limit).
function Teams.leader(players): string?
	local tiles = {}
	for _, p in players do
		if p.alive and p.team and p.team ~= "Bot" then
			tiles[p.team] = (tiles[p.team] or 0) + p.tiles
		end
	end
	local best, bestTiles = nil, -1
	for team, n in tiles do
		if n > bestTiles then
			best, bestTiles = team, n
		end
	end
	return best
end

return Teams
