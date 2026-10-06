--[[
	War Front - match HUD extras: attacks display, spawn timer, heads-up message,
	win modal and emoji bubbles.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MatchHud (ModuleScript), used by GameClient (via Interact).
-- Mirrors these OpenFront layers (src/client/hud/layers):
--   AttacksDisplay.ts  rows above the control panel: our attacks (with a retreat button), boats at
--                      sea (ETA, retreat), incoming attacks (retaliate) and incoming boats
--   SpawnTimer.ts      9 px bar across the top filling up during the spawn phase
--   HeadsUpMessage.ts  "Choose a starting location" banner (15% from the top) and toasts
--   WinModal.ts        end-of-round card: "You Won!" / "<name> has won!" / "Nation <name> has won!"
--   EventsDisplay.ts   emoji lines ("<name>: 😀", "Sent <name>: 😀"); the emoji also floats over
--                      the sender's territory for 5 s (NameLayer)
-- Reads the "me" snapshot (attacks, incoming, boatList, boatsIn) through ctx.getMe(); listens to
-- Shared.Net itself for "init", "phase" and "emoji".
--
-- MatchHud.setup(ctx)
--   ctx.gui, ctx.net, ctx.roster, ctx.getMyId(), ctx.getMe(), ctx.getPhase(), ctx.getRatio(),
--   ctx.fmt(n), ctx.stack (HudStack frame: the attack rows go in it), ctx.labelLayer (map overlay
--   frame for emoji bubbles), ctx.mapSize() -> (W, H), ctx.focusPlayer(id),
--   ctx.pushFeed(text, kind, owner), ctx.exitGame()
-- MatchHud.toast(text, color?)   OpenFront "show-message" toast ("green" | "red")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Emojis = require(Shared:WaitForChild("Emojis"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local Replay = require(script.Parent:WaitForChild("Replay"))
local ClockPanels = require(script.Parent:WaitForChild("ClockPanels"))

local MatchHud = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(31, 41, 55)
local RED400 = Color3.fromRGB(248, 113, 113)
local RED_ICON = Color3.fromRGB(220, 38, 38)
local AQUARIUS = Color3.fromHex("#3fa9f5")
local SLATE300 = Color3.fromRGB(203, 213, 225)
local BRIGHT_BLUE = Color3.fromHex("#1e90ff")

local ctx: any = nil
local gui: ScreenGui

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

local function corner(parent: Instance, r: number?)
	make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function label(props)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextSize = props.TextSize or 14
	return make("TextLabel", props)
end

local function nameOf(id: number): string
	if id == 0 then
		return "Wilderness"
	end
	local p = ctx.roster[id]
	return if p then p.name else "?"
end

-- OpenFront getBoatETA: 1s, 35s, 1m, 1m1s ...
local function eta(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	if seconds <= 0 then
		return "0s"
	end
	local m, s = seconds // 60, seconds % 60
	return (if m > 0 then m .. "m" else "") .. (if s > 0 then s .. "s" else "")
end

--------------------------------------------------------------------------------
-- Attacks display
--------------------------------------------------------------------------------
local attacks = { rows = {} :: { [string]: any }, frame = nil :: any, grid = nil :: any }

local ROW_H = 26
local MAX_H = 112 -- OpenFront max-h-[7rem]

local function rowButton(parent: Instance, order: number)
	local b = make("TextButton", {
		Size = UDim2.new(1, -30, 1, 0),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 3),
		Parent = b,
	})
	return b
end

local function makeRow(key: string)
	local f = make("Frame", {
		Name = key,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = attacks.grid,
	})
	corner(f, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 4), Parent = f })
	local main = rowButton(f, 1)
	local icon = IconKit.image("Soldier", { Size = UDim2.fromOffset(16, 16), LayoutOrder = 1, ZIndex = 4, Parent = main })
	local arrow = label({ Size = UDim2.fromOffset(9, 16), FontFace = FONT_BOLD, TextSize = 13, Text = "", LayoutOrder = 2, ZIndex = 4, Parent = main })
	local troops = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, Text = "", LayoutOrder = 3, ZIndex = 4, Parent = main })
	local name = label({ Size = UDim2.new(1, -110, 0, 16), TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, Text = "", LayoutOrder = 4, ZIndex = 4, Parent = main })
	local extra = label({ Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, TextSize = 12, TextColor3 = SLATE300, Text = "", LayoutOrder = 5, ZIndex = 4, Parent = main })
	-- Right side: retreat (X), retaliate (sword) or "(retreating...)".
	local action = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(26, 22),
		BackgroundColor3 = Color3.fromRGB(127, 29, 29),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		FontFace = FONT_BOLD,
		TextSize = 14,
		TextColor3 = RED400,
		Text = "",
		ZIndex = 4,
		Parent = f,
	})
	corner(action, 6)
	local actionStroke = make("UIStroke", { Color = Color3.fromRGB(185, 28, 28), Transparency = 0.5, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = action })
	local sword = IconKit.image("Sword", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 16), ImageColor3 = RED_ICON, Visible = false, ZIndex = 5, Parent = action })
	local status = label({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -2, 0.5, 0), Size = UDim2.fromOffset(0, 16), AutomaticSize = Enum.AutomaticSize.X, TextSize = 13, TextColor3 = AQUARIUS, Text = "(retreating...)", Visible = false, ZIndex = 4, Parent = f })
	local row = { frame = f, main = main, icon = icon, arrow = arrow, troops = troops, name = name, extra = extra, action = action, actionStroke = actionStroke, sword = sword, status = status }
	main.Activated:Connect(function()
		if row.onMain then
			row.onMain()
		end
	end)
	action.Activated:Connect(function()
		if row.onAction then
			row.onAction()
		end
	end)
	attacks.rows[key] = row
	return row
