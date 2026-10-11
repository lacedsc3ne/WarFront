-- War Front Night battle HUD. Copyright (C) 2026 Liam (lacedsc3ne). AGPL-3.0-or-later.
-- Built to the owner-approved in-game mockups (11 Oct 2026): clock pill, win card, Boosts pill and
-- menu button along the top; "Top players" on the left; "What's happening" (with ally requests) on
-- the right; a two-row command bar at the bottom (troops / gold / send slider, then build tiles with a
-- Nukes tile that opens Nuke / Big nuke / Mega nuke). Phone gets the phone mockup (rank pill, bell,
-- send quick picks, Build and Nukes buttons); controllers get button hints.
-- Presentation only: the real controls are borrowed from CornerHud / HudSidebars / GameClient (build
-- choice buttons, ratio slider, feed and ally requests, Boosts button and panel, speed / pause
-- buttons) and keep their own handlers. Everything borrowed goes through s.change, and unmount puts
-- the original properties back.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local NightMenu = script.Parent:WaitForChild("NightMenu")
local Kit = require(NightMenu:WaitForChild("Kit"))
local Art = require(NightMenu:WaitForChild("Art"))
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))
local K, F = Kit.C, Kit.F
local make = Kit.make

local Layout = {}

-- Tutorial state can arrive before/after the round HUD mounts.
local function tutorialCanSkip(): boolean
	local pg = Players.LocalPlayer.PlayerGui
	if pg:GetAttribute("FrontlinesMenuOpen") == true then return false end
	if pg:GetAttribute("FrontlinesTutorial") == true then return true end
	return workspace:GetAttribute("WFMatchKind") == "tutorial" and pg:GetAttribute("FrontlinesTutorialFinished") == nil
end

local skipHexImage
local function skipHex(parent)
	if not skipHexImage then
		local ok, img = pcall(function()
			local image = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(128, 40) })
			if not image then return nil end
			local pixels = buffer.create(128 * 40 * 4)
			for y = 0, 39 do
				for x = 0, 127 do
					local row = math.floor(y / 20)
					local cx = math.floor((x - (row % 2) * 12) / 24) * 24 + (row % 2) * 12 + 12
					local cy = row * 20 + 10
					local dx, dy = math.abs(x - cx), math.abs(y - cy)
					local edge = math.max(dx / 10, (dx + dy * 1.732) / 20)
					if edge >= 0.91 and edge <= 1.04 then
						local a = math.floor(42 * (1 - x / 128))
						buffer.writeu32(pixels, (y * 128 + x) * 4, 16777215 + a * 16777216)
					end
				end
			end
			image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
			return image
		end)
		if ok then skipHexImage = img end
	end
	if skipHexImage then
		local pattern = make("ImageLabel", { Name = "SkipHex", BackgroundTransparency = 1, ImageContent = Content.fromObject(skipHexImage), Size = UDim2.fromScale(1, 1), ZIndex = 63, Parent = parent })
		Kit.corner(pattern)
	end
end


-- Build tiles in mockup order; the nukes open from their own tile.
local TILES = {
	{ "City", "Factory", "Port", "DefensePost" },
	{ "Warship", "SAM" },
	{ "MissileSilo" },
}
local NUKES = { "AtomBomb", "HydrogenBomb", "MIRV" }
-- Boosts button: the same card pill as the rest of the top bar; the potion picture gives it colour.
local BOOST_FILL = K.CARD
local BOOST_EDGE = K.LINE
-- The game's own names (owner: keep SAM, MIRV and so on).
local NAMES = {
	City = "City", Factory = "Factory", DefensePost = "Defense Post", MissileSilo = "Missile Silo",
	Port = "Port", Warship = "Warship", SAM = "SAM Launcher", AtomBomb = "Atom Bomb", HydrogenBomb = "Hydrogen Bomb", MIRV = "MIRV",
}
local LONG_NAMES = {}
local TINT = {
	City = K.YELLOW, Factory = K.YELLOW, Port = K.CYAN, DefensePost = K.GREEN, Warship = K.CYAN, SAM = K.GREEN,
	MissileSilo = K.PINK, AtomBomb = K.PINK, HydrogenBomb = K.PINK, MIRV = K.PINK,
}
local INFO = {
	City = "Gives you room for more troops. Upgrade it for even more.",
	Factory = "Builds railroads and sends trains that earn gold.",
	DefensePost = "Makes your nearby borders much harder to attack.",
	MissileSilo = "Needed to launch nukes. Upgrade it to fire more often.",
	Port = "Goes on your coast. Sends trade ships that earn gold, and lets you build warships.",
	Warship = "Guards the sea near your port: catches trade ships and sinks enemy boats. Needs a port.",
	SAM = "Shoots down nukes that land near it.",
	AtomBomb = "A small explosion that wipes out land and buildings. Needs a missile silo.",
	HydrogenBomb = "A big explosion. Needs a missile silo.",
	MIRV = "A huge strike that splits into many warheads and only hits the player you pick. Needs a missile silo.",
}

-- Plain words for texts the game writes into borrowed pieces (feed, requests, banner, hover card).
local RENAMES = {
	{ "^ACCEPT$", "Accept" }, { "^DECLINE$", "No thanks" }, { "^FOCUS$", "Show" },
	{ "^(.-) requests an alliance!?$", "%1 wants to be allies" },
	{ "^AI country$", "Computer nation" }, { "^BOOSTS$", "Boosts" },
	{ "^You were eliminated %- spectating$", "You're out \u{00B7} watching the battle" },
	{ "^Spectating %- you'll join next round$", "Watching \u{00B7} you'll join the next battle" },
	{ "^Round over %- next round in (%d+s)$", "Battle over \u{00B7} next one in %1" },
	{ "^Game over %- back to the lobby in (%d+s)$", "Battle over \u{00B7} back to the menu in %1" },
	{ "^Next round starts in (%d+s)$", "Next battle starts in %1" },
	{ "^Waiting for players%.%.%. ", "Waiting for players \u{00B7} " },
	{ "^Choose a starting location$", "Pick your starting spot" },
}
local function renamed(text: string): string
	for _, r in RENAMES do
		local out, n = string.gsub(text, r[1], r[2], 1)
		if n > 0 then
			return out
		end
	end
	return text
end
-- Notes that also pop up above the command bar for a few seconds.
local NOTICES = {
	{ "^Practice match", "Practice battle: no XP, medals or ranking points" },
}

-- Old match colours -> Night colours, for borrowed pieces (matched by nearest colour).
local BG = {
	{ Color3.fromRGB(17, 60, 99), K.CARD }, { Color3.fromRGB(5, 22, 40), K.CARD },
	{ Color3.fromRGB(29, 88, 136), K.RAISED }, { Color3.fromRGB(14, 43, 64), K.RAISED },
	{ Color3.fromRGB(13, 48, 80), K.RAISED }, { Color3.fromRGB(11, 39, 68), K.PAGE }, { Color3.fromRGB(11, 39, 65), K.PAGE },
	{ Color3.fromRGB(71, 145, 197), K.LINE }, { Color3.fromRGB(107, 114, 128), K.LINE },
}
local FG = {
	{ Color3.fromRGB(241, 248, 255), K.TEXT }, { Color3.fromRGB(155, 184, 219), K.MUTED },
	{ Color3.fromRGB(0, 177, 235), K.CYAN }, { Color3.fromRGB(255, 211, 55), K.YELLOW }, { Color3.fromRGB(255, 211, 35), K.YELLOW },
	{ Color3.fromRGB(255, 196, 50), K.YELLOW }, { Color3.fromRGB(240, 91, 80), K.PINK }, { Color3.fromRGB(91, 220, 142), K.GREEN },
}
local function near(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.06
end
local function mapped(list, c: Color3): Color3?
	for _, pair in list do
		if near(c, pair[1]) then
			return pair[2]
		end
	end
	return nil
end

local function set(v: Instance, prop: string, value: any)
	if (v :: any)[prop] ~= value then
		(v :: any)[prop] = value
	end
end

-- Hooks (re-apply the Night value the moment the game resets it; same frame, no flicker).
local function hook(s, v: Instance, prop: string, fix: (any) -> (), tag: string?)
	local set_ = s.hooks[v]
	if not set_ then
		set_ = {}
		s.hooks[v] = set_
	end
	local key = prop .. "|" .. (tag or "")
	if set_[key] then
		return
	end
	set_[key] = true
	local busy = false
	-- Loop breaker: if something keeps fighting this hook (more than 6 runs in 0.1 s), the hook
	-- stands down for a second and the object is recorded in workspace attribute WFNightHookLoops.
	local windowStart, runs, pausedUntil = 0, 0, 0
	local function run()
		if busy then
			return
		end
		local now = os.clock()
		if now < pausedUntil then
			return
		end
		if now - windowStart > 0.1 then
			windowStart, runs = now, 0
		end
		runs += 1
		if runs > 6 then
			pausedUntil = now + 1
			local name = v:GetFullName() .. "." .. prop
			if not s.loopSeen[name] then
				s.loopSeen[name] = true
				warn("[War Front] Night HUD hook stood down (fighting another script): " .. name)
				local list = workspace:GetAttribute("WFNightHookLoops") or ""
				workspace:SetAttribute("WFNightHookLoops", string.sub(list .. name .. "; ", 1, 900))
			end
			return
		end
		busy = true
		local t0 = os.clock()
		fix(v)
		if Layout.spent then
			Layout.spent.hooks += os.clock() - t0
			Layout.spent.hookRuns += 1
		end
		busy = false
	end
	table.insert(s.connections, v:GetPropertyChangedSignal(prop):Connect(run))
	run()
end
local function keep(s, v: Instance, props: { [string]: any })
	s.change(v, props)
	for key, value in props do
		hook(s, v, key, function(o)
			if o[key] ~= value then
				o[key] = value
			end
		end, "keep")
	end
end

-- Night look for one borrowed object (colours, fonts, flat fills, plain words), kept by hooks.
local function paint(s, v: Instance)
	if v:IsA("UIGradient") then
		if v.Name == "AllianceActionFade" and v.Parent then
			local face = v.Parent
			local key = face.Parent and face.Parent.Name
			keep(s, face, { BackgroundColor3 = if key == "ACCEPT" then K.GREEN else K.RAISED })
			local caption = face.Parent and face.Parent:FindFirstChild("AllianceActionLabel")
			if caption then
				keep(s, caption, { TextColor3 = if key == "ACCEPT" then K.GREEN_TEXT else K.TEXT, TextStrokeTransparency = 1, FontFace = F.TITLE })
			end
		end
		keep(s, v, { Enabled = false })
	elseif v:IsA("UIStroke") then
		hook(s, v, "Color", function(o)
			if o.Color ~= K.LINE and (near(o.Color, Color3.new()) or mapped(BG, o.Color)) then
				s.change(o, { Color = K.LINE, Transparency = 0 })
			end
		end)
	elseif v:IsA("GuiObject") then
		if v.Name == "AngularShape" or v.Name == "DefaultCardSurface" then
			keep(s, v, { Visible = false })
			return
		end
		hook(s, v, "BackgroundColor3", function(o)
			local m = mapped(BG, o.BackgroundColor3)
			if m and m ~= o.BackgroundColor3 then
				s.change(o, { BackgroundColor3 = m })
			end
		end)
		if v:IsA("TextLabel") or v:IsA("TextButton") then
			keep(s, v, { FontFace = if v.TextSize >= 13 or v:IsA("TextButton") then F.TITLE else F.BOLD, TextStrokeTransparency = 1 })
			hook(s, v, "TextColor3", function(o)
				local m = mapped(FG, o.TextColor3)
				if m and m ~= o.TextColor3 then
					s.change(o, { TextColor3 = m })
				end
			end)
			hook(s, v, "Text", function(o)
				local t = renamed(o.Text)
				if t ~= o.Text then
					o.Text = t
				end
				for _, n in NOTICES do
					if string.find(o.Text, n[1]) then
						Layout.notice(s, n[2])
					end
				end
			end)
		end
	end
end
local function paintTree(s, root: Instance)
	if s.trees[root] then
		return
	end
	s.trees[root] = true
	paint(s, root)
	for _, v in root:GetDescendants() do
		paint(s, v)
	end
	table.insert(s.connections, root.DescendantAdded:Connect(function(v)
		task.defer(function()
			if v.Parent then
				paint(s, v)
			end
		end)
	end))
end

-- One ally request card (built by AlertsPanel) in the Night look: "Ally request" caption with a small
-- Show link on the right, the request text, then Accept (yellow) and No thanks as menu-style buttons,
-- and a thin time bar.
-- The real buttons keep their handlers: their own text is hidden and a Night face is drawn on top.
local function requestButton(s, b: TextButton, face: Color3, edge: Color3, textColor: Color3, depth: number)
	s.change(b, { BackgroundColor3 = edge, BackgroundTransparency = 0, TextTransparency = 1, AutoButtonColor = false, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(0, 0, 1, 0) })
	local bc = b:FindFirstChildWhichIsA("UICorner")
	if bc then
		s.change(bc, { CornerRadius = UDim.new(0, 12) })
	end
	local bp = b:FindFirstChildWhichIsA("UIPadding")
	if bp then
		s.change(bp, { PaddingLeft = UDim.new(), PaddingRight = UDim.new() })
	end
	local f = make("Frame", { Name = "NightFace", BackgroundColor3 = face, BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, -depth), Parent = b })
	Kit.corner(f, 12)
	Kit.text({ Text = renamed(b.Text), FontFace = F.TITLE, TextSize = 15, TextColor3 = textColor, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = f })
	table.insert(s.created, f)
	local lit = face:Lerp(Color3.new(1, 1, 1), 0.12)
	table.insert(s.connections, b.MouseEnter:Connect(function()
		f.BackgroundColor3 = lit
	end))
	table.insert(s.connections, b.MouseLeave:Connect(function()
		f.BackgroundColor3 = face
		f.Position = UDim2.new()
	end))
	table.insert(s.connections, b.MouseButton1Down:Connect(function()
		f.Position = UDim2.fromOffset(0, depth)
	end))
	table.insert(s.connections, b.MouseButton1Up:Connect(function()
		f.Position = UDim2.new()
	end))
