-- War Front Night menu home screen. Copyright (C) 2026 Liam (lacedsc3ne).
-- Presentation only: MainMenu stays in charge of the round state, queues, tutorial, pages and
-- showing / hiding the menu around matches, and calls home.update(snapshot) whenever they change.
--
-- Home.create(ctx) -> home
--   ctx.open(kind)          open a menu page ("store", "inventory", "leaderboard", "clans", "settings",
--                           "help", "news", "profile", "host", "join", "solo", "upcoming")
--   ctx.play()              the big Play button (joins the main public battle)
--   ctx.joinLobby(kind)     join one of the public battles ("ffa" | "team" | "special")
--   ctx.leaveQueue()        stop waiting for a public battle
--   ctx.tutorial()          start the guided first battle
--   ctx.preview(id, width, cutout) -> EditableImage?   map picture (nil until it is ready)
--   ctx.snapshot() -> { role, phase, phaseLeft, mapId, mode, lobbies, queue, queuedKind, profile, name }
--   ctx.closePage()         MainMenu's closePage (pages call it through their own ctx.close)
--   ctx.meta(op, arg) -> (ok, result)   Shared.MetaFn call (profile, shop, inventory, rankings)
--   ctx.startTutorial(), ctx.mapPool() -> { MapCatalog info }, ctx.nameController() -> NameInput controller?
-- home.setVisible(on), home.update(snapshot?), home.toast(text, kind), home.back() -> closed something,
-- home.focus() -> the button a controller should select first
-- home.hasPage(kind), home.showPage(kind), home.hidePage()   pages from NightMenu.Pages (see PAGES below)
--
-- PAGES: NightMenu.Pages.<kind> modules return { title = string, render = function(page, pctx) -> cleanup? }.
-- page = Kit.page(...) (frame, header, body, back). pctx = {
--   gui, toast(text, kind), close(), open(kind), profile() -> profile?, onProfile(fn) (auto-disconnected),
--   meta(op, arg) -> (ok, result), popup(opts) -> Kit.popup (B / Esc close it first), layout() -> "desktop" |
--   "phone" | "console", startTutorial(), preview(id, width, cutout), mapPool(), nameController(), rerender() }

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local SocialService = game:GetService("SocialService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent:WaitForChild("Kit"))
local Feed = require(script.Parent:WaitForChild("Feed")) -- notifications (bell)
local Art = require(script.Parent:WaitForChild("Art")) -- full-colour illustrations (where an Art name is given)
local TeleportService = game:GetService("TeleportService")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local DeviceLayout = require(script.Parent.Parent:WaitForChild("DeviceLayout"))
local MapCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapCatalog"))
local UserInputService = game:GetService("UserInputService")
local LobbyPages = require(script.Parent.Parent:WaitForChild("LobbyPages")) -- open battles list (same as Enter a code)

local C, F = Kit.C, Kit.F
local make = Kit.make
local localPlayer = Players.LocalPlayer

local Home = {}

-- Plain words ---------------------------------------------------------------------------------

local function plainMode(sub: any): string
	if type(sub) ~= "string" or sub == "" then
		return "Everyone for themselves"
	end
	local low = string.lower(sub)
	if string.find(low, "free for all", 1, true) then
		return "Everyone for themselves"
	elseif low == "duos" then
		return "Pairs"
	elseif low == "trios" then
		return "Teams of 3"
	elseif low == "quads" then
		return "Teams of 4"
	elseif string.find(low, "humans vs nations", 1, true) then
		return "Humans vs computer"
	end
	local n = string.match(low, "^(%d+) teams")
	if n then
		return n .. " teams"
	end
	return string.upper(string.sub(sub, 1, 1)) .. string.lower(string.sub(sub, 2))
end
Home.plainMode = plainMode

local function mapName(id: string?): string
	for _, m in MapCatalog do
		if m.id == id then
			return m.name
		end
	end
	return id or "War Front"
end

local function clock(secs: number): string
	local s = math.max(0, math.ceil(secs))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function short(n: number): string
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local TIPS = {
	"Build cities to grow a bigger army.",
	"Ports send trade ships that earn you gold.",
	"Allies can't attack you. Breaking an alliance makes you a traitor!",
	"Send boats to attack across the sea.",
	"SAM launchers shoot down incoming nukes.",
	"Own 80% of the land to win the battle.",
}

-- Battle shown in the middle: the lobby you wait in, else the main public battle, else this server's round.
local function battleOf(snap): any
	local lobbies = snap.lobbies
	if lobbies then
		local kind = if snap.queuedKind and lobbies[snap.queuedKind] then snap.queuedKind else "ffa"
		local l = lobbies[kind] or lobbies.ffa or lobbies.team or lobbies.special
		if l then
			local left = if l.started then 0 elseif l.endAt then l.endAt - os.clock() else (l.default or 60)
			local sub = plainMode(l.sub)
			if type(l.mods) == "table" and l.mods[1] then
				sub ..= " · " .. tostring(l.mods[1])
			end
			return {
				kind = kind,
				map = l.map,
				name = l.name or mapName(l.map),
				sub = sub,
				count = tonumber(l.count) or 0,
				max = tonumber(l.max) or 50,
				left = left,
				total = tonumber(l.default) or 60,
				started = l.started == true,
				line = if l.started then "STARTING NOW" else "NEXT BATTLE IN " .. clock(left),
			}
		end
		return nil
	end
	local line = ""
	if snap.phase == "Lobby" then
		line = "NEXT BATTLE IN " .. clock(snap.phaseLeft or 0)
	elseif snap.phase == "Spawn" or snap.phase == "Play" then
		line = "BATTLE IN PROGRESS"
	elseif snap.phase == "Ended" then
		line = "BATTLE ENDING"
	end
	return {
		map = snap.mapId,
		name = mapName(snap.mapId),
		sub = plainMode(snap.mode),
		line = line,
	}
end

-- Countdown ring (EditableImage, redrawn only when the arc moves) --------------------------------

local RING = 128
local function newRing(): EditableImage?
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(RING, RING) })
	end)
	return if ok then img else nil
end

local function packColor(c: Color3, a: number): number
	return math.floor(c.R * 255) + math.floor(c.G * 255) * 256 + math.floor(c.B * 255) * 65536 + math.floor(a * 255) * 16777216
end

local function drawRing(img: EditableImage, fraction: number)
	local buf = buffer.create(RING * RING * 4)
	local half = RING / 2
	local outer, inner = half - 2, half - 14
	local limit = fraction * 2 * math.pi
	local track = C.RAISED
	local fill = C.YELLOW
	for y = 0, RING - 1 do
		for x = 0, RING - 1 do
			local dx, dy = x + 0.5 - half, y + 0.5 - half
			local d = math.sqrt(dx * dx + dy * dy)
			local a = math.clamp(math.min(outer - d, d - inner) + 0.5, 0, 1)
			if a > 0 then
				-- angle measured clockwise from 12 o'clock
				local ang = math.atan2(dx, -dy)
				if ang < 0 then
					ang += 2 * math.pi
				end
				buffer.writeu32(buf, (y * RING + x) * 4, packColor(if ang <= limit then fill else track, a))
			end
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(RING, RING), buf)
end

-- Small builders ---------------------------------------------------------------------------------