end

-- kind: "out" | "land" | "boat" | "in" | "inboat"
local function fillRow(row, kind: string, order: number, d)
	row.frame.LayoutOrder = order
	local incoming = kind == "in" or kind == "inboat"
	local color = if incoming then RED400 else AQUARIUS
	local boat = kind == "boat" or kind == "inboat"
	local iconName = if boat then "Boat" else "Soldier"
	if row.iconName ~= iconName then
		row.iconName = iconName
		IconKit.set(row.icon, iconName)
	end
	if boat then
		local owner = ctx.roster[d.owner]
		row.icon.ImageColor3 = if owner then Color3.fromRGB(owner.r or 255, owner.g or 255, owner.b or 255) else WHITE
		row.icon.Size = UDim2.fromOffset(18, 18)
	else
		row.icon.ImageColor3 = if incoming then RED_ICON else AQUARIUS
		row.icon.Size = UDim2.fromOffset(16, 16)
	end
	row.arrow.Text = if boat then "" elseif incoming then "↓" else "↑"
	row.arrow.Size = UDim2.fromOffset(if boat then 0 else 9, 16)
	row.arrow.TextColor3 = color
	row.troops.Text = (ctx.fmtTroops or ctx.fmt)(d.troops) -- renderTroops
	row.troops.TextColor3 = color
	row.name.Text = d.name
	row.name.TextColor3 = color
	row.name.TextSize = if boat then 12 else 14
	row.extra.Text = d.extra or ""
	row.onMain = d.onMain
	row.onAction = d.onAction
	local retreating = d.retreating == true
	row.status.Visible = retreating
	row.action.Visible = d.onAction ~= nil and not retreating
	row.sword.Visible = kind == "in"
	row.action.Text = if kind == "in" then "" else "❌"
	row.action.BackgroundTransparency = if kind == "in" then 0.5 else 1
	row.actionStroke.Enabled = kind == "in"
	row.action.Selectable = row.action.Visible
	row.main.Selectable = d.onMain ~= nil
end

