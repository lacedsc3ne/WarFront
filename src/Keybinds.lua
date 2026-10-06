--[[
	War Front - keyboard shortcuts (OpenFront's default keybinds).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Keybinds (ModuleScript), used by GameClient (via Interact).
-- Defaults from OpenFront src/core/game/UserSettings.ts getDefaultKeybinds / InputHandler.ts:
--   1 City  3 Port  4 Defense Post  5 Missile Silo  6 SAM  7 Warship  8 Atom Bomb  9 Hydrogen Bomb
--   2 Factory  0 MIRV (only once the rules lanes add them to Config / actionList)        T / Y  attack ratio -10% / +10%
--   B  boat attack at the cursor    G  ground attack at the cursor    Shift+R  retaliate (latest
--   incoming attack)    K  request / renew alliance at the cursor    L  break alliance at the cursor
--   C  centre the camera on us    W A S D / arrows  pan (held)    Q / E, - / =  zoom out / in (held)
--   Shift + mouse wheel  attack ratio    Esc  cancel / close    Space (hold)  alternate view
--   M  coordinate grid
-- Keybinds.setup(ctx)
--   ctx.net, ctx.actionList, ctx.setMode({type, kind}), ctx.getRatio(), ctx.setRatio(r),
--   ctx.zoomAt(factor, sx, sy), ctx.pan(dx, dy), ctx.fitMap(), ctx.centerCamera(), ctx.cancel(),
--   ctx.tileAtMouse() -> tile?, ctx.ownerOf(tile), ctx.getMyId(), ctx.getMe(), ctx.getPhase(),
--   ctx.roster, ctx.contextMenu, ctx.overlaysChanged(), ctx.viewCenter() -> Vector2
-- Keybinds.keyDown(input) -> boolean   call from GameClient's keyboard InputBegan (unprocessed)
-- Keybinds.wheel(input) -> boolean     true when Shift + wheel changed the attack ratio
-- Keybinds.hotkey(kind) -> string      label for the build bar ("" if unbound)
-- Keybinds.order(kind) -> number?      OpenFront's unit-display order for the build bar

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)

local Keybinds = {}

local K = Enum.KeyCode
local BUILD_KEYS = {
	[K.One] = "City",
	[K.Two] = "Factory",
	[K.Zero] = "MIRV",
	[K.KeypadTwo] = "Factory",
	[K.KeypadZero] = "MIRV",
	[K.Three] = "Port",
	[K.Four] = "DefensePost",
	[K.Five] = "MissileSilo",
	[K.Six] = "SAM",
	[K.Seven] = "Warship",
	[K.Eight] = "AtomBomb",
	[K.Nine] = "HydrogenBomb",
	[K.KeypadOne] = "City",
	[K.KeypadThree] = "Port",
	[K.KeypadFour] = "DefensePost",
	[K.KeypadFive] = "MissileSilo",
	[K.KeypadSix] = "SAM",
	[K.KeypadSeven] = "Warship",
	[K.KeypadEight] = "AtomBomb",
	[K.KeypadNine] = "HydrogenBomb",
}
local HOTKEY = { City = "1", Factory = "2", MIRV = "0", Port = "3", DefensePost = "4", MissileSilo = "5", SAM = "6", Warship = "7", AtomBomb = "8", HydrogenBomb = "9" }
-- UnitDisplay.ts order: City, Factory, Port, Defense Post, Missile Silo, SAM, Warship, Atom, Hydrogen, MIRV.
local ORDER = { City = 1, Factory = 2, MIRV = 10, Port = 3, DefensePost = 4, MissileSilo = 5, SAM = 6, Warship = 7, AtomBomb = 8, HydrogenBomb = 9 }

local RATIO_STEP = 0.10 -- OpenFront attackRatioIncrement default (10%)
local PAN_SPEED = 900 -- px / s for held W A S D / arrows
local ZOOM_RATE = 2.2 -- zoom factor per second for held Q / E / - / =

local ctx: any = nil
local MapRender = require(script.Parent:WaitForChild("MapRender"))
local MapFx = require(script.Parent:WaitForChild("MapFx"))
local spaceHeld = false
local altBefore = false
local gridOn = false

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Space and spaceHeld then
		spaceHeld = false
		MapRender.setAltView(altBefore)
	end
end)

function Keybinds.hotkey(kind: string): string
	return HOTKEY[kind] or ""
end

function Keybinds.order(kind: string): number?
	return ORDER[kind]
end

-- AttackRatioEvent handling in ControlPanel.ts: clamp to 1..100 %, and 1% + 10% snaps to 10%.
local function nudgeRatio(delta: number)
	local old = ctx.getRatio()
	local new = math.clamp(old + delta, 0.01, 1)
	if math.abs(old - 0.01) < 1e-6 and math.abs(new - 0.11) < 1e-6 then
		new = 0.1
	end
	ctx.setRatio(new)
end

local function shiftDown(): boolean
	return UserInputService:IsKeyDown(K.LeftShift) or UserInputService:IsKeyDown(K.RightShift)
end

local function inPlay(): boolean
	local mine = ctx.roster[ctx.getMyId()]
	return ctx.getPhase() == "Play" and mine ~= nil and mine.stats.alive
end

local function buildByKind(kind: string)
	for _, a in ctx.actionList do
		if a.kind == kind then
			ctx.setMode({ type = a.type, kind = a.kind })
			return
		end
	end
end

local function playerAtCursor(): (number?, number?)
	local tile = ctx.tileAtMouse()
	if not tile then
		return nil, nil
	end
	local o = ctx.ownerOf(tile)
	if o == 0 or o == ctx.getMyId() or not ctx.roster[o] then
		return nil, tile
	end
	return o, tile
end

-- Returns true when the key was one of ours.
function Keybinds.keyDown(input: InputObject): boolean
	if not ctx then
		return false
	end
	local k = input.KeyCode
	local kind = BUILD_KEYS[k]
	if kind then
		buildByKind(kind)
		return true
	end
	if k == K.Escape then
		ctx.cancel()
		return true
	elseif k == K.T then
		nudgeRatio(-RATIO_STEP)
		return true
	elseif k == K.Y then
		nudgeRatio(RATIO_STEP)
		return true
	elseif k == K.Space then
		-- InputHandler: hold Space for the alternate view (territory by relation to us).
		if not spaceHeld then
			spaceHeld = true
			altBefore = MapRender.altView()
			MapRender.setAltView(not altBefore)
		end
		return true
	elseif k == K.M then
		gridOn = not gridOn
		pcall(MapFx.setGrid, gridOn)
		return true
	elseif k == K.C then
		ctx.centerCamera()
		return true
	end
	if not inPlay() then
		return false
	end
	local net = ctx.net
	if k == K.B then
		-- Boat attack under the cursor (the server picks the landing and checks boats left).
		local tile = ctx.tileAtMouse()
		if tile and ctx.ownerOf(tile) ~= ctx.getMyId() then
			net:FireServer("boat", tile, ctx.getRatio())
		end
		return true
	elseif k == K.G then
		local tile = ctx.tileAtMouse()
		if tile and ctx.ownerOf(tile) ~= ctx.getMyId() and not ctx.contextMenu.isAlly(ctx.ownerOf(tile)) then
			net:FireServer("attack", tile, ctx.getRatio())
		end
		return true
	elseif k == K.R and shiftDown() then
		-- Retaliate against the most recent incoming (non-bot) attack.
		local incoming = ctx.getMe().incoming or {}
		local last = incoming[#incoming]
		if last then
			net:FireServer("retaliate", last[1], ctx.getRatio())
		end
		return true
	elseif k == K.K then
		local id = playerAtCursor()
		local CM = ctx.contextMenu
		if id and ctx.roster[id].kind ~= "Bot" then
			if CM.hasIncoming(id) then
				net:FireServer("allyAccept", id)
			elseif not CM.hasOutgoing(id) then
				local exp = CM.allyExpiry(id)
				local renewable = exp ~= nil and exp - SimClock.now() <= Config.ALLIANCE_RENEW_TICKS * Config.TICK
				if exp == nil or renewable then
					net:FireServer("allyRequest", id)
				end
			end
		end
		return true
	elseif k == K.L then
		local id = playerAtCursor()
		if id and ctx.contextMenu.isAlly(id) then
			net:FireServer("allyBreak", id)
		end
		return true
	end
	return false
end

function Keybinds.wheel(input: InputObject): boolean
	if not ctx or not shiftDown() then
		return false
	end
	nudgeRatio(if input.Position.Z > 0 then RATIO_STEP else -RATIO_STEP)
	return true
end

function Keybinds.setup(c)
	ctx = c
	-- Held keys: pan and zoom every frame (InputHandler's moveInterval).
	RunService.RenderStepped:Connect(function(dt)
		if UserInputService:GetFocusedTextBox() then
			return
		end
		local function down(...): boolean
			for _, key in { ... } do
				if UserInputService:IsKeyDown(key) then
					return true
				end
			end
			return false
		end
		local dx, dy = 0, 0
		if down(K.W, K.Up) then
			dy += 1
		end
		if down(K.S, K.Down) then
			dy -= 1
		end
		if down(K.A, K.Left) then
			dx += 1
		end
		if down(K.D, K.Right) then
			dx -= 1
		end
		local moved = false -- zoom changed (overlays re-layout); panning needs no refresh
		if dx ~= 0 or dy ~= 0 then
			ctx.pan(dx * PAN_SPEED * dt, dy * PAN_SPEED * dt)
		end
		local z = 0
		if down(K.Q, K.Minus, K.KeypadMinus) then
			z -= 1
		end
		if down(K.E, K.Equals, K.KeypadPlus) then
			z += 1
		end
		if z ~= 0 then
			local center = ctx.viewCenter()
			ctx.zoomAt(ZOOM_RATE ^ (z * dt), center.X, center.Y)
			moved = true
		end
		if moved then
			ctx.overlaysChanged()
		end
	end)
end

return Keybinds
