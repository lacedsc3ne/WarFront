--[[
	War Front - keyboard shortcuts (OpenFront's default keybinds).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Keybinds (ModuleScript), used by GameClient (via Interact).
-- Keys come from KeybindData (OpenFront getDefaultKeybinds, rebindable in Settings > Keybinds):
--   1-9, 0 build City / Factory / Port / Defense Post / Silo / SAM / Warship / Atom / Hydrogen / MIRV
--   T / Y  attack ratio -/+ (Settings "attackRatioIncrement", default 10%)    B boat attack
--   G ground attack    Shift+R retaliate    U swap rocket direction    K request / renew alliance
--   L break alliance    C centre camera    W A S D pan (held; arrows too)    Q / E zoom (held; - / = too)
--   Space (hold) alternate view    M coordinate grid    Alt + R reset graphics    F select all warships
--   P pause, . / , game speed up / down (solo rounds)    Shift + wheel attack ratio    Esc cancel
--
-- Keybinds.setup(ctx)
--   ctx.net, ctx.actionList, ctx.setMode({type, kind}), ctx.getRatio(), ctx.setRatio(r),
--   ctx.zoomAt(factor, sx, sy), ctx.pan(dx, dy), ctx.fitMap(), ctx.centerCamera(), ctx.cancel(),
--   ctx.tileAtMouse() -> tile?, ctx.ownerOf(tile), ctx.getMyId(), ctx.getMe(), ctx.getPhase(),
--   ctx.roster, ctx.contextMenu, ctx.overlaysChanged(), ctx.viewCenter() -> Vector2,
--   ctx.selectAllWarships(), ctx.toast(text)?
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

local KeybindData = require(script.Parent:WaitForChild("KeybindData"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local HudSidebars = require(script.Parent:WaitForChild("HudSidebars"))

local K = Enum.KeyCode
local BUILD_ACTIONS = {
	buildCity = "City",
	buildFactory = "Factory",
	buildPort = "Port",
	buildDefensePost = "DefensePost",
	buildMissileSilo = "MissileSilo",
	buildSamLauncher = "SAM",
	buildWarship = "Warship",
	buildAtomBomb = "AtomBomb",
	buildHydrogenBomb = "HydrogenBomb",
	buildMIRV = "MIRV",
}
local ACTION_OF = {}
for action, kind in BUILD_ACTIONS do
	ACTION_OF[kind] = action
end
-- UnitDisplay.ts order: City, Factory, Port, Defense Post, Missile Silo, SAM, Warship, Atom, Hydrogen, MIRV.
local ORDER = { City = 1, Factory = 2, MIRV = 10, Port = 3, DefensePost = 4, MissileSilo = 5, SAM = 6, Warship = 7, AtomBomb = 8, HydrogenBomb = 9 }

local PAN_SPEED = 900 -- px / s for held W A S D / arrows
local ZOOM_RATE = 2.2 -- zoom factor per second for held Q / E / - / =

local ctx: any = nil
local MapRender = require(script.Parent:WaitForChild("MapRender"))
local MapFx = require(script.Parent:WaitForChild("MapFx"))
local viewHeld: Enum.KeyCode? = nil
local altBefore = false
local gridOn = false

-- uiState.rocketDirectionUp lives in KeybindData.rocketUp (BuildMenu.fireNuke sends it).
KeybindData.rocketUp = true

UserInputService.InputEnded:Connect(function(input)
	if viewHeld and input.KeyCode == viewHeld then
		viewHeld = nil
		MapRender.setAltView(altBefore)
	end
end)

function Keybinds.hotkey(kind: string): string
	local action = ACTION_OF[kind]
	return if action then KeybindData.label(action) else ""
end

function Keybinds.order(kind: string): number?
	return ORDER[kind]
end

local function ratioStep(): number
	return (tonumber(Settings.values.attackRatioIncrement) or 10) / 100
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

local function is(action: string, input: InputObject): boolean
	return KeybindData.matches(action, input)
end

-- Returns true when the key was one of ours.
function Keybinds.keyDown(input: InputObject): boolean
	if not ctx or KeybindData.capturing then
		return false -- the settings Keybinds tab is waiting for a new key
	end
	if input.KeyCode == K.Escape then
		ctx.cancel()
		return true
	end
	-- Alt + R (graphics refresh modifier + resetGfx): rebuild the whole map image.
	if is("resetGfx", input) and KeybindData.held("altKey") then
		MapRender.buildBase()
		MapRender.invalidate()
		MapRender.markAll()
		ctx.overlaysChanged()
		return true
	end
	for action, kind in BUILD_ACTIONS do
		if is(action, input) then
			buildByKind(kind)
			return true
		end
	end
	if is("attackRatioDown", input) then
		nudgeRatio(-ratioStep())
		return true
	elseif is("attackRatioUp", input) then
		nudgeRatio(ratioStep())
		return true
	elseif is("toggleView", input) then
		-- InputHandler: hold for the alternate view (territory by relation to us).
		if not viewHeld then
			viewHeld = input.KeyCode
			altBefore = MapRender.altView()
			MapRender.setAltView(not altBefore)
		end
		return true
	elseif is("coordinateGrid", input) then
		gridOn = not gridOn
		pcall(MapFx.setGrid, gridOn)
		return true
	elseif is("centerCamera", input) then
		ctx.centerCamera()
		return true
	elseif is("pauseGame", input) then
		HudSidebars.togglePause()
		return true
	elseif is("gameSpeedUp", input) then
		HudSidebars.stepSpeed(1)
		return true
	elseif is("gameSpeedDown", input) then
		HudSidebars.stepSpeed(-1)
		return true
	elseif is("swapDirection", input) then
		KeybindData.rocketUp = not KeybindData.rocketUp
		if ctx.toast then
			ctx.toast(if KeybindData.rocketUp then "Rocket direction: up" else "Rocket direction: down")
		end
		return true
	end
	if not inPlay() then
		return false
	end
	local net = ctx.net
	if is("selectAllWarships", input) then
		if ctx.selectAllWarships then
			ctx.selectAllWarships()
		end
		return true
	elseif is("boatAttack", input) then
		-- Boat attack under the cursor (the server picks the landing and checks boats left).
		local tile = ctx.tileAtMouse()
		if tile and ctx.ownerOf(tile) ~= ctx.getMyId() then
			net:FireServer("boat", tile, ctx.getRatio())
		end
		return true
	elseif is("groundAttack", input) then
		local tile = ctx.tileAtMouse()
		if tile and ctx.ownerOf(tile) ~= ctx.getMyId() and not ctx.contextMenu.isAlly(ctx.ownerOf(tile)) then
			net:FireServer("attack", tile, ctx.getRatio())
		end
		return true
	elseif is("retaliateAttack", input) then
		-- Retaliate against the most recent incoming (non-bot) attack.
		local incoming = ctx.getMe().incoming or {}
		local last = incoming[#incoming]
		if last then
			net:FireServer("retaliate", last[1], ctx.getRatio())
		end
		return true
	elseif is("requestAlliance", input) then
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
	elseif is("breakAlliance", input) then
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
	nudgeRatio(if input.Position.Z > 0 then ratioStep() else -ratioStep())
	return true
end

function Keybinds.setup(c)
	ctx = c
	-- Held keys: pan and zoom every frame (InputHandler's moveInterval).
	RunService.RenderStepped:Connect(function(dt)
		if UserInputService:GetFocusedTextBox() then
			return
		end
		local function down(action: string, ...): boolean
			if KeybindData.held(action) then
				return true
			end
			for _, key in { ... } do
				if UserInputService:IsKeyDown(key) then
					return true
				end
			end
			return false
		end
		local dx, dy = 0, 0
		if down("moveUp", K.Up) then
			dy += 1
		end
		if down("moveDown", K.Down) then
			dy -= 1
		end
		if down("moveLeft", K.Left) then
			dx += 1
		end
		if down("moveRight", K.Right) then
			dx -= 1
		end
		local moved = false -- zoom changed (overlays re-layout); panning needs no refresh
		if dx ~= 0 or dy ~= 0 then
			ctx.pan(dx * PAN_SPEED * dt, dy * PAN_SPEED * dt)
		end
		local z = 0
		if down("zoomOut", K.Minus, K.KeypadMinus) then
			z -= 1
		end
		if down("zoomIn", K.Equals, K.KeypadPlus) then
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
