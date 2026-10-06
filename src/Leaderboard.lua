--[[
	War Front - in-match leaderboard (OpenFront's GameLeftSidebar + PlayerStats table).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Leaderboard (ModuleScript), used by GameClient.
--
-- Mirrors src/client/hud/layers/GameLeftSidebar.ts + PlayerStats.ts + components/StatsTable.ts:
--   * an <aside> flush in the top-left corner (bg-gray-800/92, rounded-br-lg, p-2) holding the
--     leaderboard toggle (20 px icon in a bg-gray-700/50, border-slate-500 rounded box; the solid
--     icon while the table is shown, the regular one while hidden),
--   * the stats table (bg-gray-800/85 rounded-lg): a bold bg-gray-700/95 header row with the
--     default player columns  #  | player | owned % | gold | max troops  (StatsConstants
--     DEFAULT_STATS_COLUMNS minus "clan": there are no clans here), sortable by clicking an
--     orderable header (sky-300 arrow), rows h-6/h-8/h-9 with slate-600/40 dividers, the local
--     player in bold, and pinned underneath (bg-gray-700/95) when ranked below the top 5.
--   * clicking a row moves the camera to that player (GoToPlayerEvent).
--   * the ⚙️ column picker (ColumnPicker.ts + StatsColumns.ts): a gear button next to the toggle
--     opens a checkbox popover of the hideable columns; the choice is saved (Settings
--     "leaderboardColumns"). Columns we can show: player type, owned %, gold, gold income /min,
--     troops, max troops, cities, ports, factories, silos, SAMs, warships (unit columns sum
--     levels like totalUnitLevels). Not ported: clan, trade/piracy gold rates, allies, betrayals
--     (the client doesn't know other players' alliances), and the game id text.
--
-- Leaderboard.create(ctx) -> api
--   ctx.gui, ctx.roster, ctx.fmt(n), ctx.fmtTroops(n)?, ctx.getMyId(), ctx.getLandTiles(),
--   ctx.getStructures()? (rows: id, kind, tile, owner, done, ..., [10] level), ctx.getUnits()?
-- api.frame, api.width, api.toggle (TextButton), api.refresh(), api.setExpanded(open)
-- api.focusPlayer   set by GameClient: function(id) (row click)

local IconKit = require(script.Parent:WaitForChild("IconKit"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Theme = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Theme"))

local Leaderboard = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(31, 41, 55)
local GRAY700 = Color3.fromRGB(55, 65, 81)
local SLATE500 = Color3.fromRGB(100, 116, 139)
local SLATE600 = Color3.fromRGB(71, 85, 105)
local SKY300 = Color3.fromRGB(125, 211, 252)
local YELLOW = Color3.fromRGB(250, 204, 21)

local PAD = 8 -- aside p-2
local TOGGLE = 26 -- p-0.5 + 20 px icon + border
local PINNED_VISIBLE_THRESHOLD = 4 -- StatsTable: pinned row only when the index is past this

-- StatsColumns.COLUMN_DEFS (the ones we have data for), in registry order.
-- id, w, align, order (sortable), hide (offered in the picker), label (picker text)
local C_ = Enum.TextXAlignment.Center
local R_ = Enum.TextXAlignment.Right
local ALL_COLS = {
	{ id = "rank", w = 34, align = C_, label = "Rank" },
	{ id = "player", w = 110, align = Enum.TextXAlignment.Left, label = "Player" },
	{ id = "playerType", w = 64, align = C_, order = true, hide = true, label = "Player Type" },
	{ id = "tiles", w = 62, align = R_, order = true, hide = true, label = "Owned" },
	{ id = "gold", w = 62, align = R_, order = true, hide = true, label = "Gold" },
	{ id = "goldIncomePerMin", w = 66, align = R_, order = true, hide = true, label = "Gold Income/min" },
	{ id = "troops", w = 62, align = R_, order = true, hide = true, label = "Troops" },
	{ id = "maxtroops", w = 62, align = R_, order = true, hide = true, label = "Max Troops" },
	{ id = "cities", w = 44, align = C_, order = true, hide = true, label = "Cities", unit = "City" },
	{ id = "ports", w = 44, align = C_, order = true, hide = true, label = "Ports", unit = "Port" },
	{ id = "factories", w = 44, align = C_, order = true, hide = true, label = "Factories", unit = "Factory" },
	{ id = "silos", w = 44, align = C_, order = true, hide = true, label = "Launchers", unit = "MissileSilo" },
	{ id = "sams", w = 44, align = C_, order = true, hide = true, label = "SAMs", unit = "SAM" },
	{ id = "warships", w = 44, align = C_, order = true, hide = true, label = "Warships", unit = "Warship" },
}
local DEFAULT_COLUMNS = "tiles,gold,maxtroops" -- DEFAULT_STATS_COLUMNS.player minus clan
local COLS = {} -- visible columns (rebuilt by setColumns)
local TABLE_W = 0
local W = 0
local function pickColumns(csv: string)
	table.clear(COLS)
	local want = {}
	for id in string.gmatch(csv or "", "[^,]+") do
		want[id] = true
	end
	for _, c in ALL_COLS do
		if not c.hide or want[c.id] then
			COLS[#COLS + 1] = c
		end
	end
	if #COLS == 2 then -- keep at least one stat column
		for _, c in ALL_COLS do
			if c.id == "tiles" then
				COLS[#COLS + 1] = c
			end
		end
	end
	TABLE_W = 0
	for _, c in COLS do
		TABLE_W += c.w
	end
	W = TABLE_W + 2 * PAD
end
pickColumns(DEFAULT_COLUMNS)

local function make(className: string, props: { [string]: any })
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextSize = props.TextSize or 12
	return make("TextLabel", props)
end

local function corner(parent, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
end

local function vline(parent, x: number, color: Color3, transparency: number)
	make("Frame", { Name = "VLine", Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = color, BackgroundTransparency = transparency, BorderSizePixel = 0, ZIndex = 3, Parent = parent })
end

function Leaderboard.create(ctx)
	local api = {}
	local fmt = ctx.fmt
	local fmtTroops = ctx.fmtTroops or function(n)
		return fmt(n / 10)
	end
	pickColumns(Settings.values.leaderboardColumns or DEFAULT_COLUMNS)
	local expanded = true
	local rowH = 26
	local textSize = 12
	local sortKey, sortDesc = "tiles", true

	local board = make("Frame", {
		Name = "Leaderboard",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(TOGGLE + 2 * PAD, TOGGLE + 2 * PAD),
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
		ClipsDescendants = true,
		Parent = ctx.gui,
	})
	corner(board, 8)

	local toggle = make("TextButton", {
		Name = "BoardToggle",
		Position = UDim2.fromOffset(PAD, PAD),
		Size = UDim2.fromOffset(TOGGLE, TOGGLE),
		BackgroundColor3 = GRAY700,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Parent = board,
	})
	corner(toggle, 6)
	make("UIStroke", { Color = SLATE500, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = toggle })
	local toggleIcon = IconKit.image("Leaderboard", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), Parent = toggle })

	-- Team games (GameLeftSidebar): a second toggle for the team table, "Your team: <team> ⦿",
	-- and TeamStats rows (team name in its colour, summed owned % / gold / max troops).
	local teamExpanded = true
	local teamToggle = make("TextButton", {
		Name = "TeamToggle",
		Position = UDim2.fromOffset(PAD + TOGGLE + 4, PAD),
		Size = UDim2.fromOffset(TOGGLE, TOGGLE),
		BackgroundColor3 = GRAY700,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Visible = false,
		Parent = board,
	})
	corner(teamToggle, 6)
	make("UIStroke", { Color = SLATE500, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = teamToggle })
	local teamToggleIcon = IconKit.image("Team", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), Parent = teamToggle })
	teamToggle.Activated:Connect(function()
		teamExpanded = not teamExpanded
		api.refresh()
	end)
	local yourTeam = label({ Name = "YourTeam", Position = UDim2.fromOffset(PAD, PAD + TOGGLE + 4), Size = UDim2.fromOffset(TABLE_W, 18), TextXAlignment = Enum.TextXAlignment.Left, RichText = true, Text = "", Visible = false, Parent = board })
	local teamBox = make("Frame", { Name = "TeamStats", Size = UDim2.fromOffset(TABLE_W, 100), BackgroundColor3 = GRAY800, BackgroundTransparency = 0.15, BorderSizePixel = 0, ClipsDescendants = true, Visible = false, Parent = board })
	corner(teamBox, 8)
	local teamRows = {}

	-- Table container (bg-gray-800/85 rounded-lg, mt-1)
	local tableBox = make("Frame", {
		Name = "Stats",
		Position = UDim2.fromOffset(PAD, PAD + TOGGLE + 4),
		Size = UDim2.fromOffset(TABLE_W, 100),
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = board,
	})
	corner(tableBox, 8)

	local header = make("Frame", { Size = UDim2.new(1, 0, 0, rowH), BackgroundColor3 = GRAY700, BackgroundTransparency = 0.05, BorderSizePixel = 0, Parent = tableBox })
	make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = SLATE500, BorderSizePixel = 0, ZIndex = 3, Parent = header })
	local headCells = {}
	local function headerIcon(c, cell, icons)
		if c.id == "rank" then
			label({ Size = UDim2.fromOffset(12, 16), FontFace = FONT_BOLD, Text = "#", LayoutOrder = 1, Parent = cell })
		elseif c.id == "player" then
			icons[1] = IconKit.image("Profile", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, Parent = cell })
		elseif c.id == "playerType" then
			label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, Text = "Type", LayoutOrder = 1, Parent = cell })
		elseif c.id == "tiles" then
			icons[1] = IconKit.image("Land", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, Parent = cell })
		elseif c.id == "gold" then
			icons[1] = IconKit.image("Gold", { Size = UDim2.fromOffset(16, 16), ImageColor3 = YELLOW, LayoutOrder = 1, Parent = cell })
		elseif c.id == "goldIncomePerMin" then
			icons[1] = IconKit.image("Gold", { Size = UDim2.fromOffset(16, 16), ImageColor3 = YELLOW, LayoutOrder = 1, Parent = cell })
			label({ Size = UDim2.fromOffset(0, 12), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 9, Text = "/min", LayoutOrder = 2, Parent = cell })
		elseif c.id == "troops" then
			icons[1] = IconKit.image("Soldier", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, Parent = cell })
		elseif c.id == "maxtroops" then
			-- soldier icon with the upper-limit icon as a superscript
			icons[1] = IconKit.image("Soldier", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, Parent = cell })
			icons[2] = IconKit.image("UpperLimit", { Size = UDim2.fromOffset(11, 11), LayoutOrder = 2, Parent = cell })
		elseif c.unit then
			icons[1] = IconKit.image(IconKit.KIND[c.unit] or c.unit, { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, Parent = cell })
		end
	end
	local function buildHeader()
		for _, h in headCells do
			h.cell:Destroy()
		end
		for _, l in header:GetChildren() do
			if l.Name == "VLine" then
				l:Destroy()
			end
		end
		table.clear(headCells)
		local x = 0
		for i, c in COLS do
			local cell = make("TextButton", { Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, c.w, 1, 0), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Selectable = c.order == true, Parent = header })
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 2),
				Parent = cell,
			})
			local icons = {}
			headerIcon(c, cell, icons)
			local arrow = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextColor3 = SKY300, Text = "", LayoutOrder = 3, Parent = cell })
			headCells[i] = { arrow = arrow, icons = icons, cell = cell }
			if c.order then
				cell.Activated:Connect(function()
					if sortKey == c.id then
						sortDesc = not sortDesc
					else
						sortKey, sortDesc = c.id, true
					end
					api.refresh()
				end)
			end
			if i > 1 then
				vline(header, x, SLATE500, 0)
			end
			x += c.w
		end
	end
	buildHeader()

	local list = make("ScrollingFrame", {
		Position = UDim2.fromOffset(0, rowH),
		Size = UDim2.new(1, 0, 0, 100),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Color3.fromRGB(148, 163, 184),
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		Parent = tableBox,
	})
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })

	local function newRow(parent)
		local f = make("TextButton", { Size = UDim2.new(1, 0, 0, rowH), BackgroundColor3 = Color3.fromRGB(71, 85, 105), BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false, Text = "", Parent = parent })
		local cells = {}
		local x = 0
		for i, c in COLS do
			cells[i] = label({
				Position = UDim2.fromOffset(x + 4, 0),
				Size = UDim2.new(0, c.w - 8, 1, 0),
				TextXAlignment = c.align,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = "",
				Parent = f,
			})
			if i > 1 then
				vline(f, x, SLATE600, 0.6)
			end
			x += c.w
		end
		local row = { frame = f, cells = cells, id = 0, vals = {}, own = nil, ts = 0, order = 0, h = 0, shown = true }
		f.MouseEnter:Connect(function()
			f.BackgroundTransparency = 0.4 -- hover:bg-slate-600/60
		end)
		f.MouseLeave:Connect(function()
			f.BackgroundTransparency = row.baseT or 1
		end)
		f.Activated:Connect(function()
			if row.id ~= 0 and api.focusPlayer then
				api.focusPlayer(row.id)
			end
		end)
		return row
	end

	local rows = {}
	local pinned
	local function newPinned()
		pinned = newRow(tableBox)
		pinned.baseT = 0.05
		pinned.frame.BackgroundColor3 = GRAY700
		pinned.frame.BackgroundTransparency = 0.05
		pinned.frame.Visible = false
	end
	newPinned()

	-- Per-refresh data for the unit columns (totalUnitLevels) and the gold income estimate.
	local unitLevels: { [number]: { [string]: number } } = {}
	local goldRate: { [number]: number } = {}
	local goldPrev: { [number]: { number } } = {}
	local TYPE_VALUE = { Human = 0, Nation = 1, Bot = 2 }
	local TYPE_TEXT = { [0] = "Player", [1] = "Nation", [2] = "Tribe" } -- player_type.*
	local UNIT_OF = {}
	for _, c in ALL_COLS do
		if c.unit then
			UNIT_OF[c.id] = c.unit
		end
	end

	local function value(p, key: string): number
		local s = p.stats
		if key == "tiles" then
			return s.tiles
		elseif key == "gold" then
			return s.gold
		elseif key == "maxtroops" then
			return s.maxTroops
		elseif key == "troops" then
			return s.troops
		elseif key == "goldIncomePerMin" then
			return goldRate[p.id] or 0
		elseif key == "playerType" then
			return TYPE_VALUE[p.kind] or 3
		end
		local unit = UNIT_OF[key]
		if unit then
			local u = unitLevels[p.id]
			return if u then u[unit] or 0 else 0
		end
		return 0
	end

	-- Cell text of a stat column for a value (player rows and summed team rows).
	local function statText(id: string, v: number): string
		if id == "tiles" then
			return string.format("%.1f%%", v / math.max(1, ctx.getLandTiles()) * 100) -- formatPercentage
		elseif id == "gold" or id == "goldIncomePerMin" then
			return fmt(v)
		elseif id == "troops" or id == "maxtroops" then
			return fmtTroops(v)
		elseif id == "playerType" then
			return TYPE_TEXT[v] or ""
		end
		return tostring(math.floor(v))
	end

	local function collectData()
		table.clear(unitLevels)
		local structures = ctx.getStructures and ctx.getStructures()
		if structures then
			for _, r in structures do
				local o = r[4]
				if o and o ~= 0 then
					local u = unitLevels[o]
					if not u then
						u = {}
						unitLevels[o] = u
					end
					u[r[2]] = (u[r[2]] or 0) + (tonumber(r[10]) or 1)
				end
			end
		end
		local units = ctx.getUnits and ctx.getUnits()
		if units then
			for _, w in units do
				local o = w.owner
				if o and o ~= 0 then
					local u = unitLevels[o]
					if not u then
						u = {}
						unitLevels[o] = u
					end
					u.Warship = (u.Warship or 0) + 1
				end
			end
		end
		-- GoldRateTracker stand-in: gold gained per minute, smoothed (spending isn't income).
		local now = os.clock()
		for id, p in ctx.roster do
			local g = p.stats.gold or 0
			local prev = goldPrev[id]
			if not prev then
				goldPrev[id] = { g, now }
			elseif now - prev[2] >= 1 then
				local gained = math.max(0, g - prev[1])
				local rate = gained / (now - prev[2]) * 60
				local old = goldRate[id]
				goldRate[id] = if old then old + (rate - old) * 0.3 else rate
				prev[1], prev[2] = g, now
			end
		end
	end

	-- Rows only touch the properties that changed: with 100+ players most cells keep their text
	-- between updates, and every property write costs (this was ~20 ms per refresh).
	local function setCell(row, i: number, v: string)
		if row.vals[i] ~= v then
			row.vals[i] = v
			row.cells[i].Text = v
		end
	end

	local function fill(row, rank: number, p, myId: number)
		local c = row.cells
		local own = p.id == myId
		row.id = p.id
		for j, col in COLS do
			local id = col.id
			if id == "rank" then
				setCell(row, j, tostring(rank))
			elseif id == "player" then
				setCell(row, j, p.name)
			else
				setCell(row, j, statText(id, value(p, id)))
			end
		end
		if row.own ~= own or row.ts ~= textSize then
			row.own, row.ts = own, textSize
			for _, cell in c do
				cell.FontFace = if own then FONT_BOLD else FONT
				cell.TextSize = textSize
			end
		end
	end

	local function placeRow(row, order: number)
		if row.order ~= order then
			row.order = order
			row.frame.LayoutOrder = order
		end
		if row.h ~= rowH then
			row.h = rowH
			row.frame.Size = UDim2.new(1, 0, 0, rowH)
		end
		if not row.shown then
			row.shown = true
			row.frame.Visible = true
		end
	end

	function api.setDensity(h: number, ts: number)
		if rowH ~= h or textSize ~= ts then
			rowH, textSize = h, ts
			api.refresh()
		end
	end

	-- Team table (TeamStats.buildRows): one row per team, sorted by land.
	local function refreshTeams(top: number): number
		local myId = ctx.getMyId()
		local mine = ctx.roster[myId]
		local myTeam = mine and mine.team or ""
		local agg, order = {}, {}
		for _, p in ctx.roster do
			local t = p.team or ""
			if t ~= "" then
				local a = agg[t]
				if not a then
					a = { team = t, tiles = 0, sums = {} }
					agg[t] = a
					order[#order + 1] = a
				end
				if p.stats.alive then
					a.tiles += p.stats.tiles
					for _, col in COLS do
						if col.order and col.id ~= "playerType" then
							a.sums[col.id] = (a.sums[col.id] or 0) + value(p, col.id)
						end
					end
				end
			end
		end
		table.sort(order, function(a, b)
			return a.tiles > b.tiles
		end)
		local y = 0
		for i, a in order do
			local row = teamRows[i]
			if not row then
				row = newRow(teamBox)
				teamRows[i] = row
			end
			row.frame.Visible = true
			row.frame.Position = UDim2.fromOffset(0, y)
			row.frame.Size = UDim2.new(1, 0, 0, rowH)
			row.id = 0
			local c = row.cells
			for j, col in COLS do
				local id = col.id
				if id == "rank" then
					setCell(row, j, tostring(i))
				elseif id == "player" then
					setCell(row, j, if a.team == "Bot" then "Tribes" else a.team) -- team_colors.bot
					c[j].TextColor3 = Theme.teamColor(a.team)
				elseif id == "playerType" then
					setCell(row, j, "") -- a team has no single type
				else
					setCell(row, j, statText(id, a.sums[id] or 0))
				end
			end
			local own = a.team == myTeam
			if row.own ~= own or row.ts ~= textSize then
				row.own, row.ts = own, textSize
				for _, cell in c do
					cell.FontFace = if own then FONT_BOLD else FONT
					cell.TextSize = textSize
				end
			end
			y += rowH
		end
		for i = #order + 1, #teamRows do
			teamRows[i].frame.Visible = false
		end
		teamBox.Position = UDim2.fromOffset(PAD, top)
		teamBox.Size = UDim2.fromOffset(TABLE_W, math.max(rowH, y))
		return math.max(rowH, y)
	end

	-- ⚙️ column picker (ColumnPicker.ts): px-0.5 border slate-500 rounded-md bg-gray-700/50 button,
	-- popover bg-gray-800/95 border-slate-500 rounded-md p-2 with one checkbox row per hideable
	-- column; at least one stays checked.
	local gear = make("TextButton", {
		Name = "ColumnPicker",
		Size = UDim2.fromOffset(TOGGLE, TOGGLE),
		BackgroundColor3 = GRAY700,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Parent = board,
	})
	corner(gear, 6)
	make("UIStroke", { Color = SLATE500, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = gear })
	IconKit.image("Settings", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 16), Parent = gear })
	local catcher = make("TextButton", { Name = "ColumnPickerCatcher", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Selectable = false, Visible = false, ZIndex = 60, Parent = ctx.gui })
	local popover = make("Frame", { Name = "ColumnPickerPopover", Size = UDim2.fromOffset(170, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = GRAY800, BackgroundTransparency = 0.05, BorderSizePixel = 0, Visible = false, Active = true, ZIndex = 61, Parent = ctx.gui })
	corner(popover, 6)
	make("UIStroke", { Color = SLATE500, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = popover })
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = popover })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = popover })

	local function selectedIds(): { [string]: boolean }
		local set = {}
		for _, c in COLS do
			if c.hide then
				set[c.id] = true
			end
		end
		return set
	end

	local renderPicker
	local currentCsv = Settings.values.leaderboardColumns or DEFAULT_COLUMNS
	local function setColumns(csv: string, save: boolean?)
		currentCsv = csv
		pickColumns(csv)
		if save then
			Settings.set("leaderboardColumns", csv)
		end
		buildHeader()
		for _, r in rows do
			r.frame:Destroy()
		end
		table.clear(rows)
		for _, r in teamRows do
			r.frame:Destroy()
		end
		table.clear(teamRows)
		pinned.frame:Destroy()
		newPinned()
		yourTeam.Size = UDim2.fromOffset(TABLE_W, 18)
		api.width = W
		api.refresh()
		renderPicker()
	end

	renderPicker = function()
		for _, ch in popover:GetChildren() do
			if ch:IsA("GuiButton") then
				ch:Destroy()
			end
		end
		local set = selectedIds()
		local count = 0
		for _ in set do
			count += 1
		end
		for i, c in ALL_COLS do
			if c.hide then
				local checked = set[c.id] == true
				local locked = checked and count == 1
				local b = make("TextButton", { LayoutOrder = i, Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 62, Parent = popover })
				local box = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = if checked then Color3.fromRGB(37, 99, 235) else WHITE, BorderSizePixel = 0, ZIndex = 62, Parent = b })
				corner(box, 3)
				if checked then
					label({ Size = UDim2.fromScale(1, 1), FontFace = FONT_BOLD, TextSize = 11, Text = "✓", ZIndex = 63, Parent = box })
				end
				label({ Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -22, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12, TextTransparency = if locked then 0.5 else 0, Text = c.label, ZIndex = 62, Parent = b })
				b.Activated:Connect(function()
					if locked then
						return
					end
					local ids = {}
					for _, cc in ALL_COLS do
						if cc.hide and (if cc.id == c.id then not checked else set[cc.id]) then
							ids[#ids + 1] = cc.id
						end
					end
					setColumns(table.concat(ids, ","), true)
				end)
			end
		end
	end

	-- The saved choice arrives with the profile after the board is built.
	Settings.Changed:Connect(function(key: string, v: any)
		if key == "leaderboardColumns" and type(v) == "string" and v ~= currentCsv then
			setColumns(v, false)
		end
	end)

	local function closePicker()
		popover.Visible = false
		catcher.Visible = false
	end
	catcher.Activated:Connect(closePicker)
	gear.Activated:Connect(function()
		if popover.Visible then
			closePicker()
			return
		end
		renderPicker()
		local p, sz = gear.AbsolutePosition, gear.AbsoluteSize
		popover.Position = UDim2.fromOffset(p.X, p.Y + sz.Y + 4)
		catcher.Visible = true
		popover.Visible = true
	end)

	function api.refresh()
		collectData()
		IconKit.set(toggleIcon, if expanded then "Leaderboard" else "LeaderboardRegular")
		local mineP = ctx.roster[ctx.getMyId()]
		local myTeam = mineP and mineP.team or ""
		local teamGame = myTeam ~= ""
		teamToggle.Visible = teamGame
		gear.Position = UDim2.fromOffset(PAD + (if teamGame then 2 else 1) * (TOGGLE + 4), PAD)
		gear.Visible = expanded
		if not expanded and popover.Visible then
			closePicker()
		end
		IconKit.set(teamToggleIcon, if teamExpanded then "Team" else "TeamRegular")
		yourTeam.Visible = teamGame
		local top = PAD + TOGGLE + 4
		if teamGame then
			-- help_modal.ui_your_team + team name in its colour + ⦿
			local c = Theme.teamColor(myTeam)
			yourTeam.Text = string.format('Your team: <font color="rgb(%d,%d,%d)">%s ●</font>', c.R * 255, c.G * 255, c.B * 255, myTeam)
			yourTeam.TextSize = textSize + 1
			yourTeam.Position = UDim2.fromOffset(PAD, top)
			top += 22
		end
		tableBox.Visible = expanded
		teamBox.Visible = teamGame and teamExpanded
		if not expanded then
			local h = top - 4
			if teamGame and teamExpanded then
				h = top + refreshTeams(top) + 4
			end
			local wCollapsed = if teamGame then (if teamExpanded then W else 2 * TOGGLE + 4 + 2 * PAD) else TOGGLE + 2 * PAD
			board.Size = UDim2.fromOffset(wCollapsed, if teamGame then h + PAD else TOGGLE + 2 * PAD)
			return
		end
		tableBox.Position = UDim2.fromOffset(PAD, top)
		local myId = ctx.getMyId()
		local sorted = {}
		for _, p in ctx.roster do
			if p.stats.alive and p.stats.tiles > 0 then
				sorted[#sorted + 1] = p
			end
		end
		table.sort(sorted, function(a, b)
			local va, vb = value(a, sortKey), value(b, sortKey)
			if va == vb then
				return a.id < b.id
			end
			if sortDesc then
				return va > vb
			end
			return va < vb
		end)
		for i, c in COLS do
			headCells[i].arrow.Text = if c.id == sortKey then (if sortDesc then "↓" else "↑") else ""
		end
		local myIndex = nil
		for i, p in sorted do
			if p.id == myId then
				myIndex = i
				break
			end
		end
		local pin = myIndex ~= nil and myIndex - 1 > PINNED_VISIBLE_THRESHOLD
		-- Only the rows inside the scroll window get their text filled (the list shows ~5 of
		-- 100+ players; filling every row cost ~20-30 ms per update). Scrolling refreshes.
		local firstVisible = math.floor(list.CanvasPosition.Y / math.max(1, rowH)) + 1
		local lastVisible = firstVisible + (if pin then 4 else 5) + 1
		local n = 0
		for i, p in sorted do
			if not (pin and i == myIndex) then
				n += 1
				local row = rows[n]
				if not row then
					row = newRow(list)
					rows[n] = row
				end
				placeRow(row, n)
				if n >= firstVisible - 1 and n <= lastVisible then
					fill(row, i, p, myId) -- ranks stay list-wide even with the pinned row taken out
				else
					row.id = p.id
				end
			end
		end
		for i = n + 1, #rows do
			local r = rows[i]
			if r.shown then
				r.shown = false
				r.frame.Visible = false
			end
			r.id = 0
		end
		header.Size = UDim2.new(1, 0, 0, rowH)
		for _, hc in headCells do
			hc.arrow.TextSize = textSize
		end
		-- max-h-[7.5rem] md:[10rem] lg:[11.25rem] (6 / 8 / 9 rem with a pinned row): ~5 rows
		local maxRows = if pin then 4 else 5
		local listH = math.max(1, math.min(n, maxRows)) * rowH
		list.Position = UDim2.fromOffset(0, rowH)
		list.Size = UDim2.new(1, 0, 0, listH)
		local h = rowH + listH
		pinned.frame.Visible = pin
		if pin then
			pinned.frame.Position = UDim2.fromOffset(0, h)
			pinned.frame.Size = UDim2.new(1, 0, 0, rowH)
			fill(pinned, myIndex :: number, sorted[myIndex :: number], myId)
			h += rowH
		end
		tableBox.Size = UDim2.fromOffset(TABLE_W, h)
		local bottom = top + h
		if teamGame and teamExpanded then
			bottom += 6 + refreshTeams(bottom + 6)
		end
		board.Size = UDim2.fromOffset(W, bottom + PAD)
	end

	local scrollPending = false
	list:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if scrollPending then
			return
		end
		scrollPending = true
		task.defer(function()
			scrollPending = false
			api.refresh()
		end)
	end)

	function api.setExpanded(open: boolean)
		expanded = open
		api.refresh()
	end

	api.frame = board
	api.width = W
	api.toggle = toggle
	return api
end

return Leaderboard
