--[[
	War Front - the Doomsday Clock and Overtime readouts under the game timer.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(client/components/DoomsdayClockPanel.ts, OvertimePanel.ts, hud/layers/HeadsUpMessage.ts,
	resources/lang/en.json doomsday_clock / overtime). Modified version re-implemented in Luau for
	Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.ClockPanels (ModuleScript), used by HudSidebars (panels) and
-- MatchHud (the overtime heads-up notice).
-- Both panels: w-fit flex-col gap-1.5 py-2 px-4 bg-gray-800/92 rounded-bl-lg text-sm, a 208 x 10
-- bar, stacked (right-aligned) under the timer.
--   Doomsday Clock  skull + "Doomsday Clock" (red-400), status (Stable / Unstable / Collapsing
--                   -{rate}/s / Decaying -{rate} tiles/s); bar: your side's share (green) vs the
--                   rising threshold (red line); "Hold ≥ {pct}%" / "You {pct}%" | "{team}: {pct}%";
--                   detail: "Will reach {pct}% in {time}" / "Starts rising to {pct}% in {time}" /
--                   "Final zone, hold {pct}%" / "Decay in {secs}s". Red pulse in or near danger,
--                   orange pulse around a wave starting. Hidden once there is a winner.
--   Overtime        once overtime started: "Overtime" + "Hold > {pct}% to win" (orange); bar: first
--                   place's share (green if it's your side, red otherwise) vs the sinking win share
--                   (orange line); "1st: {name} ({pct}%)".
-- Server "clock" (once a second while either is on): { land = non-fallout land, doom = skulls }.
-- ClockPanels.build(parent)      creates the panels in parent (a vertical list)
-- ClockPanels.update(ctx)        ctx: roster, getMyId(), fmtTroops?; call every frame-ish
-- ClockPanels.overtimeNotice()   true during the 5 s "Overtime!" heads-up message

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(Shared:WaitForChild("SimClock"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local Doom = require(Shared:WaitForChild("Doomsday"))
local Theme = require(Shared:WaitForChild("Theme"))
local SpriteKit = require(script.Parent:WaitForChild("SpriteKit"))

local ClockPanels = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(31, 41, 55)
local GRAY600 = Color3.fromRGB(75, 85, 99)
local GRAY400 = Color3.fromRGB(156, 163, 175)
local GRAY300 = Color3.fromRGB(209, 213, 219)
local RED500 = Color3.fromRGB(239, 68, 68)
local RED400 = Color3.fromRGB(248, 113, 113)
local RED300 = Color3.fromRGB(252, 165, 165)
local GREEN400 = Color3.fromRGB(74, 222, 128)
local GREEN300 = Color3.fromRGB(134, 239, 172)
local ORANGE400 = Color3.fromRGB(251, 146, 60)
local ORANGE300 = Color3.fromRGB(253, 186, 116)
local BAR_W = 208
local OVERTIME_NOTICE_SECONDS = 5

local state = {
	phase = "Lobby",
	elapsed = 0, -- game seconds of play at atGame
	atGame = 0,
	land = 0, -- non-fallout land (server "clock")
	doom = {} :: { [number]: { stage: number, under: number } },
	teamGame = false,
}

local function make(class: string, props: { [string]: any }): any
	local inst = Instance.new(class)
	local parent = props.Parent
	props.Parent = nil
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function text(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextSize = props.TextSize or 14
	props.TextColor3 = props.TextColor3 or WHITE
	props.AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.X
	props.Size = props.Size or UDim2.fromOffset(0, 18)
	props.ZIndex = 41
	return make("TextLabel", props)
end

local function hms(d: number): string
	d = math.max(0, math.floor(d))
	local h, m, s = d // 3600, (d % 3600) // 60, d % 60
	if h ~= 0 then
		return string.format("%02d:%02d:%02d", h, m, s)
	end
	return string.format("%02d:%02d", m, s)
end

local function fixed1(x: number): string
	return string.format("%.1f", x)
end

-- Whole numbers without ".0" (OpenFront prints the percent values as JS numbers).
local function num(x: number): string
	if x == math.floor(x) then
		return string.format("%d", x)
	end
	return (string.gsub(string.format("%.2f", x), "0+$", ""))
end

local function panel(parent: Instance, order: number)
	local f = make("Frame", {
		Name = "Panel",
		LayoutOrder = order,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 40,
		Parent = parent,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 8), Parent = f })
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = f })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = f })
	local stroke = make("UIStroke", { Thickness = 3, Color = RED400, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = f })
	return f, stroke
