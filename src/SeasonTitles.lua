-- War Front titles (earned from the season pass). Copyright (C) 2026 Liam (lacedsc3ne).
-- The one list both the server (ServerScriptService.Quests) and the menu (My items, profile) read.
-- SeasonTitles.ORDER = { { id, name } } in season pass order; SeasonTitles.NAMES[id] = name.

local SeasonTitles = {}

SeasonTitles.ORDER = {
	{ "recruit", "Recruit" },
	{ "scout", "Scout" },
	{ "firstStrike", "First Striker" },
	{ "commander", "Commander" },
	{ "warlord", "Warlord" },
	{ "general", "General" },
	{ "goldGeneral", "Gold General" },
}

SeasonTitles.NAMES = {}
for _, t in SeasonTitles.ORDER do
	SeasonTitles.NAMES[t[1]] = t[2]
end

return SeasonTitles