end
local function styleRequest(s, req: Frame)
	s.change(req, { BackgroundColor3 = K.CARD, BackgroundTransparency = 0 })
	local c = req:FindFirstChildWhichIsA("UICorner")
	if c then
		s.change(c, { CornerRadius = UDim.new(0, 12) })
	end
	table.insert(s.created, Kit.stroke(req, K.LINE, 1.5))
	for _, v in req:GetChildren() do
		if v.Name == "Accent" and v:IsA("GuiObject") then
			s.change(v, { Visible = false })
		elseif v:IsA("Frame") then
			local pad = v:FindFirstChildWhichIsA("UIPadding")
			if pad then
				s.change(pad, { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) })
			end
			local list = v:FindFirstChildWhichIsA("UIListLayout")
			if list then
				s.change(list, { Padding = UDim.new(0, 8) })
			end
			local caption = Kit.text({ Name = "NightAllyCaption", Text = "ALLY REQUEST", FontFace = F.TITLE, TextSize = 11, TextColor3 = K.MUTED, LayoutOrder = 0, Parent = v })
			table.insert(s.created, caption)
			for _, w in v:GetChildren() do
				if w.Name == "Title" and w:IsA("TextButton") then
					s.change(w, { TextSize = 16, TextColor3 = K.TEXT })
				elseif w.Name == "RequestTimer" and w:IsA("Frame") then
					s.change(w, { Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = K.RAISED })
					table.insert(s.created, Kit.corner(w))
					local fill = w:FindFirstChild("Remaining")
					if fill then
						s.change(fill, { BackgroundColor3 = K.YELLOW })
						table.insert(s.created, Kit.corner(fill))
					end
				elseif w:IsA("Frame") and w:FindFirstChild("ACCEPT") then
					s.change(w, { Size = UDim2.new(1, 0, 0, 40) })
					local row = w:FindFirstChildWhichIsA("UIListLayout")
					if row then
						s.change(row, { HorizontalFlex = Enum.UIFlexAlignment.Fill, Padding = UDim.new(0, 8) })
					end
					local accept, decline, focus = w:FindFirstChild("ACCEPT"), w:FindFirstChild("DECLINE"), w:FindFirstChild("FOCUS")
					if accept and accept:IsA("TextButton") then
						s.change(accept, { LayoutOrder = 1 })
						requestButton(s, accept, K.YELLOW, K.YELLOW_EDGE, K.YELLOW_TEXT, 4)
					end
					if decline and decline:IsA("TextButton") then
						s.change(decline, { LayoutOrder = 2 })
						requestButton(s, decline, K.RAISED, K.LINE, K.TEXT, 4)
					end
					-- Show: a small link next to the caption instead of a third big button.
					if focus and focus:IsA("TextButton") then
						s.change(focus, { Parent = req, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), Size = UDim2.fromOffset(64, 22), AutomaticSize = Enum.AutomaticSize.None, BackgroundTransparency = 1, TextTransparency = 1, AutoButtonColor = false, ZIndex = 3 })
						local link = make("Frame", { Name = "NightShow", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = focus })
						Kit.list(link, true, 4, { HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center })
						Kit.icon("Eye", { Size = UDim2.fromOffset(14, 14), ImageColor3 = K.CYAN, LayoutOrder = 1, ZIndex = 3, Parent = link })
						Kit.text({ Text = "Show", FontFace = F.TITLE, TextSize = 13, TextColor3 = K.CYAN, LayoutOrder = 2, ZIndex = 3, Parent = link })
						table.insert(s.created, link)
					end
				end
			end
		end
	end
end

-- "What's happening" lines (built by AlertsPanel): no inner box, each line a soft rounded row with
-- white text and a coloured dot for the kind of event (red lost / yellow attack / green good / cyan info).
local function styleFeedBox(s, box: Frame)
	keep(s, box, { BackgroundTransparency = 1 })
	for _, v in box:GetChildren() do
		if v:IsA("UIStroke") then
			keep(s, v, { Enabled = false })
		elseif v.Name == "Accent" and v:IsA("GuiObject") then
			s.change(v, { Visible = false })
		elseif v.Name == "Content" then
			local pad = v:FindFirstChildWhichIsA("UIPadding")
			if pad then
				s.change(pad, { PaddingLeft = UDim.new(), PaddingRight = UDim.new(), PaddingTop = UDim.new(), PaddingBottom = UDim.new() })
			end
			local list = v:FindFirstChildWhichIsA("UIListLayout")
			if list then
				s.change(list, { Padding = UDim.new(0, 4) })
			end
		end
	end
end
local function styleFeedRow(s, row: GuiObject, important: boolean)
	local tone = mapped(FG, (row :: any).TextColor3) or (row :: any).TextColor3
	s.change(row, { BackgroundColor3 = K.RAISED, BackgroundTransparency = if important then 0 else 0.35, TextColor3 = K.TEXT, TextSize = if important then 14 else 13, FontFace = F.TITLE, TextStrokeTransparency = 1 })
	table.insert(s.created, Kit.corner(row, 8))
	local pad = row:FindFirstChildWhichIsA("UIPadding")
	if pad then
		s.change(pad, { PaddingLeft = UDim.new(0, 22), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5) })
	end
	-- The dot sits outside the padding, so it hangs in the row's left margin.
	local dot = make("Frame", { Name = "NightDot", BackgroundColor3 = tone, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -14, 0, 9), Size = UDim2.fromOffset(7, 7), ZIndex = row.ZIndex + 1, Parent = row })
	Kit.corner(dot)
	table.insert(s.created, dot)
end

local function scaleOf(v: Instance): UIScale
	local sc = v:FindFirstChild("NightScale")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Name = "NightScale"
		sc.Parent = v
	end
	return sc :: UIScale
end

local function card(parent: Instance, name: string, props: { [string]: any }?): Frame
	local p = props or {}
	p.Name = name
	p.BackgroundColor3 = p.BackgroundColor3 or K.CARD
	p.BorderSizePixel = 0
	p.Parent = parent
	local c = make("Frame", p)
	Kit.corner(c, 12)
	Kit.stroke(c, K.LINE, 1.5)
	return c
end

local function short(n: number): string
	n = math.floor(n)
	if n >= 1e6 then
		return (string.gsub(string.format("%.1fM", n / 1e6), "%.0M", "M"))
	elseif n >= 1e3 then
		return (string.gsub(string.format("%.1fK", n / 1e3), "%.0K", "K"))
	end
	return tostring(n)
end

-- Pieces ----------------------------------------------------------------------------------------

