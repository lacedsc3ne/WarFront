--[[
	War Front - Doomsday Clock threshold math (OpenFront core/game/DoomsdayClock.ts), shared by the
	server (Doomsday ModuleScript) and the HUD panel so the two always agree.

	The required share of the map rises in WAVES: one flat grace at the very start, then each wave
	grows the share linearly over rampSeconds to its level, followed by a flat pause before the next
	wave. A side below the bar gets a warn countdown, then bleeds troops. Integer-only and floored.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
]]

local Doomsday = {}

-- DOOMSDAY_CLOCK_DEFAULTS (Config.ts)
Doomsday.CFG = {
	warnSeconds = 30, -- cooldown (the flashing danger cue) before decay begins
	drainStartPercent = 2,
	drainMaxPercent = 5,
	drainRampSeconds = 90,
	drainFloorPercent = 5,
	floorStartPercent = 40,
	floorDecaySeconds = 90,
	rotDeathSeconds = 150,
	rotGrainSeconds = 10,
	rotSpecklePercent = 15,
	warshipDrainStartPercent = 1,
	warshipDrainMaxPercent = 50,
	warshipDrainCurveExponent = 8,
}

local LEVELS = { 200, 400, 700, 1100, 1700, 2500, 3500 } -- 2/4/7/11/17/25/35 %
local LEVELS_TEAM = { 300, 600, 1000, 1500, 2100, 2800, 3500 } -- 3/6/10/15/21/28/35 %
local function wave(ramp: number, pause: number)
	return {
		graceSeconds = 600,
		rampSeconds = { ramp, ramp, ramp, ramp, ramp, ramp, ramp },
		pauseSeconds = { pause, pause, pause, pause, pause, pause, 0 },
	}
end
local SCHEDULES = {
	normal = wave(168, 54), -- 35 % at 35:00
	slow = wave(240, 70), -- 35 % at 45:00
	fast = wave(102, 31), -- 35 % at 25:00
	veryfast = wave(36, 8), -- 35 % at 15:00
}

local function schedule(speed: string, teamGame: boolean)
	local s = SCHEDULES[speed] or SCHEDULES.normal
	return s, if teamGame then LEVELS_TEAM else LEVELS
end

