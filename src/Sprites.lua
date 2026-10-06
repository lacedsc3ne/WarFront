--[[
	War Front - map sprite index (OpenFront unit sprites and status icons as raw pixels).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Sprites © OpenFront, CC BY-SA 4.0 (resources/atlases/unit-atlas.png, status-atlas.png),
	converted by gen_sprites.py.
	GENERATED FILE - edit gen_sprites.py and re-run it instead of editing this by hand.
]]

-- ReplicatedStorage.Shared.Sprites (ModuleScript). Children-free: the pixel data lives in the
-- sibling modules Shared.SpritesData1..N (a script Source is limited to 200,000 characters).
-- Sprites.has(name), Sprites.get(name) -> (format "A" | "RGBA", size, base64)?
-- Square images. Clients draw them with StarterPlayerScripts.SpriteKit.

local Shared = script.Parent

local Sprites = {}
Sprites.CREDIT = "Sprites © OpenFront, CC BY-SA 4.0"

-- name -> { chunk index, format, size }
local INDEX = {
	UTransportA = { 1, "A", 13 },
	UTransportB = { 1, "A", 13 },
	UTradeShipA = { 1, "A", 13 },
	UTradeShipB = { 1, "A", 13 },
	UWarshipA = { 1, "A", 13 },
	UWarshipC = { 1, "A", 13 },
	UWarshipB = { 1, "A", 13 },
	UAtomBombA = { 1, "A", 13 },
	UAtomBombM = { 1, "A", 13 },
	UHydrogenBombA = { 1, "A", 13 },
	UHydrogenBombM = { 1, "A", 13 },
	USAMMissileA = { 1, "A", 13 },
	USAMMissileM = { 1, "A", 13 },
	UMIRVA = { 1, "A", 13 },
	UMIRVM = { 1, "A", 13 },
	UShellW = { 1, "A", 13 },
	UMIRVWarheadW = { 1, "A", 13 },
	UTrainEngineB = { 1, "A", 13 },
	UTrainCarriageA = { 1, "A", 13 },
	UTrainCarriageB = { 1, "A", 13 },
	UTrainCarriageLoadedA = { 1, "A", 13 },
	UTrainCarriageLoadedB = { 1, "A", 13 },
	UGlow = { 1, "A", 32 },
	StCrown = { 1, "RGBA", 64 },
	StTraitor = { 1, "RGBA", 64 },
	StDisconnected = { 1, "RGBA", 64 },
	StAlliance = { 1, "RGBA", 67 },
	StAllianceRequest = { 1, "RGBA", 64 },
	StTarget = { 1, "RGBA", 64 },
	StEmbargo = { 1, "RGBA", 64 },
	StNukeRed = { 2, "RGBA", 64 },
	StNukeWhite = { 2, "RGBA", 64 },
	StAllianceFaded = { 2, "RGBA", 67 },
	StDoomsday = { 2, "RGBA", 64 },
}

local CHUNKS = 2
local loaded: { [number]: { [string]: string } } = {}

function Sprites.has(name: string): boolean
	return INDEX[name] ~= nil
end

function Sprites.get(name: string): (string?, number?, string?)
	local e = INDEX[name]
	if not e or e[1] > CHUNKS then
		return nil, nil, nil
	end
	local i = e[1]
	if not loaded[i] then
		local mod = Shared:WaitForChild("SpritesData" .. i, 10)
		if not mod then
			return nil, nil, nil
		end
		loaded[i] = require(mod) :: any
	end
	return e[2], e[3], loaded[i][name]
end

return Sprites
