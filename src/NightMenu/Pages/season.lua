-- War Front Night menu: Season pass. Copyright (C) 2026 Liam (lacedsc3ne).
-- Data from Progression's MetaFn ops "season" (Quests.seasonView) and "claimSeason" (Quests.claimSeason:
-- free row for everyone, gold row needs the Gold pass). The Gold pass is bought with the same
-- MarketplaceService:PromptGamePassPurchase as the other passes (profile.goldPassId, 0 = not on sale).

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local Art = require(script.Parent.Parent:WaitForChild("Art"))
local MetaConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MetaConfig"))

-- Developer product of a boost / Extra revive reward, for its picture (Art.product).
local function productOf(key: string?): number?
	if key == "revive" then
		return MetaConfig.REVIVE and MetaConfig.REVIVE.id
	end
	local b = key and MetaConfig.boost(key)
	return b and b.id
end

local C, F = Kit.C, Kit.F
local make = Kit.make
local AUTO_Y = Enum.AutomaticSize.Y
local CENTER = Enum.HorizontalAlignment.Center
local MIDDLE = Enum.VerticalAlignment.Center
local GOLD_DARK = C.YELLOW:Lerp(C.CARD, 0.84)

local CELL_H, GAP, LEVEL_H = 64, 8, 26

-- Boost rewards: icon, short name for the track cell, full name for the toast.
local BOOSTS = {
	goldCrate = { icon = "Coins", short = "Gold crate", name = "Gold crate", color = C.YELLOW },
	reinforcements = { icon = "Users", short = "Troops", name = "Reinforcements", color = C.CYAN },
	shield = { icon = "Shield", short = "Shield", name = "Shield", color = C.GREEN },
	revive = { icon = "Heart", short = "Revive", name = "Extra revive", color = C.PURPLE },
	nukeVoucher = { icon = "Rocket", short = "Free nuke", name = "Free nuke", color = C.PINK },
}

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

local function endsText(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d, h = sec // 86400, sec // 3600
	if sec <= 0 then
		return "Season over"
	elseif d >= 2 then
		return "Ends in " .. d .. " days"
	elseif d == 1 then
		return "Ends in 1 day"
	elseif h >= 2 then
		return "Ends in " .. h .. " hours"
	elseif h == 1 then
		return "Ends in 1 hour"
	end
	return "Ends in " .. math.max(1, sec // 60) .. " min"
end

-- { icon, color, short (track cell), toast } for a reward table.
local function rewardLook(r: any, titles: any): any
	if type(r) ~= "table" then
		return { icon = "Gift", color = C.MUTED, short = "", toast = "Reward collected" }
	end
	if r.medals then
		return { icon = "Medal", art = "Medal", color = C.YELLOW, short = numberText(r.medals), toast = "+" .. numberText(r.medals) .. " medals" }
	elseif r.boost then
		local b = BOOSTS[r.boost] or { icon = "Bolt", short = tostring(r.boost), name = tostring(r.boost), color = C.CYAN }
		local n = math.max(1, math.floor(tonumber(r.count) or 1))
		return { icon = b.icon, color = b.color, product = productOf(r.boost), short = (if n > 1 then n .. "x " else "") .. b.short, toast = "+" .. n .. " " .. b.name }
	elseif r.title then
		local name = if type(titles) == "table" and titles[r.title] then tostring(titles[r.title]) else tostring(r.title)
		return { icon = "Star", art = Art.title(r.title), color = C.PURPLE, short = name, toast = "New title: " .. name }
	elseif r.revive then
		local n = math.max(1, math.floor(tonumber(r.revive) or 1))
		return { icon = "Heart", color = C.PURPLE, product = productOf("revive"), short = (if n > 1 then n .. "x " else "") .. "Revive", toast = "+" .. n .. " Extra revive" }
	end
	return { icon = "Gift", color = C.MUTED, short = "", toast = "Reward collected" }
end

local function wrapText(parent: Instance, order: number, text: string, size: number, color: Color3?, font: Font?, align: Enum.TextXAlignment?): TextLabel
	return Kit.text({
		Text = text,
		TextSize = size,
		TextColor3 = color or C.TEXT,
		FontFace = font or F.BODY,
		TextWrapped = true,
		TextXAlignment = align or Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = AUTO_Y,
		LayoutOrder = order,
		Parent = parent,
	})
end

local function column(parent: Instance, order: number, gap: number?): Frame
	local f = make("Frame", { Name = "Column", BackgroundTransparency = 1, Size = UDim2.new(), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = parent })
	Kit.flex(f)
	Kit.list(f, false, gap or 2)
	return f
end

-- Small round badge in a cell's top-right corner (Check when collected, Lock when locked).
local function badge(parent: Instance, icon: string, bg: Color3, fg: Color3)
	local b = make("Frame", { Name = "Badge", BackgroundColor3 = bg, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -3, 0, 3), Size = UDim2.fromOffset(16, 16), ZIndex = 3, Parent = parent })
	Kit.corner(b)
	Kit.icon(icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(11, 11), ImageColor3 = fg, ZIndex = 3, Parent = b })
