--[[
	War Front - main menu matchmaking pages: Create Lobby, Join Lobby and 1v1 Ranked, plus the
	"joining the match" screen shown while a teleport runs.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(client/HostLobbyModal.ts, JoinLobbyModal.ts, Matchmaking.ts, components/GameConfigSettings,
	resources/lang/en.json host_modal / private_lobby / matchmaking_modal / game_settings).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.LobbyPages (ModuleScript), used by MainMenu.
-- LobbyPages.init(ctx)          ctx: net, toast(text), preview(mapId, width) -> EditableImage?,
--                                    mapPool() -> { MapCatalog info }
-- LobbyPages.handles(kind)      "host" | "join" | "ranked"
--                               | "solo" (SinglePlayerModal: the same game settings, then Start)
-- LobbyPages.render(kind, page) fills a MenuKit page (MainMenu's inline page)
-- LobbyPages.closed(kind)       the page was closed: leave the lobby / the ranked queue
-- Net: sends "lobbyCreate", "lobbyJoin", "lobbyLeave", "lobbySettings", "lobbyStart",
-- "lobbyKick", "lobbyVisibility", "lobbyList", "rankedJoin", "rankedLeave"; receives "mm" (see
-- ServerScriptService.Matchmaker). Lobbies are Public (listed on Join Lobby) or Private (ID or a
-- Roblox invite, which carries the ID as launch data). ctx.open(kind) opens a menu page.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local GuiService = game:GetService("GuiService")

local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local QueueBar = require(script.Parent:WaitForChild("QueueBar"))
local CustomLobbyBar = require(script.Parent:WaitForChild("CustomLobbyBar"))
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make

local LobbyPages = {}

local ctx: any = nil
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- State from the server ------------------------------------------------------------------
local lobby: any = nil -- last "mm" lobby view (code, host, isHost, settings, members, state)
-- Public lobby we wait in (mm "public"): { type, lobby = { map, name, sub, mods, count, max, secs,
-- started }, members = { { userId, name } }, at = os.clock() when it arrived }.
local public: any = nil
local ranked = { state = "idle", queueSize = nil :: number?, elo = nil :: number? }
-- shown.night: a Night menu page (NightMenu.Pages host / join / solo) shows this kind and wants
-- shown.night() after every change (shown.page stays nil then, so the old renderers stay idle).
local shown: { page: any?, kind: string?, night: (() -> ())? } = { page = nil, kind = nil, night = nil }
local pendingSettings: any = nil -- host edits not yet echoed
local sendAt = 0 -- when to send pendingSettings (0 = sent)
local editedAt = 0 -- last host edit (echoes older than this are ignored for a moment)
local refreshers: { () -> () } = {}
-- Public lobbies on the Join Lobby page (mm "lobbyList"): { code, hostName, count, max, map,
-- randomMap, mode, teams }. listAskedAt throttles the requests.
local lobbyList: { any }? = nil
local listAskedAt = 0
local listView: { frame: Frame?, sig: string } = { frame = nil, sig = "" }
local visibilityWanted: string? = nil -- host's Public / Private click, until the server echoes it
-- Create Lobby is two pages: setup (pick the settings and who can join, then CREATE LOBBY) and the
-- lobby itself (ID, players, invites, START GAME). The host can go back to the settings from the
-- lobby (hostView = "settings") and return to it.
local host = {
	draft = nil :: any, -- settings picked before the lobby exists (kept while the menu is open)
	visibility = "public",
	view = "room" :: string, -- "room" | "settings" (an open lobby)
	creating = false, -- CREATE LOBBY pressed, waiting for the server
}
local spinners: { GuiObject } = {}
-- Single-player page settings (SinglePlayerModal DEFAULT_OPTIONS; kept while the menu is open).
local SOLO_DEFAULTS = {
	map = "World", randomMap = false, difficulty = "Easy", mode = "FFA", teams = 2, bots = 400,
	nations = true, instantBuild = false, randomSpawn = false, donateGold = false, donateTroops = false,
	infiniteGold = false, infiniteTroops = false, maxTimer = 0, compact = false, noAlliances = false,
	waterNukes = false, overtime = false, doomsday = "off", goldMultiplier = 1, startingGold = 0,
	allianceMinutes = 0, immunitySeconds = 5, disabledUnits = {},
}
local solo = { settings = table.clone(SOLO_DEFAULTS) }
-- Units the host can switch off (GameConfigSettings "Enabled units"), in UnitDisplay order.
local UNIT_TOGGLES = {
	{ "City", "City" }, { "Factory", "Factory" }, { "Port", "Port" }, { "DefensePost", "Defense Post" },
	{ "MissileSilo", "Missile Silo" }, { "SAM", "SAM Launcher" }, { "Warship", "Warship" },
	{ "AtomBomb", "Atom Bomb" }, { "HydrogenBomb", "Hydrogen Bomb" }, { "MIRV", "MIRV" },
}

local DIFFICULTIES = { "Easy", "Medium", "Hard", "Impossible" }
local TEAM_CHOICES = {
	{ 2, "2 teams" }, { 3, "3 teams" }, { 4, "4 teams" }, { 5, "5 teams" }, { 6, "6 teams" }, { 7, "7 teams" },
	{ "Duos", "Duos (teams of 2)" }, { "Trios", "Trios (teams of 3)" }, { "Quads", "Quads (teams of 4)" },
	{ "Humans Vs Nations", "Humans vs Nations" },
}

local function text(props)
	return MenuKit.text(props)
end

-- Create Lobby before the lobby exists: settings are edited locally (host.draft).
local function setupMode(): boolean
	return shown.kind == "host" and not (lobby and lobby.state == "open")
end

local function settings(): any
	if shown.kind == "solo" then
		return solo.settings
	end
	if setupMode() then
		return host.draft or {}
	end
	return pendingSettings or (lobby and lobby.settings) or {}
end

local function isHost(): boolean
	return shown.kind == "solo" or setupMode() or (lobby ~= nil and lobby.isHost == true)
end

local function mapName(id: string?): string
	for _, m in ctx.mapPool() do
		if m.id == id then
			return m.name
		end
	end
	return id or "?"
end

-- Small UI pieces
-- Loading spinner (BaseModal renderLoadingSpinner): a ring with a coloured quarter, spinning.
local function spinner(parent: Instance, order: number, color: Color3, label: string): TextLabel
	local box = make("Frame", { Name = "Spinner", LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 96), Parent = parent })
	local ring = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(48, 48),
		BackgroundTransparency = 1,
		Parent = box,
	})
	MenuKit.round(ring)
	local st = MenuKit.stroke(ring, 0, color, 4)
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.25, 0),
			NumberSequenceKeypoint.new(0.26, 0.85),
			NumberSequenceKeypoint.new(1, 0.85),
		}),
		Parent = st,
	})
	spinners[#spinners + 1] = st:FindFirstChildWhichIsA("UIGradient") :: any
	return text({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 60),
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 16,
		TextTransparency = 0.2,
		Text = label,
		Parent = box,
	})
end