-- Required share of the map in basis points at `elapsed` game seconds.
function Doomsday.requiredBasisPoints(speed: string, teamGame: boolean, elapsed: number): number
	local s, levels = schedule(speed, teamGame)
	if elapsed <= s.graceSeconds then
		return 0
	end
	local t = elapsed - s.graceSeconds
	local prev = 0
	for i, target in levels do
		local ramp = s.rampSeconds[i]
		if t < ramp then
			return prev + math.floor((target - prev) * t / ramp)
		end
		t -= ramp
		if t < s.pauseSeconds[i] then
			return target
		end
		t -= s.pauseSeconds[i]
		prev = target
	end
	return levels[#levels]
end

-- Minimum tiles one SIDE must hold (a solo player in FFA, a whole team otherwise).
function Doomsday.requiredTiles(speed: string, teamGame: boolean, land: number, elapsed: number): number
	if land <= 0 then
		return 0
	end
	return math.floor(Doomsday.requiredBasisPoints(speed, teamGame, elapsed) * land / 10000)
end

-- Display-only companion for the HUD (doomsdayClockWaveState).
function Doomsday.waveState(speed: string, teamGame: boolean, elapsed: number)
	local s, levels = schedule(speed, teamGame)
	local current = Doomsday.requiredBasisPoints(speed, teamGame, elapsed) / 100
	local n = #levels
	if elapsed <= s.graceSeconds then
		return {
			currentPercent = 0,
			targetPercent = levels[1] / 100,
			growing = false,
			secondsToNextGrowth = s.graceSeconds - elapsed,
			secondsToTarget = 0,
			waveFlash = s.graceSeconds - elapsed <= 5,
			done = false,
		}
	end
	local t = elapsed - s.graceSeconds
	for i = 1, n do
		local ramp, pause = s.rampSeconds[i], s.pauseSeconds[i]
		local isLast = i == n
		if t < ramp then
			return {
				currentPercent = current,
				targetPercent = levels[i] / 100,
				growing = true,
				secondsToNextGrowth = 0,
				secondsToTarget = ramp - t,
				waveFlash = t <= 5,
				done = false,
			}
		end
		t -= ramp
		if t < pause then
			return {
				currentPercent = current,
				targetPercent = (if isLast then levels[i] else levels[i + 1]) / 100,
				growing = false,
				secondsToNextGrowth = if isLast then 0 else pause - t,
				secondsToTarget = 0,
				waveFlash = not isLast and pause - t <= 5,
				done = isLast,
			}
		end
		t -= pause
	end
	return {
		currentPercent = current,
		targetPercent = levels[n] / 100,
		growing = false,
		secondsToNextGrowth = 0,
		secondsToTarget = 0,
		waveFlash = false,
		done = true,
	}
end

-- Troop floor `secondsPastWarn` into the decay (doomsdayClockTroopFloor).
function Doomsday.troopFloor(maxTroops: number, secondsPastWarn: number): number
	local c = Doomsday.CFG
	local finish = c.drainFloorPercent
	local span = c.floorStartPercent - finish
	local t = math.max(0, secondsPastWarn)
	local pct = if span > 0 and c.floorDecaySeconds > 0 and t < c.floorDecaySeconds
		then c.floorStartPercent - math.floor(span * t / c.floorDecaySeconds)
		else finish
	return math.floor(maxTroops * pct / 100)
end

-- Troops (or warship health) lost this second (doomsdayClockDrain). exponent > 1 = convex ramp.
function Doomsday.drain(maxValue: number, secondsPastWarn: number, startPct: number?, maxPct: number?, exponent: number?): number
	local c = Doomsday.CFG
	local s0 = startPct or c.drainStartPercent
	local s1 = maxPct or c.drainMaxPercent
	local t = math.max(0, secondsPastWarn)
	local r = c.drainRampSeconds
	local pct = s1
	if r > 0 and t < r then
		local span = s1 - s0
		if (exponent or 1) <= 1 then
			pct = s0 + math.floor(span * t / r)
		else
			pct = s0 + math.floor(span * (t / r) ^ exponent)
		end
	end
	return math.max(1, math.floor(maxValue * pct / 100))
end

-- Tiles rot takes per second: ceil(tilesLeft / secondsLeft) (doomsdayClockRotQuota).
function Doomsday.rotQuota(tilesLeft: number, secondsUnder: number): number
	local c = Doomsday.CFG
	if tilesLeft <= 0 or c.rotDeathSeconds <= 0 then
		return 0
	end
	return math.ceil(tilesLeft / math.max(1, c.rotDeathSeconds - secondsUnder))
end

-- Rot noise (integer hashes, no PRNG state)
local TWO32 = 4294967296
local function mul32(a: number, b: number): number
	a, b = a % TWO32, b % TWO32
	local ah, al = a // 65536, a % 65536
	local bh, bl = b // 65536, b % 65536
	return (((ah * bl + al * bh) % 65536) * 65536 + al * bl) % TWO32
end
Doomsday.NOISE_SCALE = 65536

-- R2 low-discrepancy lattice: near-evenly spaced pinholes (rotSpeckleNoise).
function Doomsday.speckleNoise(x: number, y: number, salt: number): number
	local h = (mul32(x, 3242174889) + mul32(y, 2447445413) + mul32(salt, 0x9e3779b9)) % TWO32
	return (h // 65536) % 65536
end

-- Hashed per-tile value that orders the rot front (rotFrontNoise).
function Doomsday.frontNoise(tile: number, salt: number): number
	local h = bit32.bxor(mul32(tile, 0x27d4eb2d), mul32(salt, 0x9e3779b9))
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = mul32(h, 0x2545f491)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	return bit32.rshift(h, 16) % 65536
end

return Doomsday
