--[[
	War Front - replay of the last round (record while playing, watch it afterwards).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(client/replay/ReplayControls.ts, hud/layers/ReplayPanel.ts, resources/lang/en.json
	"replay_viewer.*" / "replay_panel.*"). Modified version re-implemented in Luau for Roblox; not
	affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Replay (ModuleScript), used by GameClient, MatchHud and
-- PauseMenu.
--
-- OpenFront replays a finished game by re-running its turns. Our simulation runs on the server, so
-- the client records the round instead: every map message it receives (the "init" snapshot, tile
-- changes, stats, structures, boats, nukes, units, rails, trains...) with its game-clock time.
-- When the round has ended, "Watch replay" plays those messages back through GameClient's own
-- handler while live map messages are held back:
--   * bottom bar (ReplayControls): timeline (sky-400 played fill, white/10 track), m:ss / m:ss,
--     play / pause, speed menu (x0.5 x1 x2 x4 x8 x16 x32), exit.
--   * GameClient's clock (serverNow) follows the replay time, so boats, nukes, trains and build
--     bars move at the replay speed; seeking back restarts from the snapshot and fast-forwards.
--   * The viewer is a spectator (myId 0). A new round that includes us stops the replay.
--   * A recording stops growing past ~48 MB (the rest of the round can't be watched, like
--     OpenFront's "Only the first {time} of this game can be watched").
--
-- Replay.setup(ctx)  ctx.dispatch(kind, data, quiet)  GameClient's net handler
--                    ctx.onStart(), ctx.onStop()       hide / restore match HUD, resync
--                    ctx.gui                           ScreenGui parent for nothing (own gui)
-- Replay.record(kind, data)        every incoming message (GameClient's OnClientEvent)
-- Replay.blocks(kind, data) -> bool  true = hold the live message back (replay playing)
-- Replay.active(), Replay.now() -> number (replay game time), Replay.available() -> bool
-- Replay.start(), Replay.stop()
-- PlayerGui attribute "WFReplay" = true while watching.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SimClock = require(Shared:WaitForChild("SimClock"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))

local Replay = {}

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

-- Messages that draw the match (everything GameClient's handler knows except "me", which is
-- personal, and the lobby vote). Transient ones are skipped while fast-forwarding.
local RECORD = {
	init = true, tiles = true, roster = true, stats = true, structures = true, phase = true,
	boat = true, boatEnd = true, nuke = true, nukeEnd = true, event = true, diplomacy = true,
	units = true, shot = true, conquest = true,
	rails = true, trains = true, trainEnd = true, warheads = true, warheadEnd = true,
	samMissile = true, samMissileEnd = true, shields = true,
}
-- Full snapshots: only the newest one due in a frame is applied.
local SNAPSHOT = { stats = true, units = true, structures = true, roster = true }
-- Effects only worth showing in real time.
local TRANSIENT = { shot = true, conquest = true, event = true, warheads = true, samMissile = true }
local SPEEDS = { 0.5, 1, 2, 4, 8, 16, 32 } -- ReplayControls SPEEDS
local LIMIT_BYTES = 48 * 1024 * 1024
local CATCH_UP_BUDGET = 0.008 -- seconds per frame spent fast-forwarding

local ctx: any = nil
local rec: any = nil -- recording in progress { round, map, events, bytes, t0, t1, playT, done, partial }
local last: any = nil -- the last finished round
local pendingInit: any = nil -- a new round's init, until its Spawn phase arrives { t, data }
local play: any = nil -- { rec, idx, vt, speed, playing, seekTo }

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------
local function sizeOf(v: any, depth: number): number
	local t = typeof(v)
	if t == "buffer" then
		return buffer.len(v)
	elseif t == "string" then
		return #v
	elseif t == "table" then
		local n = 32
		if depth < 3 then
			for _, x in v do
				n += 16 + sizeOf(x, depth + 1)
			end
		end
		return n
	end
	return 8
end

local function finish(r)
	if r and not r.done then
		r.done = true
		r.t1 = if #r.events > 0 then r.events[#r.events][1] else r.t0
		if #r.events > 1 then
			last = r
		end
	end
end

function Replay.record(kind: string, data: any)
	if not RECORD[kind] then
		return
	end
	local t = SimClock.now()
	if kind == "init" then
		if type(data) ~= "table" or type(data.map) ~= "string" then
			return
		end
		local ph = if type(data.phase) == "table" then data.phase else {}
		if rec and not rec.done and rec.round == ph.round and rec.map == data.map then
			return -- a resync of the round being recorded (rejoin, end of a replay)
		end
		if ph.phase ~= "Spawn" and ph.phase ~= "Play" then
			-- The server sends a new round's init just before switching to Spawn, so keep it: the
			-- recording starts from it when the Spawn phase arrives.
			pendingInit = { t, data }
			return
		end
		pendingInit = nil
		finish(rec)
		rec = { round = ph.round, map = data.map, events = {}, bytes = 0, t0 = t, t1 = t, playT = nil, done = false, partial = false }
		if ph.phase == "Play" then
			rec.playT = t - (tonumber(ph.elapsed) or 0)
		end
	elseif kind == "phase" and pendingInit and type(data) == "table" and (data.phase == "Spawn" or data.phase == "Play") and (not rec or rec.done) then
		local it, idata = pendingInit[1], pendingInit[2]
		pendingInit = nil
		finish(rec)
		rec = { round = data.round, map = idata.map, events = { { it, "init", idata } }, bytes = sizeOf(idata, 0), t0 = it, t1 = it, playT = nil, done = false, partial = false }
	elseif not rec or rec.done then
		return
	end
	if kind == "phase" and type(data) == "table" then
		if data.phase == "Play" and not rec.playT then
			rec.playT = t - (tonumber(data.elapsed) or 0)
		end
	end
	if not rec.partial then
		local size = sizeOf(data, 0)
		if rec.bytes + size > LIMIT_BYTES then
			rec.partial = true
		else
			rec.bytes += size
			rec.events[#rec.events + 1] = { t, kind, data }
		end
	end
	if kind == "phase" and type(data) == "table" and (data.phase == "Ended" or data.phase == "Lobby") then
		finish(rec)
	end
end

function Replay.available(): boolean
	return last ~= nil and play == nil
end

function Replay.active(): boolean
	return play ~= nil
end

function Replay.now(): number
	return if play then play.vt else SimClock.now()
end

--------------------------------------------------------------------------------
-- UI (ReplayControls)
--------------------------------------------------------------------------------
local C = MenuKit.C
local SKY400 = Color3.fromRGB(56, 189, 248)
local GRAY800 = Color3.fromRGB(31, 41, 55)

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

local function corner(o: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = o })
end

local ui: any = {}

local function iconButton(icon: string, order: number, parent: Instance): (TextButton, ImageLabel)
	-- p-1 rounded-md hover:bg-white/10, 20 px icon
	local b = make("TextButton", { Size = UDim2.fromOffset(28, 28), BackgroundColor3 = C.WHITE, BackgroundTransparency = 1, AutoButtonColor = false, Text = "", LayoutOrder = order, ZIndex = 3, Parent = parent })
	corner(b, 6)
	local img = IconKit.image(icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), ZIndex = 4, Parent = b })
	MenuKit.hover(b, function(s)
		b.BackgroundTransparency = if s == "idle" then 1 else 0.9
	end)
	return b, img
end

local function fmtTime(seconds: number): string -- formatGameTime
	local total = math.floor(math.max(0, seconds))
	local s, m, h = total % 60, (total // 60) % 60, total // 3600
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

local function buildUI()
	local gui = make("ScreenGui", { Name = "FrontlinesReplay", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 7, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false, Parent = playerGui })
	DeviceLayout.attachScreenGui(gui)
	ui.gui = gui
	-- absolute left-0 right-0 bottom-0 flex items-center gap-4 px-4 py-2 bg-gray-800/92
	local bar = make("Frame", { Name = "ReplayControls", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = GRAY800, BackgroundTransparency = 0.08, BorderSizePixel = 0, Active = true, ZIndex = 2, Parent = gui })
	make("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = bar })
	ui.bar = bar

	-- Right side: time, play / pause, speed, exit (fixed width, laid out from the right).
	local right = make("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, ZIndex = 2, Parent = bar })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = right })
	ui.time = make("TextLabel", { Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, FontFace = MenuKit.F.MEDIUM, TextSize = 14, TextColor3 = C.WHITE, TextTransparency = 0.2, Text = "0:00 / 0:00", LayoutOrder = 1, ZIndex = 3, Parent = right })
	ui.playBtn, ui.playIcon = iconButton("Pause", 2, right)
	ui.speedBtn = iconButton("FastForward", 3, right)
	ui.exitBtn = iconButton("Exit", 4, right)
	ui.right = right

	-- Timeline (flex-1): white/10 track h-1.5 rounded-full, loaded fill zinc-400/60, played sky-400,
	-- 14 px sky-400 thumb.
	local track = make("TextButton", { Name = "Timeline", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, -260, 0, 16), BackgroundTransparency = 1, AutoButtonColor = false, Text = "", ZIndex = 2, Parent = bar })
	local rail = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 3, Parent = track })
	corner(rail, 3)
	ui.loaded = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(161, 161, 170), BackgroundTransparency = 0.4, BorderSizePixel = 0, ZIndex = 3, Parent = rail })
	ui.played = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = SKY400, BorderSizePixel = 0, ZIndex = 4, Parent = rail })
	ui.thumb = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = SKY400, BorderSizePixel = 0, ZIndex = 5, Parent = track })
	corner(ui.thumb, 7)
	ui.track = track

	-- Speed menu: absolute bottom-full right-0 mb-4 p-2 bg-gray-800/92 rounded-lg, "Replay speed",
	-- grid-cols-4 gap-2 of py-0.5 px-1 text-sm rounded-sm border-gray-500 buttons (chosen: malibu).
	local menu = make("Frame", { Name = "SpeedMenu", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -60), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = GRAY800, BackgroundTransparency = 0.08, BorderSizePixel = 0, Active = true, Visible = false, ZIndex = 6, Parent = gui })
	corner(menu, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = menu })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = menu })
	make("TextLabel", { Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, FontFace = MenuKit.F.MEDIUM, TextSize = 16, TextColor3 = C.WHITE, TextXAlignment = Enum.TextXAlignment.Left, Text = "Replay speed", LayoutOrder = 1, ZIndex = 7, Parent = menu }) -- replay_panel.replay_speed
	local grid = make("Frame", { Size = UDim2.fromOffset(4 * 48 + 3 * 8, 2 * 24 + 8), BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 7, Parent = menu })
	make("UIGridLayout", { CellSize = UDim2.fromOffset(48, 24), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	ui.speedButtons = {}
	for i, sp in SPEEDS do
		local b = make("TextButton", { BackgroundColor3 = C.MALIBU, BackgroundTransparency = 1, AutoButtonColor = false, FontFace = MenuKit.F.MEDIUM, TextSize = 14, TextColor3 = C.WHITE, Text = "×" .. tostring(sp), LayoutOrder = i, ZIndex = 8, Parent = grid })
		corner(b, 2)
		local st = make("UIStroke", { Color = Color3.fromRGB(107, 114, 128), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		MenuKit.hover(b, function(s)
			st.Color = if s == "idle" then Color3.fromRGB(107, 114, 128) else Color3.fromRGB(229, 231, 235)
		end)
		b.Activated:Connect(function()
			if play then
				play.speed = sp
			end
			menu.Visible = false
		end)
		ui.speedButtons[sp] = b
	end
	ui.menu = menu

	-- Status line above the bar while preparing a seek ("Preparing this replay…").
	ui.status = make("TextLabel", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -56), Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = GRAY800, BackgroundTransparency = 0.08, FontFace = MenuKit.F.MEDIUM, TextSize = 14, TextColor3 = C.WHITE, Text = "", Visible = false, ZIndex = 6, Parent = gui })
	corner(ui.status, 6)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = ui.status })
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------
local function startT(r): number
	return r.playT or r.t0
