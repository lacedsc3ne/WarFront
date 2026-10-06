--[[
	War Front - context menu, alliance request popup and client diplomacy state.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.ContextMenu (ModuleScript), used by GameClient.
-- State functions (isAlly, isTraitor, tags) work before setup(); the UI needs setup(ctx).

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local MapUtil = require(Shared:WaitForChild("MapUtil"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))

local ContextMenu = {}
ContextMenu.alliances = {} :: { any }
ContextMenu.betrayals = {} :: { [number]: number } -- player id -> alliances broken this round (seen by us)

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local PANEL = Color3.fromRGB(24, 28, 36)
local ACCENT = Color3.fromRGB(70, 110, 200)
local DISABLED = Color3.fromRGB(70, 74, 86)
local RED = Color3.fromRGB(190, 60, 60)
local GREEN = Color3.fromRGB(50, 150, 90)
local ALLY_COLOR = Color3.fromRGB(110, 240, 160)
local TRAITOR_COLOR = Color3.fromRGB(255, 110, 90)

local MENU_W = 236
local BUTTON_H = 36
local HEADER_H = 46
local PAD = 8

-- Diplomacy state (from the server's "diplomacy" and "allyRequests" messages)
local myAllies: { [number]: number } = {} -- ally id -> expiry (server time)
local traitorUntil: { [number]: number } = {} -- player id -> server time
local incoming: { any } = {} -- { fromId, expiresAt, renew }
local outgoing: { any } = {} -- { toId, expiresAt, renew }

local ctx: any = nil

local function now(): number
	return SimClock.now()
end

-- Team games (PlayerImpl.isOnSameTeam): same team, never the tribes' "Bot" team.
function ContextMenu.isTeammate(id: number): boolean
	if not ctx or not ctx.roster or not ctx.getMyId then
		return false
	end
	local me = ctx.getMyId()
	local a, b = ctx.roster[me], ctx.roster[id]
	return id ~= me and a ~= nil and b ~= nil and (a.team or "") ~= "" and a.team == b.team and a.team ~= "Bot"
end

-- Is this a team game (we were given a team)?
function ContextMenu.teamGame(): boolean
	if not ctx or not ctx.roster or not ctx.getMyId then
		return false
	end
	local mine = ctx.roster[ctx.getMyId()]
	return mine ~= nil and (mine.team or "") ~= ""
end

-- PlayerImpl.isFriendly: allied or a teammate.
function ContextMenu.isAlly(id: number): boolean
	return myAllies[id] ~= nil or ContextMenu.isTeammate(id)
end

function ContextMenu.isTraitor(id: number): boolean
	local u = traitorUntil[id]
	return u ~= nil and u > now()
end

-- Prefix for a map name label.
function ContextMenu.tagText(id: number): string
	if myAllies[id] then
		return "[Ally] "
	elseif ContextMenu.isTraitor(id) then
		return "[Traitor] "
	end
	return ""
end

function ContextMenu.tagColor(id: number): Color3
	if myAllies[id] then
		return ALLY_COLOR
	elseif ContextMenu.isTraitor(id) then
		return TRAITOR_COLOR
	end
	return Color3.new(1, 1, 1)
end

-- Rich-text suffix for a leaderboard row.
function ContextMenu.boardTag(id: number): string
	local s = ""
	if myAllies[id] then
		s ..= " <font color=\"#6ef0a0\">[Ally]</font>"
	end
	if ContextMenu.isTraitor(id) then
		s ..= " <font color=\"#ff6e5a\">[Traitor]</font>"
	end
	return s
end

local function findReq(list, id: number)
	for _, r in list do
		if r[1] == id and r[2] > now() then
			return r
		end
	end
	return nil
end

-- For the radial menu / player panel: pending requests with `id` and our alliance's expiry.
function ContextMenu.hasIncoming(id: number): boolean
	return findReq(incoming, id) ~= nil
end

function ContextMenu.hasOutgoing(id: number): boolean
	return findReq(outgoing, id) ~= nil
end

function ContextMenu.allyExpiry(id: number): number?
	return myAllies[id]
end

function ContextMenu.traitorUntil(id: number): number?
	return traitorUntil[id]
end

-- Returns true when the local player's ally set changed (the map needs a repaint).
function ContextMenu.applyDiplomacy(data): boolean
	local myId = if ctx then ctx.getMyId() else 0
	local before = myAllies
	myAllies = {}
	ContextMenu.alliances = data.alliances or {} -- every alliance { a, b, expiresAt } (PlayerPanel)
	for _, e in data.alliances or {} do
		if e[1] == myId then
			myAllies[e[2]] = e[3]
		elseif e[2] == myId then
			myAllies[e[1]] = e[3]
		end
	end
	local wasTraitor = table.clone(traitorUntil)
	table.clear(traitorUntil)
	for _, e in data.traitors or {} do
		traitorUntil[e[1]] = e[2]
		local prev = wasTraitor[e[1]]
		if prev == nil or e[2] > prev + 2 then -- (expiry times jitter a little between messages)
			-- A new traitor mark = one more broken alliance (PlayerPanel's "Betrayals").
			ContextMenu.betrayals[e[1]] = (ContextMenu.betrayals[e[1]] or 0) + 1
		end
	end
	for id in before do
		if not myAllies[id] then
			return true
		end
	end
	for id in myAllies do
		if not before[id] then
			return true
		end
	end
	return false
end

-- UI helpers
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

local function corner(parent, r)
	make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function usingGamepad(): boolean
	return string.find(UserInputService:GetLastInputType().Name, "Gamepad") ~= nil
end

local function fmt(n: number): string
	return if ctx then ctx.fmt(n) else tostring(math.floor(n))
end

local function button(parent, text: string, color: Color3, order: number, onClick: (() -> ())?, icon: string?)
	local b = make("TextButton", {
		Size = UDim2.new(1, 0, 0, BUTTON_H),
		BackgroundColor3 = if onClick then color else DISABLED,
		BorderSizePixel = 0,
		AutoButtonColor = onClick ~= nil,
		Selectable = onClick ~= nil,
		FontFace = FONT_BOLD,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		Text = text,
		LayoutOrder = order,
		Parent = parent,
	})
	corner(b, 6)
	if icon then
		IconKit.image(icon, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(18, 18), ImageTransparency = if onClick then 0 else 0.4, Parent = b })
	end
	if onClick then
		b.Activated:Connect(onClick)
	end
	return b
end

-- Context menu
local blocker: TextButton
local menu: Frame
local menuHeader: TextLabel
local menuList: Frame
local popup: Frame
local menuOpen = false

local function clearSelectionIn(root: Instance)
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(root) then
		GuiService.SelectedObject = nil
	end
end

function ContextMenu.close()
	if not menuOpen then
		return
	end
	menuOpen = false
	clearSelectionIn(menu)
	menu.Visible = false
	blocker.Visible = false
	for _, c in menuList:GetChildren() do
		if c:IsA("GuiButton") then
			c:Destroy()
		end
	end
end

function ContextMenu.isOpen(): boolean
	return menuOpen
end

-- Is there coast of `ownerId` near `tile`? Mirrors the server's boat landing search.
local NB = table.create(4)
local function coastNear(tile: number, ownerId: number): boolean
	local map = ctx.map
	local W, H = map.width, map.height
	local cx, cy = tile % W, tile // W
	for dy = -20, 20 do
		for dx = -20, 20 do
			local x, y = cx + dx, cy + dy
			if x >= 0 and x < W and y >= 0 and y < H then
				local t = y * W + x
				if ctx.ownerOf(t) == ownerId and MapUtil.isOwnable(map, t) then
					local n = MapUtil.neighbors(map, t, NB)
					for i = 1, n do
						if not MapUtil.isLand(map, NB[i]) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local function fire(kind: string, a1: number, a2: any)
	ctx.net:FireServer(kind, a1, a2)
	ContextMenu.close()
end

local function timeLeft(t: number): string
	local s = math.max(0, math.floor(t - now()))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Opens the menu for `tile`, placed at screen point sx, sy.
function ContextMenu.open(sx: number, sy: number, tile: number)
	if not ctx then
		return
	end
	ContextMenu.close()
	local roster = ctx.roster
	local myId = ctx.getMyId()
	local mine = roster[myId]
	local alive = mine ~= nil and mine.stats.alive
	local ratio = ctx.getRatio()
	local ownerId = ctx.ownerOf(tile)
	local target = if ownerId ~= 0 then roster[ownerId] else nil
	local map = ctx.map

	-- Header
	local title, sub
	if ownerId == 0 then
		title = if MapUtil.isOwnable(map, tile) then "Wilderness" elseif MapUtil.isLand(map, tile) then "Mountains" else "Sea"
		sub = ""
	elseif not target then
		title, sub = "Unknown", ""
	else
		local s = target.stats
		title = "<b>" .. target.name .. "</b>"
		if ownerId == myId then
			title ..= "  (you)"
		elseif target.kind == "Bot" then
			title ..= "  (bot)"
		end
		local ally = myAllies[ownerId]
		if ally then
			title ..= string.format("  <font color=\"#6ef0a0\">Ally %s</font>", timeLeft(ally))
		end
		if ContextMenu.isTraitor(ownerId) then
			title ..= "  <font color=\"#ff6e5a\">Traitor</font>"
		end
		sub = string.format("Troops %s · Land %.1f%%", fmt(s.troops), s.tiles / map.landTiles * 100)
	end
	menuHeader.Text = title .. (if sub ~= "" then "\n" .. sub else "")

	-- Actions
	local order = 0
	local first: GuiButton? = nil
	local function add(text: string, color: Color3, onClick: (() -> ())?, icon: string?)
		order += 1
		local b = button(menuList, text, color, order, onClick, icon)
		if onClick and not first then
			first = b
		end
	end
	local myTroops = if mine then mine.stats.troops else 0
	local myGold = if mine then mine.stats.gold else 0
	local troopsText = fmt(myTroops * ratio)

	if alive and ownerId ~= myId and (target or (ownerId == 0 and MapUtil.isOwnable(map, tile))) then
		local allied = myAllies[ownerId] ~= nil
		if not allied then
			add((if ownerId == 0 then "Expand (" else "Attack (") .. troopsText .. ")", RED, function()
				fire("attack", tile, ratio)
			end, "Sword")
			if coastNear(tile, ownerId) then
				local me = ctx.getMe()
				local full = (me.boats or 0) >= Config.MAX_BOATS
				add("Send boat (" .. troopsText .. ")", ACCENT, if full then nil else function()
					fire("boat", tile, ratio)
				end, "Boat")
			end
		end
		if target and target.kind ~= "Bot" then
			local theirReq = findReq(incoming, ownerId)
			local myReq = findReq(outgoing, ownerId)
			if allied then
				add("Send troops (" .. troopsText .. ")", GREEN, function()
					fire("donateTroops", ownerId, ratio)
				end, "DonateTroops")
				add("Send gold (" .. fmt(myGold * ratio) .. ")", GREEN, function()
					fire("donateGold", ownerId, ratio)
				end, "DonateGold")
				if myAllies[ownerId] - now() <= Config.ALLIANCE_RENEW_TICKS * Config.TICK then
					if theirReq then
						add("Accept renewal", GREEN, function()
							fire("allyAccept", ownerId)
						end)
					elseif myReq then
						add("Renewal requested", DISABLED, nil)
					else
						add("Renew alliance", GREEN, function()
							fire("allyRequest", ownerId)
						end)
					end
				end
				add("Break alliance", RED, function()
					fire("allyBreak", ownerId)
				end, "Traitor")
			elseif theirReq then
				add("Accept alliance", GREEN, function()
					fire("allyAccept", ownerId)
				end, "Alliance")
			elseif myReq then
				add("Alliance requested", DISABLED, nil)
			else
				add("Request alliance", GREEN, function()
					fire("allyRequest", ownerId)
				end, "Alliance")
			end
		end
	end
	add("Close", DISABLED, function()
		ContextMenu.close()
	end, "Close")

	-- Place it next to the pointer, kept on screen.
	local h = PAD * 2 + HEADER_H + order * (BUTTON_H + 4)
	local screen = ctx.gui.AbsoluteSize
	local x = if sx + 8 + MENU_W > screen.X then sx - 8 - MENU_W else sx + 8
	local y = math.clamp(sy - 12, 4, math.max(4, screen.Y - h - 4))
	menu.Size = UDim2.fromOffset(MENU_W, h)
	menu.Position = UDim2.fromOffset(math.max(4, x), y)
	menu.Visible = true
	blocker.Visible = true
	menuOpen = true
	if usingGamepad() and first then
		local sel = first
		task.defer(function()
			if menuOpen and sel.Parent then
				GuiService.SelectedObject = sel
			end
		end)
	end
end

-- Incoming alliance requests popup
local popupRows: { [number]: any } = {} -- fromId -> { frame, text, expiresAt, renew }

local function removeRequest(fromId: number)
	for i, r in incoming do
		if r[1] == fromId then
			table.remove(incoming, i)
			break
		end
	end
	local row = popupRows[fromId]
	if row then
		clearSelectionIn(row.frame)
		row.frame:Destroy()
		popupRows[fromId] = nil
	end
	popup.Visible = next(popupRows) ~= nil
end

local function answer(fromId: number, accept: boolean)
	ctx.net:FireServer(if accept then "allyAccept" else "allyDecline", fromId)
	pcall(function() -- ActionableEvents: alliance-accepted / alliance-declined
		require(script.Parent:WaitForChild("SoundKit")).play(if accept then "alliance-accepted" else "alliance-declined")
	end)
	removeRequest(fromId)
end

-- Accept / decline from elsewhere (the alerts panel).
function ContextMenu.answerRequest(fromId: number, accept: boolean)
	if ctx then
		answer(fromId, accept)
	end
end

local function rowText(fromId: number, row): string
	local p = ctx.roster[fromId]
	local name = if p then p.name else "?"
	local what = if row.renew then " wants to renew your alliance" else " requests an alliance"
	return string.format("<b>%s</b>%s  (%ds)", name, what, math.max(0, math.ceil(row.expiresAt - now())))
end

local function rebuildPopup()
	if not ctx then
		return
	end
	-- When something else shows the requests (GameClient's alerts panel), hand them over instead.
	if ContextMenu.onRequests then
		popup.Visible = false
		ContextMenu.onRequests(incoming)
		return
	end
	local seen = {}
	local newest: GuiButton? = nil
	for i, r in incoming do
		local fromId = r[1]
		seen[fromId] = true
		local row = popupRows[fromId]
		if not row then
			local frame = make("Frame", {
				Size = UDim2.new(1, 0, 0, 74),
				BackgroundColor3 = PANEL,
				BackgroundTransparency = 0.1,
				BorderSizePixel = 0,
				LayoutOrder = i,
				Parent = popup,
			})
			corner(frame)
			local text = make("TextLabel", {
				Position = UDim2.fromOffset(10, 4),
				Size = UDim2.new(1, -20, 0, 28),
				BackgroundTransparency = 1,
				FontFace = FONT,
				TextSize = 14,
				RichText = true,
				TextWrapped = true,
				TextColor3 = Color3.new(1, 1, 1),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = frame,
			})
			local accept = make("TextButton", {
				Position = UDim2.new(0, 10, 1, -40),
				Size = UDim2.new(0.5, -15, 0, 34),
				BackgroundColor3 = GREEN,
				BorderSizePixel = 0,
				FontFace = FONT_BOLD,
				TextSize = 14,
				TextColor3 = Color3.new(1, 1, 1),
				Text = "Accept",
				Parent = frame,
			})
			local decline = make("TextButton", {
				Position = UDim2.new(0.5, 5, 1, -40),
				Size = UDim2.new(0.5, -15, 0, 34),
				BackgroundColor3 = RED,
				BorderSizePixel = 0,
				FontFace = FONT_BOLD,
				TextSize = 14,
				TextColor3 = Color3.new(1, 1, 1),
				Text = "Decline",
				Parent = frame,
			})
			corner(accept, 6)
			corner(decline, 6)
			accept:SetAttribute("RequestFrom", fromId)
			decline:SetAttribute("RequestFrom", fromId)
			accept.Activated:Connect(function()
				answer(fromId, true)
			end)
			decline.Activated:Connect(function()
				answer(fromId, false)
			end)
			row = { frame = frame, text = text }
			popupRows[fromId] = row
			newest = accept
		end
		row.expiresAt, row.renew = r[2], r[3]
		row.frame.LayoutOrder = i
		row.text.Text = rowText(fromId, row)
	end
	for fromId, row in popupRows do
		if not seen[fromId] then
			clearSelectionIn(row.frame)
			row.frame:Destroy()
			popupRows[fromId] = nil
		end
	end
	popup.Visible = next(popupRows) ~= nil
	-- Gamepad players get the cursor on a fresh request if they aren't using any other UI.
	if newest and usingGamepad() and not menuOpen and GuiService.SelectedObject == nil then
		GuiService.SelectedObject = newest
	end
end

function ContextMenu.applyRequests(data)
	incoming = data.incoming or {}
	outgoing = data.outgoing or {}
	rebuildPopup()
end

-- New round / rejoin: drop everything until the server sends fresh state.
function ContextMenu.reset()
	table.clear(myAllies)
	ContextMenu.alliances = {}
	table.clear(ContextMenu.betrayals)
	table.clear(traitorUntil)
	incoming, outgoing = {}, {}
	if ctx then
		ContextMenu.close()
		rebuildPopup()
	end
end

-- Setup
--[[
	ctx = {
		gui, net, map, roster,         -- ScreenGui, RemoteEvent, map, live roster table
		getMyId(), getRatio(), getMe(), getPhase(), ownerOf(tile), fmt(n)
	}
]]
-- The map can change between rounds; GameClient calls this after switching.
function ContextMenu.setMap(m)
	if ctx then
		ctx.map = m
	end
end

function ContextMenu.setup(c)
	ctx = c
	blocker = make("TextButton", {
		Name = "ContextMenuBlocker",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Visible = false,
		ZIndex = 30,
		Parent = c.gui,
	})
	blocker.Activated:Connect(ContextMenu.close)
	blocker.MouseButton2Click:Connect(ContextMenu.close)

	menu = make("Frame", {
		Name = "ContextMenu",
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 31,
		Parent = c.gui,
	})
	corner(menu)
	make("UIStroke", { Color = Color3.fromRGB(90, 100, 120), Thickness = 1, Parent = menu })
	menuHeader = make("TextLabel", {
		Position = UDim2.fromOffset(PAD + 2, PAD),
		Size = UDim2.new(1, -PAD * 2 - 4, 0, HEADER_H - 4),
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = 14,
		RichText = true,
		TextWrapped = true,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = menu,
	})
	menuList = make("Frame", {
		Position = UDim2.fromOffset(PAD, PAD + HEADER_H),
		Size = UDim2.new(1, -PAD * 2, 1, -PAD * 2 - HEADER_H),
		BackgroundTransparency = 1,
		Parent = menu,
	})
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = menuList })

	popup = make("Frame", {
		Name = "AllianceRequests",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.fromOffset(380, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 25,
		Parent = c.gui,
	})
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = popup })

	-- Esc / gamepad B close the menu; B on a request popup declines it.
	local lastSel: GuiObject? = nil
	local lastSelChange = 0
	GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
		local sel = GuiService.SelectedObject
		if sel then
			lastSel = sel
		end
		lastSelChange = os.clock()
	end)
	UserInputService.InputBegan:Connect(function(input)
		local k = input.KeyCode
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.ButtonB then
			if menuOpen then
				ContextMenu.close()
				return
			end
			if k == Enum.KeyCode.ButtonB then
				local sel = GuiService.SelectedObject or (if os.clock() - lastSelChange < 0.3 then lastSel else nil)
				local fromId = sel and sel.Parent and sel:GetAttribute("RequestFrom")
				if typeof(fromId) == "number" and popupRows[fromId] then
					answer(fromId, false)
				end
			end
		end
	end)

	-- Countdown text, expiry of requests, and closing the menu when the round ends.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		if menuOpen and c.getPhase() ~= "Play" then
			ContextMenu.close()
		end
		local t = now()
		for fromId, row in popupRows do
			if row.expiresAt <= t then
				removeRequest(fromId)
			else
				row.text.Text = rowText(fromId, row)
			end
		end
	end)
end

return ContextMenu