end

return {
	title = "Season pass",
	headerRight = function()
		-- Filled in by render (headerRight gets no ctx).
		local f = make("Frame", { Name = "SeasonEnds", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, Visible = false })
		Kit.list(f, true, 6, { VerticalAlignment = MIDDLE })
		Kit.icon("Clock", { Size = UDim2.fromOffset(16, 16), ImageColor3 = C.MUTED, LayoutOrder = 1, Parent = f })
		Kit.text({ Name = "Label", Text = "", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = f })
		return f
	end,
	render = function(page, ctx)
		local body = page.body
		local phone = ctx.layout() == "phone"
		local COL_W = if phone then 70 else 76
		local LABEL_W = if phone then 50 else 76
		local alive = true
		Kit.list(body, false, 14)
		local content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = body })
		Kit.list(content, false, 14)

		local endsFrame = page.header:FindFirstChild("SeasonEnds")
		local endsLabel = endsFrame and endsFrame:FindFirstChild("Label")

		local data: any = nil
		local fetchedAt = 0
		local failed, errorText = false, nil
		local loading, again = false, false
		local busy = false
		local track: ScrollingFrame? = nil
		local trackX: number? = nil -- keeps the track where it was across refreshes
		local load: () -> ()

		local function tick()
			if endsFrame and endsLabel then
				endsFrame.Visible = data ~= nil
				if data then
					endsLabel.Text = endsText((tonumber(data.endsIn) or 0) - (os.clock() - fetchedAt))
				end
			end
		end

		local function trackWidth(levels: number): number
			return levels * COL_W + math.max(0, levels - 1) * GAP + 6
		end

		-- Scroll so `level`'s column is in the middle of the track.
		local function scrollTo(level: number, animate: boolean)
			local sf = track
			if not sf or not data then
				return
			end
			local view = sf.AbsoluteWindowSize.X
			local maxX = math.max(0, trackWidth(tonumber(data.levels) or #data.rows) - view)
			local x = math.clamp(3 + (level - 1) * (COL_W + GAP) - (view - COL_W) / 2, 0, maxX)
			if animate then
				TweenService:Create(sf, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { CanvasPosition = Vector2.new(x, 0) }):Play()
			else
				sf.CanvasPosition = Vector2.new(x, 0)
			end
		end

		local function claim(level: number, trackName: string)
			if busy then
				return
			end
			busy = true
			task.spawn(function()
				local ok, res = ctx.meta("claimSeason", { level = level, track = trackName })
				busy = false
				if ok and type(res) == "table" then
					ctx.toast(rewardLook(res, data and data.titles).toast, "ok")
				else
					ctx.toast(if type(res) == "string" and res ~= "" then res else "Something went wrong, try again", "error")
				end
				load()
			end)
		end

		-- One reward cell. state: "claimed" | "ready" | "locked" (level too high) | "gold" (needs the pass)
		local function cell(parent: Instance, order: number, row: any, trackName: string)
			local level = tonumber(row.level) or 0
			local claimed = if trackName == "free" then row.freeClaimed == true else row.goldClaimed == true
			local state = if claimed then "claimed"
				elseif trackName == "gold" and not data.gold then "gold"
				elseif level <= (tonumber(data.level) or 0) then "ready"
				else "locked"
			local look = rewardLook(row[trackName], data.titles)
			local dim = state == "locked" or state == "gold"
			local bg = if state == "gold" then GOLD_DARK else C.CARD
			local b = make("TextButton", {
				Name = trackName .. "_" .. level,
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = bg,
				BorderSizePixel = 0,
				Size = UDim2.fromOffset(COL_W, CELL_H),
				LayoutOrder = order,
				SelectionImageObject = Kit.ring,
				Parent = parent,
			})
			b:SetAttribute("State", state)
			Kit.corner(b, 12)
			Kit.stroke(b, if state == "claimed" then C.GREEN elseif state == "ready" then C.YELLOW elseif state == "gold" then C.YELLOW_EDGE:Lerp(C.CARD, 0.4) else C.LINE, if state == "claimed" or state == "ready" then 2 else 1.5)
			if look.art then
				Art.image(look.art, {
					Name = "Icon",
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.new(0.5, 0, 0, 7),
					Size = UDim2.fromOffset(24, 24),
					ImageTransparency = if dim then 0.5 else 0,
					Parent = b,
				})
			else
				local line = Kit.icon(look.icon, {
					Name = "Icon",
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.new(0.5, 0, 0, 9),
					Size = UDim2.fromOffset(20, 20),
					ImageColor3 = look.color,
					ImageTransparency = if dim then 0.5 else 0,
					Parent = b,
				})
				if look.product then
					-- Boosts / Extra revive: their own picture (as in the Shop) once it loads.
					local pic = Art.product(look.product, {
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.new(0.5, 0, 0, 5),
						Size = UDim2.fromOffset(28, 28),
						ImageTransparency = if dim then 0.5 else 0,
						Parent = b,
					}, function()
						line.Visible = false
					end)
					Kit.corner(pic, 7)
				end
			end
			Kit.text({
				Name = "Label",
				Text = look.short,
				FontFace = F.TITLE,
				TextSize = 13,
				TextColor3 = if dim then C.MUTED else C.TEXT,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(4, 34),
				Size = UDim2.new(1, -8, 0, 28),
				Parent = b,
			})
			if state == "claimed" then
				badge(b, "Check", C.GREEN, C.GREEN_TEXT)
			elseif dim then
				badge(b, "Lock", C.DEEP, if state == "gold" then C.YELLOW else C.MUTED)
			end
			Kit.hover(b, function(s)
				b.BackgroundColor3 = if s == "idle" or state ~= "ready" then bg else bg:Lerp(C.WHITE, 0.08)
			end)
			b.Activated:Connect(function()
				if state == "ready" then
					claim(level, trackName)
				elseif state == "gold" then
					ctx.toast("This reward needs the Gold pass", "info")
				elseif state == "locked" then
					ctx.toast("Reach season level " .. level .. " first", "info")
				end
			end)
		end

		local function levelCard(order: number)
			local level = tonumber(data.level) or 0
			local levels = tonumber(data.levels) or #data.rows
			local into, need = tonumber(data.xpInto) or 0, math.max(1, tonumber(data.xpNeed) or 1)
			local maxed = level >= levels
			local card = Kit.card({ Name = "SeasonLevel", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = content })
			Kit.pad(card, 16, 16, 14, 14)
			Kit.list(card, true, 14, { VerticalAlignment = MIDDLE })
			local circle = make("Frame", { Name = "Level", BackgroundColor3 = C.CYAN, BorderSizePixel = 0, Size = UDim2.fromOffset(52, 52), LayoutOrder = 1, Parent = card })
			Kit.corner(circle)
			Kit.text({ Text = tostring(level), FontFace = F.TITLE, TextSize = 24, TextColor3 = C.BG, Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.None, Parent = circle })
			local col = column(card, 2, 6)
			if type(data.name) == "string" then
				Kit.text({ Name = "SeasonName", Text = data.name, FontFace = F.TITLE, TextSize = 14, TextColor3 = C.CYAN, LayoutOrder = 1, Parent = col })
			end
			wrapText(col, 2, if maxed then "Level " .. level .. " · top level reached" else "Level " .. level .. " · " .. numberText(into) .. " / " .. numberText(need) .. " XP to level " .. (level + 1), 16, C.TEXT, F.BOLD)
			local bar = Kit.progress(if maxed then 1 else into / need, C.CYAN)
			bar.LayoutOrder = 3
			bar.Parent = col
			wrapText(col, 4, "Earn season XP by playing battles and finishing missions", 14, C.MUTED)
		end

		local function trackCard(order: number)
			local level = tonumber(data.level) or 0
			local levels = tonumber(data.levels) or #data.rows
			local colH = LEVEL_H + GAP + CELL_H + GAP + CELL_H
			local card = Kit.card({ Name = "Track", Size = UDim2.new(1, 0, 0, colH + 6 + 10 + 24), LayoutOrder = order, Parent = content })
			Kit.pad(card, if phone then 10 else 14, if phone then 10 else 14, 12, 12)
			Kit.list(card, true, if phone then 6 else 10)
			local labels = make("Frame", { Name = "Labels", BackgroundTransparency = 1, Size = UDim2.new(0, LABEL_W, 1, 0), LayoutOrder = 1, Parent = card })
			for i, t in { { "Free", C.TEXT }, { "Gold pass", C.YELLOW } } do
				Kit.text({
					Text = t[1],
					FontFace = F.TITLE,
					TextSize = if phone then 14 else 15,
					TextColor3 = t[2],
					TextWrapped = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					Position = UDim2.fromOffset(0, 3 + LEVEL_H + GAP + (i - 1) * (CELL_H + GAP)),
					Size = UDim2.new(1, 0, 0, CELL_H),
					AutomaticSize = Enum.AutomaticSize.None,
					Parent = labels,
				})
			end
			local sf = make("ScrollingFrame", {
				Name = "Levels",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(0, 1),
				CanvasSize = UDim2.fromOffset(trackWidth(levels), 0),
				ScrollingDirection = Enum.ScrollingDirection.X,
				HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = C.LINE,
				Selectable = false,
				LayoutOrder = 2,
				Parent = card,
			})
			Kit.flex(sf)
			Kit.pad(sf, 3, 3, 3, 3)
			Kit.list(sf, true, GAP)
			track = sf
			local nextLevel = if level < levels then level + 1 else -1
			for _, row in data.rows do
				local l = tonumber(row.level) or 0
				local col = make("Frame", { Name = "Level_" .. l, BackgroundTransparency = 1, Size = UDim2.fromOffset(COL_W, colH), LayoutOrder = l, Parent = sf })
				Kit.list(col, false, GAP)
				local isNext = l == nextLevel
				local head = make("Frame", { Name = "Head", BackgroundColor3 = C.CYAN, BackgroundTransparency = if isNext then 0 else 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, LEVEL_H), LayoutOrder = 1, Parent = col })
				Kit.corner(head)
				Kit.text({
					Text = tostring(l),
					FontFace = F.TITLE,
					TextSize = 15,
					TextColor3 = if isNext then C.BG elseif l <= level then C.TEXT else C.MUTED,
					Size = UDim2.fromScale(1, 1),
					AutomaticSize = Enum.AutomaticSize.None,
					Parent = head,
				})
				cell(col, 2, row, "free")
				cell(col, 3, row, "gold")
			end
			local function place()
				if trackX then
					sf.CanvasPosition = Vector2.new(trackX, 0)
				else
					scrollTo(math.clamp(level + 1, 1, levels), false)
				end
			end
			if sf.AbsoluteWindowSize.X > 0 then
				place()
			else
				sf:GetPropertyChangedSignal("AbsoluteWindowSize"):Once(place)
			end
			sf:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
				if track == sf then
					trackX = sf.CanvasPosition.X
				end
			end)
		end

		local function shortcuts(order: number)
			local levels = tonumber(data.levels) or #data.rows
			local row = make("Frame", { Name = "Shortcuts", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = order, Parent = content })
			Kit.list(row, true, 8, { VerticalAlignment = MIDDLE })
			Kit.button("secondary", "Level 1", { name = "First", icon = "ChevronLeft", height = 36, textSize = 15, padX = 14, layoutOrder = 1, parent = row, onActivated = function()
				scrollTo(1, true)
			end })
			Kit.button("secondary", "Level " .. levels, { name = "Last", icon = "ChevronRight", height = 36, textSize = 15, padX = 14, layoutOrder = 2, parent = row, onActivated = function()
				scrollTo(levels, true)
			end })
		end

		local function goldCard(order: number)
			local p = ctx.profile()
			if data.gold then
				local line = make("Frame", { Name = "GoldOwned", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = order, Parent = content })
				Kit.list(line, true, 6, { VerticalAlignment = MIDDLE })
				Kit.icon("CheckCircle", { Size = UDim2.fromOffset(18, 18), ImageColor3 = C.GREEN, LayoutOrder = 1, Parent = line })
				Kit.text({ Text = "You have the Gold pass: collect the gold reward on every level you reach", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.GREEN, LayoutOrder = 2, Parent = line })
				return
			end
			if not p then
				return
			end
			local passId = tonumber(p.goldPassId) or 0
			local card = Kit.card({ Name = "GoldPass", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order, Parent = content })
			Kit.pad(card, 16, 16, 14, 14)
			Kit.list(card, not phone or passId == 0, 12, { VerticalAlignment = MIDDLE })
			local head = make("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(if phone and passId ~= 0 then 1 else 0, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = card })
			if not phone or passId == 0 then
				Kit.flex(head)
			end
			Kit.list(head, true, 12, { VerticalAlignment = MIDDLE })
			local sq = make("Frame", { Name = "Crown", BackgroundColor3 = C.YELLOW, BackgroundTransparency = if passId == 0 then 0.9 else 0.8, BorderSizePixel = 0, Size = UDim2.fromOffset(44, 44), LayoutOrder = 1, Parent = head })
			Kit.corner(sq, 12)
			Kit.icon("Crown", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.58, 0.58), ImageColor3 = if passId == 0 then C.MUTED else C.YELLOW, Parent = sq })
			local col = column(head, 2, 2)
			if passId == 0 then
				Kit.text({ Text = "Gold pass coming soon", FontFace = F.TITLE, TextSize = 18, TextColor3 = C.MUTED, LayoutOrder = 1, Parent = col })
				wrapText(col, 2, "An extra reward on every level, with its own titles.", 14, C.MUTED)
			else
				Kit.text({ Text = "Gold pass", FontFace = F.TITLE, TextSize = 18, TextColor3 = C.YELLOW, LayoutOrder = 1, Parent = col })
				wrapText(col, 2, "An extra reward on every level, with its own titles. Rewards you already reached are yours right away.", 14, C.MUTED)
				Kit.button("robux", "Get Gold pass", { name = "GetGoldPass", icon = "Crown", height = 44, textSize = 17, size = if phone then UDim2.new(1, 0, 0, 44) else nil, layoutOrder = 2, parent = card, onActivated = function()
					MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, passId)
				end })
			end
		end

		local function errorCard()
			local card = Kit.card({ Name = "Error", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = content })
			Kit.pad(card, 18, 18, 18, 18)
			Kit.list(card, false, 10, { HorizontalAlignment = CENTER })
			Kit.icon("AlertCircle", { Size = UDim2.fromOffset(30, 30), ImageColor3 = C.PINK, LayoutOrder = 1, Parent = card })
			Kit.text({ Text = "Couldn't load the season pass", FontFace = F.TITLE, TextSize = 18, LayoutOrder = 2, Parent = card })
			if errorText then
				wrapText(card, 3, errorText, 14, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
			end
			Kit.button("secondary", "Try again", { name = "TryAgain", icon = "Refresh", height = 40, textSize = 16, layoutOrder = 4, parent = card, onActivated = function()
				failed = false
				load()
			end })
		end

		local function draw()
			if not alive or not content.Parent then
				return
			end
			local y = body.CanvasPosition
			track = nil
			for _, ch in content:GetChildren() do
				if not ch:IsA("UIListLayout") then
					ch:Destroy()
				end
			end
			if data and type(data.rows) == "table" then
				levelCard(1)
				trackCard(2)
				shortcuts(3)
				goldCard(4)
			elseif failed then
				errorCard()
			else
				wrapText(content, 1, "Loading the season pass...", 15, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
			end
			body.CanvasPosition = y
			tick()
		end

		-- Fetch the season; calls that arrive while one is running are folded into one more fetch.
		load = function()
			if not alive then
				return
			end
			if loading then
				again = true
				return
			end
			loading = true
			if not data then
				draw()
			end
			task.spawn(function()
				repeat
					again = false
					local ok, res = ctx.meta("season")
					if not alive then
						return
					end
					if ok and type(res) == "table" and type(res.rows) == "table" then
						data, fetchedAt, failed, errorText = res, os.clock(), false, nil
					elseif not data then
						failed, errorText = true, if type(res) == "string" then res else nil
					end
					draw()
				until not again
				loading = false
			end)
		end

		ctx.onProfile(function()
			load() -- season XP changes after battles, missions and claims; Gold pass after buying it
		end)
		load()
		task.spawn(function()
			while alive do
				task.wait(30)
				if alive then
					tick()
				end
			end
		end)

		return function()
			alive = false
		end
	end,
}
