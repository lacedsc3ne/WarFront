--[[
	War Front - step-by-step in-match tutorial panel.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Tutorial (ModuleScript), used by GameClient.
--
-- Shown while PlayerGui attribute FrontlinesTutorial == true (the main menu's TUTORIAL button
-- sets it) and the local player is in a round. The X button sets the attribute back to false.
--
-- Tutorial.create(ctx) -> api
--   ctx.parent       GuiObject the box goes into (GameClient's stack above the control panel)
--   ctx.layoutOrder  LayoutOrder inside that parent
--   ctx.deviceLayout DeviceLayout module (verb(), state.input)
--   ctx.snapshot()   -> {
--       inRound, phase, spawned, alive, gold, cityCost, counts = { [kind] = n },
--       attacksSent, playerAttacksSent, ratioMoves, attacking, attackingPlayer }
--   ctx.canGoTo(kind) -> boolean     kind: "home" | "enemy"
--   ctx.goTo(kind)
-- api.update()     call a few times a second
-- api.reset()      new round: start again from step 1
-- api.wantsRing()  true while a step wants the pulsing ring on our territory
-- api.frame

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Tutorial = {}

local ATTR = "FrontlinesTutorial"
local DONE_LINGER = 1.2 -- seconds a completed step stays up (with its tick) before advancing

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local BG = Color3.fromRGB(31, 41, 55)
local YELLOW = Color3.fromRGB(255, 215, 0)
local MALIBU = Color3.fromRGB(0, 132, 209)
local GRAY300 = Color3.fromRGB(209, 213, 219)
local GRAY400 = Color3.fromRGB(156, 163, 175)
local GREEN = Color3.fromRGB(74, 222, 128)

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

local function fmt(n: number): string
	n = math.floor(n)
	if n >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("%.0fK", n / 1e3)
	end
	return tostring(n)
end

--------------------------------------------------------------------------------
-- Steps. text(snap, d) gets the device helpers below; done(snap, entry) compares against the
-- snapshot taken when the step started. Steps without `done` advance with the Next button.
--------------------------------------------------------------------------------
local function lower(s: string): string
	return string.lower(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

local function pick(input: string, kbm: string, touch: string, pad: string): string
	if input == "Gamepad" then
		return pad
	elseif input == "Touch" then
		return touch
	end
	return kbm
end

local STEPS = {
	{
		id = "spawn",
		text = function(s, d)
			if s.spawned then
				return "Good spot! The round starts when the spawn timer runs out. You can still " .. d.lverb .. " somewhere else to move."
			end
			return d.verb .. " an empty spot on the map to choose where you start. Pick land away from big neighbours."
		end,
		goTo = function(s)
			return if s.spawned then "home" else nil
		end,
		done = function(s)
			return s.spawned and s.phase == "Play"
		end,
		ring = true,
	},
	{
		id = "territory",
		text = function()
			return "The pulsing ring marks your territory. Press Go to whenever you lose track of it."
		end,
		goTo = "home",
		ring = true,
	},
	{
		id = "expand",
		text = function(_, d)
			return d.verb .. " the grey, unclaimed land next to your border to send troops into it and expand."
		end,
		goTo = "home",
		done = function(s, e)
			return s.attacksSent > e.attacksSent or (s.attacking and not e.attacking)
		end,
		ring = true,
	},
	{
		id = "ratio",
		text = function(_, d)
			return "The attack ratio is the share of your troops each attack sends. "
				.. pick(d.input, "Drag the slider or press T / Y to change it.", "Drag the slider to change it.", "Press LB / RB to change it.")
		end,
		done = function(s, e)
			return s.ratioMoves > e.ratioMoves
		end,
	},
	{
		id = "growth",
		text = function()
			return "Troops regrow every second (the green +/s). Growth is fastest at about 40% of your max troops, so keep attacking instead of sitting full."
		end,
	},
	{
		id = "gold",
		text = function()
			return "You earn gold every second, and trade ships between ports bring in more. Spend it on the build bar below."
		end,
	},
	{
		id = "city",
		text = function(s, d)
			if (s.counts.City or 0) == 0 and s.gold < s.cityCost then
				return string.format("Save up %s gold (you have %s), then build a City: it raises your max troops.", fmt(s.cityCost), fmt(s.gold))
			end
			return "Build a City: "
				.. pick(d.input, "press 1 or click the City button", "tap the City button", "press Y and pick City with A")
				.. ", then "
				.. d.lverb
				.. " your land. Cities raise your max troops."
		end,
		goTo = "home",
		done = function(s)
			return (s.counts.City or 0) > 0
		end,
	},
	{
		id = "port",
		text = function(_, d)
			return "Ports go on your coast and send trade ships for gold. To cross the sea, " .. d.lverb .. " land across the water and your troops sail there by boat."
		end,
		goTo = "home",
		done = function(s)
			return (s.counts.Port or 0) > 0
		end,
		optional = true,
	},
	{
		id = "defense",
		text = function()
			return "Defense Posts make nearby land 5x harder to take. Put one on a border you need to hold."
		end,
		done = function(s)
			return (s.counts.DefensePost or 0) > 0
		end,
		optional = true,
	},
	{
		id = "players",
		text = function(_, d)
			return "Attack other players the same way: " .. d.lverb .. " their land. Check their troops on the leaderboard first and pick fights you can win."
		end,
		goTo = "enemy",
		done = function(s, e)
			return s.playerAttacksSent > e.playerAttacksSent or (s.attackingPlayer and not e.attackingPlayer)
		end,
		optional = true,
	},
	{
		id = "alliances",
		text = function(_, d)
			return pick(d.input, "Right-click", "Long-press", "Press X on")
				.. " a player to open their menu and propose an alliance. Allies can't attack each other; breaking an alliance brands you a Traitor."
		end,
	},
	{
		id = "nukes",
		text = function()
			return "A Missile Silo launches Atom and Hydrogen bombs at anyone on the map. SAM launchers shoot incoming nukes down, so guard your cities with them."
		end,
	},
	{
		id = "warships",
		text = function(_, d)
			return "With a Port you can build Warships: they patrol, sink enemy boats and capture trade. "
				.. d.verb
				.. " your warship, then the water, to move it."
		end,
		done = function(s)
			return (s.counts.Warship or 0) > 0
		end,
		optional = true,
	},
	{
		id = "win",
		text = function()
			return string.format("Hold %d%% of the land to win the round. Good luck, commander!", math.floor(Config.WIN_FRACTION * 100 + 0.5))
		end,
	},
}

--------------------------------------------------------------------------------
function Tutorial.create(ctx)
	local api = {}
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local DeviceLayout = ctx.deviceLayout

	local index = 1
	local entry = nil -- snapshot when the current step started
	local doneAt: number? = nil

	-- UI ------------------------------------------------------------------------------
	local frame = make("Frame", {
		Name = "Tutorial",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = BG,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		LayoutOrder = ctx.layoutOrder or 2,
		Parent = ctx.parent,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 8), Parent = frame })
	make("UIStroke", { Color = Color3.fromRGB(75, 85, 99), Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = frame })
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8), Parent = frame })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = frame })

	local header = make("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, LayoutOrder = 1, Parent = frame })
	make("TextLabel", {
		Size = UDim2.new(0, 90, 1, 0),
		BackgroundTransparency = 1,
		FontFace = FONT_BOLD,
		TextSize = 13,
		TextColor3 = YELLOW,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "TUTORIAL",
		Parent = header,
	})
	local actions = make("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(1, -90, 1, 0), BackgroundTransparency = 1, Parent = header })
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
		Parent = actions,
	})

	local function blueButton(text: string, order: number): TextButton
		local b = make("TextButton", {
			Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = MALIBU,
			BorderSizePixel = 0,
			FontFace = FONT_BOLD,
			TextSize = 13,
			TextColor3 = Color3.new(1, 1, 1),
			Text = text,
			AutoButtonColor = true,
			LayoutOrder = order,
			Parent = actions,
		})
		make("UICorner", { CornerRadius = UDim.new(0, 4), Parent = b })
		make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = b })
		return b
	end

	local nextButton = blueButton("Next", 1)
	local goButton = blueButton("Go to", 2)
	local skipButton = make("TextButton", {
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = 13,
		TextColor3 = GRAY400,
		RichText = true,
		Text = "<u>Skip</u>",
		LayoutOrder = 3,
		Parent = actions,
	})
	local counter = make("TextLabel", {
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = 13,
		TextColor3 = GRAY300,
		Text = "",
		LayoutOrder = 4,
		Parent = actions,
	})
	local closeButton = make("TextButton", {
		Size = UDim2.fromOffset(24, 22),
		BackgroundTransparency = 1,
		FontFace = FONT_BOLD,
		TextSize = 18,
		TextColor3 = GRAY400,
		Text = "×",
		LayoutOrder = 5,
		Parent = actions,
	})

	local body = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.1,
		Text = "",
		LayoutOrder = 2,
		Parent = frame,
	})
	api.frame = frame

	-- Logic ---------------------------------------------------------------------------
	local function active(): boolean
		return playerGui:GetAttribute(ATTR) == true and playerGui:GetAttribute("FrontlinesMenuOpen") ~= true
	end

	local function goToKind(step, s): string?
		local g = step.goTo
		if type(g) == "function" then
			g = g(s)
		end
		return g
	end

	local function startStep(i: number)
		index = i
		doneAt = nil
		entry = ctx.snapshot()
		if index > #STEPS then
			playerGui:SetAttribute(ATTR, false)
		end
	end

	local function clearSelection()
		local GuiService = game:GetService("GuiService")
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(frame) then
			GuiService.SelectedObject = nil
		end
	end

	function api.reset()
		startStep(1)
	end

	function api.wantsRing(): boolean
		local step = STEPS[index]
		return frame.Visible and step ~= nil and step.ring == true
	end

	function api.update()
		local s = ctx.snapshot()
		local show = active() and s.inRound and s.alive and index <= #STEPS
		frame.Visible = show
		if not show then
			clearSelection()
			return
		end
		if not entry then
			entry = s
		end
		local step = STEPS[index]
		local now = os.clock()
		if doneAt then
			if now - doneAt >= DONE_LINGER then
				startStep(index + 1)
				api.update()
			end
			return
		end
		if step.done and step.done(s, entry) then
			doneAt = now
			body.Text = "✓  " .. step.text(s, api.device())
			body.TextColor3 = GREEN
			nextButton.Visible = false
			goButton.Visible = false
			skipButton.Visible = false
			return
		end
		local text = "•  " .. step.text(s, api.device())
		if body.Text ~= text then
			body.Text = text
		end
		body.TextColor3 = Color3.new(1, 1, 1)
		local manual = step.done == nil or step.optional == true
		nextButton.Visible = manual
		nextButton.Text = if index == #STEPS then "Finish" else "Next"
		local g = goToKind(step, s)
		goButton.Visible = g ~= nil and ctx.canGoTo(g)
		skipButton.Visible = step.done ~= nil and not step.optional
		counter.Text = string.format("Step %d of %d", index, #STEPS)
	end

	function api.device()
		local verb = DeviceLayout.verb()
		return { verb = verb, lverb = lower(verb), input = DeviceLayout.state.input }
	end

	nextButton.Activated:Connect(function()
		startStep(index + 1)
		api.update()
	end)
	skipButton.Activated:Connect(function()
		startStep(index + 1)
		api.update()
	end)
	goButton.Activated:Connect(function()
		local step = STEPS[index]
		if step then
			local g = goToKind(step, ctx.snapshot())
			if g then
				ctx.goTo(g)
			end
		end
	end)
	closeButton.Activated:Connect(function()
		playerGui:SetAttribute(ATTR, false)
		api.update()
	end)
	playerGui:GetAttributeChangedSignal(ATTR):Connect(function()
		if playerGui:GetAttribute(ATTR) == true then
			startStep(1) -- (re)started from the main menu's TUTORIAL or the pause menu's HOW TO PLAY
		end
		api.update()
	end)

	return api
end

return Tutorial