local function refreshAttacks()
	local frame = attacks.frame
	if not frame then
		return
	end
	local myId = ctx.getMyId()
	local mine = ctx.roster[myId]
	local me = ctx.getMe()
	local show = ctx.getPhase() == "Play" and mine ~= nil and mine.stats.alive
	local seen = {}
	local order = 0
	local function put(key: string, kind: string, d)
		order += 1
		seen[key] = true
		local row = attacks.rows[key] or makeRow(key)
		fillRow(row, kind, order, d)
	end
	if show then
		local function focus(id: number)
			return function()
				ctx.focusPlayer(id)
			end
		end
		-- Outgoing attacks on players, then on the wilderness.
		for _, a in me.attacks or {} do
			local target, troops, retreating = a[1], a[2], a[3]
			if target ~= 0 then
				put("out" .. target, "out", {
					troops = troops,
					name = nameOf(target),
					retreating = retreating,
					onMain = focus(target),
					onAction = function()
						ctx.net:FireServer("retreat", target)
					end,
				})
			end
		end
		for _, a in me.attacks or {} do
			if a[1] == 0 then
				put("land", "land", {
					troops = a[2],
					name = "Wilderness",
					retreating = a[3],
					onAction = function()
						ctx.net:FireServer("retreat", 0)
					end,
				})
			end
		end
		-- Our boats at sea.
		for _, b in me.boatList or {} do
			local id, troops, targetOwner, secs, retreating = b[1], b[2], b[3], b[4], b[5]
			put("boat" .. id, "boat", {
				owner = myId,
				troops = troops,
				name = if retreating then nameOf(myId) else nameOf(targetOwner),
				extra = eta(secs),
				retreating = retreating,
				onMain = focus(targetOwner),
				onAction = function()
					ctx.net:FireServer("boatRetreat", id)
				end,
			})
		end
		-- Incoming attacks (not from bots) with a retaliate button, then incoming boats.
		for _, a in me.incoming or {} do
			local attacker, troops, retreating = a[1], a[2], a[3]
			put("in" .. attacker, "in", {
				troops = troops,
				name = nameOf(attacker) .. (if retreating then " (retreating...)" else ""),
				retreating = false,
				onMain = focus(attacker),
				onAction = if retreating then nil else function()
					ctx.net:FireServer("retaliate", attacker, ctx.getRatio())
				end,
			})
		end
		for _, b in me.boatsIn or {} do
			local id, troops, owner, secs = b[1], b[2], b[3], b[4]
			put("inboat" .. id, "inboat", {
				owner = owner,
				troops = troops,
				name = nameOf(owner),
				extra = eta(secs),
				onMain = focus(owner),
			})
		end
	end
	for key, row in attacks.rows do
		if not seen[key] then
			local sel = GuiService.SelectedObject
			if sel and sel:IsDescendantOf(row.frame) then
				GuiService.SelectedObject = nil
			end
			row.frame:Destroy()
			attacks.rows[key] = nil
		end
	end
	local rows = math.ceil(order / 2)
	local h = rows * ROW_H + math.max(0, rows - 1) * 4
	frame.Visible = order > 0
	frame.Size = UDim2.new(1, 0, 0, math.min(h, MAX_H))
	frame.CanvasSize = UDim2.fromOffset(0, h)
end

local function buildAttacks(parent: Instance)
	local frame = make("ScrollingFrame", {
		Name = "AttacksDisplay",
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		LayoutOrder = 1,
		Selectable = false,
		Parent = parent,
	})
	attacks.frame = frame
	attacks.grid = frame
	make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -2, 0, ROW_H),
		CellPadding = UDim2.fromOffset(4, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = frame,
	})
end

--------------------------------------------------------------------------------
-- Spawn timer + heads-up message + toast
--------------------------------------------------------------------------------
local phaseInfo = { phase = "Lobby", ticksLeft = 0, at = 0, winnerId = 0, winner = nil :: string?, winnerTeam = nil :: string? }
local spawnBar: Frame
local spawnFill: Frame
local headsUp: TextLabel
local toastFrame: Frame
local toastText: TextLabel
local toastToken = 0

