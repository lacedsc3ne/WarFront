-- War Front Night menu illustrations. Copyright (C) 2026 Liam (lacedsc3ne).
-- Full-colour art (owner's icon set, uploaded 11 Oct 2026 from WAR-FRONT-all-icons.zip; prompts in
-- Documents/WarFront/UI Updates/night-menu/ICON_PROMPTS.md). Line icons (NightMenu.Icons) stay for
-- small, tinted places; these are used where a picture helps.
--
-- Art.has(name) -> boolean
-- Art.image(name, props) -> ImageLabel   transparent, Fit; nil-safe (a missing name shows nothing)
-- Art.set(label, name)                  change (or clear) the picture on an existing label
-- Art.mission(id) / Art.title(id) / Art.rank(tierName) -> art name or nil
-- Art.preload()                          ask Roblox to fetch every image (call once when the menu opens)

local ContentProvider = game:GetService("ContentProvider")

local Art = {}

Art.IDS = {
	-- Ways to play (B)
	QuickBattle = "rbxassetid://101300202701275",
	WithFriends = "rbxassetid://132469271670765",
	Practice = "rbxassetid://93737836939419",
	EnterCode = "rbxassetid://95054094797588",
	HowToPlay = "rbxassetid://99182535646029",
	-- Home and rewards (C)
	Missions = "rbxassetid://71439224122443",
	Season = "rbxassetid://131076978310637",
	Gift = "rbxassetid://76461496463654",
	GiftBig = "rbxassetid://92779554368269",
	Medal = "rbxassetid://101905357741972",
	Bell = "rbxassetid://129341483232122",
	ClanGoal = "rbxassetid://115861049108078",
	Friends = "rbxassetid://130351445254104",
	-- Titles (D), keyed by title id (Shared.SeasonTitles)
	recruit = "rbxassetid://101751457102107",
	scout = "rbxassetid://137529583774706",
	firstStrike = "rbxassetid://122278671252425",
	commander = "rbxassetid://94108153077872",
	warlord = "rbxassetid://71201841171304",
	general = "rbxassetid://125012060627835",
	goldGeneral = "rbxassetid://132548158442056",
	-- Missions (E)
	PlayBattles = "rbxassetid://107876585281049",
	WinBattle = "rbxassetid://79811973601969",
	BuildCities = "rbxassetid://123050743416781",
	Ships = "rbxassetid://95660986462409",
	OwnLand = "rbxassetid://91866522796741",
	BeatPlayers = "rbxassetid://121489076201525",
	Nuke = "rbxassetid://119584453042259",
	PlayWithFriend = "rbxassetid://119512453887777",
	-- 1 vs 1 ranks (F): ready for the future ranked update
	Bronze = "rbxassetid://124687955343573",
	Silver = "rbxassetid://99591170981254",
	Gold = "rbxassetid://112658210630405",
	Platinum = "rbxassetid://72937035794875",
	Diamond = "rbxassetid://85203932047477",
	Champion = "rbxassetid://105209216755411",
	-- Battle screen (G build bar, keyed by structure / unit / nuke kind; H battle bar; I battle
	-- moments). Uploaded 11 Oct 2026 from WAR-FRONT-GHI-icons.zip (prompts: ICON_PROMPTS_INGAME.md).
	City = "rbxassetid://124000232214344",
	Factory = "rbxassetid://110502707343293",
	Port = "rbxassetid://74458771958473",
	DefensePost = "rbxassetid://104080607927476",
	MissileSilo = "rbxassetid://83390941469939",
	Warship = "rbxassetid://89022152573676",
	SAM = "rbxassetid://103677641662158",
	AtomBomb = "rbxassetid://81868256230251",
	HydrogenBomb = "rbxassetid://139505692475098",
	MIRV = "rbxassetid://109147280333560",
	Troops = "rbxassetid://111116277367336",
	SendTroops = "rbxassetid://88075199440461",
	Boosts = "rbxassetid://109652106796144", -- v2: purple potion (yellow bolt blended into the yellow Boosts pill)
	BattleStarting = "rbxassetid://140531872778623",
	YouWon = "rbxassetid://110820300186492",
	Defeated = "rbxassetid://85428618463855",
	FreeRevive = "rbxassetid://108533919355855",
	Watching = "rbxassetid://116731096831602",
	AllyRequest = "rbxassetid://86203965475630",
}

