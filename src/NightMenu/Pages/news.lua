-- War Front Night menu: What's new (release notes). Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES).

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

-- Newest first. Keep each line short and in plain words.
local NOTES = {
	{
		title = "Latest update",
		icon = "Star",
		color = C.YELLOW,
		items = {
			"Open battles list: see public battles and join with one click. Private battles stay hidden behind their code.",
			"Retreating troops always come home now, and nukes no longer leave stuck target outlines.",
			"Make your own battle: pick the settings first, then invite your friends.",
			"Clans update live: members, roles and join requests refresh by themselves.",
			"Hold Shift while placing a building to keep placing more.",
			"Join the Phasma Studio's group for 500 medals, the Phasma Teal colour and a free Gold crate every day.",
			"New music in the menu and in battles.",
		},
	},
	{
		title = "Ways to play",
		icon = "Swords",
		color = C.CYAN,
		items = {
			"Quick battles for everyone, teams, and special battles with extra rules like the Doomsday clock.",
			"Practice alone against computer players, with all the battle options.",
			"Make your own battle, keep it private with a code, and start when everyone is in.",
		},
	},
	{
		title = "In every battle",
		icon = "Flag",
		color = C.GREEN,
		items = {
			"Alliances, betrayals, trading, targets, emojis and quick chat.",
			"Warships, boats, trade ships, nukes, missile silos and SAM launchers.",
			"Upgrade buildings, and build factories for trains and railways.",
			"Clans: your tag shows before your name and clanmates play on the same team.",
			"Rankings, friends, battle history and end-of-battle stats.",
			"Works with mouse, touch and controller.",
		},
	},
}

local function section(body: Instance, order: number, note)
	local card = Kit.card({ Name = note.title, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = body })
	Kit.pad(card, 18, 18, 14, 16)
	Kit.list(card, false, 8)
	local head = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 0, Parent = card })
	Kit.list(head, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local badge = make("Frame", { BackgroundColor3 = note.color, BorderSizePixel = 0, Size = UDim2.fromOffset(30, 30), LayoutOrder = 1, Parent = head })
	Kit.corner(badge, 9)
	Kit.icon(note.icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), ImageColor3 = C.BG, Parent = badge })
	Kit.text({ Text = note.title, FontFace = F.TITLE, TextSize = 21, LayoutOrder = 2, Parent = head })
	for i, line in note.items do
		local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = card })
		local dot = make("Frame", { BackgroundColor3 = note.color, BorderSizePixel = 0, Position = UDim2.fromOffset(4, 8), Size = UDim2.fromOffset(7, 7), Parent = row })
		Kit.corner(dot)
		Kit.text({
			Text = line,
			FontFace = F.BOLD,
			TextSize = 16,
			TextColor3 = C.TEXT,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(22, 0),
			Size = UDim2.new(1, -22, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = row,
		})
	end
end

return {
	title = "What's new",
	render = function(page, _ctx)
		Kit.list(page.body, false, 14)
		for i, note in NOTES do
			section(page.body, i, note)
		end
	end,
}
