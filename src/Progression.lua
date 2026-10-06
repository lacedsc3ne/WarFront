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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))
local Config = require(Shared:WaitForChild("Config")) -- RANKED_START_ELO / RANKED_K

local Progression = {}

local STORE_NAME = "Frontlines_Profiles_v1"
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
local loaded: { [Player]: boolean } = {} -- true only when loaded from (or confirmed new in) the DataStore
local vipCache: { [Player]: boolean } = {}
local allColorsCache: { [Player]: boolean } = {}
local perkCache: { [Player]: { [string]: boolean } } = {} -- gameplay perk passes owned (MetaConfig.PERKS)
local groupCache: { [Player]: boolean } = {} -- in MetaConfig.GROUP (checked on join and on request)

local function defaultProfile()
	return {
		xp = 0,
		coins = 0,
		games = 0,
		wins = 0,
		eliminations = 0,
		nukes = 0,
		bestPlacement = 0,
		ownedColors = {},
		color = nil,
		lastDaily = 0, -- day number (os.time() // 86400)
		streak = 0,
		purchases = {}, -- receipt ids already granted (last 50)
		settings = {}, -- client settings (Settings.lua), see SETTINGS below
		elo = nil, -- ranked 1v1 rating; nil = no ranked game yet ("No ELO yet")
		rankedGames = 0,
		rankedWins = 0,
		boosts = {}, -- one-use boosts owned: key -> count (MetaConfig.BOOSTS)
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
		return DataStoreService:GetDataStore("WF_Leaderboards_v1")
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
		elseif rule == "string" or rule == "longstring" then
			if typeof(v) == "string" and #v <= (if rule == "longstring" then 2000 else 300) then
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

local function save(plr: Player)
	local profile = profiles[plr]
	if not profile or not store or not loaded[plr] then
		return false
	end
	local ok, err = retry(function()
		store:UpdateAsync(key(plr.UserId), function()
			return profile
		end)
	end, 3)
	if not ok then
		warn("[Frontlines] Failed to save profile for " .. plr.Name .. ": " .. tostring(err))
	end
	return ok
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
				BadgeService:AwardBadge(plr.UserId, id)
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
	return {
		level = level,
		xpInto = into,
		xpNeed = need,
		coins = p.coins,
		games = p.games,
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
		inGroup = groupCache[plr] or false,
		groupMedals = p.groupMedals == true,
		groupBoostToday = p.lastGroupBoost == os.time() // 86400,
	}
end

local function push(plr: Player)
	metaEvent:FireClient(plr, "profile", publicProfile(plr))
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
	local data
	if store then
		local ok, result = retry(function()
			return store:GetAsync(key(plr.UserId))
		end, 3)
		if ok then
			data = result
			loaded[plr] = true
		else
			warn("[Frontlines] Could not load profile for " .. plr.Name .. "; using a temporary one.")
		end
	end
	if not plr.Parent then
		return
	end
	profiles[plr] = reconcile(data)
	vipCache[plr] = ownsPass(plr, MetaConfig.GAMEPASS.VIP)
	allColorsCache[plr] = ownsPass(plr, MetaConfig.GAMEPASS.AllColors)
	local perks = {}
	for _, perk in MetaConfig.PERKS do
		perks[perk.key] = ownsPass(plr, perk.id)
	end
	perkCache[plr] = perks
	claimDaily(plr)
	claimGroup(plr)
	push(plr)
end

local function onPlayerRemoving(plr: Player)
	save(plr)
	profiles[plr] = nil
	loaded[plr] = nil
	vipCache[plr] = nil
	allColorsCache[plr] = nil
	perkCache[plr] = nil
	groupCache[plr] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, plr in Players:GetPlayers() do
	task.spawn(onPlayerAdded, plr)
end

game:BindToClose(function()
	for _, plr in Players:GetPlayers() do
		task.spawn(save, plr)
	end
	task.wait(3)
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
	local profile = plr and profiles[plr]
	if not plr or not profile or not loaded[plr] or not store then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	for _, rid in profile.purchases do
		if rid == receipt.PurchaseId then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end
	local product, boost
	for _, prod in MetaConfig.PRODUCTS do
		if prod.id ~= 0 and prod.id == receipt.ProductId then
			product = prod
		end
	end
	for _, b in MetaConfig.SHOP_ITEMS do -- boosts + extra revive
		if b.id ~= 0 and b.id == receipt.ProductId then
			boost = b
		end
	end
	if not product and not boost then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if typeof(profile.boosts) ~= "table" then
		profile.boosts = {}
	end
	if product then
		profile.coins += product.coins
	else
		profile.boosts[boost.key] = (tonumber(profile.boosts[boost.key]) or 0) + 1
	end
	table.insert(profile.purchases, receipt.PurchaseId)
	while #profile.purchases > 50 do
		table.remove(profile.purchases, 1)
	end
	if not save(plr) then
		-- Undo so the retry doesn't double-grant; Roblox will call again later.
		if product then
			profile.coins -= product.coins
		else
			profile.boosts[boost.key] -= 1
		end
		table.remove(profile.purchases)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	push(plr)
	if boost and Progression.onItemBought then
		task.spawn(Progression.onItemBought, plr, boost.key) -- GameServer: use it now if it can be
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Client requests
metaFn.OnServerInvoke = function(plr: Player, action: any, arg: any)
	local p = profiles[plr]
	if not p or typeof(action) ~= "string" then
		return false, "Profile not loaded yet"
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
		local board = if arg == "elo" then "elo" else "wins"
		local list = lbRead(board)
		local you = { rank = nil, v = if board == "elo" then p.elo else p.wins, g = if board == "elo" then p.rankedGames else p.games, w = if board == "elo" then p.rankedWins else p.wins }
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
	if not p or typeof(p.boosts) ~= "table" or (tonumber(p.boosts[key]) or 0) <= 0 then
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
	if p then
		p.coins += amount
		push(plr)
		task.spawn(save, plr)
	end
end

-- Put a boost back (it was taken but could not be used after all).
function Progression.returnBoost(plr: Player, key: string)
	local p = profiles[plr]
	if p and typeof(p.boosts) == "table" then
		p.boosts[key] = (tonumber(p.boosts[key]) or 0) + 1
		push(plr)
	end
end

function Progression.noteNuke(plr: Player)
	local p = profiles[plr]
	if p then
		p.nukes += 1
		awardBadge(plr, "FirstNuke")
	end
end

--[[
	results: { { player = Player, placement = number, won = boolean, peakPercent = number,
	             eliminations = number, seconds = number } }
]]
function Progression.roundEnded(results, info: any?)
	local R = MetaConfig.REWARDS
	info = info or {}
	for _, r in results do
		local plr = r.player
		local p = profiles[plr]
		if p and plr.Parent then
			-- Game history (OpenFront account "Games" tab): newest last, with the match stats.
			if typeof(p.history) ~= "table" then
				p.history = {}
			end
			table.insert(p.history, {
				t = os.time(),
				map = info.mapName or info.map,
				mode = info.mode,
				kind = info.kind,
				players = info.players,
				place = r.placement,
				won = r.won,
				secs = math.floor(r.seconds),
				stats = r.stats,
			})
			while #p.history > HISTORY_MAX do
				table.remove(p.history, 1)
			end
		end
		if p and plr.Parent and r.seconds >= R.minSecondsForReward then
			local xp = R.playXP + r.eliminations * R.eliminationXP + math.floor(r.peakPercent * R.landXPPerPercent)
			local coins = R.playCoins + r.eliminations * R.eliminationCoins
			if R.podiumXP[r.placement] then
				xp += R.podiumXP[r.placement]
				coins += R.podiumCoins[r.placement]
			end
			if r.won then
				xp += R.winXP
				coins += R.winCoins
				p.wins += 1
				awardBadge(plr, "FirstWin")
			end
			if vipCache[plr] then
				xp = math.floor(xp * MetaConfig.VIP_MULT)
				coins = math.floor(coins * MetaConfig.VIP_MULT)
			end
			p.games += 1
			p.eliminations += r.eliminations
			if p.bestPlacement == 0 or r.placement < p.bestPlacement then
				p.bestPlacement = r.placement
			end
			p.coins += coins
			addXP(plr, xp)
			awardBadge(plr, "FirstGame")
			if p.wins > 0 then
				lbUpdate("wins", plr.UserId, plr.DisplayName, p.wins, p.games, p.wins)
			end
			metaEvent:FireClient(plr, "reward", {
				placement = r.placement,
				won = r.won,
				xp = xp,
				coins = coins,
				vip = vipCache[plr] or false,
			})
			push(plr)
			task.spawn(save, plr)
		end
	end
end

-- Matchmaking (ServerScriptService.Matchmaker / GameServer)

-- Before a teleport to another place: save now and stop this server saving the profile again,
-- so the server the player arrives on loads the latest profile and later saves aren't undone.
function Progression.handOff(plr: Player)
	if loaded[plr] then
		save(plr)
		loaded[plr] = nil
	end
end

function Progression.getElo(plr: Player): number?
	local p = profiles[plr]
	return if p then p.elo else nil
end

-- Elo for a finished ranked 1v1 (K = Config.RANKED_K). Works for players who already left the
-- match server: their stored profile is updated directly.
function Progression.rankedResult(winnerId: number, loserId: number)
	local function current(uid: number)
		local plr = Players:GetPlayerByUserId(uid)
		local p = plr and profiles[plr]
		if p then
			return p.elo or Config.RANKED_START_ELO
		end
		if not store then
			return Config.RANKED_START_ELO
		end
		local ok, data = retry(function()
			return store:GetAsync(key(uid))
		end, 2)
		return if ok and typeof(data) == "table" and data.elo then data.elo else Config.RANKED_START_ELO
	end
	local ra, rb = current(winnerId), current(loserId)
	local expectA = 1 / (1 + 10 ^ ((rb - ra) / 400))
	local delta = math.max(1, math.floor(Config.RANKED_K * (1 - expectA) + 0.5))
	local function apply(uid: number, change: number, won: boolean)
		local plr = Players:GetPlayerByUserId(uid)
		local p = plr and profiles[plr]
		if p then
			p.elo = (p.elo or Config.RANKED_START_ELO) + change
			p.rankedGames = (p.rankedGames or 0) + 1
			if won then
				p.rankedWins = (p.rankedWins or 0) + 1
			end
			local last = if typeof(p.history) == "table" then p.history[#p.history] else nil
			if last and last.kind == "ranked" and os.time() - (last.t or 0) < 600 then
				last.elo = change
			end
			lbUpdate("elo", uid, (plr :: Player).DisplayName, p.elo, p.rankedGames, p.rankedWins)
			push(plr :: Player)
			if loaded[plr :: Player] then
				task.spawn(save, plr :: Player)
			end
			metaEvent:FireClient(plr :: Player, "ranked", { elo = p.elo, change = change, won = won })
		elseif store then
			retry(function()
				local d2
				store:UpdateAsync(key(uid), function(old)
					local d = reconcile(old)
					d.elo = (d.elo or Config.RANKED_START_ELO) + change
					d.rankedGames = (d.rankedGames or 0) + 1
					if won then
						d.rankedWins = (d.rankedWins or 0) + 1
					end
					d2 = d
					return d
				end)
				if d2 then
					local okName, name = pcall(function()
						return Players:GetNameFromUserIdAsync(uid)
					end)
					lbUpdate("elo", uid, if okName then name else ("Player " .. uid), d2.elo, d2.rankedGames, d2.rankedWins)
				end
			end, 3)
		end
	end
	apply(winnerId, delta, true)
	apply(loserId, -delta, false)
end

return Progression
