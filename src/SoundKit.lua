--[[
	War Front - sound effects and structure ambience (OpenFront's sounds).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(src/client/sound/Sounds.ts, controllers/SoundEffectController.ts, AmbienceController.ts).
	Sounds © OpenFront, CC BY-SA 4.0. Modified version re-implemented in Luau for Roblox; not
	affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.SoundKit (ModuleScript), used by GameClient and UI modules.
-- SoundKit.setup({ myId = fn, roster = fn, structures = fn -> rows })
-- SoundKit.play(name)                 one of the cue names below (no-op until the asset is uploaded)
-- SoundKit.onNet(kind, data)          derives OpenFront's game cues from server messages
-- SoundKit.step(zoom, centerTile, W)  structure ambience near the screen centre when zoomed in
-- Asset ids live in ReplicatedStorage.Shared.SoundIds (name -> "rbxassetid://..."), filled in once
-- the files in Documents/WarFront/sounds are uploaded to Roblox.

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local okIds, IDS = pcall(require, Shared:WaitForChild("SoundIds", 5))
if not okIds or type(IDS) ~= "table" then
	IDS = {}
end

local SoundKit = {}

-- Sounds.ts CUE_CATEGORY: mixer channel per cue.
local CATEGORY = {
	click = "Interface",
	["click-1"] = "Interface",
	["click-2"] = "Interface",
	["click-3"] = "Interface",
	slider = "Interface",
	["nuke-warning"] = "Alerts",
	["alliance-suggested"] = "Alerts",
	["alliance-accepted"] = "Alerts",
	["alliance-declined"] = "Alerts",
	["alliance-broken"] = "Alerts",
	message = "Alerts",
}
-- "message" reuses the alliance request's morse-code cue (one asset, two registry entries).
local ASSET_ALIAS = { message = "alliance-suggested" }

local AMBIENCE_BY_KIND = { City = "ambience-city", Factory = "ambience-factory", MissileSilo = "ambience-missile-silo", SAM = "ambience-sam-silo" }
local AMBIENCE_PEAK_GAIN = 0.3
local MIRV_HIT_INTERVAL = 0.5 -- MIRV_HIT_SOUND_INTERVAL_TICKS (5)
local NUKE_WARNING_INTERVAL = 1 -- NUKE_WARNING_SOUND_INTERVAL_TICKS (10)

local ctx: any = nil
local groups: { [string]: SoundGroup } = {}
local templates: { [string]: Sound } = {}
local lastPlayed: { [string]: number } = {}
local knownStructures: { [number]: boolean } = {}
local knownUnits: { [number]: boolean } = {}
local lastPhase: string? = nil
local ambience: Sound? = nil
local ambienceName: string? = nil
local music: Sound? = nil
local musicName: string? = nil

local function group(name: string): SoundGroup
	local g = groups[name]
	if g then
		return g
	end
	local master = SoundService:FindFirstChild("Master")
	if not master then
		master = Instance.new("SoundGroup")
		master.Name = "Master"
		master.Parent = SoundService
	end
	g = master:FindFirstChild(name) :: any
	if not (g and g:IsA("SoundGroup")) then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = master
	end
	groups[name] = g :: SoundGroup
	return g :: SoundGroup
end

local function assetFor(name: string): string?
	local id = IDS[ASSET_ALIAS[name] or name]
	if type(id) == "number" and id > 0 then
		return "rbxassetid://" .. id
	elseif type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

function SoundKit.play(name: string)
	local asset = assetFor(name)
	if not asset then
		return
	end
	local t = templates[name]
	if not t then
		t = Instance.new("Sound")
		t.Name = name
		t.SoundId = asset
		t.SoundGroup = group(CATEGORY[name] or "Effects")
		t.Parent = SoundService
		templates[name] = t
	end
	local s = t:Clone()
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	task.delay(30, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function throttled(name: string, interval: number): boolean
	local now = os.clock()
	if now - (lastPlayed[name] or -math.huge) < interval then
		return true
	end
	lastPlayed[name] = now
	return false
end

local BUILD_SOUND = {
	City = "build-city",
	Port = "build-port",
	DefensePost = "build-defense-post",
	SAM = "sam-built",
	MissileSilo = "silo-built",
	Factory = "build-factory",
}

local function myName(): string?
	local r = ctx.roster()[ctx.myId()]
	return r and r.name
end

-- SoundEffectController + ActionableEvents / EventsDisplay / WinModal cues.
function SoundKit.onNet(kind: string, data: any)
	if not ctx then
		return
	end
	local me = ctx.myId()
	if kind == "init" then
		table.clear(knownStructures)
		table.clear(knownUnits)
	elseif kind == "phase" and type(data) == "table" then
		if lastPhase == "Spawn" and data.phase == "Play" then
			SoundKit.play("game-start")
		end
		if data.phase ~= lastPhase and (data.phase == "Spawn" or data.phase == "Lobby") then
			table.clear(knownStructures)
			table.clear(knownUnits)
		end
		if data.phase == "Ended" and lastPhase == "Play" and me ~= 0 then
			local mine = ctx.roster()[me]
			local alive = mine and mine.stats and mine.stats.alive
			if data.winnerId == me or (data.winnerTeam and mine and mine.team == data.winnerTeam) then
				SoundKit.play("victory")
			elseif alive then
				SoundKit.play("defeat") -- the dead already heard it on "defeated"
			end
		end
		lastPhase = data.phase
		local inMatch = me ~= 0 and (data.phase == "Spawn" or data.phase == "Play")
		SoundKit.setMusic(if inMatch then "music-gameplay" else "music-menu")
	elseif kind == "defeated" then
		SoundKit.play("defeat")
	elseif kind == "conquest" and type(data) == "table" then
		if data.killer == me and me ~= 0 then
			local victim = ctx.roster()[data.victim]
			SoundKit.play(if victim and victim.kind == "Human" then "conquered" else "ka-ching")
		end
	elseif kind == "nuke" and type(data) == "table" then
		SoundKit.play(if data.kind == "HydrogenBomb" then "hydrogen-launch" elseif data.kind == "MIRV" then "mirv-launch" else "atom-launch")
	elseif kind == "nukeEnd" and type(data) == "table" then
		if data.exploded and not data.silent then
			SoundKit.play(if (data.radius or 0) > 15 then "hydrogen-hit" else "atom-hit")
		end
	elseif kind == "warheadEnd" and typeof(data) == "buffer" then
		for o = 0, buffer.len(data) - 9, 9 do
			if buffer.readu8(data, o + 8) == 1 then
				if not throttled("mirv-hit", MIRV_HIT_INTERVAL) then
					SoundKit.play("atom-hit")
				end
				break
			end
		end
	elseif kind == "structures" and type(data) == "table" then
		for _, row in data do
			local id = row[1]
			if id and not knownStructures[id] then
				knownStructures[id] = true
				if row[4] == me and me ~= 0 and BUILD_SOUND[row[2]] and lastPhase == "Play" and row[5] == false then
					SoundKit.play(BUILD_SOUND[row[2]])
				end
			end
		end
	elseif kind == "units" and typeof(data) == "buffer" then
		for o = 0, buffer.len(data) - 16, 16 do
			local id = buffer.readu32(data, o)
			if not knownUnits[id] then
				knownUnits[id] = true
				if buffer.readu16(data, o + 4) == me and me ~= 0 then
					SoundKit.play("build-warship")
				end
			end
		end
	elseif kind == "boat" and type(data) == "table" then
		if data.owner == me and me ~= 0 and data.kind == "transport" then
			SoundKit.play("transport-ship")
		end
	elseif kind == "event" and type(data) == "table" then
		local text = tostring(data.text or "")
		local name = myName()
		if data.kind == "nuke" and data.owner == me and (text:find("INBOUND") or text:find("inbound")) then
			if not throttled("nuke-warning", NUKE_WARNING_INTERVAL) then
				SoundKit.play("nuke-warning")
			end
		elseif text:find(" requests an alliance") or text:find(" wants to renew your alliance") then
			SoundKit.play("alliance-suggested")
		elseif (data.kind == "ally" or data.kind == "traitor") and name and text:find(name, 1, true)
			and (text:find("ended") or text:find("betrayed") or text:find("expired")) then
			SoundKit.play("alliance-broken")
		end
	elseif kind == "stationBuilt" then
		-- TRAIN_STATION_SOUND_INTERVAL_TICKS (10)
		if lastPhase == "Play" and not throttled("build-train-station", 1) then
			SoundKit.play("build-train-station")
		end
	elseif kind == "quickChat" or kind == "emoji" then
		SoundKit.play("message")
	end
end

-- AmbienceController: the nearest City / Factory / Silo / SAM to the screen centre loops while the
-- player is zoomed in (OpenFront scale 8 to 20 px per tile, our zoom mapped to the same share of
-- the maximum zoom), fading up to -20 dB under the cues.
function SoundKit.step(zoom: number, maxZoom: number, centerTile: number?, W: number)
	if not ctx then
		return
	end
	local threshold = maxZoom * 8 / 20
	local want, gain = nil, 0
	if centerTile and zoom >= threshold and lastPhase == "Play" then
		local cx, cy = centerTile % W, centerTile // W
		local best = 5 * 5 -- AMBIENCE_RANGE_TILES 20 / LINEAR_SCALE 4
		for _, row in ctx.structures() do
			local track = AMBIENCE_BY_KIND[row[2]]
			if track and row[5] then
				local dx, dy = row[3] % W - cx, row[3] // W - cy
				local d = dx * dx + dy * dy
				if d <= best then
					best, want = d, track
				end
			end
		end
		gain = AMBIENCE_PEAK_GAIN * math.clamp((zoom - threshold) / math.max(0.001, maxZoom - threshold), 0, 1)
	end
	if want ~= ambienceName then
		if ambience then
			ambience:Destroy()
			ambience = nil
		end
		ambienceName = want
		local asset = want and assetFor(want)
		if asset then
			local s = Instance.new("Sound")
			s.Name = "Ambience"
			s.SoundId = asset
			s.Looped = true
			s.SoundGroup = group("Ambience")
			s.Parent = SoundService
			s:Play()
			ambience = s
		end
	end
	if ambience then
		ambience.Volume = gain
	end
end

-- SoundManager.playBackgroundMusic / MenuMusic: one looping track on the Music channel.
-- OpenFront's menu and gameplay tracks (used with OpenFront's permission), ids in Shared.SoundIds
-- "music-menu" loops; "music-gameplay" is a playlist (MUSIC_PLAYLISTS) played in order and then
-- from the start again. Ids in Shared.SoundIds (0 = silence).
local MUSIC_PLAYLISTS = {
	["music-gameplay"] = { "music-gameplay-1", "music-gameplay-2", "music-gameplay-3" },
}
local musicIndex = 0
local function playMusicTrack(name: string, loop: boolean)
	if music then
		music:Destroy()
		music = nil
	end
	local asset = assetFor(name)
	if not asset then
		return false
	end
	local s = Instance.new("Sound")
	s.Name = "Music"
	s.SoundId = asset
	s.Looped = loop
	s.SoundGroup = group("Music")
	s.Parent = SoundService
	s:Play()
	music = s
	return true
end

function SoundKit.setMusic(track: string?)
	if track == musicName then
		return
	end
	musicName = track
	if music then
		music:Destroy()
		music = nil
	end
	if not track then
		return
	end
	local list = MUSIC_PLAYLISTS[track]
	if not list then
		playMusicTrack(track, true)
		return
	end
	-- Playlist: next track when one ends (skipping silent / missing ones).
	musicIndex = 0
	local function nextTrack()
		for _ = 1, #list do
			musicIndex = musicIndex % #list + 1
			if musicName ~= track then
				return
			end
			if playMusicTrack(list[musicIndex], #list == 1) then
				local s = music :: Sound
				s.Ended:Connect(function()
					if music == s and musicName == track then
						nextTrack()
					end
				end)
				return
			end
		end
	end
	nextTrack()
end

function SoundKit.setup(c)
	ctx = c
end

return SoundKit