-- Square crop around each picture's visible content ({ x, y, size } in the 512 px source), measured
-- from the alpha channel on 11 Oct 2026, so every picture is centred and fills its box the same way.
local RECT = {
	BeatPlayers = { 42, 42, 426 },
	Bell = { 43, 44, 426 },
	Bronze = { 42, 42, 428 },
	BuildCities = { 41, 42, 428 },
	Champion = { 44, 42, 426 },
	ClanGoal = { 44, 43, 426 },
	Diamond = { 42, 42, 428 },
	EnterCode = { 42, 42, 426 },
	Friends = { 44, 43, 426 },
	Gift = { 44, 44, 424 },
	GiftBig = { 43, 42, 426 },
	Gold = { 42, 42, 428 },
	HowToPlay = { 44, 43, 426 },
	Medal = { 43, 44, 424 },
	Missions = { 42, 42, 428 },
	Nuke = { 43, 42, 428 },
	OwnLand = { 43, 42, 428 },
	Platinum = { 42, 42, 428 },
	PlayBattles = { 44, 44, 424 },
	PlayWithFriend = { 42, 43, 426 },
	Practice = { 63, 42, 436 },
	QuickBattle = { 15, 12, 480 },
	Season = { 42, 42, 426 },
	Ships = { 42, 42, 428 },
	Silver = { 42, 43, 426 },
	WinBattle = { 44, 44, 426 },
	WithFriends = { 44, 48, 424 },
	commander = { 42, 42, 428 },
	firstStrike = { 43, 42, 426 },
	general = { 42, 43, 428 },
	goldGeneral = { 41, 42, 428 },
	recruit = { 44, 44, 424 },
	scout = { 43, 42, 428 },
	warlord = { 43, 44, 426 },
	City = { 52, 51, 408 },
	Factory = { 53, 52, 409 },
	Port = { 52, 51, 410 },
	DefensePost = { 53, 52, 408 },
	MissileSilo = { 52, 52, 409 },
	Warship = { 52, 52, 408 },
	SAM = { 52, 52, 408 },
	AtomBomb = { 53, 52, 408 },
	HydrogenBomb = { 51, 53, 409 },
	MIRV = { 52, 51, 410 },
	Troops = { 52, 52, 409 },
	SendTroops = { 52, 52, 409 },
	BattleStarting = { 51, 52, 409 },
	YouWon = { 51, 51, 409 },
	Defeated = { 52, 52, 408 },
	FreeRevive = { 53, 52, 408 },
	Watching = { 52, 53, 409 },
	AllyRequest = { 52, 52, 409 },
}

-- ServerScriptService.Quests mission ids -> art.
local MISSIONS = {
	play2 = "PlayBattles",
	wplay15 = "PlayBattles",
	attack20 = "PlayBattles",
	win1 = "WinBattle",
	wwin5 = "WinBattle",
	top3 = "WinBattle",
	cities5 = "BuildCities",
	wcity40 = "BuildCities",
	ports3 = "Ships",
	boats3 = "Ships",
	land15 = "OwnLand",
	beat3 = "BeatPlayers",
	nuke1 = "Nuke",
	wnuke10 = "Nuke",
	wfriend5 = "PlayWithFriend",
}

function Art.has(name: string?): boolean
	return name ~= nil and Art.IDS[name] ~= nil
end

function Art.mission(id: string?): string?
	return id and MISSIONS[id] or nil
end

function Art.title(id: string?): string?
	return if id and Art.IDS[id] then id else nil
end

function Art.rank(tier: string?): string?
	return if tier and Art.IDS[tier] then tier else nil
end

-- Points an ImageLabel at a picture (or clears it), with its centring crop.
function Art.set(label: ImageLabel, name: string?)
	local r = name and RECT[name]
	label.Image = if name then Art.IDS[name] or "" else ""
	label.ImageRectOffset = if r then Vector2.new(r[1], r[2]) else Vector2.zero
	label.ImageRectSize = if r then Vector2.new(r[3], r[3]) else Vector2.zero
end

function Art.image(name: string?, props: { [string]: any }?): ImageLabel
	local label = Instance.new("ImageLabel")
	label.Name = "Art_" .. tostring(name)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.ScaleType = Enum.ScaleType.Fit
	label.Size = UDim2.fromOffset(40, 40)
	Art.set(label, name)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(label :: any)[k] = v
			end
		end
	end
	if parent then
		label.Parent = parent
	end
	return label
end

-- A developer product's own picture (boosts, Extra revive: the same picture as in the Shop).
-- Returns an ImageLabel right away; the picture fills in once Roblox answers (cached per product).
-- onLoaded() runs when it arrives (e.g. to hide a placeholder icon).
local productIcons: { [number]: string | false } = {}
local productWaiters: { [number]: { (string) -> () } } = {}
function Art.product(productId: number?, props: { [string]: any }?, onLoaded: (() -> ())?): ImageLabel
	local label = Art.image(nil, props)
	label.Name = "Product"
	local id = tonumber(productId)
	if not id or id == 0 then
		return label
	end
	local function apply(image: string)
		label.Image = image
		if onLoaded then
			onLoaded()
		end
	end
	local known = productIcons[id]
	if type(known) == "string" then
		apply(known)
	elseif known == nil then
		if productWaiters[id] then
			table.insert(productWaiters[id], apply)
		else
			productWaiters[id] = { apply }
			task.spawn(function()
				local ok, info = pcall(function()
					return game:GetService("MarketplaceService"):GetProductInfoAsync(id, Enum.InfoType.Product)
				end)
				local image = ok and type(info) == "table" and tonumber(info.IconImageAssetId)
				productIcons[id] = if image and image > 0 then "rbxassetid://" .. image else false
				local waiting = productWaiters[id]
				productWaiters[id] = nil
				if productIcons[id] then
					for _, f in waiting do
						f(productIcons[id] :: string)
					end
				end
			end)
		end
	end
	return label
end

local preloaded = false
function Art.preload()
	if preloaded then
		return
	end
	preloaded = true
	task.spawn(function()
		local list = {}
		for _, id in Art.IDS do
			table.insert(list, id)
		end
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

return Art
