--[[
	War Front - alert frame (red / orange screen border when betrayed or attacked).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.AlertFrame (ModuleScript), used by GameClient.
-- OpenFront AlertFrame.ts: a 17 px border that blinks twice (1.6 s each, ease-in-out).
--   betrayal (#ee0000): an ally broke the alliance with us (server message "betrayed").
--   land attack (#ffa500): a new incoming land attack (bots never come through), unless we are in
--   the 15 s cooldown, it is a retaliation (we attacked them in the last 15 s) or it is smaller
--   than a fifth of our troops.
-- Settings.values.alertFrame turns it off.
-- AlertFrame.mount(gui)                 create the frame
-- AlertFrame.betrayed()                 betrayal alert
-- AlertFrame.update(me, troops, alive)  per "me" snapshot (attacks / incoming lists)
-- AlertFrame.reset()                    new round / death

local TweenService = game:GetService("TweenService")

local Settings = require(script.Parent:WaitForChild("Settings"))

local AlertFrame = {}

local ALERT_SPEED = 1.6
local ALERT_COUNT = 2
local RETALIATION_WINDOW = 15
local COOLDOWN = 15
local BETRAYAL = Color3.fromRGB(238, 0, 0)
local LAND_ATTACK = Color3.fromRGB(255, 165, 0)

local frame: Frame? = nil
local stroke: UIStroke? = nil
local tween: Tween? = nil
local lastAlert = -math.huge
local seen: { [number]: boolean } = {}
local outgoing: { [number]: number } = {} -- player id -> time we last attacked them

function AlertFrame.mount(gui: Instance)
	local f = Instance.new("Frame")
	f.Name = "AlertFrame"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundTransparency = 1
	f.Active = false
	f.ZIndex = 40
	f.Visible = false
	local s = Instance.new("UIStroke")
	s.Thickness = 17
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Transparency = 1
	s.Parent = f
	f.Parent = gui
	frame, stroke = f, s
end

local function activate(color: Color3)
	if not Settings.values.alertFrame or not frame or not stroke then
		return
	end
	lastAlert = os.clock()
	if tween then
		tween:Cancel()
	end
	-- UIStroke draws outside the frame: inset it so the 17 px band sits on the screen edge.
	frame.Position = UDim2.fromOffset(17, 17)
	frame.Size = UDim2.new(1, -34, 1, -34)
	stroke.Color = color
	stroke.Transparency = 1
	frame.Visible = true
	local info = TweenInfo.new(ALERT_SPEED / 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, ALERT_COUNT - 1, true) -- one cycle = fade in + out
	local t = TweenService:Create(stroke, info, { Transparency = 0 })
	tween = t
	t.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and tween == t then
			if stroke then
				stroke.Transparency = 1
			end
			if frame then
				frame.Visible = false
			end
		end
	end)
	t:Play()
end

function AlertFrame.betrayed()
	activate(BETRAYAL)
end

function AlertFrame.reset()
	table.clear(seen)
	table.clear(outgoing)
	lastAlert = -math.huge
end

function AlertFrame.update(me: any, troops: number, alive: boolean)
	if type(me) ~= "table" then
		return
	end
	if not alive then
		AlertFrame.reset()
		return
	end
	local now = os.clock()
	for _, a in me.attacks or {} do
		local target, retreating = a[1], a[3]
		if target ~= 0 and not retreating then
			local at = outgoing[target]
			if at == nil or now - at >= RETALIATION_WINDOW then
				outgoing[target] = now
			end
		end
	end
	for id, at in outgoing do
		if now - at > RETALIATION_WINDOW then
			outgoing[id] = nil
		end
	end
	local inCooldown = now - lastAlert < COOLDOWN
	local active = {}
	for _, a in me.incoming or {} do
		local attacker, size, retreating, uid = a[1], a[2], a[3], a[4] or 0
		active[uid] = true
		if not retreating and not seen[uid] then
			seen[uid] = true
			local at = outgoing[attacker]
			local retaliation = at ~= nil and now - at < RETALIATION_WINDOW
			if not inCooldown and not retaliation and size >= troops / 5 then
				activate(LAND_ATTACK)
				inCooldown = true
			end
		end
	end
	for uid in seen do
		if not active[uid] then
			seen[uid] = nil
		end
	end
end

return AlertFrame