-- A selectable option card (GameConfigSettings map / difficulty / mode cards): bg-white/5,
-- border white/10, the selected one malibu-blue bordered and tinted.
local function optionCard(parent: Instance, order: number, label: string, w: number, h: number): (TextButton, (boolean, boolean?) -> ())
	local b = make("TextButton", {
		Name = "Option",
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.WHITE,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(w, h),
		Parent = parent,
	})
	MenuKit.corner(b, 12)
	local st = MenuKit.stroke(b, 0.9)
	local t = text({
		Name = "Label",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -12, 0, 20),
		FontFace = F.BOLD,
		TextSize = 14,
		Text = label,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = b,
	})
	local on, off = false, false
	local function paint()
		b.BackgroundColor3 = if on then C.MALIBU else C.WHITE
		b.BackgroundTransparency = if on then 0.75 else 0.95
		st.Color = if on then C.MALIBU else C.WHITE
		st.Transparency = if on then 0 else 0.9
		t.TextTransparency = if off then 0.6 else 0
	end
	MenuKit.hover(b, function(s)
		if not on then
			b.BackgroundTransparency = if s == "idle" then 0.95 else 0.9
		end
	end)
	paint()
	return b, function(selected: boolean, disabled: boolean?)
		on, off = selected, disabled == true
		paint()
	end
end