end

local function initCopy(data)
	local c = table.clone(data)
	c.myId = 0 -- watch as a spectator
	return c
end

-- Applies events up to time `upTo` (inclusive). Snapshot kinds are coalesced to the newest one;
-- `fast` skips transient effects and sounds. Returns false if the time budget ran out first.
local function applyUntil(upTo: number, fast: boolean, deadline: number?): boolean
	local r = play.rec
	local ev = r.events
	local pending: { [string]: any } = {}
	local pendingAt: { [string]: number } = {}
	local finished = true
	while play.idx <= #ev and ev[play.idx][1] <= upTo do
		local e = ev[play.idx]
		local kind = e[2]
		play.idx += 1
		if SNAPSHOT[kind] then
			pending[kind] = e[3]
			pendingAt[kind] = play.idx
		elseif not (fast and TRANSIENT[kind]) then
			if kind == "init" then
				ctx.dispatch(kind, initCopy(e[3]), true)
			else
				ctx.dispatch(kind, e[3], fast)
			end
		end
		if deadline and os.clock() > deadline then
			finished = false
			break
		end
	end
	-- roster before stats / structures / units
	for _, k in { "roster", "structures", "units", "stats" } do
		if pending[k] then
			ctx.dispatch(k, pending[k], fast)
		end
	end
	return finished
