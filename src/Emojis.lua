--[[
	War Front - quick emoji list (shared by the client emoji table and the server relay).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- ReplicatedStorage.Shared.Emojis (ModuleScript), used by GameServer (validates the index it relays)
-- and the client (PlayerPanel's emoji table, MatchHud's emoji bubbles / feed lines).
-- Players only ever send an index into this fixed list, never free text, so nothing needs filtering.
-- Order and layout follow OpenFront's emojiTable (5 per row); one gesture is swapped for 😤.

local Emojis = {}

Emojis.COLUMNS = 5
Emojis.LIST = {
	"😀", "😊", "🥰", "😇", "😎",
	"😞", "🥺", "😭", "😱", "😡",
	"😈", "🤡", "🥱", "🫡", "😤",
	"👋", "👏", "✋", "🙏", "💪",
	"👍", "👎", "🫴", "🤌", "🤦‍♂️",
	"🤝", "🆘", "🕊️", "🏳️", "⏳",
	"🔥", "💥", "💀", "☢️", "⚠️",
	"↖️", "⬆️", "↗️", "👑", "🥇",
	"⬅️", "🎯", "➡️", "🥈", "🥉",
	"↙️", "⬇️", "↘️", "❤️", "💔",
	"💰", "⚓", "⛵", "🏡", "🛡️",
	"🏭", "🚂", "❓", "🐔", "🐀",
}
Emojis.COUNT = #Emojis.LIST
-- OpenFront: an emoji stays over the sender's name for 5 s; the same recipient can get one every 5 s.
Emojis.DURATION = 5
Emojis.COOLDOWN_TICKS = 50

return Emojis