local function grid(parent: Instance, order: number, cellW: number, cellH: number): Frame
	local f = make("Frame", { Name = "Grid", LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	make("UIGridLayout", { CellSize = UDim2.fromOffset(cellW, cellH), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	return f
end

local function sectionTitle(parent: Instance, order: number, title: string)
	MenuKit.heading(parent, order, nil, title)
end

-- Settings (GameConfigSettings subset)
local function pushSettings(change: { [string]: any })
	if not isHost() then
		return
	end
	if shown.kind == "solo" or setupMode() then
		local t = if shown.kind == "solo" then solo.settings else host.draft
		for k, v in change do
			t[k] = v
		end
		for _, f in refreshers do
			f()
		end
		if shown.night then
			shown.night()
		end
		return
	end
	local s = table.clone(settings())
	for k, v in change do
		s[k] = v
	end
	pendingSettings = s
	sendAt = os.clock() + 0.25
	editedAt = os.clock()
	for _, f in refreshers do
		f()
	end
	if shown.night then
		shown.night()
	end
end

local function buildSettings(body: Instance, base: number, editable: boolean)
	-- Map
	sectionTitle(body, base + 1, "Map")
	local maps = grid(body, base + 2, 132, 96)
	local pool = ctx.mapPool()
	for i, m in pool do
		local b, set = optionCard(maps, i, m.name, 132, 96)
		local img = make("ImageLabel", {
			Name = "Preview",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.new(1, -16, 1, -36),
			ScaleType = Enum.ScaleType.Fit,
			Parent = b,
		})
		local shownImg = false
		refreshers[#refreshers + 1] = function()
			local s = settings()
			set(not s.randomMap and s.map == m.id)
			if not shownImg then
				local e = ctx.preview(m.id, 120)
				if e then
					shownImg = pcall(function()
						img.ImageContent = Content.fromObject(e)
					end)
				end
			end
		end
		b.Active = editable
		b.Activated:Connect(function()
			if editable then
				pushSettings({ map = m.id, randomMap = false })
			end
		end)
	end
	do
		local b, set = optionCard(maps, #pool + 1, "Random", 132, 96)
		text({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Size = UDim2.fromOffset(48, 44), FontFace = F.BOLD, TextSize = 36, TextTransparency = 0.3, Text = "?", Parent = b })
		refreshers[#refreshers + 1] = function()
			set(settings().randomMap == true)
		end
		b.Activated:Connect(function()
			if editable then
				pushSettings({ randomMap = true })
			end
		end)
	end

	-- Nation difficulty
	sectionTitle(body, base + 3, "Nation difficulty")
	local diffs = grid(body, base + 4, 132, 44)
	for i, d in DIFFICULTIES do
		local b, set = optionCard(diffs, i, d, 132, 44)
		b:FindFirstChild("Label").AnchorPoint = Vector2.new(0.5, 0.5);
		(b:FindFirstChild("Label") :: TextLabel).Position = UDim2.fromScale(0.5, 0.5)
		refreshers[#refreshers + 1] = function()
			local s = settings()
			set(s.difficulty == d, s.nations == false)
		end
		b.Activated:Connect(function()
			if editable then
				pushSettings({ difficulty = d })
			end
		end)
	end

	-- Mode
	sectionTitle(body, base + 5, "Mode")
	local modes = grid(body, base + 6, 200, 44)
	for i, m in { { "FFA", "Free for All" }, { "Team", "Teams" } } do
		local b, set = optionCard(modes, i, m[2], 200, 44)
		b:FindFirstChild("Label").AnchorPoint = Vector2.new(0.5, 0.5);
		(b:FindFirstChild("Label") :: TextLabel).Position = UDim2.fromScale(0.5, 0.5)
		refreshers[#refreshers + 1] = function()
			set(settings().mode == m[1])
		end
		b.Activated:Connect(function()
			if editable then
				-- OpenFront: switching to Teams turns both donations on.
				if m[1] == "Team" and settings().mode ~= "Team" then
					pushSettings({ mode = "Team", donateGold = true, donateTroops = true })
				else
					pushSettings({ mode = m[1] })
				end
			end
		end)
	end
	local teamsTitle = MenuKit.heading(body, base + 7, nil, "Number of Teams")
	local teams = grid(body, base + 8, 160, 44)
	for i, t in TEAM_CHOICES do
		local b, set = optionCard(teams, i, t[2], 160, 44)
		b:FindFirstChild("Label").AnchorPoint = Vector2.new(0.5, 0.5);
		(b:FindFirstChild("Label") :: TextLabel).Position = UDim2.fromScale(0.5, 0.5)
		refreshers[#refreshers + 1] = function()
			set(settings().teams == t[1])
		end
		b.Activated:Connect(function()
			if editable then
				pushSettings({ teams = t[1] })
			end
		end)
	end
	refreshers[#refreshers + 1] = function()
		local on = settings().mode == "Team"
		teamsTitle.Visible = on
		teams.Visible = on
	end

	-- Options
	sectionTitle(body, base + 9, "Options")
	local order = base + 10
	if editable then
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, order, "Tribes", nil, 0, 400, 10, function()
			return settings().bots or 400
		end, function(v)
			pushSettings({ bots = v })
		end, function(v)
			return if v <= 0 then "Disabled" else tostring(v)
		end)
		order += 1
		refreshers[#refreshers + 1] = MenuKit.sliderRow(body, order, "Game length (minutes)", nil, 0, 120, 5, function()
			return settings().maxTimer or 0
		end, function(v)
			pushSettings({ maxTimer = v })
		end, function(v)
			return if v <= 0 then "Off" else tostring(v)
		end)
		order += 1
		for _, opt in {
			{ "nations", "Nations" },
			{ "instantBuild", "Instant build" },
			{ "randomSpawn", "Random spawn" },
			{ "donateGold", "Donate gold" },
			{ "donateTroops", "Donate troops" },
			{ "infiniteGold", "Infinite gold" },
			{ "infiniteTroops", "Infinite troops" },
		} do
			local key = opt[1]
			refreshers[#refreshers + 1] = MenuKit.toggleRow(body, order, opt[2], nil, function()
				local v = settings()[key]
				if key == "nations" then
					return v ~= false
				end
				return v == true
			end, function(v)
				pushSettings({ [key] = v })
			end)
			order += 1
		end
		-- GameConfigSettings extras: modifiers, economy, alliances, spawn immunity.
		for _, opt in {
			{ "compact", "Compact map", "A smaller version of the map with fewer nations and tribes." },
			{ "noAlliances", "Disable alliances", nil },
			{ "waterNukes", "Water nukes", "Nukes turn land into water instead of leaving fallout." },
			{ "overtime", "Overtime", "After 30 minutes the share of land needed to win keeps dropping." },
		} do
			local key = opt[1]
			refreshers[#refreshers + 1] = MenuKit.toggleRow(body, order, opt[2], opt[3], function()
				return settings()[key] == true
			end, function(v)
				pushSettings({ [key] = v })
			end)
			order += 1
		end
		for _, sel in {
			{ "doomsday", "Doomsday Clock", "Hold enough land as the clock ticks or be wiped out.", { { "off", "Off" }, { "slow", "Slow" }, { "normal", "Normal" }, { "fast", "Fast" }, { "veryfast", "Very fast" } }, "off" },
			{ "goldMultiplier", "Gold multiplier", nil, { { 1, "Off" }, { 1.5, "x1.5" }, { 2, "x2" }, { 3, "x3" }, { 5, "x5" } }, 1 },
			{ "startingGold", "Starting gold", nil, { { 0, "Off" }, { 1000000, "1M" }, { 5000000, "5M" }, { 25000000, "25M" } }, 0 },
			{ "allianceMinutes", "Alliance duration", "How long an alliance lasts before it must be renewed.", { { 0, "5 min" }, { 2, "2 min" }, { 3, "3 min" }, { 10, "10 min" }, { 15, "15 min" }, { 30, "30 min" } }, 0 },
			{ "immunitySeconds", "Spawn immunity", "No attacks between players for this long after the spawn phase.", { { 5, "5 s" }, { 30, "30 s" }, { 60, "1 min" }, { 120, "2 min" }, { 300, "5 min" } }, 5 },
		} do
			local key, default = sel[1], sel[5]
			refreshers[#refreshers + 1] = MenuKit.selectRow(body, order, sel[2], sel[3], sel[4], function()
				local v = settings()[key]
				return if v == nil then default else v
			end, function(v)
				pushSettings({ [key] = v })
			end)
			order += 1
		end
		sectionTitle(body, order, "Enabled units")
		order += 1
		for _, u in UNIT_TOGGLES do
			local kind = u[1]
			refreshers[#refreshers + 1] = MenuKit.toggleRow(body, order, u[2], nil, function()
				local list = settings().disabledUnits
				return not (type(list) == "table" and table.find(list, kind) ~= nil)
			end, function(on)
				local list = table.clone(settings().disabledUnits or {})
				local i = table.find(list, kind)
				if on and i then
					table.remove(list, i)
				elseif not on and not i then
					list[#list + 1] = kind
				end
				pushSettings({ disabledUnits = list })
			end)
			order += 1
		end
	else
		-- Players who joined see the host's choices.
		local card = MenuKit.card(body, order, 16, 12, 6)
		local summary = MenuKit.paragraph(card, 1, "", { TextSize = 14, TextTransparency = 0.2 })
		refreshers[#refreshers + 1] = function()
			local s = settings()
			local on = {}
			for _, opt in {
				{ "instantBuild", "Instant build" }, { "randomSpawn", "Random spawn" }, { "donateGold", "Donate gold" },
				{ "donateTroops", "Donate troops" }, { "infiniteGold", "Infinite gold" }, { "infiniteTroops", "Infinite troops" },
			} do
				if s[opt[1]] then
					on[#on + 1] = opt[2]
				end
			end
			for _, opt in { { "compact", "Compact map" }, { "noAlliances", "Alliances disabled" }, { "waterNukes", "Water nukes" }, { "overtime", "Overtime" } } do
				if s[opt[1]] then
					on[#on + 1] = opt[2]
				end
			end
			if type(s.doomsday) == "string" and s.doomsday ~= "off" then
				on[#on + 1] = "Doomsday Clock (" .. s.doomsday .. ")"
			end
			if (tonumber(s.goldMultiplier) or 1) > 1 then
				on[#on + 1] = "x" .. s.goldMultiplier .. " gold"
			end
			if (tonumber(s.startingGold) or 0) > 0 then
				on[#on + 1] = string.format("%gM starting gold", s.startingGold / 1e6)
			end
			if (tonumber(s.allianceMinutes) or 0) > 0 then
				on[#on + 1] = s.allianceMinutes .. " min alliances"
			end
			if type(s.disabledUnits) == "table" and #s.disabledUnits > 0 then
				on[#on + 1] = "Disabled: " .. table.concat(s.disabledUnits, ", ")
			end
			local bots = s.bots or 400
			summary.Text = string.format(
				"Tribes: %s   Nations: %s   Game length: %s%s",
				if bots <= 0 then "Disabled" else tostring(bots),
				if s.nations == false then "Disabled" else "On",
				if (s.maxTimer or 0) > 0 then s.maxTimer .. " min" else "Off",
				if #on > 0 then "\n" .. table.concat(on, " · ") else ""
			)
		end
	end
	return order
end

-- Players list (HostLobbyModal lobby-player-view)
local function buildPlayers(body: Instance, order: number)
	local title = MenuKit.heading(body, order, "People", "Players")
	local list = make("Frame", { Name = "Players", LayoutOrder = order + 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
	make("UIGridLayout", { CellSize = UDim2.fromOffset(220, 40), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	local sig = ""
	refreshers[#refreshers + 1] = function()
		local members = if lobby then lobby.members or {} else {}
		local s = tostring(isHost())
		for _, m in members do
			s ..= ":" .. tostring(m.userId)
		end
		if s == sig then
			return
		end
		sig = s
		local label = title:FindFirstChildWhichIsA("TextLabel", true)
		if label then
			label.Text = string.upper(#members .. (if #members == 1 then " Player" else " Players"))
		end
		for _, c in list:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for i, m in members do
			local row = make("Frame", { LayoutOrder = i, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Parent = list })
			MenuKit.corner(row, 8)
			MenuKit.stroke(row, 0.9)
			text({
				Position = UDim2.fromOffset(12, 0),
				Size = UDim2.new(1, -(if m.host then 70 else 48), 1, 0),
				TextSize = 14,
				FontFace = F.MEDIUM,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = tostring(m.name),
				Parent = row,
			})
			if m.host then
				local badge = text({
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -8, 0.5, 0),
					Size = UDim2.fromOffset(48, 20),
					BackgroundTransparency = 0,
					BackgroundColor3 = C.MALIBU,
					FontFace = F.BOLD,
					TextSize = 11,
					Text = "HOST", -- host_modal.host_badge
					Parent = row,
				})
				MenuKit.corner(badge, 4)
			elseif isHost() then
				local kick = make("TextButton", {
					Name = "Remove",
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -6, 0.5, 0),
					Size = UDim2.fromOffset(28, 28),
					AutoButtonColor = false,
					BackgroundColor3 = C.RED600,
					BackgroundTransparency = 0.8,
					FontFace = F.BOLD,
					TextSize = 14,
					TextColor3 = C.RED300,
					Text = "",
					Parent = row,
				})
				MenuKit.corner(kick, 6)
				MenuKit.icon("X", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 16), ImageColor3 = C.RED300, Parent = kick })
				local uid = m.userId
				kick.Activated:Connect(function()
					ctx.net:FireServer("lobbyKick", uid) -- host_modal.remove_player
				end)
			end
		end
	end
end

-- Pages
local function resetPage(page)
	page:setTabs({})
	page:clear()
	table.clear(refreshers)
	table.clear(spinners)
end

local function lobbyIdCard(body: Instance, order: number)
	local card = MenuKit.card(body, order, 16, 14, 4)
	MenuKit.paragraph(card, 1, "Lobby ID", { TextSize = 13, TextTransparency = 0.5, FontFace = F.BOLD })
	local code = text({ LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 40), TextXAlignment = Enum.TextXAlignment.Left, FontFace = Font.new(F.MONO.Family, Enum.FontWeight.Bold), TextSize = 32, Text = "", Parent = card })
	MenuKit.paragraph(card, 3, "Share this ID: friends enter it on JOIN LOBBY. Or invite them below.", { TextSize = 13, TextTransparency = 0.5 })
	-- OpenFront "Hidden Lobby IDs": the ID shows as dots until clicked (handy when streaming).
	local revealed = false
	local reveal = make("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = code })
	local function show()
		local id = if lobby and lobby.code then lobby.code else "......"
		code.Text = if require(script.Parent:WaitForChild("Settings")).values.hiddenLobbyIds and not revealed then "••••••  (click to show)" else id
	end
	reveal.Activated:Connect(function()
		revealed = not revealed
		show()
	end)
	refreshers[#refreshers + 1] = show
end

-- Roblox game invite carrying the lobby ID (Matchmaker sends invited players straight to it).
local function inviteFriends()
	local code = lobby and lobby.code
	if not code then
		return
	end
	local ok, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(localPlayer)
	end)
	if not ok or not can then
		ctx.toast("Invites aren't available on this account. Share the lobby ID instead.")
		return
	end
	local options = Instance.new("ExperienceInviteOptions")
	options.PromptMessage = "Join my War Front lobby!"
	options.LaunchData = code
	pcall(function()
		SocialService:PromptGameInvite(localPlayer, options)
	end)
end

local function customSettingsLines()
 local s=settings()
 local lines={}
 local function bullet(title,value) table.insert(lines,title..": "..tostring(value)) end
 local function on(value) return if value then "On" else "Off" end
 bullet("Visibility",if (visibilityWanted or lobby.visibility)=="public" then "Public" else "Private")
 bullet("Game mode",if s.mode=="Team" then "Teams" else "Free for All")
 if s.mode=="Team" then
  local value=tostring(s.teams or 2)
  for _,choice in TEAM_CHOICES do if choice[1]==s.teams then value=choice[2];break end end
  bullet("Team format",value)
 end
 bullet("Nations",if s.nations~=false then s.difficulty or "Easy" else "Off")
 bullet("Tribes",s.bots or 400)
 for _,option in {
  {"randomMap","Random map"},{"randomSpawn","Random spawn"},{"instantBuild","Instant build"},
  {"infiniteTroops","Infinite troops"},{"infiniteGold","Infinite gold"},{"compact","Compact map"},
  {"donateGold","Donate gold"},{"donateTroops","Donate troops"},{"waterNukes","Water nukes"},{"overtime","Overtime"},
 } do bullet(option[2],on(s[option[1]]==true)) end
 bullet("Alliances",on(s.noAlliances~=true))
 bullet("Alliance duration",tostring(if (s.allianceMinutes or 0)==0 then 5 else s.allianceMinutes).." min")
 bullet("Spawn immunity",tostring(s.immunitySeconds or 5).." s")
 bullet("Gold multiplier","x"..tostring(s.goldMultiplier or 1))
 bullet("Starting gold",tostring(s.startingGold or 0))
 bullet("Doomsday Clock",s.doomsday or "off")
 if (s.maxTimer or 0)>0 then bullet("Game length",tostring(s.maxTimer).." min") end
 for _,unit in UNIT_TOGGLES do bullet(unit[2],on(not table.find(s.disabledUnits or {},unit[1]))) end
 return lines
end
local function showCustomLobby()
 if not lobby then return end
 CustomLobbyBar.show(lobby,if settings().randomMap then "RANDOM MAP" else string.upper(mapName(settings().map)),customSettingsLines())
end

-- Who can join: Public (listed on everyone's Join Lobby page) or Private (lobby ID or invite only).
local function visibilityCard(body: Instance, order: number)
	local card = MenuKit.card(body, order, 16, 14, 10)
	MenuKit.paragraph(card, 1, "Who can join", { FontFace = F.BOLD, TextSize = 16 })
	local row = grid(card, 2, 160, 44)
	local hint = MenuKit.paragraph(card, 3, "", { TextSize = 13, TextTransparency = 0.5 })
	local setters = {}
	for i, v in { { "public", "Public" }, { "private", "Private" } } do
		local b, set = optionCard(row, i, v[2], 160, 44)
		b.Name = "Visibility" .. v[2]
		local label = b:FindFirstChild("Label") :: TextLabel
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		setters[v[1]] = set
		b.Activated:Connect(function()
			if setupMode() then
				host.visibility = v[1]
			elseif not isHost() or not lobby then
				return
			else
				visibilityWanted = v[1]
				ctx.net:FireServer("lobbyVisibility", v[1])
			end
			for _, f in refreshers do
				f()
			end
		end)
	end
	if not setupMode() then
		local invite = MenuKit.button("secondary", { Name = "InviteFriends", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 44), FontFace = F.BOLD, Text = "INVITE FRIENDS", Parent = card })
		invite.Activated:Connect(inviteFriends)
	end
	refreshers[#refreshers + 1] = function()
		local current = if setupMode() then host.visibility else ((lobby and lobby.visibility) or "private")
		if visibilityWanted == current then
			visibilityWanted = nil
		end
		local v = visibilityWanted or current
		for key, set in setters do
			set(key == v, not isHost())
		end
		hint.Text = if v == "public"
			then "Public: anyone can find this lobby on the Join Lobby page."
			else "Private: only people with the lobby ID or an invite can join."
	end
end

local LOBBY_DEFAULTS = table.clone(SOLO_DEFAULTS)
LOBBY_DEFAULTS.map = "Europe"

local function buildHostSettings(page,base,isSolo)
 local body=page.body
 return require(script.Parent:WaitForChild("HostLobbyView")).build(body,base,{
  page=page,solo=isSolo==true,get=settings,set=pushSettings,refreshers=refreshers,pool=ctx.mapPool,preview=ctx.preview,
  teams=TEAM_CHOICES,units=UNIT_TOGGLES,
  getVisibility=function()
   local current=if setupMode() then host.visibility else ((lobby and lobby.visibility) or "private")
   if visibilityWanted==current then visibilityWanted=nil end
   return visibilityWanted or current
  end,
  setVisibility=function(value)
   if setupMode() then host.visibility=value
   elseif isHost() and lobby then visibilityWanted=value;ctx.net:FireServer("lobbyVisibility",value)
   else return end
   for _,f in refreshers do f() end
  end,
 })
end

local renderLobby

-- Create Lobby, step 1: the game settings and who can join, then CREATE LOBBY.
local function renderHostSetup(page)
	resetPage(page)
	local body = page.body
	if host.creating then
		local status=MenuKit.paragraph(body,1,"Creating lobby…",{TextSize=18,FontFace=F.BOLD,TextColor3=C.MALIBU})
		status.Name="CreatingStatus";status.TextXAlignment=Enum.TextXAlignment.Center
		return
	end
	if not host.draft then
		host.draft = table.clone(LOBBY_DEFAULTS)
		host.draft.disabledUnits = {}
	end
	local order = buildHostSettings(page, 0)
	local create = MenuKit.button("primary", { Name = "CreateLobby", LayoutOrder = order + 1, Size = UDim2.new(1, 0, 0, 52), FontFace = F.BOLD, Text = "CREATE LOBBY", Parent = body })
	create.Activated:Connect(function()
		if host.creating then
			return
		end
		host.creating = true
		ctx.net:FireServer("lobbyCreate", { settings = host.draft, visibility = host.visibility })
		renderHostSetup(page)
		task.delay(12, function()
			-- No answer (the server refused or failed): back to the settings.
			if host.creating and not lobby and shown.kind == "host" and shown.page == page then
				host.creating = false
				renderHostSetup(page)
			end
		end)
	end)
	for _, f in refreshers do
		f()
	end
end

-- The host editing an open lobby's settings (changes reach the players as they're made).
local function renderLobbySettings(page)
 CustomLobbyBar.setEditing(true)
	resetPage(page)
	local body = page.body
	local back = MenuKit.button("secondary", { Name = "BackToLobby", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 44), FontFace = F.BOLD, Text = "BACK TO LOBBY", Parent = body })
	back.Activated:Connect(function()
		host.view = "room"
		renderLobby(page, true)
	end)
	local order = buildHostSettings(page, 10)
	local done = MenuKit.button("primary", { Name = "Done", LayoutOrder = order + 1, Size = UDim2.new(1, 0, 0, 52), FontFace = F.BOLD, Text = "BACK TO LOBBY", Parent = body })
	done.Activated:Connect(function()
		host.view = "room"
		renderLobby(page, true)
	end)
	for _, f in refreshers do
		f()
	end
end

-- Create Lobby, step 2 (and Join Lobby once in): ID, players, who can join, the settings, START.
renderLobby = function(page, hosting: boolean)
	if hosting and not (lobby and lobby.state == "open") then
		renderHostSetup(page)
		return
	end
	if hosting and lobby and lobby.isHost and host.view == "settings" then
		renderLobbySettings(page)
		return
	end
	showCustomLobby()
 CustomLobbyBar.setEditing(false)
 if ctx.close then ctx.close() end
end

-- Single player (SinglePlayerModal): the game settings, then START GAME.
local function renderSolo(page)
	resetPage(page)
	local body = page.body
	local order = buildHostSettings(page, 0, true)
	local row = make("Frame", { LayoutOrder = order + 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), Parent = body })
	local reset = MenuKit.button("gray", { Size = UDim2.new(0, 140, 1, 0), FontFace = F.BOLD, Text = "RESET", Parent = row })
	reset.Activated:Connect(function()
		solo.settings = table.clone(SOLO_DEFAULTS)
		solo.settings.disabledUnits = {}
		renderSolo(page)
	end)
	local start = MenuKit.button("primary", { Name = "StartGame", Position = UDim2.fromOffset(150, 0), Size = UDim2.new(1, -150, 1, 0), FontFace = F.BOLD, Text = "START GAME", Parent = row })
	start.Activated:Connect(function()
		start.Text = "STARTING…" -- game_settings.starting
		ctx.net:FireServer("play", "solo", solo.settings)
		task.delay(4, function()
			if start.Parent then
				start.Text = "START GAME"
			end
		end)
	end)
	for _, f in refreshers do
		f()
	end
end

local function renderJoin(page)
	resetPage(page)
	local body = page.body
	if lobby and lobby.state == "open" then
		renderLobby(page, false)
		return
	end
	local card = MenuKit.card(body, 1, 16, 16, 12)
	MenuKit.paragraph(card, 1, "Enter Lobby ID", { FontFace = F.BOLD, TextSize = 16 }) -- private_lobby.enter_id
	local box = make("TextBox", {
		Name = "LobbyId",
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = C.BLACK,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		PlaceholderText = "ABC123",
		PlaceholderColor3 = C.GRAY400,
		Text = "",
		TextColor3 = C.WHITE,
		FontFace = Font.new(F.MONO.Family, Enum.FontWeight.Bold),
		TextSize = 24,
		Parent = card,
	})
	MenuKit.corner(box, 8)
	MenuKit.stroke(box, 0.85)
	local status = MenuKit.paragraph(card, 4, "", { TextSize = 14, TextColor3 = C.RED400 })
	local join = MenuKit.button("primary", { Name = "Join", LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 48), FontFace = F.BOLD, Text = "JOIN LOBBY", Parent = card })
	local function go()
		local code = string.upper((string.gsub(box.Text, "[^%w]", "")))
		if #code ~= 6 then
			status.Text = "Lobby not found. Please check the ID and try again."
			return
		end
		status.Text = ""
		join.Text = "JOINING…"
		ctx.net:FireServer("lobbyJoin", code)
	end
	join.Activated:Connect(go)
	box.FocusLost:Connect(function(enter)
		if enter then
			go()
		end
	end)
	shown.joinStatus = status
	shown.joinButton = join

	-- Public lobbies (hosts that chose Public), newest first.
	local head = make("Frame", { LayoutOrder = 5, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = body })
	MenuKit.heading(head, 1, "People", "Public Lobbies").Size = UDim2.new(1, -120, 1, 0)
	local refresh = MenuKit.button("secondary", { Name = "Refresh", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(110, 32), FontFace = F.BOLD, TextSize = 13, Text = "REFRESH", Parent = head })
	refresh.Activated:Connect(function()
		LobbyPages.askList(true)
	end)
	local list = make("Frame", { Name = "PublicLobbies", LayoutOrder = 6, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
	make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	listView.frame, listView.sig = list, ""
	LobbyPages.drawList()
	LobbyPages.askList(true)
end

local function modeLabel(e): string
	if e.mode ~= "Team" then
		return "Free for All"
	end
	return if type(e.teams) == "number" then e.teams .. " teams" else tostring(e.teams)
end

-- Fills the Join Lobby page's public list from lobbyList.
function LobbyPages.drawList()
	local list = listView.frame
	if not list or not list.Parent then
		return
	end
	local sig = if lobbyList == nil then "loading" else ""
	for _, e in lobbyList or {} do
		sig ..= string.format("%s:%s:%s:%s:%s:%s;", tostring(e.code), tostring(e.count), tostring(e.map), tostring(e.randomMap), tostring(e.mode), tostring(e.teams))
	end
	if sig == listView.sig then
		return
	end
	listView.sig = sig
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	if lobbyList == nil then
		MenuKit.paragraph(list, 1, "Loading lobbies...", { TextSize = 14, TextTransparency = 0.5 })
		return
	end
	if #lobbyList == 0 then
		MenuKit.paragraph(list, 1, "No public lobbies right now. Make one with CREATE LOBBY, or ask a friend for their lobby ID.", { TextSize = 14, TextTransparency = 0.5 })
		return
	end
	for i, e in lobbyList do
		local row = make("Frame", { Name = "Lobby", LayoutOrder = i, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 60), Parent = list })
		MenuKit.corner(row, 10)
		MenuKit.stroke(row, 0.9)
		text({
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -130, 0, 22),
			FontFace = F.BOLD,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = tostring(e.hostName) .. "'s lobby",
			Parent = row,
		})
		text({
			Position = UDim2.fromOffset(14, 32),
			Size = UDim2.new(1, -130, 0, 18),
			TextSize = 13,
			TextTransparency = 0.45,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = string.format("%s  ·  %s  ·  %d/%d players", if e.randomMap then "Random map" else mapName(e.map), modeLabel(e), tonumber(e.count) or 0, tonumber(e.max) or 0),
			Parent = row,
		})
		local full = (tonumber(e.count) or 0) >= (tonumber(e.max) or 0)
		local join = MenuKit.button(if full then "secondary" else "primary", { Name = "Join", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(100, 40), FontFace = F.BOLD, TextSize = 14, Text = if full then "FULL" else "JOIN", Parent = row })
		local code = e.code
		join.Activated:Connect(function()
			if full then
				return
			end
			join.Text = "JOINING…"
			ctx.net:FireServer("lobbyJoin", code)
		end)
	end
end

-- Asks the server for the public lobbies (at most every 2 s; force = the player asked).
function LobbyPages.askList(force: boolean?)
	local now = os.clock()
	if now - listAskedAt < (if force then 2 else 6) then
		return
	end
	listAskedAt = now
	ctx.net:FireServer("lobbyList")
end

local function renderRanked(page)
	resetPage(page)
	local body = page.body
	local elo = MenuKit.paragraph(body, 1, "", { TextSize = 16, TextTransparency = 0.4 })
	elo.TextXAlignment = Enum.TextXAlignment.Center
	local label = spinner(body, 2, C.EMERALD500, "Searching for game...")
	local queue = MenuKit.paragraph(body, 3, "", { TextSize = 14, TextTransparency = 0.4 })
	queue.TextXAlignment = Enum.TextXAlignment.Center
	MenuKit.paragraph(body, 4, "1v1 on a random map with tribes and no nations. Win to raise your ELO; the game ends after " .. 15 .. " minutes and the bigger nation wins.", { TextSize = 13, TextTransparency = 0.5 })
	refreshers[#refreshers + 1] = function()
		elo.Text = if ranked.elo then "Your ELO: " .. math.floor(ranked.elo) else "No ELO yet" -- matchmaking_modal.elo / no_elo
		if ranked.state == "found" then
			label.Text = "Waiting for game to start..." -- matchmaking_modal.waiting_for_game
		elseif ranked.state == "searching" then
			label.Text = "Searching for game..."
		else
			label.Text = "Connecting to matchmaking server..."
		end
		queue.Text = if ranked.queueSize then "Players in queue: " .. ranked.queueSize else ""
	end
	for _, f in refreshers do
		f()
	end
end

-- "Joining the match" screen
local overlay: any = nil
-- Night look: a centred card with the battle picture, a running bar and a tip.
local NIGHT_TIPS = {
	"Build cities to grow a bigger army.",
	"Ports send trade ships that earn you gold.",
	"Allies can't attack you. Breaking an alliance makes you a traitor!",
	"Send boats to attack across the sea.",
	"Shields shoot down incoming nukes.",
}
local function nightOverlay()
	local NightMenu = script.Parent:WaitForChild("NightMenu")
	local Kit = require(NightMenu:WaitForChild("Kit"))
	local Art = require(NightMenu:WaitForChild("Art"))
	local K, F = Kit.C, Kit.F
	local gui = Kit.make("ScreenGui", { Name = "FrontlinesTeleport", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 200, Enabled = false, Parent = playerGui })
	local dim = Kit.make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = K.BACKDROP, BackgroundTransparency = 0.15, BorderSizePixel = 0, Active = true, Parent = gui })
	local card = Kit.card({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(380, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = K.PAGE, Parent = dim })
	card:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 16)
	Kit.pad(card, 24, 24, 22, 22)
	Kit.list(card, false, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local pic = Art.image("BattleStarting", { Size = UDim2.fromOffset(84, 84), LayoutOrder = 1, Parent = card })
	local title = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 26, LayoutOrder = 2, Parent = card })
	Kit.text({ Text = "Getting everyone onto the map", FontFace = F.BOLD, TextSize = 15, TextColor3 = K.MUTED, LayoutOrder = 3, Parent = card })
	local track = Kit.make("Frame", { BackgroundColor3 = K.DEEP, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 8), ClipsDescendants = true, LayoutOrder = 4, Parent = card })
	Kit.corner(track)
	local run = Kit.make("Frame", { BackgroundColor3 = K.YELLOW, BorderSizePixel = 0, Size = UDim2.fromScale(0.35, 1), Parent = track })
	Kit.corner(run)
	local tip = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 14, TextColor3 = K.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = card })
	local scale = Instance.new("UIScale")
	scale.Parent = card
	local TweenService = game:GetService("TweenService")
	gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if gui.Enabled then
			tip.Text = "Tip: " .. NIGHT_TIPS[math.random(1, #NIGHT_TIPS)]
			scale.Scale = math.clamp(math.min(gui.AbsoluteSize.X / 520, gui.AbsoluteSize.Y / 420), 0.7, 1.2)
		end
	end)
	task.spawn(function()
		while gui.Parent do
			if gui.Enabled then
				run.Position = UDim2.fromScale(-0.35, 0)
				TweenService:Create(run, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Position = UDim2.fromScale(1, 0) }):Play()
				TweenService:Create(pic, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true), { Rotation = 6 }):Play()
			end
			task.wait(1.15)
		end
	end)
	return { gui = gui, text = title, shownAt = 0, night = true }
end

local function showOverlay(label: string?)
	if not overlay and LobbyPages.nightMode then
		overlay = nightOverlay()
	end
	if not overlay then
		local gui = make("ScreenGui", { Name = "FrontlinesTeleport", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 200, Enabled = false, Parent = playerGui })
		local dim = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.BLACK, BackgroundTransparency = 0.25, BorderSizePixel = 0, Active = true, Parent = gui })
		local holder = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(360, 110), BackgroundTransparency = 1, Parent = dim })
		MenuKit.list(holder, false, 0, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		local t = spinner(holder, 1, C.CYBER, "")
		overlay = { gui = gui, text = t, shownAt = 0 }
	end
	overlay.text.Text = label or "Starting..."
	if overlay.night then
		local t = string.gsub(label or "Starting...", "%.%.%.$", "")
		overlay.text.Text = if t == "Starting" then "Starting your battle" elseif t == "Returning to the lobby" then "Back to the menu" else t
	end
	overlay.gui.Enabled = true
	overlay.shownAt = os.clock()
end

local function hideOverlay()
	if overlay then
		overlay.gui.Enabled = false
	end
end

function LobbyPages.handles(kind: string): boolean
	return kind == "host" or kind == "join" or kind == "ranked" or kind == "solo"
end

LobbyPages.TITLES = { host = "Create Lobby", join = "Join Lobby", ranked = "1v1 Ranked Matchmaking", solo = "Solo" }

function LobbyPages.render(kind: string, page)
	shown.page, shown.kind = page, kind
	page.title.Text = string.upper(LobbyPages.TITLES[kind])
	local coins = page.header:FindFirstChild("StoreCoins") -- (the store's coin count, MenuPages)
	if coins then
		coins.Visible = false
	end
	if kind == "host" then
		if not lobby or lobby.state ~= "open" then
			pendingSettings = nil
		end
		host.view = if CustomLobbyBar.active() and lobby and lobby.isHost then "settings" else "room"
		renderLobby(page, true)
	elseif kind == "join" then
		renderJoin(page)
	elseif kind == "ranked" then
		ranked.state = "connecting"
		ctx.net:FireServer("rankedJoin")
		renderRanked(page)
	elseif kind == "solo" then
		renderSolo(page)
	end
end

-- Joins a premade game without opening a page; QueueBar stays on the main menu.
function LobbyPages.joinPublic(lobbyType: string, view: any?)
	if not public or public.type ~= lobbyType then
		public = { type = lobbyType, lobby = view, members = {}, at = os.clock() }
	end
	QueueBar.show(public.lobby, true)
	ctx.net:FireServer("play", lobbyType)
end

function LobbyPages.queued(lobbyType: string?): boolean
	return (public ~= nil and (lobbyType == nil or public.type == lobbyType)) or (lobbyType==nil and CustomLobbyBar.active())
end

function LobbyPages.queueHeight(): number
	return math.max(QueueBar.height(),CustomLobbyBar.height())
end

function LobbyPages.leavePublic()
	if public then
		ctx.net:FireServer("leave")
		public = nil
	end
	QueueBar.clear()
end

function LobbyPages.leaveCustom()
 if lobby then ctx.net:FireServer("lobbyLeave") end
 lobby=nil;pendingSettings=nil;visibilityWanted=nil
 host.view,host.creating="room",false
 CustomLobbyBar.clear()
 if shown.page and (shown.kind=="host" or shown.kind=="join") and ctx.close then ctx.close() end
 if shown.night then shown.night() end
end

function LobbyPages.closed(kind: string?)
	if kind == "host" or kind == "join" then
		-- Closing the page (Esc, B, back) keeps you in your party; only Leave leaves it.
		if CustomLobbyBar.active() then
			CustomLobbyBar.setEditing(false)
		end
		host.view, host.creating = "room", false
	elseif kind == "ranked" then
		ctx.net:FireServer("rankedLeave")
		ranked.state = "idle"
	end
	shown.page, shown.kind, shown.night = nil, nil, nil
	table.clear(refreshers)
end

local function onMM(data: any)
	if type(data) ~= "table" then
		return
	end
	if data.kind == "notice" then
		hideOverlay()
		if QueueBar.teleporting() then
			LobbyPages.leavePublic()
		end
		ctx.toast(tostring(data.text))
  if CustomLobbyBar.active() then CustomLobbyBar.retry() end
		if host.creating and not lobby then
			host.creating = false -- CREATE LOBBY was refused (too soon / error): back to the settings
			if shown.kind == "host" and shown.page then
				renderHostSetup(shown.page)
			end
		end
	elseif data.kind == "studioMatch" then
		-- Studio: the match is played in this server (no teleport).
  lobby=nil;pendingSettings=nil;CustomLobbyBar.clear()
		hideOverlay()
		public = nil
		QueueBar.clear()
		if ctx.studioMatch then
			ctx.studioMatch(data.tutorial == true)
		end
	elseif data.kind == "studioLobby" then
  lobby=nil;pendingSettings=nil;CustomLobbyBar.clear()
		hideOverlay()
		public = nil
		QueueBar.clear()
		if ctx.studioLobby then
			ctx.studioLobby()
		end
	elseif data.kind == "teleport" then
		if LobbyPages.nightMode then
			showOverlay(data.text) -- the Night menu has no queue / lobby bars
		elseif public then
			QueueBar.teleport()
  elseif CustomLobbyBar.active() then
   CustomLobbyBar.teleport()
		else
			showOverlay(data.text)
		end
		if require(script.Parent:WaitForChild("Settings")).values.lobbyStartAlerts then
			pcall(function()
				require(script.Parent:WaitForChild("SoundKit")).play("game-start") -- OpenFront lobby start alert
			end)
		end
	elseif data.kind == "public" then
		if data.type == nil then
			public = nil
			QueueBar.clear()
		elseif public == nil or public.type == data.type then
			public = { type = data.type, lobby = data.lobby, members = data.members or {}, at = os.clock() }
			QueueBar.show(public.lobby)
		end
	elseif data.kind == "lobbyList" then
		lobbyList = if type(data.lobbies) == "table" then data.lobbies else {}
		LobbyPages.drawList()
	elseif data.kind == "invite" then
		-- Arrived from a friend's lobby invite: open Join Lobby and join that lobby.
		if type(data.code) == "string" and not lobby and ctx.open then
			ctx.open("join")
			ctx.toast("Joining your friend's lobby...")
			ctx.net:FireServer("lobbyJoin", data.code)
		end
	elseif data.kind == "ranked" then
		ranked.state = data.state or ranked.state
		ranked.queueSize = data.queueSize
		ranked.elo = data.elo
		if shown.kind == "ranked" then
			for _, f in refreshers do
				f()
			end
		end
	elseif data.kind == "lobby" then
		if data.state == "error" then
			if shown.kind == "join" and shown.joinStatus then
				shown.joinStatus.Text = tostring(data.reason)
				shown.joinButton.Text = "JOIN LOBBY"
				listView.sig = "" -- redraw the list's JOIN buttons
				LobbyPages.drawList()
			else
				ctx.toast(tostring(data.reason))
			end
			return
		end
		if data.state == "closed" or data.state == "left" then
			local wasIn = lobby ~= nil
   CustomLobbyBar.clear()
			lobby = nil
			pendingSettings = nil
			if wasIn and data.reason then
				ctx.toast(tostring(data.reason))
			end
			if shown.kind == "join" and shown.page then
				renderJoin(shown.page)
			elseif shown.kind == "host" and ctx.close then
				ctx.close()
			end
			return
		end
		local first = lobby == nil or lobby.code ~= data.code or lobby.isHost ~= data.isHost
		lobby = data
  public=nil;QueueBar.clear()
		host.creating = false
		if pendingSettings and sendAt == 0 and os.clock() > editedAt + 1.5 then
			pendingSettings = nil -- the server has our edit by now
		end
		showCustomLobby()
		if first and LobbyPages.nightMode and shown.night and (shown.kind == "host" or shown.kind == "join") and ctx.close then
			ctx.close() -- Night menu: no room screen, Home shows the party (code, Start, Leave)
		end
  if shown.page and (shown.kind=="host" or shown.kind=="join") then
   if shown.kind=="host" and lobby.isHost and host.view=="settings" then
    if first then renderLobbySettings(shown.page)
    else for _,f in refreshers do f() end end
   elseif ctx.close then ctx.close() end
  end
	end
end

-- Night menu interface (NightMenu.Pages host / join / solo and NightMenu.Home) ------------------
-- LobbyPages.nightMode = true      set by MainMenu when the Night menu is on (teleports show the overlay)
-- LobbyPages.attach(kind, onChange) a Night page now shows kind ("host" | "join" | "solo");
--                                  MainMenu's closePage still calls LobbyPages.closed(kind)
-- LobbyPages.night.*               read state and act exactly like the old pages
LobbyPages.nightMode = false
local nightListeners: { () -> () } = {}

function LobbyPages.attach(kind: string, onChange: () -> ())
	shown.page, shown.kind, shown.night = nil, kind, onChange
	table.clear(refreshers)
	if kind == "host" then
		if not lobby or lobby.state ~= "open" then
			pendingSettings = nil
		end
		host.view = "room"
		if not host.draft then
			host.draft = table.clone(LOBBY_DEFAULTS)
			host.draft.disabledUnits = {}
		end
	elseif kind == "join" then
		LobbyPages.askList(true)
	end
end

-- Home listens too (the battle room card): fn() after every server update.
function LobbyPages.onNightChange(fn: () -> ())
	table.insert(nightListeners, fn)
end

local function nightNotify()
	if shown.night then
		shown.night()
	end
	for _, fn in nightListeners do
		task.spawn(fn)
	end
end

LobbyPages.night = {
	TEAMS = TEAM_CHOICES,
	UNITS = UNIT_TOGGLES,
	DIFFICULTIES = DIFFICULTIES,
	settings = function()
		return settings()
	end,
	isHost = function()
		return isHost()
	end,
	setupMode = function()
		return setupMode()
	end,
	push = function(change)
		pushSettings(change)
	end,
	lobby = function()
		return if lobby and lobby.state == "open" then lobby else nil
	end,
	creating = function()
		return host.creating
	end,
	visibility = function()
		local current = if setupMode() then host.visibility else ((lobby and lobby.visibility) or "private")
		if visibilityWanted == current then
			visibilityWanted = nil
		end
		return visibilityWanted or current
	end,
	setVisibility = function(value: string)
		if setupMode() then
			host.visibility = value
		elseif isHost() and lobby then
			visibilityWanted = value
			ctx.net:FireServer("lobbyVisibility", value)
		else
			return
		end
		nightNotify()
	end,
	-- Create the battle from the draft settings (CREATE LOBBY).
	create = function()
		if host.creating or not host.draft then
			return
		end
		host.creating = true
		LobbyPages.leavePublic() -- making a party leaves the public queue (opening pages doesn't)
		ctx.net:FireServer("lobbyCreate", { settings = host.draft, visibility = host.visibility })
		nightNotify()
		task.delay(12, function()
			if host.creating and not lobby then
				host.creating = false -- no answer: back to the settings
				nightNotify()
			end
		end)
	end,
	start = function()
		if lobby and lobby.isHost then
			ctx.net:FireServer("lobbyStart")
		end
	end,
	leave = function()
		LobbyPages.leaveCustom()
	end,
	invite = function()
		inviteFriends()
	end,
	kick = function(userId: number)
		if lobby and lobby.isHost then
			ctx.net:FireServer("lobbyKick", userId)
		end
	end,
	join = function(code: string)
		LobbyPages.leavePublic()
		ctx.net:FireServer("lobbyJoin", code)
	end,
	askList = function(force: boolean?)
		LobbyPages.askList(force)
	end,
	list = function()
		return lobbyList
	end,
	soloStart = function()
		LobbyPages.leavePublic()
		ctx.net:FireServer("play", "solo", solo.settings)
	end,
	soloReset = function()
		solo.settings = table.clone(SOLO_DEFAULTS)
		solo.settings.disabledUnits = {}
		nightNotify()
	end,
	mapName = function(id: string?)
		return mapName(id)
	end,
}

function LobbyPages.init(c)
	ctx = c
	QueueBar.setup({ parent = ctx.queueParent, preview = ctx.preview, leave = LobbyPages.leavePublic, changed = ctx.queueChanged, toast = ctx.toast })
 CustomLobbyBar.setup({
  parent=ctx.queueParent,changed=ctx.queueChanged,
  leave=LobbyPages.leaveCustom,invite=inviteFriends,
  start=function() if lobby and lobby.isHost then ctx.net:FireServer("lobbyStart") end end,
  edit=function() if lobby and lobby.isHost and ctx.open then ctx.open("host") end end,
 })
	ctx.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "mm" then
			onMM(data)
			nightNotify()
		end
	end)
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		for _, g in spinners do
			if g.Parent then
				(g :: any).Rotation = ((g :: any).Rotation + dt * 360) % 360
			end
		end
		if overlay and overlay.gui.Enabled then
			local g = overlay.gui:FindFirstChildWhichIsA("UIGradient", true)
			if g then
				g.Rotation = (g.Rotation + dt * 360) % 360
			end
			if os.clock() - overlay.shownAt > 30 then
				hideOverlay() -- the teleport didn't happen
				ctx.toast("Couldn't join the match. Please try again.")
			end
		end
		-- Host edits: send the latest settings once the slider / clicks settle.
		if pendingSettings and sendAt > 0 and os.clock() >= sendAt then
			sendAt = 0
			ctx.net:FireServer("lobbySettings", pendingSettings)
		end
		acc += dt
		if acc >= 0.5 then
			acc = 0
			-- Map previews arrive asynchronously.
			if shown.kind == "host" or shown.kind == "join" or shown.kind == "solo" then
				for _, f in refreshers do
					f()
				end
			end
			if shown.kind == "join" and not lobby and listView.frame and listView.frame.Parent then
				LobbyPages.askList(false)
			end
		end
	end)
end

function LobbyPages.showOverlay(label: string?)
	showOverlay(label)
end

return LobbyPages
