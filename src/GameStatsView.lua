--[[
	War Front - one match's stats (OpenFront GameStatsModal / game-info-view), shown from the end of
	round modal and from the profile's game history.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.GameStatsView (ModuleScript), used by MatchHud and MenuPages.
--
-- stats = the server's "matchStats" payload (GameFlow.statsFor): placement, peakTiles, finalTiles,
--   peakPercent, seconds, attacksSent, attacksReceived, troopsSent, boatsSent, bombsLaunched,
--   built { kind = n }, kills, goldWar, deathSeconds (-1 = survived)
-- meta (optional, from the game history): map, mode, kind, players, won, t (os.time), elo
--
-- GameStatsView.render(body, stats, meta?, order?) -> next LayoutOrder   fills a MenuKit page body
-- GameStatsView.open(screenGui, stats, meta?)                            "STATS" modal over a GUI

local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local C, F, make = MenuKit.C, MenuKit.F, MenuKit.make

local GameStatsView = {}

local BUILD_NAMES = {
	City = "Cities", Factory = "Factories", Port = "Ports", DefensePost = "Defense Posts",
	MissileSilo = "Missile Silos", SAM = "SAM Launchers", Warship = "Warships",
}

local function num(n: any): string
	n = tonumber(n) or 0
	if n >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.1fK", n / 1e3)
	end
	local s = string.reverse((string.gsub(string.reverse(tostring(math.floor(n))), "(%d%d%d)", "%1,")))
	return (string.gsub(s, "^,", ""))
end

local function duration(sec: any): string
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	local h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
	if h > 0 then
		return string.format("%dh %dmin", h, m)
	elseif m > 0 then
		return string.format("%dmin %ds", m, s)
	end
	return s .. "s"
end

local function ordinal(n: number): string
	local suffix = "th"
	if n % 100 < 11 or n % 100 > 13 then
		suffix = ({ "st", "nd", "rd" })[n % 10] or "th"
	end
	return n .. suffix
end
GameStatsView.ordinal = ordinal
GameStatsView.duration = duration

local KIND_NAMES = { public = "Public", private = "Private", solo = "Singleplayer", tutorial = "Tutorial", ranked = "1v1 Ranked", standalone = "Public" }
GameStatsView.KIND_NAMES = KIND_NAMES

local function statCard(grid: Instance, order: number, label: string, value: string, accent: Color3?)
	local c = make("Frame", { LayoutOrder = order, BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, BorderSizePixel = 0, Parent = grid })
	MenuKit.corner(c, 12)
	MenuKit.stroke(c, 0.9)
	MenuKit.text({ Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 14), FontFace = F.BOLD, TextSize = 11, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, Text = string.upper(label), Parent = c })
	MenuKit.text({ Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -28, 0, 26), FontFace = F.BOLD, TextSize = 22, TextColor3 = accent or C.WHITE, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = value, Parent = c })
end

