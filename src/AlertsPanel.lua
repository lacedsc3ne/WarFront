--[[
	Frontlines (working title) - bottom-right alerts panel (event feed + alliance requests).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.AlertsPanel (ModuleScript), used by GameClient.
-- One place for in-match alerts, laid out like OpenFront's EventsDisplay + ActionableEvents
-- (src/client/hud/layers): from top to bottom
--   * minor events: small rows in a dark rounded box (latest 4),
--   * important events (ones about us, nukes, wins): bigger rows in a solid box with a red left
--     accent,
--   * alliance request cards (yellow left accent): "<Name> requests an alliance!" with
--     Focus (grey, pans to them), Accept (green) and Reject (blue).
-- Events fade out after EVENT_SECONDS. Clicking an event about a player focuses that player.
-- Gamepad: a new request selects its Accept button if nothing else is selected; D-pad up jumps
-- into the panel; B on a request card rejects it, B elsewhere in the panel leaves it.
-- DeviceLayout places the panel (its frame is GameClient's `feedFrame`) and calls setCompact().
-- AlertsPanel.create(ctx) -> Frame   ctx = { gui, roster, getMyId(), usingGamepad() }
-- AlertsPanel.bind(c)                 c = { focusPlayer(id), answer(fromId, accept) }
-- AlertsPanel.push(text, kind, owner?)
-- AlertsPanel.setRequests(incoming)   ContextMenu's list of { fromId, expiresAt, renew }
-- AlertsPanel.setFeedEnabled(on)      Settings "Event feed" (requests always show)
-- AlertsPanel.setCompact(on)          phone layout

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)

local AlertsPanel = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)

-- Tailwind colours OpenFront uses for these panels.
local GRAY800 = Color3.fromRGB(31, 41, 55)
local GRAY500 = Color3.fromRGB(107, 114, 128)
local GREEN600 = Color3.fromRGB(22, 163, 74)
local BLUE500 = Color3.fromRGB(59, 130, 246)
local RED500 = Color3.fromRGB(239, 68, 68)
local YELLOW400 = Color3.fromRGB(250, 204, 21)
local WHITE = Color3.new(1, 1, 1)

-- Severity text colours (OpenFront getMessageTypeClasses).
local SEVERITY = {
	fail = Color3.fromRGB(248, 113, 113), -- red-400
	warn = YELLOW400,
	success = Color3.fromRGB(74, 222, 128), -- green-400
	info = Color3.fromRGB(229, 231, 235), -- gray-200
	blue = Color3.fromRGB(96, 165, 250), -- blue-400
}
-- Server feed kinds -> severity.
local KIND_SEVERITY = {
	death = "fail",
	nuke = "fail",
	traitor = "fail",
	sam = "success",
	win = "success",
	ally = "success",
	attack = "warn",
	info = "info",
	chat = "info", -- QuickChat lines (MessageType.CHAT)
}
-- Kinds that go in the important box when they involve us (wins always do).
local IMPORTANT_KINDS = { death = true, nuke = true, traitor = true, ally = true, attack = true }

local EVENT_SECONDS = 8 -- OpenFront: 80 ticks
local MINOR_MAX, MINOR_MAX_COMPACT = 4, 2
local IMPORTANT_MAX, IMPORTANT_MAX_COMPACT = 6, 3
local REQUESTS_MAX, REQUESTS_MAX_COMPACT = 3, 2

local ctx: any = nil
local hooks: any = {}
local root: Frame
local minorBox: Frame
local importantBox: Frame
local minorRows: Frame
local importantRows: Frame
local requestsBox: Frame
local compact = false
local feedEnabled = true

local events: { any } = {} -- { text, kind, owner, important, at, row }
local cards: { [number]: any } = {} -- fromId -> { frame, title, accept, expiresAt, renew, order }

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

local function corner(parent: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
end

local function pad(parent: Instance, x: number, y: number)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, y),
		PaddingBottom = UDim.new(0, y),
		Parent = parent,
	})
end

local function list(parent: Instance, gap: number, horizontal: boolean?)
	return make("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap),
		Parent = parent,
	})
