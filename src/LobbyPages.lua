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
-- LobbyPages.handles(kind)      "host" | "join" | "ranked" | "public" (waiting in a public lobby)
--                               | "solo" (SinglePlayerModal: the same game settings, then Start)
-- LobbyPages.render(kind, page) fills a MenuKit page (MainMenu's inline page)
-- LobbyPages.closed(kind)       the page was closed: leave the lobby / the ranked queue
-- Net: sends "lobbyCreate", "lobbyJoin", "lobbyLeave", "lobbySettings", "lobbyStart",
-- "lobbyKick", "rankedJoin", "rankedLeave"; receives "mm" (see ServerScriptService.Matchmaker).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
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
local shown: { page: any?, kind: string? } = { page = nil, kind = nil }
local pendingSettings: any = nil -- host edits not yet echoed
local sendAt = 0 -- when to send pendingSettings (0 = sent)
local editedAt = 0 -- last host edit (echoes older than this are ignored for a moment)
local refreshers: { () -> () } = {}
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

local function settings(): any
	if shown.kind == "solo" then
		return solo.settings
	end
	return pendingSettings or (lobby and lobby.settings) or {}
end

local function isHost(): boolean
	return shown.kind == "solo" or (lobby ~= nil and lobby.isHost == true)
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
	if shown.kind == "solo" then
		for k, v in change do
			solo.settings[k] = v
		end
		for _, f in refreshers do
			f()
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
	MenuKit.paragraph(card, 3, "Friends join with JOIN LOBBY on the main menu and this ID.", { TextSize = 13, TextTransparency = 0.5 })
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

local function renderLobby(page, hosting: boolean)
	resetPage(page)
	local body = page.body
	if not lobby or lobby.state ~= "open" then
		spinner(body, 1, C.MALIBU, if hosting then "Creating lobby..." else "Joining lobby...")
		return
	end
	lobbyIdCard(body, 1)
	if not isHost() then
		MenuKit.paragraph(body, 2, "Lobby joined! Waiting for host to start...", { FontFace = F.BOLD, TextSize = 16 }) -- private_lobby.joined_waiting
	end
	buildPlayers(body, 3)
	local order = buildSettings(body, 10, isHost())
	if isHost() then
		local start = MenuKit.button("primary", { Name = "StartGame", LayoutOrder = order + 1, Size = UDim2.new(1, 0, 0, 52), FontFace = F.BOLD, Text = "START GAME", Parent = body })
		start.Activated:Connect(function()
			start.Text = "STARTING…" -- game_settings.starting
			ctx.net:FireServer("lobbyStart")
		end)
	end
	for _, f in refreshers do
		f()
	end
end

-- Single player (SinglePlayerModal): the game settings, then START GAME.
local function renderSolo(page)
	resetPage(page)
	local body = page.body
	local order = buildSettings(body, 10, true)
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

-- "Waiting for Game Start..." (JoinLobbyModal, public lobby): the game's map, mode and modifiers,
-- the players in the lobby and a status bar ("Starting in {time}" / "Waiting for players" /
-- "Started", players n/max). Closing the page leaves the lobby.
local function renderPublic(page)
	resetPage(page)
	local body = page.body
	if not public or not public.lobby then
		spinner(body, 1, C.MALIBU, "Connecting to lobby...") -- public_lobby.connecting
		return
	end
	-- Game config: map preview, map name, mode, modifier pills.
	local card = MenuKit.card(body, 1, 16, 14, 8)
	local top = make("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 96), Parent = card })
	local img = make("ImageLabel", { Name = "Preview", BackgroundTransparency = 1, Size = UDim2.fromOffset(150, 96), ScaleType = Enum.ScaleType.Fit, Parent = top })
	local mapLabel = text({ Position = UDim2.fromOffset(166, 8), Size = UDim2.new(1, -166, 0, 26), FontFace = F.BOLD, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = top })
	local modeLabel = text({ Position = UDim2.fromOffset(166, 38), Size = UDim2.new(1, -166, 0, 18), TextSize = 14, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = top })
	local pills = make("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card })
	make("UIGridLayout", { CellSize = UDim2.fromOffset(200, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = pills })
	-- Players
	local title = MenuKit.heading(body, 2, "People", "Players")
	local list = make("Frame", { Name = "Players", LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
	make("UIGridLayout", { CellSize = UDim2.fromOffset(220, 40), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	-- Status bar
	local statusBar = MenuKit.card(body, 4, 16, 12, 2)
	local statusTitle = text({ LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 14), TextSize = 10, FontFace = F.BOLD, TextTransparency = 0.6, TextXAlignment = Enum.TextXAlignment.Left, Text = "STATUS", Parent = statusBar })
	local statusRow = make("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = statusBar })
	local status = text({ Size = UDim2.new(1, -90, 1, 0), FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = statusRow })
	local count = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -22, 0, 0), Size = UDim2.fromOffset(60, 20), FontFace = F.BOLD, TextSize = 12, TextTransparency = 0.2, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = statusRow })
	MenuKit.icon("People", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16), Parent = statusRow })
	local _ = statusTitle

	local shownImg, pillSig, memberSig = nil, "", ""
	refreshers[#refreshers + 1] = function()
		local l = public and public.lobby
		if not l then
			return
		end
		mapLabel.Text = string.upper(tostring(l.name or l.map))
		modeLabel.Text = string.upper(tostring(l.sub or ""))
		if shownImg ~= l.map then
			local e = ctx.preview(l.map, 150)
			if e and pcall(function()
				img.ImageContent = Content.fromObject(e)
			end) then
				shownImg = l.map
			end
		end
		local mods = table.clone(l.mods or {})
		table.sort(mods, function(a, b)
			return #a > #b
		end)
		local sig = table.concat(mods, "|")
		if sig ~= pillSig then
			pillSig = sig
			for _, c in pills:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			for i, m in mods do
				local pill = text({ LayoutOrder = i, BackgroundTransparency = 0, BackgroundColor3 = C.MALIBU, FontFace = F.BOLD, TextSize = 12, Text = string.upper(m), Parent = pills })
				MenuKit.corner(pill, 4)
			end
			pills.Visible = #mods > 0
		end
		-- Players
		local members = public.members or {}
		local ms = ""
		for _, m in members do
			ms ..= tostring(m.userId) .. ":"
		end
		if ms ~= memberSig then
			memberSig = ms
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
				local r = make("Frame", { LayoutOrder = i, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Parent = list })
				MenuKit.corner(r, 8)
				MenuKit.stroke(r, if m.userId == localPlayer.UserId then 0.3 else 0.9, if m.userId == localPlayer.UserId then C.MALIBU else C.WHITE)
				text({ Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0), TextSize = 14, FontFace = F.MEDIUM, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(m.name), Parent = r })
			end
		end
		-- Status
		local left = if type(l.secs) == "number" then l.secs - (os.clock() - (public.at or os.clock())) else nil
		if l.started then
			status.Text = "Started" -- public_lobby.started
		elseif left == nil then
			status.Text = "Waiting for players" -- public_lobby.waiting_for_players
		elseif left > 0 then
			local whole = math.ceil(left)
			local m, sec = whole // 60, whole % 60
			status.Text = "Starting in " .. (if m > 0 then m .. "min" .. (if sec > 0 then " " .. sec .. "s" else "") else sec .. "s")
		else
			status.Text = "Started"
		end
		count.Text = tostring(l.count or #members) .. "/" .. tostring(l.max or "?")
	end
	for _, f in refreshers do
		f()
	end
end

-- "Joining the match" screen
local overlay: any = nil
local function showOverlay(label: string?)
	if not overlay then
		local gui = make("ScreenGui", { Name = "FrontlinesTeleport", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 200, Enabled = false, Parent = playerGui })
		local dim = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.BLACK, BackgroundTransparency = 0.25, BorderSizePixel = 0, Active = true, Parent = gui })
		local holder = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(360, 110), BackgroundTransparency = 1, Parent = dim })
		MenuKit.list(holder, false, 0, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		local t = spinner(holder, 1, C.CYBER, "")
		overlay = { gui = gui, text = t, shownAt = 0 }
	end
	overlay.text.Text = label or "Starting..."
	overlay.gui.Enabled = true
	overlay.shownAt = os.clock()
end

local function hideOverlay()
	if overlay then
		overlay.gui.Enabled = false
	end
end

function LobbyPages.handles(kind: string): boolean
	return kind == "host" or kind == "join" or kind == "ranked" or kind == "public" or kind == "solo"
end

LobbyPages.TITLES = { host = "Create Lobby", join = "Join Lobby", ranked = "1v1 Ranked Matchmaking", public = "Waiting for Game Start...", solo = "Solo" }

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
			ctx.net:FireServer("lobbyCreate")
		end
		renderLobby(page, true)
	elseif kind == "join" then
		renderJoin(page)
	elseif kind == "ranked" then
		ranked.state = "connecting"
		ctx.net:FireServer("rankedJoin")
		renderRanked(page)
	elseif kind == "public" then
		page.title.Text = "Waiting for Game Start..." -- public_lobby.title
		renderPublic(page)
	elseif kind == "solo" then
		renderSolo(page)
	end
end

-- Joins a public lobby ("ffa" | "team" | "special") and shows its waiting page.
function LobbyPages.joinPublic(lobbyType: string, view: any?)
	if not public or public.type ~= lobbyType then
		public = { type = lobbyType, lobby = view, members = {}, at = os.clock() }
	end
	ctx.net:FireServer("play", lobbyType)
end

function LobbyPages.closed(kind: string?)
	if kind == "host" or kind == "join" then
		if lobby then
			ctx.net:FireServer("lobbyLeave")
		end
		lobby = nil
		pendingSettings = nil
	elseif kind == "ranked" then
		ctx.net:FireServer("rankedLeave")
		ranked.state = "idle"
	elseif kind == "public" then
		if public then
			ctx.net:FireServer("leave")
		end
		public = nil
	end
	shown.page, shown.kind = nil, nil
	table.clear(refreshers)
end

local function onMM(data: any)
	if type(data) ~= "table" then
		return
	end
	if data.kind == "notice" then
		hideOverlay()
		ctx.toast(tostring(data.text))
	elseif data.kind == "studioMatch" then
		-- Studio: the match is played in this server (no teleport).
		hideOverlay()
		if ctx.studioMatch then
			ctx.studioMatch(data.tutorial == true)
		end
	elseif data.kind == "studioLobby" then
		hideOverlay()
		if ctx.studioLobby then
			ctx.studioLobby()
		end
	elseif data.kind == "teleport" then
		showOverlay(data.text)
		if require(script.Parent:WaitForChild("Settings")).values.lobbyStartAlerts then
			pcall(function()
				require(script.Parent:WaitForChild("SoundKit")).play("game-start") -- OpenFront lobby start alert
			end)
		end
	elseif data.kind == "public" then
		if data.type == nil then
			public = nil
		elseif public == nil or public.type == data.type then
			local first = public == nil or public.lobby == nil
			public = { type = data.type, lobby = data.lobby, members = data.members or {}, at = os.clock() }
			if shown.kind == "public" and shown.page then
				if first then
					renderPublic(shown.page)
				else
					for _, f in refreshers do
						f()
					end
				end
			end
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
			else
				ctx.toast(tostring(data.reason))
			end
			return
		end
		if data.state == "closed" or data.state == "left" then
			local wasIn = lobby ~= nil
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
		if pendingSettings and sendAt == 0 and os.clock() > editedAt + 1.5 then
			pendingSettings = nil -- the server has our edit by now
		end
		if shown.page and (shown.kind == "host" or shown.kind == "join") then
			if first then
				renderLobby(shown.page, shown.kind == "host")
			else
				for _, f in refreshers do
					f()
				end
			end
		end
	end
end

function LobbyPages.init(c)
	ctx = c
	ctx.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "mm" then
			onMM(data)
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
			if shown.kind == "host" or shown.kind == "join" or shown.kind == "public" or shown.kind == "solo" then
				for _, f in refreshers do
					f()
				end
			end
		end
	end)
end

function LobbyPages.showOverlay(label: string?)
	showOverlay(label)
end

return LobbyPages