function Layout.notice(s, text: string)
	if s.noticed[text] or not s.gui.Parent then
		return
	end
	s.noticed[text] = true
	local c = card(s.gui, "Notice", { AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(0, 46), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 70 })
	c:FindFirstChildWhichIsA("UIStroke").Color = K.YELLOW
	c:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
	Kit.pad(c, 16, 20)
	Kit.list(c, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon("Info", { Size = UDim2.fromOffset(22, 22), ImageColor3 = K.YELLOW, ZIndex = 71, LayoutOrder = 1, Parent = c })
	Kit.text({ Name = "Message", Text = text, FontFace = F.TITLE, TextSize = 18, ZIndex = 71, LayoutOrder = 2, Parent = c })
	scaleOf(c)
	s.notice = c
	Layout.place(s.api)
	task.delay(7, function()
		if c.Parent then
			c:Destroy()
		end
	end)
end

-- Hover / controller-selection card for a build tile.
local function tooltip(s, button: GuiButton, kind: string, costLabel: TextLabel?)
	local function show()
		local tip = s.tip
		s.tipFor = button
		s.tipName.Text = LONG_NAMES[kind] or NAMES[kind] or kind
		s.tipInfo.Text = INFO[kind] or ""
		Art.set(s.tipArt, if Art.has(kind) then kind else nil)
		s.tipArt.Visible = Art.has(kind)
		s.tipCost.Text = if costLabel then costLabel.Text .. " gold" else ""
		s.tipCost.TextColor3 = if costLabel then costLabel.TextColor3 else K.YELLOW
		local u = s.u
		scaleOf(tip).Scale = u
		local half = 125 * u
		local x = math.clamp(button.AbsolutePosition.X + button.AbsoluteSize.X / 2, half + 6, math.max(half + 6, s.gui.AbsoluteSize.X - half - 6))
		local top = math.min(button.AbsolutePosition.Y, s.bar.AbsolutePosition.Y)
		tip.Position = UDim2.fromOffset(x, top - s.gui.AbsolutePosition.Y - 8)
		tip.Visible = true
	end
	local function hide()
		if s.tipFor == button then
			s.tip.Visible = false
			s.tipFor = nil
		end
	end
	table.insert(s.connections, button.MouseEnter:Connect(show))
	table.insert(s.connections, button.MouseLeave:Connect(hide))
	table.insert(s.connections, button.SelectionGained:Connect(show))
	table.insert(s.connections, button.SelectionLost:Connect(hide))
end

-- A borrowed build choice button as a mockup tile: icon, short name, cost.
local function tile(s, entry, parent: Instance, order: number)
	local b = entry.button
	local kind = entry.action.kind
	keep(s, b, { BackgroundTransparency = 0, AutoButtonColor = false, Text = "" })
	s.change(b, { Parent = parent, LayoutOrder = order, AnchorPoint = Vector2.zero, Position = UDim2.new(), Size = UDim2.fromOffset(62, 66), ZIndex = 62, BackgroundColor3 = K.RAISED })
	-- CornerHud's own build popover hides the military choices; every tile stays visible here.
	keep(s, b, { Visible = true })
	for _, v in b:GetChildren() do
		if v.Name == "AngularShape" and v:IsA("GuiObject") then
			keep(s, v, { Visible = false })
		elseif v:IsA("ImageLabel") and Art.has(kind) then
			-- The owner's full-colour picture for this building / unit / nuke.
			local r = Art.IDS[kind]
			Art.set(v, kind)
			keep(s, v, { Image = r, ImageRectOffset = v.ImageRectOffset, ImageRectSize = v.ImageRectSize, ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 3), Size = UDim2.fromOffset(25, 25), ImageColor3 = Color3.new(1, 1, 1), ZIndex = 63 })
		elseif v:IsA("ImageLabel") then
			keep(s, v, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(20, 20), ImageColor3 = TINT[kind] or K.TEXT, ZIndex = 63 })
		elseif v.Name == "Name" and v:IsA("TextLabel") then
			-- Long names (Hydrogen Bomb) get a smaller fixed size. (TextScaled is not used: Roblox
			-- turns TextWrapped back on for scaled text, which fought the hook and froze Play.)
			-- Two-word names (Hydrogen Bomb, SAM Launcher) wrap onto two readable lines.
			local name = NAMES[kind] or v.Text
			keep(s, v, { Text = name, Position = UDim2.fromOffset(2, 27), Size = UDim2.new(1, -4, 0, 24), TextSize = 11, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Center, FontFace = F.TITLE, TextColor3 = K.TEXT, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.None, ZIndex = 63 })
		elseif v.Name == "Cost" and v:IsA("TextLabel") then
			keep(s, v, { Position = UDim2.fromOffset(1, 51), Size = UDim2.new(1, -2, 0, 12), TextSize = 10, FontFace = F.TITLE, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 63 })
			-- CornerHud writes the cost and its colour (gold / muted) every update: map to Night colours.
			hook(s, v, "TextColor3", function(o)
				local c = mapped(FG, o.TextColor3)
				if c and c ~= o.TextColor3 then
					s.change(o, { TextColor3 = c })
				end
			end, "cost")
		end
	end
	local c = b:FindFirstChildWhichIsA("UICorner")
	if c then
		keep(s, c, { CornerRadius = UDim.new(0, 10) })
	else
		table.insert(s.created, Kit.corner(b, 10))
	end
	local st = make("UIStroke", { Name = "NightEdge", Color = K.LINE, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
	table.insert(s.created, st)
	-- Keyboard key for this tile (top-left), filled from the real keybinds in refresh().
	local key = make("Frame", { Name = "NightKey", BackgroundColor3 = K.DEEP, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(15, 15), Visible = false, ZIndex = 64, Parent = b })
	Kit.corner(key, 4)
	local keyNumber = Kit.number(key, "", 10, K.MUTED)
	keyNumber.ZIndex = 65
	keyNumber.TextTransparency = 0.15
	table.insert(s.created, key)
	s.tiles[kind] = { button = b, cost = b:FindFirstChild("Cost"), stroke = st, entry = entry, key = key }
	tooltip(s, b, kind, b:FindFirstChild("Cost") :: TextLabel?)
	return b
end

local function roundButton(parent: Instance, name: string, icon: string, fill: Color3, iconColor: Color3, size: number): TextButton
	local b = make("TextButton", { Name = name, Text = "", AutoButtonColor = false, BackgroundColor3 = fill, BorderSizePixel = 0, Size = UDim2.fromOffset(size, size), SelectionImageObject = Kit.ring, ZIndex = 62, Parent = parent })
	Kit.corner(b)
	Kit.stroke(b, if fill == K.CARD then K.LINE else fill:Lerp(Color3.new(), 0.25), 1.5)
	Kit.icon(icon, { Name = "Icon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.5, 0.5), ImageColor3 = iconColor, ZIndex = 63, Parent = b })
	Kit.hover(b, function(st)
		b.BackgroundColor3 = if st == "idle" then fill else fill:Lerp(K.WHITE, 0.12)
	end)
	return b
end

local function menuRow(parent: Instance, order: number, icon: string, label: string, color: Color3?): TextButton
	local b = make("TextButton", { Name = "Row_" .. label, Text = "", AutoButtonColor = false, BackgroundColor3 = K.RAISED, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = order, SelectionImageObject = Kit.ring, ZIndex = 81, Parent = parent })
	Kit.corner(b, 10)
	Kit.pad(b, 12, 12)
	Kit.list(b, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon(icon, { Size = UDim2.fromOffset(18, 18), ImageColor3 = color or K.MUTED, ZIndex = 82, LayoutOrder = 1, Parent = b })
	Kit.text({ Name = "Label", Text = label, FontFace = F.TITLE, TextSize = 15, TextColor3 = if color == K.PINK then K.PINK else K.TEXT, ZIndex = 82, LayoutOrder = 2, Parent = b })
	local danger = color == K.PINK -- Leave battle: red on hover
	Kit.hover(b, function(st)
		if danger then
			local lit = st ~= "idle"
			b.BackgroundColor3 = if lit then Color3.fromRGB(214, 64, 86) else K.RAISED
			for _, c in b:GetChildren() do
				if c:IsA("TextLabel") then
					c.TextColor3 = if lit then K.WHITE else K.PINK
				elseif c:IsA("ImageLabel") then
					c.ImageColor3 = if lit then K.WHITE else K.PINK
				end
			end
			return
		end
		b.BackgroundColor3 = if st == "idle" then K.RAISED else K.RAISED:Lerp(K.WHITE, 0.08)
	end)
	return b
end

-- Mount ------------------------------------------------------------------------------------------

function Layout.mount(api)
	local ctx = api.ctx
	local s: any = { api = api, saved = {}, connections = {}, created = {}, hooks = setmetatable({}, { __mode = "k" }), trees = setmetatable({}, { __mode = "k" }), noticed = {}, loopSeen = {}, tiles = {}, rows = {}, u = 1, goldSamples = {} }
	-- The Development layout's id is kept ("Default"): CornerHud's sideStep then only positions the
	-- Boosts button instead of moving it into its own bar.
	api.development = s
	api.night = s
	function s.change(v: Instance, props: { [string]: any })
		local original = s.saved[v]
		if not original then
			original = {}
			s.saved[v] = original
		end
		for key, value in props do
			if original[key] == nil then
				original[key] = (v :: any)[key]
			end
			(v :: any)[key] = value
		end
	end

	local gui = make("ScreenGui", { Name = "NightBattleHud", IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = ctx.gui.DisplayOrder + 1, Enabled = false, Parent = ctx.gui.Parent })
	table.insert(s.created, gui)
	s.gui = gui

	-- Top: clock, win card, boosts + menu.
	s.clock = card(gui, "Clock", { Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 60 })
	s.clock:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
	Kit.pad(s.clock, 14, 16)
	Kit.list(s.clock, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon("Clock", { Size = UDim2.fromOffset(18, 18), ImageColor3 = K.MUTED, ZIndex = 61, LayoutOrder = 1, Parent = s.clock })
	s.time = Kit.text({ Text = "00:00", FontFace = F.TITLE, TextSize = 19, ZIndex = 61, LayoutOrder = 2, Parent = s.clock })
	s.rankPill = card(gui, "RankPill", { Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 60, Visible = false })
	s.rankPill:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
	Kit.pad(s.rankPill, 14, 14)
	s.rankText = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 16, TextColor3 = K.YELLOW, ZIndex = 61, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Parent = s.rankPill })
	local rankHit = make("TextButton", { Name = "Hit", Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = s.rankPill })
	rankHit.Activated:Connect(function()
		s.boardOpen = not s.boardOpen
		s.feedOpen = false
		Layout.place(api)
	end)

	s.goal = card(gui, "Win", { AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(300, 64), ZIndex = 60 })
	Kit.pad(s.goal, 14, 14, 8, 8)
	s.goalTitle = Kit.text({ Text = "Own 80% to win", FontFace = F.TITLE, TextSize = 15, TextColor3 = K.YELLOW, ZIndex = 61, Parent = s.goal })
	s.goalTop = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 13, TextColor3 = K.MUTED, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), ZIndex = 61, Parent = s.goal })
	local track = make("Frame", { Name = "Track", BackgroundColor3 = K.DEEP, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 8), ZIndex = 61, Parent = s.goal })
	Kit.corner(track)
	s.goalFill = make("Frame", { Name = "You", BackgroundColor3 = K.YELLOW, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 62, Parent = track })
	Kit.corner(s.goalFill)
	s.goalLeader = make("Frame", { Name = "Leader", BackgroundColor3 = K.CYAN, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(3, 14), ZIndex = 63, Parent = track })
	s.goalMark = make("Frame", { Name = "Goal", BackgroundColor3 = K.TEXT, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.8, 0.5), Size = UDim2.fromOffset(3, 14), ZIndex = 63, Parent = track })
	s.goalYou = Kit.text({ Text = "You 0%", FontFace = F.BOLD, TextSize = 13, TextColor3 = K.MUTED, Position = UDim2.fromOffset(0, 34), ZIndex = 61, Parent = s.goal })

	s.right = make("Frame", { Name = "TopRight", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 60, Parent = gui })
	Kit.list(s.right, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Right })
	s.boostsSlot = make("Frame", { Name = "BoostsSlot", BackgroundTransparency = 1, Size = UDim2.fromOffset(118, 40), LayoutOrder = 1, ZIndex = 60, Parent = s.right })
	s.skipTutorial = make("TextButton", { Name = "SkipTutorial", Text = "", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AutoButtonColor = false, Size = UDim2.fromOffset(142, 40), LayoutOrder = 0, ZIndex = 63, Visible = false, SelectionImageObject = Kit.ring, Parent = s.right })
	Kit.corner(s.skipTutorial)
	Kit.stroke(s.skipTutorial, Color3.fromRGB(247, 113, 119), 1.5)
	make("UIGradient", { Name = "SkipRedGradient", Color = ColorSequence.new(Color3.fromRGB(222, 70, 81), Color3.fromRGB(145, 32, 55)), Rotation = 90, Parent = s.skipTutorial })
	skipHex(s.skipTutorial)
	s.skipTutorialLabel = Kit.text({ Name = "Label", Text = "Skip tutorial", FontFace = F.TITLE, TextSize = 16, TextColor3 = K.TEXT, Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 64, Parent = s.skipTutorial })
	local skipConfirmUntil = 0
	local skipLeaving = false
	table.insert(s.connections, s.skipTutorial:GetPropertyChangedSignal("Visible"):Connect(function()
		skipConfirmUntil = 0
		if s.skipTutorial.Visible then skipLeaving = false end
		s.skipTutorialLabel.Text = "Skip tutorial"
	end))
	table.insert(s.connections, s.skipTutorial.Activated:Connect(function()
		if skipLeaving or not tutorialCanSkip() then return end
		if os.clock() >= skipConfirmUntil then
			skipConfirmUntil = os.clock() + 4
			local armed = skipConfirmUntil
			s.skipTutorialLabel.Text = "Are you sure?"
			task.delay(4, function()
				if s.skipTutorialLabel.Parent and skipConfirmUntil == armed and not skipLeaving then
					skipConfirmUntil = 0
					s.skipTutorialLabel.Text = "Skip tutorial"
				end
			end)
			return
		end
		skipLeaving = true
		s.skipTutorialLabel.Text = "Returning…"
		require(script.Parent:WaitForChild("Tutorial")).skip()
	end))
	local pg = Players.LocalPlayer.PlayerGui
	for _, attr in { "FrontlinesTutorial", "FrontlinesTutorialFinished", "FrontlinesMenuOpen" } do
		table.insert(s.connections, pg:GetAttributeChangedSignal(attr):Connect(function()
			set(s.skipTutorial, "Visible", tutorialCanSkip())
		end))
	end
	table.insert(s.connections, workspace:GetAttributeChangedSignal("WFMatchKind"):Connect(function()
		set(s.skipTutorial, "Visible", tutorialCanSkip())
	end))
	s.bell = roundButton(s.right, "Bell", "Bell", K.CARD, K.TEXT, 40)
	s.bell.LayoutOrder = 2
	s.bell.Visible = false
	s.bell.Activated:Connect(function()
		s.feedOpen = not s.feedOpen
		s.boardOpen = false
		Layout.place(api)
	end)
	s.menuButton = roundButton(s.right, "Menu", "Menu", K.CARD, K.TEXT, 40)
	s.menuButton.LayoutOrder = 3

	-- Menu dropdown: settings window, game speed / pause (solo), leave.
	s.menu = card(gui, "MatchMenu", { AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(220, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = K.PAGE, Visible = false, ZIndex = 80 })
	Kit.pad(s.menu, 8, 8, 8, 8)
	Kit.list(s.menu, false, 6)
	local settingsRow = menuRow(s.menu, 1, "Settings", "Settings and more")
	settingsRow.Activated:Connect(function()
		s.menu.Visible = false
		api.close()
		ctx.openMenu()
	end)
	s.speedSlot = make("Frame", { Name = "SpeedSlot", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 2, Visible = false, ZIndex = 81, Parent = s.menu })
	s.pauseSlot = make("Frame", { Name = "PauseSlot", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 3, Visible = false, ZIndex = 81, Parent = s.menu })
	local leaveRow = menuRow(s.menu, 4, "Door", "Leave battle", K.PINK)
	local armed = 0
	leaveRow.Activated:Connect(function()
		local label = leaveRow:FindFirstChild("Label") :: TextLabel
		if os.clock() < armed then
			armed = 0
			s.menu.Visible = false
			api.close()
			require(script.Parent:WaitForChild("PauseMenu")).exitGame()
		else
			armed = os.clock() + 3
			label.Text = "Tap again to leave"
			task.delay(3, function()
				if label.Parent and os.clock() >= armed then
					label.Text = "Leave battle"
				end
			end)
		end
	end)
	s.menuButton.Activated:Connect(function()
		s.menu.Visible = not s.menu.Visible
		s.nukesOpen = false
		Layout.place(api)
	end)

	-- Left: top players.
	s.board = card(gui, "TopPlayers", { Size = UDim2.fromOffset(272, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 60 })
	Kit.pad(s.board, 12, 12, 10, 10)
	Kit.list(s.board, false, 4)
	local boardHead = make("TextButton", { Name = "Head", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = -1, ZIndex = 61, Parent = s.board })
	-- Column labels, lined up over the rows' troops and land numbers.
	s.boardCols = make("Frame", { Name = "Columns", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 0, ZIndex = 61, Parent = s.board })
	Kit.text({ Text = "Troops", FontFace = F.TITLE, TextSize = 11, TextColor3 = K.MUTED, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -49, 0, 0), Size = UDim2.fromOffset(46, 14), AutomaticSize = Enum.AutomaticSize.None, ZIndex = 62, Parent = s.boardCols })
	Kit.text({ Text = "Land", FontFace = F.TITLE, TextSize = 11, TextColor3 = K.MUTED, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 0), Size = UDim2.fromOffset(38, 14), AutomaticSize = Enum.AutomaticSize.None, ZIndex = 62, Parent = s.boardCols })
	Kit.text({ Text = "Top players", FontFace = F.TITLE, TextSize = 16, ZIndex = 62, Parent = boardHead })
	s.boardChevron = Kit.icon("ChevronUp", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16), ImageColor3 = K.MUTED, ZIndex = 62, Parent = boardHead })
	boardHead.Activated:Connect(function()
		s.boardFolded = not s.boardFolded
		Layout.place(api)
	end)
	for i = 1, 5 do
		local row = make("TextButton", { Name = "Row" .. i, Text = "", AutoButtonColor = false, BackgroundColor3 = K.RAISED, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = i, Visible = false, SelectionImageObject = Kit.ring, ZIndex = 61, Parent = s.board })
		Kit.corner(row, 6)
		Kit.pad(row, 4, 4)
		Kit.list(row, true, 7, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local r: any = { button = row }
		r.rank = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 13, TextColor3 = K.MUTED, Size = UDim2.fromOffset(22, 20), AutomaticSize = Enum.AutomaticSize.None, ZIndex = 62, LayoutOrder = 1, Parent = row })
		r.dot = make("Frame", { BackgroundColor3 = K.CYAN, BorderSizePixel = 0, Size = UDim2.fromOffset(10, 10), LayoutOrder = 2, ZIndex = 62, Parent = row })
		Kit.corner(r.dot)
		r.name = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -138, 1, 0), AutomaticSize = Enum.AutomaticSize.None, ZIndex = 62, LayoutOrder = 3, Parent = row })
		-- Troops (fixed width, right-aligned so changing numbers don't shift the row).
		r.troops = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 13, TextColor3 = K.CYAN, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(46, 20), AutomaticSize = Enum.AutomaticSize.None, ZIndex = 62, LayoutOrder = 4, Parent = row })
		r.share = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 13, TextColor3 = K.MUTED, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(38, 20), AutomaticSize = Enum.AutomaticSize.None, ZIndex = 62, LayoutOrder = 5, Parent = row })
		row.Activated:Connect(function()
			if r.id and ctx.focusPlayer then
				ctx.focusPlayer(r.id)
			end
		end)
		s.rows[i] = r
	end

	-- Right: what's happening (ally requests on top, then the real feed).
	s.feed = card(gui, "Happening", { AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(260, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 60 })
	Kit.pad(s.feed, 10, 10, 10, 10)
	Kit.list(s.feed, false, 6)
	Kit.text({ Name = "Head", Text = "What's happening", FontFace = F.TITLE, TextSize = 16, Size = UDim2.new(1, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 61, LayoutOrder = 0, Parent = s.feed })
	-- Ally requests sit in their own stack under the card, so they're easy to spot.
	s.requests = make("Frame", { Name = "AllyRequests", AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Size = UDim2.fromOffset(260, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 60, Parent = gui })
	s.styledRequests = setmetatable({}, { __mode = "k" })
	s.feedBody = make("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 110), ClipsDescendants = true, LayoutOrder = 2, ZIndex = 61, Parent = s.feed })
	s.feedEmpty = Kit.text({ Text = "Nothing yet. Attacks, trades and requests show up here.", FontFace = F.BOLD, TextSize = 13, TextColor3 = K.MUTED, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 62, Parent = s.feedBody })

	Art.preload() -- battle pictures (bar, defeat and results screens) ready before they're needed

	-- Bottom: the command bar.
	-- Named like the Development bar: GamepadControls and Tutorial look for it by name.
	s.bar = card(gui, "DevelopmentNavbar", { AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(600, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 60 })
	s.bar:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0, 16)
	Kit.pad(s.bar, 14, 14, 10, 10)
	Kit.list(s.bar, false, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local stats = make("Frame", { Name = "Stats", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1, ZIndex = 61, Parent = s.bar })
	Kit.list(stats, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local troops = make("Frame", { Name = "Troops", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 1, ZIndex = 61, Parent = stats })
	Kit.flex(troops)
	s.troopArt = Art.image("Troops", { Position = UDim2.fromOffset(-1, -2), Size = UDim2.fromOffset(20, 20), ZIndex = 62, Parent = troops })
	s.troops = Kit.text({ Text = "", RichText = true, FontFace = F.TITLE, TextSize = 15, Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -80, 0, 18), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 62, Parent = troops })
	s.troopRate = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 13, TextColor3 = K.GREEN, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 1), ZIndex = 62, Parent = troops })
	local tbar = make("Frame", { BackgroundColor3 = K.DEEP, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, 22), Size = UDim2.new(1, 0, 0, 5), ZIndex = 62, Parent = troops })
	Kit.corner(tbar)
	s.troopFill = make("Frame", { BackgroundColor3 = K.CYAN, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 63, Parent = tbar })
	Kit.corner(s.troopFill)
	s.populationCount = make("Frame", { Name = "PopulationCount", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 7), Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, Visible = false, ZIndex = 62, Parent = troops })
	Kit.list(s.populationCount, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	make("Frame", { Name = "Divider", BackgroundColor3 = K.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 24), LayoutOrder = 2, ZIndex = 61, Parent = stats })
	-- Fixed width (not automatic): changing numbers must not shift the bar.
	local gold = make("Frame", { Name = "Gold", BackgroundTransparency = 1, Size = UDim2.new(0, 190, 1, 0), LayoutOrder = 3, ZIndex = 61, Parent = stats })
	Kit.list(gold, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	make("ImageLabel", { Name = "GoldIcon", Image = "rbxassetid://122263341747372", BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Size = UDim2.fromOffset(20, 20), ZIndex = 62, LayoutOrder = 1, Parent = gold }) -- the game's gold coin
	s.gold = Kit.text({ Text = "", RichText = true, FontFace = F.TITLE, TextSize = 15, ZIndex = 62, LayoutOrder = 2, Parent = gold })
	make("Frame", { Name = "Divider", BackgroundColor3 = K.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 24), LayoutOrder = 4, ZIndex = 61, Parent = stats })
	s.sendRow = make("Frame", { Name = "Send", BackgroundTransparency = 1, Size = UDim2.new(0, 236, 1, 0), LayoutOrder = 5, ZIndex = 61, Parent = stats })
	Art.image("SendTroops", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(22, 22), ZIndex = 62, Parent = s.sendRow })
	s.send = Kit.text({ Text = "Send 20%", FontFace = F.TITLE, TextSize = 15, TextColor3 = K.PINK, Position = UDim2.fromOffset(26, 0), Size = UDim2.fromOffset(78, 18), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 62, Parent = s.sendRow })
	s.sendTroops = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 13, TextColor3 = K.TEXT, Position = UDim2.fromOffset(26, 17), Size = UDim2.fromOffset(78, 14), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 62, Parent = s.sendRow })
	s.sliderSlot = make("Frame", { Name = "SliderSlot", BackgroundTransparency = 1, Position = UDim2.fromOffset(108, 0), Size = UDim2.new(1, -108, 1, 0), ZIndex = 61, Parent = s.sendRow })
	-- Phone: quick picks instead of the slider.
	s.picks = make("Frame", { Name = "QuickPicks", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 6, Visible = false, ZIndex = 61, Parent = stats })
	Kit.list(s.picks, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	s.pickButtons = {}
	s.pickFaces = {}
	for i, v in { 0.1, 0.3, 0.5, 1 } do
		local b = make("TextButton", { Name = "Pick" .. i, Text = if v == 1 then "All" else (v * 100) .. "%", FontFace = F.TITLE, TextSize = 14, TextColor3 = K.TEXT, AutoButtonColor = false, BackgroundColor3 = K.DEEP, BorderSizePixel = 0, Size = UDim2.fromOffset(46, 30), LayoutOrder = i, SelectionImageObject = Kit.ring, ZIndex = 62, Parent = s.picks })
		Kit.corner(b)
		local face = make("TextLabel", { Name = "CompactFace", Text = b.Text, FontFace = F.TITLE, TextSize = 13, TextColor3 = K.TEXT, BackgroundColor3 = K.DEEP, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(40, 40), Visible = false, Active = false, ZIndex = 61, Parent = b })
		Kit.corner(face, 7)
		s.pickFaces[v] = face
		b.Activated:Connect(function()
			if ctx.setRatio then
				ctx.setRatio(v)
			end
		end)
		s.pickButtons[v] = b
	end

	s.tileRow = make("Frame", { Name = "Tiles", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 66), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 61, Parent = s.bar })
	Kit.list(s.tileRow, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	-- Phone: Build and Nukes buttons open the tiles in a card instead.
	s.phoneButtons = make("Frame", { Name = "PhoneButtons", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(0, 70), AutomaticSize = Enum.AutomaticSize.X, Visible = false, ZIndex = 60, Parent = gui })
	Kit.list(s.phoneButtons, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Bottom })
	local function phoneButton(order: number, icon: string, label: string, fill: Color3, iconColor: Color3)
		local holder = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(52, 70), LayoutOrder = order, ZIndex = 60, Parent = s.phoneButtons })
		local b = roundButton(holder, label, icon, fill, iconColor, 52)
		Kit.text({ Text = label, FontFace = F.TITLE, TextSize = 12, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), ZIndex = 61, Parent = holder })
		return b
	end
	s.buildButton = phoneButton(1, "Building", "Build", K.YELLOW, K.YELLOW_TEXT)
	s.nukeButton = phoneButton(2, "Bomb", "Nukes", K.CARD, K.PINK)
	s.buildButton.Activated:Connect(function()
		s.phoneBuild = not s.phoneBuild
		s.nukesOpen = false
		Layout.place(api)
	end)
	s.nukeButton.Activated:Connect(function()
		s.nukesOpen = not s.nukesOpen
		s.phoneBuild = false
		Layout.place(api)
	end)
	-- The Nukes pop-up closes when the map is tapped (or held for the action wheel), so it never
	-- stays over the wheel or the player panel.
	table.insert(s.connections, game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
		if processed or not s.nukesOpen then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			s.nukesOpen = false
			Layout.place(api)
		end
	end))

	-- Nukes popup (above the Nukes tile / button).
	s.nukes = card(gui, "Nukes", { AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = K.PAGE, Visible = false, ZIndex = 75 })
	s.nukes:FindFirstChildWhichIsA("UIStroke").Color = K.PINK
	Kit.pad(s.nukes, 10, 10, 8, 10)
	Kit.list(s.nukes, false, 6)
	Kit.text({ Text = "Nukes", FontFace = F.TITLE, TextSize = 15, TextColor3 = K.PINK, ZIndex = 76, LayoutOrder = 0, Parent = s.nukes })
	s.nukeRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 58), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, ZIndex = 76, Parent = s.nukes })
	Kit.list(s.nukeRow, true, 6)
	Kit.text({ Text = "Needs a missile silo", FontFace = F.BOLD, TextSize = 12, TextColor3 = K.MUTED, ZIndex = 76, LayoutOrder = 2, Parent = s.nukes })

	-- Borrow the build buttons.
	local byKind = {}
	for _, entry in api.choices or {} do
		byKind[entry.action.kind] = entry
	end
	local order = 0
	for g, group in TILES do
		if g > 1 then
			order += 1
			make("Frame", { Name = "Gap" .. g, BackgroundColor3 = K.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 44), LayoutOrder = order, ZIndex = 61, Parent = s.tileRow })
		end
		for _, kind in group do
			local entry = byKind[kind]
			if entry then
				order += 1
				tile(s, entry, s.tileRow, order)
			end
		end
	end
	order += 1
	s.nukeTile = make("TextButton", { Name = "NukesTile", Text = "", AutoButtonColor = false, BackgroundColor3 = K.RAISED, BorderSizePixel = 0, Size = UDim2.fromOffset(62, 66), LayoutOrder = order, SelectionImageObject = Kit.ring, ZIndex = 62, Parent = s.tileRow })
	Kit.corner(s.nukeTile, 10)
	s.nukeTileStroke = Kit.stroke(s.nukeTile, K.PINK, 1.5)
	Art.image("AtomBomb", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 3), Size = UDim2.fromOffset(25, 25), ZIndex = 63, Parent = s.nukeTile })
	Kit.text({ Text = "Nukes", FontFace = F.TITLE, TextSize = 11, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 28), ZIndex = 63, Parent = s.nukeTile })
	s.nukeChevron = Kit.icon("ChevronUp", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 42), Size = UDim2.fromOffset(12, 12), ImageColor3 = K.PINK, ZIndex = 63, Parent = s.nukeTile })
	s.nukeTile.Activated:Connect(function()
		s.nukesOpen = not s.nukesOpen
		s.menu.Visible = false
		Layout.place(api)
	end)
	-- Nukes: on the bar after the silo (desktop / console); in the Nukes pop-up on phones.
	s.nukeOrder = order
	for i, kind in NUKES do
		local entry = byKind[kind]
		if entry then
			tile(s, entry, s.nukeRow, i)
			table.insert(s.connections, entry.button.Activated:Connect(function()
				s.nukesOpen = false
				Layout.place(api)
			end))
		end
	end
	for _, t in s.tiles do
		table.insert(s.connections, t.button.Activated:Connect(function()
			if s.phoneBuild then
				s.phoneBuild = false
				Layout.place(api)
			end
		end))
	end

	-- Tooltip card.
	s.tip = card(gui, "BuildTip", { AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(250, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, ZIndex = 90 })
	Kit.pad(s.tip, 12, 12, 10, 10)
	Kit.list(s.tip, false, 4)
	local tipHead = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 1, ZIndex = 91, Parent = s.tip })
	Kit.list(tipHead, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	s.tipArt = Art.image(nil, { Size = UDim2.fromOffset(36, 36), LayoutOrder = 1, ZIndex = 92, Parent = tipHead })
	s.tipName = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 17, ZIndex = 91, LayoutOrder = 2, Parent = tipHead })
	s.tipInfo = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 14, TextColor3 = K.MUTED, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 91, LayoutOrder = 2, Parent = s.tip })
	local costRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 3, ZIndex = 91, Parent = s.tip })
	Kit.list(costRow, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	make("ImageLabel", { Image = "rbxassetid://122263341747372", BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Size = UDim2.fromOffset(18, 18), ZIndex = 92, LayoutOrder = 1, Parent = costRow })
	s.tipCost = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 15, TextColor3 = K.YELLOW, ZIndex = 92, LayoutOrder = 2, Parent = costRow })

	-- Controller hints.
	s.hints = card(gui, "Hints", { AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, Visible = false, ZIndex = 60 })
	s.hints:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
	Kit.pad(s.hints, 12, 14)
	Kit.list(s.hints, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	for i, h in { { "A", K.GREEN, "Act" }, { "X", K.PURPLE, "Actions" }, { "Y", K.YELLOW, "Build" }, { "B", K.PINK, "Back" } } do
		local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i, ZIndex = 61, Parent = s.hints })
		Kit.list(row, true, 5, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local key = make("Frame", { BackgroundColor3 = h[2], BorderSizePixel = 0, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, ZIndex = 62, Parent = row })
		Kit.corner(key)
		Kit.number(key, h[1], 13, K.BG).ZIndex = 63
		Kit.text({ Text = h[3], FontFace = F.TITLE, TextSize = 14, LayoutOrder = 2, ZIndex = 62, Parent = row })
	end

	for _, v in { s.clock, s.rankPill, s.goal, s.right, s.menu, s.board, s.feed, s.requests, s.bar, s.nukes, s.phoneButtons, s.hints } do
		scaleOf(v)
	end

	-- The slider (keeps its drag handler; restyled as a pink track with a white knob).
	if api.slider then
		s.change(api.slider, { Parent = s.sliderSlot, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 24), ZIndex = 62, Visible = true })
		local rail = api.fill and api.fill.Parent
		if rail then
			keep(s, rail, { BackgroundColor3 = K.DEEP, Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0.5, -3), ZIndex = 62 })
			table.insert(s.created, Kit.corner(rail))
		end
		keep(s, api.fill, { BackgroundColor3 = K.PINK, ZIndex = 63 })
		table.insert(s.created, Kit.corner(api.fill))
		keep(s, api.knob, { BackgroundColor3 = K.WHITE, Size = UDim2.fromOffset(16, 16), ZIndex = 64 })
	end

	-- Wrap CornerHud's own layout steps so the Night positions always win (same frame).
	local oldAlerts, oldSide = api.layoutAlerts, api.sideStep
	api.layoutAlerts = function(...)
		oldAlerts(...)
		Layout.borrow(api)
	end
	api.sideStep = function(...)
		oldSide(...)
		Layout.borrow(api)
	end
	s.restoreWraps = function()
		api.layoutAlerts, api.sideStep = oldAlerts, oldSide
	end
	table.insert(s.connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		Layout.place(api)
	end))
	table.insert(s.connections, DeviceLayout.Changed:Connect(function()
		Layout.place(api)
	end))
	local acc = 0
	table.insert(s.connections, RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			Layout.refresh(api)
		end
	end))

	Layout.place(api)
	Layout.refresh(api)
	return function()
		for _, c in s.connections do
			c:Disconnect()
		end
		s.restoreWraps()
		for v, props in s.saved do
			if v.Parent then
				for key, value in props do
					pcall(function()
						(v :: any)[key] = value
					end)
				end
			end
		end
		for _, v in s.created do
			if typeof(v) == "Instance" then
				v:Destroy()
			end
		end
		api.development = nil
		api.night = nil
	end