end

local function restartFromSnapshot()
	local r = play.rec
	play.idx = 1
	play.vt = r.t0
	applyUntil(r.t0, true, nil) -- the init snapshot (and anything stamped with the same time)
end

local function refreshUI()
	if not play then
		return
	end
	local r = play.rec
	local s0 = startT(r)
	local total = math.max(0.001, r.t1 - s0)
	local shown = play.seekTo or play.vt
	local frac = math.clamp((shown - s0) / total, 0, 1)
	ui.played.Size = UDim2.fromScale(frac, 1)
	ui.thumb.Position = UDim2.fromScale(frac, 0.5)
	ui.time.Text = fmtTime(shown - s0) .. " / " .. fmtTime(total)
	IconKit.set(ui.playIcon, if play.playing then "Pause" else "Play")
	for sp, b in ui.speedButtons do
		b.BackgroundTransparency = if sp == play.speed then 0 else 1
	end
	ui.status.Visible = play.seekTo ~= nil or r.partial
	if play.seekTo then
		local done = math.clamp((play.vt - r.t0) / math.max(0.001, play.seekTo - r.t0), 0, 1)
		ui.status.Text = string.format("Replaying the game: %d%%", math.floor(done * 100)) -- replay_viewer.processing_simulating
	elseif r.partial then
		ui.status.Text = "Only the first " .. fmtTime(total) .. " of this game can be watched." -- replay_viewer.partial
	end
	-- Timeline width: everything left of the controls.
	ui.track.Size = UDim2.new(1, -(ui.right.AbsoluteSize.X + 16), 0, 16)