end

-- A rounded box (optionally with a left accent strip); rows go in the returned content frame.
local function box(name: string, transparency: number, accent: Color3?, order: number): (Frame, Frame)
	local f = make("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		LayoutOrder = order,
		Parent = root,
	})
	corner(f, 8)
	if accent then
		local a = make("Frame", {
			Name = "Accent",
			Size = UDim2.new(0, 4, 1, 0),
			BackgroundColor3 = accent,
			BorderSizePixel = 0,
			Parent = f,
		})
		corner(a, 2)
	end
	local content = make("Frame", {
		Name = "Content",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = f,
	})
	make("UIPadding", {
		PaddingLeft = UDim.new(0, if accent then 6 else 2),
		PaddingRight = UDim.new(0, 2),
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 2),
		Parent = content,
	})
	list(content, 0)
	return f, content
end

local function nowServer(): number
	return SimClock.now()
end

local function playerName(id: number): string
	local p = ctx and ctx.roster[id]
	return if p then p.name else "?"
end

local function isAboutMe(text: string, owner: number?): boolean
	local myId = ctx.getMyId()
	if myId == 0 then
		return false
	end
	if owner == myId then
		return true
	end
	local p = ctx.roster[myId]
	return p ~= nil and p.name ~= "" and string.find(text, p.name, 1, true) ~= nil
end

local function selectObj(obj: GuiObject?)
	if obj and obj.Parent and obj.Visible then
		GuiService.SelectedObject = obj
	end
end

local function selectionInside(): GuiObject?
	local sel = GuiService.SelectedObject
	if sel and root and sel:IsDescendantOf(root) then
		return sel
	end
	return nil
end

local function leaveSelection(frame: Instance)
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(frame) then
		GuiService.SelectedObject = nil
	end
end

-- Events
local function textSizes(): (number, number)
	if compact then
		return 11, 13
	end
	return 13, 16
end

local function makeRow(e)
	local small, big = textSizes()
	local focusable = e.owner ~= nil and e.owner ~= 0 and ctx.roster[e.owner] ~= nil
	local row = make(if focusable then "TextButton" else "TextLabel", {
		Name = "Event",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = if e.important then big else small,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = SEVERITY[KIND_SEVERITY[e.kind] or "info"] or SEVERITY.info,
		Text = e.text,
		LayoutOrder = e.order,
	})
	if focusable then
		local b = row :: TextButton
		b.AutoButtonColor = false
		b.Selectable = true
		b.Activated:Connect(function()
			if hooks.focusPlayer then
				hooks.focusPlayer(e.owner)
			end
		end)
	end
	pad(row, if compact then 6 else 8, if compact then 2 else 4)
	return row
end

local eventOrder = 0
local function layoutEvents()
	local t = os.clock()
	for i = #events, 1, -1 do
		local e = events[i]
		if t - e.at >= EVENT_SECONDS then
			if e.row then
				leaveSelection(e.row)
				e.row:Destroy()
			end
			table.remove(events, i)
		end
	end
	local minorMax = if compact then MINOR_MAX_COMPACT else MINOR_MAX
	local importantMax = if compact then IMPORTANT_MAX_COMPACT else IMPORTANT_MAX
	local nMinor, nImportant = 0, 0
	-- Newest first when counting, so the oldest drop off.
	for i = #events, 1, -1 do
		local e = events[i]
		local keep
		if e.important then
			nImportant += 1
			keep = nImportant <= importantMax
		else
			nMinor += 1
			keep = nMinor <= minorMax
		end
		keep = keep and feedEnabled
		if keep and not e.row then
			e.row = makeRow(e)
			e.row.Parent = if e.important then importantRows else minorRows
		elseif not keep and e.row then
			leaveSelection(e.row)
			e.row:Destroy()
			e.row = nil
		end
	end
	minorBox.Visible = feedEnabled and nMinor > 0
	importantBox.Visible = feedEnabled and nImportant > 0
end