local function cardGrid(body: Instance, order: number): Frame
	local grid = make("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = body })
	local layout = make("UIGridLayout", { CellPadding = UDim2.fromOffset(10, 10), CellSize = UDim2.new(1 / 3, -7, 0, 66), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local function fit()
		local w = grid.AbsoluteSize.X
		local cols = if w < 360 then 2 elseif w < 640 then 3 else 4
		layout.CellSize = UDim2.new(1 / cols, -math.ceil(10 * (cols - 1) / cols) - 1, 0, 66) -- -1: rounding never wraps a row
	end
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	return grid
end

function GameStatsView.render(body: Instance, stats: any, meta: any?, order: number?): number
	local o = order or 1
	stats = if type(stats) == "table" then stats else {}
	meta = meta or {}
	local place = tonumber(stats.placement) or tonumber(meta.place) or 0
	local won = meta.won == true or place == 1

	-- Summary line: result, map, mode, game type, length.
	local head = MenuKit.card(body, o, 16, 14, 4)
	o += 1
	local result = if won then "Victory" elseif place > 0 then ordinal(place) .. " place" else "Game over"
	MenuKit.paragraph(head, 1, result, { FontFace = F.BOLD, TextSize = 24, TextColor3 = if won then C.CYBER else C.WHITE })
	local parts = {}
	for _, v in { meta.map, meta.mode, if meta.kind then KIND_NAMES[meta.kind] or meta.kind else nil } do
		if type(v) == "string" and v ~= "" then
			parts[#parts + 1] = v
		end
	end
	parts[#parts + 1] = duration(stats.seconds or meta.secs)
	if tonumber(meta.players) then
		parts[#parts + 1] = meta.players .. " players"
	end
	MenuKit.paragraph(head, 2, table.concat(parts, "  ·  "), { TextSize = 14, TextTransparency = 0.4 })
	if tonumber(meta.elo) then
		local d = tonumber(meta.elo)
		MenuKit.paragraph(head, 3, "ELO " .. (if d >= 0 then "+" .. d else tostring(d)), { FontFace = F.BOLD, TextSize = 14, TextColor3 = if d >= 0 then C.EMERALD300 else C.RED400 })
	end

	MenuKit.heading(body, o, nil, "Territory")
	o += 1
	local g1 = cardGrid(body, o)
	o += 1
	statCard(g1, 1, "Placement", if place > 0 then ordinal(place) else "-", if won then C.CYBER else nil)
	statCard(g1, 2, "Peak land", string.format("%.1f%%", tonumber(stats.peakPercent) or 0))
	statCard(g1, 3, "Peak tiles", num(stats.peakTiles))
	statCard(g1, 4, "Final tiles", num(stats.finalTiles))
	local death = tonumber(stats.deathSeconds) or -1
	statCard(g1, 5, "Survived", if death < 0 then "Until the end" else duration(death), if death < 0 then C.EMERALD300 else nil)

	MenuKit.heading(body, o, nil, "Combat")
	o += 1
	local g2 = cardGrid(body, o)
	o += 1
	statCard(g2, 1, "Players eliminated", num(stats.kills))
	statCard(g2, 2, "Gold from conquests", num(stats.goldWar), C.CYBER)
	statCard(g2, 3, "Attacks sent", num(stats.attacksSent))
	statCard(g2, 4, "Attacks received", num(stats.attacksReceived))
	statCard(g2, 5, "Troops sent", num(stats.troopsSent))
	statCard(g2, 6, "Boats sent", num(stats.boatsSent))
	statCard(g2, 7, "Bombs launched", num(stats.bombsLaunched))

	local built = if type(stats.built) == "table" then stats.built else {}
	local kinds = {}
	for k, n in built do
		if (tonumber(n) or 0) > 0 then
			kinds[#kinds + 1] = k
		end
	end
	table.sort(kinds, function(a, b)
		return (tonumber(built[a]) or 0) > (tonumber(built[b]) or 0)
	end)
	MenuKit.heading(body, o, nil, "Built")
	o += 1
	if #kinds == 0 then
		MenuKit.paragraph(body, o, "Nothing built this game.", { TextSize = 14, TextTransparency = 0.5 })
	else
		local g3 = cardGrid(body, o)
		for i, k in kinds do
			statCard(g3, i, BUILD_NAMES[k] or k, num(built[k]))
		end
	end
	return o + 1
end

local modal: any = nil
function GameStatsView.open(gui: Instance, stats: any, meta: any?)
	if not modal or not modal.holder.Parent or modal.gui ~= gui then
		modal = MenuKit.modal(gui, "GameStats")
		modal.gui = gui
		modal.holder.ZIndex = 80
	end
	local page = modal.page
	page:setTabs({})
	page:clear()
	page.title.Text = "STATS" -- game_list.stats
	GameStatsView.render(page.body, stats, meta)
	page.body.CanvasPosition = Vector2.zero
	modal.open()
end

return GameStatsView
