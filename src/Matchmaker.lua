--[[
	War Front - matchmaking: the public lobby, private lobbies and the ranked 1v1 queue (lobby place),
	and the match settings / trip back to the lobby (match place).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(server/MasterLobbyService.ts, MapPlaylist.ts, client/Matchmaking.ts, HostLobbyModal.ts,
	JoinLobbyModal.ts). Modified version re-implemented in Luau for Roblox; not affiliated with or
	endorsed by OpenFront.
]]

-- ServerScriptService.Matchmaker (ModuleScript), used by GameServer.
--
-- Every lobby server shares the queues through MemoryStoreService (sorted maps, prefix WF1_):
--   WF1_Public   "ffa" | "team" | "special" -> that public lobby { id, type, map, mode, max, settings,
--                startsAt, state, access, recent }
--   WF1_PubMem   "<lobbyId>:<userId>" -> { name, job }   (members of that lobby, 30 s expiry, refreshed)
--   WF1_Ranked   "<userId>" -> { elo, job, t, state, access }   (1v1 queue)
--   WF1_Private  "<CODE>" -> { code, host, hostName, settings, members, state, access }
--   WF1_Match    "<privateServerId>" -> match settings, read by the match server when it boots
--   WF1_Lock     "ranked" -> { job, exp }   (one server pairs the ranked queue at a time)
-- A lobby is started by whichever server claims it first (UpdateAsync); it reserves a match server,
-- stores the settings, and marks the lobby started with the access code. Every server then
-- teleports its own players that belong to that lobby.
--
-- Net (client -> server), lobby place:
--   "play" [, "ffa" | "team" | "special" | "solo" | "tutorial"]   join that public lobby
--                           (solo / tutorial: a single-player match right away; "solo" may carry
--                           the single-player page's settings as a2, cleaned by cleanSettings)
--   "leave"                 leave the public lobby
--   "rankedJoin" / "rankedLeave"
--   "lobbyCreate", "lobbyJoin" code, "lobbyLeave", "lobbySettings" table, "lobbyStart",
--   "lobbyKick" userId
-- Net (server -> client): "mm" { kind = "ranked" | "lobby" | "public" | "notice" | "teleport", ... }
--
-- Studio: MemoryStore works, teleports don't. A match that would start is announced with an
-- "mm" teleport notice and its settings are stored in the workspace attribute WFMatchConfigLast
-- (copy it into WFMatchConfig, set WFRole = "match" and press Play to test that match).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Place = require(Shared:WaitForChild("Place"))
local Modifiers = require(Shared:WaitForChild("Modifiers"))

local Matchmaker = {}

local IS_STUDIO = RunService:IsStudio()
local JOB = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
local PREFIX = "WF1_"
local SYNC_SECONDS = 2
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

local ctx: any = nil
-- ctx = { net, progression (module or nil), mapPool() -> { MapCatalog info },
--         rollTeams() -> team config, modeTitle(mode, maxPlayers) -> string, isTeam(mode) -> boolean }

local role = Place.role()
Matchmaker.role = role
Matchmaker.active = role == "lobby" -- GameServer: the lobby place plays no rounds

local function sortedMap(name: string)
	return MemoryStoreService:GetSortedMap(PREFIX .. name)
end

local maps = {} -- lazily created MemoryStore sorted maps
local function store(name: string)
	local m = maps[name]
	if not m then
		m = sortedMap(name)
		maps[name] = m
	end
	return m
end

-- pcall wrapper: MemoryStore calls throw on throttling / outages; a failed call just skips a beat.
local function try(fn, ...)
	local ok, a, b = pcall(fn, ...)
	if not ok then
		warn("[War Front] matchmaking: " .. tostring(a))
		return nil
	end
	return a, b
end

local function send(plr: Player, data)
	if plr.Parent then
		ctx.net:FireClient(plr, "mm", data)
	end
end

local function notice(plr: Player, text: string, color: string?)
	send(plr, { kind = "notice", text = text, color = color })
end

--------------------------------------------------------------------------------
-- Map sizes (MapPlaylist.calculateMapPlayerCounts / lobbyMaxPlayers)
--------------------------------------------------------------------------------
local function mapInfo(id: string)
	for _, info in ctx.mapPool() do
		if info.id == id then
			return info
		end
	end
	return nil
end

-- "For every 1,000,000 land tiles, take 50 players", rounded to 5; our tiles are 1/16 of the area.
local function mapPlayerCounts(id: string): (number, number, number)
	local info = mapInfo(id)
	local land = (if info then info.land else 134751) * Config.AREA_SCALE
	local function r5(n: number): number
		return math.floor(n / 5 + 0.5) * 5
	end
	local base = math.max(r5(land / 1000000 * 50), 5)
	return base, r5(base * 0.75), r5(base * 0.5)
end

--------------------------------------------------------------------------------
-- Teleports
--------------------------------------------------------------------------------
local function handOff(plr: Player)
	-- Save the profile now and stop this server from saving it again, so the next server reads
	-- the up-to-date profile (Progression.handOff).
	if ctx.progression and ctx.progression.handOff then
		pcall(ctx.progression.handOff, plr)
	end
end

-- Sends players to a reserved match server (lobby -> match).
local function teleportToMatch(list: { Player }, access: string, label: string)
	local alive = {}
	for _, plr in list do
		if plr.Parent then
			alive[#alive + 1] = plr
			send(plr, { kind = "teleport", text = label })
		end
	end
	if #alive == 0 then
		return
	end
	if IS_STUDIO or access == "STUDIO" then
		for _, plr in alive do
			notice(plr, "Studio: the match would start now (teleports only work in a live game). Its settings are in workspace.WFMatchConfigLast.", "blue")
		end
		return
	end
	for _, plr in alive do
		handOff(plr)
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = access
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Config.MATCH_PLACE_ID, alive, options)
	end)
	if not ok then
		warn("[War Front] teleport to match failed: " .. tostring(err))
		for _, plr in alive do
			notice(plr, "Couldn't join the match. Please try again.", "red")
		end
	end