end

-- A justify-between row: left and right labels.
local function row(parent: Instance, order: number, height: number)
	local r = make("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.fromOffset(BAR_W, height), ZIndex = 41, Parent = parent })
	return r
end

local function bar(parent: Instance, order: number, lineColor: Color3)
	local b = make("Frame", { Name = "Bar", LayoutOrder = order, Size = UDim2.fromOffset(BAR_W, 10), BackgroundColor3 = GRAY600, BackgroundTransparency = 0.4, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 41, Parent = parent })
	make("UICorner", { CornerRadius = UDim.new(0, 4), Parent = b })
	local fill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = GREEN400, BorderSizePixel = 0, ZIndex = 42, Parent = b })
	local line = make("Frame", { Name = "Line", Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = lineColor, BorderSizePixel = 0, ZIndex = 43, Parent = b })
	return fill, line
end

local ui: any = nil

function ClockPanels.build(parent: Instance)
	ui = {}
	-- Doomsday Clock
	local d, dStroke = panel(parent, 1)
	d.Name = "DoomsdayClockPanel"
	local top = row(d, 1, 20)
	local title = make("Frame", { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 20), BackgroundTransparency = 1, ZIndex = 41, Parent = top })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = title })
	local skull = SpriteKit.image("StDoomsday", { LayoutOrder = 1, Size = UDim2.fromOffset(20, 20), ZIndex = 42, Parent = title })
	if not skull then
		make("Frame", { LayoutOrder = 1, Size = UDim2.fromOffset(0, 20), BackgroundTransparency = 1, Parent = title })
	end
	text({ LayoutOrder = 2, FontFace = FONT_BOLD, TextColor3 = RED400, Text = "Doomsday Clock", Parent = title })
	ui.dStatus = text({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Text = "", Parent = top })
	ui.dFill, ui.dLine = bar(d, 2, RED500)
	local mid = row(d, 3, 18)
	ui.dHold = text({ TextColor3 = GRAY300, Text = "", Parent = mid })
	ui.dYou = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Text = "", Parent = mid })
	ui.dDetail = text({ LayoutOrder = 4, TextSize = 12, TextColor3 = GRAY400, Size = UDim2.fromOffset(0, 16), Text = "", Parent = d })
	ui.doom, ui.doomStroke = d, dStroke

	-- Overtime
	local o, oStroke = panel(parent, 2)
	o.Name = "OvertimePanel"
	oStroke.Transparency = 1
	local otop = row(o, 1, 20)
	text({ FontFace = FONT_BOLD, TextColor3 = ORANGE400, Text = "Overtime", Size = UDim2.fromOffset(0, 20), Parent = otop })
	ui.oWin = text({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), FontFace = FONT_BOLD, TextColor3 = ORANGE300, Text = "", Parent = otop })
	ui.oFill, ui.oLine = bar(o, 2, ORANGE400)
	ui.oFirst = text({ LayoutOrder = 3, TextSize = 12, TextColor3 = GRAY300, Size = UDim2.fromOffset(0, 16), Text = "", Parent = o })
	ui.over = o
end

local function elapsedNow(): number
	if state.phase ~= "Play" then
		return 0
	end
	return math.floor(state.elapsed + (SimClock.now() - state.atGame))
end

-- Config.percentageTilesOwnedToWin with overtime: 80 % minus 2 points a minute after 30 minutes.
local function winPercent(elapsed: number): number
	local base = math.floor(Config.WIN_FRACTION * 100 + 0.5)
	local past = elapsed - Config.OVERTIME_START_MINUTES * 60
	if past <= 0 then
		return base
	end
	return math.max(0, base - math.floor(past * Config.OVERTIME_DROP_PER_MINUTE / 60))
end