local function buildTop()
	spawnBar = make("Frame", { Name = "SpawnTimer", Size = UDim2.new(1, 0, 0, 9), BackgroundTransparency = 1, Visible = false, ZIndex = 30, Parent = gui })
	spawnFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = BRIGHT_BLUE, BackgroundTransparency = 0.15, BorderSizePixel = 0, ZIndex = 30, Parent = spawnBar })
	-- border-b-3 / border-r-2 black
	make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 31, Parent = spawnFill })
	make("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 31, Parent = spawnFill })

	headsUp = label({
		Name = "HeadsUpMessage",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.15),
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0.3,
		BackgroundColor3 = GRAY800,
		TextSize = 20,
		Text = "",
		Visible = false,
		ZIndex = 29,
		Parent = gui,
	})
	corner(headsUp, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), Parent = headsUp })
	make("UISizeConstraint", { MaxSize = Vector2.new(900, 200), Parent = headsUp })

	toastFrame = make("Frame", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 24),
		Size = UDim2.fromOffset(200, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = Color3.fromRGB(34, 197, 94),
		BackgroundTransparency = 0.85,
		Visible = false,
		ZIndex = 35,
		Parent = gui,
	})
	corner(toastFrame, 12)
	make("UIPadding", { PaddingLeft = UDim.new(0, 24), PaddingRight = UDim.new(0, 24), PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14), Parent = toastFrame })
	make("UIStroke", { Name = "Border", Color = Color3.fromRGB(34, 197, 94), Transparency = 0.5, Parent = toastFrame })
	toastText = label({ Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT, TextSize = 16, Text = "", ZIndex = 36, Parent = toastFrame })
end

function MatchHud.toast(text: string, color: string?, seconds: number?)
	if not toastFrame then
		return
	end
	local c = if color == "red" then Color3.fromRGB(239, 68, 68) else Color3.fromRGB(34, 197, 94)
	toastFrame.BackgroundColor3 = c
	local border = toastFrame:FindFirstChild("Border") :: UIStroke?
	if border then
		border.Color = c
	end
	toastText.Text = text
	toastFrame.Visible = true
	toastToken += 1
	local token = toastToken
	task.delay(seconds or 2, function()
		if toastToken == token then
			toastFrame.Visible = false
		end
	end)
end

local function refreshTop()
	local ph = ctx.getPhase()
	local inSpawn = ph == "Spawn"
	spawnBar.Visible = inSpawn
	if inSpawn then
		local total = Config.SPAWN_PHASE_TICKS
		local left = phaseInfo.ticksLeft - (os.clock() - phaseInfo.at) / Config.TICK
		spawnFill.Size = UDim2.fromScale(math.clamp((total - left) / total, 0, 1), 1)
	end
	-- (Overtime: "Overtime! ..." for its first 5 seconds, HeadsUpMessage.isOvertimeNotice.)
	local overtime = not inSpawn and ClockPanels.overtimeNotice()
	headsUp.Visible = inSpawn or overtime
	if inSpawn then
		local mine = ctx.roster[ctx.getMyId()]
		headsUp.Text = if ctx.getMyId() ~= 0 and mine then "Choose a starting location" else "Players are choosing starting locations"
	elseif overtime then
		headsUp.Text = "Overtime! The territory needed to win is now dropping."
	end
end

--------------------------------------------------------------------------------
-- Win modal
--------------------------------------------------------------------------------
local win = { card = nil :: any, title = nil :: any, body = nil :: any, keep = nil :: any, shownFor = "" }

local function hideWin()
	if win.card and win.card.Visible then
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(win.card) then
			GuiService.SelectedObject = nil
		end
		win.card.Visible = false
	end
end

