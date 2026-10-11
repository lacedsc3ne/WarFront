-- War Front missions, season pass and weekly progress. Copyright (C) 2026 Liam (lacedsc3ne).
-- Pure rules (no services), so Progression can apply them inside its durable "round" operation and
-- tests can run them on fake profiles.
--
-- Profile fields (all optional, created on first use; old profiles simply don't have them):
--   quests  = { seed, day, daily = { { id, n, claimed } }, week, weekly = { ... } }
--   season  = { id, xp, claimed = { ["free:3"] = true, ["gold:3"] = true } }
--   weekWins = { week, wins }
--   titles  = { titleId, ... }, title = titleId?, flag = code?
--
-- Quests.day(t) / Quests.week(t)                 day / week numbers (weeks start on Monday, UTC)
-- Quests.ensure(p, day, week, seed?)              roll today's / this week's missions if needed
-- Quests.onRound(p, q)                            apply one finished battle (q from Quests.roundInfo)
-- Quests.roundInfo(r, at, friendInBattle, xp)     what a battle result contributes (stored in the op)
-- Quests.claim(p, id) -> (ok, reward | message)   mark a finished mission claimed
-- Quests.view(p, day, week) -> client table       missions with text, progress and rewards
-- Quests.seasonView(p, goldOwned) -> client table
-- Quests.claimSeason(p, level, track, goldOwned) -> (ok, reward | message)
-- Quests.claimable(p, day, week, goldOwned) -> number   finished missions + season rewards waiting

local Quests = {}

-- Missions -----------------------------------------------------------------------------------------

-- stat(q) -> how much one battle adds. q = Quests.roundInfo result.
Quests.DAILY = {
	{ id = "play2", text = "Play 2 battles", goal = 2, medals = 40, xp = 60, stat = function(q) return 1 end, icon = "Swords" },
	{ id = "win1", text = "Win a battle", goal = 1, medals = 120, xp = 150, stat = function(q) return if q.won then 1 else 0 end, icon = "Trophy" },
	{ id = "cities5", text = "Build 5 cities", goal = 5, medals = 40, xp = 60, stat = function(q) return q.cities end, icon = "Building" },
	{ id = "ports3", text = "Build 3 ports", goal = 3, medals = 40, xp = 60, stat = function(q) return q.ports end, icon = "Ship" },
	{ id = "land15", text = "Own 15% of the map in one battle", goal = 1, medals = 60, xp = 80, stat = function(q) return if q.peak >= 15 then 1 else 0 end, icon = "Flag" },
	{ id = "beat3", text = "Beat 3 players or nations", goal = 3, medals = 60, xp = 80, stat = function(q) return q.kills end, icon = "Crown" },
	{ id = "nuke1", text = "Launch a nuke", goal = 1, medals = 50, xp = 60, stat = function(q) return q.bombs end, icon = "Rocket" },
	{ id = "boats3", text = "Send 3 boats", goal = 3, medals = 40, xp = 60, stat = function(q) return q.boats end, icon = "Ship" },
	{ id = "attack20", text = "Attack 20 times", goal = 20, medals = 40, xp = 60, stat = function(q) return q.attacks end, icon = "Swords" },
	{ id = "top3", text = "Finish in the top 3", goal = 1, medals = 80, xp = 100, stat = function(q) return if q.place and q.place <= 3 then 1 else 0 end, icon = "Trophy" },
}
Quests.WEEKLY = {
	{ id = "wwin5", text = "Win 5 battles", goal = 5, medals = 150, xp = 300, stat = function(q) return if q.won then 1 else 0 end, icon = "Trophy" },
	{ id = "wnuke10", text = "Launch 10 nukes", goal = 10, medals = 150, xp = 300, stat = function(q) return q.bombs end, icon = "Rocket" },
	{ id = "wplay15", text = "Play 15 battles", goal = 15, medals = 150, xp = 300, stat = function(q) return 1 end, icon = "Swords" },
	{ id = "wcity40", text = "Build 40 cities", goal = 40, medals = 150, xp = 300, stat = function(q) return q.cities end, icon = "Building" },
	{ id = "wfriend5", text = "Play 5 battles with a friend", goal = 5, medals = 150, xp = 300, stat = function(q) return if q.friend then 1 else 0 end, icon = "Friends" },
}
Quests.DAILY_COUNT = 3
Quests.WEEKLY_COUNT = 2

local byId = {}
for _, list in { Quests.DAILY, Quests.WEEKLY } do
	for _, m in list do
		byId[m.id] = m
	end
end

function Quests.day(t: number): number
	return t // 86400
end

function Quests.week(t: number): number
	return (t // 86400 + 3) // 7 -- day 0 (1 Jan 1970) was a Thursday
end

local function roll(pool, count: number, seed: number)
	local rng = Random.new(seed)
	local ids = {}
	for _, m in pool do
		table.insert(ids, m.id)
	end
	local out = {}
	for _ = 1, math.min(count, #ids) do
		local i = rng:NextInteger(1, #ids)
		table.insert(out, { id = ids[i], n = 0, claimed = false })
		table.remove(ids, i)
	end
	return out
end

-- Deterministic for a given profile seed and day / week, so every server rolls the same set.
function Quests.ensure(p, day: number, week: number, seed: number?)
	local q = p.quests
	if type(q) ~= "table" then
		q = { seed = seed or 1 }
		p.quests = q
	end
	q.seed = tonumber(q.seed) or seed or 1
	if q.day ~= day or type(q.daily) ~= "table" then
		q.day = day
		q.daily = roll(Quests.DAILY, Quests.DAILY_COUNT, q.seed * 31 + day * 7919)
	end
	if q.week ~= week or type(q.weekly) ~= "table" then
		q.week = week
		q.weekly = roll(Quests.WEEKLY, Quests.WEEKLY_COUNT, q.seed * 17 + week * 104729)
	end
	return q
end

local function count(t: any, key: string): number
	return if type(t) == "table" then math.max(0, math.floor(tonumber(t[key]) or 0)) else 0
end

-- What one battle result contributes. Plain numbers only (it is stored inside the round operation).
function Quests.roundInfo(r: any, at: number, friendInBattle: boolean, xp: number)
	local s = if type(r.stats) == "table" then r.stats else {}
	return {
		day = Quests.day(at),
		week = Quests.week(at),
		won = r.won == true,
		place = tonumber(r.placement),
		peak = tonumber(r.peakPercent) or 0,
		kills = math.max(count(s, "kills"), math.floor(tonumber(r.eliminations) or 0)),
		bombs = count(s, "bombsLaunched"),
		boats = count(s, "boatsSent"),
		attacks = count(s, "attacksSent"),
		cities = count(s.built, "City"),
		ports = count(s.built, "Port"),
		friend = friendInBattle == true,
		seasonXp = math.max(0, math.floor(xp)),
	}
end

-- Season ------------------------------------------------------------------------------------------

Quests.SEASON = {
	id = 1,
	name = "Season 1: First strike",
	endsAt = 1796083200, -- 30 November 2026, 00:00 UTC
	xpPerLevel = 600,
	levels = 30,
}

-- Rewards: { medals = n } | { boost = key, count = n } | { title = id } | { revive = n }
-- Every level has a free reward; the gold row needs the Gold pass (MetaConfig.GAMEPASS.GoldPass).
-- id -> name, shared with the menu (ReplicatedStorage.Shared.SeasonTitles).
Quests.TITLES = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SeasonTitles")).NAMES

local FREE, GOLD = {}, {}
for level = 1, Quests.SEASON.levels do
	if level % 10 == 0 then
		FREE[level] = { title = if level == 10 then "scout" elseif level == 20 then "commander" else "general" }
	elseif level % 5 == 0 then
		FREE[level] = { boost = "reinforcements", count = 1 }
	elseif level % 3 == 0 then
		FREE[level] = { boost = "goldCrate", count = 1 }
	else
		FREE[level] = { medals = 50 + 5 * level }
	end
	if level == 1 then
		FREE[level] = { title = "recruit" }
	end
	if level == Quests.SEASON.levels then
		GOLD[level] = { title = "goldGeneral" }
	elseif level % 10 == 0 then
		GOLD[level] = { title = if level == 10 then "firstStrike" else "warlord" }
	elseif level % 4 == 0 then
		GOLD[level] = { boost = "revive", count = 1 }
	elseif level % 2 == 0 then
		GOLD[level] = { boost = "shield", count = 1 }
	else
		GOLD[level] = { medals = 100 + 10 * level }
	end
end
Quests.FREE, Quests.GOLD = FREE, GOLD

local function season(p)
	local s = p.season
	if type(s) ~= "table" or s.id ~= Quests.SEASON.id then
		s = { id = Quests.SEASON.id, xp = 0, claimed = {} }
		p.season = s
	end
	s.xp = math.max(0, math.floor(tonumber(s.xp) or 0))
	s.claimed = if type(s.claimed) == "table" then s.claimed else {}
	return s
end

function Quests.seasonLevel(p): (number, number, number)
	local s = season(p)
	local per = Quests.SEASON.xpPerLevel
	local level = math.min(Quests.SEASON.levels, s.xp // per)
	local into = if level >= Quests.SEASON.levels then per else s.xp % per
	return level, into, per
end

-- Apply one battle (inside Progression's round operation: deterministic, no services).
function Quests.onRound(p, q)
	if type(q) ~= "table" then
		return
	end
	local quests = Quests.ensure(p, q.day, q.week)
	for _, list in { quests.daily, quests.weekly } do
		for _, m in list do
			local def = byId[m.id]
			if def and not m.claimed and m.n < def.goal then
				local ok, add = pcall(def.stat, q)
				if ok and type(add) == "number" and add > 0 then
					m.n = math.min(def.goal, m.n + math.floor(add))
				end
			end
		end
	end
	local s = season(p)
	if q.day * 86400 < Quests.SEASON.endsAt then -- the battle's own date: replays give the same result
		s.xp += math.max(0, math.floor(tonumber(q.seasonXp) or 0))
	end
	local w = p.weekWins
	if type(w) ~= "table" or w.week ~= q.week then
		w = { week = q.week, wins = 0 }
		p.weekWins = w
	end
	if q.won then
		w.wins = (tonumber(w.wins) or 0) + 1
	end
end

function Quests.claim(p, id: string, day: number, week: number)
	local quests = Quests.ensure(p, day, week)
	for _, list in { quests.daily, quests.weekly } do
		for _, m in list do
			if m.id == id then
				local def = byId[id]
				if not def then
					return false, "Unknown mission"
				end
				if m.claimed then
					return false, "Already collected"
				end
				if m.n < def.goal then
					return false, "Not finished yet"
				end
				m.claimed = true
				local s = season(p)
				if os.time() < Quests.SEASON.endsAt then
					s.xp += def.xp
				end
				return true, { medals = def.medals, seasonXp = def.xp }
			end
		end
	end
	return false, "That mission isn't active any more"
end

local function missionView(list)
	local out = {}
	for _, m in list do
		local def = byId[m.id]
		if def then
			table.insert(out, { id = m.id, text = def.text, icon = def.icon, n = m.n, goal = def.goal, claimed = m.claimed == true, medals = def.medals, xp = def.xp })
		end
	end
	return out
end

function Quests.view(p, day: number, week: number, now: number)
	local q = Quests.ensure(p, day, week)
	return {
		daily = missionView(q.daily),
		weekly = missionView(q.weekly),
		dailyResetIn = (day + 1) * 86400 - now,
		weeklyResetIn = ((week + 1) * 7 - 3) * 86400 - now,
	}
end

function Quests.seasonView(p, goldOwned: boolean, now: number)
	local s = season(p)
	local level, into, per = Quests.seasonLevel(p)
	local rows = {}
	for l = 1, Quests.SEASON.levels do
		table.insert(rows, {
			level = l,
			free = FREE[l],
			gold = GOLD[l],
			freeClaimed = s.claimed["free:" .. l] == true,
			goldClaimed = s.claimed["gold:" .. l] == true,
		})
	end
	return {
		name = Quests.SEASON.name,
		endsIn = math.max(0, Quests.SEASON.endsAt - now),
		level = level,
		xpInto = into,
		xpNeed = per,
		levels = Quests.SEASON.levels,
		gold = goldOwned,
		rows = rows,
		titles = Quests.TITLES,
	}
end

function Quests.claimSeason(p, level: number, track: string, goldOwned: boolean)
	local s = season(p)
	level = math.floor(tonumber(level) or 0)
	if track ~= "free" and track ~= "gold" then
		return false, "Unknown reward"
	end
	local reward = if track == "free" then FREE[level] else GOLD[level]
	if not reward then
		return false, "Unknown reward"
	end
	if track == "gold" and not goldOwned then
		return false, "This reward needs the Gold pass"
	end
	if (Quests.seasonLevel(p)) < level then
		return false, "Reach season level " .. level .. " first"
	end
	local k = track .. ":" .. level
	if s.claimed[k] then
		return false, "Already collected"
	end
	s.claimed[k] = true
	if reward.title then
		p.titles = if type(p.titles) == "table" then p.titles else {}
		if not table.find(p.titles, reward.title) then
			table.insert(p.titles, reward.title)
		end
	end
	return true, reward
end

function Quests.claimable(p, day: number, week: number, goldOwned: boolean): number
	local n = 0
	local q = Quests.ensure(p, day, week)
	for _, list in { q.daily, q.weekly } do
		for _, m in list do
			local def = byId[m.id]
			if def and not m.claimed and m.n >= def.goal then
				n += 1
			end
		end
	end
	local s = season(p)
	local level = Quests.seasonLevel(p)
	for l = 1, level do
		if not s.claimed["free:" .. l] then
			n += 1
		end
		if goldOwned and not s.claimed["gold:" .. l] then
			n += 1
		end
	end
	return n
end

return Quests