function ClockPanels.overtimeNotice(): boolean
	if state.phase ~= "Play" or not MatchRules.get().overtime then
		return false
	end
	local start = Config.OVERTIME_START_MINUTES * 60
	local e = elapsedNow()
	return e >= start and e < start + OVERTIME_NOTICE_SECONDS
end

local function pulse(stroke: UIStroke, color: Color3?, period: number)
	if not color then
		stroke.Transparency = 1
		return
	end
	stroke.Color = color
	local wave = 0.5 - 0.5 * math.cos(os.clock() / period * 2 * math.pi) -- 0 -> 1 -> 0
	stroke.Transparency = 1 - wave * 0.95
end

local function landOf(roster): number
	if state.land > 0 then
		return state.land
	end
	return 0
end

local function updateDoom(c, roster, myId: number)
	local rules = MatchRules.get()
	local speed = rules.doomsday
	local visible = speed ~= nil and state.phase == "Play"
	ui.doom.Visible = visible
	if not visible then
		return
	end
	local team = state.teamGame
	local elapsed = elapsedNow()
	local land = landOf(roster)
	local me = roster[myId]
	local live = me ~= nil and me.stats.alive and me.stats.tiles > 0
	local myTeam = if me and me.team ~= "" then me.team else nil
	local yourTiles = 0
	if me then
		if team and myTeam then
			for _, p in roster do
				if p.team == myTeam and p.stats.alive and p.kind ~= "Bot" then
					yourTiles += p.stats.tiles
				end
			end
		else
			yourTiles = me.stats.tiles
		end
	end
	local required = Doom.requiredTiles(speed :: string, team, land, elapsed)
	local wave = Doom.waveState(speed :: string, team, elapsed)
	local requiredPct = if land > 0 then required / land * 100 else 0
	local yourPct = if land > 0 then yourTiles / land * 100 else 0
	local mine = state.doom[myId]
	local flagged = mine ~= nil
	local under = if mine then mine.under else 0
	local draining = flagged and under >= Doom.CFG.warnSeconds
	local decaying = draining and mine ~= nil and mine.stage == 3
	local nearDanger = live and not flagged and required > 0 and yourPct <= requiredPct * 1.1
	local redAlert = flagged or nearDanger

	local zoneDetail = if wave.done
		then "Final zone, hold " .. num(wave.currentPercent) .. "%"
		elseif wave.growing then "Will reach " .. num(wave.targetPercent) .. "% in " .. hms(wave.secondsToTarget)
		else "Starts rising to " .. num(wave.targetPercent) .. "% in " .. hms(wave.secondsToNextGrowth)
	local status, statusColor, statusBold, detail = "", WHITE, false, zoneDetail
	if live and decaying then
		status = "Decaying -" .. Doom.rotQuota(me.stats.tiles, under) .. " tiles/s"
		statusColor, statusBold = RED500, true
	elseif live and draining then
		local maxT = me.stats.maxTroops or 0
		local past = under - Doom.CFG.warnSeconds
		local floor = Doom.troopFloor(maxT, past)
		local chunk = Doom.drain(maxT, past)
		local rate = math.max(0, math.min(me.stats.troops - floor, chunk))
		status = "Collapsing -" .. (if c.fmtTroops then c.fmtTroops(rate) else tostring(math.floor(rate))) .. "/s"
		statusColor, statusBold = RED400, true
	elseif live and flagged then
		status = "Unstable"
		statusColor, statusBold = RED400, true
		detail = "Decay in " .. math.max(0, Doom.CFG.warnSeconds - under) .. "s"
	elseif live then
		status = "Stable"
		statusColor, statusBold = if nearDanger then ORANGE300 else GREEN400, nearDanger
	end
	ui.dStatus.Text = status
	ui.dStatus.TextColor3 = statusColor
	ui.dStatus.FontFace = if statusBold then FONT_BOLD else FONT
	ui.dFill.Size = UDim2.fromScale(math.clamp(yourPct / 100, 0, 1), 1)
	ui.dLine.Position = UDim2.new(math.clamp(requiredPct / 100, 0, 1), 0, 0, 0)
	ui.dHold.Text = "Hold ≥ " .. fixed1(requiredPct) .. "%"
	if live and myTeam then
		ui.dYou.Text = myTeam .. ": " .. fixed1(yourPct) .. "%"
		ui.dYou.TextColor3 = Theme.teamColor(myTeam)
	elseif live then
		ui.dYou.Text = "You " .. fixed1(yourPct) .. "%"
		ui.dYou.TextColor3 = if redAlert then RED300 else GREEN300
	else
		ui.dYou.Text = ""
	end
	ui.dDetail.Text = detail
	ui.dDetail.Visible = detail ~= ""
	if redAlert then
		pulse(ui.doomStroke, RED400, 1)
	elseif wave.waveFlash then
		pulse(ui.doomStroke, ORANGE400, 1.8)
	else
		pulse(ui.doomStroke, nil, 1)
	end
