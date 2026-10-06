--[[
	War Front - map effects (explosions, shockwaves, target rings, spawn rings, glows, grid).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Ported from OpenFront (AGPL-3.0): src/client/render/gl/passes/fx-pass/* (sprite FX, nuke debris,
	shockwaves, transport attack rings), passes/MoveIndicatorPass.ts, passes/SpawnOverlayPass.ts,
	passes/SmallPlayerGlowPass.ts, passes/FalloutBloomPass.ts, passes/CoordinateGridPass.ts, their
	shaders and render-settings.json. Sprites © OpenFront, CC BY-SA 4.0 (FxSprites.lua, gen_fx.py).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MapFx (ModuleScript), used by GameClient.
-- Everything here is GUI instances inside GameClient's map frame, positioned by map scale, so they
-- follow pan / zoom for free. Procedural textures (rings, glows, chevrons) are drawn once into small
-- EditableImages; sprite sheets come from FxSprites (palette-indexed OpenFront sprites).
-- MapFx.init(ctx)  ctx = { parent = map frame, layer = top fx frame, roster, getMyId(), getPhase(),
--                          getStructures(), mapSize() -> W, H, landTiles() -> n, fmt(n) -> string }
-- MapFx.reset()                       new round
-- MapFx.boat(data) / MapFx.boatEnd(id) server "boat" payload: wake (MapRender) + target ring (ours)
-- MapFx.nukeEnd(data)                 server "nukeEnd": nuke explosion or SAM interception
-- MapFx.unitSunk(tile)                warship destroyed
-- MapFx.shellHit(tile)                warship shell landed
-- MapFx.moveIndicator(tile, owner)    warship move order (converging chevrons)
-- MapFx.conquest(data)                server "conquest" { killer, victim, gold }
-- MapFx.spawnRing(stats?, now)        our breathing spawn ring (stats = { cx, cy, tiles } or nil)
-- MapFx.setGrid(on)                   coordinate grid overlay (OpenFront's M key)
-- MapFx.step(now, zoom)               every frame

local AssetService = game:GetService("AssetService")

local Settings = require(script.Parent:WaitForChild("Settings"))
local MapRender = require(script.Parent:WaitForChild("MapRender"))

local MapFx = {}

local floor, clamp = math.floor, math.clamp

-- render-settings.json "fx" (OpenFront world units; our tiles are 4 of theirs)
local OF_TILE = 4
local NUKE_SHOCK_MS = 1.5
local NUKE_SHOCK_FACTOR = 1.5
local SAM_SHOCK_MS = 0.8
local SAM_SHOCK_RADIUS = 40 / OF_TILE
local RING_WIDTH = 0.04
local DEBRIS_LIFE, DEBRIS_IN, DEBRIS_OUT = 6, 0.1, 0.8
local CONQUEST_LIFE, CONQUEST_IN, CONQUEST_OUT = 2.5, 0.1, 0.6
local ATTACK_RING_PX = 30 -- quad half size, screen px
local RING_FADE_IN, RING_FADE_OUT = 0.2, 0.3
-- moveIndicator
local MOVE_START_R, MOVE_CHEVRON, MOVE_LINE, MOVE_DURATION, MOVE_CONVERGE = 13, 5, 2, 0.8, 0.7
-- spawnOverlay (self ring 10..30 OpenFront tiles, breath speed 0.008 / ms)
local SELF_MIN_R, SELF_MAX_R = 10 / OF_TILE, 30 / OF_TILE
local BREATH_SPEED = 8
local GOLD = Color3.new(1, 0.84, 0)
-- smallPlayerGlow
local SMALL_COLOR = Color3.new(1, 0.12, 0.1)
local SMALL_ALPHA, SMALL_STRENGTH, SMALL_PULSE = 0.9, 0.35, 3
local SMALL_FRACTION, SMALL_GRACE = 0.002, 60
-- falloutBloom: heat 255 -> 0 at 1 per 100 ms tick
local FALLOUT_COOL = 25.5
local FALLOUT_COLOR = Color3.new(0.055, 0.82, 0)
local FALLOUT_HOT, FALLOUT_COLD = 1.8, 0.15
-- nuke debris plan (FxSpritePass DEBRIS_PLAN)
local DEBRIS = {
	{ "MiniFire", 1.0, 1 / 25 },
	{ "MiniSmoke", 1.0, 1 / 28 },
	{ "MiniBigSmoke", 0.9, 1 / 70 },
	{ "MiniSmokeFire", 0.9, 1 / 70 },
}

local ctx: any = nil
local glowLayer: Frame? = nil
local active: { any } = {}
local attackRings: { [number]: any } = {}
local smallGlows: { [number]: any } = {}
local lastSmallScan = 0
local playStart: number? = nil
local lastPhase = ""
local prevStructures: { [number]: number }? = nil
local lastStructureList: any = nil
local spawnRingLabel: ImageLabel? = nil
local breath = 0
local lastStep = os.clock()
local grid: Frame? = nil
local gridOn = false
local gridLabels: { TextLabel } = {}
local gridCell = 0

-- Textures
local textures: { [string]: any } = {}
local texFailed = false

local function smoothstep(e0: number, e1: number, x: number): number
	local t = clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- White texture whose alpha is fn(u, v) over u, v in [-1, 1].
local function texture(name: string, size: number, fn: (number, number) -> number): any
	local cached = textures[name]
	if cached ~= nil then
		return cached or nil
	end
	textures[name] = false
	if texFailed then
		return nil
	end
	local ok, img = pcall(function()
		local b = buffer.create(size * size * 4)
		for y = 0, size - 1 do
			local v = (y + 0.5) / size * 2 - 1
			for x = 0, size - 1 do
				local u = (x + 0.5) / size * 2 - 1
				local a = clamp(fn(u, v), 0, 1)
				buffer.writeu32(b, (y * size + x) * 4, 16777215 + floor(a * 255 + 0.5) * 16777216)
			end
		end
		local ei = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
		ei:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), b)
		return ei
	end)
	if ok and img then
		textures[name] = img
		return img
	end
	texFailed = true
	return nil
end

local TAU = math.pi * 2

-- shockwave.frag classicRing; the quad spans 1.1 x the ring radius.
local function ringTex()
	return texture("ring", 256, function(u, v)
		local d = math.sqrt(u * u + v * v) * 1.1
		return 1 - smoothstep(0, RING_WIDTH, math.abs(d - 1))
	end)
end

-- attack-ring.frag: inner thin ring with 8 dashes / outer thicker ring with 2 dashes.
local function attackTex(outer: boolean)
	return texture(if outer then "atkOuter" else "atkInner", 128, function(u, v)
		local d = math.sqrt(u * u + v * v)
		local a = math.atan2(v, u)
		if outer then
			local ring = 1 - smoothstep(0, RING_WIDTH * 3, math.abs(d - 0.8))
			local f = (a * 2 / TAU) % 1
			return ring * smoothstep(0.3, 0.4, math.abs(f - 0.5) * 2)
		end
		local ring = 1 - smoothstep(0, RING_WIDTH * 2, math.abs(d - 0.5))
		local f = (a * 8 / TAU) % 1
		return ring * smoothstep(0.4, 0.5, math.abs(f - 0.5) * 2)
	end)
end

-- spawn-overlay.frag breathing ring (radius normalised to the outer edge).
local function spawnTex()
	local inner = SELF_MIN_R / SELF_MAX_R
	return texture("spawn", 128, function(u, v)
		local d = math.sqrt(u * u + v * v)
		if d < inner then
			return d / inner
		end
		local t = (d - inner) / (1 - inner)
		if t < 0.1 then
			return 1
		elseif t < 1 then
			return 1 - (t - 0.1) / 0.9
		end
		return 0
	end)
end

-- Soft round glow (bloom stand-in).
local function glowTex()
	return texture("glow", 64, function(u, v)
		local d = math.sqrt(u * u + v * v)
		local a = math.max(0, 1 - d)
		return a * a
	end)
end

-- move-indicator.frag chevron (pointing down), 16 x 16 px quad.
local function chevronTex()
	return texture("chevron", 32, function(u, v)
		local px, py = math.abs(u * 8), v * 8
		local w, tip, wing = MOVE_CHEVRON, MOVE_CHEVRON * 0.4, MOVE_CHEVRON * 0.6
		local ax, ay = w, -wing
		local bx, by = 0, tip
		local abx, aby = bx - ax, by - ay
		local t = clamp(((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby), 0, 1)
		local dx, dy = px - ax - abx * t, py - ay - aby * t
		local d = math.sqrt(dx * dx + dy * dy)
		local half = MOVE_LINE * 0.5
		return 1 - smoothstep(half - 0.5, half + 0.5, d)
	end)
end

-- Sprite sheets
local sheetsModule: any = nil
local sheets: { [string]: any } = {}

local function sheet(name: string): (any, any)
	local cached = sheets[name]
	if cached ~= nil then
		return cached and cached.img, cached and cached.def
	end
	sheets[name] = false
	if texFailed then
		return nil, nil
	end
	if not sheetsModule then
		local mod = script.Parent:FindFirstChild("FxSprites")
		if not mod then
			return nil, nil
		end
		sheetsModule = require(mod) :: any
	end
	local def = sheetsModule[name]
	if not def then
		return nil, nil
	end
	local w, h = def.w * def.n, def.h
	local ok, img = pcall(function()
		local b = buffer.create(w * h * 4)
		local pal, px = def.pal, def.px
		for i = 1, w * h do
			buffer.writeu32(b, (i - 1) * 4, pal[string.byte(px, i) - 47])
		end
		local ei = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		ei:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), b)
		return ei
	end)
	if not ok or not img then
		texFailed = true
		return nil, nil
	end
	sheets[name] = { img = img, def = def }
	return img, def
end

-- Instances
local function tilePos(x: number, y: number): UDim2
	local W, H = ctx.mapSize()
	return UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
end

local function tileSize(wTiles: number, hTiles: number): UDim2
	local W, H = ctx.mapSize()
	return UDim2.fromScale(wTiles / W, hTiles / H)
end

local function image(img: any, props: { [string]: any }): ImageLabel
	local l = Instance.new("ImageLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.ImageContent = Content.fromObject(img)
	for k, v in props do
		(l :: any)[k] = v
	end
	return l
end

local function reduced(): boolean
	return Settings.values.reducedMotion
end

-- Animated sprite at tile (x, y). opts: { life, fadeIn, fadeOut, z }
local function sprite(name: string, x: number, y: number, opts: any?)
	local img, def = sheet(name)
	if not img then
		return
	end
	local o = opts or {}
	local label = image(img, {
		Position = tilePos(x, y),
		Size = tileSize(def.w / OF_TILE, def.h / OF_TILE),
		ImageRectSize = Vector2.new(def.w, def.h),
		ImageRectOffset = Vector2.zero,
		ResampleMode = Enum.ResamplerMode.Pixelated,
		ZIndex = o.z or 2,
		Parent = ctx.layer,
	})
	active[#active + 1] = {
		kind = "sprite",
		label = label,
		def = def,
		t0 = os.clock(),
		life = o.life or def.ms * def.n / 1000,
		fadeIn = o.fadeIn or 0,
		fadeOut = o.fadeOut or 1,
		static = reduced(),
		extra = o.extra,
	}
end

local function shockwave(x: number, y: number, maxR: number, duration: number)
	if reduced() then
		return
	end
	local img = ringTex()
	if not img then
		return
	end
	local label = image(img, { Position = tilePos(x, y), Size = UDim2.fromScale(0, 0), ZIndex = 1, Parent = ctx.layer })
	active[#active + 1] = { kind = "shock", label = label, t0 = os.clock(), life = duration, maxR = maxR }
end

local function glow(x: number, y: number, radius: number, color: Color3, life: number)
	local img = glowTex()
	if not img or not glowLayer then
		return
	end
	local label = image(img, {
		Position = tilePos(x, y),
		Size = tileSize(radius * 2, radius * 2),
		ImageColor3 = color,
		ImageTransparency = 1,
		Parent = glowLayer,
	})
	active[#active + 1] = { kind = "fallout", label = label, t0 = os.clock(), life = life }
end

local function seeded(seed: number): number
	return Random.new(seed):NextNumber()
end

-- Events
function MapFx.nukeEnd(data)
	local W = ctx.mapSize()
	local t = data.tile
	local x, y = t % W, t // W
	if not data.exploded then
		-- SAM interception: SAM explosion sprite + white shockwave.
		sprite("SamExplosion", x, y)
		shockwave(x, y, SAM_SHOCK_RADIUS, SAM_SHOCK_MS)
		return
	end
	local outer = data.radius or 7.5
	-- OpenFront's visual blast radius (70 atom / 160 hydrogen, their tiles) vs gameplay radius.
	local visual = if outer >= 20 then 160 else 70
	sprite("Nuke", x, y, { z = 3 })
	shockwave(x, y, visual * NUKE_SHOCK_FACTOR / OF_TILE, NUKE_SHOCK_MS)
	glow(x, y, outer * 1.15, FALLOUT_COLOR, FALLOUT_COOL)
	if reduced() or Settings.values.lowDetail then
		return
	end
	local i = 0
	for _, plan in DEBRIS do
		local count = floor(visual * plan[3])
		local r = visual * plan[2] / OF_TILE
		for _ = 1, count do
			local seed = t * 997 + i
			i += 1
			local angle = seeded(seed) * TAU
			local dist = seeded(seed + 65536) * (r / 2)
			sprite(plan[1], x + floor(math.cos(angle) * dist), y + floor(math.sin(angle) * dist), {
				life = DEBRIS_LIFE,
				fadeIn = DEBRIS_IN,
				fadeOut = DEBRIS_OUT,
				z = 2,
			})
		end
	end
end

function MapFx.unitSunk(tile: number)
	local W = ctx.mapSize()
	local x, y = tile % W, tile // W
	sprite("UnitExplosion", x, y, { z = 3 })
	sprite("SinkingShip", x, y)
end

function MapFx.shellHit(tile: number)
	local W = ctx.mapSize()
	sprite("MiniExplosion", tile % W, tile // W)
end

local function lighten(c: Color3, k: number): Color3
	return Color3.new(c.R + (1 - c.R) * k, c.G + (1 - c.G) * k, c.B + (1 - c.B) * k)
end

function MapFx.moveIndicator(tile: number, owner: number)
	local img = chevronTex()
	if not img then
		return
	end
	local W = ctx.mapSize()
	local p = ctx.roster[owner]
	local color = lighten(if p and p.r then Color3.fromRGB(p.r, p.g, p.b) else Color3.new(1, 0, 0), 0.3)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(1, 1)
	holder.Position = tilePos(tile % W, tile // W)
	holder.ZIndex = 4
	holder.Parent = ctx.layer
	local parts = {}
	for k = 0, 3 do
		parts[k + 1] = image(img, {
			Size = UDim2.fromOffset(16, 16),
			Rotation = k * 90,
			ImageColor3 = color,
			ZIndex = 4,
			Parent = holder,
		})
	end
	active[#active + 1] = { kind = "move", label = holder, parts = parts, t0 = os.clock(), life = MOVE_DURATION }
end

-- WorldTextPass bonus popup: "+ 10K" rising and fading over a port / train station when trade or a
-- train pays us (server "bonus" { tile, gold }).
local BONUS_LIFE = 2
function MapFx.bonus(tile: number, gold: number)
	local W = ctx.mapSize()
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 1)
	text.Position = tilePos(tile % W, tile // W)
	text.Size = UDim2.fromOffset(90, 16)
	text.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	text.TextSize = 13
	text.TextColor3 = Color3.fromRGB(253, 224, 71) -- yellow-300
	text.TextStrokeTransparency = 0.2
	text.Text = "+ " .. (if ctx.fmt then ctx.fmt(gold) else tostring(gold))
	text.ZIndex = 5
	text.Parent = ctx.layer
	active[#active + 1] = { kind = "bonus", label = text, t0 = os.clock(), life = BONUS_LIFE, base = text.Position }
end

function MapFx.conquest(data)
	if not data or data.killer ~= ctx.getMyId() then
		return
	end
	local p = ctx.roster[data.victim]
	local st = p and p.stats
	if not st or (st.cx == 0 and st.cy == 0) then
		return
	end
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0)
	text.Position = UDim2.new(0.5, 0, 1, 0)
	text.Size = UDim2.fromOffset(120, 18)
	text.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	text.TextSize = 15
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.2
	text.Text = "+ " .. (if ctx.fmt then ctx.fmt(data.gold or 0) else tostring(data.gold or 0))
	text.ZIndex = 4
	sprite("Conquest", st.cx, st.cy, { life = CONQUEST_LIFE, fadeIn = CONQUEST_IN, fadeOut = CONQUEST_OUT, z = 4, extra = text })
	local e = active[#active]
	if e and e.extra == text then
		text.Parent = e.label
	else
		text:Destroy()
	end
end

function MapFx.boat(data)
	if data.kind ~= "transport" then
		return
	end
	MapRender.addTrail(data.id, data.path, data.start, data.speed, data.owner)
	if data.owner ~= ctx.getMyId() then
		return
	end
	local n = buffer.len(data.path) // 4
	if n == 0 then
		return
	end
	local inner, outer = attackTex(false), attackTex(true)
	if not inner or not outer then
		return
	end
	local W = ctx.mapSize()
	local target = buffer.readu32(data.path, (n - 1) * 4)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(ATTACK_RING_PX * 2, ATTACK_RING_PX * 2)
	holder.Position = tilePos(target % W, target // W)
	holder.ZIndex = 3
	holder.Parent = ctx.layer
	local props = { Size = UDim2.fromScale(1, 1), Position = UDim2.fromScale(0.5, 0.5), ImageColor3 = Color3.new(1, 0, 0), ImageTransparency = 1, ZIndex = 3, Parent = holder }
	local a = image(inner, props)
	local b = image(outer, props)
	attackRings[data.id] = { holder = holder, inner = a, outer = b, t0 = os.clock(), fading = false }
end

function MapFx.boatEnd(id: number)
	MapRender.removeTrail(id)
	local r = attackRings[id]
	if r and not r.fading then
		r.fading = true
		r.t0 = os.clock()
	end
end

-- Our breathing spawn ring (spawn phase, and while the tutorial keeps it up).
function MapFx.spawnRing(st: any?, now: number)
	if not st then
		if spawnRingLabel then
			spawnRingLabel.Visible = false
		end
		return
	end
	if not spawnRingLabel then
		local img = spawnTex()
		if not img or not glowLayer then
			return
		end
		spawnRingLabel = image(img, { ZIndex = 2, Parent = glowLayer })
	end
	local l = spawnRingLabel :: ImageLabel
	local b = if reduced() then 0.6 else 0.5 + 0.5 * math.sin(breath)
	local scale = 0.5 + 0.65 * b
	local r = SELF_MAX_R * scale
	l.Visible = true
	l.Position = tilePos(st.cx, st.cy)
	l.Size = tileSize(r * 2, r * 2)
	l.ImageColor3 = Color3.new(1, 1, 1):Lerp(GOLD, b)
	l.ImageTransparency = 1 - (0.65 + 0.35 * b)
end

-- Coordinate grid (CoordinateGridPass: white lines, "A1" labels once cells are >= 60 px)
local function cellSize(W: number, H: number): number
	local raw = math.min(W, H) / 10
	local rows = math.max(1, math.floor(H / raw + 0.5))
	local cols = math.max(1, math.floor(W / raw + 0.5))
	if cols > 50 then
		local maxRows = math.floor(50 * H / W)
		rows = math.max(2, math.min(rows, maxRows))
		cols = 50
	end
	return math.min(W / cols, H / rows)
end

local function rowName(r: number): string
	if r < 26 then
		return string.char(65 + r)
	end
	return string.char(65 + r // 26 - 1) .. string.char(65 + r % 26)
end

local function buildGrid()
	if grid then
		grid:Destroy()
	end
	table.clear(gridLabels)
	local W, H = ctx.mapSize()
	local cs = cellSize(W, H)
	gridCell = cs
	local g = Instance.new("Frame")
	g.Name = "CoordinateGrid"
	g.BackgroundTransparency = 1
	g.Size = UDim2.fromScale(1, 1)
	g.ZIndex = 3
	g.Visible = gridOn
	g.Parent = ctx.parent
	local cols, rows = math.ceil(W / cs - 1e-6), math.ceil(H / cs - 1e-6)
	local function line(horizontal: boolean, f: number)
		local l = Instance.new("Frame")
		l.BorderSizePixel = 0
		l.BackgroundColor3 = Color3.new(1, 1, 1)
		l.BackgroundTransparency = 0.5
		l.ZIndex = 3
		if horizontal then
			l.Position = UDim2.fromScale(0, f)
			l.Size = UDim2.new(1, 0, 0, 1)
		else
			l.Position = UDim2.fromScale(f, 0)
			l.Size = UDim2.new(0, 1, 1, 0)
		end
		l.Parent = g
	end
	for c = 0, cols - 1 do
		line(false, c * cs / W)
	end
	for r = 0, rows - 1 do
		line(true, r * cs / H)
	end
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local t = Instance.new("TextLabel")
			t.BackgroundTransparency = 1
			t.Position = UDim2.new(c * cs / W, 8, r * cs / H, 8)
			t.Size = UDim2.fromOffset(60, 24)
			t.TextXAlignment = Enum.TextXAlignment.Left
			t.TextYAlignment = Enum.TextYAlignment.Top
			t.FontFace = Font.fromEnum(Enum.Font.Code)
			t.TextColor3 = Color3.new(1, 1, 1)
			t.TextStrokeTransparency = 0.3
			t.TextTransparency = 0.5
			t.TextSize = 20
			t.Text = rowName(r) .. tostring(c + 1)
			t.ZIndex = 3
			t.Parent = g
			gridLabels[#gridLabels + 1] = t
		end
	end
	grid = g
end

function MapFx.setGrid(on: boolean)
	gridOn = on
	if on and not grid then
		buildGrid()
	end
	if grid then
		grid.Visible = on
	end
end

-- Per-frame
local function stepStructures()
	local list = ctx.getStructures()
	if list == lastStructureList then
		return
	end
	lastStructureList = list
	local now: { [number]: number } = {}
	for _, s in list do
		now[s[1]] = s[3]
	end
	local prev = prevStructures
	prevStructures = now
	if not prev or ctx.getPhase() ~= "Play" then
		return
	end
	local W = ctx.mapSize()
	local gone = 0
	for id, tile in prev do
		if now[id] == nil then
			gone += 1
			if gone > 40 then
				break -- a reset, not a battle
			end
			sprite("BuildingExplosion", tile % W, tile // W)
		end
	end
end

local function stepSmallGlows(now: number)
	local phase = ctx.getPhase()
	if phase ~= lastPhase then
		lastPhase = phase
		playStart = if phase == "Play" then now else nil
	end
	local want = playStart ~= nil and now - playStart >= SMALL_GRACE and not Settings.values.lowDetail
	if now - lastSmallScan > 1 then
		lastSmallScan = now
		local land = math.max(1, ctx.landTiles())
		local keep = {}
		if want then
			for id, p in ctx.roster do
				local st = p.stats
				if p.kind == "Human" and st and st.alive and st.tiles > 0 and st.tiles / land <= SMALL_FRACTION then
					keep[id] = true
					local g = smallGlows[id]
					if not g and glowLayer then
						local img = glowTex()
						if img then
							g = { label = image(img, { ImageColor3 = SMALL_COLOR, ZIndex = 1, Parent = glowLayer }) }
							smallGlows[id] = g
						end
					end
					if g then
						local r = math.sqrt(st.tiles / math.pi) + 5
						g.label.Position = tilePos(st.cx, st.cy)
						g.label.Size = tileSize(r * 2, r * 2)
					end
				end
			end
		end
		for id, g in smallGlows do
			if not keep[id] then
				g.label:Destroy()
				smallGlows[id] = nil
			end
		end
	end
	if next(smallGlows) then
		local pulse = if reduced() then 1 else 0.75 + 0.25 * math.sin(now * SMALL_PULSE)
		local a = SMALL_ALPHA * SMALL_STRENGTH * 1.6 * pulse
		for _, g in smallGlows do
			g.label.ImageTransparency = 1 - math.min(1, a)
		end
	end
end

function MapFx.step(now: number, zoom: number)
	if not ctx then
		return
	end
	local dt = math.min(0.1, now - lastStep)
	lastStep = now
	breath += dt * BREATH_SPEED
	stepStructures()
	stepSmallGlows(now)

	local i = 1
	while i <= #active do
		local e = active[i]
		local el = now - e.t0
		if el >= e.life or not e.label.Parent then
			e.label:Destroy()
			active[i] = active[#active]
			active[#active] = nil
			continue
		end
		local f = el / e.life
		if e.kind == "sprite" then
			local def = e.def
			local frame
			if e.static then
				frame = if def.loop then 0 else def.n // 2
			elseif def.loop then
				frame = floor(el * 1000 / def.ms) % def.n
			else
				frame = math.min(floor(el * 1000 / def.ms), def.n - 1)
			end
			e.label.ImageRectOffset = Vector2.new(frame * def.w, 0)
			local alpha = 1
			if f < e.fadeIn then
				alpha = f / e.fadeIn
			elseif f > e.fadeOut then
				alpha = (1 - f) / (1 - e.fadeOut)
			end
			e.label.ImageTransparency = 1 - alpha
			if e.extra then
				e.extra.TextTransparency = 1 - alpha
				e.extra.TextStrokeTransparency = 1 - alpha * 0.8
			end
		elseif e.kind == "shock" then
			local r = f * e.maxR * 1.1
			e.label.Size = tileSize(r * 2, r * 2)
			e.label.ImageTransparency = f
		elseif e.kind == "move" then
			local radius = MOVE_START_R * (1 - (if reduced() then 0.5 else f) * MOVE_CONVERGE)
			local offs = { Vector2.new(0, -radius), Vector2.new(radius, 0), Vector2.new(0, radius), Vector2.new(-radius, 0) }
			for k, part in e.parts do
				part.Position = UDim2.new(0.5, offs[k].X, 0.5, offs[k].Y)
				part.ImageTransparency = f
			end
		elseif e.kind == "bonus" then
			e.label.Position = e.base + UDim2.fromOffset(0, -18 * f)
			local alpha = if f < 0.7 then 1 else (1 - f) / 0.3
			e.label.TextTransparency = 1 - alpha
			e.label.TextStrokeTransparency = 1 - alpha * 0.8
		elseif e.kind == "fallout" then
			local heat = 1 - f
			local intensity = FALLOUT_COLD + (FALLOUT_HOT - FALLOUT_COLD) * heat
			e.label.ImageTransparency = 1 - math.min(0.85, smoothstep(0, 1, heat) * intensity * 0.5)
		end
		i += 1
	end

	for id, r in attackRings do
		local el = now - r.t0
		local alpha
		if r.fading then
			alpha = 1 - el / RING_FADE_OUT
			if alpha <= 0 then
				r.holder:Destroy()
				attackRings[id] = nil
				continue
			end
		else
			alpha = math.min(1, el / RING_FADE_IN)
		end
		r.inner.ImageTransparency = 1 - alpha
		r.outer.ImageTransparency = 1 - alpha
		if not reduced() then
			r.inner.Rotation = math.deg(now * 1.2) % 360
			r.outer.Rotation = -math.deg(now * 0.6) % 360
		end
	end

	if grid and gridOn then
		local show = gridCell * zoom >= 60
		local size = clamp(24 + (zoom / OF_TILE - 1) * 1.2, 24 * 0.9, 24 * 1.6) * 0.8
		for _, t in gridLabels do
			t.Visible = show
			t.TextSize = size
		end
	end
end

function MapFx.reset()
	MapRender.invalidate() -- new round: the owners snapshot replaced every tile
	for _, e in active do
		e.label:Destroy()
	end
	table.clear(active)
	for _, r in attackRings do
		r.holder:Destroy()
	end
	table.clear(attackRings)
	for _, g in smallGlows do
		g.label:Destroy()
	end
	table.clear(smallGlows)
	prevStructures = nil
	lastStructureList = nil
	if grid then
		grid:Destroy()
		grid = nil
		if gridOn then
			buildGrid()
		end
	end
end

function MapFx.init(c)
	ctx = c
	local g = Instance.new("Frame")
	g.Name = "MapGlow"
	g.BackgroundTransparency = 1
	g.Size = UDim2.fromScale(1, 1)
	g.ZIndex = 1 -- above the map chunks (0), below structures / units / names (2+)
	g.Parent = c.parent
	glowLayer = g
end

return MapFx
