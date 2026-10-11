-- War Front Night menu: Your profile. Copyright (C) 2026 Liam (lacedsc3ne).
-- Same data as the old page:
--   MenuPages.renderProfileTab: stats from the public profile (games, wins, eliminations, win rate),
--     MetaFn "history" (newest last, Progression.roundEnded: t, map, mode, kind, players, place, won,
--     secs, stats, left) and GameStatsView.open(gui, g.stats, g) for one battle.
--   AccountView: the battle name goes through MainMenu's NameInput controller
--     (ctx.nameController(): submit(text) -> (ok, "pending" | "unchanged" | error), get(), Changed).
--     A second NameInput.attach is not used: it would add another Net listener and send the saved
--     name again.
-- Rank points (ranked) stay hidden until ranked comes out.
-- Title and flag: profile.title / profile.flag (picked in My items, MetaFn "equipTitle" / "equipFlag").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local Art = require(script.Parent.Parent:WaitForChild("Art"))
local MetaConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MetaConfig"))
local FlagKit = require(script.Parent.Parent.Parent:WaitForChild("FlagKit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local MAX_NAME = 20 -- NameInput MAX

-- Title names (shared with the server's season pass rewards).
local TITLES = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SeasonTitles")).NAMES

local function short(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

-- Same wording as Home.plainMode (Teams.label values).
local function plainMode(sub: any): string
	if type(sub) ~= "string" or sub == "" then
		return "Everyone for themselves"
	end
	local low = string.lower(sub)
	if string.find(low, "free for all", 1, true) then
		return "Everyone for themselves"
	elseif low == "duos" then
		return "Pairs"
	elseif low == "trios" then
		return "Teams of 3"
	elseif low == "quads" then
		return "Teams of 4"
	elseif string.find(low, "humans vs nations", 1, true) then
		return "Humans vs computer"
	end
	local n = string.match(low, "^(%d+) teams")
	if n then
		return n .. " teams"
	end
	return string.upper(string.sub(sub, 1, 1)) .. string.lower(string.sub(sub, 2))
end

local KIND_WORDS = { public = "Public battle", standalone = "Public battle", private = "Private battle", solo = "Practice", tutorial = "Tutorial" }

local function timeAgo(t: any): string
	local age = os.time() - (tonumber(t) or os.time())
	if age < 60 then
		return "Just now"
	elseif age < 3600 then
		return age // 60 .. " min ago"
	elseif age < 86400 then
		local h = age // 3600
		return h .. (if h == 1 then " hour ago" else " hours ago")
	end
	local d = age // 86400
	return d .. (if d == 1 then " day ago" else " days ago")
end

local function length(secs: any): string?
	local s = math.floor(tonumber(secs) or 0)
	if s <= 0 then
		return nil
	elseif s < 60 then
		return s .. " s"
	end
	return s // 60 .. " min"
end

local function colourOf(profile: any): Color3?
	local c = profile and MetaConfig.color(profile.color)
	if c and type(c.rgb) == "table" then
		return Color3.fromRGB(c.rgb[1], c.rgb[2], c.rgb[3])
	end
	return nil
end

return {
	title = "Your profile",
	render = function(page, ctx)
		local body = page.body
		local phone = ctx.layout() == "phone"
		local lp = Players.LocalPlayer
		local alive = true
		local conns = {}
		local controller = ctx.nameController and ctx.nameController()

		Kit.list(body, false, 14)
		local main = make("Frame", { Name = "Main", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
		Kit.list(main, not phone, 14)

		-- Left: who you are ----------------------------------------------------------------------

		local idCard = Kit.card({
			Name = "Identity",
			Size = if phone then UDim2.new(1, 0, 0, 0) else UDim2.new(0, 320, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = main,
		})
		Kit.pad(idCard, 18, 18, 22, 20)
		Kit.list(idCard, false, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center })

		local circle = make("Frame", { Name = "Level", BackgroundColor3 = C.RAISED, BorderSizePixel = 0, Size = UDim2.fromOffset(112, 112), LayoutOrder = 1, Parent = idCard })
		Kit.corner(circle)
		Kit.stroke(circle, C.YELLOW, 3)
		local levelWord = Kit.text({ Name = "Word", Text = "Level", FontFace = F.BOLD, TextSize = 13, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18), Parent = circle })
		local levelNum = Kit.text({ Name = "Number", Text = "–", FontFace = F.TITLE, TextSize = 46, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 8), Parent = circle })

		-- Name, with the pencil to change it.
		local nameRow = make("Frame", { Name = "NameRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 2, Parent = idCard })
		Kit.list(nameRow, true, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
		-- Your flag, left of the name (hidden when none is picked).
		local flagImg = make("ImageLabel", {
			Name = "Flag",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(math.floor(20 * FlagKit.ASPECT), 20),
			Visible = false,
			LayoutOrder = 0,
			Parent = nameRow,
		})
		local nameLabel = Kit.text({
			Name = "Name",
			Text = if controller then controller.get() elseif lp then lp.DisplayName else "Player",
			FontFace = F.TITLE,
			TextSize = 24,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 1,
			Parent = nameRow,
		})
		local nameMax = make("UISizeConstraint", { MaxSize = Vector2.new(230, 36), Parent = nameLabel })
		local pencil = Kit.iconButton("Pencil", { name = "EditName", size = 32, layoutOrder = 2, parent = nameRow })

		local editor = make("Frame", { Name = "NameEditor", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Visible = false, Parent = idCard })
		Kit.list(editor, false, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		local box = make("TextBox", {
			Name = "NameBox",
			Text = "",
			PlaceholderText = "Your battle name",
			PlaceholderColor3 = C.MUTED,
			ClearTextOnFocus = false,
			FontFace = F.BOLD,
			TextSize = 18,
			TextColor3 = C.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundColor3 = C.DEEP,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 44),
			SelectionImageObject = Kit.ring,
			LayoutOrder = 1,
			Parent = editor,
		})
		Kit.corner(box, 10)
		Kit.stroke(box)
		Kit.pad(box, 12, 12)
		Kit.text({
			Name = "Hint",
			Text = "Your battle name. 3–20 letters. Changes next battle.",
			FontFace = F.BODY,
			TextSize = 13,
			TextColor3 = C.MUTED,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			Parent = editor,
		})
		local status = Kit.text({
			Name = "Status",
			Text = "",
			FontFace = F.BOLD,
			TextSize = 14,
			TextColor3 = C.PINK,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
			LayoutOrder = 3,
			Parent = editor,
		})
		local buttons = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 4, Parent = editor })
		Kit.list(buttons, true, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		local save = Kit.button("primary", "Save", { name = "SaveName", height = 40, layoutOrder = 1, parent = buttons })
		local cancel = Kit.button("secondary", "Cancel", { name = "CancelName", height = 40, layoutOrder = 2, parent = buttons })
		local reset = Kit.button("ghost", "Use my Roblox name", { name = "ResetName", height = 36, textSize = 14, layoutOrder = 5, parent = editor })

		-- Your title (tap to pick another in My items).
		local titleBtn = make("TextButton", {
			Name = "Title",
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = C.RAISED,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(0, 28),
			AutomaticSize = Enum.AutomaticSize.X,
			Visible = false,
			LayoutOrder = 4,
			SelectionImageObject = Kit.ring,
			Parent = idCard,
		})
		Kit.corner(titleBtn, 14)
		Kit.pad(titleBtn, 10, 6)
		Kit.list(titleBtn, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
		local titleBadge = Art.image(nil, { Name = "Badge", Size = UDim2.fromOffset(26, 26), Visible = false, LayoutOrder = 0, Parent = titleBtn })
		local titleText = Kit.text({ Name = "Text", Text = "", FontFace = F.TITLE, TextSize = 17, TextColor3 = C.YELLOW, LayoutOrder = 1, Parent = titleBtn })
		local titleArrow = Kit.icon("ChevronRight", { Name = "Arrow", Size = UDim2.fromOffset(14, 14), ImageColor3 = C.YELLOW, LayoutOrder = 2, Parent = titleBtn })
		Kit.hover(titleBtn, function(s)
			titleBtn.BackgroundTransparency = if s == "idle" then 1 else 0
		end)
		titleBtn.Activated:Connect(function()
			ctx.open("inventory")
		end)

		local sub = Kit.text({ Name = "Sub", Text = "", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 5, Parent = idCard })
		local function showSub()
			local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
			local tag = pg and pg:GetAttribute("WFClanTag")
			local parts = {}
			if type(tag) == "string" and tag ~= "" then
				parts[#parts + 1] = "[" .. tag .. "]"
			end
			if lp then
				parts[#parts + 1] = "@" .. lp.Name
			end
			sub.Text = table.concat(parts, "  ·  ")
			sub.Visible = sub.Text ~= ""
		end
		showSub()
		local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
		if pg then
			table.insert(conns, pg:GetAttributeChangedSignal("WFClanTag"):Connect(showSub))
		end

		local chips = make("Frame", { Name = "Chips", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 6, Visible = false, Parent = idCard })
		Kit.list(chips, true, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })

		local xpBox = make("Frame", { Name = "Progress", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 7, Visible = false, Parent = idCard })
		Kit.list(xpBox, false, 6)
		local xpBar, setXp = Kit.progress(0, C.CYAN)
		xpBar.LayoutOrder = 1
		xpBar.Parent = xpBox
		local xpText = Kit.text({ Name = "XP", Text = "", FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = xpBox })

		-- Name editing (AccountView commit / Changed).
		local pending = false
		local function setStatus(textValue: string, color: Color3?)
			status.Text = textValue
			status.TextColor3 = color or C.PINK
			status.Visible = textValue ~= ""
		end
		local hasTitle = false
		local function openEditor(on: boolean)
			editor.Visible = on
			nameRow.Visible = not on
			titleBtn.Visible = hasTitle and not on
			if on then
				box.Text = if controller then controller.get() else nameLabel.Text
				setStatus("")
			else
				pending = false
				save:SetAttribute("Disabled", false)
				Kit.setButtonText(save, "Save")
			end
		end
		local function commit(value: string)
			if pending or not controller then
				return
			end
			local ok, result = controller.submit(value)
			if not ok then
				box.Text = controller.get()
				setStatus(tostring(result))
				return
			end
			if result == "pending" then
				pending = true
				save:SetAttribute("Disabled", true)
				Kit.setButtonText(save, "Saving…")
				setStatus("Saving your name…", C.CYAN)
			else
				openEditor(false)
			end
		end
		pencil.Activated:Connect(function()
			if not controller then
				ctx.toast("Your name is still loading. Try again in a moment.", "info")
				return
			end
			openEditor(true)
			box:CaptureFocus()
		end)
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if #box.Text > MAX_NAME then
				box.Text = string.sub(box.Text, 1, MAX_NAME)
			end
		end)
		box.FocusLost:Connect(function(enter)
			if enter then
				commit(box.Text)
			end
		end)
		save.Activated:Connect(function()
			if not save:GetAttribute("Disabled") then
				commit(box.Text)
			end
		end)
		cancel.Activated:Connect(function()
			openEditor(false)
		end)
		reset.Activated:Connect(function()
			commit("")
		end)
		if controller and controller.Changed then
			table.insert(conns, controller.Changed:Connect(function(result)
				if not alive then
					return
				end
				nameLabel.Text = tostring(result.name)
				if not pending then
					return
				end
				pending = false
				save:SetAttribute("Disabled", false)
				Kit.setButtonText(save, "Save")
				if result.ok then
					openEditor(false)
					ctx.toast("Name saved. It shows from your next battle.", "ok")
				else
					box.Text = tostring(result.name)
					setStatus(tostring(result.error or "Couldn't save that name. Try another one."))
				end
			end))
		end

		-- Right: numbers and recent battles ---------------------------------------------------------

		local right = make("Frame", { Name = "Right", BackgroundTransparency = 1, Size = UDim2.new(if phone then 1 else 0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = main })
		if not phone then
			Kit.flex(right)
		end
		Kit.list(right, false, 14)

		local grid = make("Frame", { Name = "Stats", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = right })
		local cols = if phone then 2 else 4
		make("UIGridLayout", {
			CellPadding = UDim2.fromOffset(12, 12),
			CellSize = UDim2.new(1 / cols, -math.ceil(12 * (cols - 1) / cols) - 1, 0, 96),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = grid,
		})
		local tiles = {}
		for i, t in { { "games", "Battles", "PlayBattles", C.CYAN }, { "wins", "Wins", "WinBattle", C.YELLOW }, { "elims", "Eliminations", "BeatPlayers", C.PINK }, { "rate", "Win rate", "Star", C.GREEN } } do
			local tile = Kit.card({ Name = t[2], LayoutOrder = i, Parent = grid })
			Kit.text({ Name = "Label", Text = t[2], FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, Position = UDim2.fromOffset(16, 14), Parent = tile })
			if Art.has(t[3]) then
				Art.image(t[3], { Name = "Icon", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), Size = UDim2.fromOffset(34, 34), Parent = tile })
			else
				Kit.icon(t[3], { Name = "Icon", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 12), Size = UDim2.fromOffset(20, 20), ImageColor3 = t[4], Parent = tile })
			end
			tiles[t[1]] = Kit.text({ Name = "Value", Text = "–", FontFace = F.TITLE, TextSize = 34, Position = UDim2.fromOffset(16, 40), Parent = tile })
		end

		local histHead = make("Frame", { Name = "RecentHead", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 2, Parent = right })
		Kit.text({ Name = "Title", Text = "Recent battles", FontFace = F.TITLE, TextSize = 20, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Parent = histHead })
		local holder = make("Frame", { Name = "Recent", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = right })
		Kit.list(holder, false, 8)

		-- Fill from the profile (and again whenever it changes).
		local function fill(profile: any)
			if not alive then
				return
			end
			if type(profile) ~= "table" then
				return
			end
			local colour = colourOf(profile)
			circle.BackgroundColor3 = colour or C.RAISED
			local light = colour and (colour.R * 0.299 + colour.G * 0.587 + colour.B * 0.114) > 0.62
			levelNum.TextColor3 = if light then C.BG else C.TEXT
			levelWord.TextColor3 = if light then C.BG else C.TEXT
			levelNum.Text = tostring(profile.level or 1)
			local hasFlag = FlagKit.set(flagImg, if type(profile.flag) == "string" then profile.flag else nil)
			nameMax.MaxSize = Vector2.new(if hasFlag then 190 else 230, 36)
			local titleName = type(profile.title) == "string" and TITLES[profile.title]
			local ownsAny = type(profile.titles) == "table" and #profile.titles > 0
			local badgeArt = titleName and Art.title(profile.title)
			Art.set(titleBadge, badgeArt or nil)
			titleBadge.Visible = badgeArt ~= nil
			if titleName then
				titleText.Text = titleName
				titleText.FontFace = F.TITLE
				titleText.TextColor3 = C.YELLOW
				titleArrow.ImageColor3 = C.YELLOW
			elseif ownsAny then
				titleText.Text = "Pick a title"
				titleText.FontFace = F.BOLD
				titleText.TextColor3 = C.MUTED
				titleArrow.ImageColor3 = C.MUTED
			end
			hasTitle = if titleName then true else ownsAny
			titleBtn.Visible = hasTitle and not editor.Visible
			local into, need = tonumber(profile.xpInto), tonumber(profile.xpNeed)
			if into and need and need > 0 then
				xpBox.Visible = true
				setXp(into / need)
				xpText.Text = short(into) .. " / " .. short(need) .. " XP to level " .. ((tonumber(profile.level) or 1) + 1)
			end
			local games, wins = tonumber(profile.games) or 0, tonumber(profile.wins) or 0
			tiles.games.Text = short(games)
			tiles.wins.Text = short(wins)
			tiles.elims.Text = short(profile.eliminations)
			tiles.rate.Text = if games > 0 then string.format("%.0f%%", wins / games * 100) else "–"
			for _, c in chips:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			local any = false
			if profile.vip then
				any = true
				Kit.chip("VIP", { name = "VIP", icon = "Star", color = C.YELLOW, textColor = C.YELLOW_TEXT, iconColor = C.YELLOW_TEXT, stroke = false, layoutOrder = 1, parent = chips })
			end
			local streak = tonumber(profile.streak) or 0
			if streak > 0 then
				any = true
				Kit.chip(streak .. "-day streak", { name = "Streak", icon = "Flame", iconColor = C.PINK, layoutOrder = 2, parent = chips })
			end
			chips.Visible = any
		end
		fill(ctx.profile())
		ctx.onProfile(fill)

		-- Recent battles (MetaFn "history", newest last).
		local gen = 0
		local function clearHolder()
			for _, c in holder:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
		end
		local function message(textValue: string, retry: (() -> ())?)
			clearHolder()
			local card = Kit.card({ Name = "Message", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = holder })
			Kit.pad(card, 18, 18, 22, 22)
			Kit.list(card, false, 12, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
			Kit.text({ Name = "Text", Text = textValue, FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
			if retry then
				Kit.button("secondary", "Try again", { icon = "Refresh", height = 40, layoutOrder = 2, parent = card, onActivated = retry })
			end
		end
		local function battleRow(g: any, order: number)
			local row = make("TextButton", {
				Name = "Battle" .. order,
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = C.CARD,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 64),
				LayoutOrder = order,
				SelectionImageObject = Kit.ring,
				Parent = holder,
			})
			Kit.corner(row, 12)
			Kit.stroke(row)
			Kit.hover(row, function(s)
				row.BackgroundColor3 = if s == "idle" then C.CARD else C.RAISED
			end)
			local place = tonumber(g.place)
			local word, color
			if g.won == true then
				word, color = "Won", C.GREEN
			elseif place and g.left ~= true then
				word, color = "#" .. place, C.MUTED
			else
				word, color = "Lost", C.PINK
			end
			Kit.text({ Name = "Result", Text = word, FontFace = F.TITLE, TextSize = 22, TextColor3 = color, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(16, 0), Size = UDim2.new(0, 64, 1, 0), Parent = row })
			Kit.text({
				Name = "Title",
				Text = tostring(g.map or "Battle") .. "  ·  " .. plainMode(g.mode),
				FontFace = F.BOLD,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Position = UDim2.fromOffset(88, 12),
				Size = UDim2.new(1, -180, 0, 20),
				Parent = row,
			})
			local parts = { timeAgo(g.t) }
			if KIND_WORDS[g.kind] then
				parts[#parts + 1] = KIND_WORDS[g.kind]
			end
			if tonumber(g.players) then
				parts[#parts + 1] = short(g.players) .. (if tonumber(g.players) == 1 then " player" else " players")
			end
			parts[#parts + 1] = length(g.secs)
			Kit.text({
				Name = "Sub",
				Text = table.concat(parts, "  ·  "),
				FontFace = F.BODY,
				TextSize = 13,
				TextColor3 = C.MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Position = UDim2.fromOffset(88, 34),
				Size = UDim2.new(1, -180, 0, 18),
				Parent = row,
			})
			Kit.text({
				Name = "Stats",
				Text = "Stats ›",
				FontFace = F.BOLD,
				TextSize = 15,
				TextColor3 = C.CYAN,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -16, 0.5, 0),
				Size = UDim2.fromOffset(76, 20),
				Parent = row,
			})
			row.Activated:Connect(function()
				local ok, GameStatsView = pcall(function()
					return require(script.Parent.Parent.Parent:WaitForChild("GameStatsView")) :: any
				end)
				if ok and GameStatsView then
					GameStatsView.open(ctx.gui, g.stats, g)
				else
					ctx.toast("Couldn't open the battle stats.", "error")
				end
			end)
		end
		local loadHistory
		loadHistory = function()
			gen += 1
			local my = gen
			message("Loading your battles…")
			task.spawn(function()
				local ok, list = ctx.meta("history")
				if not alive or my ~= gen then
					return
				end
				if not ok or type(list) ~= "table" then
					message("Couldn't load your battles. Try again in a moment.", loadHistory)
					return
				end
				if #list == 0 then
					message("Play a battle and it will show up here.")
					return
				end
				clearHolder()
				for i = #list, 1, -1 do
					if type(list[i]) == "table" then
						battleRow(list[i], #list - i + 1)
					end
				end
			end)
		end
		loadHistory()

		return function()
			alive = false
			for _, c in conns do
				c:Disconnect()
			end
		end
	end,
}
