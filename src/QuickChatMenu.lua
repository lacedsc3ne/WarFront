--[[
	War Front - quick chat (OpenFront's ChatModal + QuickChat.json phrases).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.QuickChat (ModuleScript), used by PlayerPanel / GameClient
-- (via Interact).
--
-- Mirrors src/client/hud/layers/ChatModal.ts (o-modal "Quick Chat"): a Category column, then the
-- Phrase column for the chosen category, then (for phrases with [P1]) a Player column with a
-- "Sort by territory" toggle and a search box; a preview line ("Build your message...") and a
-- green Send button. Phrases are resources/QuickChat.json with the English text of en.json chat.*.
-- Players only ever send a phrase key ("category.key"), never free text, so nothing needs filtering.
--
-- Network (shared contract): client -> server  net:FireServer("quickChat", recipientId, phraseKey,
-- targetId?)  (targetId = the [P1] player; an extra argument the server may ignore);
-- server -> client  "quickChat" { from, to, key, target? }  shown in the events panel as
-- "From <name>: <msg>" / "Sent <name>: <msg>" (en.json chat.from / chat.to).
--
-- QuickChat.setup(ctx)   ctx: gui, net, roster, getMyId(), pushFeed(text, kind, owner)
-- QuickChat.open(recipientId), QuickChat.close(), QuickChat.isOpen()
-- QuickChat.text(phraseKey, targetName?) -> string?

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local QuickChat = {}

local CATEGORIES = { "help", "attack", "defend", "greet", "misc", "warnings" }
local CATEGORY_NAMES = { attack = "Attack", defend = "Defend", greet = "Greetings", help = "Help", misc = "Miscellaneous", warnings = "Warnings" }
local PHRASES = {
	help = {
		{ key = "troops", text = "Please give me troops!", player = false },
		{ key = "troops_frontlines", text = "Send troops to the frontlines!", player = false },
		{ key = "gold", text = "Please give me gold!", player = false },
		{ key = "no_attack", text = "Please don't attack me!", player = false },
		{ key = "sorry_attack", text = "Sorry, I didn’t mean to attack.", player = false },
		{ key = "alliance", text = "Alliance?", player = false },
		{ key = "help_defend", text = "Help me defend against [P1]!", player = true },
		{ key = "trade_partners", text = "Let's be trade partners!", player = false },
	},
	attack = {
		{ key = "attack", text = "Attack [P1]!", player = true },
		{ key = "mirv", text = "Launch a MIRV at [P1]!", player = true },
		{ key = "focus", text = "Focus fire on [P1]!", player = true },
		{ key = "finish", text = "Let's finish off [P1]!", player = true },
		{ key = "build_warships", text = "Build Warships!", player = false },
	},
	defend = {
		{ key = "defend", text = "Defend [P1]!", player = true },
		{ key = "defend_from", text = "Defend from [P1]!", player = true },
		{ key = "dont_attack", text = "Don’t attack [P1]!", player = true },
		{ key = "ally", text = "[P1] is my ally!", player = true },
		{ key = "build_posts", text = "Build Defense Posts!", player = false },
	},
	greet = {
		{ key = "hello", text = "Hello!", player = false },
		{ key = "good_job", text = "Good job!", player = false },
		{ key = "good_luck", text = "Good luck!", player = false },
		{ key = "have_fun", text = "Have fun!", player = false },
		{ key = "gg", text = "GG!", player = false },
		{ key = "nice_to_meet", text = "Nice to meet you!", player = false },
		{ key = "well_played", text = "Well played!", player = false },
		{ key = "hi_again", text = "Hi again!", player = false },
		{ key = "bye", text = "Bye!", player = false },
		{ key = "thanks", text = "Thanks!", player = false },
		{ key = "oops", text = "Oops, wrong button!", player = false },
		{ key = "trust_me", text = "You can trust me. Promise!", player = false },
		{ key = "trust_broken", text = "I trusted you...", player = false },
		{ key = "ruining_games", text = "You're ruining both of our games.", player = false },
		{ key = "dont_do_that", text = "Don't do that!", player = false },
		{ key = "same_team", text = "I'm on your side!", player = false },
	},
	misc = {
		{ key = "go", text = "Let’s go!", player = false },
		{ key = "strategy", text = "Nice strategy!", player = false },
		{ key = "fun", text = "This game is fun!", player = false },
		{ key = "team_up", text = "Let’s team up against [P1]!", player = true },
		{ key = "pr", text = "When will my PR finally get merged...?", player = false },
		{ key = "build_closer", text = "Build closer to get trains!", player = false },
		{ key = "coastline", text = "Please let me get a coastline.", player = false },
	},
	warnings = {
		{ key = "strong", text = "[P1] is strong.", player = true },
		{ key = "weak", text = "[P1] is weak.", player = true },
		{ key = "mirv_soon", text = "[P1] can launch a MIRV soon!", player = true },
		{ key = "number1_warning", text = "The #1 player will win soon unless we team up!", player = false },
		{ key = "stalemate", text = "Let's make peace. This is a stalemate, we will both lose.", player = false },
		{ key = "has_allies", text = "[P1] has many allies.", player = true },
		{ key = "no_allies", text = "[P1] has no allies.", player = true },
		{ key = "betrayed", text = "[P1] betrayed their ally!", player = true },
		{ key = "betrayed_me", text = "[P1] betrayed me!", player = true },
		{ key = "getting_big", text = "[P1] is growing too fast!", player = true },
		{ key = "danger_base", text = "[P1] is unprotected!", player = true },
		{ key = "saving_for_mirv", text = "[P1] is saving up to launch a MIRV.", player = true },
		{ key = "mirv_ready", text = "[P1] has enough gold to launch a MIRV!", player = true },
		{ key = "snowballing", text = "[P1] is snowballing too fast!", player = true },
		{ key = "cheating", text = "[P1] is cheating!", player = true },
		{ key = "stop_trading", text = "Stop trading with [P1]!", player = true },
		{ key = "stop_trading_all", text = "Please stop trading with all!", player = false },
	},
}

QuickChat.CATEGORIES = CATEGORIES
QuickChat.PHRASES = PHRASES

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local OPTION = Color3.fromHex("#333333")
local SELECTED = Color3.fromHex("#6666cc")
local PREVIEW = Color3.fromHex("#222222")
local SEND = Color3.fromHex("#4caf50")
local SEND_OFF = Color3.fromHex("#666666")

local ctx: any = nil
local ui: any = nil
local state = { open = false, recipient = 0, category = nil :: string?, phrase = nil :: any, player = 0, search = "", byTerritory = false }

local function find(phraseKey: string)
	local cat, key = string.match(phraseKey, "^([%w_]+)%.([%w_]+)$")
	local list = cat and PHRASES[cat]
	if not list then
		return nil
	end
	for _, p in list do
		if p.key == key then
			return p
		end
	end
	return nil
end

function QuickChat.text(phraseKey: string, targetName: string?): string?
	local p = find(phraseKey)
	if not p then
		return nil
	end
	if targetName then
		return (string.gsub(p.text, "%[P1%]", function()
			return targetName
		end))
	end
	return p.text
end

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

local function vlist(parent: Instance, gap: number)
	return make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap), Parent = parent })