end

-- Match / anywhere -> lobby place.
function Matchmaker.toLobby(list: { Player })
	local alive = {}
	for _, plr in list do
		if plr.Parent then
			alive[#alive + 1] = plr
			send(plr, { kind = "teleport", text = "Returning to the lobby..." })
		end
	end
	if #alive == 0 then
		return
	end
	if IS_STUDIO then
		for _, plr in alive do
			notice(plr, "Studio: you would go back to the lobby now (teleports only work in a live game).", "blue")
		end
		return
	end
	for _, plr in alive do
		handOff(plr)
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Config.LOBBY_PLACE_ID, alive)
	end)
	if not ok then
		warn("[War Front] teleport to lobby failed: " .. tostring(err))
	end
end

-- Reserves a match server and stores its settings. Returns the access code (or nil).
local function reserveMatch(cfg): string?
	cfg.created = os.time()
	if IS_STUDIO then
		workspace:SetAttribute("WFMatchConfigLast", HttpService:JSONEncode(cfg))
		return "STUDIO"
	end
	if Config.MATCH_PLACE_ID == 0 then
		return nil
	end
	local ok, access, privateId = pcall(function()
		return TeleportService:ReserveServer(Config.MATCH_PLACE_ID)
	end)
	if not ok or not access then
		warn("[War Front] ReserveServer failed: " .. tostring(access))
		return nil
	end
	local stored = false
	for _ = 1, 3 do
		if try(function()
			store("Match"):SetAsync(privateId, cfg, 3600)
			return true
		end) then
			stored = true
			break
		end
		task.wait(1)
	end
	if not stored then
		return nil
	end
	return access
end