local function buildWin()
	local c = make("Frame", {
		Name = "WinModal",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 60,
		Parent = gui,
	})
	corner(c, 8)
	make("UISizeConstraint", { MaxSize = Vector2.new(700, math.huge), Parent = c })
	-- p-4 md:p-6
	make("UIPadding", { PaddingLeft = UDim.new(0, 24), PaddingRight = UDim.new(0, 24), PaddingTop = UDim.new(0, 24), PaddingBottom = UDim.new(0, 24), Parent = c })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 16), HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = c })
	win.title = label({ Size = UDim2.new(1, 0, 0, 32), TextSize = 26, TextWrapped = true, Text = "", LayoutOrder = 1, ZIndex = 61, Parent = c })
	local box = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.7, LayoutOrder = 2, ZIndex = 61, Parent = c })
	corner(box, 2) -- rounded-sm
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = box })
	win.body = label({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, FontFace = FONT_BOLD, TextSize = 20, TextWrapped = true, Text = "", ZIndex = 62, Parent = box }) -- h3 text-xl font-semibold
	local buttons = make("Frame", { Size = UDim2.new(1, 0, 0, 48), BackgroundTransparency = 1, LayoutOrder = 3, ZIndex = 61, Parent = c })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = buttons })
	-- o-button primary block: bg-malibu-blue hover:bg-aquarius, rounded-xl, bold uppercase.
	local function oButton(text: string, order: number, onClick: () -> ())
		local malibu = Color3.fromHex("#0084d1")
		local b = make("TextButton", {
			Size = UDim2.new(0.5, -5, 1, 0),
			BackgroundColor3 = malibu,
			AutoButtonColor = false,
			FontFace = FONT_BOLD,
			TextSize = 16,
			TextColor3 = WHITE,
			Text = text,
			LayoutOrder = order,
			ZIndex = 62,
			Parent = buttons,
		})
		corner(b, 12)
		b.MouseEnter:Connect(function()
			b.BackgroundColor3 = AQUARIUS
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundColor3 = malibu
		end)
		b.SelectionGained:Connect(function()
			b.BackgroundColor3 = AQUARIUS
		end)
		b.SelectionLost:Connect(function()
			b.BackgroundColor3 = malibu
		end)
		b.Activated:Connect(onClick)
		return b
	end
	win.exitBtn = oButton("EXIT GAME", 1, function()
		hideWin()
		if ctx.exitGame then
			ctx.exitGame()
		end
	end)
	win.keep = oButton("KEEP PLAYING", 3, hideWin)
	-- War Front: the round can be watched again right away (Replay.lua); OpenFront lists replays
	-- in the player's game history instead.
	win.replay = oButton("WATCH REPLAY", 2, function()
		hideWin()
		Replay.start()
	end)
	win.replay.Visible = false
	-- OpenFront GameStatsModal: this round's stats (server "matchStats", GameStatsView).
	win.stats = oButton("STATS", 4, function()
		if win.matchStats then
			require(script.Parent:WaitForChild("GameStatsView")).open(gui, win.matchStats)
		end
	end)
	win.stats.Visible = false
	win.card = c
end

local function refreshWin()
	if ctx.getPhase() ~= "Ended" then
		hideWin()
		win.shownFor = ""
		return
	end
	local myId = ctx.getMyId()
	local key = tostring(phaseInfo.winnerId) .. ":" .. tostring(phaseInfo.winner) .. ":" .. tostring(phaseInfo.winnerTeam)
	if win.shownFor ~= key then
		win.shownFor = key
		local wid = phaseInfo.winnerId or 0
		local w = ctx.roster[wid]
		local title
		local mineP = ctx.roster[myId]
		if phaseInfo.winnerTeam then
			-- win_modal.your_team / other_team
			title = if mineP and mineP.team == phaseInfo.winnerTeam then "Your team won!" else phaseInfo.winnerTeam .. " team has won!"
		elseif wid ~= 0 and wid == myId then
			title = "You Won!"
		elseif w and w.kind == "Nation" then
			title = "Nation " .. w.name .. " has won!"
		elseif w or phaseInfo.winner then
			title = (if w then w.name else phaseInfo.winner) .. " has won!"
		else
			title = "Round over"
		end
		win.title.Text = title
		local mine = ctx.roster[myId]
		win.keep.Text = if mine and mine.stats.alive then "KEEP PLAYING" else "SPECTATE"
		win.card.Visible = true
		if UserInputService.GamepadEnabled and string.find(UserInputService:GetLastInputType().Name, "Gamepad") then
			GuiService.SelectedObject = win.keep
		end
	end
	local secs = math.max(0, math.ceil((phaseInfo.ticksLeft - (os.clock() - phaseInfo.at) / Config.TICK) * Config.TICK))
	win.body.Text = string.format("Next round starts in %ds", secs)
	if workspace:GetAttribute("WFPlaceRole") == "match" then
		win.body.Text = string.format("Back to the lobby in %ds", secs)
	end
	-- flex-1 buttons: share the row between the visible ones
	local canReplay = Replay.available()
	local hasStats = win.matchStats ~= nil
	if win.replay.Visible ~= canReplay or win.stats.Visible ~= hasStats then
		win.replay.Visible = canReplay
		win.stats.Visible = hasStats
		local n = 2 + (if canReplay then 1 else 0) + (if hasStats then 1 else 0)
		for _, b in { win.keep, win.replay, win.exitBtn, win.stats } do
			if b then
				b.Size = UDim2.new(1 / n, -(10 * (n - 1)) / n, 1, 0)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Emoji messages
