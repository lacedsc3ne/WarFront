-- War Front Night menu notifications feed. Copyright (C) 2026 Liam (lacedsc3ne).
-- Collects this session's events from Shared.Meta (battle rewards, level ups, daily gift, group
-- rewards) for the bell. Nothing is saved; the server stays the source of truth.
--
-- Feed.items() -> { { id, kind, icon, color, title, body, t } } newest first
-- Feed.unread() -> number            Feed.markRead()
-- Feed.add(item)                     extra items (e.g. the client adding a notice)
-- Feed.Changed (RBXScriptSignal)     fires after any change

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent:WaitForChild("Kit"))
local C = Kit.C

local Feed = {}
local MAX = 30
local list: { any } = {}
local readUpTo = 0
local nextId = 0
local changed = Instance.new("BindableEvent")
Feed.Changed = changed.Event

function Feed.add(item: any)
	nextId += 1
	item.id = nextId
	item.t = item.t or os.time()
	table.insert(list, 1, item)
	while #list > MAX do
		table.remove(list)
	end
	changed:Fire()
end

function Feed.items(): { any }
	return list
end

function Feed.unread(): number
	local n = 0
	for _, item in list do
		if item.id > readUpTo then
			n += 1
		end
	end
	return n
end

function Feed.markRead()
	if list[1] and list[1].id > readUpTo then
		readUpTo = list[1].id
		changed:Fire()
	end
end

local function placeWords(n: any): string
	n = tonumber(n)
	if not n then
		return ""
	end
	local suffix = if n % 10 == 1 and n % 100 ~= 11 then "st" elseif n % 10 == 2 and n % 100 ~= 12 then "nd" elseif n % 10 == 3 and n % 100 ~= 13 then "rd" else "th"
	return n .. suffix
end

task.spawn(function()
	local meta = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Meta")
	meta.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "reward" and type(data) == "table" then
			local extra = {}
			if data.friend then
				table.insert(extra, "friend bonus")
			end
			if data.vip then
				table.insert(extra, "VIP")
			end
			Feed.add({
				kind = "reward",
				icon = if data.won then "Trophy" else "Swords",
				color = if data.won then C.YELLOW else C.CYAN,
				title = if data.won then "You won the battle!" elseif data.placement then "You finished " .. placeWords(data.placement) else "Battle finished",
				body = string.format("+%d medals · +%d XP%s", tonumber(data.coins) or 0, tonumber(data.xp) or 0, if #extra > 0 then " (" .. table.concat(extra, ", ") .. ")" else ""),
			})
		elseif kind == "levelUp" then
			Feed.add({ kind = "level", icon = "Star", color = C.CYAN, title = "Level up! You're level " .. tostring(data), body = "New colours may be ready in the Shop." })
		elseif kind == "daily" and type(data) == "table" then
			Feed.add({ kind = "daily", icon = "Gift", color = C.YELLOW, title = "Daily gift: day " .. tostring(data.day), body = "+" .. tostring(data.coins) .. " medals. Come back tomorrow for more!" })
		elseif kind == "group" and type(data) == "table" then
			Feed.add({ kind = "group", icon = "Users", color = C.GREEN, title = "Group reward", body = if data.medals then "+" .. data.medals .. " medals for joining the group" else "A free boost from the group" })
		end
	end)
end)

return Feed