end

local function updateOvertime(roster, myId: number)
	local rules = MatchRules.get()
	local elapsed = elapsedNow()
	local visible = rules.overtime and state.phase == "Play" and elapsed >= Config.OVERTIME_START_MINUTES * 60
	ui.over.Visible = visible
	if not visible then
		return
	end
	local land = landOf(roster)
	local requiredPct = winPercent(elapsed)
	local me = roster[myId]
	local leaderName, leaderTiles, isMine = nil, 0, false
	if not state.teamGame then
		for id, p in roster do
			if p.stats.alive and (leaderName == nil or p.stats.tiles > leaderTiles) then
				leaderName, leaderTiles, isMine = p.name, p.stats.tiles, id == myId
			end
		end
	else
		local tiles = {}
		for _, p in roster do
			if p.stats.alive and p.team ~= "" then
				tiles[p.team] = (tiles[p.team] or 0) + p.stats.tiles
			end
		end
		for t, n in tiles do
			if leaderName == nil or n > leaderTiles then
				leaderName, leaderTiles = t, n
			end
		end
		if leaderName == "Bot" then
			leaderName = nil -- the bot team can't win on tiles: no first place to show
		end
		isMine = me ~= nil and leaderName ~= nil and me.team == leaderName
	end
	local leaderPct = if land > 0 and leaderName then leaderTiles / land * 100 else 0
	ui.oWin.Text = "Hold > " .. requiredPct .. "% to win"
	ui.oFill.Size = UDim2.fromScale(math.clamp(leaderPct / 100, 0, 1), 1)
	ui.oFill.BackgroundColor3 = if leaderName and me ~= nil and not isMine then RED400 else GREEN400
	ui.oLine.Position = UDim2.new(math.clamp(requiredPct / 100, 0, 1), 0, 0, 0)
	ui.oFirst.Visible = leaderName ~= nil
	ui.oFirst.Text = if leaderName then "1st: " .. leaderName .. " (" .. math.floor(leaderPct) .. "%)" else ""
end

function ClockPanels.update(c)
	if not ui then
		return
	end
	local roster = c.roster
	local myId = c.getMyId()
	if Players.LocalPlayer:WaitForChild("PlayerGui"):GetAttribute("WFReplay") == true then
		ui.doom.Visible, ui.over.Visible = false, false
		return
	end
	updateDoom(c, roster, myId)
	updateOvertime(roster, myId)
end

function ClockPanels.visible(): boolean
	return ui ~= nil and (ui.doom.Visible or ui.over.Visible)
end

local function applyPhase(ph)
	if type(ph) ~= "table" then
		return
	end
	state.phase = ph.phase or state.phase
	state.elapsed = if type(ph.elapsed) == "number" then ph.elapsed else 0
	state.atGame = SimClock.now()
	state.teamGame = ph.teamGame == true
end

local net = Shared:WaitForChild("Net") :: RemoteEvent
net.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "init" and type(data) == "table" then
		applyPhase(data.phase)
		table.clear(state.doom)
		state.land = 0
	elseif kind == "phase" then
		applyPhase(data)
	elseif kind == "clock" and type(data) == "table" then
		state.land = tonumber(data.land) or state.land
		table.clear(state.doom)
		if type(data.doom) == "table" then
			for _, d in data.doom do
				if type(d) == "table" and type(d[1]) == "number" then
					state.doom[d[1]] = { stage = tonumber(d[2]) or 1, under = tonumber(d[3]) or 0 }
				end
			end
		end
	end
end)

return ClockPanels
