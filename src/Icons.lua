--[[
	Frontlines (working title) - icon index (OpenFront icons as raw pixels for EditableImage).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Icons © OpenFront, CC BY-SA 4.0 (resources/images), rasterized to 48x48 by icons/gen_icons.py.
	GENERATED FILE - edit gen_icons.py and re-run it instead of editing this by hand.
]]

-- ReplicatedStorage.Shared.Icons (ModuleScript). Children-free: the pixel data lives in the
-- sibling modules Shared.IconsData1..N (a script Source is limited to 200,000 characters).
-- Icons.SIZE, Icons.CREDIT, Icons.has(name), Icons.get(name) -> (format "A" | "RGBA", base64)?
-- Clients draw them with StarterPlayerScripts.IconKit.

local Shared = script.Parent

local Icons = {}
Icons.SIZE = 48
Icons.CREDIT = "Icons © OpenFront, CC BY-SA 4.0"

-- name -> { chunk index, format }
local INDEX = {
	City = { 1, "A" },
	Port = { 1, "A" },
	Defense = { 1, "A" },
	Silo = { 1, "A" },
	SAM = { 1, "A" },
	AtomBomb = { 1, "A" },
	HBomb = { 1, "A" },
	Warship = { 1, "A" },
	TradeShip = { 1, "A" },
	Boat = { 1, "A" },
	Gold = { 1, "A" },
	Troops = { 1, "A" },
	Alliance = { 1, "A" },
	Traitor = { 1, "A" },
	Embargo = { 1, "A" },
	Target = { 1, "A" },
	Sword = { 1, "A" },
	Leaderboard = { 1, "A" },
	Settings = { 1, "A" },
	Info = { 1, "A" },
	DonateGold = { 1, "A" },
	DonateTroops = { 1, "A" },
	Close = { 1, "A" },
	Crown = { 1, "RGBA" },
	Explosion = { 1, "A" },
	Land = { 1, "A" },
	Build = { 1, "A" },
	Emoji = { 1, "A" },
	Back = { 1, "A" },
	Soldier = { 1, "A" },
	Factory = { 1, "A" },
	MIRV = { 1, "A" },
	Chat = { 1, "A" },
	Exit = { 1, "A" },
	LeaderboardRegular = { 1, "A" },
	Tree = { 1, "A" },
	UpperLimit = { 1, "A" },
	Profile = { 1, "A" },
	Stop = { 1, "A" },
	Team = { 1, "A" },
	TeamRegular = { 1, "A" },
	MkCity = { 1, "A" },
	MkCityIn = { 1, "A" },
	MkIconCity = { 1, "A" },
	MkPort = { 1, "A" },
	MkPortIn = { 1, "A" },
	MkIconPort = { 1, "A" },
	MkDefense = { 1, "A" },
	MkDefenseIn = { 1, "A" },
	MkIconDefense = { 1, "A" },
	MkSAM = { 1, "A" },
	MkSAMIn = { 1, "A" },
	MkIconSAM = { 1, "A" },
	MkSilo = { 1, "A" },
	MkSiloIn = { 1, "A" },
	MkIconSilo = { 1, "A" },
	MkFactory = { 2, "A" },
	MkFactoryIn = { 2, "A" },
	MkIconFactory = { 2, "A" },
	Play = { 2, "A" },
	Pause = { 2, "A" },
	FastForward = { 2, "A" },
}

local CHUNKS = 2
local loaded: { [number]: { [string]: string } } = {}

function Icons.has(name: string): boolean
	return INDEX[name] ~= nil
end

function Icons.get(name: string): (string?, string?)
	local e = INDEX[name]
	if not e then
		return nil, nil
	end
	local i = e[1]
	if not loaded[i] then
		local mod = Shared:WaitForChild("IconsData" .. i, 10)
		if not mod or i > CHUNKS then
			return nil, nil
		end
		loaded[i] = require(mod) :: any
	end
	return e[2], loaded[i][name]
end

return Icons