--------------------------------------------------------------------------------
local bubbles: { any } = {}

local function onEmoji(data)
	local from, to, index = data.from, data.to, data.i
	local emoji = Emojis.LIST[index]
	if not emoji then
		return
	end
	local myId = ctx.getMyId()
	local sender = ctx.roster[from]
	if not sender then
		return
	end
	-- Feed line (EventsDisplay.onEmojiMessageEvent): to us, or sent by us to one player.
	if to == myId and myId ~= 0 then
		ctx.pushFeed(sender.name .. ": " .. emoji, "info", from)
	elseif from == myId and to ~= 0 then
		ctx.pushFeed("Sent " .. nameOf(to) .. ": " .. emoji, "info", to)
	end
	-- Over the sender's territory for everyone it was meant for (NameLayer shows emojis sent to
	-- us or to all players).
	-- Settings "Emojis" off hides them over the map.
	local showEmojis = require(script.Parent:WaitForChild("Settings")).values.emojis ~= false
	if showEmojis and (to == myId or to == 0) and ctx.labelLayer and sender.stats and sender.stats.tiles > 0 then
		local b = label({
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.fromOffset(34, 34),
			TextSize = 28,
			Text = emoji,
			ZIndex = 8,
			Parent = ctx.labelLayer,
		})
		bubbles[#bubbles + 1] = { label = b, owner = from, untilT = os.clock() + Emojis.DURATION }
	end
end

local function stepBubbles()
	local now = os.clock()
	local i = 1
	while i <= #bubbles do
		local b = bubbles[i]
		local p = ctx.roster[b.owner]
		if now >= b.untilT or not p or not p.stats.alive then
			b.label:Destroy()
			table.remove(bubbles, i)
		else
			local W, H = ctx.mapSize()
			-- Just above the territory's centre (where the name plate sits).
			b.label.Position = UDim2.new((p.stats.cx + 0.5) / W, 0, (p.stats.cy + 0.5) / H, -18)
			i += 1
		end
	end
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------
function MatchHud.setup(c)
	ctx = c
	gui = c.gui
	buildAttacks(c.stack)
	buildTop()
	buildWin()

	c.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "init" then
			for _, b in bubbles do
				b.label:Destroy()
			end
			table.clear(bubbles)
		end
		if kind == "matchStats" and type(data) == "table" then
			win.matchStats = data -- shown by the win modal's STATS button
		elseif (kind == "phase" and type(data) == "table" and data.phase == "Spawn") or kind == "init" then
			if not (kind == "init" and type(data) == "table" and type(data.phase) == "table" and data.phase.phase == "Ended") then
				win.matchStats = nil -- a new round
			end
		end
		if (kind == "phase" or kind == "init") and type(data) == "table" then
			local ph = if kind == "init" then data.phase else data
			if type(ph) == "table" then
				phaseInfo.phase = ph.phase
				phaseInfo.ticksLeft = ph.ticksLeft or 0
				phaseInfo.at = os.clock()
				phaseInfo.winnerId = ph.winnerId or 0
				phaseInfo.winner = ph.winner
				phaseInfo.winnerTeam = ph.winnerTeam
			end
		elseif kind == "emoji" and type(data) == "table" then
			onEmoji(data)
		end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		stepBubbles()
		acc += dt
		if acc < 0.2 then
			return
		end
		acc = 0
		refreshAttacks()
		refreshTop()
		refreshWin()
	end)
end

return MatchHud