end

-- Positions (desktop / phone / console), run after every CornerHud layout step.
local placeCount, refreshCount, countAt = 0, 0, 0
local spent = { place = 0, borrow = 0, refresh = 0, hooks = 0, borrows = 0, hookRuns = 0 }
Layout.spent = spent
function Layout.place(api)
	local s = api.night
	if not s or s.placing then
		return
	end
	placeCount += 1
	if os.clock() - countAt > 2 then
		local dt = os.clock() - countAt
		workspace:SetAttribute("WFNightHudRate", string.format("place %.0f/s refresh %.0f/s borrow %.0f/s hooks %.0f/s | ms per s: place %.1f borrow %.1f refresh %.1f hooks %.1f", placeCount / dt, refreshCount / dt, spent.borrows / dt, spent.hookRuns / dt, spent.place * 1000 / dt, spent.borrow * 1000 / dt, spent.refresh * 1000 / dt, spent.hooks * 1000 / dt))
		placeCount, refreshCount, countAt = 0, 0, os.clock()
		for k in spent do spent[k] = 0 end
	end
	s.placing = true
	local ctx = api.ctx
	local gui = s.gui
	local X, Y = gui.AbsoluteSize.X, gui.AbsoluteSize.Y
	if X < 2 then
		s.placing = false
		return
	end
	local state = ctx.device.state or {}
	local phone = (state.profile == "phone") or X < 700 or Y < 430
	s.phone = phone
	local u = if phone then 1 else math.clamp(math.min(X / 1280, Y / 720) * (ctx.device.userScale or 1), 0.7, 1.25)
	if state.profile == "console" then
		u *= 1.08
	end
	s.u = u
	for _, v in { s.goal, s.menu, s.board, s.feed, s.requests, s.bar, s.nukes, s.phoneButtons, s.hints } do
		set(scaleOf(v), "Scale", u)
	end
	local inset = GuiService.TopbarInset
	local topH = math.max(44, inset.Max.Y)
	local left = math.max(12, inset.Min.X + 8)
	local learning = Players.LocalPlayer.PlayerGui:GetAttribute("FrontlinesTutorial") == true

	-- Top row (in Roblox's top bar row).
	-- Same height as Roblox's own top-bar buttons (44 px) and centred on their line, whatever the
	-- screen size; the rest of the HUD keeps scaling with u.
	local topU = 44 / 40
	for _, v in { s.clock, s.rankPill, s.right } do
		set(scaleOf(v), "Scale", topU)
	end
	-- Roblox's buttons sit at the bottom of the top-bar inset (2 px above its edge), not in its middle.
	local topY = math.max(0, topH - 40 * topU - 2)
	set(s.clock, "Visible", not phone)
	set(s.clock, "Position", UDim2.fromOffset(left, topY))
	set(s.rankPill, "Visible", phone and not learning)
	set(s.rankPill, "Position", UDim2.fromOffset(if phone then 12 else left + (s.clock.AbsoluteSize.X + 8), if phone then topY + 52 else topY))
	set(s.right, "Position", UDim2.new(1, -12, 0, topY))
	set(s.skipTutorial, "Visible", tutorialCanSkip())
	set(s.skipTutorial, "Size", UDim2.fromOffset(if phone then 124 else 142, 40))
	set(s.skipTutorialLabel, "TextSize", if phone then 14 else 16)
	set(s.bell, "Visible", phone)
	set(s.goal, "Visible", not phone and not learning)
	set(s.goal, "Position", UDim2.new(0.5, 0, 0, 8))
	set(s.menu, "Position", UDim2.new(1, -12, 0, if phone then topY + 52 else topH + 4))
	local below = if phone then topH + 8 + (if s.rankPill.Visible then 48 else 0) else topH + 8

	-- Side cards.
	local showBoard = not learning and (not phone or s.boardOpen == true)
	set(s.board, "Visible", showBoard)
	set(s.board, "Position", UDim2.fromOffset(12, below))
	for _, r in s.rows do
		set(r.button, "Visible", r.id ~= nil and not s.boardFolded)
	end
	set(s.boardChevron, "Rotation", if s.boardFolded then 180 else 0)
	set(s.boardCols, "Visible", not s.boardFolded)
	set(s.feed, "Visible", not phone or s.feedOpen == true)
	if phone then
		set(s.feed, "AnchorPoint", Vector2.new(1, 0))
		set(s.feed, "Position", UDim2.new(1, -12, 0, below))
	else
		-- PC / console: bottom right, beside the command bar (owner: easier on the eyes). If the
		-- screen is too narrow for both side by side, it sits just above the bar instead.
		set(s.feed, "AnchorPoint", Vector2.new(1, 1))
		local room = X / 2 - (760 * u) / 2 - 24
		local lift = if room >= 260 * u then 12 else s.bar.AbsoluteSize.Y + 24
		set(s.feed, "Position", UDim2.new(1, -12, 1, -lift))
	end
	s.below = below

	-- Bottom. Compute final visibility once; AutoSize must not see a temporary hidden row.
	local showTiles = not phone or s.phoneBuild == true or (phone and learning)
	if phone and learning then s.phoneBuild = true end
	set(s.bar, "AutomaticSize", if phone then Enum.AutomaticSize.None else Enum.AutomaticSize.Y)
	set(s.bar, "Position", UDim2.new(0.5, 0, 1, -12))
	set(s.bar, "Size", UDim2.fromOffset(if phone then math.min(526, (X - 24) / u) else 760, if phone then (if showTiles then 122 else 52) else 0))
	local barPadding = s.bar:FindFirstChildWhichIsA("UIPadding")
	set(barPadding, "PaddingLeft", UDim.new(0, if phone then 8 else 14))
	set(barPadding, "PaddingRight", UDim.new(0, if phone then 8 else 14))
	set(barPadding, "PaddingTop", UDim.new(0, if phone then 4 else 10))
	set(barPadding, "PaddingBottom", UDim.new(0, if phone then 4 else 10))
	set(s.bar:FindFirstChildWhichIsA("UIListLayout"), "Padding", UDim.new(0, if phone then 4 else 8))
	set(s.tileRow, "Visible", showTiles)
	set(s.sendRow, "Visible", not phone)
	set(s.picks, "Visible", phone)
	set(s.picks, "Parent", s.sendRow.Parent)
	set(s.picks, "LayoutOrder", 6)
	local statsWidth = math.min(510, s.bar.Size.X.Offset - 16)
	local ratioWidth = 194
	local resourceWidth = statsWidth - ratioWidth - 96 - 26
	set(s.picks, "AutomaticSize", if phone then Enum.AutomaticSize.None else Enum.AutomaticSize.X)
	set(s.picks, "Size", UDim2.fromOffset(if phone then ratioWidth else 0, if phone then 44 else 30))
	set(s.picks:FindFirstChildWhichIsA("UIListLayout"), "HorizontalAlignment", Enum.HorizontalAlignment.Center)
	for value, b in s.pickButtons do
		set(s.pickFaces[value], "Visible", phone)
		set(b, "BackgroundTransparency", if phone then 1 else 0)
		set(b, "TextTransparency", if phone then 1 else 0)
		set(b, "TextSize", if phone then 13 else 14)
		set(b, "Size", UDim2.fromOffset(if phone then 44 else 46, if phone then 44 else 30))
		set(b:FindFirstChildWhichIsA("UICorner"), "CornerRadius", if phone then UDim.new(0, 8) else UDim.new(0.5, 0))
	end
	local stats = s.sendRow.Parent
	set(stats, "Size", if phone then UDim2.fromOffset(statsWidth, 44) else UDim2.new(1, 0, 0, 30))
	set(stats:FindFirstChildWhichIsA("UIListLayout"), "Padding", UDim.new(0, if phone then 6 else 12))
	set(stats.Troops:FindFirstChildWhichIsA("UIFlexItem"), "FlexMode", if phone then Enum.UIFlexMode.None else Enum.UIFlexMode.Fill)
	set(stats.Troops, "Size", UDim2.new(0, if phone then resourceWidth else 0, 1, 0))
	set(stats.Gold, "Size", UDim2.new(0, if phone then 96 else 190, 1, 0))
	set(stats.Gold:FindFirstChildWhichIsA("UIListLayout"), "HorizontalAlignment", if phone then Enum.HorizontalAlignment.Center else Enum.HorizontalAlignment.Left)
	set(s.populationCount, "Visible", phone)
	set(s.troops, "Parent", if phone then s.populationCount else stats.Troops)
	set(s.troopArt, "Parent", if phone then s.populationCount else stats.Troops)
	set(s.troopArt, "Position", if phone then UDim2.new() else UDim2.fromOffset(-1, -2))
	set(s.troopArt, "LayoutOrder", 1)
	set(s.troops, "LayoutOrder", 2)
	set(s.troops, "AutomaticSize", if phone then Enum.AutomaticSize.X else Enum.AutomaticSize.None)
	set(s.troops, "Size", if phone then UDim2.fromOffset(0, 18) else UDim2.new(1, -80, 0, 18))
	set(s.troops, "Position", if phone then UDim2.new() else UDim2.fromOffset(22, 0))
	local populationBar = s.troopFill.Parent
	set(populationBar, "AnchorPoint", if phone then Vector2.new(0.5, 0) else Vector2.zero)
	set(populationBar, "Position", if phone then UDim2.new(0.5, 0, 0, 32) else UDim2.fromOffset(0, 22))
	set(populationBar, "Size", if phone then UDim2.fromOffset(math.min(150, math.max(44, resourceWidth - 24)), 4) else UDim2.new(1, 0, 0, 5))
	set(s.troopRate, "Visible", not phone)
	for _, v in stats:GetChildren() do
		if v.Name == "Divider" then set(v, "Visible", true) end
	end
	local tilesLayout = s.tileRow:FindFirstChildWhichIsA("UIListLayout")
	set(tilesLayout, "Wraps", false)
	set(tilesLayout, "HorizontalAlignment", Enum.HorizontalAlignment.Center)
	set(s.tileRow, "LayoutOrder", 2)
	set(s.tileRow, "AutomaticSize", if phone then Enum.AutomaticSize.None else Enum.AutomaticSize.X)
	set(s.tileRow, "Size", if phone then UDim2.new(1, 0, 0, 66) else UDim2.fromOffset(0, 66))
	for _, v in s.tileRow:GetChildren() do
		if v:IsA("Frame") and string.sub(v.Name, 1, 3) == "Gap" then set(v, "Visible", not phone) end
	end
	set(s.phoneButtons, "Visible", phone and (not learning or Players.LocalPlayer.PlayerGui:GetAttribute("FrontlinesTutorialLesson") ~= nil))
	set(s.phoneButtons, "Position", UDim2.new(1, -12, 1, -(s.bar.AbsoluteSize.Y + 20)))
	-- showTiles already includes tutorial building access; do not toggle it again.
	set(s.nukeTile, "Visible", false) -- desktop shows every nuke on the bar; phones use the Nukes button
	for i, kind in NUKES do
		local t = s.tiles[kind]
		if t then
			set(t.button, "Parent", if phone then s.nukeRow else s.tileRow)
			set(t.button, "LayoutOrder", if phone then i else s.nukeOrder + i)
		end
	end
	if not phone and s.nukesOpen then
		s.nukesOpen = false
	end
	set(s.nukes, "Visible", s.nukesOpen == true)
	if s.nukesOpen then
		local anchor = if phone then s.nukeButton else s.nukeTile
		local ax = anchor.AbsolutePosition.X + anchor.AbsoluteSize.X / 2 - gui.AbsolutePosition.X
		local half = (s.nukes.AbsoluteSize.X / 2) + 6
		set(s.nukes, "Position", UDim2.fromOffset(math.clamp(ax, half, math.max(half, X - half)), anchor.AbsolutePosition.Y - gui.AbsolutePosition.Y - 8))
	end
	set(s.nukeChevron, "Rotation", if s.nukesOpen then 180 else 0)
	set(s.hints, "Visible", DeviceLayout.usingGamepad() or state.profile == "console")
	set(s.hints, "Position", UDim2.new(1, -12, 1, -(s.bar.AbsoluteSize.Y + 24)))

	-- Notice above the bar.
	if s.notice and s.notice.Parent then
		set(scaleOf(s.notice), "Scale", u)
		local label = s.notice:FindFirstChild("Message")
		set(s.notice, "AutomaticSize", if phone then Enum.AutomaticSize.None else Enum.AutomaticSize.X)
		set(s.notice, "Size", UDim2.fromOffset(if phone then math.min(300, X - 24) else 0, if phone then 64 else 46))
		if label then
			set(label, "TextWrapped", phone)
			set(label, "TextSize", if phone then 16 else 18)
			set(label, "AutomaticSize", if phone then Enum.AutomaticSize.Y else Enum.AutomaticSize.XY)
			set(label, "Size", if phone then UDim2.fromOffset(math.min(300, X - 24) - 68, 0) else UDim2.new())
		end
	end

	Layout.borrow(api)
	api.infoTop = 8 + 74 * u + 48
	api.infoBottom = api.infoTop + 40
	s.placing = false
end

-- Borrowed pieces only (cheap): re-applied every time CornerHud / HudSidebars move them, which
-- happens every frame; the full layout above runs a few times a second.
function Layout.borrow(api)
	local s = api.night
	if not s or s.borrowing then
		return
	end
	s.borrowing = true
	local ctx = api.ctx
	local gui = s.gui
	local X = gui.AbsoluteSize.X
	local phone = s.phone == true
	local u = s.u or 1
	local inset = GuiService.TopbarInset
	local topH = math.max(44, inset.Max.Y)
	local below = topH + 8
	local r = api.refs
	local ui = api.sidebar
	for _, v in { api.resources, api.attack, api.commands, api.round, api.utility, api.creditsButton, api.attacksPop, api.buildPop } do
		if v then
			set(v, "Visible", false)
		end
	end
	if ui then
		if ui.boosts then
			if not s.boostsStyled then
				s.boostsStyled = true
				for _, v in ui.boosts:GetChildren() do
					if v:IsA("ImageLabel") or v.Name == "Caption" or v.Name == "AngularShape" then
						keep(s, v, { Visible = false })
					end
				end
				table.insert(s.created, Kit.corner(ui.boosts))
				table.insert(s.created, Kit.stroke(ui.boosts, BOOST_EDGE, 1.5))
				-- Icon + word as one centred group (the button's own text stays empty).
				local group = make("Frame", { Name = "NightContent", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 64, Parent = ui.boosts })
				Kit.list(group, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
				Art.image("Boosts", { Name = "NightBolt", Size = UDim2.fromOffset(30, 30), ZIndex = 65, LayoutOrder = 1, Parent = group })
				s.boostsWord = Kit.text({ Text = "Boosts", FontFace = F.TITLE, TextSize = 16, TextColor3 = K.TEXT, ZIndex = 65, LayoutOrder = 2, Parent = group })
				table.insert(s.created, group)
				table.insert(s.connections, ui.boosts.Activated:Connect(function()
					s.menu.Visible = false
				end))
			end
			s.change(ui.boosts, { Parent = s.boostsSlot, AnchorPoint = Vector2.zero, Position = UDim2.new(), Size = if phone then UDim2.fromOffset(40, 40) else UDim2.fromOffset(118, 40), BackgroundColor3 = BOOST_FILL, BackgroundTransparency = 0, Text = "", ZIndex = 63 })
			if s.boostsWord then
				set(s.boostsWord, "Visible", not phone)
			end
			set(s.boostsSlot, "Size", if phone then UDim2.fromOffset(40, 40) else UDim2.fromOffset(118, 40))
			local sc = ui.boosts:FindFirstChildWhichIsA("UIScale")
			if sc then
				s.change(sc, { Scale = 1 })
			end
		end
		if ui.boostsPanel then
			-- BoostsPanel colours itself the Night way; only the frame is styled here.
			if not s.boostsPanelStyled then
				s.boostsPanelStyled = true
				table.insert(s.created, Kit.stroke(ui.boostsPanel, K.LINE, 1.5))
				for _, v in ui.boostsPanel:GetDescendants() do
					if v:IsA("TextLabel") and v.Text == "BOOSTS" then
						v.Text = "Boosts"
					end
				end
			end
			s.change(ui.boostsPanel, { Parent = gui, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, topH + 4), BackgroundColor3 = K.PAGE, BackgroundTransparency = 0, ZIndex = 80 })
			local sc = ui.boostsPanel:FindFirstChildWhichIsA("UIScale")
			if sc then
				s.change(sc, { Scale = u })
			end
			if ui.boostsPanel.Visible then
				s.menu.Visible = false
			end
		end
		-- Solo speed / pause buttons live in the menu.
		for _, pair in { { ui.speedBtn, s.speedSlot, "Game speed" }, { ui.pauseBtn, s.pauseSlot, "Pause" } } do
			local b, slot, label = pair[1], pair[2], pair[3]
			if b then
				slot.Visible = b.Visible
				if not s.trees[b] then
					s.trees[b] = true
					for _, v in b:GetChildren() do
						if v:IsA("ImageLabel") then
							keep(s, v, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(18, 18), ImageColor3 = K.MUTED, ZIndex = 83 })
						elseif v.Name == "AngularShape" and v:IsA("GuiObject") then
							keep(s, v, { Visible = false })
						end
					end
					local t = Kit.text({ Text = label, FontFace = F.TITLE, TextSize = 15, Position = UDim2.fromOffset(40, 0), Size = UDim2.new(1, -40, 1, 0), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 83, Parent = b })
					table.insert(s.created, t)
					table.insert(s.created, Kit.corner(b, 10))
				end
				s.change(b, { Parent = slot, AnchorPoint = Vector2.zero, Position = UDim2.new(), Size = UDim2.fromScale(1, 1), BackgroundColor3 = K.RAISED, BackgroundTransparency = 0, ZIndex = 82 })
			end
		end
		if ui.speedPanel then
			s.change(ui.speedPanel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12 - 228 * u, 0, topH + 4) })
		end
		if ui.clocks then
			s.change(ui.clocks, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, below + (if s.feed.Visible then s.feed.AbsoluteSize.Y + 8 else 0)) })
		end
	end
	if r then
		for _, v in { r.board, r.zoomIn, r.zoomOut } do
			if v and not phone then
				set(v, "Visible", false)
			end
		end
		-- Feed and ally requests inside the "What's happening" card.
		if r.feedFrame then
			if not s.trees[r.feedFrame] then
				paintTree(s, r.feedFrame)
			end
			s.change(r.feedFrame, { Parent = s.feedBody, AnchorPoint = Vector2.zero, Position = UDim2.new(), Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 62 })
			r.feedFrame:SetAttribute("WFLayoutHidden", false)
			local fsc = r.feedFrame:FindFirstChildWhichIsA("UIScale")
			if fsc then
				s.change(fsc, { Scale = 1 })
			end
			local requests = r.feedFrame:FindFirstChild("Requests") or s.requests:FindFirstChild("Requests")
			if requests and requests ~= s.requests then
				s.change(requests, { Parent = s.requests, AnchorPoint = Vector2.zero, Position = UDim2.new(), Size = UDim2.new(1, 0, 0, 0) })
				if not s.trees[requests] then
					paintTree(s, requests)
				end
			end
			if requests then
				for _, req in requests:GetChildren() do
					if req.Name == "Request" and req:IsA("Frame") and not s.styledRequests[req] then
						s.styledRequests[req] = true
						styleRequest(s, req)
					end
				end
			end
			if phone then
				-- Under "What's happening" (or at its spot when that card is hidden).
				local y = if s.feed.Visible then s.feed.AbsolutePosition.Y - s.gui.AbsolutePosition.Y + s.feed.AbsoluteSize.Y + 8 else (s.below or 52)
				set(s.requests, "AnchorPoint", Vector2.new(1, 0))
				set(s.requests, "Position", UDim2.new(1, -12, 0, y))
			else
				-- PC / console: stacked just above "What's happening" (bottom right).
				set(s.requests, "AnchorPoint", Vector2.new(1, 1))
				set(s.requests, "Position", UDim2.new(1, -12, 0, s.feed.AbsolutePosition.Y - s.gui.AbsolutePosition.Y - 8))
			end
			s.styledFeed = s.styledFeed or setmetatable({}, { __mode = "k" })
			for _, name in { "Events", "Important" } do
				local box = r.feedFrame:FindFirstChild(name)
				if box and box:IsA("Frame") then
					if not s.styledFeed[box] then
						s.styledFeed[box] = true
						styleFeedBox(s, box)
					end
					local content = box:FindFirstChild("Content")
					if content then
						for _, row in content:GetChildren() do
							if row.Name == "Event" and row:IsA("GuiObject") and not s.styledFeed[row] then
								s.styledFeed[row] = true
								styleFeedRow(s, row, name == "Important" or row:GetAttribute("Important") == true)
							end
						end
					end
				end
			end
			local has = false
			for _, v in r.feedFrame:GetChildren() do
				if v:IsA("GuiObject") and v.Visible and v.Name ~= "Requests" then
					has = true
				end
			end
			set(s.feedEmpty, "Visible", not has)
		end
		-- Status banner (spectating, battle over...) under the win card, Night pill.
		if r.banner then
			if not s.bannerStyled then
				s.bannerStyled = true
				table.insert(s.created, Kit.stroke(r.banner, K.LINE, 1.5))
				local c = r.banner:FindFirstChildWhichIsA("UICorner")
				if c then
					s.change(c, { CornerRadius = UDim.new(0.5, 0) })
				end
				for _, v in r.banner:GetDescendants() do
					if v.Name == "AngularShape" and v:IsA("GuiObject") then
						s.change(v, { Visible = false })
					elseif v:IsA("TextLabel") then
						paint(s, v) -- plain words for the banner text
					end
				end
			end
			s.change(r.banner, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8 + 74 * u + 48), BackgroundColor3 = K.CARD, BackgroundTransparency = 0 })
		end
		if r.stack then
			s.change(r.stack, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -(s.bar.AbsoluteSize.Y + 24 + (if s.notice and s.notice.Parent then 56 * u else 0))) })
		end
	end
	-- Hover card + start message (owned by other modules): Night colours and words.
	local screen = ctx.gui
	local msg = screen:FindFirstChild("HeadsUpMessage")
	if msg then
		paint(s, msg)
	end
	-- Short messages ("Not enough gold..."): Night pill under the win card and the Protected pill,
	-- so nothing overlaps.
	local toast = screen:FindFirstChild("Toast")
	if toast and toast:IsA("GuiObject") then
		if not s.toastStyled then
			s.toastStyled = true
			paintTree(s, toast)
			local c = toast:FindFirstChildWhichIsA("UICorner")
			if c then
				s.change(c, { CornerRadius = UDim.new(0.5, 0) })
			end
			s.change(toast, { BackgroundColor3 = K.CARD, BackgroundTransparency = 0 })
		end
		local top = if s.goal.Visible then s.goal.AbsolutePosition.Y + s.goal.AbsoluteSize.Y + 52 * s.u else s.gui.AbsolutePosition.Y + (s.below or 52)
		set(toast, "AnchorPoint", Vector2.new(0.5, 0))
		set(toast, "Position", UDim2.new(0.5, 0, 0, math.floor(top - (toast.Parent :: any).AbsolutePosition.Y)))
	end
	-- Attacks strip (MatchHud's AttacksDisplay: your attacks, attacks on you, boats, retreating, with
	-- Retreat / fight-back buttons). CornerHud keeps it in a popover this HUD hides, so it lives in
	-- its own dock just above the command bar, left-aligned with it, in the Night look.
	local list = (r and r.stack and r.stack:FindFirstChild("AttacksDisplay")) or (api.attackBody and api.attackBody:FindFirstChild("AttacksDisplay")) or (s.attackDock and s.attackDock:FindFirstChild("AttacksDisplay"))
	if not s.attackDock then
		-- fixed height (MatchHud's max list height): it sizes the list from its parent's height
		s.attackDock = make("Frame", { Name = "NightAttacks", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Size = UDim2.fromOffset(330, 112), ZIndex = 60, Parent = gui })
		table.insert(s.created, s.attackDock)
		scaleOf(s.attackDock)
	end
	local dock = s.attackDock
	if list and list.Parent ~= dock then
		s.change(list, { Parent = dock, Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1) }) -- rows sit on the bar
	end
	if list and not s.attacksStyled then
		s.attacksStyled = true
		paintTree(s, list)
		local function styleRow(row: Instance)
			if not row:IsA("Frame") then
				return
			end
			keep(s, row, { BackgroundColor3 = K.CARD, BackgroundTransparency = 0 })
			local c = row:FindFirstChildWhichIsA("UICorner")
			if c then
				s.change(c, { CornerRadius = UDim.new(0, 10) })
			end
			if not row:FindFirstChild("NightEdge") then
				local st = make("UIStroke", { Name = "NightEdge", Color = K.LINE, Thickness = 1, Transparency = 0.45, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = row })
				table.insert(s.created, st)
			end
		end
		for _, row in list:GetChildren() do
			styleRow(row)
		end
		table.insert(s.connections, list.ChildAdded:Connect(function(row)
			task.defer(styleRow, row)
		end))
	end
	if dock then
		scaleOf(dock).Scale = u
		local dockWidth = if phone then math.min(250, (s.bar.AbsoluteSize.X - (if s.phoneButtons.Visible then s.phoneButtons.AbsoluteSize.X + 8 else 0)) / u) else 330
		if list then
			local grid = list:FindFirstChildWhichIsA("UIGridLayout")
			if grid then s.change(grid, { CellSize = UDim2.new(1, -4, 0, if phone then 44 else 32) }) end
			for _, row in list:GetChildren() do
				if row:IsA("Frame") then
					local action = row:FindFirstChild("Action")
					local main = row:FindFirstChildWhichIsA("TextButton")
					local statusWidth = 0
					for _, child in row:GetChildren() do
						if child:IsA("TextLabel") and child.Visible and child.AutomaticSize == Enum.AutomaticSize.X then statusWidth = math.max(statusWidth, child.TextBounds.X + 8) end
					end
					if action then set(action, "Size", if phone then UDim2.fromOffset(44, 44) else UDim2.fromOffset(26, 22)) end
					if main and main ~= action then set(main, "Size", UDim2.new(1, -(if phone then math.max(48, statusWidth) else 30), 1, 0)) end
				end
			end
		end
		set(dock, "Size", UDim2.fromOffset(math.max(180, dockWidth), 112))
		local barPos = s.bar.AbsolutePosition - gui.AbsolutePosition
		set(dock, "Position", UDim2.fromOffset(math.floor(barPos.X), math.floor(barPos.Y - 8)))
		if s.notice and s.notice.Parent and s.notice.Visible then
			local noticeBottom = barPos.Y - 12
			if list and list.Visible then noticeBottom = math.min(noticeBottom, barPos.Y - 16 - list.AbsoluteSize.Y) end
			if phone and s.phoneButtons.Visible then noticeBottom = math.min(noticeBottom, s.phoneButtons.AbsolutePosition.Y - gui.AbsolutePosition.Y - 8) end
			set(s.notice, "AnchorPoint", Vector2.new(if phone then 1 else 0.5, 1))
			-- One position writer: place() only sizes the notice, preventing periodic jumps.
			set(s.notice, "Position", UDim2.fromOffset(math.floor(if phone then X - 12 else X / 2), math.floor(noticeBottom)))
		end
		set(dock, "Visible", s.bar.Visible)
	end
	s.borrowing = false