-- Makes a frame clickable by wrapping it in a same-sized transparent button (a click layer inside
-- the frame would be laid out by the frame's own UIListLayout).
local function clickable(frame: GuiObject, onClick: () -> ()): TextButton
	local b = make("TextButton", {
		Name = frame.Name,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = frame.Size,
		AutomaticSize = frame.AutomaticSize,
		Position = frame.Position,
		AnchorPoint = frame.AnchorPoint,
		LayoutOrder = frame.LayoutOrder,
		SelectionImageObject = Kit.ring,
		Parent = frame.Parent,
	})
	frame.Position = UDim2.new()
	frame.AnchorPoint = Vector2.zero
	frame.Parent = b
	b.Activated:Connect(onClick)
	Kit.hover(b, function(state)
		local stroke = frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if state == "idle" then (frame:GetAttribute("Stroke") or C.LINE) else C.MUTED
		end
	end)
	return b
end

-- Square-ish tile: big coloured icon over a short word (mode buttons, phone corner buttons).
local function tile(parent: Instance, icon: string, label: string, color: Color3, size: Vector2, order: number, onClick: () -> ()): TextButton
	local b = make("TextButton", {
		Name = "Tile_" .. label,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.CARD,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size.X, size.Y),
		LayoutOrder = order,
		SelectionImageObject = Kit.ring,
		Parent = parent,
	})
	Kit.corner(b, 12)
	local stroke = Kit.stroke(b)
	Kit.list(b, false, 2, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
	if Art.has(icon) then
		local artSize = math.floor(size.Y * 0.52)
		Art.image(icon, { Name = "Icon", Size = UDim2.fromOffset(artSize, artSize), LayoutOrder = 1, Parent = b })
	else
		local iconSize = math.floor(size.Y * 0.36)
		Kit.icon(icon, { Name = "Icon", Size = UDim2.fromOffset(iconSize, iconSize), ImageColor3 = color, LayoutOrder = 1, Parent = b })
	end
	Kit.text({ Name = "Label", Text = label, FontFace = F.TITLE, TextSize = math.max(13, math.floor(size.Y * 0.18)), LayoutOrder = 2, Parent = b })
	Kit.hover(b, function(state)
		b.BackgroundColor3 = if state == "idle" then C.CARD else C.CARD:Lerp(C.WHITE, 0.08)
		stroke.Color = if state == "idle" then C.LINE else C.MUTED
	end)
	b.Activated:Connect(onClick)
	return b
end

local function cardTitle(parent: Instance, icon: string, iconColor: Color3, label: string, size: number)
	local row = make("Frame", { Name = "Title", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, size + 4), LayoutOrder = 0, Parent = parent })
	Kit.list(row, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	if Art.has(icon) then
		Art.image(icon, { Size = UDim2.fromOffset(size + 10, size + 10), LayoutOrder = 1, Parent = row })
	else
		Kit.icon(icon, { Size = UDim2.fromOffset(size + 2, size + 2), ImageColor3 = iconColor, LayoutOrder = 1, Parent = row })
	end
	Kit.text({ Text = label, FontFace = F.TITLE, TextSize = size, LayoutOrder = 2, Parent = row })
	return row
end

local function muted(parent: Instance, textValue: string, size: number, order: number, color: Color3?): TextLabel
	return Kit.text({
		Text = textValue,
		FontFace = F.BOLD,
		TextSize = size,
		TextColor3 = color or C.MUTED,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = order,
		Parent = parent,
	})
end

-- Home -----------------------------------------------------------------------------------------

function Home.create(ctx)
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Background (full bleed, behind the notch) and content (inside Roblox's safe area).
	local bgGui = make("ScreenGui", {
		Name = "WarFrontNightBackground",
		DisplayOrder = 9,
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		Enabled = false,
		ScreenInsets = Enum.ScreenInsets.None,
		Parent = playerGui,
	})
	local bg = make("TextButton", {
		Name = "Backdrop",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundColor3 = C.BG,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = bgGui,
	})
	-- The next battle's map in its real colours (sea included), filling the whole screen, under a
	-- soft dark layer so the menu stays readable (owner: the faint boxed silhouette was hard to see).
	local mapImage = make("ImageLabel", {
		Name = "Map",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Crop,
		ImageTransparency = 0,
		Visible = false,
		Parent = bg,
	})
	local dim = make("Frame", { Name = "Dim", BackgroundColor3 = C.BG, BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = bg })
	make("UIGradient", {
		-- darker at the edges (side cards), lighter in the middle so the map shows behind Play
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(0.5, 0.42), NumberSequenceKeypoint.new(1, 0.18) }),
		Parent = dim,
	})

	local gui = make("ScreenGui", {
		Name = "WarFrontNight",
		DisplayOrder = 10,
		ResetOnSpawn = false,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		Parent = playerGui,
	})
	-- Header row (name, medals, profile, bell, settings) lives in Roblox's top bar, right of the Roblox
	-- buttons. Shown only with the home screen (pages have their own header).
	local topGui = make("ScreenGui", {
		Name = "WarFrontNightTop",
		DisplayOrder = 10,
		ResetOnSpawn = false,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.TopbarSafeInsets,
		Parent = playerGui,
	})
	local topHolder = make("Frame", { Name = "Holder", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = topGui })
	Art.preload()
	local canvas = make("Frame", { Name = "Canvas", BackgroundTransparency = 1, Parent = gui })
	local function syncTop()
		topGui.Enabled = gui.Enabled and canvas.Visible
	end
	gui:GetPropertyChangedSignal("Enabled"):Connect(syncTop)
	canvas:GetPropertyChangedSignal("Visible"):Connect(syncTop)
	local scale = make("UIScale", { Parent = canvas })
	local pageLayer = make("Frame", { Name = "PageLayer", BackgroundTransparency = 1, Visible = false, Parent = gui })
	local pageScale = make("UIScale", { Parent = pageLayer })
	local pagesFolder = script.Parent:WaitForChild("Pages", 5)
	local currentPage: string? = nil
	local pageCleanup: { () -> () } = {}
	local profileListeners: { (any) -> () } = {}
	local lastProfile = nil

	local home = {}
	local ui: any = {}
	local layoutKind = nil
	local friends: { any } = {}
	local friendsLoaded = false
	local popup = nil
	local shownMap = nil
	local tipIndex = math.random(1, #TIPS)
	local lastSnap = nil

	local function closePopup(): boolean
		if popup then
			local p = popup
			popup = nil
			p.close()
			return true
		end
		return false
	end

	local function invite()
		local ok, err = pcall(function()
			SocialService:PromptGameInvite(localPlayer)
		end)
		if not ok then
			Kit.toast(gui, "Invites aren't available right now", "error")
			warn("[War Front] invite prompt failed: " .. tostring(err))
		end
	end

	local function open(kind: string)
		return function()
			closePopup()
			ctx.open(kind)
		end
	end

	local function codePopup()
		closePopup()
		local api = LobbyPages.night
		if api.lobby() then
			ctx.open("host")
			return
		end
		local previousFocus = GuiService.SelectedObject
		local card = Kit.card({ Name = "EnterCodePopup", Active = true, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -24), Size = UDim2.fromOffset(530, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 50, Parent = gui })
		Kit.corner(card, 16)
		Kit.pad(card, 16, 16, 14, 14)
		Kit.list(card, false, 8)
		local p: any = { frame = card, card = card, codeEntry = true }
		local resizeConnection
		local motion
		local dismissing = false
		function p.close()
			if dismissing or not card.Parent then return end
			dismissing = true
			if popup == p then popup = nil end
			if resizeConnection then resizeConnection:Disconnect() end
			if motion then motion:Cancel() end
			if previousFocus and previousFocus.Parent then GuiService.SelectedObject = previousFocus end
			motion = TweenService:Create(card, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.new(0.5, 0, 1, math.max(180, card.AbsoluteSize.Y + 16)) })
			motion.Completed:Once(function() card:Destroy() end)
			motion:Play()
		end
		popup = p
		card.Position = UDim2.new(0.5, 0, 1, 180)
		local function fit()
			if dismissing then return end
			card.Size = UDim2.fromOffset(math.min(530, math.max(1, gui.AbsoluteSize.X - 24)), 0)
			if motion then motion:Cancel() end
			motion = TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 1, if layoutKind == "phone" then -80 else -24) })
			motion:Play()
		end
		resizeConnection = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		fit()
		local head = make("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1, Parent = card })
		Kit.list(head, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
		Kit.icon("Key", { Size = UDim2.fromOffset(24, 24), ImageColor3 = C.YELLOW, LayoutOrder = 1, Parent = head })
		Kit.text({ Text = "Enter a code", FontFace = F.TITLE, TextSize = 22, LayoutOrder = 2, Parent = head })
		local space = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 3, Parent = head })
		Kit.flex(space)
		local close = Kit.iconButton("Close", { name = "Close", size = 30, layoutOrder = 4, parent = head, onActivated = p.close })
		local row = make("Frame", { Name = "Entry", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 2, Parent = card })
		local box = make("TextBox", { Name = "Code", Text = "", PlaceholderText = "ABC123", PlaceholderColor3 = C.LINE, ClearTextOnFocus = false, FontFace = F.TITLE, TextSize = 26, TextColor3 = C.YELLOW, BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.new(1, -122, 1, 0), SelectionImageObject = Kit.ring, Parent = row })
		Kit.corner(box, 12)
		local boxStroke = Kit.stroke(box, C.LINE, 2)
		local helper = Kit.text({ Name = "Help", Text = "Ask your friend for their 6-character code.", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 3, Parent = card })
		local busy = false
		local join
		local function go()
			if busy or dismissing or not card.Parent then return end
			local code = string.upper((string.gsub(box.Text, "[^%w]", "")))
			if #code ~= 6 then
				helper.Text = "Codes are 6 letters and numbers. Check it and try again."
				helper.TextColor3 = C.PINK
				boxStroke.Color = C.PINK
				return
			end
			busy = true
			helper.Text = "Ask your friend for their 6-character code."
			helper.TextColor3 = C.MUTED
			boxStroke.Color = C.YELLOW
			Kit.setButtonText(join, "Joining…")
			api.join(code)
			task.delay(6, function()
				if card.Parent then
					busy = false
					Kit.setButtonText(join, "Join")
				end
			end)
		end
		join = Kit.button("primary", "Join", { name = "Join", height = 44, textSize = 20, size = UDim2.fromOffset(110, 44), parent = row, onActivated = go })
		join.AnchorPoint = Vector2.new(1, 0)
		join.Position = UDim2.fromScale(1, 0)
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local clean = string.upper(string.sub((string.gsub(box.Text, "[^%w]", "")), 1, 6))
			if clean ~= box.Text then box.Text = clean end
			helper.Text = "Ask your friend for their 6-character code."
			helper.TextColor3 = C.MUTED
			boxStroke.Color = if #clean == 6 then C.YELLOW else C.LINE
		end)
		box.FocusLost:Connect(function(enter) if enter then go() end end)
		box.NextSelectionRight = join
		join.NextSelectionLeft = box
		close.NextSelectionDown = box
		p.focus = box
		if DeviceLayout.usingGamepad() then GuiService.SelectedObject = box end
	end

	LobbyPages.onNightChange(function()
		if popup and popup.codeEntry and LobbyPages.night.lobby() then
			closePopup()
			ctx.open("host")
		end
	end)

	local MODES = {
		{ icon = "QuickBattle", color = C.YELLOW, title = "Quick battle", desc = "Jump into the next big battle with everyone", run = function()
			ctx.play()
		end },
		{ icon = "WithFriends", color = C.CYAN, title = "Play with friends", short = "With friends", desc = "Make your own battle and invite friends", run = function()
			ctx.open("host")
		end },
		{ icon = "Practice", color = C.GREEN, title = "Practice", short = "Practice", desc = "Play alone against computer players", run = function()
			ctx.open("solo")
		end },
		{ icon = "EnterCode", color = C.PURPLE, title = "Enter a code", short = "Enter code", desc = "Got a code from a friend? Join here", run = codePopup },
		{ icon = "HowToPlay", color = C.YELLOW, title = "How to play", short = "How to play", desc = "The tutorial and short lessons", run = function()
			ctx.open("help") -- tutorial button, chapters and lessons, then the controls
		end },
	}

	-- Popups (phone menus, ways to play, friends) ------------------------------------------------

	local function popupRow(parent: Instance, order: number, icon: string, color: Color3, title: string, desc: string?, onClick: () -> ())
		local row = make("TextButton", {
			Name = "Row_" .. title,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = C.CARD,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, if desc then 62 else 48),
			LayoutOrder = order,
			SelectionImageObject = Kit.ring,
			Parent = parent,
		})
		Kit.corner(row, 12)
		local stroke = Kit.stroke(row)
		Kit.pad(row, 10, 12)
		Kit.list(row, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
		if Art.has(icon) then
			Art.image(icon, { Size = UDim2.fromOffset(if desc then 48 else 34, if desc then 48 else 34), LayoutOrder = 1, Parent = row })
		else
			local badge = make("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(if desc then 42 else 30, if desc then 42 else 30), LayoutOrder = 1, Parent = row })
			Kit.corner(badge, 10)
			Kit.icon(icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), ImageColor3 = C.BG, Parent = badge })
		end
		local words = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1), LayoutOrder = 2, Parent = row })
		Kit.flex(words)
		Kit.list(words, false, 0, { VerticalAlignment = Enum.VerticalAlignment.Center })
		Kit.text({ Text = title, FontFace = F.TITLE, TextSize = 17, LayoutOrder = 1, Parent = words })
		if desc then
			muted(words, desc, 13, 2)
		end
		Kit.hover(row, function(state)
			stroke.Color = if state == "idle" then C.LINE else C.MUTED
		end)
		row.Activated:Connect(function()
			closePopup()
			onClick()
		end)
		return row
	end

	local function newPopup(title: string, width: number)
		closePopup()
		local p = Kit.popup(gui, { width = width, onClose = function()
			popup = nil
		end })
		popup = p
		Kit.list(p.card, false, 8)
		local head = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 0, Parent = p.card })
		Kit.list(head, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
		Kit.text({ Text = title, FontFace = F.TITLE, TextSize = 22, LayoutOrder = 1, Parent = head })
		local spacer = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 2, Parent = head })
		Kit.flex(spacer)
		local close = Kit.iconButton("Close", { size = 32, layoutOrder = 3, parent = head, onActivated = closePopup })
		return p, close
	end

	local function selectSoon(obj: GuiObject?)
		if obj and DeviceLayout.usingGamepad() then
			task.defer(function()
				if obj.Parent then
					GuiService.SelectedObject = obj
				end
			end)
		end
	end

	local function waysToPlay()
		local p = newPopup("Ways to play", 480)
		local first
		for i, m in MODES do
			local r = popupRow(p.card, i, m.icon, m.color, m.title, m.desc, m.run)
			first = first or r
		end
		selectSoon(first)
	end

	local function friendsPopup()
		local p = newPopup("Friends online", 400)
		local list = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = p.card })
		ui.popupFriends = list
		Kit.list(list, false, 6)
		local b = Kit.button("primary", "Invite friends", { icon = "UserPlus", height = 44, size = UDim2.new(1, 0, 0, 44), layoutOrder = 2, parent = p.card, onActivated = invite })
		home.update()
		selectSoon(b)
	end

	local function menuPopup()
		local p = newPopup("Menu", 360)
		local rows = {
			{ "Backpack", C.CYAN, "My items", "inventory" },
			{ "Shield", C.GREEN, "Clans", "clans" },
			{ "User", C.YELLOW, "Your profile", "profile" },
			{ "Season", C.CYAN, "Season pass", "season" },
			{ "Bell", C.YELLOW, "Notifications", "notifications" },
			{ "Help", C.MUTED, "How to play", "help" },
			{ "Settings", C.MUTED, "Settings", "settings" },
		}
		local first
		for i, r in rows do
			local row = popupRow(p.card, i, r[1], r[2], r[3], nil, open(r[4]))
			first = first or row
		end
		selectSoon(first)
	end

	-- Shared pieces --------------------------------------------------------------------------

	-- The middle: next battle line, map name, mode, Play, and the waiting view that replaces them.
	local function battleBlock(parent: Instance, big: boolean)
		local block = make("Frame", {
			Name = "Battle",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Size = UDim2.fromOffset(if big then 560 else 380, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = parent,
		})
		local ready = make("Frame", { Name = "Ready", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = block })
		Kit.list(ready, false, if big then 4 else 2, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		ui.line = Kit.text({ Name = "Line", Text = "", FontFace = F.TITLE, TextSize = if big then 18 else 14, TextColor3 = C.YELLOW, LayoutOrder = 1, Parent = ready })
		ui.mapName = Kit.text({ Name = "MapName", Text = "", FontFace = F.TITLE, TextSize = if big then 50 else 32, LayoutOrder = 2, Parent = ready })
		ui.sub = Kit.text({ Name = "Sub", Text = "", FontFace = F.BOLD, TextSize = if big then 17 else 14, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = ready })
		make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, if big then 10 else 6), LayoutOrder = 4, Parent = ready })
		ui.play = Kit.button("primary", "Play", {
			name = "Play",
			height = if big then 82 else 62,
			textSize = if big then 44 else 34,
			padX = if big then 96 else 70,
			layoutOrder = 5,
			parent = ready,
			onActivated = function()
				ctx.play()
			end,
		})
		ui.ready = ready

		local waiting = make("Frame", { Name = "Waiting", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Parent = block })
		Kit.list(waiting, false, if big then 12 else 6, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		ui.waitMap = Kit.text({ Name = "MapName", Text = "", FontFace = F.TITLE, TextSize = if big then 44 else 30, LayoutOrder = 1, Parent = waiting })
		ui.waitSub = Kit.text({ Name = "Sub", Text = "", FontFace = F.BOLD, TextSize = if big then 16 else 13, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = waiting })
		local ringSize = if big then 150 else 96
		local ringHolder = make("Frame", { Name = "Ring", BackgroundTransparency = 1, Size = UDim2.fromOffset(ringSize, ringSize), LayoutOrder = 3, Parent = waiting })
		local ringImg = make("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = ringHolder })
		local ring = newRing()
		if ring then
			ringImg.ImageContent = Content.fromObject(ring)
		end
		ui.ring, ui.ringFraction = ring, -1
		ui.ringTime = Kit.number(ringHolder, "0:00", if big then 38 else 26)
		local queued = Kit.chip("You're in!", { name = "Queued", color = C.YELLOW, textColor = C.YELLOW_TEXT, stroke = false, height = if big then 64 else 44, textSize = if big then 30 else 22, layoutOrder = 4, parent = waiting })
		local queuedPadding = queued:FindFirstChildOfClass("UIPadding")
		if queuedPadding then
			queuedPadding.PaddingLeft = UDim.new(0, if big then 24 else 18)
			queuedPadding.PaddingRight = UDim.new(0, if big then 24 else 18)
		end
		local actions = Kit.card({ Name = "Actions", Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 6, Parent = waiting })
		Kit.corner(actions, 18)
		Kit.pad(actions, if big then 12 else 8, if big then 12 else 8, if big then 10 else 6, if big then 10 else 6)
		Kit.list(actions, true, if big then 8 else 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
		ui.waitCount = Kit.chip("0 of 50 players", { name = "PlayerCount", icon = "Users", iconColor = C.CYAN, stroke = false, height = if big then 42 else 34, textSize = if big then 15 else 12, layoutOrder = 1, parent = actions })
		make("Frame", { Name = "CountDivider", BackgroundColor3 = C.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(1, if big then 30 else 24), LayoutOrder = 2, Parent = actions })
		Kit.button("secondary", "Invite a friend", { name = "Invite", icon = "UserPlus", height = if big then 42 else 34, textSize = if big then 16 else 12, padX = if big then 16 else 8, layoutOrder = 3, parent = actions, onActivated = invite })
		make("Frame", { Name = "LeaveDivider", BackgroundColor3 = C.LINE, BorderSizePixel = 0, Size = UDim2.fromOffset(1, if big then 30 else 24), LayoutOrder = 4, Parent = actions })
		ui.leave = Kit.button("ghost", "Leave queue", { name = "Leave", redHover = true, height = if big then 42 else 34, textSize = if big then 16 else 12, padX = if big then 12 else 6, layoutOrder = 5, parent = actions, onActivated = function()
			ctx.leaveQueue()
		end })
		ui.leave.Face.Label.TextColor3 = C.PINK
		if big then
			local tipCard = make("Frame", { Name = "Tip", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 7, Parent = waiting })
			Kit.list(tipCard, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Center })
			Kit.icon("Bulb", { Size = UDim2.fromOffset(18, 18), ImageColor3 = C.YELLOW, LayoutOrder = 1, Parent = tipCard })
			ui.tip = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, TextWrapped = true, LayoutOrder = 2, Parent = tipCard })
			make("UISizeConstraint", { MaxSize = Vector2.new(414, math.huge), Parent = ui.tip })
		end
		ui.waiting = waiting

		-- In a party (a custom battle made or joined): this replaces Play. The code with Copy, then the
		-- host's Start battle (members wait for the host) and Leave. No separate room screen.
		local room = make("Frame", { Name = "Room", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Parent = block })
		Kit.list(room, false, if big then 6 else 3, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		Kit.text({ Text = "YOU'RE IN A PARTY", FontFace = F.TITLE, TextSize = if big then 18 else 14, TextColor3 = C.YELLOW, LayoutOrder = 1, Parent = room })
		ui.roomName = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = if big then 42 else 28, LayoutOrder = 2, Parent = room })
		ui.roomSub = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = if big then 17 else 14, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = room })
		-- Code + Copy. Games can't write to the clipboard, so Copy selects the code for Ctrl+C
		-- (a long-press copies it on phones).
		local codeRow = make("Frame", { Name = "CodeRow", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, if big then 44 else 36), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 4, Parent = room })
		Kit.list(codeRow, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local codePill = make("Frame", { Name = "Code", BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.fromOffset(0, if big then 40 else 32), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = codeRow })
		Kit.corner(codePill)
		Kit.pad(codePill, 14, 14, 0, 0)
		Kit.list(codePill, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
		Kit.text({ Text = "Code", FontFace = F.BOLD, TextSize = if big then 15 else 13, TextColor3 = C.MUTED, LayoutOrder = 1, Parent = codePill })
		local codeBox = make("TextBox", { Name = "CodeText", Text = "", PlaceholderText = "", ClearTextOnFocus = false, TextEditable = true, FontFace = F.TITLE, TextSize = if big then 22 else 18, TextColor3 = C.YELLOW, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, if big then 40 else 32), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Parent = codePill })
		ui.roomCodeBox = codeBox
		codeBox:GetPropertyChangedSignal("Text"):Connect(function()
			-- read-only: put the code back if someone types into it
			local want = ui.roomCode or ""
			if codeBox.Text ~= want then
				codeBox.Text = want
			end
		end)
		Kit.button("secondary", "Copy", { name = "CopyCode", height = if big then 40 else 32, textSize = if big then 16 else 13, padX = 12, layoutOrder = 2, parent = codeRow, onActivated = function()
			local code = ui.roomCode or ""
			if code == "" then
				return
			end
			codeBox:CaptureFocus()
			codeBox.SelectionStart = 1
			codeBox.CursorPosition = #code + 1
			Kit.toast(gui, if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "Hold the code to copy it" else "Code selected: press Ctrl+C to copy", "info")
		end })
		local roomActions = make("Frame", { Name = "RoomActions", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, if big then 70 else 56), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 5, Parent = room })
		Kit.pad(roomActions, 0, 0, 8, 0)
		Kit.list(roomActions, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
		ui.roomOpen = Kit.button("primary", "Start battle", { name = "StartBattle", height = if big then 60 else 48, textSize = if big then 26 else 20, layoutOrder = 1, parent = roomActions, onActivated = function()
			local api = LobbyPages.night
			local l = api and api.lobby()
			if l and l.isHost then
				api.start()
			end
		end })
		Kit.button("danger", "Leave", { name = "LeaveRoom", height = if big then 48 else 40, layoutOrder = 2, parent = roomActions, onActivated = function()
			ctx.leaveRoom()
		end })
		ui.room = room
		return block
	end

	local function medalsChip(parent: Instance, order: number, height: number)
		local chip = Kit.chip("…", { icon = "Medal", iconColor = C.YELLOW, height = height, textSize = math.floor(height * 0.46), layoutOrder = order, parent = parent })
		local lineIcon = chip:FindFirstChild("Icon")
		if lineIcon then
			lineIcon:Destroy()
			Art.image("Medal", { Name = "Icon", Size = UDim2.fromOffset(height - 6, height - 6), LayoutOrder = 1, Parent = chip })
		end
		local plus = Kit.plusBadge(math.floor(height * 0.5))
		plus.LayoutOrder = 3
		plus.Parent = chip
		local pad = chip:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 8)
		end
		local list = chip:FindFirstChildOfClass("UIListLayout")
		if list then
			list.Padding = UDim.new(0, 6)
		end
		clickable(chip, open("store"))
		ui.medals = chip:FindFirstChild("Label")
		return chip
	end

	local function profileCard(parent: Instance, order: number)
		local card = Kit.card({ Name = "Profile", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
		Kit.pad(card, 14, 14, 12, 12)
		Kit.list(card, false, 6)
		local top = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 1, Parent = card })
		Kit.list(top, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local circle = make("Frame", { BackgroundColor3 = C.YELLOW, BorderSizePixel = 0, Size = UDim2.fromOffset(42, 42), LayoutOrder = 1, Parent = top })
		Kit.corner(circle)
		ui.level = Kit.number(circle, "1", 19, C.YELLOW_TEXT)
		ui.name = Kit.text({ Text = localPlayer.DisplayName, FontFace = F.TITLE, TextSize = 17, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, Parent = top })
		ui.seasonLabel = muted(card, "Season pass", 14, 2)
		local bar, setBar = Kit.progress(0, C.CYAN)
		bar.LayoutOrder = 3
		bar.Parent = card
		ui.setXp = setBar
		ui.xp = muted(card, "", 13, 4)
		clickable(card, open("season"))
		return card
	end

	local function missionsCard(parent: Instance, order: number)
		local card = Kit.card({ Name = "Missions", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
		Kit.pad(card, 14, 14, 12, 12)
		Kit.list(card, false, 4)
		local title = cardTitle(card, "Missions", C.YELLOW, "Today's missions", 16)
		ui.missionsBadge = Kit.chip("", { color = C.GREEN, textColor = C.GREEN_TEXT, stroke = false, height = 20, textSize = 12, layoutOrder = 3, parent = title })
		ui.missionsBadge.Visible = false
		local list = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
		Kit.list(list, false, 3)
		ui.missionsList = list
		muted(list, "Loading…", 14, 1)
		clickable(card, open("missions"))
		return card
	end

	local function friendsCard(parent: Instance, order: number)
		local card = Kit.card({ Name = "Friends", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
		Kit.pad(card, 14, 14, 12, 12)
		Kit.list(card, false, 6)
		cardTitle(card, "Friends", C.CYAN, "Friends online", 16)
		local list = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
		Kit.list(list, false, 4)
		ui.friendsList = list
		Kit.button("secondary", "Invite friends", { icon = "UserPlus", height = 36, textSize = 15, size = UDim2.new(1, 0, 0, 36), layoutOrder = 2, parent = card, onActivated = invite })
		return card
	end

	local function giftCard(parent: Instance, order: number)
		local card = Kit.card({ Name = "Gift", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
		card:SetAttribute("Stroke", C.YELLOW)
		card:FindFirstChildOfClass("UIStroke").Color = C.YELLOW
		Kit.pad(card, 14, 14, 12, 12)
		Kit.list(card, false, 6)
		cardTitle(card, "Gift", C.YELLOW, "Daily gift", 16)
		local days = make("Frame", { Name = "Days", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 1, Parent = card })
		Kit.list(days, true, 4, { HorizontalFlex = Enum.UIFlexAlignment.Fill })
		ui.giftDays = {}
		for d = 1, 7 do
			local dot = make("Frame", { BackgroundColor3 = C.DEEP, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), LayoutOrder = d, Parent = days })
			Kit.corner(dot, 4)
			ui.giftDays[d] = dot
		end
		ui.gift = muted(card, "", 13, 2)
		return card
	end

	-- "Coming up" card: the other public battles, one row each (globe, map, mode, time); tap to join.
	local function comingUp(parent: Instance, order: number)
		local card = Kit.card({ Name = "ComingUp", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Visible = false, Parent = parent })
		-- Rows own the horizontal padding so their hit areas reach both card edges.
		Kit.pad(card, 0, 0, 12, 8)
		Kit.list(card, false, 0, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		Kit.text({ Text = "COMING UP", FontFace = F.TITLE, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 0, Size = UDim2.new(1, -28, 0, 22), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, Parent = card })
		ui.comingCard = card
		ui.coming = {}
		for i, kind in { "team", "special" } do
			if i > 1 then
				make("Frame", { Name = "Divider_" .. kind, BackgroundColor3 = C.LINE, BorderSizePixel = 0, Size = UDim2.new(1, -28, 0, 1), LayoutOrder = i * 2 - 1, Parent = card })
			end
			local b = make("TextButton", {
				Name = "Coming_" .. kind,
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 52),
				LayoutOrder = i * 2,
				Visible = false,
				SelectionImageObject = Kit.ring,
				Parent = card,
			})
			Kit.pad(b, 14, 14)
			Kit.list(b, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
			Art.image("QuickBattle", { Size = UDim2.fromOffset(30, 30), LayoutOrder = 1, Parent = b })
			local words = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1), LayoutOrder = 2, Parent = b })
			Kit.flex(words)
			Kit.list(words, false, 0, { VerticalAlignment = Enum.VerticalAlignment.Center })
			local name = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 17, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 1, Parent = words })
			local sub = Kit.text({ Text = "", FontFace = F.BOLD, TextSize = 13, TextColor3 = C.MUTED, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, Parent = words })
			local time = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 17, LayoutOrder = 3, Parent = b })
			local row = { button = b, name = name, sub = sub, time = time, highlighted = false }
			Kit.hover(b, function(state)
				row.highlighted = state ~= "idle"
				name.TextColor3 = if row.highlighted or b:GetAttribute("Mine") then C.YELLOW else C.TEXT
			end)
			b.Activated:Connect(function()
				ctx.joinLobby(kind)
			end)
			ui.coming[kind] = row
		end
		return card
	end

	-- Open battles (custom battles anyone can join), under the mode buttons so matches are quick to find.
	-- Same list and join call as the Enter a code page (LobbyPages.night).
	local function openBattles(parent: Instance, order: number, big: boolean)
		local box = make("Frame", { Name = "OpenBattles", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = order, Parent = parent })
		Kit.pad(box, 0, 0, if big then 14 else 8, 0)
		Kit.list(box, false, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		if not big then
			return
		end
		local head = make("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.fromOffset(560, 28), LayoutOrder = 1, Parent = box })
		Kit.text({ Text = "Open battles", FontFace = F.TITLE, TextSize = 18, Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, Parent = head })

		local row = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, LayoutOrder = 2, Parent = box })
		Kit.list(row, true, 10)
		ui.battlesList = row
		ui.battlesSig = nil
	end

	local function drawOpenBattles()
		local api = LobbyPages.night
		local battles = api and api.list()
		if ui.battlesButton then
			local n = if battles then #battles else 0
			Kit.setButtonText(ui.battlesButton, if n > 0 then "Open battles (" .. n .. ")" else "Open battles")
		end
		local row = ui.battlesList
		if not row then
			return
		end
		-- Your own open battle is listed too: it shows "Your battle" and Open (back to your lobby).
		local mine = api and api.lobby()
		local mineCode = if mine then mine.code else nil
		local sig = (if battles == nil then "loading" else "") .. tostring(mineCode) .. "|"
		for i, e in battles or {} do
			if i > 3 then
				break
			end
			sig ..= string.format("%s:%s:%s:%s:%s;", tostring(e.code), tostring(e.count), tostring(e.max), tostring(e.map), tostring(e.randomMap))
		end
		if sig == ui.battlesSig then
			return
		end
		ui.battlesSig = sig
		for _, c in row:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if not battles or #battles == 0 then
			Kit.text({ Text = if battles then "None open right now. Make one with \"With friends\"." else "Looking for open battles…", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 1, Parent = row })
			return
		end
		for i, e in battles do
			if i > 3 then
				break
			end
			local card = Kit.card({ Name = "Battle_" .. tostring(e.code), Size = UDim2.fromOffset(176, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = row })
			Kit.pad(card, 12, 12, 10, 10)
			Kit.list(card, false, 4)
			Kit.text({ Text = if e.randomMap then "Random map" else api.mapName(e.map), FontFace = F.TITLE, TextSize = 16, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, Parent = card })
			local count, max = tonumber(e.count) or 0, tonumber(e.max) or 0
			local own = mineCode ~= nil and e.code == mineCode
			Kit.text({ Text = (if own then "Your battle" else tostring(e.hostName)) .. " · " .. count .. "/" .. max, FontFace = F.BOLD, TextSize = 13, TextColor3 = if own then C.YELLOW else C.MUTED, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2, Parent = card })
			if own then
				Kit.button("secondary", "Open", { name = "OpenMine", height = 34, textSize = 15, size = UDim2.new(1, 0, 0, 34), layoutOrder = 3, parent = card, onActivated = open("host") })
			elseif count >= max and max > 0 then
				Kit.text({ Text = "Full", FontFace = F.TITLE, TextSize = 15, TextColor3 = C.PINK, LayoutOrder = 3, Parent = card })
			else
				local code = e.code
				local b
				b = Kit.button("primary", "Join", { name = "Join", height = 34, textSize = 15, size = UDim2.new(1, 0, 0, 34), layoutOrder = 3, parent = card, onActivated = function()
					Kit.setButtonText(b, "Joining…")
					api.join(code)
				end })
			end
		end
	end

	local function renderFriends(list: Instance?, max: number, size: number)
		if not list then
			return
		end
		for _, c in list:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if not friendsLoaded then
			muted(list, "Looking for friends…", size, 1)
			return
		end
		if #friends == 0 then
			muted(list, "No friends online right now.", size, 1)
			return
		end
		for i, f in friends do
			if i > max then
				muted(list, "+ " .. (#friends - max) .. " more online", size - 1, i)
				break
			end
			local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, size + 8), LayoutOrder = i, Parent = list })
			Kit.list(row, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
			local dot = make("Frame", { BackgroundColor3 = if f.here then C.YELLOW else C.GREEN, BorderSizePixel = 0, Size = UDim2.fromOffset(8, 8), LayoutOrder = 1, Parent = row })
			Kit.corner(dot)
			Kit.text({ Text = f.name, FontFace = F.BOLD, TextSize = size, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, Parent = row })
			Kit.text({ Text = if f.lobby then "in the menu" elseif f.here then "in a battle" else "online", FontFace = F.BODY, TextSize = size - 2, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = row })
			if f.lobby and f.jobId and f.jobId ~= game.JobId then
				local gap = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 4, Parent = row })
				Kit.flex(gap)
				local placeId, jobId = f.placeId, f.jobId
				Kit.button("secondary", "Join", { height = size + 8, textSize = size - 1, padX = 10, layoutOrder = 5, parent = row, onActivated = function()
					-- Same as leaving and joining their lobby server; the profile hands over on leave.
					local ok, err = pcall(function()
						TeleportService:TeleportToPlaceInstance(placeId, jobId, localPlayer)
					end)
					if not ok then
						Kit.toast(gui, "Couldn't join your friend right now", "error")
						warn("[War Front] friend join failed: " .. tostring(err))
					else
						Kit.toast(gui, "Joining " .. f.name .. "…", "info")
					end
				end })
			end
		end
	end

	-- Layouts --------------------------------------------------------------------------------

	local function buildDesktop()
		-- Top bar (in Roblox's top bar row)
		local top = make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = topHolder })
		Kit.pad(top, 10, 12)
		Kit.list(top, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
		-- Logo: chunky outlined letters in the icons' cartoon style (no emblem: owner's call).
		local logo = make("Frame", { Name = "Logo", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = top })
		Kit.list(logo, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local function word(text: string, order: number, color: Color3, edge: Color3, gradient: ColorSequence?)
			local l = Kit.text({ Text = text, FontFace = F.TITLE, TextSize = 30, TextColor3 = color, LayoutOrder = order, Parent = logo })
			Kit.stroke(l, edge, 2.5).ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			if gradient then
				l.TextColor3 = Color3.new(1, 1, 1)
				make("UIGradient", { Color = gradient, Rotation = 90, Parent = l })
			end
			return l
		end
		word("WAR", 2, C.TEXT, Color3.fromRGB(10, 18, 40))
		word("FRONT", 3, C.YELLOW, Color3.fromRGB(58, 30, 0), ColorSequence.new(Color3.fromRGB(255, 226, 110), Color3.fromRGB(255, 150, 30)))
		local spacer = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 2, Parent = top })
		Kit.flex(spacer)
		medalsChip(top, 3, 40)
		Kit.iconButton("User", { name = "IconButton_Profile", size = 40, layoutOrder = 4, parent = top, onActivated = open("profile") })
		ui.bell = Kit.iconButton("Bell", { size = 40, layoutOrder = 5, parent = top, onActivated = open("notifications") })
		Kit.iconButton("Settings", { size = 40, layoutOrder = 6, parent = top, onActivated = open("settings") })

		-- Side columns
		local left = make("Frame", { Name = "Left", BackgroundTransparency = 1, Position = UDim2.fromOffset(24, 18), Size = UDim2.fromOffset(270, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = canvas })
		Kit.list(left, false, 12)
		profileCard(left, 1)
		missionsCard(left, 2)
		local right = make("Frame", { Name = "Right", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -24, 0, 18), Size = UDim2.fromOffset(270, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = canvas })
		Kit.list(right, false, 12)
		friendsCard(right, 1)
		giftCard(right, 2)
		-- Coming up: bottom left, level with the page buttons on the right.
		local coming = comingUp(canvas, 1)
		coming.AnchorPoint = Vector2.new(0, 1)
		coming.Position = UDim2.new(0, 24, 1, -18)
		coming.Size = UDim2.fromOffset(270, 0)

		-- Middle
		local battle = battleBlock(canvas, true)
		battle.Position = UDim2.new(0.5, 0, 0, 40)
		local modes = make("Frame", { Name = "Modes", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 92), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 6, Parent = ui.ready })
		Kit.pad(modes, 0, 0, 14, 0)
		Kit.list(modes, true, 10)
		for i = 2, 5 do
			local m = MODES[i]
			tile(modes, m.icon, m.short, m.color, Vector2.new(112, 88), i, m.run)
		end
		openBattles(ui.ready, 7, true)

		-- Bottom: coming up + page links
		local bottom = make("Frame", { Name = "Bottom", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 24, 1, -18), Size = UDim2.new(1, -48, 0, 40), Parent = canvas })
		Kit.list(bottom, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local gap = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 2, Parent = bottom })
		Kit.flex(gap)
		local links = {
			{ "Shop", "Shop", "store" },
			{ "Backpack", "My items", "inventory" },
			{ "Trophy", "Rankings", "leaderboard" },
			{ "Shield", "Clans", "clans" },
		}
		for i, l in links do
			Kit.button("secondary", l[2], { icon = l[1], iconColor = C.YELLOW, height = 40, textSize = 16, layoutOrder = 2 + i, parent = bottom, onActivated = open(l[3]) })
		end

		-- Controller hints (only while a controller is in use)
		local hints = make("Frame", { Name = "Hints", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -24, 1, -68), Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = canvas })
		Kit.list(hints, true, 16, { VerticalAlignment = Enum.VerticalAlignment.Center })
		for i, h in { { "A", C.GREEN, "Select" }, { "B", C.PINK, "Back" } } do
			local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i, Parent = hints })
			Kit.list(row, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
			local btn = make("Frame", { BackgroundColor3 = h[2], BorderSizePixel = 0, Size = UDim2.fromOffset(24, 24), LayoutOrder = 1, Parent = row })
			Kit.corner(btn)
			Kit.number(btn, h[1], 15, C.BG)
			Kit.text({ Text = h[3], FontFace = F.TITLE, TextSize = 16, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = row })
		end
		ui.hints = hints
	end

	local function buildPhone()
		local top = make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = topHolder })
		Kit.pad(top, 8, 10)
		Kit.list(top, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local circle = make("Frame", { BackgroundColor3 = C.YELLOW, BorderSizePixel = 0, Size = UDim2.fromOffset(38, 38), LayoutOrder = 1, Parent = top })
		Kit.corner(circle)
		ui.level = Kit.number(circle, "1", 17, C.YELLOW_TEXT)
		clickable(circle, open("profile"))
		local barHolder = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(90, 8), LayoutOrder = 2, Parent = top })
		local bar, setBar = Kit.progress(0, C.CYAN)
		bar.Size = UDim2.fromScale(1, 1)
		bar.BackgroundColor3 = C.RAISED -- the plain track would vanish against the background
		bar.Parent = barHolder
		ui.setXp = setBar
		local spacer = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 3, Parent = top })
		Kit.flex(spacer)
		medalsChip(top, 4, 36)
		Kit.iconButton("Menu", { size = 38, layoutOrder = 5, parent = top, onActivated = menuPopup })

		local battle = battleBlock(canvas, false)
		battle.Position = UDim2.new(0.5, 0, 0, 10)
		openBattles(ui.ready, 7, false)

		local tileSize = Vector2.new(66, 60)
		local leftTiles = make("Frame", { Name = "LeftTiles", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -10), Size = UDim2.fromOffset(0, tileSize.Y), AutomaticSize = Enum.AutomaticSize.X, Parent = canvas })
		Kit.list(leftTiles, true, 8)
		ui.missionsTile = tile(leftTiles, "Missions", "Missions", C.YELLOW, tileSize, 1, open("missions"))
		ui.giftTile = tile(leftTiles, "Gift", "Gift", C.YELLOW, tileSize, 2, function()
			local p = lastSnap and lastSnap.profile
			local day = tonumber(p and p.streak) or 0
			Kit.toast(gui, if day > 0 then "Day " .. day .. " gift collected. Come back tomorrow!" else "Come back every day for bigger gifts", "info")
		end)
		tile(leftTiles, "Friends", "Friends", C.CYAN, tileSize, 3, friendsPopup)

		local rightTiles = make("Frame", { Name = "RightTiles", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -10), Size = UDim2.fromOffset(0, tileSize.Y), AutomaticSize = Enum.AutomaticSize.X, Parent = canvas })
		Kit.list(rightTiles, true, 8)
		tile(rightTiles, "QuickBattle", "Modes", C.YELLOW, tileSize, 1, waysToPlay)
		tile(rightTiles, "Shop", "Shop", C.PINK, tileSize, 2, open("store"))
		tile(rightTiles, "WinBattle", "Ranks", C.GREEN, tileSize, 3, open("leaderboard"))
	end

	-- Device switching ---------------------------------------------------------------------------

	-- Studio testing: PlayerGui attribute WFNightForceLayout = "phone" | "desktop" | "console".
	local function forced(): string?
		local v = playerGui:GetAttribute("WFNightForceLayout")
		return if RunService:IsStudio() and type(v) == "string" and v ~= "" then v else nil
	end

	local function wantedLayout(): (string, Vector2, number)
		local ds = table.clone(DeviceLayout.state)
		ds.profile = forced() or ds.profile
		local size = gui.AbsoluteSize
		if size.X < 2 or size.Y < 2 then
			size = ds.screen or Vector2.new(1280, 720)
		end
		if ds.profile == "phone" then
			local base = Vector2.new(720, 340)
			return "phone", base, math.clamp(math.min(size.X / base.X, size.Y / base.Y), 0.7, 1.3)
		end
		local base = Vector2.new(1280, 700)
		local s = math.min(size.X / base.X, size.Y / base.Y)
		if ds.profile == "console" then
			s *= 1.08
		end
		return "desktop", base, math.clamp(s, 0.6, 1.8)
	end

	local showPage: (string) -> ()

	local function relayout()
		local kind, _base, s = wantedLayout()
		scale.Scale = s
		pageScale.Scale = s
		local size = gui.AbsoluteSize
		canvas.Size = UDim2.fromOffset(math.floor(size.X / s), math.floor(size.Y / s))
		pageLayer.Size = canvas.Size
		if kind ~= layoutKind and currentPage then
			layoutKind = kind
			ui = {}
			for _, c in canvas:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			topHolder:ClearAllChildren()
			if kind == "phone" then
				buildPhone()
			else
				buildDesktop()
			end
			showPage(currentPage)
			return
		end
		if kind ~= layoutKind then
			layoutKind = kind
			closePopup()
			for _, c in canvas:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			topHolder:ClearAllChildren()
			ui = {}
			if kind == "phone" then
				buildPhone()
			else
				buildDesktop()
			end
			home.update()
		end
		if ui.hints then
			ui.hints.Visible = DeviceLayout.usingGamepad() or forced() == "console"
		end
	end

	-- Updates ------------------------------------------------------------------------------------

	function home.update(snapArg: any?)
		local snap = snapArg or lastSnap or ctx.snapshot()
		lastSnap = snap
		if snap.profile ~= lastProfile then
			lastProfile = snap.profile
			for _, fn in table.clone(profileListeners) do
				task.spawn(fn, snap.profile)
			end
		end
		if not ui.play then
			return
		end
		local battle = battleOf(snap)
		local room = snap.room
		local waiting = not room and snap.queuedKind ~= nil and battle ~= nil and battle.kind == snap.queuedKind
		ui.ready.Visible = not waiting and not room
		ui.waiting.Visible = waiting
		ui.room.Visible = room ~= nil
		if room then
			local hostName = "Your"
			for _, m in room.members or {} do
				if m.host and not room.isHost then
					hostName = tostring(m.name) .. "'s"
				end
			end
			local s = room.settings or {}
			local count = #(room.members or {})
			ui.roomName.Text = hostName .. " party"
			ui.roomSub.Text = (if s.randomMap then "Random map" else mapName(s.map)) .. " · " .. count .. (if count == 1 then " player" else " players") .. (if room.isHost then "" else " · waiting for the host")
			local code = tostring(room.code or "")
			if ui.roomCode ~= code then
				ui.roomCode = code
				ui.roomCodeBox.Text = code
			end
			Kit.setButtonText(ui.roomOpen, if room.isHost then "Start battle" else "Waiting for the host")
			ui.roomOpen.Active = room.isHost == true
		end
		if battle then
			ui.line.Text = battle.line
			ui.mapName.Text = battle.name
			ui.sub.Text = battle.sub .. (if battle.count then " · " .. battle.count .. " of " .. battle.max .. " players" else "")
			if waiting then
				ui.ringTime.Text = if battle.started then "Go!" else clock(battle.left)
				ui.waitMap.Text = battle.name
				ui.waitSub.Text = battle.sub
				local label = ui.waitCount:FindFirstChild("Label")
				if label then
					label.Text = battle.count .. " of " .. battle.max .. " players"
				end
				if ui.tip then
					ui.tip.Text = TIPS[tipIndex]
				end
				if ui.ring then
					local f = if battle.started then 1 else 1 - math.clamp(battle.left / math.max(1, battle.total), 0, 1)
					if math.abs(f - ui.ringFraction) > 0.004 then
						ui.ringFraction = f
						drawRing(ui.ring, f)
					end
				end
			end
		else
			ui.line.Text = "FINDING BATTLES…"
			ui.mapName.Text = "War Front"
			ui.sub.Text = ""
		end

		-- Coming up: the other public battles
		if ui.coming then
			local any = false
			for kind, c in ui.coming do
				local l = snap.lobbies and snap.lobbies[kind]
				c.button.Visible = l ~= nil
				if l then
					any = true
					local left = if l.started then 0 elseif l.endAt then l.endAt - os.clock() else (l.default or 60)
					local mine = snap.queuedKind == kind
					c.button:SetAttribute("Mine", mine)
					c.name.Text = string.format("%s (%d/%d)", l.name or mapName(l.map), l.count or 0, l.max or Config.PUBLIC_MAX_PLAYERS)
					c.name.TextColor3 = if mine or c.highlighted then C.YELLOW else C.TEXT
					c.sub.Text = plainMode(l.sub)
					c.time.Text = if mine then "You're in" elseif l.started then "Starting" else clock(left)
					c.time.TextColor3 = if mine then C.YELLOW else C.TEXT
				end
			end
			local divider = ui.comingCard and ui.comingCard:FindFirstChild("Divider_special")
			if divider then
				divider.Visible = ui.coming.team.button.Visible and ui.coming.special.button.Visible
			end
			if ui.comingCard then
				ui.comingCard.Visible = any
			end
		end

		-- Background map
		if battle and battle.map then
			local img = ctx.preview(battle.map, 768, false)
			if img and shownMap ~= battle.map then
				local ok = pcall(function()
					mapImage.ImageContent = Content.fromObject(img)
				end)
				if ok then
					shownMap = battle.map
					mapImage.Visible = true
				end
			end
		end

		-- Profile
		local p = snap.profile
		if ui.medals then
			ui.medals.Text = if p then short(tonumber(p.coins) or 0) else "…"
		end
		if ui.level then
			ui.level.Text = if p then tostring(math.floor(tonumber(p.level) or 1)) else "…"
		end
		if ui.name then
			ui.name.Text = snap.name or localPlayer.DisplayName
		end
		if ui.setXp then
			-- Season pass progress (the circle shows the account level).
			local into, need = tonumber(p and p.seasonXpInto) or 0, tonumber(p and p.seasonXpNeed) or 1
			ui.setXp(into / math.max(1, need))
			if ui.seasonLabel then
				ui.seasonLabel.Text = if p then "Season pass · level " .. math.floor(tonumber(p.seasonLevel) or 0) else "Season pass"
			end
			if ui.xp then
				ui.xp.Text = if p then string.format("%s / %s season XP", short(into), short(need)) else "Loading…"
			end
		end
		-- Badges: rewards waiting (missions + season) and unread notifications.
		local ready = tonumber(p and p.missionsReady) or 0
		if ui.missionsBadge then
			ui.missionsBadge.Visible = ready > 0
			local label = ui.missionsBadge:FindFirstChild("Label")
			if label then
				label.Text = ready .. " ready"
			end
		end
		for _, holder in { ui.missionsTile, ui.bell } do
			local want = if holder == ui.bell then Feed.unread() > 0 else ready > 0
			local dot = holder:FindFirstChild("Dot")
			if want and not dot then
				dot = make("Frame", { Name = "Dot", BackgroundColor3 = C.PINK, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 2, 0, -2), Size = UDim2.fromOffset(12, 12), ZIndex = 5, Parent = holder })
				Kit.corner(dot)
				Kit.stroke(dot, C.BG, 2)
			elseif not want and dot then
				dot:Destroy()
			end
		end
		if ui.missionsList and p and (p ~= ui.missionsFor) then
			ui.missionsFor = p
			local list, mine = ui.missionsList, ui
			task.spawn(function()
				local ok, data = ctx.meta("missions")
				if mine ~= ui or not list.Parent then
					return
				end
				for _, c in list:GetChildren() do
					if c:IsA("GuiObject") then
						c:Destroy()
					end
				end
				if not ok or type(data) ~= "table" or type(data.daily) ~= "table" then
					muted(list, "Tap to see your missions.", 14, 1)
					return
				end
				for i, m in data.daily do
					local done = (tonumber(m.n) or 0) >= (tonumber(m.goal) or 1)
					local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = i, Parent = list })
					Kit.list(row, true, 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
					if not (m.claimed or done) and Art.mission(m.id) then
					Art.image(Art.mission(m.id), { Size = UDim2.fromOffset(18, 18), LayoutOrder = 1, Parent = row })
				else
					Kit.icon(if m.claimed or done then "CheckCircle" else "Missions", { Size = UDim2.fromOffset(14, 14), ImageColor3 = if m.claimed or done then C.GREEN else C.MUTED, LayoutOrder = 1, Parent = row })
				end
					local t = Kit.text({ Text = tostring(m.text) .. (if done then "" else " · " .. tostring(m.n) .. "/" .. tostring(m.goal)), FontFace = F.BOLD, TextSize = 13, TextColor3 = if m.claimed then C.MUTED elseif done then C.GREEN else C.TEXT, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 2, Parent = row })
					t.AutomaticSize = Enum.AutomaticSize.None
					t.Size = UDim2.new(1, -20, 1, 0)
					t.TextXAlignment = Enum.TextXAlignment.Left
				end
			end)
		end
		if ui.giftDays then
			local streak = tonumber(p and p.streak) or 0
			local today = if streak > 0 then (streak - 1) % 7 + 1 else 0
			for d, dot in ui.giftDays do
				dot.BackgroundColor3 = if d < today then C.GREEN elseif d == today then C.YELLOW else C.DEEP
			end
			ui.gift.Text = if streak > 0 then "Day " .. streak .. " collected. Come back tomorrow!" else "Come back every day for bigger gifts."
		end

		drawOpenBattles()
		renderFriends(ui.friendsList, 4, 15)
		if popup and ui.popupFriends and ui.popupFriends.Parent then
			renderFriends(ui.popupFriends, 8, 16)
		end
	end

	function home.setVisible(on: boolean)
		if not on then
			closePopup()
		end
		gui.Enabled = on
		bgGui.Enabled = on
		if on then
			if not currentPage then
				pageLayer.Visible = false
				canvas.Visible = true
			end
			relayout()
			home.update()
		end
	end

	function home.toast(textValue: string, kind: string?)
		Kit.toast(gui, textValue, kind)
	end

	-- Pages ----------------------------------------------------------------------------------------

	local function clearPage()
		closePopup()
		for _, fn in pageCleanup do
			local ok, err = pcall(fn)
			if not ok then
				warn("[War Front] page cleanup failed: " .. tostring(err))
			end
		end
		table.clear(pageCleanup)
		table.clear(profileListeners)
		for _, c in pageLayer:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
	end

	function home.hasPage(kind: string): boolean
		return pagesFolder ~= nil and pagesFolder:FindFirstChild(kind) ~= nil
	end

	showPage = function(kind: string)
		local mod = pagesFolder and pagesFolder:FindFirstChild(kind)
		if not mod then
			return
		end
		clearPage()
		currentPage = kind
		local phone = layoutKind == "phone"
		local holder = make("Frame", { Name = "Holder", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = pageLayer })
		Kit.pad(holder, if phone then 8 else 24, if phone then 8 else 24, if phone then 6 else 16, if phone then 6 else 20)
		local def = require(mod) :: any
		local page = Kit.page(holder, def.title or kind, { onBack = function()
			ctx.closePage()
		end, right = if def.headerRight then def.headerRight() else nil })
		if not phone then
			make("UISizeConstraint", { MaxSize = Vector2.new(1200, math.huge), Parent = page.frame })
			page.frame.AnchorPoint = Vector2.new(0.5, 0)
			page.frame.Position = UDim2.fromScale(0.5, 0)
		end
		local pctx = {
			gui = gui,
			kind = kind,
			toast = function(textValue: string, k: string?)
				Kit.toast(gui, textValue, k)
			end,
			close = function()
				ctx.closePage()
			end,
			open = function(k: string)
				ctx.open(k)
			end,
			profile = function()
				return lastSnap and lastSnap.profile
			end,
			onProfile = function(fn: (any) -> ())
				table.insert(profileListeners, fn)
			end,
			onCleanup = function(fn: () -> ())
				table.insert(pageCleanup, fn)
			end,
			meta = ctx.meta,
			popup = function(opts: any)
				closePopup()
				local o = table.clone(opts or {})
				local userClose = o.onClose
				o.onClose = function()
					popup = nil
					if userClose then
						userClose()
					end
				end
				local p = Kit.popup(gui, o)
				popup = p
				return p
			end,
			layout = function()
				local f = forced()
				return if f then f elseif layoutKind == "phone" then "phone" elseif DeviceLayout.state.profile == "console" then "console" else "desktop"
			end,
			startTutorial = ctx.startTutorial,
			preview = ctx.preview,
			mapPool = ctx.mapPool,
			nameController = ctx.nameController,
			rerender = function()
				if currentPage == kind then
					showPage(kind)
				end
			end,
		}
		local ok, cleanup = pcall(def.render, page, pctx)
		if not ok then
			warn("[War Front] Night page '" .. kind .. "' failed: " .. tostring(cleanup))
			Kit.text({ Text = "This page couldn't load. Try again in a moment.", FontFace = F.BOLD, TextColor3 = C.MUTED, Parent = page.body })
		elseif type(cleanup) == "function" then
			table.insert(pageCleanup, cleanup)
		end
		canvas.Visible = false
		pageLayer.Visible = true
		if DeviceLayout.usingGamepad() then
			task.defer(function()
				if page.back.Parent then
					GuiService.SelectedObject = page.back
				end
			end)
		end
	end

	function home.showPage(kind: string)
		gui.Enabled = true
		bgGui.Enabled = true
		relayout()
		showPage(kind)
	end

	function home.hidePage()
		if currentPage then
			currentPage = nil
			clearPage()
		end
		pageLayer.Visible = false
		canvas.Visible = true
	end

	function home.pageOpen(): string?
		return currentPage
	end

	function home.back(): boolean
		return closePopup()
	end

	function home.focus(): GuiObject?
		if popup and popup.focus then return popup.focus end
		if ui.waiting and ui.waiting.Visible then
			return ui.leave
		end
		if ui.room and ui.room.Visible then
			return ui.roomOpen
		end
		return ui.play
	end

	function home.isVisible(): boolean
		return gui.Enabled
	end

	-- Friends online (Roblox friends; refreshed every minute while the menu is open)
	task.spawn(function()
		while gui.Parent do
			if gui.Enabled or not friendsLoaded then
				local ok, list = pcall(function()
					return localPlayer:GetFriendsOnline(50)
				end)
				if ok and type(list) == "table" then
					local out = {}
					for _, f in list do
						-- GetFriendsOnline: PlaceId is the place they are in, GameId is that server's JobId.
						local inLobby = f.PlaceId == Config.LOBBY_PLACE_ID
						local inMatch = f.PlaceId == Config.MATCH_PLACE_ID
						table.insert(out, {
							name = f.DisplayName or f.UserName or "Friend",
							here = inLobby or inMatch,
							lobby = inLobby,
							placeId = f.PlaceId,
							jobId = if type(f.GameId) == "string" and f.GameId ~= "" then f.GameId else nil,
						})
					end
					table.sort(out, function(a, b)
						if a.here ~= b.here then
							return a.here
						end
						return a.name < b.name
					end)
					friends = out
				end
				friendsLoaded = true
				home.update()
			end
			task.wait(60)
		end
	end)

	-- Keep the open battles list fresh while the home screen shows (throttled inside LobbyPages).
	task.spawn(function()
		local first = true
		while gui.Parent do
			task.wait(2)
			if gui.Enabled and canvas.Visible and LobbyPages.night and not LobbyPages.night.lobby() then
				LobbyPages.night.askList(first)
				first = false
			end
		end
	end)

	-- A new tip each time the waiting view appears.
	local wasWaiting = false
	task.spawn(function()
		while gui.Parent do
			task.wait(0.5)
			local now = ui.waiting ~= nil and ui.waiting.Visible
			if now and not wasWaiting then
				tipIndex = tipIndex % #TIPS + 1
			end
			wasWaiting = now
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if gui.Enabled then
			relayout()
		end
	end)
	Feed.Changed:Connect(function()
		if gui.Enabled then
			home.update()
		end
	end)
	DeviceLayout.Changed:Connect(function()
		if gui.Enabled then
			relayout()
		end
	end)
	playerGui:GetAttributeChangedSignal("WFNightForceLayout"):Connect(function()
		if gui.Enabled then
			relayout()
		end
	end)

	return home
end

return Home
