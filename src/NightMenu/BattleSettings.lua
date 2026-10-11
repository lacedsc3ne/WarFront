-- War Front Night menu: battle settings and battle room pieces. Copyright (C) 2026 Liam (lacedsc3ne).
-- Used by NightMenu.Pages host / join / solo. All state and actions go through LobbyPages.night
-- (the same settings table, pushSettings throttling, lobby messages and server calls as before).
--
-- BattleSettings.mapArt(parent, props) -> (ImageLabel, show(mapId))   map thumbnail
-- BattleSettings.build(body, order, opts) -> (refresh(), nextOrder)
--   opts: api (LobbyPages.night), editable, solo, pool() -> maps, preview(id, w), phone
-- BattleSettings.summary(settings) -> { string }   plain lines for players who can't edit
-- BattleSettings.room(body, order, opts) -> refresh()  code, who can join, players, invite
--   opts: api, ctx (page ctx), onSettings() (host: edit settings), phone

local Players = game:GetService("Players")

local Kit = require(script.Parent:WaitForChild("Kit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local BattleSettings = {}

-- Map pictures in the map style E look (11 Oct 2026), drawn from each map's own cleaned terrain:
-- land, soft coastline and the style E sea, the whole map as it looks in a battle.
-- { x, y, w, h, image } (whole image). Old painted atlas: rbxassetid://123526786397636 / 114682684854030.
local THUMBNAIL_ASSET = "rbxassetid://131085760210363"
local THUMBNAIL_REGIONS = {
	World = { 0, 0, 800, 400, "rbxassetid://131085760210363" },
	Europe = { 0, 0, 704, 640, "rbxassetid://83361553562776" },
	NorthAmerica = { 0, 0, 704, 608, "rbxassetid://127645978925542" },
	Africa = { 0, 0, 640, 608, "rbxassetid://121858660429391" },
	UnitedStates = { 0, 0, 704, 392, "rbxassetid://127821727590057" },
	Alps = { 0, 0, 704, 448, "rbxassetid://72288144375553" },
	Britannia = { 0, 0, 480, 640, "rbxassetid://89887823831230" },
	Italia = { 0, 0, 544, 640, "rbxassetid://90980522725639" },
}

function BattleSettings.mapArt(parent: Instance, props: { [string]: any }?, preview: ((string, number) -> any)?)
	local p = props or {}
	p.Name = p.Name or "MapArt"
	p.BackgroundTransparency = 1
	p.ScaleType = Enum.ScaleType.Crop -- pictures fill the card (whole map with its sea)
	p.Parent = parent
	local image = make("ImageLabel", p)
	local last = nil
	local function show(mapId: string?)
		if mapId == last then
			return
		end
		local region = mapId and THUMBNAIL_REGIONS[mapId]
		if region then
			image.Image = region[5] or THUMBNAIL_ASSET
			image.ImageRectOffset = Vector2.new(region[1], region[2])
			image.ImageRectSize = Vector2.new(region[3], region[4])
			last = mapId
		elseif mapId and preview then
			local art = preview(mapId, 300)
			if art then
				image.Image = ""
				image.ImageRectOffset, image.ImageRectSize = Vector2.zero, Vector2.zero
				image.ImageContent = Content.fromObject(art)
				last = mapId
			end
		end
	end
	return image, show
end

-- Plain words ---------------------------------------------------------------------------------

local TEAM_WORDS = {
	Duos = "Pairs",
	Trios = "Teams of 3",
	Quads = "Teams of 4",
	["Humans Vs Nations"] = "Humans vs computer",
}
local function teamWord(v: any): string
	if type(v) == "number" then
		return v .. " teams"
	end
	return TEAM_WORDS[v] or tostring(v)
end
BattleSettings.teamWord = teamWord

local DIFFICULTY_WORDS = { Easy = "Easy", Medium = "Medium", Hard = "Hard", Impossible = "Very hard" }

local TOGGLES = {
	-- key, label, help, inverted (on = key is false)
	{ "noAlliances", "Alliances", "Players can team up during the battle", true },
	{ "compact", "Small map", "A smaller map with fewer computer players" },
	{ "randomSpawn", "Start anywhere at random", nil },
	{ "instantBuild", "Build instantly", nil },
	{ "donateGold", "Share gold with others", nil },
	{ "donateTroops", "Share troops with others", nil },
	{ "infiniteGold", "Endless gold", nil },
	{ "infiniteTroops", "Endless troops", nil },
	{ "waterNukes", "Nukes flood land", "Nukes turn land into water instead of fallout" },
	{ "overtime", "Easier win after 30 min", "Less land is needed to win as time goes on" },
}

local CHOICES = {
	{ "doomsday", "Doomsday clock", "Hold enough land as the clock ticks, or be wiped out", { { "off", "Off" }, { "slow", "Slow" }, { "normal", "Normal" }, { "fast", "Fast" }, { "veryfast", "Very fast" } }, "off" },
	{ "goldMultiplier", "Gold speed", nil, { { 1, "x1" }, { 1.5, "x1.5" }, { 2, "x2" }, { 3, "x3" }, { 5, "x5" } }, 1 },
	{ "startingGold", "Starting gold", nil, { { 0, "None" }, { 1000000, "1M" }, { 5000000, "5M" }, { 25000000, "25M" } }, 0 },
	{ "allianceMinutes", "Alliance length", "How long an alliance lasts before it must be renewed", { { 2, "2 min" }, { 3, "3 min" }, { 0, "5 min" }, { 10, "10 min" }, { 15, "15 min" }, { 30, "30 min" } }, 0 },
	{ "immunitySeconds", "Safe time at the start", "No attacks between players for this long", { { 5, "5 s" }, { 30, "30 s" }, { 60, "1 min" }, { 120, "2 min" }, { 300, "5 min" } }, 5 },
}

function BattleSettings.summary(s: any): { string }
	local lines = {}
	local mode = if s.mode == "Team" then teamWord(s.teams or 2) else "Everyone for themselves"
	table.insert(lines, mode)
	table.insert(lines, "Computer players: " .. (if s.nations == false then "none" else string.lower(DIFFICULTY_WORDS[s.difficulty or "Easy"] or "easy")))
	local on = {}
	for _, t in TOGGLES do
		local v = s[t[1]] == true
		if t[4] then
			if v then
				table.insert(on, "No alliances")
			end
		elseif v then
			table.insert(on, t[2])
		end
	end
	if type(s.doomsday) == "string" and s.doomsday ~= "off" then
		table.insert(on, "Doomsday clock (" .. s.doomsday .. ")")
	end
	if (tonumber(s.goldMultiplier) or 1) > 1 then
		table.insert(on, "x" .. s.goldMultiplier .. " gold")
	end
	if (tonumber(s.startingGold) or 0) > 0 then
		table.insert(on, string.format("%gM starting gold", s.startingGold / 1e6))
	end
	if (tonumber(s.maxTimer) or 0) > 0 then
		table.insert(on, s.maxTimer .. " min time limit")
	end
	if type(s.disabledUnits) == "table" and #s.disabledUnits > 0 then
		table.insert(on, "Some buildings and weapons turned off")
	end
	if #on > 0 then
		table.insert(lines, table.concat(on, " · "))
	end
	return lines
end

-- Building blocks ------------------------------------------------------------------------------

local function heading(parent: Instance, order: number, textValue: string, size: number?)
	return Kit.text({ Name = "Heading", Text = textValue, FontFace = F.TITLE, TextSize = size or 19, LayoutOrder = order, Parent = parent })
end

local function muted(parent: Instance, order: number, textValue: string)
	return Kit.text({
		Text = textValue,
		FontFace = F.BOLD,
		TextSize = 14,
		TextColor3 = C.MUTED,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
end
BattleSettings.muted = muted

-- A wrapping row of pill choices (team formats, buildings).
local function pillRow(parent: Instance, order: number)
	local row = make("Frame", { Name = "Pills", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.list(row, true, 6, { Wraps = true })
	return row
end

local function pill(parent: Instance, order: number, label: string, onClick: () -> ())
	local b = make("TextButton", {
		Name = "Pill_" .. label,
		Text = label,
		FontFace = F.TITLE,
		TextSize = 15,
		AutoButtonColor = false,
		BackgroundColor3 = C.CARD,
		TextColor3 = C.TEXT,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
		SelectionImageObject = Kit.ring,
		Parent = parent,
	})
	Kit.corner(b)
	local stroke = Kit.stroke(b)
	Kit.pad(b, 14)
	b.Activated:Connect(onClick)
	return b, function(on: boolean, dim: boolean?)
		b.BackgroundColor3 = if on then C.YELLOW else C.CARD
		b.TextColor3 = if on then C.YELLOW_TEXT elseif dim then C.MUTED else C.TEXT
		stroke.Color = if on then C.YELLOW_EDGE else C.LINE
	end
end

local function toggleRow(parent: Instance, order: number, label: string, help: string?, onChange: (boolean) -> ())
	local row = make("Frame", { Name = "Row_" .. label, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, if help then 46 else 34), LayoutOrder = order, Parent = parent })
	Kit.list(row, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local words = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1), LayoutOrder = 1, Parent = row })
	Kit.flex(words)
	Kit.list(words, false, 0, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.text({ Text = label, FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = words })
	if help then
		Kit.text({ Text = help, FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 2, Parent = words })
	end
	local toggle, set = Kit.toggle(false, onChange)
	toggle.LayoutOrder = 2
	toggle.Parent = row
	return set
end

local function choiceRow(parent: Instance, order: number, label: string, help: string?, options: { any }, onChange: (any) -> (), phone: boolean)
	local block = make("Frame", { Name = "Choice_" .. label, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.list(block, false, 4)
	Kit.text({ Text = label, FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = block })
	if help then
		Kit.text({ Text = help, FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = block })
	end
	local seg, set = Kit.segmented(options, nil, onChange)
	seg.LayoutOrder = 3
	seg.Size = UDim2.fromOffset(0, if phone then 42 else 38)
	seg.Parent = block
	return set
end

local function sliderRow(parent: Instance, order: number, label: string, min: number, max: number, step: number, fmt: (number) -> string, onChange: (number) -> ())
	local row = make("Frame", { Name = "Slider_" .. label, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = order, Parent = parent })
	Kit.list(row, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local name = Kit.text({ Text = label, FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = row })
	name.Size = UDim2.fromOffset(0, 20)
	name.AutomaticSize = Enum.AutomaticSize.X
	local spacer = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 2, Parent = row })
	Kit.flex(spacer)
	local value = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 16, TextColor3 = C.YELLOW, LayoutOrder = 4, Parent = row })
	local slider, set = Kit.slider(min, max, min, step, function(v)
		value.Text = fmt(v)
		onChange(v)
	end)
	slider.LayoutOrder = 3
	slider.Parent = row
	return function(v: number)
		set(v)
		value.Text = fmt(v)
	end
end

-- Settings editor ----------------------------------------------------------------------------

function BattleSettings.build(body: Instance, order: number, opts: any): (() -> (), number)
	local api = opts.api
	local phone = opts.phone == true
	local refreshers: { () -> () } = {}
	local function get()
		return api.settings()
	end
	local function push(change)
		api.push(change)
	end
	local function nextOrder(): number
		order += 1
		return order
	end

	if not opts.editable then
		local card = Kit.card({ Name = "Summary", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = body })
		Kit.pad(card, 16, 16, 12, 14)
		Kit.list(card, false, 6)
		local head = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 1, Parent = card })
		Kit.list(head, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local artBox = make("Frame", { BackgroundColor3 = C.MAP_LAND, BorderSizePixel = 0, Size = UDim2.fromOffset(96, 64), LayoutOrder = 1, ClipsDescendants = true, Parent = head })
		Kit.corner(artBox, 8)
		local _, showArt = BattleSettings.mapArt(artBox, { Size = UDim2.fromScale(1, 1) }, opts.preview)
		local mapLabel = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 22, LayoutOrder = 2, Parent = head })
		local lines = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = card })
		Kit.list(lines, false, 2)
		local sig = ""
		table.insert(refreshers, function()
			local s = get()
			showArt(if s.randomMap then nil else s.map)
			mapLabel.Text = if s.randomMap then "Random map" else api.mapName(s.map)
			local list = BattleSettings.summary(s)
			local now = table.concat(list, "\n")
			if now ~= sig then
				sig = now
				for _, c in lines:GetChildren() do
					if c:IsA("GuiObject") then
						c:Destroy()
					end
				end
				for i, l in list do
					muted(lines, i, l)
				end
			end
		end)
		local function refresh()
			for _, f in refreshers do
				f()
			end
		end
		refresh()
		return refresh, order
	end

	-- 1. Map
	heading(body, nextOrder(), "1. Pick a map")
	local maps = make("Frame", { Name = "Maps", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = body })
	local cell = if phone then Vector2.new(124, 92) else Vector2.new(150, 108)
	make("UIGridLayout", { CellSize = UDim2.fromOffset(cell.X, cell.Y), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = maps })
	local function mapTile(i: number, id: string?, name: string, onClick: () -> ())
		local b = make("TextButton", {
			Name = "Map_" .. (id or "Random"),
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = C.MAP_LAND,
			BorderSizePixel = 0,
			LayoutOrder = i,
			ClipsDescendants = true,
			SelectionImageObject = Kit.ring,
			Parent = maps,
		})
		Kit.corner(b, 10)
		local stroke = Kit.stroke(b, C.LINE, 2)
		if id then
			local _, show = BattleSettings.mapArt(b, { Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -34) }, opts.preview)
			table.insert(refreshers, function()
				show(id)
			end)
		else
			Kit.icon("Dice", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -12), Size = UDim2.fromOffset(34, 34), ImageColor3 = C.YELLOW, Parent = b })
		end
		local strip = make("Frame", { BackgroundColor3 = C.CARD, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 26), Parent = b })
		Kit.text({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Text = name, FontFace = F.TITLE, TextSize = 14, Parent = strip })
		b.Activated:Connect(onClick)
		return function(on: boolean)
			stroke.Color = if on then C.YELLOW else C.LINE
			stroke.Thickness = if on then 3 else 2
		end
	end
	local pool = opts.pool()
	for i, m in pool do
		local set = mapTile(i, m.id, m.name, function()
			push({ map = m.id, randomMap = false })
		end)
		table.insert(refreshers, function()
			local s = get()
			set(not s.randomMap and s.map == m.id)
		end)
	end
	do
		local set = mapTile(#pool + 1, nil, "Random", function()
			push({ randomMap = true })
		end)
		table.insert(refreshers, function()
			set(get().randomMap == true)
		end)
	end

	-- 2. Mode
	heading(body, nextOrder(), "2. How do you want to play?")
	local setMode = choiceRow(body, nextOrder(), "Battle type", nil, { { "FFA", "Everyone for themselves" }, { "Team", "Teams" } }, function(v)
		-- Same rule as before: switching to teams turns on sharing gold and troops.
		if v == "Team" and get().mode ~= "Team" then
			push({ mode = "Team", donateGold = true, donateTroops = true })
		else
			push({ mode = v })
		end
	end, phone)
	local teamBlock = make("Frame", { Name = "Teams", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = body })
	Kit.list(teamBlock, false, 4)
	Kit.text({ Text = "Team size", FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = teamBlock })
	local teamPills = pillRow(teamBlock, 2)
	for i, t in api.TEAMS do
		local value = t[1]
		local _, set = pill(teamPills, i, teamWord(value), function()
			push({ teams = value })
		end)
		table.insert(refreshers, function()
			set(get().teams == value)
		end)
	end
	table.insert(refreshers, function()
		local s = get()
		setMode(s.mode or "FFA")
		teamBlock.Visible = s.mode == "Team"
	end)

	-- 3. Computer players
	heading(body, nextOrder(), "3. Computer players")
	local diffOptions = { { "none", "None" } }
	for _, d in api.DIFFICULTIES do
		table.insert(diffOptions, { d, DIFFICULTY_WORDS[d] or d })
	end
	local setDiff = choiceRow(body, nextOrder(), "How strong are the computer nations?", nil, diffOptions, function(v)
		if v == "none" then
			push({ nations = false })
		else
			push({ nations = true, difficulty = v })
		end
	end, phone)
	table.insert(refreshers, function()
		local s = get()
		setDiff(if s.nations == false then "none" else (s.difficulty or "Easy"))
	end)

	-- More options (folded away)
	local moreButton = make("TextButton", {
		Name = "MoreOptions",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.CARD,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 48),
		LayoutOrder = nextOrder(),
		SelectionImageObject = Kit.ring,
		Parent = body,
	})
	Kit.corner(moreButton, 12)
	Kit.stroke(moreButton)
	Kit.pad(moreButton, 14)
	Kit.list(moreButton, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon("Adjust", { Size = UDim2.fromOffset(20, 20), ImageColor3 = C.YELLOW, LayoutOrder = 1, Parent = moreButton })
	Kit.text({ Text = "More options", FontFace = F.TITLE, TextSize = 17, LayoutOrder = 2, Parent = moreButton })
	Kit.text({ Text = "gold, alliances, timer, weapons…", FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = moreButton })
	local gap = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 4, Parent = moreButton })
	Kit.flex(gap)
	local chevron = Kit.icon("ChevronDown", { Size = UDim2.fromOffset(20, 20), ImageColor3 = C.MUTED, LayoutOrder = 5, Parent = moreButton })

	local more = Kit.card({ Name = "More", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Visible = false, Parent = body })
	Kit.pad(more, 16, 16, 12, 16)
	Kit.list(more, false, 10)
	moreButton.Activated:Connect(function()
		more.Visible = not more.Visible
		Kit.setIcon(chevron, if more.Visible then "ChevronUp" else "ChevronDown")
	end)

	local grid = make("Frame", { Name = "Toggles", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = more })
	make("UIGridLayout", { CellSize = if phone then UDim2.new(1, 0, 0, 46) else UDim2.new(0.5, -10, 0, 46), CellPadding = UDim2.fromOffset(20, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	for i, t in TOGGLES do
		local key, inverted = t[1], t[4] == true
		local holder = make("Frame", { BackgroundTransparency = 1, LayoutOrder = i, Parent = grid })
		local set = toggleRow(holder, 1, t[2], t[3], function(v)
			push({ [key] = if inverted then not v else v })
		end)
		holder:FindFirstChildWhichIsA("Frame").Size = UDim2.fromScale(1, 1)
		table.insert(refreshers, function()
			local v = get()[key] == true
			set(if inverted then not v else v)
		end)
	end

	local o = 2
	for _, c in CHOICES do
		local key, default = c[1], c[5]
		local set = choiceRow(more, o, c[2], c[3], c[4], function(v)
			push({ [key] = v })
		end, phone)
		o += 1
		table.insert(refreshers, function()
			local v = get()[key]
			set(if v == nil then default else v)
		end)
	end

	local setTimer = sliderRow(more, o, "Time limit", 0, 120, 5, function(v)
		return if v <= 0 then "None" else v .. " min"
	end, function(v)
		push({ maxTimer = v })
	end)
	o += 1
	local setTribes = sliderRow(more, o, "Small computer tribes", 0, 400, 10, function(v)
		return if v <= 0 then "None" else tostring(v)
	end, function(v)
		push({ bots = v })
	end)
	o += 1
	table.insert(refreshers, function()
		local s = get()
		setTimer(s.maxTimer or 0)
		setTribes(s.bots or 400)
	end)

	Kit.text({ Text = "Allowed buildings and weapons", FontFace = F.BOLD, TextSize = 16, LayoutOrder = o, Parent = more })
	o += 1
	local units = pillRow(more, o)
	for i, u in api.UNITS do
		local kind = u[1]
		local _, set = pill(units, i, u[2], function()
			local list = table.clone(get().disabledUnits or {})
			local at = table.find(list, kind)
			if at then
				table.remove(list, at)
			else
				table.insert(list, kind)
			end
			push({ disabledUnits = list })
		end)
		table.insert(refreshers, function()
			local list = get().disabledUnits
			local off = type(list) == "table" and table.find(list, kind) ~= nil
			set(not off, off)
		end)
	end

	local function refresh()
		for _, f in refreshers do
			f()
		end
	end
	refresh()
	return refresh, order
end

-- Battle room: code, who can join, players ---------------------------------------------------------

function BattleSettings.room(body: Instance, order: number, opts: any): () -> ()
	local api, ctx = opts.api, opts.ctx
	local card = Kit.card({ Name = "Room", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = body })
	Kit.pad(card, 16, 16, 14, 16)
	Kit.list(card, false, 10)

	-- Code
	local codeRow = make("Frame", { Name = "Code", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 1, Parent = card })
	Kit.list(codeRow, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.text({ Text = "Code", FontFace = F.TITLE, TextSize = 18, TextColor3 = C.MUTED, LayoutOrder = 1, Parent = codeRow })
	local revealed = false
	local code = make("TextButton", {
		Name = "CodeValue",
		Text = "",
		FontFace = F.TITLE,
		TextSize = 30,
		TextColor3 = C.YELLOW,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		SelectionImageObject = Kit.ring,
		Parent = codeRow,
	})
	code.Activated:Connect(function()
		revealed = not revealed
	end)
	muted(card, 2, "Friends can join with this code: Ways to play › Enter a code.")

	-- Who can join
	local visBlock = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = card })
	Kit.list(visBlock, false, 4)
	Kit.text({ Text = "Who can join?", FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = visBlock })
	local vis, setVis = Kit.segmented({ { "private", "Only with the code" }, { "public", "Anyone" } }, nil, function(v)
		api.setVisibility(v)
	end)
	vis.LayoutOrder = 2
	vis.Parent = visBlock
	local visText = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = visBlock })

	-- Players
	local playersTitle = Kit.text({ Text = "Players", FontFace = F.TITLE, TextSize = 18, LayoutOrder = 4, Parent = card })
	local list = make("Frame", { Name = "Players", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = card })
	Kit.list(list, false, 6)
	local invite = Kit.button("secondary", "Invite friends", { icon = "UserPlus", height = 42, size = UDim2.new(1, 0, 0, 42), layoutOrder = 6, parent = card, onActivated = function()
		api.invite()
	end })
	invite.Name = "InviteFriends"

	local sig = ""
	return function()
		local lobby = api.lobby()
		if not lobby then
			return
		end
		local hidden = false
		local ok, Settings = pcall(require, script.Parent.Parent:WaitForChild("Settings"))
		if ok and Settings.values.hiddenLobbyIds then
			hidden = not revealed
		end
		code.Text = if hidden then "••••••  (tap to show)" else tostring(lobby.code or "......")
		local v = api.visibility()
		setVis(v)
		vis.Visible = lobby.isHost == true
		visText.Visible = lobby.isHost ~= true
		visText.Text = if v == "public" then "Anyone can find this battle in Open battles" else "Only people with the code can join"
		local members = lobby.members or {}
		local now = tostring(lobby.isHost)
		for _, m in members do
			now ..= ":" .. tostring(m.userId) .. tostring(m.host)
		end
		if now == sig then
			return
		end
		sig = now
		playersTitle.Text = "Players · " .. #members .. "/" .. tostring(lobby.max or lobby.settings and lobby.settings.max or 50)
		for _, c in list:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for i, m in members do
			local row = make("Frame", { Name = "Player_" .. tostring(m.userId), BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = i, Parent = list })
			Kit.corner(row, 10)
			Kit.pad(row, 12, 8)
			Kit.list(row, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
			local me = m.userId == Players.LocalPlayer.UserId
			local dot = make("Frame", { BackgroundColor3 = if m.host then C.YELLOW else C.CYAN, BorderSizePixel = 0, Size = UDim2.fromOffset(10, 10), LayoutOrder = 1, Parent = row })
			Kit.corner(dot)
			Kit.text({ Text = tostring(m.name) .. (if me then " (you)" else ""), FontFace = F.BOLD, TextSize = 16, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, Parent = row })
			if m.host then
				Kit.icon("Crown", { Size = UDim2.fromOffset(18, 18), ImageColor3 = C.YELLOW, LayoutOrder = 3, Parent = row })
			end
			local gap = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 4, Parent = row })
			Kit.flex(gap)
			if lobby.isHost and not m.host then
				local uid = m.userId
				Kit.iconButton("Close", { name = "Remove", size = 28, color = C.CARD, iconColor = C.PINK, layoutOrder = 5, parent = row, onActivated = function()
					api.kick(uid)
				end })
			end
		end
	end
end

return BattleSettings