end

local function seek(frac: number)
	local r = play.rec
	local s0 = startT(r)
	local target = s0 + math.clamp(frac, 0, 1) * (r.t1 - s0)
	if target < play.vt then
		restartFromSnapshot()
	end
	play.seekTo = target
end

local function step(dt: number)
	if not play then
		return
	end
	local r = play.rec
	if play.seekTo then
		local deadline = os.clock() + CATCH_UP_BUDGET
		local target = play.seekTo
		local ev = r.events
		-- advance vt with the events so the progress shows
		local done = applyUntil(target, true, deadline)
		play.vt = if play.idx <= #ev then math.min(target, ev[math.max(1, play.idx - 1)][1]) else target
		if done then
			play.vt = target
			play.seekTo = nil
		end
	elseif play.playing then
		play.vt = math.min(play.vt + dt * play.speed, r.t1)
		applyUntil(play.vt, play.speed > 8, nil)
		if play.vt >= r.t1 then
			play.playing = false
		end
	end
	refreshUI()
end

local function bindKeys()
	-- Gamepad: B leaves the replay, A play / pause, LB / RB slower / faster.
	ContextActionService:BindActionAtPriority("FrontlinesReplay", function(_n, state, input)
		if state ~= Enum.UserInputState.Begin or not play then
			return Enum.ContextActionResult.Pass
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.ButtonB then
			Replay.stop()
		elseif k == Enum.KeyCode.ButtonA then
			play.playing = not play.playing
		elseif k == Enum.KeyCode.ButtonL1 or k == Enum.KeyCode.ButtonR1 then
			local i = table.find(SPEEDS, play.speed) or 2
			i = math.clamp(i + (if k == Enum.KeyCode.ButtonR1 then 1 else -1), 1, #SPEEDS)
			play.speed = SPEEDS[i]
		else
			return Enum.ContextActionResult.Pass
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 40, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
end

function Replay.start()
	if not last or play then
		return
	end
	play = { rec = last, idx = 1, vt = last.t0, speed = 1, playing = true, seekTo = nil }
	playerGui:SetAttribute("WFReplay", true)
	ctx.onStart()
	restartFromSnapshot()
	-- start where the fighting starts (skip most of the spawn phase)
	if last.playT and last.playT > last.t0 then
		play.seekTo = math.max(last.t0, last.playT - 3)
	end
	ui.gui.Enabled = true
	ui.menu.Visible = false
	bindKeys()
	refreshUI()
end

function Replay.stop()
	if not play then
		return
	end
	play = nil
	playerGui:SetAttribute("WFReplay", false)
	ui.gui.Enabled = false
	ContextActionService:UnbindAction("FrontlinesReplay")
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(ui.gui) then
		GuiService.SelectedObject = nil
	end
	ctx.onStop()
end

-- Live messages while watching: held back, except a new round that includes us (it ends the replay).
function Replay.blocks(kind: string, data: any): boolean
	if not play then
		return false
	end
	if kind == "init" and type(data) == "table" and (tonumber(data.myId) or 0) ~= 0 and type(data.phase) == "table" and data.phase.phase == "Spawn" then
		Replay.stop()
		return false
	end
	return true
end

function Replay.setup(c)
	ctx = c
	buildUI()
	ui.playBtn.Activated:Connect(function()
		if play then
			if not play.playing and play.vt >= play.rec.t1 then
				restartFromSnapshot() -- at the end: play again from the start
				seek(0)
			end
			play.playing = not play.playing
		end
	end)
	ui.speedBtn.Activated:Connect(function()
		ui.menu.Visible = not ui.menu.Visible
	end)
	ui.exitBtn.Activated:Connect(Replay.stop)
	-- Timeline: click or drag to seek (applied on release, like the range input's last value).
	local dragging = false
	local function fracAt(x: number): number
		local a, s = ui.track.AbsolutePosition.X, ui.track.AbsoluteSize.X
		return math.clamp((x - a) / math.max(1, s), 0, 1)
	end
	local function preview(x: number)
		if not play then
			return
		end
		local r = play.rec
		local s0 = startT(r)
		local f = fracAt(x)
		ui.played.Size = UDim2.fromScale(f, 1)
		ui.thumb.Position = UDim2.fromScale(f, 0.5)
		ui.time.Text = fmtTime(f * (r.t1 - s0)) .. " / " .. fmtTime(r.t1 - s0)
	end
	ui.track.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = true
			preview(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			preview(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if dragging and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
			dragging = false
			if play then
				seek(fracAt(input.Position.X))
			end
		end
	end)
	-- Esc leaves; P plays / pauses (keybinds.pauseGame).
	UserInputService.InputBegan:Connect(function(input, processed)
		if not play or processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			Replay.stop()
		elseif input.KeyCode == Enum.KeyCode.P then
			play.playing = not play.playing
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return Replay