--------------------------------------------------------------------------------
-- Settings (HostLobbyModal / GameConfig subset)
--------------------------------------------------------------------------------
local DIFFICULTIES = { Easy = true, Medium = true, Hard = true, Impossible = true }
local TEAM_CHOICES = {
	[2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true,
	Duos = true, Trios = true, Quads = true, ["Humans Vs Nations"] = true,
}

Matchmaker.DEFAULT_SETTINGS = {
	map = "Europe",
	randomMap = false,
	difficulty = "Easy", -- HostLobbyModal default
	mode = "FFA", -- "FFA" | "Team" (switching to Team turns both donations on, like OpenFront)
	teams = 2, -- 2..7 | "Duos" | "Trios" | "Quads" | "Humans Vs Nations"
	bots = 400, -- OpenFront units (0-400); our maps get 1/4, scaled by land
	nations = true,
	instantBuild = false,
	randomSpawn = false,
	donateGold = false,
	donateTroops = false,
	infiniteGold = false,
	infiniteTroops = false,
	maxTimer = 0, -- minutes, 0 = no limit
	-- GameConfigSettings extras (solo and private lobbies)
	compact = false, -- compact map (half size, 25 % of the nations)
	noAlliances = false, -- disable alliances
	waterNukes = false, -- nukes turn land into water
	overtime = false, -- the win share sinks after 30 minutes
	doomsday = "off", -- Doomsday Clock: "off" | "slow" | "normal" | "fast" | "veryfast"
	goldMultiplier = 1, -- 1 = off
	startingGold = 0, -- 0 = off
	allianceMinutes = 0, -- custom alliance duration, 0 = default (5 min)
	immunitySeconds = 5, -- spawn immunity after the spawn phase (OpenFront default 5 s)
	disabledUnits = {}, -- unit kinds nobody may build (Config.STRUCTURES / NUKES / UNITS keys)
}
local DOOMSDAY = { off = true, slow = true, normal = true, fast = true, veryfast = true }

-- Number setting: a finite number clamped to [lo, hi] (rounded to `step`).
local function num(v: any, lo: number, hi: number, step: number): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.clamp(math.floor(v / step + 0.5) * step, lo, hi)
end

-- Copies only known keys with valid values over the current settings.
function Matchmaker.cleanSettings(incoming: any, current: any)
	local out = table.clone(current or Matchmaker.DEFAULT_SETTINGS)
	if type(incoming) ~= "table" then
		return out
	end
	if type(incoming.map) == "string" and mapInfo(incoming.map) then
		out.map = incoming.map
	end
	for _, k in { "randomMap", "nations", "instantBuild", "randomSpawn", "donateGold", "donateTroops", "infiniteGold", "infiniteTroops" } do
		if type(incoming[k]) == "boolean" then
			out[k] = incoming[k]
		end
	end
	if type(incoming.difficulty) == "string" and DIFFICULTIES[incoming.difficulty] then
		out.difficulty = incoming.difficulty
	end
	if incoming.mode == "FFA" or incoming.mode == "Team" then
		out.mode = incoming.mode
	end
	if incoming.teams ~= nil and TEAM_CHOICES[incoming.teams] then
		out.teams = incoming.teams
	end
	if type(incoming.bots) == "number" and incoming.bots == incoming.bots then
		out.bots = math.clamp(math.floor(incoming.bots + 0.5), 0, 400)
	end
	if type(incoming.maxTimer) == "number" and incoming.maxTimer == incoming.maxTimer then
		out.maxTimer = math.clamp(math.floor(incoming.maxTimer + 0.5), 0, 120)
	end
	for _, k in { "compact", "noAlliances", "waterNukes", "overtime" } do
		if type(incoming[k]) == "boolean" then
			out[k] = incoming[k]
		end
	end
	if type(incoming.doomsday) == "string" and DOOMSDAY[incoming.doomsday] then
		out.doomsday = incoming.doomsday
	end
	out.goldMultiplier = num(incoming.goldMultiplier, 1, 10, 0.5) or out.goldMultiplier or 1
	out.startingGold = num(incoming.startingGold, 0, 100000000, 100000) or out.startingGold or 0
	out.allianceMinutes = num(incoming.allianceMinutes, 0, 60, 1) or out.allianceMinutes or 0
	out.immunitySeconds = num(incoming.immunitySeconds, 0, 600, 5) or out.immunitySeconds or 5
	if type(incoming.disabledUnits) == "table" then
		local list = {}
		for _, k in incoming.disabledUnits do
			if type(k) == "string" and (Config.STRUCTURES[k] or Config.NUKES[k] or Config.UNITS[k]) and not table.find(list, k) then
				list[#list + 1] = k
			end
		end
		out.disabledUnits = list
	end
	return out
end

-- Settings as the match server reads them (GameServer match.rules): "off" Doomsday -> none.
local function rulesFromSettings(s)
	local r = table.clone(s)
	if r.doomsday == "off" then
		r.doomsday = nil
	end
	return r
end

local function modeFromSettings(s)
	if s.mode == "Team" then
		return { kind = "Team", teams = s.teams }
	end
	return { kind = "FFA" }
end

--------------------------------------------------------------------------------
-- Public lobbies (MasterLobbyService + MapPlaylist): an FFA, a Teams and a Special lobby run
-- side by side. Each picks its map from its own playlist; Special lobbies roll FFA or Teams and
-- one to three modifiers. The countdown starts with the first player.
--------------------------------------------------------------------------------
local PUB_TYPES = { "ffa", "team", "special" }
Matchmaker.PUB_TYPES = PUB_TYPES

local pub = {
	recs = {} :: { [string]: any }, -- last read record per lobby type
	count = {} :: { [string]: number },
	members = {} :: { [string]: { any } }, -- { userId, name } per lobby type
	want = {} :: { [Player]: string }, -- lobby type each of our players is waiting in
	memberOf = {} :: { [Player]: string }, -- lobby id their membership entry is written for
	refreshedAt = {} :: { [Player]: number },
	rng = Random.new(),
}

-- MapPlaylist.addNextMapNonConsecutive: never one of the last 5 maps of this playlist.
local function nextMap(prev): string
	local pool = ctx.mapPool()
	local recent = if prev and type(prev.recent) == "table" then prev.recent else {}
	local keep = math.min(5, #pool - 1)
	local options = {}
	for _, info in pool do
		local seen = false
		for i = math.max(1, #recent - keep + 1), #recent do
			if recent[i] == info.id then
				seen = true
			end
		end
		if not seen then
			options[#options + 1] = info.id
		end
	end
	if #options == 0 then
		for _, info in pool do
			options[#options + 1] = info.id
		end
	end
	return options[pub.rng:NextInteger(1, #options)]
end

-- playersPerTeam / numberOfTeams / adjustForTeams / supportsTeamPlayerCount
local function perTeam(n: number, teams): number
	if teams == "Duos" then
		return math.min(2, n)
	elseif teams == "Trios" then
		return math.min(3, n)
	elseif teams == "Quads" then
		return math.min(4, n)
	elseif teams == "Humans Vs Nations" then
		return n
	end
	return n // teams
end
local function teamCount(n: number, teams): number
	if teams == "Duos" then
		return n // 2
	elseif teams == "Trios" then
		return n // 3
	elseif teams == "Quads" then
		return n // 4
	elseif teams == "Humans Vs Nations" then
		return 2
	end
	return teams
end
local function adjustForTeams(n: number, teams): number
	if teams == nil then
		return n
	elseif teams == "Duos" then
		return n - n % 2
	elseif teams == "Trios" then
		return n - n % 3
	elseif teams == "Quads" then
		return n - n % 4
	elseif teams == "Humans Vs Nations" then
		return n // 2
	end
	return n - n % teams
end
local function supportsTeams(n: number, teams): boolean
	return perTeam(n, teams) >= 2 and teamCount(n, teams) >= 2
end

-- supportsCompactMapForTeams: the smallest tier, compact, still gives every team 2 players.
local function supportsCompact(map: string, teams): boolean
	local l, _, s = mapPlayerCounts(map)
	local p = math.min(math.ceil(s * 1.5), l)
	p = math.max(3, math.floor(p * 0.25))
	return supportsTeams(adjustForTeams(p, teams), teams)
end

-- lobbyMaxPlayers: large / medium / small player count with 30 / 30 / 40 % odds (x1.5 for
-- teams, capped at the large count), a quarter on compact maps.
local function rollMaxPlayers(map: string, team: boolean, compact: boolean): number
	local l, m, s = mapPlayerCounts(map)
	local r = pub.rng:NextNumber()
	local base = if r < 0.3 then l elseif r < 0.6 then m else s
	local p = math.min(if team then math.ceil(base * 1.5) else base, l)
	if compact then
		p = math.max(3, math.floor(p * 0.25))
	end
	return p
end

-- getCrowdedMaxPlayers: small maps (largest count <= 60) take 125 players (60 compact).
local function crowdedMax(map: string, compact: boolean): number?
	local l = mapPlayerCounts(map)
	if l <= 60 then
		return if compact then 60 else 125
	end
	return nil
end

-- adjustTeamCountForPlayerCapacity
local function fitTeams(teams, maxPlayers: number)
	if type(teams) ~= "number" or supportsTeams(adjustForTeams(maxPlayers, teams), teams) then
		return teams
	end
	return math.max(2, maxPlayers // 2)
end

-- One rolled public game (MapPlaylist.gameConfig / getSpecialConfig).
local function rollGame(kind: string, prev)
	local round = (if prev then prev.round or 0 else 0) + 1
	local map = nextMap(prev)
	local team = if kind == "ffa" then false elseif kind == "team" then true else pub.rng:NextNumber() < 0.5
	local teams = if team then ctx.rollTeams() else nil
	local m: any = {}
	local crowdedPlayers: number? = nil
	if kind == "special" then
		local excluded = {}
		if team and not supportsCompact(map, teams) then
			excluded.isCompact = true
		end
		if teams == "Duos" or teams == "Trios" or teams == "Quads" then
			excluded.isRandomSpawn = true
		end
		if team then
			excluded.isHardNations = true
		end
		if teams == "Humans Vs Nations" then
			excluded.startingGold25M = true
			excluded.isPeaceTime = true
		end
		local keys = Modifiers.pick(pub.rng, excluded)
		m = Modifiers.fromKeys(keys, pub.rng)
		if m.crowded then
			crowdedPlayers = crowdedMax(map, m.compact == true)
			if not crowdedPlayers then
				-- The map doesn't support crowded: drop it, and roll one replacement when it was
				-- the only modifier, so the lobby always has at least one.
				m.crowded = nil
				if not Modifiers.any(m) then
					excluded.isCrowded = true
					m = Modifiers.fromKeys(Modifiers.pick(pub.rng, excluded, 1), pub.rng)
				end
			end
		end
	else
		-- Every third FFA / Teams game is on a compact map.
		local compact = round % 3 == 0
		if compact and team and not supportsCompact(map, teams) then
			compact = false
		end
		m.compact = compact or nil
	end
	local unadjusted = crowdedPlayers or rollMaxPlayers(map, team, m.compact == true)
	teams = if team then fitTeams(teams, unadjusted) else nil
	local maxPlayers = math.max(2, adjustForTeams(unadjusted, teams))
	maxPlayers = math.max(2, math.min(maxPlayers, adjustForTeams(Config.PUBLIC_MAX_PLAYERS, teams)))
	local mode = if team then { kind = "Team", teams = teams } else { kind = "FFA" }
	local hvn = teams == "Humans Vs Nations"
	local recent = if prev and type(prev.recent) == "table" then table.clone(prev.recent) else {}
	recent[#recent + 1] = map
	while #recent > 5 do
		table.remove(recent, 1)
	end
	local settings = {
		difficulty = if m.hardNations or hvn then "Hard" else "Medium",
		-- Nations sit out team games (except Humans vs Nations) and 25M starting gold games.
		nations = not ((team and not hvn) or (m.startingGold or 0) >= 25000000),
		bots = if m.compact then 100 else 400,
		randomSpawn = m.randomSpawn == true,
		donateGold = team,
		donateTroops = team,
		immunitySeconds = Modifiers.immunitySeconds(m, hvn),
		startingGold = m.startingGold,
		goldMultiplier = m.goldMultiplier,
		noAlliances = m.alliancesDisabled == true,
		disabledUnits = Modifiers.disabledUnits(m),
		waterNukes = m.waterNukes == true,
		doomsday = m.doomsday,
		overtime = kind == "ffa", -- the default for every public FFA game (no badge)
		compact = m.compact == true,
		mods = Modifiers.labels(m),
	}
	return {
		id = string.sub(HttpService:GenerateGUID(false), 1, 8),
		type = kind,
		round = round,
		map = map,
		mode = mode,
		max = maxPlayers,
		settings = settings,
		recent = recent,
		state = "open",
		created = os.time(),
	}
end

local function pubView(rec, kind: string)
	local info = mapInfo(rec.map)
	local secs = if rec.startsAt then math.max(0, rec.startsAt - os.time()) else nil
	local s = rec.settings or {}
	return {
		id = rec.id,
		type = kind,
		map = rec.map,
		name = if info then info.name else rec.map,
		mode = rec.mode,
		sub = ctx.modeTitle(rec.mode, rec.max),
		mods = s.mods or {},
		count = pub.count[kind] or 0,
		max = rec.max or Config.PUBLIC_MAX_PLAYERS,
		secs = if rec.state == "open" then secs else 0,
		started = rec.state ~= "open",
		default = Config.PUBLIC_LOBBY_SECONDS,
	}
end

-- Phase payload pieces for the lobby place (GameServer merges them into "phase").
function Matchmaker.lobbyPhase()
	local out = {}
	for _, kind in PUB_TYPES do
		local rec = pub.recs[kind]
		if rec then
			out[kind] = pubView(rec, kind)
		end
	end
	return { lobbies = out }
end

function Matchmaker.inPublic(plr: Player): boolean
	return pub.want[plr] ~= nil
end

local function writeMember(plr: Player, lobbyId: string)
	local key = lobbyId .. ":" .. plr.UserId
	local ok = try(function()
		store("PubMem"):SetAsync(key, { name = plr.DisplayName, job = JOB }, 30)
		return true
	end)
	if ok then
		pub.memberOf[plr] = lobbyId
		pub.refreshedAt[plr] = os.clock()
	end
end

local function removeMember(plr: Player)
	local id = pub.memberOf[plr]
	pub.memberOf[plr] = nil
	pub.refreshedAt[plr] = nil
	if id then
		task.spawn(try, function()
			store("PubMem"):RemoveAsync(id .. ":" .. plr.UserId)
		end)
	end
end

-- Tells a waiting player about their lobby (the "Waiting for Game Start..." page).
local function sendPublic(plr: Player)
	local kind = pub.want[plr]
	if not kind then
		send(plr, { kind = "public", type = nil })
		return
	end
	local rec = pub.recs[kind]
	send(plr, {
		kind = "public",
		type = kind,
		lobby = if rec then pubView(rec, kind) else nil,
		members = pub.members[kind] or {},
	})
end

local function startPublic(rec, members)
	-- We claimed it: reserve the server and publish the access code.
	local ids = {}
	for _, m in members do
		local uid = tonumber(string.match(m.key, ":(%d+)$"))
		if uid then
			ids[#ids + 1] = uid
		end
	end
	local cfg = {
		kind = "public",
		lobbyType = rec.type,
		map = rec.map,
		mode = rec.mode,
		players = ids,
		settings = rec.settings,
	}
	local access = reserveMatch(cfg)
	try(function()
		store("Public"):UpdateAsync(rec.type, function(old)
			if not old or old.id ~= rec.id then
				return nil
			end
			if access then
				old.state = "started"
				old.access = access
				old.startedAt = os.time()
			else
				old.state = "open" -- couldn't reserve a server: try again next beat
				old.owner = nil
				old.startsAt = os.time() + 5
			end
			return old
		end, 3600)
	end)
end

local function syncPublicType(kind: string)
	local pubStore = store("Public")
	local now = os.time()
	local function isStale(r)
		return r == nil
			or r.type ~= kind
			or (r.state == "started" and now - (r.startedAt or 0) > 8)
			or (r.state == "starting" and now - (r.startingAt or 0) > 20)
	end
	local rec = try(function()
		return pubStore:GetAsync(kind)
	end)
	if isStale(rec) then
		try(function()
			pubStore:UpdateAsync(kind, function(old)
				if old == nil or old.type ~= kind or (old.state == "started" and now - (old.startedAt or 0) > 8) then
					return rollGame(kind, if old and old.type == kind then old else nil)
				elseif old.state == "starting" and now - (old.startingAt or 0) > 20 then
					old.state, old.owner = "open", nil
					return old
				end
				return nil
			end, 3600)
		end)
		rec = try(function()
			return pubStore:GetAsync(kind)
		end)
	end
	if not rec then
		return
	end
	pub.recs[kind] = rec

	-- Our players: membership entries for the open lobby (written on change, refreshed every 10 s).
	if rec.state == "open" then
		for plr, k in pub.want do
			if k == kind and (pub.memberOf[plr] ~= rec.id or os.clock() - (pub.refreshedAt[plr] or 0) > 10) then
				writeMember(plr, rec.id)
			end
		end
	end

	local members = try(function()
		return store("PubMem"):GetRangeAsync(Enum.SortDirection.Ascending, 200, { key = rec.id .. ":" }, { key = rec.id .. ";" })
	end) or {}
	pub.count[kind] = #members
	local list = {}
	for _, m in members do
		local uid = tonumber(string.match(m.key, ":(%d+)$"))
		list[#list + 1] = { userId = uid, name = if type(m.value) == "table" then tostring(m.value.name or "") else "" }
	end
	pub.members[kind] = list

	if rec.state == "open" then
		local max = rec.max or Config.PUBLIC_MAX_PLAYERS
		if #members > 0 and not rec.startsAt then
			-- The countdown starts with the first player (an empty lobby waits).
			try(function()
				pubStore:UpdateAsync(kind, function(old)
					if old and old.id == rec.id and old.state == "open" and not old.startsAt then
						old.startsAt = now + Config.PUBLIC_LOBBY_SECONDS
						return old
					end
					return nil
				end, 3600)
			end)
		elseif #members == 0 and rec.startsAt then
			try(function()
				pubStore:UpdateAsync(kind, function(old)
					if old and old.id == rec.id and old.state == "open" then
						old.startsAt = nil
						return old
					end
					return nil
				end, 3600)
			end)
		elseif #members > 0 and rec.startsAt and (now >= rec.startsAt or #members >= max) then
			-- Full or time's up: the first server to claim it starts the game.
			local claimed = false
			try(function()
				pubStore:UpdateAsync(kind, function(old)
					claimed = false
					if old and old.id == rec.id and old.state == "open" then
						old.state, old.owner, old.startingAt = "starting", JOB, now
						claimed = true
						return old
					end
					return nil
				end, 3600)
			end)
			if claimed then
				startPublic(rec, members)
			end
		end
	elseif rec.state == "started" and rec.access then
		-- Send our members of this lobby to the match.
		local list2 = {}
		for plr, k in pub.want do
			if k == kind and pub.memberOf[plr] == rec.id then
				list2[#list2 + 1] = plr
			end
		end
		if #list2 > 0 then
			for _, plr in list2 do
				pub.want[plr] = nil
				pub.memberOf[plr] = nil
			end
			task.spawn(teleportToMatch, list2, rec.access, "Starting...")
		end
	end
	for plr, k in pub.want do
		if k == kind then
			sendPublic(plr)
		end
	end
end

local function syncPublic()
	for _, kind in PUB_TYPES do
		try(syncPublicType, kind)
	end
end

--------------------------------------------------------------------------------
-- Ranked 1v1 (Matchmaking.ts / MapPlaylist.get1v1Config)
--------------------------------------------------------------------------------
local ranked = {
	queued = {} :: { [Player]: number }, -- os.time() they joined
	refreshedAt = {} :: { [Player]: number },
	queueSize = 0,
}

local RANKED_MAPS = { "Europe", "Europe", "Britannia", "Italia" } -- 1v1 map pool (closest we have)

local function eloOf(plr: Player): number?
	if ctx.progression and ctx.progression.getElo then
		return ctx.progression.getElo(plr)
	end
	return nil
end

local function rankedStatus(plr: Player, state: string)
	send(plr, { kind = "ranked", state = state, queueSize = ranked.queueSize, elo = eloOf(plr) })
end

local function rankedConfig(a: number, b: number)
	local pool = {}
	for _, id in RANKED_MAPS do
		if mapInfo(id) then
			pool[#pool + 1] = id
		end
	end
	local map = if #pool > 0 then pool[math.random(1, #pool)] else "Europe"
	return {
		kind = "ranked",
		map = map,
		mode = { kind = "FFA" },
		players = { a, b },
		settings = {
			nations = false, -- nations: "disabled"
			bots = 400,
			donateGold = false,
			donateTroops = false,
			maxTimer = Config.RANKED_TIMER_MINUTES,
			immunitySeconds = 30, -- spawnImmunityDuration 30 * 10 ticks
		},
	}
end

local function pairRanked(entries)
	-- Greedy pairing of neighbours by Elo; the allowed gap grows the longer people wait.
	local now = os.time()
	local list = {}
	for _, e in entries do
		local v = e.value
		if type(v) == "table" and v.state == "queued" then
			list[#list + 1] = { uid = tonumber(e.key), elo = v.elo or Config.RANKED_START_ELO, t = v.t or now }
		end
	end
	table.sort(list, function(x, y)
		return x.elo < y.elo
	end)
	local used = {}
	for i = 1, #list - 1 do
		local a, b = list[i], list[i + 1]
		if not used[i] and not used[i + 1] and a.uid and b.uid then
			local waited = now - math.min(a.t, b.t)
			local window = math.min(100 + 25 * waited, 2000)
			if math.abs(a.elo - b.elo) <= window then
				used[i], used[i + 1] = true, true
				local access = reserveMatch(rankedConfig(a.uid, b.uid))
				if access then
					for _, uid in { a.uid, b.uid } do
						try(function()
							store("Ranked"):UpdateAsync(tostring(uid), function(old)
								if old and old.state == "queued" then
									old.state, old.access = "matched", access
									return old
								end
								return nil
							end, 120)
						end)
					end
				end
			end
		end
	end
end

local function syncRanked()
	if next(ranked.queued) == nil then
		return
	end
	local rk = store("Ranked")
	local now = os.time()
	for plr, since in ranked.queued do
		if os.clock() - (ranked.refreshedAt[plr] or 0) > 10 then
			ranked.refreshedAt[plr] = os.clock()
			try(function()
				rk:UpdateAsync(tostring(plr.UserId), function(old)
					if old and old.state == "matched" then
						return nil
					end
					return { elo = eloOf(plr) or Config.RANKED_START_ELO, job = JOB, t = since, state = "queued" }
				end, 60)
			end)
		end
	end
	local entries = try(function()
		return rk:GetRangeAsync(Enum.SortDirection.Ascending, 200)
	end) or {}
	local size = 0
	for _, e in entries do
		if type(e.value) == "table" and e.value.state == "queued" then
			size += 1
		end
	end
	ranked.queueSize = size
	-- One server pairs at a time.
	local leader = false
	try(function()
		store("Lock"):UpdateAsync("ranked", function(old)
			if old == nil or old.job == JOB or (old.exp or 0) < now then
				leader = true
				return { job = JOB, exp = now + 6 }
			end
			leader = false
			return nil
		end, 10)
	end)
	if leader and size >= 2 then
		pairRanked(entries)
	end
	-- Our players: matched -> teleport, otherwise report the queue.
	for plr in table.clone(ranked.queued) do
		local entry = try(function()
			return rk:GetAsync(tostring(plr.UserId))
		end)
		if type(entry) == "table" and entry.state == "matched" and entry.access then
			ranked.queued[plr] = nil
			ranked.refreshedAt[plr] = nil
			task.spawn(try, function()
				rk:RemoveAsync(tostring(plr.UserId))
			end)
			rankedStatus(plr, "found")
			task.spawn(teleportToMatch, { plr }, entry.access, "Waiting for game to start...")
		else
			rankedStatus(plr, "searching")
		end
	end
end

local function leaveRanked(plr: Player)
	if ranked.queued[plr] then
		ranked.queued[plr] = nil
		ranked.refreshedAt[plr] = nil
		task.spawn(try, function()
			store("Ranked"):RemoveAsync(tostring(plr.UserId))
		end)
	end
end

--------------------------------------------------------------------------------
-- Private lobbies (HostLobbyModal / JoinLobbyModal)
--------------------------------------------------------------------------------
local private = {
	codeOf = {} :: { [Player]: string },
}

local function newCode(): string
	local out = table.create(6)
	for i = 1, 6 do
		local k = math.random(1, #CODE_CHARS)
		out[i] = string.sub(CODE_CHARS, k, k)
	end
	return table.concat(out)
end

local function cleanCode(raw: any): string?
	if type(raw) ~= "string" then
		return nil
	end
	local c = string.upper((string.gsub(raw, "[^%w]", "")))
	if #c ~= 6 then
		return nil
	end
	return c
end

local function memberCount(rec): number
	local n = 0
	for _ in rec.members or {} do
		n += 1
	end
	return n
end

-- What the client sees of a lobby.
local function lobbyView(rec, plr: Player)
	local members = {}
	for uid, m in rec.members or {} do
		members[#members + 1] = { userId = tonumber(uid), name = m.name, host = tonumber(uid) == rec.host }
	end
	table.sort(members, function(a, b)
		if a.host ~= b.host then
			return a.host
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return {
		kind = "lobby",
		code = rec.code,
		host = rec.host,
		isHost = rec.host == plr.UserId,
		hostName = rec.hostName,
		settings = rec.settings,
		members = members,
		state = rec.state,
	}
end

local function updateLobby(code: string, fn: (any) -> any?): any?
	local result = nil
	try(function()
		store("Private"):UpdateAsync(code, function(old)
			result = nil
			if old == nil then
				return nil
			end
			local new = fn(old)
			if new then
				new.updated = os.time()
				result = new
			end
			return new
		end, 7200)
	end)
	return result
end

local function lobbyClosed(plr: Player, why: string)
	private.codeOf[plr] = nil
	send(plr, { kind = "lobby", state = "closed", reason = why })
end

local function createLobby(plr: Player)
	if private.codeOf[plr] then
		return
	end
	leaveRanked(plr)
	for _ = 1, 6 do
		local code = newCode()
		local rec = {
			code = code,
			host = plr.UserId,
			hostName = plr.DisplayName,
			settings = table.clone(Matchmaker.DEFAULT_SETTINGS),
			members = { [tostring(plr.UserId)] = { name = plr.DisplayName, job = JOB } },
			state = "open",
			created = os.time(),
			updated = os.time(),
		}
		local made = false
		try(function()
			store("Private"):UpdateAsync(code, function(old)
				if old ~= nil then
					made = false
					return nil
				end
				made = true
				return rec
			end, 7200)
		end)
		if made then
			private.codeOf[plr] = code
			send(plr, lobbyView(rec, plr))
			return
		end
	end
	notice(plr, "An error occurred. Please try again or contact support.", "red") -- private_lobby.error
end

local function joinLobby(plr: Player, raw: any)
	local code = cleanCode(raw)
	if not code then
		send(plr, { kind = "lobby", state = "error", reason = "Lobby not found. Please check the ID and try again." })
		return
	end
	if private.codeOf[plr] == code then
		return
	end
	leaveRanked(plr)
	local why = "Lobby not found. Please check the ID and try again." -- private_lobby.not_found
	local rec = updateLobby(code, function(old)
		if old.state ~= "open" then
			why = "This lobby has already started."
			return nil
		end
		if memberCount(old) >= Config.PRIVATE_MAX_PLAYERS and not old.members[tostring(plr.UserId)] then
			why = "This lobby is full."
			return nil
		end
		old.members[tostring(plr.UserId)] = { name = plr.DisplayName, job = JOB }
		return old
	end)
	if not rec then
		send(plr, { kind = "lobby", state = "error", reason = why })
		return
	end
	private.codeOf[plr] = code
	send(plr, lobbyView(rec, plr))
end

local function leaveLobby(plr: Player)
	local code = private.codeOf[plr]
	if not code then
		return
	end
	private.codeOf[plr] = nil
	task.spawn(updateLobby, code, function(old)
		old.members[tostring(plr.UserId)] = nil
		if old.host == plr.UserId and old.state == "open" then
			old.state = "closed" -- the host left: the lobby closes for everyone
		end
		return old
	end)
	send(plr, { kind = "lobby", state = "left" })
end

local function startLobby(plr: Player)
	local code = private.codeOf[plr]
	if not code then
		return
	end
	local rec = try(function()
		return store("Private"):GetAsync(code)
	end)
	if not rec or rec.host ~= plr.UserId or rec.state ~= "open" then
		return
	end
	local s = Matchmaker.cleanSettings(rec.settings, Matchmaker.DEFAULT_SETTINGS)
	local map = s.map
	if s.randomMap then
		local pool = ctx.mapPool()
		map = pool[math.random(1, #pool)].id
	end
	local ids = {}
	for uid in rec.members do
		ids[#ids + 1] = tonumber(uid)
	end
	local access = reserveMatch({
		kind = "private",
		map = map,
		mode = modeFromSettings(s),
		players = ids,
		settings = rulesFromSettings(s),
	})
	if not access then
		notice(plr, "An error occurred. Please try again or contact support.", "red")
		return
	end
	updateLobby(code, function(old)
		if old.state ~= "open" then
			return nil
		end
		old.state, old.access = "started", access
		return old
	end)
end

local function syncPrivate()
	local byCode: { [string]: { Player } } = {}
	for plr, code in private.codeOf do
		local list = byCode[code]
		if not list then
			list = {}
			byCode[code] = list
		end
		list[#list + 1] = plr
	end
	for code, list in byCode do
		local rec = try(function()
			return store("Private"):GetAsync(code)
		end)
		if not rec or rec.state == "closed" then
			for _, plr in list do
				lobbyClosed(plr, if rec then "The host closed the lobby." else "The lobby expired.")
			end
		elseif rec.state == "started" and rec.access then
			local go = {}
			for _, plr in list do
				if rec.members[tostring(plr.UserId)] then
					go[#go + 1] = plr
				end
				private.codeOf[plr] = nil
			end
			task.spawn(teleportToMatch, go, rec.access, "Starting...")
		else
			for _, plr in list do
				if rec.members[tostring(plr.UserId)] then
					send(plr, lobbyView(rec, plr))
				else
					lobbyClosed(plr, "You were removed from the lobby.")
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Requests (lobby place)
--------------------------------------------------------------------------------
local KINDS = {
	play = true, leave = true,
	rankedJoin = true, rankedLeave = true,
	lobbyCreate = true, lobbyJoin = true, lobbyLeave = true, lobbySettings = true, lobbyStart = true, lobbyKick = true,
}

function Matchmaker.handles(kind: string): boolean
	return Matchmaker.active and KINDS[kind] == true
end

-- Tutorial / Solo: a single-player match right away (Solo: a random map, OpenFront's
-- single-player defaults: Medium nations, 400 bots).
-- custom: the single-player page's settings (SinglePlayerModal); nil = quick solo on a random map.
local function soloMatch(plr: Player, kind: string, custom: any)
	local pool = ctx.mapPool()
	local map = if mapInfo("Europe") then "Europe" else pool[1].id
	if kind == "solo" and #pool > 0 then
		map = pool[pub.rng:NextInteger(1, #pool)].id
	end
	pub.want[plr] = nil
	removeMember(plr)
	local settings = if kind == "solo" then { difficulty = "Medium", bots = 400, nations = true } else {}
	local mode = { kind = "FFA" }
	if kind == "solo" and type(custom) == "table" then
		local s = Matchmaker.cleanSettings(custom, Matchmaker.DEFAULT_SETTINGS)
		if not s.randomMap and mapInfo(s.map) then
			map = s.map
		end
		mode = modeFromSettings(s)
		settings = rulesFromSettings(s)
	end
	local access = reserveMatch({ kind = kind, map = map, mode = mode, players = { plr.UserId }, settings = settings })
	if access then
		task.spawn(teleportToMatch, { plr }, access, "Starting...")
	else
		notice(plr, "An error occurred. Please try again or contact support.", "red")
	end
end

local lastRequestAt: { [Player]: number } = {}

function Matchmaker.handle(plr: Player, kind: string, a1: any, a2: any)
	-- At most 5 requests a second per player (each may write to MemoryStore).
	local now = os.clock()
	if lastRequestAt[plr] and now - lastRequestAt[plr] < 0.2 then
		return
	end
	lastRequestAt[plr] = now
	if kind == "play" then
		if a1 == "tutorial" then
			task.spawn(soloMatch, plr, "tutorial")
			return
		end
		if a1 == "solo" then
			task.spawn(soloMatch, plr, "solo", a2) -- a2: single-player settings (optional)
			return
		end
		leaveRanked(plr)
		if private.codeOf[plr] then
			leaveLobby(plr)
		end
		local lobbyType = if table.find(PUB_TYPES, a1) then a1 else "ffa"
		if pub.want[plr] ~= lobbyType then
			removeMember(plr) -- switching lobbies
		end
		pub.want[plr] = lobbyType
		ctx.net:FireClient(plr, "joined", { phase = "Lobby", inRound = false, lobbyType = lobbyType })
		sendPublic(plr)
		task.spawn(syncPublicType, lobbyType)
	elseif kind == "leave" then
		pub.want[plr] = nil
		removeMember(plr)
		sendPublic(plr)
		ctx.net:FireClient(plr, "left", {})
	elseif kind == "rankedJoin" then
		pub.want[plr] = nil
		removeMember(plr)
		if private.codeOf[plr] then
			leaveLobby(plr)
		end
		if not ranked.queued[plr] then
			ranked.queued[plr] = os.time()
			ranked.refreshedAt[plr] = 0
		end
		rankedStatus(plr, "searching")
		task.spawn(syncRanked)
	elseif kind == "rankedLeave" then
		leaveRanked(plr)
		rankedStatus(plr, "idle")
	elseif kind == "lobbyCreate" then
		pub.want[plr] = nil
		removeMember(plr)
		task.spawn(createLobby, plr)
	elseif kind == "lobbyJoin" then
		pub.want[plr] = nil
		removeMember(plr)
		task.spawn(joinLobby, plr, a1)
	elseif kind == "lobbyLeave" then
		leaveLobby(plr)
	elseif kind == "lobbySettings" then
		local code = private.codeOf[plr]
		if code then
			task.spawn(function()
				local rec = updateLobby(code, function(old)
					if old.host ~= plr.UserId or old.state ~= "open" then
						return nil
					end
					old.settings = Matchmaker.cleanSettings(a1, old.settings)
					return old
				end)
				if rec then
					send(plr, lobbyView(rec, plr))
				end
			end)
		end
	elseif kind == "lobbyStart" then
		task.spawn(startLobby, plr)
	elseif kind == "lobbyKick" then
		local code = private.codeOf[plr]
		if code and type(a1) == "number" and a1 ~= plr.UserId then
			task.spawn(updateLobby, code, function(old)
				if old.host ~= plr.UserId then
					return nil
				end
				old.members[tostring(math.floor(a1))] = nil
				return old
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Match place
--------------------------------------------------------------------------------
-- The settings of this match server (nil = none found: a default public FFA game).
function Matchmaker.matchConfig(): any
	if IS_STUDIO then
		local raw = workspace:GetAttribute("WFMatchConfig")
		if type(raw) == "string" and raw ~= "" then
			local ok, cfg = pcall(HttpService.JSONDecode, HttpService, raw)
			if ok and type(cfg) == "table" then
				return cfg
			end
			warn("[War Front] WFMatchConfig is not valid JSON")
		end
		return { kind = "public", map = "Europe", mode = { kind = "FFA" }, players = {}, settings = {} }
	end
	if game.PrivateServerId == "" or game.PrivateServerOwnerId ~= 0 then
		return nil
	end
	for _ = 1, 10 do
		local cfg = try(function()
			return store("Match"):GetAsync(game.PrivateServerId)
		end)
		if type(cfg) == "table" then
			return cfg
		end
		task.wait(1)
	end
	return nil
end

--------------------------------------------------------------------------------
function Matchmaker.init(c)
	ctx = c
	if not Matchmaker.active then
		return
	end
	Players.PlayerRemoving:Connect(function(plr)
		lastRequestAt[plr] = nil
		pub.want[plr] = nil
		removeMember(plr)
		leaveRanked(plr)
		if private.codeOf[plr] then
			leaveLobby(plr)
		end
	end)
	task.spawn(function()
		while true do
			try(syncPublic)
			try(syncRanked)
			try(syncPrivate)
			task.wait(SYNC_SECONDS)
		end
	end)
end

return Matchmaker