function AlertsPanel.push(text: string, kind: string?, owner: number?)
	if not ctx then
		return
	end
	kind = kind or "info"
	eventOrder += 1
	table.insert(events, {
		text = text,
		kind = kind,
		owner = owner,
		important = kind == "win" or kind == "chat" or (IMPORTANT_KINDS[kind :: string] == true and isAboutMe(text, owner)),
		at = os.clock(),
		order = eventOrder,
	})
	while #events > 30 do
		local e = table.remove(events, 1)
		if e and e.row then
			leaveSelection(e.row)
			e.row:Destroy()
		end
	end
	layoutEvents()
end

-- Empties the event feed (entering / leaving a replay: its events belong to another round).
function AlertsPanel.clear()
	for _, e in events do
		if e.row then
			leaveSelection(e.row)
			e.row:Destroy()
		end
	end
	table.clear(events)
	if root then
		layoutEvents()
	end
end

function AlertsPanel.setFeedEnabled(on: boolean)
	feedEnabled = on
	if root then
		layoutEvents()
	end
end

-- Alliance request cards
local function cardTitle(fromId: number, renew: boolean): string
	if renew then
		return playerName(fromId) .. " wants to renew your alliance!"
	end
	return playerName(fromId) .. " requests an alliance!"
end

local function removeCard(fromId: number)
	local c = cards[fromId]
	if c then
		local hadSelection = selectionInside() ~= nil and GuiService.SelectedObject:IsDescendantOf(c.frame)
		leaveSelection(c.frame)
		c.frame:Destroy()
		cards[fromId] = nil
		-- Keep a gamepad user inside the panel if another request is waiting.
		if hadSelection then
			local nextId, best = nil, math.huge
			for id, other in cards do
				if other.order < best then
					nextId, best = id, other.order
				end
			end
			if nextId then
				selectObj(cards[nextId].accept)
			end
		end
	end
	requestsBox.Visible = next(cards) ~= nil
end

local function answer(fromId: number, accept: boolean)
	if hooks.answer then
		hooks.answer(fromId, accept)
	end
	removeCard(fromId)
end

local function cardButton(parent: Instance, text: string, color: Color3, order: number): TextButton
	local b = make("TextButton", {
		Name = text,
		Size = UDim2.fromOffset(0, if compact then 26 else 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Selectable = true,
		FontFace = FONT_BOLD,
		TextSize = if compact then 12 else 13,
		TextColor3 = WHITE,
		Text = text,
		LayoutOrder = order,
		Parent = parent,
	})
	corner(b, 4)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = b })
	return b
end

local cardOrder = 0
local function newCard(fromId: number)
	cardOrder += 1
	local frame = make("Frame", {
		Name = "Request",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
		LayoutOrder = -cardOrder, -- newest on top, like OpenFront
		Parent = requestsBox,
	})
	corner(frame, 8)
	local accent = make("Frame", { Name = "Accent", Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = YELLOW400, BorderSizePixel = 0, Parent = frame })
	corner(accent, 2)
	local inner = make("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = frame,
	})
	pad(inner, if compact then 10 else 12, if compact then 8 else 10)
	list(inner, if compact then 6 else 8)
	local title = make("TextButton", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Selectable = false,
		FontFace = FONT_BOLD,
		TextSize = if compact then 13 else 15,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = SEVERITY.info,
		Text = "",
		LayoutOrder = 1,
		Parent = inner,
	})
	local buttons = make("Frame", {
		Size = UDim2.new(1, 0, 0, if compact then 26 else 30),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = inner,
	})
	list(buttons, 6, true)
	local focus = cardButton(buttons, "Focus", GRAY500, 1)
	local accept = cardButton(buttons, "Accept", GREEN600, 2)
	local reject = cardButton(buttons, "Reject", BLUE500, 3)
	for _, b in { focus, accept, reject } do
		b:SetAttribute("AlertRequestFrom", fromId)
	end
	local function goTo()
		if hooks.focusPlayer then
			hooks.focusPlayer(fromId)
		end
	end
	title.Activated:Connect(goTo)
	focus.Activated:Connect(goTo)
	accept.Activated:Connect(function()
		answer(fromId, true)
	end)
	reject.Activated:Connect(function()
		answer(fromId, false)
	end)
	local c = { frame = frame, title = title, accept = accept, order = cardOrder }
	cards[fromId] = c
	return c
