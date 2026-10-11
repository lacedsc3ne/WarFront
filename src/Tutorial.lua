--[[
	War Front - in-match tutorial (Night look, 11 Oct 2026 redesign).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- StarterPlayer.StarterPlayerScripts.Tutorial (ModuleScript), used by GameClient.
-- Owner's brief: clearly explain each step and show what everything does, no walls of text, and
-- the game is paused until the player does what the step asks.
-- Three short chapters (Grow, Build, Fight). Each step is one spotlight on the thing to use, a
-- short title + one line, a bouncing arrow, and the action itself finishes the step (no "Next").
-- "Quick look" picture cards replace the old reading steps. A finished chapter gives a one-time
-- medal reward (server: Progression.tutorialChapter). Optional lessons (How to play page) set
-- PlayerGui attribute FrontlinesTutorialLesson before the tutorial match starts.
-- Pausing: while a step waits for the player the solo game is paused (Net "pause"); it resumes as
-- soon as the player acts, and while saving up gold for a building.
-- Shown while PlayerGui attribute FrontlinesTutorial == true and the player is in a round.
-- Tutorial.create(ctx) -> api   (ctx from GameClient: snapshot(), targets(stepId), canGoTo(kind),
--   goTo(kind), retreat(), onFinish(reason), setPaused(on), chapterDone(chapter), deviceLayout)
-- api.update() a few times a second, api.reset() on a new round, api.reward(data) on
-- "tutorialReward", api.wantsRing(), api.device(), api.frame

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local NightMenu = script.Parent:WaitForChild("NightMenu")
local Kit = require(NightMenu:WaitForChild("Kit"))
local Art = require(NightMenu:WaitForChild("Art"))
local K, F = Kit.C, Kit.F
local make = Kit.make

local Tutorial = {}

local ATTR = "FrontlinesTutorial"
local LESSON_ATTR = "FrontlinesTutorialLesson"
local DONE_LINGER = 1.6 -- seconds the game runs after an action before the next step
local GOLD_ICON = "rbxassetid://122263341747372"

local function fmt(n: number): string
	n = math.floor(n)
	if n >= 1e6 then
		return (string.gsub(string.format("%.1fM", n / 1e6), "%.0M", "M"))
	elseif n >= 1e3 then
		return (string.gsub(string.format("%.1fK", n / 1e3), "%.0K", "K"))
	end
	return tostring(n)
end

local function pick(d, kbm: string, touch: string, pad: string): string
	if d.input == "Gamepad" then
		return pad
	elseif d.mobile then
		return touch
	end
	return kbm
end

local function count(t: any, key: string): number
	return if type(t) == "table" then (tonumber(t[key]) or 0) else 0
end

-- Has the player made their move this step (an attack, a build or a launch was sent)? The game
-- then runs again, so the server can carry it out; the step finishes once it really happened.
local function actedSince(s, e): boolean
	if s.attacksSent > e.attacksSent then
		return true
	end
	for k, v in (s.builds or {}) :: any do
		if v > count(e.builds, k) then
			return true
		end
	end
	return false
end

-- Steps ------------------------------------------------------------------------------------------
-- kind "action": spotlight + bubble; done(s, entry) finishes it. pause = game paused while waiting.
-- build = structure kind: while it isn't affordable the step shows a saving bar and the game runs.
-- kind "look": picture cards with one "Got it" (game paused).
local STEP = {}

STEP.spawn = {
	kind = "action",
	title = "Pick where you start",
	art = "OwnLand",
	line = function(_, d) return pick(d, "Click any green land", "Tap any green land", "Move the cursor and press A on green land") end,
	done = function(s) return s.spawned and s.phase == "Play" end,
	pause = false, -- the spawn phase already waits for you
}
-- Lessons that need the sea (ports, warships): start on the coast.
STEP.spawnCoast = {
	kind = "action",
	title = "Start on the coast",
	art = "Port",
	line = function(_, d) return pick(d, "Click the green land by the sea", "Tap the green land by the sea", "Move the cursor and press A on land by the sea") end,
	done = function(s) return s.spawned and s.phase == "Play" end,
	pause = false,
}
STEP.reachSea = {
	kind = "action",
	title = "Reach the sea",
	art = "SendTroops",
	line = function(_, d) return pick(d, "Click the land between you and the sea", "Tap the land between you and the sea", "Point at the land between you and the sea and press A") end,
	done = function(s) return s.coastal == true end,
	pause = false, -- your land has to grow, so the game keeps running
	fast = true, -- and runs fast, so it doesn't take long
	sendAll = true, -- every troop goes (computer players can't hit back in the tutorial)
	goTo = "home",
	success = "You reached the sea",
}
-- Shown instead of a building step while there's no room left to build on.
STEP.growLand = {
	kind = "action",
	title = "Grab more land",
	art = "OwnLand",
	targetId = "growLand",
	line = function(_, d) return pick(d, "Buildings need space. Click the land next to you", "Buildings need space. Tap the land next to you", "Buildings need space. Press A on the land next to you") end,
	done = function() return false end,
	pause = false,
	fast = true,
}
STEP.expand = {
	kind = "action",
	title = "Grab free land",
	art = "SendTroops",
	line = function(_, d) return pick(d, "Click the free land next to you", "Tap the free land next to you", "Point at the free land next to you and press A") end,
	done = function(s, e) return (s.attacking and s.attacksSent > e.attacksSent) or s.tiles > e.tiles + 4 end, -- a real attack, not just a click
	pause = true,
	labels = true, -- "This is you" / "Free land" on the map
	success = "Your troops are taking it",
}
STEP.ratio = {
	kind = "action",
	title = "How many troops to send",
	art = "Troops",
	line = function(_, d) return pick(d, "Drag the slider (or press T / Y)", "Drag the slider", "Press LB / RB") end,
	done = function(s, e) return s.ratioMoves > e.ratioMoves end,
	pause = true,
	live = function(s) return string.format("%d%% = %s troops", math.floor(s.ratio * 100 + 0.5), s.sendText or fmt(s.troops * s.ratio)) end,
	success = "Bigger attacks take land faster",
}
STEP.look_basics = {
	kind = "look",
	cards = {
		{ art = "Troops", title = "Troops grow", line = "By themselves, every second" },
		{ image = GOLD_ICON, title = "Gold comes in", line = "Spend it on buildings" },
		{ art = "OwnLand", title = "More land", line = "More troops and more gold" },
	},
}
STEP.city = {
	kind = "action",
	build = "City",
	title = "Build a City",
	line = function(_, d) return pick(d, "Pick City, then click your land", "Tap City, then tap your land", "Press Y, pick City, then press A on your land") end,
	key = "1",
	done = function(s, e) return count(s.counts, "City") > count(e.counts, "City") end,
	pause = true,
	goTo = "home",
	needsRoom = true,
	success = "City built: room for more troops",
}
STEP.defense = {
	kind = "action",
	build = "DefensePost",
	title = "Build a Defense Post",
	line = function() return "Land near it is much harder to take" end,
	key = "4",
	done = function(s, e) return count(s.counts, "DefensePost") > count(e.counts, "DefensePost") end,
	pause = true,
	goTo = "home",
	needsRoom = true,
	success = "Defense Post built",
}
STEP.look_build = {
	kind = "look",
	cards = {
		{ art = "Port", title = "Ports", line = "On your coast. Trade ships earn gold" },
		{ art = "Factory", title = "Factories", line = "Trains bring in more gold" },
		{ art = "MissileSilo", title = "Missile Silo", line = "Needed to launch nukes" },
	},
}
STEP.players = {
	kind = "action",
	title = "Attack a player",
	art = "BeatPlayers",
	line = function(_, d) return pick(d, "Click a neighbour's land", "Tap a neighbour's land", "Point at a neighbour's land and press A") end,
	done = function(s, e) return s.attackingPlayer and (s.playerAttacksSent > e.playerAttacksSent or not e.attackingPlayer) end, -- the server accepted it
	pause = true,
	goTo = "enemy",
	enemyLabel = true, -- "Another player" on their land
	waitFor = function(s) return if s.protected then "Everyone is protected for a few seconds" else nil end,
	success = "Attack sent",
}
STEP.cancel = {
	kind = "action",
	title = "Pull your troops back",
	line = function() return "Press Retreat on your attack" end,
	done = function(s, e) return s.cancelMoves > e.cancelMoves end,
	pause = true,
	skipIf = function(s) return not s.attacking end, -- nothing to pull back
	success = "Troops coming home",
}
STEP.look_fight = {
	kind = "look",
	cards = {
		{ art = "AllyRequest", title = "Make allies", line = "Right-click a player (hold on phone)" },
		{ art = "AtomBomb", title = "Nukes", line = "Hit anyone. SAM Launchers stop them" },
		{ art = "YouWon", title = "Win", line = "Own 80% of the land" },
	},
}
-- Lesson-only steps
STEP.port = {
	kind = "action",
	build = "Port",
	title = "Build a Port",
	line = function() return "Only on your coast, next to the sea" end,
	key = "3",
	done = function(s, e) return count(s.counts, "Port") > count(e.counts, "Port") end,
	pause = true,
	goTo = "home",
	success = "Port built: trade ships earn gold",
}
-- Warships lesson: a Port is needed first, but if you already have one (e.g. straight after the
-- Ports lesson) the step is skipped instead of asking for a second Port.
STEP.warshipPort = table.clone(STEP.port)
STEP.warshipPort.line = function() return "Warships need a Port. Build one on your coast" end
STEP.warshipPort.skipIf = function(s) return count(s.counts, "Port") > 0 end
STEP.warships = {
	kind = "action",
	build = "Warship",
	title = "Build a Warship",
	line = function(_, d) return pick(d, "Pick Warship, then click the sea by your Port", "Tap Warship, then tap the sea by your Port", "Pick Warship, then press A on the sea by your Port") end,
	key = "7",
	done = function(s, e) return count(s.counts, "Warship") > count(e.counts, "Warship") end,
	pause = true,
	goTo = "home",
	success = "Warship on its way",
}
STEP.nukes = {
	kind = "action",
	build = "MissileSilo",
	title = "Build a Missile Silo",
	line = function() return "You need one to launch nukes" end,
	key = "5",
	done = function(s, e) return count(s.counts, "MissileSilo") > count(e.counts, "MissileSilo") end,
	pause = true,
	goTo = "home",
	needsRoom = true,
	success = "Silo built",
}
STEP.bomb = {
	kind = "action",
	build = "AtomBomb",
	title = "Launch an Atom Bomb",
	line = function(_, d) return pick(d, "Pick Atom Bomb, then click enemy land", "Tap Atom Bomb, then tap enemy land", "Pick Atom Bomb, then press A on enemy land") end,
	key = "8",
	done = function(s, e) return s.bombsLaunched > e.bombsLaunched end,
	waitFor = function(s) return if s.protected then "Everyone is protected for a few seconds" elseif s.siloReady then nil else "Your silo is getting ready" end,
	pause = true,
	goTo = "enemy",
	success = "Bomb away",
}
STEP.look_allies = {
	kind = "look",
	cards = {
		{ art = "AllyRequest", title = "Ask to be allies", line = "Right-click a player (hold on phone)" },
		{ art = "FreeRevive", title = "Allies are safe", line = "You can't attack each other" },
		{ art = "Defeated", title = "Don't betray", line = "Breaking it makes you a traitor" },
	},
}
STEP.look_sam = {
	kind = "look",
	cards = {
		{ art = "SAM", title = "SAM Launcher", line = "Shoots down nukes near it" },
		{ art = "HydrogenBomb", title = "Hydrogen Bomb", line = "A much bigger blast" },
		{ art = "MIRV", title = "MIRV", line = "Many warheads on one player" },
	},
}
STEP.look_boosts = {
	kind = "look",
	cards = {
		{ art = "Boosts", title = "Boosts", line = "Top right in every battle" },
		{ product = 3716871545, title = "Gold crate", line = "Gold right away" },
		{ product = 3716871574, title = "Reinforcements", line = "More troops now" },
	},
}

local CHAPTERS = {
	{ key = "grow", name = "Grow", icon = "MapPin", art = "OwnLand", color = K.GREEN, time = "60 s", sub = "Start, grab land, send troops", steps = { "spawn", "expand", "ratio", "look_basics" } },
	{ key = "build", name = "Build", icon = "Building", art = "BuildCities", color = K.YELLOW, time = "40 s", sub = "Cities and defense", steps = { "city", "defense", "look_build" } },
	-- (no "cancel" step: the Night battle screen has no Retreat list to point at)
	{ key = "fight", name = "Fight", icon = "Swords", art = "BeatPlayers", color = K.PINK, time = "30 s", sub = "Attack other players", steps = { "players", "look_fight" } },
}
-- Optional lessons (How to play page). Every lesson starts by picking a spot.
Tutorial.LESSONS = {
	{ key = "ports", name = "Ports and trade", art = "Port", time = "40 s", steps = { "spawnCoast", "reachSea", "port" } },
	{ key = "warships", name = "Warships", art = "Warship", time = "40 s", steps = { "spawnCoast", "reachSea", "warshipPort", "warships" } },
	{ key = "allies", name = "Allies", art = "AllyRequest", time = "20 s", steps = { "spawn", "look_allies" } },
	{ key = "nukes", name = "Nukes and SAM", art = "AtomBomb", time = "60 s", steps = { "spawn", "nukes", "bomb", "look_sam" } },
	{ key = "boosts", name = "Boosts", art = "Boosts", time = "20 s", steps = { "spawn", "look_boosts" } },
}
Tutorial.CHAPTERS = CHAPTERS

function Tutorial.create(ctx)
	local api = {}
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local DeviceLayout = ctx.deviceLayout

	-- State
	local stage = "welcome" -- "welcome" | "steps" | "chapter" | "finished"
	local chapterIndex = 1
	local lesson = nil -- Tutorial.LESSONS entry when a lesson is running
	local steps: { string } = {}
	local index = 1
	local entry = nil
	local doneAt: number? = nil
	local pausedByUs = false
	local lastPauseAsk = 0
	local fastForward = false -- game sped up while saving gold
	local reward: number? = nil
	local savedRatio: number? = nil -- send % before a "send all" step
	local shortSince: number? = nil -- when this step started saving up
	local toppedUp = false -- gold already topped up this step
	local zoomedIn = false -- camera already moved to the new land this step

	-- UI ------------------------------------------------------------------------------------------
	local gui = make("ScreenGui", { Name = "NightTutorial", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 40, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false, Parent = playerGui })
	local masks = {}
	local function mask(i: number): Frame
		if not masks[i] then
			masks[i] = make("Frame", { Name = "Shade", BackgroundColor3 = K.BACKDROP, BackgroundTransparency = 0.45, BorderSizePixel = 0, Active = false, ZIndex = 1, Parent = gui })
		end
		return masks[i]
	end

	-- Progress pill (top centre): chapter name, dots, "n of m", Skip.
	local pill = Kit.card({ Name = "Progress", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 10, Parent = gui })
	pill:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
	Kit.pad(pill, 16, 10)
	Kit.list(pill, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local pillName = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 16, LayoutOrder = 1, ZIndex = 11, Parent = pill })
	local dotsRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 10), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 11, Parent = pill })
	Kit.list(dotsRow, true, 5, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local pillCount = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 13, TextColor3 = K.MUTED, LayoutOrder = 3, ZIndex = 11, Parent = pill })
	local skip = make("TextButton", { Name = "TutorialSkip", Text = "Skip", FontFace = F.BOLD, TextSize = 13, TextColor3 = K.MUTED, BackgroundTransparency = 1, Size = UDim2.fromOffset(40, 24), LayoutOrder = 4, ZIndex = 11, Parent = pill })
	local dots = {}

	-- Coach bubble: title, one line, extras (live readout / key / saving bar).
	local bubble = Kit.card({ Name = "Coach", Size = UDim2.fromOffset(290, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 10, Parent = gui })
	bubble:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 14)
	Kit.pad(bubble, 14, 14, 11, 12)
	Kit.list(bubble, false, 4)
	local head = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, ZIndex = 11, Parent = bubble })
	Kit.list(head, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local bIcon = Art.image(nil, { Size = UDim2.fromOffset(48, 48), LayoutOrder = 1, ZIndex = 11, Parent = head })
	local textCol = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -58, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, ZIndex = 11, Parent = head })
	Kit.list(textCol, false, 2)
	local bTitle = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 19, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, ZIndex = 11, Parent = textCol })
	local bLine = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 15, TextColor3 = K.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2, ZIndex = 11, Parent = textCol })
	local extras = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, ZIndex = 11, Parent = bubble })
	Kit.list(extras, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center, Wraps = true })
	-- A pill that always fits its text: a padded frame that grows around an auto-sized label.
	local function pillLabel(parent: Instance, text: string, bg: Color3, fg: Color3, size: number, z: number): (Frame, TextLabel)
		local f = make("Frame", { BackgroundColor3 = bg, BorderSizePixel = 0, Size = UDim2.fromOffset(0, size + 12), AutomaticSize = Enum.AutomaticSize.X, ZIndex = z, Parent = parent })
		Kit.corner(f)
		make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = f })
		local l = Kit.text({ Text = text, FontFace = F.TITLE, TextSize = size, TextColor3 = fg, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, ZIndex = z + 1, Parent = f })
		return f, l
	end
	local function chip(bg: Color3, fg: Color3, order: number): (Frame, TextLabel)
		local f, l = pillLabel(extras, "", bg, fg, 14, 12)
		f.LayoutOrder = order
		f.Visible = false
		return f, l
	end
	local liveChip, liveText = chip(K.DEEP, K.TEXT, 1)
	local keyChip, keyText = chip(K.YELLOW, K.YELLOW_TEXT, 2)
	local saving = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 3, Visible = false, ZIndex = 11, Parent = extras })
	local savingText = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 14, TextColor3 = K.YELLOW, Position = UDim2.fromOffset(26, 0), ZIndex = 12, Parent = saving })
	make("ImageLabel", { Image = GOLD_ICON, BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Size = UDim2.fromOffset(20, 20), ZIndex = 12, Parent = saving })
	local savingTrack = make("Frame", { BackgroundColor3 = K.DEEP, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 7), ZIndex = 12, Parent = saving })
	Kit.corner(savingTrack)
	local savingFill = make("Frame", { BackgroundColor3 = K.YELLOW, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 13, Parent = savingTrack })
	Kit.corner(savingFill)
	api.frame = bubble

	-- Ring + bouncing arrow on the target.
	local ring = make("Frame", { Name = "Ring", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, ZIndex = 9, Parent = gui })
	Kit.corner(ring)
	local ringStroke = Kit.stroke(ring, K.YELLOW, 3)
	-- Dim everything but the target: a see-through frame shaped like the ring with a huge dark stroke.
	local spot = make("Frame", { Name = "Spot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Active = false, Visible = false, ZIndex = 1, Parent = gui })
	local spotCorner = make("UICorner", { CornerRadius = UDim.new(0, 14), Parent = spot })
	make("UIStroke", { Color = K.BACKDROP, Transparency = 0.45, Thickness = 4000, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = spot })
	local arrow = Kit.icon("ChevronDown", { Name = "Arrow", AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(40, 40), ImageColor3 = K.YELLOW, Visible = false, ZIndex = 12, Parent = gui })

	-- Map labels.
	local function mapLabel(text: string, bg: Color3, fg: Color3): Frame
		local f = pillLabel(gui, text, bg, fg, 15, 8)
		f.AnchorPoint = Vector2.new(0.5, 1)
		f.Visible = false
		return f
	end
	local youLabel = mapLabel("This is you", K.PURPLE, Color3.fromRGB(30, 16, 70))
	local freeLabel = mapLabel("Free land", K.GREEN, K.GREEN_TEXT)
	local enemyLabel = mapLabel("Another player", K.PINK, Color3.fromRGB(70, 10, 24))

	-- Success pop.
	local pop = Kit.card({ Name = "Success", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(0, 44), AutomaticSize = Enum.AutomaticSize.X, Visible = false, ZIndex = 20, Parent = gui })
	pop:FindFirstChildWhichIsA("UIStroke").Color = K.GREEN
	Kit.pad(pop, 14, 18, 0, 0)
	Kit.list(pop, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon("CheckCircle", { Size = UDim2.fromOffset(22, 22), ImageColor3 = K.GREEN, LayoutOrder = 1, ZIndex = 21, Parent = pop })
	local popText = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 16, LayoutOrder = 2, ZIndex = 21, Parent = pop })

	-- Full-screen modal (welcome, quick look, chapter done): blocks clicks to the map.
	local modal = make("TextButton", { Name = "Modal", Text = "", AutoButtonColor = false, BackgroundColor3 = K.BACKDROP, BackgroundTransparency = 0.3, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 30, Parent = gui })
	local modalBody = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, ZIndex = 31, Parent = modal })
	Kit.list(modalBody, false, 14, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local modalScale = Instance.new("UIScale")
	modalScale.Parent = modalBody
	local function clearModal()
		for _, c in modalBody:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
	end

	local function device()
		local verb = DeviceLayout.verb()
		local st = DeviceLayout.state
		local mobile = st.touch and (st.profile == "phone" or st.profile == "tablet")
		return { verb = if mobile then "Tap" else verb, input = if mobile then "Touch" else st.input, mobile = mobile, phone = st.profile == "phone" }
	end
	api.device = device

	-- Pause --------------------------------------------------------------------------------------
	local function wantPause(on: boolean, s)
		if not ctx.setPaused or s.phase ~= "Play" then
			return
		end
		if on ~= s.paused and os.clock() - lastPauseAsk > 0.6 then
			lastPauseAsk = os.clock()
			ctx.setPaused(on)
		end
		pausedByUs = on or (pausedByUs and s.paused)
	end
	local function wantFast(on: boolean)
		if on ~= fastForward and ctx.setSpeed then
			fastForward = on
			ctx.setSpeed(if on then 6 else 1)
		end
	end
	local function release()
		if pausedByUs and ctx.setPaused then
			ctx.setPaused(false)
		end
		pausedByUs = false
		wantFast(false)
	end

	-- Flow ---------------------------------------------------------------------------------------
	local function stepDef(): any
		return STEP[steps[index]]
	end
	local function finish(reason: string)
		release()
		if savedRatio and ctx.setRatio then
			ctx.setRatio(savedRatio)
			savedRatio = nil
		end
		stage = "finished"
		modal.Visible = false
		gui.Enabled = false
		if ctx.onFinish then
			ctx.onFinish(reason)
		end
		playerGui:SetAttribute(LESSON_ATTR, nil)
		playerGui:SetAttribute(ATTR, false)
	end
	local function startStep(i: number)
		index = i
		doneAt = nil
		shortSince, toppedUp, zoomedIn = nil, false, false
		if ctx.clearMode then
			ctx.clearMode() -- leave build mode, so this step's click isn't another building
		end
		entry = ctx.snapshot()
		playerGui:SetAttribute("FrontlinesTutorialStep", steps[index] or "finished")
		local def = stepDef()
		-- "send all" lasts one step: then the player's own send % comes back
		if savedRatio and ctx.setRatio and not (def and def.sendAll) then
			ctx.setRatio(savedRatio)
			savedRatio = nil
		end
		if steps[index] == "bomb" and ctx.requestBombTarget then
			ctx.requestBombTarget() -- an enemy builds a City to bomb
		end
		if def and def.sendAll and ctx.setRatio then
			savedRatio = savedRatio or (entry and entry.ratio)
			ctx.setRatio(1)
		end
		if def and def.goTo and ctx.canGoTo(def.goTo) then
			ctx.goTo(def.goTo)
		end
		for i2, d in dots do
			d.BackgroundColor3 = if i2 < index then K.GREEN elseif i2 == index then K.YELLOW else K.LINE
		end
		pillCount.Text = index .. " of " .. #steps
	end
	local showModal -- forward
	local function startChapter(i: number)
		chapterIndex = i
		local ch = CHAPTERS[i]
		steps = ch.steps
		pillName.Text = ch.name
		for _, d in dots do d:Destroy() end
		table.clear(dots)
		for n = 1, #steps do
			local d = make("Frame", { BackgroundColor3 = K.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(9, 9), LayoutOrder = n, ZIndex = 12, Parent = dotsRow })
			Kit.corner(d)
			dots[n] = d
		end
		stage = "steps"
		startStep(1)
	end
	local function startLesson(l)
		lesson = l
		steps = l.steps
		pillName.Text = l.name
		for _, d in dots do d:Destroy() end
		table.clear(dots)
		for n = 1, #steps do
			local d = make("Frame", { BackgroundColor3 = K.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(9, 9), LayoutOrder = n, ZIndex = 12, Parent = dotsRow })
			Kit.corner(d)
			dots[n] = d
		end
		stage = "steps"
		startStep(1)
	end
	local function nextStep()
		if index < #steps then
			startStep(index + 1)
			return
		end
		-- chapter / lesson finished
		reward = nil
		if not lesson and ctx.chapterDone then
			ctx.chapterDone(CHAPTERS[chapterIndex].key)
		end
		stage = "chapter"
		showModal("chapter")
	end

	-- Modals --------------------------------------------------------------------------------------
	local function bigButton(kind: string, text: string, order: number, parent: Instance, fn: () -> ()): TextButton
		return Kit.button(kind, text, { height = 46, textSize = 18, layoutOrder = order, parent = parent, onActivated = fn })
	end
	local function focus(b: GuiObject?)
		if b and device().input == "Gamepad" then
			task.defer(function()
				if b.Parent and b.Visible then
					GuiService.SelectedObject = b
				end
			end)
		end
	end
	function showModal(kind: string)
		clearModal()
		modal.Visible = true
		local first: GuiObject? = nil
		if kind == "welcome" then
			local card = Kit.card({ Size = UDim2.fromOffset(440, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, ZIndex = 32, Parent = modalBody })
			card:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 18)
			Kit.pad(card, 24, 24, 22, 22)
			Kit.list(card, false, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
			if lesson then
				Art.image(lesson.art, { Size = UDim2.fromOffset(84, 84), LayoutOrder = 1, ZIndex = 33, Parent = card })
				Kit.text({ Text = lesson.name, FontFace = F.TITLE, TextSize = 26, LayoutOrder = 2, ZIndex = 33, Parent = card })
				Kit.text({ Text = "A short lesson, about " .. lesson.time, FontFace = F.BOLD, TextSize = 15, TextColor3 = K.MUTED, LayoutOrder = 3, ZIndex = 33, Parent = card })
			else
				Kit.text({ Text = "Learn War Front in 2 minutes", FontFace = F.TITLE, TextSize = 26, LayoutOrder = 1, ZIndex = 33, Parent = card })
				Kit.text({ Text = "Play along. Every step is one thing to do.", FontFace = F.BOLD, TextSize = 15, TextColor3 = K.MUTED, LayoutOrder = 2, ZIndex = 33, Parent = card })
				local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 3, ZIndex = 33, Parent = card })
				Kit.list(row, true, 10)
				for i, ch in CHAPTERS do
					local c = make("Frame", { BackgroundColor3 = K.RAISED, BorderSizePixel = 0, Size = UDim2.fromOffset(110, 92), LayoutOrder = i, ZIndex = 34, Parent = row })
					Kit.corner(c, 12)
					Art.image(ch.art, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(38, 38), ZIndex = 35, Parent = c })
					Kit.text({ Text = i .. "  " .. ch.name, FontFace = F.TITLE, TextSize = 17, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 44), ZIndex = 35, Parent = c })
					Kit.text({ Text = ch.time, FontFace = F.BOLD, TextSize = 12, TextColor3 = K.MUTED, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 66), ZIndex = 35, Parent = c })
				end
			end
			first = bigButton("primary", "Start", 5, card, function()
				modal.Visible = false
				-- Studio test shortcut: PlayerGui attribute WFTutorialStartChapter = 2 / 3 jumps ahead.
				local jump = game:GetService("RunService"):IsStudio() and tonumber(playerGui:GetAttribute("WFTutorialStartChapter")) or nil
				if lesson then startLesson(lesson) else startChapter(if jump and CHAPTERS[jump] then jump else 1) end
				api.update()
			end)
			first.Name = "TutorialStart"
			local later = make("TextButton", { Name = "TutorialKnowHow", Text = if lesson then "Not now" else "I know how to play", FontFace = F.BOLD, TextSize = 14, TextColor3 = K.MUTED, BackgroundTransparency = 1, Size = UDim2.fromOffset(200, 26), LayoutOrder = 6, ZIndex = 33, Parent = card })
			later.Activated:Connect(function()
				finish("skipped")
			end)
		elseif kind == "look" then
			local def = stepDef()
			local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 1, ZIndex = 32, Parent = modalBody })
			Kit.list(row, true, 12, { Wraps = true, HorizontalAlignment = Enum.HorizontalAlignment.Center })
			for i, c in def.cards do
				-- same height for every card, whether its line wraps or not
				local card = Kit.card({ Size = UDim2.fromOffset(196, 176), LayoutOrder = i, ZIndex = 33, Parent = row })
				card:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 16)
				Kit.pad(card, 14, 14, 16, 16)
				Kit.list(card, false, 6, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
				if c.art then
					Art.image(c.art, { Size = UDim2.fromOffset(64, 64), LayoutOrder = 1, ZIndex = 34, Parent = card })
				elseif c.product then
					Kit.corner(Art.product(c.product, { Size = UDim2.fromOffset(64, 64), LayoutOrder = 1, ZIndex = 34, Parent = card }), 14)
				else
					make("ImageLabel", { Image = c.image, BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Size = UDim2.fromOffset(64, 64), LayoutOrder = 1, ZIndex = 34, Parent = card })
				end
				Kit.text({ Text = c.title, FontFace = F.TITLE, TextSize = 19, LayoutOrder = 2, ZIndex = 34, Parent = card })
				Kit.text({ Text = c.line, FontFace = F.BOLD, TextSize = 14, TextColor3 = K.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 34, LayoutOrder = 3, Parent = card })
			end
			first = bigButton("primary", "Got it", 2, modalBody, function()
				modal.Visible = false
				nextStep()
				api.update()
			end)
			first.Name = "TutorialGotIt"
		elseif kind == "chapter" then
			local card = Kit.card({ Size = UDim2.fromOffset(420, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, ZIndex = 32, Parent = modalBody })
			card:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 18)
			Kit.pad(card, 24, 24, 20, 22)
			Kit.list(card, false, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
			Art.image("YouWon", { Size = UDim2.fromOffset(84, 84), LayoutOrder = 1, ZIndex = 33, Parent = card })
			local nextLesson = nil
			if lesson then
				for i, l in Tutorial.LESSONS do
					if l == lesson then nextLesson = Tutorial.LESSONS[i + 1] end
				end
			elseif chapterIndex >= #CHAPTERS then
				nextLesson = Tutorial.LESSONS[1]
			end
			local last = lesson ~= nil or chapterIndex >= #CHAPTERS
			Kit.text({ Text = if lesson then lesson.name .. ": done" elseif last then "Training done" else CHAPTERS[chapterIndex].name .. ": done", FontFace = F.TITLE, TextSize = 26, LayoutOrder = 2, ZIndex = 33, Parent = card })
			local rewardChip = Kit.chip("…", { name = "Reward", icon = "Medal", iconColor = K.YELLOW, textColor = K.YELLOW, height = 32, layoutOrder = 3, parent = card })
			rewardChip.Visible = false
			api._rewardChip = rewardChip
			if reward and reward > 0 then
				rewardChip.Visible = true
				local t = rewardChip:FindFirstChildWhichIsA("TextLabel", true)
				if t then t.Text = "+" .. reward .. " medals" end
			end
			if not last or nextLesson then
				local nextCh = if not last then CHAPTERS[chapterIndex + 1] else { art = nextLesson.art, name = nextLesson.name, sub = "Short lesson, about " .. nextLesson.time }
				local nx = make("Frame", { BackgroundColor3 = K.RAISED, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 58), LayoutOrder = 4, ZIndex = 33, Parent = card })
				Kit.corner(nx, 12)
				Art.image(nextCh.art, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(36, 36), ZIndex = 34, Parent = nx })
				Kit.text({ Text = "Next: " .. nextCh.name, FontFace = F.TITLE, TextSize = 17, Position = UDim2.fromOffset(54, 9), ZIndex = 34, Parent = nx })
				Kit.text({ Text = nextCh.sub, FontFace = F.BOLD, TextSize = 13, TextColor3 = K.MUTED, Position = UDim2.fromOffset(54, 31), ZIndex = 34, Parent = nx })
			else
				Kit.text({ Text = if lesson then "More lessons are in How to play." else "You know the basics. More lessons are in How to play.", FontFace = F.BOLD, TextSize = 14, TextColor3 = K.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, ZIndex = 33, Parent = card })
			end
			local buttons = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 46), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 5, ZIndex = 33, Parent = card })
			Kit.list(buttons, true, 10)
			if not last or nextLesson then
				first = bigButton("primary", if not last then "Next chapter" else "Next lesson", 1, buttons, function()
					modal.Visible = false
					if not last then startChapter(chapterIndex + 1) else startLesson(nextLesson) end
					api.update()
				end)
				first.Name = "TutorialNextChapter"
				local keep = bigButton("secondary", "Keep playing", 2, buttons, function()
					finish("completed")
				end)
				keep.Name = "TutorialKeepPlaying"
			else
				first = bigButton("primary", "Keep playing", 1, buttons, function()
					finish("completed")
				end)
				first.Name = "TutorialKeepPlaying"
			end
		end
		local size = gui.AbsoluteSize
		modalScale.Scale = math.clamp(math.min(size.X / 760, size.Y / 520), 0.6, 1.2)
		focus(first)
	end

	function api.reward(data)
		reward = type(data) == "table" and tonumber(data.medals) or 0
		local c = api._rewardChip
		if c and c.Parent and reward > 0 then
			c.Visible = true
			local t = c:FindFirstChildWhichIsA("TextLabel", true)
			if t then t.Text = "+" .. reward .. " medals" end
		end
	end

	-- Layout helpers -------------------------------------------------------------------------------
	local function rectOf(target: GuiObject): (Vector2, Vector2)
		return target.AbsolutePosition - gui.AbsolutePosition, target.AbsoluteSize
	end
	local function shade(holes)
		local size = gui.AbsoluteSize
		local regions = { { 0, 0, size.X, size.Y } }
		for _, hole in holes do
			local remaining = {}
			for _, r in regions do
				local x1, y1 = math.max(r[1], hole[1]), math.max(r[2], hole[2])
				local x2, y2 = math.min(r[3], hole[3]), math.min(r[4], hole[4])
				if x2 <= x1 or y2 <= y1 then
					table.insert(remaining, r)
				else
					for _, part in { { r[1], r[2], r[3], y1 }, { r[1], y2, r[3], r[4] }, { r[1], y1, x1, y2 }, { x2, y1, r[3], y2 } } do
						if part[3] > part[1] and part[4] > part[2] then
							table.insert(remaining, part)
						end
					end
				end
			end
			regions = remaining
		end
		for i, r in regions do
			local m = mask(i)
			m.Visible = true
			-- whole pixels, so neighbouring shade pieces don't leave thin bright seams
			local x1, y1, x2, y2 = math.floor(r[1]), math.floor(r[2]), math.floor(r[3]), math.floor(r[4])
			m.Position = UDim2.fromOffset(x1, y1)
			m.Size = UDim2.fromOffset(x2 - x1, y2 - y1)
		end
		for i = #regions + 1, #masks do
			masks[i].Visible = false
		end
	end
	local function hideShade()
		spot.Visible = false
		for _, m in masks do
			m.Visible = false
		end
	end

	local function visibleTarget(t: any): boolean
		if typeof(t) ~= "Instance" or not t:IsA("GuiObject") or t.AbsoluteSize.X <= 0 then
			return false
		end
		local v: Instance? = t
		while v and v:IsA("GuiObject") do
			if not v.Visible then
				return false
			end
			v = v.Parent
		end
		local sg = t:FindFirstAncestorWhichIsA("ScreenGui")
		return sg == nil or sg.Enabled
	end

	-- Update ----------------------------------------------------------------------------------------
	local function active(): boolean
		return playerGui:GetAttribute(ATTR) == true and playerGui:GetAttribute("FrontlinesMenuOpen") ~= true
	end

	function api.wantsRing(): boolean
		return false
	end

	function api.update()
		-- Outside a tutorial, skip the snapshot: it scans the map for the tutorial's checks and
		-- this runs 5 times a second in every battle.
		if not active() or stage == "finished" then
			gui.Enabled = false
			hideShade()
			release()
			return
		end
		local s = ctx.snapshot()
		local show = s.inRound and s.alive
		gui.Enabled = show
		if not show then
			hideShade()
			release()
			return
		end
		local d = device()
		local size = gui.AbsoluteSize
		-- Progress pill where the win card normally is (hidden in the tutorial); pop-ups and the
		-- bubble stay below the "Protected" pill.
		local topY = 8
		local lowY = 130
		pill.Position = UDim2.new(0.5, 0, 0, topY)
		pill.Visible = stage == "steps"

		if stage == "welcome" then
			if not modal.Visible then
				showModal("welcome")
			end
			bubble.Visible, ring.Visible, arrow.Visible, youLabel.Visible, freeLabel.Visible, enemyLabel.Visible, spot.Visible = false, false, false, false, false, false, false
			hideShade()
			return
		end
		if stage == "chapter" then
			wantPause(true, s)
			bubble.Visible, ring.Visible, arrow.Visible, youLabel.Visible, freeLabel.Visible, enemyLabel.Visible, spot.Visible = false, false, false, false, false, false, false
			hideShade()
			return
		end

		local def = stepDef()
		if not def then
			nextStep()
			return
		end
		if def.kind == "look" then
			wantPause(true, s)
			if not modal.Visible then
				showModal("look")
			end
			bubble.Visible, ring.Visible, arrow.Visible, youLabel.Visible, freeLabel.Visible, enemyLabel.Visible, spot.Visible = false, false, false, false, false, false, false
			hideShade()
			return
		end

		-- Action step
		if doneAt then
			wantPause(false, s)
			wantFast(false)
			if os.clock() - doneAt >= DONE_LINGER then
				pop.Visible = false
				nextStep()
			end
			bubble.Visible, ring.Visible, arrow.Visible, youLabel.Visible, freeLabel.Visible, enemyLabel.Visible, spot.Visible = false, false, false, false, false, false, false
			hideShade()
			return
		end
		-- Picked a start: zoom in on the new land right away, so it's easy to see.
		if (steps[index] == "spawn" or steps[index] == "spawnCoast") and s.spawned and not zoomedIn then
			zoomedIn = true
			if ctx.canGoTo and ctx.canGoTo("home") then
				ctx.goTo("home")
			end
		end
		if def.skipIf and def.skipIf(s) then
			nextStep()
			return
		end
		if def.done(s, entry) then
			doneAt = os.clock()
			if def.success then
				popText.Text = def.success
				pop.Visible = true
				pop.Position = UDim2.new(0.5, 0, 0, lowY)
			end
			wantPause(false, s)
			return
		end

		-- No room to build: grab more land first (shown in place of this step).
		if def.needsRoom and s.roomToBuild == false then
			def = STEP.growLand
		end

		-- Waiting for the player: saving up / silo reload keeps the game running.
		local cost = def.build and (tonumber(s.costs[def.build]) or 0) or 0
		local short = def.build and cost > 0 and s.gold < cost
		local waitText = def.waitFor and def.waitFor(s)
		wantPause(def.pause and not short and not waitText and not actedSince(s, entry), s)
		wantFast(short or waitText ~= nil or def.fast == true) -- saving up / reloading / growing goes by quickly
		-- Saving up never takes long: after a few seconds the rest of the gold is given.
		if short then
			shortSince = shortSince or os.clock()
			if not toppedUp and os.clock() - shortSince > 5 and ctx.topUpGold then
				toppedUp = true
				ctx.topUpGold(def.build)
			end
		end

		bTitle.Text = if short then "Save up for: " .. def.title:gsub("^Build an? ", ""):gsub("^Launch an? ", "") elseif waitText then def.title else def.title
		local artName = def.art or def.build
		Art.set(bIcon, artName)
		bIcon.Visible = artName ~= nil
		textCol.Size = if artName then UDim2.new(1, -58, 0, 0) else UDim2.new(1, 0, 0, 0)
		bLine.Text = if short then "Gold comes in by itself. The game runs fast until you have enough." elseif waitText then waitText else def.line(s, d)
		liveChip.Visible = def.live ~= nil and not short
		if def.live then
			liveText.Text = def.live(s)
		end
		keyChip.Visible = def.key ~= nil and not short and d.input ~= "Gamepad" and not d.mobile
		keyText.Text = "Press " .. (def.key or "")
		saving.Visible = short
		if short then
			savingText.Text = fmt(s.gold) .. " / " .. fmt(cost)
			savingFill.Size = UDim2.fromScale(math.clamp(s.gold / cost, 0, 1), 1)
		end

		-- Target and spotlight
		local targets = (not short and not waitText and ctx.targets and ctx.targets(def.targetId or steps[index])) or {}
		local target = nil
		for _, t in targets do
			-- (a whole-screen fallback like the map holder is no target: the bubble just sits on top)
			if visibleTarget(t) and not (t.AbsoluteSize.X >= size.X * 0.75 and t.AbsoluteSize.Y >= size.Y * 0.75) then
				target = t
				break
			end
		end
		local bw = math.min(300, size.X - 24)
		bubble.Size = UDim2.fromOffset(bw, 0)
		bubble.Visible = true
		local holes = {}
		if target then
			local p, z = rectOf(target)
			local pad = if z.X < 60 then 18 else 8
			table.insert(holes, { p.X - pad, p.Y - pad, p.X + z.X + pad, p.Y + z.Y + pad })
			local pulse = (math.sin(os.clock() * 5) + 1) * 0.5
			ring.Visible = true
			-- A circle on map spots, a rounded box hugging buttons and the slider.
			local round = target.Name == "TutorialMapTarget"
			local rs = math.max(z.X, z.Y) + pad * 2
			local rw, rh = if round then rs else z.X + 12, if round then rs else z.Y + 12
			ring.Size = UDim2.fromOffset(rw, rh)
			ring:FindFirstChildWhichIsA("UICorner").CornerRadius = if round then UDim.new(0.5, 0) else UDim.new(0, 14)
			ring.Position = UDim2.fromOffset(p.X + z.X / 2, p.Y + z.Y / 2)
			spot.Size, spot.Position = ring.Size, ring.Position
			spotCorner.CornerRadius = if round then UDim.new(0.5, 0) else UDim.new(0, 14)
			ringStroke.Thickness = 3 + pulse * 2
			ringStroke.Transparency = pulse * 0.3
			arrow.Visible = true
			arrow.Position = UDim2.fromOffset(p.X + z.X / 2, p.Y + z.Y / 2 - rh / 2 - 6 - pulse * 8)
			-- Bubble beside the target (right, else left; above it for the bottom bar).
			local bh = bubble.AbsoluteSize.Y
			local bx, by
			if d.phone then
				bx, by = (size.X - bw) / 2, lowY
			elseif p.Y > size.Y * 0.62 then
				bx, by = math.clamp(p.X + z.X / 2 - bw / 2, 12, size.X - bw - 12), p.Y - pad - bh - 52
			elseif p.X + z.X + pad + 20 + bw < size.X - 12 then
				bx, by = p.X + z.X + pad + 20, p.Y + z.Y / 2 - bh / 2
			else
				bx, by = p.X - pad - 20 - bw, p.Y + z.Y / 2 - bh / 2
			end
			bubble.Position = UDim2.fromOffset(math.clamp(bx, 12, size.X - bw - 12), math.clamp(by, lowY, math.max(lowY, size.Y - bh - 12)))
		else
			ring.Visible, arrow.Visible = false, false
			bubble.Position = UDim2.fromOffset((size.X - bw) / 2, lowY)
		end
		-- Map labels (expand step): this is you / free land.
		if def.labels and target then
			local p, z = rectOf(target)
			-- "Free land" above the arrow; "This is you" to the left of your name.
			freeLabel.Visible = true
			freeLabel.Position = UDim2.fromOffset(p.X + z.X / 2, p.Y - 70)
			local you = ctx.targets("territory")
			local plate = you and you[1]
			if plate and typeof(plate) == "Instance" and plate:IsA("TextLabel") and visibleTarget(plate) then
				local pp, pz = rectOf(plate)
				youLabel.Visible = true
				youLabel.AnchorPoint = Vector2.new(1, 0.5)
				youLabel.Position = UDim2.fromOffset(pp.X - 40, pp.Y + pz.Y / 2)
			else
				youLabel.Visible = false
			end
		else
			youLabel.Visible, freeLabel.Visible = false, false
		end
		if def.enemyLabel and target then
			local p, z = rectOf(target)
			-- below the ring, so it doesn't sit on your own name
			enemyLabel.Visible = true
			enemyLabel.AnchorPoint = Vector2.new(0.5, 0)
			enemyLabel.Position = UDim2.fromOffset(p.X + z.X / 2, p.Y + z.Y + 30)
		else
			enemyLabel.Visible = false
		end
		-- Shade everything but the target (the bubble and pill sit above the shade).
		-- (map spots get the ring and labels only: a square cut-out around a circle looks clumsy)
		hideShade()
		spot.Visible = target ~= nil and not short and not waitText
	end

	function api.reset()
		release()
		local key = playerGui:GetAttribute(LESSON_ATTR)
		lesson = nil
		for _, l in Tutorial.LESSONS do
			if l.key == key then
				lesson = l
			end
		end
		stage = "welcome"
		modal.Visible = false
		pop.Visible = false
		steps = if lesson then lesson.steps else CHAPTERS[1].steps
		index = 1
		entry = ctx.snapshot()
	end

	skip.Activated:Connect(function()
		finish("skipped")
	end)
	local attrConn = playerGui:GetAttributeChangedSignal(ATTR):Connect(function()
		if playerGui:GetAttribute(ATTR) == true then
			api.reset()
		else
			release()
		end
		api.update()
	end)
	local menuConn = playerGui:GetAttributeChangedSignal("FrontlinesMenuOpen"):Connect(api.update)
	gui.Destroying:Connect(function()
		attrConn:Disconnect()
		menuConn:Disconnect()
	end)
	-- Smooth arrow / ring animation between the slower updates.
	game:GetService("RunService").RenderStepped:Connect(function()
		if gui.Enabled and arrow.Visible then
			local pulse = (math.sin(os.clock() * 5) + 1) * 0.5
			ringStroke.Thickness = 3 + pulse * 2
		end
	end)
	api.reset()
	return api
end

return Tutorial