end

local function option(parent: Instance, text: string, order: number, selected: boolean, onClick: () -> ())
	local b = make("TextButton", {
		Size = UDim2.new(1, -4, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = if selected then SELECTED else OPTION,
		AutoButtonColor = true,
		FontFace = FONT,
		TextSize = 14,
		TextColor3 = WHITE,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		LayoutOrder = order,
		ZIndex = 93,
		Parent = parent,
	})
	corner(b, 4)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = b })
	b.Activated:Connect(onClick)
	return b
end

local function column(order: number, title: string)
	local col = make("Frame", { Size = UDim2.new(0, 170, 1, 0), BackgroundTransparency = 1, LayoutOrder = order, Visible = false, ZIndex = 92, Parent = ui.columns })
	make("TextLabel", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, FontFace = FONT_BOLD, TextSize = 15, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, Text = title, ZIndex = 93, Parent = col })
	local scroll = make("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 1, -24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		ZIndex = 93,
		Parent = col,
	})
	vlist(scroll, 6)
	return col, scroll
end

local function clear(f: Instance)
	for _, c in f:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local render

local function playersSorted()
	local list = {}
	for id, p in ctx.roster do
		if p.stats.alive and p.stats.tiles > 0 and p.kind ~= "Bot" then
			list[#list + 1] = p
		end
	end
	table.sort(list, function(a, b)
		if state.byTerritory then
			return a.stats.tiles > b.stats.tiles
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
	-- matches first, then the rest (getSortedFilteredPlayers)
	local q = string.lower(state.search)
	local hit, rest = {}, {}
	for _, p in list do
		if q == "" or string.find(string.lower(p.name), q, 1, true) then
			hit[#hit + 1] = p
		else
			rest[#rest + 1] = p
		end
	end
	for _, p in rest do
		hit[#hit + 1] = p
	end
	return hit
end

local function previewText(): string?
	if not state.phrase then
		return nil
	end
	local target = ctx.roster[state.player]
	if state.phrase.player and target then
		return (string.gsub(state.phrase.text, "%[P1%]", function()
			return target.name
		end))
	end
	return state.phrase.text
end

local function canSend(): boolean
	return state.phrase ~= nil and (not state.phrase.player or ctx.roster[state.player] ~= nil)
end

function render()
	-- categories
	clear(ui.catList)
	for i, id in CATEGORIES do
		option(ui.catList, CATEGORY_NAMES[id], i, state.category == id, function()
			state.category, state.phrase, state.player = id, nil, 0
			render()
		end)
	end
	ui.catCol.Visible = true
	-- phrases
	ui.phraseCol.Visible = state.category ~= nil
	clear(ui.phraseList)
	if state.category then
		for i, p in PHRASES[state.category] do
			option(ui.phraseList, p.text, i, state.phrase == p, function()
				state.phrase, state.player = p, 0
				render()
			end)
		end
	end
	-- players
	local needPlayer = state.phrase ~= nil and state.phrase.player
	ui.playerCol.Visible = needPlayer
	clear(ui.playerList)
	if needPlayer then
		for i, p in playersSorted() do
			local b = option(ui.playerList, p.name, i, state.player == p.id, function()
				state.player = p.id
				render()
			end)
			make("UIStroke", { Color = Color3.fromRGB(p.r or 255, p.g or 255, p.b or 255), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		end
		ui.sortToggle.Text = (if state.byTerritory then "☑ " else "☐ ") .. "Sort by territory"
	end
	local text = previewText()
	ui.preview.Text = text or "Build your message..."
	local ok = canSend()
	ui.send.BackgroundColor3 = if ok then SEND else SEND_OFF
	ui.send.AutoButtonColor = ok
end

local function build()
	local gui = ctx.gui
	local dim = make("TextButton", { Name = "QuickChatDim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, AutoButtonColor = false, Text = "", Selectable = false, Visible = false, ZIndex = 90, Parent = gui })
	local card = make("Frame", { Name = "QuickChat", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(600, 460), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.3, Active = true, Visible = false, ZIndex = 91, Parent = gui })
	corner(card, 16)
	make("UIStroke", { Color = WHITE, Transparency = 0.9, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = card })
	make("UISizeConstraint", { MaxSize = Vector2.new(640, 520), Parent = card })
	make("TextLabel", { Position = UDim2.fromOffset(22, 14), Size = UDim2.new(1, -80, 0, 32), BackgroundTransparency = 1, FontFace = FONT_BOLD, TextSize = 24, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, Text = "Quick Chat", ZIndex = 92, Parent = card })
	local close = make("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 14), Size = UDim2.fromOffset(32, 32), BackgroundTransparency = 1, FontFace = FONT_BOLD, TextSize = 22, TextColor3 = WHITE, Text = "✕", ZIndex = 93, Parent = card })
	local columns = make("ScrollingFrame", {
		Position = UDim2.fromOffset(12, 56),
		Size = UDim2.new(1, -24, 1, -56 - 120),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		Selectable = false,
		ZIndex = 92,
		Parent = card,
	})
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 16), Parent = columns })
	ui = { dim = dim, card = card, close = close, columns = columns }
	ui.catCol, ui.catList = column(1, "Category")
	ui.phraseCol, ui.phraseList = column(2, "Phrase")
	ui.playerCol, ui.playerList = column(3, "Player")
	-- player column extras: sort toggle + search, above the list
	ui.playerList.Position = UDim2.fromOffset(0, 24 + 64)
	ui.playerList.Size = UDim2.new(1, 0, 1, -24 - 64)
	ui.sortToggle = make("TextButton", { Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, FontFace = FONT, TextSize = 13, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, Text = "", ZIndex = 93, Parent = ui.playerCol })
	ui.search = make("TextBox", { Position = UDim2.fromOffset(0, 52), Size = UDim2.new(1, -4, 0, 30), BackgroundColor3 = WHITE, TextColor3 = Color3.new(0, 0, 0), PlaceholderText = "Search player...", PlaceholderColor3 = Color3.fromRGB(110, 110, 110), FontFace = FONT, TextSize = 14, ClearTextOnFocus = false, Text = "", TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 93, Parent = ui.playerCol })
	corner(ui.search, 4)
	make("UIStroke", { Color = Color3.fromHex("#666666"), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ui.search })
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = ui.search })
	ui.preview = make("TextLabel", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 24, 1, -64), Size = UDim2.new(1, -48, 0, 40), BackgroundColor3 = PREVIEW, BackgroundTransparency = 0, FontFace = FONT, TextSize = 15, TextColor3 = WHITE, TextWrapped = true, Text = "", ZIndex = 92, Parent = card })
	corner(ui.preview, 6)
	ui.send = make("TextButton", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -12), Size = UDim2.fromOffset(90, 36), BackgroundColor3 = SEND_OFF, FontFace = FONT_BOLD, TextSize = 15, TextColor3 = WHITE, Text = "Send", ZIndex = 92, Parent = card })
	corner(ui.send, 4)

	dim.Activated:Connect(QuickChat.close)
	close.Activated:Connect(QuickChat.close)
	ui.sortToggle.Activated:Connect(function()
		state.byTerritory = not state.byTerritory
		render()
	end)
	ui.search:GetPropertyChangedSignal("Text"):Connect(function()
		if state.search ~= ui.search.Text then
			state.search = ui.search.Text
			if state.open then
				render()
			end
		end
	end)
	ui.send.Activated:Connect(function()
		if not canSend() then
			return
		end
		local key = state.category .. "." .. state.phrase.key
		local target = if state.phrase.player then state.player else nil
		ctx.net:FireServer("quickChat", state.recipient, key, target)
		QuickChat.close()
	end)
end

function QuickChat.isOpen(): boolean
	return state.open
end

function QuickChat.close()
	if not ui or not state.open then
		return
	end
	state.open = false
	state.category, state.phrase, state.player = nil, nil, 0
	ui.dim.Visible = false
	ui.card.Visible = false
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(ui.card) then
		GuiService.SelectedObject = nil
	end
end

function QuickChat.open(recipientId: number)
	if not ui or not ctx.roster[recipientId] then
		return
	end
	state.open = true
	state.recipient = recipientId
	state.category, state.phrase, state.player, state.search = nil, nil, 0, ""
	ui.search.Text = ""
	ui.dim.Visible = true
	ui.card.Visible = true
	render()
	if UserInputService:GetLastInputType().Name:sub(1, 7) == "Gamepad" then
		task.defer(function()
			local first = ui.catList:FindFirstChildWhichIsA("TextButton")
			if first and state.open then
				GuiService.SelectedObject = first
			end
		end)
	end
end

-- Incoming "quickChat" { from, to, key, target? } (EventsDisplay.onDisplayChatEvent).
local function onChat(data)
	if type(data) ~= "table" then
		return
	end
	local myId = ctx.getMyId()
	local target = if type(data.target) == "number" then ctx.roster[data.target] else nil
	local msg = QuickChat.text(tostring(data.key), if target then target.name else nil)
	if not msg then
		return
	end
	if data.to == myId and myId ~= 0 then
		local from = ctx.roster[data.from]
		ctx.pushFeed(string.format("From %s: %s", if from then from.name else "?", msg), "chat", data.from)
	elseif data.from == myId and myId ~= 0 then
		local to = ctx.roster[data.to]
		ctx.pushFeed(string.format("Sent %s: %s", if to then to.name else "?", msg), "chat", data.to)
	end
end

function QuickChat.setup(c)
	ctx = c
	build()
	c.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "quickChat" then
			onChat(data)
		elseif kind == "init" then
			QuickChat.close()
		end
	end)
	UserInputService.InputBegan:Connect(function(input)
		if state.open and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
			QuickChat.close()
		end
	end)
end

return QuickChat