end

function AlertsPanel.setRequests(incoming)
	if not root then
		return
	end
	local seen = {}
	local fresh: GuiObject? = nil
	local maxCards = if compact then REQUESTS_MAX_COMPACT else REQUESTS_MAX
	local shown = 0
	for _, r in incoming or {} do
		local fromId = r[1]
		if shown >= maxCards then
			break
		end
		if r[2] and r[2] <= nowServer() then
			continue
		end
		shown += 1
		seen[fromId] = true
		local c = cards[fromId]
		if not c then
			c = newCard(fromId)
			fresh = c.accept
		end
		c.expiresAt, c.renew = r[2], r[3] == true
		c.title.Text = cardTitle(fromId, c.renew)
	end
	for fromId in cards do
		if not seen[fromId] then
			removeCard(fromId)
		end
	end
	requestsBox.Visible = next(cards) ~= nil
	-- Gamepad players get the cursor on a fresh request if they aren't using any other UI.
	if fresh and ctx.usingGamepad() and GuiService.SelectedObject == nil then
		selectObj(fresh)
	end
end

-- Layout
function AlertsPanel.setCompact(on: boolean)
	if compact == on then
		return
	end
	compact = on
	-- Rebuild rows and cards at the new sizes.
	for _, e in events do
		if e.row then
			leaveSelection(e.row)
			e.row:Destroy()
			e.row = nil
		end
	end
	layoutEvents()
	local pending = {}
	for fromId, c in cards do
		pending[#pending + 1] = { fromId, c.expiresAt, c.renew, c.order }
	end
	table.sort(pending, function(a, b)
		return a[4] < b[4]
	end)
	for _, p in pending do
		removeCard(p[1])
	end
	AlertsPanel.setRequests(pending)
end

function AlertsPanel.create(c): Frame
	ctx = c
	root = make("Frame", {
		Name = "Alerts",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -12),
		Size = UDim2.fromOffset(340, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 6,
		Parent = c.gui,
	}) :: Frame
	local l = list(root, 6)
	l.VerticalAlignment = Enum.VerticalAlignment.Bottom

	-- bg-gray-800/92 + opacity-90 for the minor box; solid with a red accent for the important one.
	minorBox, minorRows = box("Events", 0.17, nil, 1)
	importantBox, importantRows = box("Important", 0.02, RED500, 2)
	requestsBox = make("Frame", {
		Name = "Requests",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		LayoutOrder = 3,
		Parent = root,
	}) :: Frame
	list(requestsBox, 8)

	-- Expire events and requests.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		local t = os.clock()
		for _, e in events do
			if t - e.at >= EVENT_SECONDS then
				layoutEvents()
				break
			end
		end
		local st = nowServer()
		for fromId, card in cards do
			if card.expiresAt and card.expiresAt <= st then
				removeCard(fromId)
			end
		end
	end)

	-- Gamepad: D-pad up jumps into the panel; B rejects a request / leaves the panel.
	UserInputService.InputBegan:Connect(function(input)
		local k = input.KeyCode
		if k == Enum.KeyCode.DPadUp then
			if GuiService.SelectedObject == nil and root.Visible then
				local best, bestOrder = nil, math.huge
				for _, card in cards do
					if card.order < bestOrder then
						best, bestOrder = card.accept, card.order
					end
				end
				if not best then
					-- No request: the newest focusable event row.
					for i = #events, 1, -1 do
						local row = events[i].row
						if row and row:IsA("TextButton") then
							best = row
							break
						end
					end
				end
				selectObj(best)
			end
		elseif k == Enum.KeyCode.ButtonB then
			local sel = selectionInside()
			if sel then
				local fromId = sel:GetAttribute("AlertRequestFrom")
				if typeof(fromId) == "number" and cards[fromId] then
					answer(fromId, false)
				else
					GuiService.SelectedObject = nil
				end
			end
		end
	end)
	return root
end

function AlertsPanel.bind(c)
	hooks = c
end

return AlertsPanel