end

-- Numbers (4x a second and on every game update).
function Layout.refresh(api)
	local s = api.night
	if not s then
		return
	end
	refreshCount += 1
	local ctx = api.ctx
	s.gui.Enabled = api.root.Visible
	set(s.skipTutorial, "Visible", tutorialCanSkip())
	if not api.root.Visible then
		s.menu.Visible = false
		s.nukesOpen = false
		return
	end
	s.time.Text = api.timer.Text
	local mine = ctx.getMine()
	local st = mine and mine.stats
	local map = ctx.getMap()
	local land = math.max(1, map.landTiles or 1)
	local ph = api.lastPhase or {}
	local fraction = tonumber(ph.winPercent) or Config.WIN_FRACTION
	if fraction > 1 then
		fraction /= 100
	end
	s.goalTitle.Text = string.format("Own %d%% to win", math.floor(fraction * 100 + 0.5))
	s.goalMark.Position = UDim2.fromScale(fraction, 0.5)
	local alive = st ~= nil and st.alive
	s.bar.Visible = st ~= nil
	if st then
		local share = (st.tiles or 0) / land
		s.goalFill.Size = UDim2.fromScale(math.clamp(share, 0, 1), 1)
		s.goalYou.Text = string.format("You %.0f%%", share * 100)
		local troops, max = tonumber(st.troops) or 0, math.max(1, tonumber(st.maxTroops) or 1)
		s.troops.Text = string.format(if s.phone then '%s <font color="#bcc8e6">/ %s</font>' else '%s <font color="#bcc8e6">/ %s troops</font>', ctx.fmtTroops(troops), ctx.fmtTroops(max))
		local rate = if alive and ph.phase == "Play" then math.max(0, Config.troopGrowth(mine.kind, troops, max) / Config.TICK) else 0
		s.troopRate.Text = "+" .. ctx.fmtTroops(rate) .. "/s"
		s.troopFill.Size = UDim2.fromScale(math.clamp(troops / max, 0, 1), 1)
		-- Gold per second from the last few samples.
		local now = os.clock()
		table.insert(s.goldSamples, { now, tonumber(st.gold) or 0 })
		while #s.goldSamples > 2 and now - s.goldSamples[1][1] > 3 do
			table.remove(s.goldSamples, 1)
		end
		local first = s.goldSamples[1]
		local gps = if now - first[1] > 0.5 then math.max(0, ((tonumber(st.gold) or 0) - first[2]) / (now - first[1])) else 0
		s.gold.Text = if s.phone then string.format('%s <font color="#bcc8e6">gold</font>', short(st.gold or 0)) else string.format('%s <font color="#bcc8e6">gold</font> <font color="#7ee2a8">+%s/s</font>', ctx.fmt(st.gold or 0), short(gps))
		local ratio = api.lastRatio or 0.2
		s.send.Text = string.format("Send %d%%", math.floor(ratio * 100 + 0.5))
		s.sendTroops.Text = ctx.fmtTroops(troops * ratio) .. " troops"
		for v, b in s.pickButtons do
			local on = math.abs(ratio - v) < 0.02
			b.BackgroundColor3 = if on then K.PINK else K.DEEP
			set(s.pickFaces[v], "BackgroundColor3", b.BackgroundColor3)
			b.TextColor3 = if on then K.BG else K.TEXT
			set(s.pickFaces[v], "TextColor3", b.TextColor3)
		end
		for kind, t in s.tiles do
			local usable = ctx.usable(t.entry.action, st.gold or 0)
			t.button.BackgroundColor3 = K.RAISED
			-- Key badge (keyboard players only), same letter the game binds.
			local keyText = ""
			if api.refs and api.refs.actionButtons then
				for _, original in api.refs.actionButtons do
					if original.action.kind == kind and original.hotkey then
						keyText = original.hotkey.Text
						break
					end
				end
			end
			local keyboard = (ctx.device.state or {}).input ~= "Touch" and not DeviceLayout.usingGamepad()
			local num = t.key:FindFirstChild("Number") :: TextLabel?
			if num and num.Text ~= keyText then
				num.Text = keyText
			end
			t.key.Visible = keyboard and keyText ~= ""
			t.key.Size = UDim2.fromOffset(math.max(15, 7 * #keyText + 6), 15)
			for _, v in t.button:GetChildren() do
				if v:IsA("ImageLabel") then
					v.ImageTransparency = if usable then 0 else 0.45
				end
			end
		end
	end

	-- Top players (land %), you highlighted; you show as 5th when not in the top 4.
	local now = os.clock()
	if now - (s.lastRoster or 0) >= 0.35 then
		s.lastRoster = now
		local roster = ctx.getRoster and ctx.getRoster() or {}
		local myId = ctx.getMyId and ctx.getMyId() or (mine and mine.id)
		local sorted = {}
		for _, v in roster do
			if v.stats and v.stats.alive and (v.stats.tiles or 0) > 0 then
				table.insert(sorted, v)
			end
		end
		table.sort(sorted, function(a, b)
			if a.stats.tiles == b.stats.tiles then
				return a.id < b.id
			end
			return a.stats.tiles > b.stats.tiles
		end)
		local myRank
		for i, v in sorted do
			if v.id == myId then
				myRank = i
			end
		end
		local leader = sorted[1]
		if leader then
			local ls = (leader.stats.tiles or 0) / land
			s.goalTop.Text = string.format("Top: %s %.0f%%", if leader.id == myId then "You" else leader.name, ls * 100)
			s.goalLeader.Position = UDim2.fromScale(math.clamp(ls, 0, 1), 0.5)
		end
		s.rankText.Text = if myRank then (myRank .. (if myRank % 10 == 1 and myRank ~= 11 then "st" elseif myRank % 10 == 2 and myRank ~= 12 then "nd" elseif myRank % 10 == 3 and myRank ~= 13 then "rd" else "th") .. " \u{00B7} " .. string.format("%.0f%%", (sorted[myRank].stats.tiles or 0) / land * 100)) else "Watching"
		for i, r in s.rows do
			local rank = if i == 5 and myRank and myRank > 5 then myRank else i
			local v = sorted[rank]
			r.id = v and v.id
			if v then
				local me = v.id == myId
				r.rank.Text = tostring(rank)
				r.name.Text = if me then "You" else tostring(v.name)
				r.name.TextColor3 = if me then K.YELLOW else K.TEXT
				r.name.FontFace = if me then F.TITLE else F.BOLD
				r.share.Text = string.format("%.0f%%", (v.stats.tiles or 0) / land * 100)
				r.troops.Text = short(v.stats.troops or 0)
				r.dot.BackgroundColor3 = Color3.fromRGB(v.r or 0, v.g or 177, v.b or 235)
				r.button.BackgroundTransparency = if me then 0 else 1
			end
		end
	end
	Layout.place(api)
end

function Layout.layout(api)
	Layout.place(api)
end

function Layout.update(api, mine, me, phase, ratio)
	local s = api.night
	if not s then
		return
	end
	api.lastPhase = phase or api.lastPhase
	api.lastRatio = ratio or api.lastRatio
	-- CornerHud's update just re-showed its own panels: hide them in the same frame.
	for _, v in { api.resources, api.attack, api.commands, api.round, api.utility, api.creditsButton, api.attacksPop, api.buildPop } do
		if v and v.Visible then
			v.Visible = false
		end
	end
	local now = os.clock()
	if now - (s.lastUpdate or 0) < 0.1 then
		return
	end
	s.lastUpdate = now
	Layout.refresh(api)
end

-- Timing (temporary): time spent in each step, reported with WFNightHudRate.
for _, name in { "place", "borrow", "refresh" } do
	local f = Layout[name]
	Layout[name] = function(api)
		local t0 = os.clock()
		f(api)
		Layout.spent[name] += os.clock() - t0
		if name == "borrow" then
			Layout.spent.borrows += 1
		end
	end
end

return Layout
