--[[
	War Front - attacking-troops labels on the front lines.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(src/client/controllers/AttackingTroopsController.ts, render/gl/passes/WorldTextPass.ts,
	core/game/AttackImpl.ts clusteredPositions). Modified version re-implemented in Luau for
	Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.AttackLabels (ModuleScript), used by GameClient.
--
-- Our outgoing attacks on players (#3fa9f5) and incoming attacks from players / nations (#f87171)
-- show their troop count (renderTroops) on up to two front segments. The server sends the label
-- tiles with every personal update ("me": attacks[i][4] = id, [5] = tiles); labels glide to new
-- positions and snap on big jumps. Constant on-screen size (17 px, 1.2 px black outline), hidden
-- in the alternate view and when the "Attacking Troops Overlay" setting is off.
--
-- AttackLabels.init({ layer = Frame (map-sized), mapSize() -> W, H, fmtTroops(n) -> string })
-- AttackLabels.update(me)      on every "me" message
-- AttackLabels.step(hidden)    every frame (hidden = alt view / not playing)
-- AttackLabels.clear()

local AttackLabels = {}

local OUTGOING = Color3.fromHex("#3fa9f5")
local INCOMING = Color3.fromHex("#f87171")
-- OpenFront animates 250 ms between 200 ms polls; our server updates every 500 ms, so the glide
-- spans the whole interval to stay continuous.
local ANIM = 0.5
local SNAP_DISTANCE = 200 / 4 -- full-size tiles -> ours (LINEAR_SCALE 4)
local TEXT_SIZE = 17 -- ATTACK_LABEL_SCREEN_SCALE
local OUTLINE = 1.2 -- ATTACK_LABEL_OUTLINE_WIDTH
local FONT = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold) -- as NameLabels

local ctx: any = nil
local entries: { [string]: any } = {}
local pool: { TextLabel } = {}
local Settings: any = nil

local function newLabel(): TextLabel
	local l = table.remove(pool)
	if l then
		return l
	end
	l = Instance.new("TextLabel")
	l.Name = "AttackTroops"
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromOffset(80, TEXT_SIZE + 4)
	l.FontFace = FONT
	l.TextSize = TEXT_SIZE
	l.ZIndex = 6
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = OUTLINE
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = l
	return l
end

local function release(l: TextLabel)
	l.Parent = nil
	pool[#pool + 1] = l
end

local function dropEntry(key: string)
	local e = entries[key]
	if e then
		for _, slot in e.slots do
			release(slot.label)
		end
		entries[key] = nil
	end
end

function AttackLabels.clear()
	for key in entries do
		dropEntry(key)
	end
end

-- alignClusterOrder: keep two labels from swapping places between updates.
local function align(next: { { number } }, slots)
	if #next ~= 2 or #slots ~= 2 then
		return
	end
	local function d(s, c)
		return math.abs(c[1] - s.dx) + math.abs(c[2] - s.dy)
	end
	if d(slots[1], next[2]) + d(slots[2], next[1]) < d(slots[1], next[1]) + d(slots[2], next[2]) then
		next[1], next[2] = next[2], next[1]
	end
end

local function reconcile(e, tiles, W: number, now: number)
	local next = {}
	for i, t in tiles do
		next[i] = { t % W, t // W }
	end
	align(next, e.slots)
	while #e.slots > #next do
		release(table.remove(e.slots).label)
	end
	for i, c in next do
		local slot = e.slots[i]
		if not slot then
			slot = { label = newLabel(), sx = c[1], sy = c[2], dx = c[1], dy = c[2], start = now }
			slot.label.Parent = ctx.layer
			e.slots[i] = slot
		else
			local f = math.min(1, (now - slot.start) / ANIM)
			local cx, cy = slot.sx + (slot.dx - slot.sx) * f, slot.sy + (slot.dy - slot.sy) * f
			if math.sqrt((c[1] - cx) ^ 2 + (c[2] - cy) ^ 2) > SNAP_DISTANCE then
				cx, cy = c[1], c[2]
			end
			slot.sx, slot.sy, slot.dx, slot.dy, slot.start = cx, cy, c[1], c[2], now
		end
	end
end

function AttackLabels.update(me)
	if not ctx then
		return
	end
	if Settings and Settings.values.attackingTroopsOverlay == false then
		AttackLabels.clear()
		return
	end
	local W = ctx.mapSize()
	local now = os.clock()
	local seen = {}
	local function take(list, incoming: boolean)
		if type(list) ~= "table" then
			return
		end
		for _, a in list do
			local tiles = a[5]
			if type(tiles) == "table" and #tiles > 0 and (a[4] or 0) ~= 0 then
				local key = (if incoming then "i" else "o") .. tostring(a[4])
				seen[key] = true
				local e = entries[key]
				if not e then
					e = { slots = {} }
					entries[key] = e
				end
				e.text = ctx.fmtTroops(a[2] or 0)
				e.color = if incoming then INCOMING else OUTGOING
				reconcile(e, tiles, W, now)
			end
		end
	end
	take(me.attacks, false)
	take(me.incoming, true)
	for key in entries do
		if not seen[key] then
			dropEntry(key)
		end
	end
end

function AttackLabels.step(hidden: boolean)
	if not ctx then
		return
	end
	local W, H = ctx.mapSize()
	local now = os.clock()
	for _, e in entries do
		for _, slot in e.slots do
			local l = slot.label
			l.Visible = not hidden
			if hidden then
				continue
			end
			local f = math.min(1, (now - slot.start) / ANIM)
			local x = slot.sx + (slot.dx - slot.sx) * f
			local y = slot.sy + (slot.dy - slot.sy) * f
			l.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
			if l.Text ~= e.text then
				l.Text = e.text
			end
			if l.TextColor3 ~= e.color then
				l.TextColor3 = e.color
			end
		end
	end
end

function AttackLabels.init(c)
	ctx = c
	local ok, s = pcall(require, script.Parent:WaitForChild("Settings"))
	if ok then
		Settings = s
	end
end

return AttackLabels
