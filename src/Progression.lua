--[[
	War Front - player profiles, rewards, shop and purchases.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.

	Profiles live in a DataStore. If DataStores are unavailable (e.g. Studio without
	"Enable Studio Access to API Services"), profiles still work for the session but
	are not saved, and Robux purchases are refused so nobody pays without receiving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local BadgeService = game:GetService("BadgeService")
local GroupService = game:GetService("GroupService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ProfileData = require(script.Parent:WaitForChild("ProfileData"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))
local InGameLayoutCatalog = require(Shared:WaitForChild("InGameLayoutCatalog"))
local Config = require(Shared:WaitForChild("Config")) -- RANKED_START_ELO / RANKED_K
local Flags = require(Shared:WaitForChild("Flags")) -- equipFlag checks the code exists
-- Missions, season pass and weekly wins (pure rules; applied inside the durable "round" operation).
local Quests = require(script.Parent:WaitForChild("Quests"))
local Teams = require(script.Parent:WaitForChild("Teams")) -- Roblox friends cache (friend bonus)
local FRIEND_BONUS = 1.1 -- medals x1.1 for a battle played with a Roblox friend

local Progression = {}

local STORE_NAME = "Frontlines_Profiles_v1" .. (if RunService:IsStudio() then "_Studio" else "")
local store
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = if ok then result else nil
	if not ok then
		warn("[Frontlines] DataStore unavailable, profiles will not save: " .. tostring(result))
	end
end

local metaEvent = Shared:FindFirstChild("Meta") or Instance.new("RemoteEvent")
metaEvent.Name = "Meta"
metaEvent.Parent = Shared
local metaFn = Shared:FindFirstChild("MetaFn") or Instance.new("RemoteFunction")
metaFn.Name = "MetaFn"
metaFn.Parent = Shared

local profiles: { [Player]: any } = {}
local initializing: { [Player]: boolean } = {}
local loaded: { [Player]: boolean } = {} -- true only when loaded from (or confirmed new in) the DataStore
local vipCache: { [Player]: boolean } = {}
local allColorsCache: { [Player]: boolean } = {}
local perkCache: { [Player]: { [string]: boolean } } = {} -- gameplay perk passes owned (MetaConfig.PERKS)
local goldCache: { [Player]: boolean } = {} -- season Gold pass (MetaConfig.GAMEPASS.GoldPass; 0 = not on sale yet)
local groupChecked: { [Player]: boolean } = {}
local groupCache: { [Player]: boolean } = {} -- in MetaConfig.GROUP (checked on join and on request)

local function defaultProfile()
	return {
		xp = 0,
		coins = 0,
		games = 0,
		tutorialSeen = false,
		tutorialRewards = {}, -- tutorial chapters already rewarded: chapter key -> true (Progression.tutorialChapter)
		wins = 0,
		eliminations = 0,
		nukes = 0,
		bestPlacement = 0,
		ownedColors = {},
		color = nil,
		lastDaily = 0, -- day number (os.time() // 86400)
		streak = 0,
		purchases = {}, -- legacy receipts retained during migration
		receiptLedger = {}, -- durable PurchaseId -> grant; never evicted
		settings = {}, -- client settings (Settings.lua), see SETTINGS below
		elo = nil, -- ranked 1v1 rating; nil = no ranked game yet ("No ELO yet")
		rankedGames = 0,
		rankedWins = 0,
		boosts = {}, -- one-use boosts owned: key -> count (MetaConfig.BOOSTS)
		groupFeedbackPrompted = false, -- (old) rating prompt acknowledgement; no longer needed for the rewards
		favorited = false, -- the client reported a favourite (AvatarEditorService, client-only check)
		groupModalSeen = false, -- closed the group + favourite modal once (it then stays docked in the menu)
		groupMedals = false, -- the one-time group reward was given
		lastGroupBoost = 0, -- day number of the last free daily group boost
		history = {}, -- last HISTORY_MAX games, newest last (see Progression.roundEnded)
	}
end

local HISTORY_MAX = 25

-- Global leaderboards (one DataStore key per board: the top LB_SIZE entries, kept sorted).
local LB_SIZE = 100
local lbStore
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("WF_Leaderboards_v1" .. (if RunService:IsStudio() then "_Studio" else ""))
	end)
	lbStore = if ok then result else nil
end
local lbCache: { [string]: { at: number, list: { any } } } = {}

-- board "elo": v = Elo, g = ranked games, w = ranked wins; board "wins": v = wins, g = games.
local function lbUpdate(board: string, uid: number, name: string, v: number, g: number, w: number)
	if not lbStore then
		return
	end
	task.spawn(function()
		pcall(function()
			lbStore:UpdateAsync(board, function(old)
				local list = if type(old) == "table" then old else {}
				local found = false
				for _, e in list do
					if e.u == uid then
						e.n, e.v, e.g, e.w = name, v, g, w
						found = true
					end
				end
				if not found then
					list[#list + 1] = { u = uid, n = name, v = v, g = g, w = w }
				end
				table.sort(list, function(a, b)
					return a.v > b.v
				end)
				while #list > LB_SIZE do
					table.remove(list)
				end
				return list
			end)
		end)
		lbCache[board] = nil
	end)
end

local function lbRead(board: string): { any }
	local c = lbCache[board]
	if c and os.clock() - c.at < 60 then
		return c.list
	end
	local list = {}
	if lbStore then
		local ok, data = pcall(function()
			return lbStore:GetAsync(board)
		end)
		if ok and type(data) == "table" then
			list = data
		end
	end
	lbCache[board] = { at = os.clock(), list = list }
	return list
end

-- Client settings the profile may hold: true = boolean, { min, max } = number (clamped, rounded).
-- Keep in sync with Settings.DEFAULTS (StarterPlayerScripts.Settings).
local SETTINGS = {
	inGameUILayout = "layout",
	terrainShading = true,
	nameLabels = true,
	structureIcons = true,
	eventFeed = true,
	boardOpen = true,
	reducedMotion = true,
	lowDetail = true,
	borderContrast = true,
	attackingTroopsOverlay = true,
	cursorCostLabel = true,
	leaderboardColumns = "string",
	playerName = "string",
	uiScale = { 80, 130 },
	masterVolume = { 0, 100 },
	effectsVolume = { 0, 100 },
	alertsVolume = { 0, 100 },
	ambienceVolume = { 0, 100 },
	interfaceVolume = { 0, 100 },
	musicVolume = { 0, 100 },
	audioVersion = { 0, 100 },
	muted = true,
	alertFrame = true,
	leftClickMenu = true,
	anonymousNames = true,
	hiddenLobbyIds = true,
	lobbyStartAlerts = true,
	goToPlayer = true,
	attackRatio = { 1, 100 },
	attackRatioIncrement = { 1, 20 },
	nukeAllySafety = { 0, 30 },
	emojis = true,
	perfOverlay = true,
	muteOnBlur = true,
	alertsWhenUnfocused = true,
	keybinds = "longstring", -- JSON keybind overrides
}

-- Copies only known keys with valid values; numbers are clamped. Keys missing from `incoming` keep
-- their `current` value.
local function cleanSettings(incoming: { [any]: any }, current: any): { [string]: any }
	local out = {}
	for k, rule in SETTINGS do
		local v = incoming[k]
		if v == nil and typeof(current) == "table" then
			v = current[k]
		end
		if rule == true then
			if typeof(v) == "boolean" then
				out[k] = v
			end
		elseif rule == "layout" then
			out[k] = InGameLayoutCatalog.resolve(v)
		elseif rule == "string" or rule == "longstring" then
			if typeof(v) == "string" and utf8.len(v) ~= nil and #v <= (if rule == "longstring" then 2000 else 300) then
				out[k] = v
			end
		elseif typeof(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
			out[k] = math.clamp(math.floor(v + 0.5), rule[1], rule[2])
		end
	end
	return out
end

local function reconcile(data)
	local d = defaultProfile()
	if typeof(data) == "table" then
		for k, v in data do
			d[k] = v
		end
	end
	d.settings = cleanSettings(if type(d.settings) == "table" then d.settings else {}, {})
	return d
end

local function retry(fn, attempts: number)
	local lastErr
	for i = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(1.5 * i)
	end
	return false, lastErr
end

local function key(userId: number): string
	return "u_" .. userId
end

local saveLocks = {}
local handedOff = {}
local sessionTokens = {}
local copyProfile = ProfileData.copy
local push

local function applyAdminEdit(p, op: string, a: any, b: any): (boolean, string)
	local n = math.floor(tonumber(b) or tonumber(a) or 0)
	if op == "medals" then
		p.coins = math.max(0, (tonumber(p.coins) or 0) + n)
		return true, string.format("%+d medals (now %d)", n, p.coins)
	elseif op == "xp" then
		p.xp = math.max(0, (tonumber(p.xp) or 0) + n)
		return true, string.format("%+d XP (level %d)", n, MetaConfig.levelFromXP(p.xp))
	elseif op == "item" then
		local item = typeof(a) == "string" and MetaConfig.item(a)
		if not item then
			return false, "Unknown item"
		end
		if typeof(p.boosts) ~= "table" then
			p.boosts = {}
		end
		p.boosts[item.key] = math.max(0, (tonumber(p.boosts[item.key]) or 0) + n)
		return true, string.format("%+d %s (now %d)", n, item.name, p.boosts[item.key])
	elseif op == "reset" then
		local keep = p.purchases -- durable transaction records survive a reset
		local receipts, applied, sequence = p.receiptLedger, p._wfApplied, p._wfOperationSeq
		for k in p do
			p[k] = nil
		end
		for k, v in defaultProfile() do
			p[k] = v
		end
		p.purchases = keep
		p.receiptLedger, p._wfApplied, p._wfOperationSeq = receipts, applied, sequence
		return true, "Data reset"
	end
	return false, "Unknown action"
end


local function applyOperation(p, op)
 if op.kind == "round" then
  p.xp += op.xp
  p.coins += op.coins
  p.games += 1
  p.eliminations += op.eliminations
  if op.won then p.wins += 1 end
  if op.placement and (p.bestPlacement == 0 or op.placement < p.bestPlacement) then p.bestPlacement = op.placement end
  p.history = p.history or {}
  table.insert(p.history, op.history)
  while #p.history > HISTORY_MAX do table.remove(p.history, 1) end
  if type(op.quest) == "table" then Quests.onRound(p, op.quest) end -- missions, season XP, weekly wins
 elseif op.kind == "admin" then
  applyAdminEdit(p, op.op, op.a, op.b)
 elseif op.kind == "ranked" then
  p.elo = (p.elo or Config.RANKED_START_ELO) + op.change
  p.rankedGames = (p.rankedGames or 0) + 1
  if op.won then p.rankedWins = (p.rankedWins or 0) + 1 end
  local last = type(p.history) == "table" and p.history[#p.history]
  if last and last.kind == "ranked" and math.abs((last.t or 0) - op.at) < 600 then last.elo = op.change end
 end
end
local persistence = store and ProfileData.new(store, reconcile, applyOperation)
local function withProfileLock(plr, fn)
 local deadline = os.clock() + 20
 while saveLocks[plr] do
  if os.clock() >= deadline then return false, "Profile write is busy" end
  task.wait(.05)
 end
 saveLocks[plr] = true
 local ok, a, b = pcall(fn)
 saveLocks[plr] = nil
 if not ok then warn("[War Front] profile transaction: " .. tostring(a)); return false, a end
 return a, b
end
local function save(plr: Player, release: boolean?)
 return withProfileLock(plr, function()
  local profile, token = profiles[plr], sessionTokens[plr]
  if not profile or not persistence or not loaded[plr] or not token then return false end
  if release then loaded[plr] = nil end -- Freeze spending/rewards before the release snapshot.
  local ok, result = persistence.save(key(plr.UserId), token, copyProfile(profile), plr.UserId, release == true)
  if ok then
   local previousElo = profile.elo
   persistence.adopt(profile, result)
   if profile.elo ~= previousElo and profile.elo ~= nil then
    lbUpdate("elo", plr.UserId, plr.DisplayName, profile.elo, profile.rankedGames, profile.rankedWins)
   end
   if plr.Parent and not release and push then push(plr) end
   if release then loaded[plr], sessionTokens[plr] = nil, nil end
  else
   if release then loaded[plr] = true end
   if result == "Profile session ownership was lost" then
    loaded[plr] = nil
    if plr.Parent then plr:Kick("Your saved profile session ended. Please rejoin.") end
   end
   warn("[War Front] Failed to save " .. plr.Name .. ": " .. tostring(result))
  end
  return ok
 end)
end

local function ownsPass(plr: Player, passId: number): boolean
	if passId == 0 then
		return false
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(plr.UserId, passId)
	end)
	return ok and owns
end

local function awardBadge(plr: Player, badgeName: string)
	local id = MetaConfig.BADGES[badgeName]
	if not id or id == 0 then
		return
	end
	task.spawn(function()
		pcall(function()
			if not BadgeService:UserHasBadgeAsync(plr.UserId, id) then
				BadgeService:AwardBadgeAsync(plr.UserId, id)
			end
		end)
	end)
end

-- What the client is allowed to see.
local function publicProfile(plr: Player)
	local p = profiles[plr]
	if not p then
		return nil
	end
	local level, into, need = MetaConfig.levelFromXP(p.xp)
	local now = os.time()
	local seasonLevel, seasonInto, seasonNeed = Quests.seasonLevel(p)
	return {
		missionsReady = Quests.claimable(p, Quests.day(now), Quests.week(now), goldCache[plr] == true),
		seasonLevel = seasonLevel,
		seasonXpInto = seasonInto,
		seasonXpNeed = seasonNeed,
		goldPass = goldCache[plr] == true,
		goldPassId = MetaConfig.GAMEPASS.GoldPass or 0,
		title = p.title,
		titles = if type(p.titles) == "table" then p.titles else {},
		flag = p.flag,
		weekWins = if type(p.weekWins) == "table" and p.weekWins.week == Quests.week(now) then tonumber(p.weekWins.wins) or 0 else 0,
		level = level,
		xpInto = into,
		xpNeed = need,
		coins = p.coins,
		games = p.games,
		tutorialSeen = p.tutorialSeen == true,
		tutorialRewards = if type(p.tutorialRewards) == "table" then table.clone(p.tutorialRewards) else {}, -- finished tutorial chapters
		wins = p.wins,
		eliminations = p.eliminations,
		ownedColors = p.ownedColors,
		color = p.color,
		streak = p.streak,
		settings = if typeof(p.settings) == "table" then p.settings else {},
		vip = vipCache[plr] or false,
		allColors = allColorsCache[plr] or false,
		saving = loaded[plr] == true,
		elo = p.elo,
		rankedGames = p.rankedGames,
		rankedWins = p.rankedWins,
		perks = perkCache[plr] or {},
		boosts = if typeof(p.boosts) == "table" then p.boosts else {},
		inGroup = if groupChecked[plr] then groupCache[plr] == true else nil,
		groupKnown = groupChecked[plr] == true,
		groupFeedbackNeeded = false, -- Roblox can't tell us a player's rating, so the rewards no longer ask for it
		favorited = p.favorited == true,
		groupModalSeen = p.groupModalSeen == true,
		groupMedals = p.groupMedals == true,
		groupBoostToday = p.lastGroupBoost == os.time() // 86400,
	}
end

push = function(plr: Player)
	metaEvent:FireClient(plr, "profile", publicProfile(plr))
end

-- Called only when the server has opened a real tutorial match, never by a client claim.
function Progression.markTutorialStarted(plr: Player)
	plr:SetAttribute("WFTutorialStarted",true)
	local p=profiles[plr]
	if not p or not loaded[plr] then return false end
	if p.tutorialSeen~=true then
		p.tutorialSeen=true;push(plr)
		if loaded[plr] then task.spawn(save,plr) end
	end
	return true
end

-- Tutorial chapter finished (Grow / Build / Fight): a one-time medal reward per chapter. Only inside
-- a real tutorial match the server opened (WFTutorialStarted), so it can't be claimed from a lobby.
local TUTORIAL_CHAPTERS = { grow = true, build = true, fight = true }
local TUTORIAL_CHAPTER_MEDALS = 50
function Progression.tutorialChapter(plr: Player, chapter: any): (boolean, number)
	local p = profiles[plr]
	if not p or not loaded[plr] or plr:GetAttribute("WFTutorialStarted") ~= true or not TUTORIAL_CHAPTERS[chapter] then
		return false, 0
	end
	p.tutorialRewards = if type(p.tutorialRewards) == "table" then p.tutorialRewards else {}
	if p.tutorialRewards[chapter] then
		return false, 0
	end
	p.tutorialRewards[chapter] = true
	p.coins += TUTORIAL_CHAPTER_MEDALS
	push(plr)
	task.spawn(save, plr)
	return true, TUTORIAL_CHAPTER_MEDALS
end

local function addXP(plr: Player, amount: number)
	local p = profiles[plr]
	local before = MetaConfig.levelFromXP(p.xp)
	p.xp += amount
	local after = MetaConfig.levelFromXP(p.xp)
	if after > before then
		metaEvent:FireClient(plr, "levelUp", after)
		if after >= 10 then
			awardBadge(plr, "Level10")
		end
	end
end

local function claimDaily(plr: Player)
	local p = profiles[plr]
	local today = os.time() // 86400
	if p.lastDaily == today then
		return
	end
	if p.lastDaily == today - 1 then
		p.streak += 1
	else
		p.streak = 1
	end
	p.lastDaily = today
	local idx = math.min(p.streak, #MetaConfig.DAILY)
	local coins = MetaConfig.DAILY[idx]
	p.coins += coins
	metaEvent:FireClient(plr, "daily", { day = p.streak, coins = coins, table = MetaConfig.DAILY })
end

-- Group rewards (MetaConfig.GROUP). GetGroupsAsync is not cached for the session like IsInGroup,
-- so "check again" after joining works without rejoining.
local function checkGroup(plr: Player): boolean
	local ok, groups = pcall(function()
		return GroupService:GetGroupsAsync(plr.UserId)
	end)
	if not ok or type(groups) ~= "table" then
		return groupCache[plr] or false
	end
	groupChecked[plr] = true
	for _, g in groups do
		if g.Id == MetaConfig.GROUP.id then
			return true
		end
	end
	return false
end

-- Gives what a group member hasn't had yet (the one-time medals, today's free boost). Returns a
-- message for the store.
local function claimGroup(plr: Player): string
	local p = profiles[plr]
	groupCache[plr] = checkGroup(plr)
	if not p or not groupCache[plr] then
		return "Join " .. MetaConfig.GROUP.name .. " to get the group rewards."
	end
	if not loaded[plr] then
		return "Group rewards are paused: your progress can't be saved right now."
	end
	if p.favorited ~= true then
		return "Favourite the game too, then your group rewards arrive."
	end
	local got = {}
	local gift = {}
	if not p.groupMedals then
		p.groupMedals = true
		p.coins += MetaConfig.GROUP.MEDALS
		got[#got + 1] = "+" .. MetaConfig.GROUP.MEDALS .. " medals"
		gift.medals = MetaConfig.GROUP.MEDALS
	end
	local today = os.time() // 86400
	local boost = MetaConfig.boost(MetaConfig.GROUP.DAILY_BOOST)
	if boost and p.lastGroupBoost ~= today then
		p.lastGroupBoost = today
		p.boosts[boost.key] = (tonumber(p.boosts[boost.key]) or 0) + 1
		got[#got + 1] = "a free " .. boost.name
		gift.boost = boost.key
	end
	if #got > 0 then
		task.spawn(save, plr)
		metaEvent:FireClient(plr, "group", gift)
		return "Group reward: " .. table.concat(got, " and ") .. "."
	end
	return "Thanks for being in the group! Your next free boost comes tomorrow."
end

-- Player lifecycle
local function onPlayerAdded(plr: Player)
	if initializing[plr] or profiles[plr] then return end
	initializing[plr] = true
	local data
 local token = HttpService:GenerateGUID(false)
 if persistence then
  local deadline = os.clock() + 20
  repeat
   local ok, result = persistence.acquire(key(plr.UserId), token, plr.UserId)
   if ok then data = result; loaded[plr] = true; sessionTokens[plr] = token; break end
   if RunService:IsStudio() then break end -- No repeated lock waits for temporary Studio profiles.
   if os.clock() >= deadline or not plr.Parent then break end
   task.wait(1)
  until false
 end
 if not plr.Parent then
  if sessionTokens[plr] then persistence.release(key(plr.UserId), token) end
  loaded[plr], sessionTokens[plr], initializing[plr] = nil, nil, nil
  return
 end
 if not data and not RunService:IsStudio() then
  initializing[plr] = nil
  plr:Kick("Your saved progress could not be opened safely. Please rejoin shortly.")
  return
 end
	profiles[plr] = reconcile(data)
	initializing[plr] = nil
	if plr:GetAttribute("WFTutorialStarted")==true then profiles[plr].tutorialSeen=true end
	do -- missions: a per-player seed so everyone gets their own daily set
		local pr, now = profiles[plr], os.time()
		local seeded = type(pr.quests) == "table" and pr.quests.seed ~= nil
		Quests.ensure(pr, Quests.day(now), Quests.week(now), if seeded then nil else Random.new():NextInteger(1, 1000000000))
	end
	vipCache[plr] = ownsPass(plr, MetaConfig.GAMEPASS.VIP)
	goldCache[plr] = ownsPass(plr, MetaConfig.GAMEPASS.GoldPass or 0)
	allColorsCache[plr] = ownsPass(plr, MetaConfig.GAMEPASS.AllColors)
	local perks = {}
	for _, perk in MetaConfig.PERKS do
		perks[perk.key] = ownsPass(plr, perk.id)
	end
	if not plr.Parent or not profiles[plr] then return end
	perkCache[plr] = perks
	claimDaily(plr)
	claimGroup(plr)
	if not plr.Parent or not profiles[plr] then return end
	-- Badges for what the player already did (earned before the badges existed, or a missed award).
	do
		local pr = profiles[plr]
		if (tonumber(pr.games) or 0) > 0 then
			awardBadge(plr, "FirstGame")
		end
		if (tonumber(pr.wins) or 0) > 0 then
			awardBadge(plr, "FirstWin")
		end
		if (tonumber(pr.nukes) or 0) > 0 then
			awardBadge(plr, "FirstNuke")
		end
		if MetaConfig.levelFromXP(tonumber(pr.xp) or 0) >= 10 then
			awardBadge(plr, "Level10")
		end
	end
	-- Leaderboards only change when a game ends; put players whose wins / Elo predate the boards
	-- (or whose last update failed) on them once.
	local profile = profiles[plr]
	if loaded[plr] and profile.lbSynced ~= 2 then
		profile.lbSynced = 2
		if (tonumber(profile.wins) or 0) > 0 then
			lbUpdate("wins", plr.UserId, plr.DisplayName, profile.wins, profile.games, profile.wins)
		end
		if type(profile.elo) == "number" then
			lbUpdate("elo", plr.UserId, plr.DisplayName, profile.elo, profile.rankedGames, profile.rankedWins)
		end
	end
	push(plr)
end

local function onPlayerRemoving(plr: Player)
	save(plr, true)
	profiles[plr] = nil
	loaded[plr] = nil
	vipCache[plr] = nil
	allColorsCache[plr] = nil
	perkCache[plr] = nil
	goldCache[plr] = nil
	groupCache[plr] = nil
	groupChecked[plr] = nil
	handedOff[plr] = nil
	sessionTokens[plr] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, plr in Players:GetPlayers() do
	task.spawn(onPlayerAdded, plr)
end

-- Server shutting down: save everyone and wait until every save is done (Roblox allows 30 s).
game:BindToClose(function()
	local pending = 0
	for _, plr in Players:GetPlayers() do
		pending += 1
		task.spawn(function()
			pcall(save, plr, true)
			pending -= 1
		end)
	end
	local started = os.clock()
	while pending > 0 and os.clock() - started < 25 do
		task.wait(0.1)
	end
end)

task.spawn(function()
	while true do
		task.wait(120)
		for _, plr in Players:GetPlayers() do
			task.spawn(save, plr)
		end
	end
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, passId, purchased)
	if not purchased then
		return
	end
	if passId == MetaConfig.GAMEPASS.VIP then
		vipCache[plr] = true
	elseif passId == MetaConfig.GAMEPASS.AllColors then
		allColorsCache[plr] = true
	elseif passId == (MetaConfig.GAMEPASS.GoldPass or 0) and passId ~= 0 then
		goldCache[plr] = true
	end
	for _, perk in MetaConfig.PERKS do
		if passId == perk.id then
			perkCache[plr] = perkCache[plr] or {}
			perkCache[plr][perk.key] = true
		end
	end
	push(plr)
end)

-- Developer products: coins are granted and SAVED before the purchase is confirmed.
MarketplaceService.ProcessReceipt = function(receipt)
 local plr = Players:GetPlayerByUserId(receipt.PlayerId)
 if not plr then return Enum.ProductPurchaseDecision.NotProcessedYet end
 local grant
 for _, prod in MetaConfig.PRODUCTS do
  if prod.id ~= 0 and prod.id == receipt.ProductId then grant = { coins = prod.coins } end
 end
 for _, item in MetaConfig.SHOP_ITEMS do
  if item.id ~= 0 and item.id == receipt.ProductId then grant = { boost = item.key, count = 1 } end
 end
 if not grant then return Enum.ProductPurchaseDecision.NotProcessedYet end
 local newlyGranted = false
 local ok = withProfileLock(plr, function()
  local profile, token = profiles[plr], sessionTokens[plr]
  if not profile or not loaded[plr] or not token or not persistence then return false end
  local snapshot = copyProfile(profile)
  snapshot.receiptLedger = if type(snapshot.receiptLedger) == "table" then snapshot.receiptLedger else {}
  for _, id in snapshot.purchases or {} do
   snapshot.receiptLedger[id] = snapshot.receiptLedger[id] or { legacy = true }
  end
  newlyGranted = snapshot.receiptLedger[receipt.PurchaseId] == nil
  if newlyGranted then
   ProfileData.grant(snapshot, grant)
   snapshot.receiptLedger[receipt.PurchaseId] = grant
  end
  -- Staged grants are invisible to spend/use handlers until committed.
  local saved, result = persistence.save(key(plr.UserId), token, snapshot, plr.UserId, false)
  if not saved then return false end
  persistence.adopt(profile, result)
  return true
 end)
 if not ok then return Enum.ProductPurchaseDecision.NotProcessedYet end
 push(plr)
 if newlyGranted and grant.boost and Progression.onItemBought then
  task.spawn(Progression.onItemBought, plr, grant.boost)
 end
 return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Client requests
-- Spam guard for MetaFn: 8 requests a second (bursts of 16) per player; "groupCheck" (a web call)
-- at most once every 5 s.
local metaRate: { [Player]: any } = {}
Players.PlayerRemoving:Connect(function(plr)
	metaRate[plr] = nil
end)

metaFn.OnServerInvoke = function(plr: Player, action: any, arg: any)
	local p = profiles[plr]
	if not p or typeof(action) ~= "string" then
		return false, "Profile not loaded yet"
	end
	local now = os.clock()
	local rate = metaRate[plr]
	if not rate then
		rate = { tokens = 16, at = now, group = 0 }
		metaRate[plr] = rate
	end
	rate.tokens = math.min(16, rate.tokens + (now - rate.at) * 8)
	rate.at = now
	if rate.tokens < 1 then
		return false, "Slow down a little"
	end
	rate.tokens -= 1
	if action == "groupCheck" then
		if now - rate.group < 5 then
			return false, "Wait a few seconds and check again"
		end
		rate.group = now
	end
	if not loaded[plr] and action ~= "get" and action ~= "history" and action ~= "leaderboard" and action ~= "saveSettings" and action ~= "missions" and action ~= "season" then
		return false, "Your saved profile is not available right now"
	end
	if action == "get" then
		return true, publicProfile(plr)
	elseif action == "buyColor" or action == "equipColor" then
		if typeof(arg) ~= "string" then
			return false, "Bad colour"
		end
		local c = MetaConfig.color(arg)
		if not c then
			return false, "Unknown colour"
		end
		local owned = c.price == 0 or allColorsCache[plr] or table.find(p.ownedColors, c.id) ~= nil
		if c.group then
			owned = groupCache[plr] == true
			if not owned then
				return false, "Join " .. MetaConfig.GROUP.name .. " to use this colour"
			end
		end
		if action == "buyColor" and not owned then
			local level = MetaConfig.levelFromXP(p.xp)
			if level < c.level then
				return false, "Reach level " .. c.level .. " first"
			end
			if p.coins < c.price then
				return false, "Not enough medals"
			end
			p.coins -= c.price
			table.insert(p.ownedColors, c.id)
			owned = true
		end
		if not owned then
			return false, "You don't own that colour"
		end
		p.color = c.id
		push(plr)
		return true, "Colour applies from your next round"
	elseif action == "history" then
		return true, if typeof(p.history) == "table" then p.history else {}
	elseif action == "leaderboard" then
		local week = Quests.week(os.time())
		local board = if arg == "elo" then "elo" elseif arg == "week" then "week:" .. week else "wins"
		local list = lbRead(board)
		local you = { rank = nil, v = if board == "elo" then p.elo else p.wins, g = if board == "elo" then p.rankedGames else p.games, w = if board == "elo" then p.rankedWins else p.wins }
		if arg == "week" then
			local wins = if type(p.weekWins) == "table" and p.weekWins.week == week then tonumber(p.weekWins.wins) or 0 else 0
			you.v, you.w = wins, wins
			you.resetIn = ((week + 1) * 7 - 3) * 86400 - os.time()
		end
		for i, e in list do
			if e.u == plr.UserId then
				you.rank = i
			end
		end
		return true, { board = board, list = list, you = you }
	elseif action == "buyBoost" then
		local b = typeof(arg) == "string" and MetaConfig.item(arg)
		if not b then
			return false, "Unknown boost"
		end
		if p.coins < b.coins then
			return false, "Not enough medals"
		end
		if typeof(p.boosts) ~= "table" then
			p.boosts = {}
		end
		p.coins -= b.coins
		p.boosts[b.key] = (tonumber(p.boosts[b.key]) or 0) + 1
		push(plr)
		task.spawn(save, plr)
		if b.key == "revive" then
			return true, b.name .. " added. Use it from the defeat screen."
		end
		return true, b.name .. " added. Use it in a match from the boosts bar."
	elseif action == "groupCheck" then
		-- Roblox does not return the chosen rating. This is only a prompt acknowledgement.
		if arg == "feedbackPromptClosed" and loaded[plr] and checkGroup(plr) then
			p.groupFeedbackPrompted = true
			task.spawn(save, plr)
		end
		local msg = claimGroup(plr)
		push(plr)
		return true, msg
	elseif action == "groupModalSeen" then
		if p.groupModalSeen ~= true then
			p.groupModalSeen = true
			task.spawn(save, plr)
		end
		push(plr)
		return true
	elseif action == "favorited" then
		-- Only the player's client can check a favourite, so this is the client's report.
		if p.favorited ~= true then
			p.favorited = true
			task.spawn(save, plr)
		end
		local msg = claimGroup(plr)
		push(plr)
		return true, msg
	elseif action == "clearColor" then
		p.color = nil
		push(plr)
		return true, "Back to a random colour"
	elseif action == "saveSettings" then
		if typeof(arg) ~= "table" then
			return false, "Bad settings"
		end
		p.settings = cleanSettings(arg, p.settings)
		return true, "Settings saved" -- written to the DataStore with the profile (autosave / leave)
	elseif action == "missions" then
		local now = os.time()
		return true, Quests.view(p, Quests.day(now), Quests.week(now), now)
	elseif action == "claimMission" then
		if typeof(arg) ~= "string" then
			return false, "Unknown mission"
		end
		local now = os.time()
		local ok, reward = Quests.claim(p, arg, Quests.day(now), Quests.week(now))
		if not ok then
			return false, reward
		end
		p.coins += reward.medals
		push(plr)
		task.spawn(save, plr)
		return true, reward
	elseif action == "season" then
		return true, Quests.seasonView(p, goldCache[plr] == true, os.time())
	elseif action == "claimSeason" then
		if typeof(arg) ~= "table" then
			return false, "Unknown reward"
		end
		local ok, reward = Quests.claimSeason(p, arg.level, arg.track, goldCache[plr] == true)
		if not ok then
			return false, reward
		end
		if reward.medals then
			p.coins += reward.medals
		end
		if reward.boost then
			if typeof(p.boosts) ~= "table" then
				p.boosts = {}
			end
			p.boosts[reward.boost] = (tonumber(p.boosts[reward.boost]) or 0) + (reward.count or 1)
		end
		push(plr)
		task.spawn(save, plr)
		return true, reward
	elseif action == "equipTitle" then
		if arg == nil or arg == "" then
			p.title = nil
		elseif typeof(arg) == "string" and type(p.titles) == "table" and table.find(p.titles, arg) then
			p.title = arg
		else
			return false, "You don't have that title yet"
		end
		push(plr)
		return true, if p.title then "Title equipped" else "Title removed"
	elseif action == "equipFlag" then
		if arg == nil or arg == "" then
			p.flag = nil
		elseif typeof(arg) == "string" and #arg <= 40 and Flags.has(arg) then
			p.flag = arg
		else
			return false, "Unknown flag"
		end
		push(plr)
		return true, if p.flag then "Your flag shows from your next battle" else "Flag removed"
	end
	return false, "Unknown action"
end

-- API used by GameServer

-- Returns {r,g,b} if the player picked a colour, or nil for random.
function Progression.colorFor(plr: Player)
	local p = profiles[plr]
	if not p or not p.color then
		return nil
	end
	local c = MetaConfig.color(p.color)
	if not c then
		return nil
	end
	if c.group then
		if not groupCache[plr] then
			return nil -- left the group: random colour
		end
	elseif c.price > 0 and not allColorsCache[plr] and not table.find(p.ownedColors, c.id) then
		return nil
	end
	return c.rgb
end

-- Flag code the player chose (shown next to their name in battle), or nil.
function Progression.flagFor(plr: Player): string?
	local p = profiles[plr]
	return if p and typeof(p.flag) == "string" and Flags.has(p.flag) then p.flag else nil
end

-- Title id the player equipped (shown under their name in battle), or nil.
function Progression.titleFor(plr: Player): string?
	local p = profiles[plr]
	return if p and typeof(p.title) == "string" and type(p.titles) == "table" and table.find(p.titles, p.title) then p.title else nil
end

-- Weekly clan goal (Clans): claimed this week already?
function Progression.clanGoalClaimed(plr: Player, week: number): boolean
	local p = profiles[plr]
	return p ~= nil and p.clanGoalWeek == week
end

function Progression.claimClanGoal(plr: Player, week: number, medals: number): (boolean, string)
	local p = profiles[plr]
	if not p or not loaded[plr] then
		return false, "Rewards can't be saved right now."
	end
	if p.clanGoalWeek == week then
		return false, "You already collected this week's clan reward."
	end
	p.clanGoalWeek = week
	p.coins += medals
	push(plr)
	task.spawn(save, plr)
	return true, "+" .. medals .. " medals from your clan goal!"
end

function Progression.tagFor(plr: Player)
	local p = profiles[plr]
	local level = if p then MetaConfig.levelFromXP(p.xp) else 1
	return level, vipCache[plr] or false
end

-- Gameplay perk passes the player owns: { startingArmy = true, ... } (MetaConfig.PERKS keys).
function Progression.perksFor(plr: Player): { [string]: boolean }
	return perkCache[plr] or {}
end

-- Set by GameServer: called after a boost / revive bought with Robux is in the inventory.
Progression.onItemBought = nil :: ((Player, string) -> ())?

-- How many of a boost (or "revive") the player owns.
function Progression.itemCount(plr: Player, key: string): number
	local p = profiles[plr]
	return if p and typeof(p.boosts) == "table" then tonumber(p.boosts[key]) or 0 else 0
end

-- One boost of this kind, if the player has one: takes it from the inventory and returns true.
function Progression.takeBoost(plr: Player, key: string): boolean
	local p = profiles[plr]
	if not p or not loaded[plr] or typeof(p.boosts) ~= "table" or (tonumber(p.boosts[key]) or 0) <= 0 then
		return false
	end
	p.boosts[key] -= 1
	push(plr)
	if loaded[plr] then
		task.spawn(save, plr)
	end
	return true
end

-- Spend medals (profile.coins) for something bought outside metaFn (Clans). Returns true if paid.
function Progression.spendCoins(plr: Player, amount: number): boolean
	local p = profiles[plr]
	if not p or not loaded[plr] or (tonumber(p.coins) or 0) < amount then
		return false
	end
	p.coins -= amount
	push(plr)
	task.spawn(save, plr)
	return true
end

-- Give medals back (a purchase that failed after paying).
function Progression.refundCoins(plr: Player, amount: number)
	local p = profiles[plr]
	if p and loaded[plr] then
		p.coins += amount
		push(plr)
		task.spawn(save, plr)
	end
end

-- Put a boost back (it was taken but could not be used after all).
function Progression.returnBoost(plr: Player, key: string)
	local p = profiles[plr]
	if p and loaded[plr] and typeof(p.boosts) == "table" then
		p.boosts[key] = (tonumber(p.boosts[key]) or 0) + 1
		push(plr)
	end
end

function Progression.noteNuke(plr: Player)
	local p = profiles[plr]
	if p and loaded[plr] then
		p.nukes += 1
		awardBadge(plr, "FirstNuke")
	end
end

--[[
	results: { { player = Player, placement = number, won = boolean, peakPercent = number,
	             eliminations = number, seconds = number } }
]]
function Progression.roundEnded(results, info: any?)
 if not info or not info.eligible or not info.roundId or not persistence then return false end
 local allSaved = true
 local R = MetaConfig.REWARDS
 for _, r in results do
  if r.seconds < R.minSecondsForReward then continue end
  local uid = r.userId or (r.player and r.player.UserId)
  if not uid then continue end
  local plr = Players:GetPlayerByUserId(uid)
  local xp = R.playXP + r.eliminations * R.eliminationXP + math.floor(r.peakPercent * R.landXPPerPercent)
  local coins = R.playCoins + r.eliminations * R.eliminationCoins
  if r.placement and R.podiumXP[r.placement] then
   xp += R.podiumXP[r.placement]; coins += R.podiumCoins[r.placement]
  end
  if r.won then xp += R.winXP; coins += R.winCoins end
  if r.vip then xp = math.floor(xp * MetaConfig.VIP_MULT); coins = math.floor(coins * MetaConfig.VIP_MULT) end
  xp = math.floor(xp * Progression.event.xp)
  coins = math.floor(coins * Progression.event.medals)
  local friend = false -- another human in this battle is a Roblox friend
  for _, other in results do
   local ou = other.userId or (other.player and other.player.UserId)
   if ou and ou ~= uid and Teams.isFriend(uid, ou) then friend = true; break end
  end
  if friend then coins = math.floor(coins * FRIEND_BONUS + 0.5) end
  local quest = Quests.roundInfo(r, os.time(), friend, xp)
  local id = "round:" .. info.roundId
  local before = plr and profiles[plr]
  local already = before and ((before._wfApplied and before._wfApplied[id]) or (before._wfPending and before._wfPending[id]))
  local op = {kind="round", xp=xp, coins=coins, won=r.won == true, placement=r.placement, eliminations=r.eliminations,
   history={t=os.time(), map=info.mapName or info.map, mode=info.mode, kind=info.kind, players=info.players,
    place=r.placement, won=r.won == true, secs=math.floor(r.seconds), stats=r.stats, left=r.left == true}, quest=quest}
  local ok, result = persistence.operation(key(uid), id, op, uid)
  if not ok then allSaved = false; warn("[War Front] Participation save failed for " .. uid); continue end
  if plr and loaded[plr] and save(plr) then
   local p = profiles[plr]
   if p then
    if not already then
     awardBadge(plr, "FirstGame")
     if r.won then awardBadge(plr, "FirstWin") end
     local level = MetaConfig.levelFromXP(p.xp)
     if before and level > MetaConfig.levelFromXP(p.xp - xp) then metaEvent:FireClient(plr,"levelUp",level) end
     if level >= 10 then awardBadge(plr,"Level10") end
     metaEvent:FireClient(plr,"reward",{placement=r.placement,won=r.won,xp=xp,coins=coins,vip=r.vip or false,
      event=Progression.event.medals>1 or Progression.event.xp>1, friend=friend})
    end
    lbUpdate("wins",uid,plr.DisplayName,p.wins,p.games,p.wins)
    if r.won and type(p.weekWins) == "table" and p.weekWins.week == quest.week then
     lbUpdate("week:" .. quest.week,uid,plr.DisplayName,p.weekWins.wins,p.games,p.weekWins.wins)
    end
    push(plr)
   end
  elseif result._wfApplied and result._wfApplied[id] then
   lbUpdate("wins",uid,r.name or ("Player " .. uid),result.wins,result.games,result.wins)
  end
 end
 return allSaved
end

-- Matchmaking (ServerScriptService.Matchmaker / GameServer)

-- Before a teleport to another place: save now and stop this server saving the profile again,
-- so the server the player arrives on loads the latest profile and later saves aren't undone.
function Progression.handOff(plr: Player)
	if handedOff[plr] then return true end
	if not loaded[plr] or not save(plr, true) then return false end
	-- save() waited for older writes; pending saves recheck loaded after the lock.
	loaded[plr] = nil
	handedOff[plr] = true
	return true
end

function Progression.resumeHandOff(plr: Player)
 if not handedOff[plr] or not profiles[plr] or not plr.Parent or not persistence then return end
 withProfileLock(plr, function()
  local token = HttpService:GenerateGUID(false)
  local ok, data = persistence.acquire(key(plr.UserId), token, plr.UserId)
  if not ok then
   plr:Kick("Your profile is active on another server. Please rejoin.")
   return false
  end
  -- The released session was frozen; reacquire the current durable data.
  profiles[plr] = reconcile(data)
  handedOff[plr], sessionTokens[plr], loaded[plr] = nil, token, true
  push(plr)
  return true
 end)
end

function Progression.getElo(plr: Player): number?
	local p = profiles[plr]
	return if p then p.elo else nil
end

-- Elo for a finished ranked 1v1 (K = Config.RANKED_K). Works for players who already left the
-- match server: their stored profile is updated directly.
-- Admin tools (ServerScriptService.Admin)
-- Live reward multipliers for events; Admin keeps them in sync across servers.
Progression.event = { medals = 1, xp = 1 }

local function adminSummary(p, online: boolean)
	return {
		online = online,
		medals = tonumber(p.coins) or 0,
		xp = tonumber(p.xp) or 0,
		level = MetaConfig.levelFromXP(tonumber(p.xp) or 0),
		games = tonumber(p.games) or 0,
		wins = tonumber(p.wins) or 0,
		elo = p.elo,
		rankedGames = tonumber(p.rankedGames) or 0,
		boosts = if typeof(p.boosts) == "table" then p.boosts else {},
		streak = tonumber(p.streak) or 0,
		inGroup = p.groupMedals == true,
	}
end

-- Profile of any player: the live one when they're in this server, else the saved one.
function Progression.adminView(uid: number): any?
	local plr = Players:GetPlayerByUserId(uid)
	if plr and profiles[plr] then
		return adminSummary(profiles[plr], true)
	end
	if not store then
		return nil
	end
	local ok, data = pcall(function()
		return store:GetAsync(key(uid))
	end)
	if ok and type(data) == "table" then
		return adminSummary(reconcile(data), false)
	end
	return nil
end


-- Change a player's saved data: the live profile when they're in this server (Admin asks the other
-- servers first), otherwise straight in the DataStore.
function Progression.adminEdit(uid: number, op: string, a: any, b: any): (boolean, string)
 if not persistence then return false, "DataStores aren't available" end
 local plr = Players:GetPlayerByUserId(uid)
 local p = plr and profiles[plr]
 if p and not loaded[plr] then return false, "Their saved profile is unavailable" end
 local valid, message = applyAdminEdit(copyProfile(p or defaultProfile()), op, a, b)
 if not valid then return false, message end
 local ok = persistence.operation(key(uid), HttpService:GenerateGUID(false), { kind="admin", op=op, a=a, b=b }, uid)
 if not ok then return false, "Could not persist the profile edit" end
 if plr and p then
  if not save(plr) then return true, "Edit saved and queued for their active profile" end
  push(plr)
  return true, message
 end
 return true, "Edit saved; an active server will apply it on its next save"
end

function Progression.rankedResult(winnerId: number, loserId: number, matchId: string?)
 if not persistence then return end
 local function current(uid)
  local plr = Players:GetPlayerByUserId(uid)
  local p = plr and profiles[plr]
  if p and loaded[plr] then return p.elo or Config.RANKED_START_ELO end
  local ok, data = retry(function() return store:GetAsync(key(uid)) end, 3)
  if not ok then return nil end
  return if type(data) == "table" and data.elo then data.elo else Config.RANKED_START_ELO
 end
 local ra, rb = current(winnerId), current(loserId)
 if not ra or not rb then warn("[War Front] Ranked rating read failed"); return end
 local delta = math.max(1, math.floor(Config.RANKED_K * (1 - 1 / (1 + 10 ^ ((rb - ra) / 400))) + .5))
 local id = "ranked:" .. (matchId or HttpService:GenerateGUID(false))
 local function apply(uid, change, won)
  local ok, result = persistence.operation(key(uid), id, { kind="ranked", change=change, won=won, at=os.time() }, uid)
  if not ok then warn("[War Front] Could not persist ranked result for " .. uid); return end
  local plr = Players:GetPlayerByUserId(uid)
  if result._wfApplied and result._wfApplied[id] then
   local named, name = pcall(function() return Players:GetNameFromUserIdAsync(uid) end)
   lbUpdate("elo", uid, if named then name else ("Player " .. uid), result.elo, result.rankedGames, result.rankedWins)
  end
  if plr and loaded[plr] and save(plr) then
   local p = profiles[plr]
   if not p then return end
   lbUpdate("elo", uid, plr.DisplayName, p.elo, p.rankedGames, p.rankedWins)
   push(plr)
   metaEvent:FireClient(plr, "ranked", { elo=p.elo, change=change, won=won })
  end
 end
 apply(winnerId, delta, true)
 apply(loserId, -delta, false)
end

return Progression
