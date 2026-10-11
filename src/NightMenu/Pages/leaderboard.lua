-- War Front Night menu: Rankings. Copyright (C) 2026 Liam (lacedsc3ne).
-- Same data as the old page:
--   MenuPages.renderLeaderboardTab: MetaFn "leaderboard" "wins" -> { board, list, you }
--     list = top 100 { u = userId, n = name, v = wins, g = battles, w = wins } (Progression lbRead),
--     you = { rank?, v = your wins, g = your battles }
--   MetaFn "leaderboard" "week" -> same shape, board "week:<n>", v = wins this week, you.resetIn = seconds
--     (g in the weekly list is all-time battles, so the weekly table shows wins only)
--   ClanPages.renderBoard: ClanFn "list" "" -> up to 100 clans { t = tag, n = name, w, g, m }, most wins first
-- The 1 vs 1 board (rank points) stays hidden until ranked comes out.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local LB_SIZE = 100 -- Progression LB_SIZE
local SILVER = Color3.fromRGB(200, 211, 232)
local BRONZE = Color3.fromRGB(222, 146, 98)
local MEDAL = { C.YELLOW, SILVER, BRONZE }

local function short(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local function esc(s: any): string
	local t = tostring(s or "?")
	t = string.gsub(t, "&", "&amp;")
	t = string.gsub(t, "<", "&lt;")
	t = string.gsub(t, ">", "&gt;")
	return t
end

local function plural(n: number, word: string): string
	return short(n) .. " " .. word .. (if n == 1 then "" else "s")
end

-- "3d 4h", "5h 12m", "8m"
local function untilText(secs: any): string?
	local s = tonumber(secs)
	if not s or s ~= s then
		return nil
	end
	s = math.max(0, math.floor(s))
	local d, h, m = s // 86400, (s % 86400) // 3600, (s % 3600) // 60
	if d > 0 then
		return d .. "d " .. h .. "h"
	elseif h > 0 then
		return h .. "h " .. m .. "m"
	end
	return math.max(1, m) .. "m"
end

-- ClanPages call(): retries while the server is still busy with another request of ours.
local function clanCall(op: string, arg: any?): (boolean, any)
	local shared = ReplicatedStorage:WaitForChild("Shared", 10)
	local fn = shared and shared:WaitForChild("ClanFn", 10)
	if not fn then
		return false, "Couldn't reach the server, try again."
	end
	for attempt = 1, 4 do
		local ok, success, result = pcall(function()
			return (fn :: RemoteFunction):InvokeServer(op, arg)
		end)
		if not ok then
			return false, "Couldn't reach the server, try again."
		end
		if success ~= true and result == "One moment..." and attempt < 4 then
			task.wait(0.4)
		else
			return success == true, result
		end
	end
	return false, "One moment..."
end

local thumbs: { [number]: string } = {}
local function thumb(img: ImageLabel, placeholder: GuiObject, uid: any)
	local id = tonumber(uid)
	if not id or id <= 0 then
		return
	end
	if thumbs[id] then
		img.Image = thumbs[id]
		placeholder.Visible = false
		return
	end
	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(id, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and type(url) == "string" then
			thumbs[id] = url
			if img.Parent then
				img.Image = url
				placeholder.Visible = false
			end
		end
	end)
end

-- The friendly goal line under your row, only when the board data makes it exact.
local function goalLine(list: { any }, you: any): string?
	local v = tonumber(you.v)
	local rank = tonumber(you.rank)
	local function need(target: number): number?
		local e = list[target]
		if not e or v == nil then
			return nil
		end
		local n = (tonumber(e.v) or 0) - v + 1
		return if n > 0 then n else nil
	end
	local function line(n: number?, goal: string): string?
		return if n then "Win " .. plural(n, "more battle") .. " to " .. goal .. "!" else nil
	end
	if rank then
		if rank == 1 then
			return "You're number 1! Keep winning to stay on top."
		elseif rank > 50 then
			return line(need(50), "reach the top 50")
		elseif rank > 10 then
			return line(need(10), "reach the top 10")
		elseif rank > 3 then
			return line(need(3), "reach the top 3")
		end
		return line(need(rank - 1), "take #" .. (rank - 1))
	end
	if #list >= LB_SIZE then
		return line(need(LB_SIZE), "reach the top 100")
	end
	return "Win a battle to get on the board."
end

local M = {}
M.title = "Rankings"
M.clanCall = clanCall -- tests swap this for a fake

function M.render(page, ctx)
	local body = page.body
	local phone = ctx.layout() == "phone"
	local lp = Players.LocalPlayer
	local myId = if lp then lp.UserId else 0
	local alive = true
	local gen = 0
	local pinned = false
	local conns = {}
	local RIGHT_W = if phone then 62 else 86

	Kit.list(body, false, 14)
	local top = make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 1, Parent = body })
	Kit.list(top, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = body })

	local function clear()
		for _, c in content:GetChildren() do
			c:Destroy()
		end
	end

	-- AbsoluteSize is in screen pixels; the page is drawn under Home's UIScale.
	local function uiScale(): number
		local o = body.Parent
		while o do
			local s = o:FindFirstChildOfClass("UIScale")
			if s then
				return s.Scale
			end
			o = o.Parent
		end
		return 1
	end

	local function fitContent()
		if pinned then
			local h = body.AbsoluteSize.Y / uiScale() - 12 - 16 - 36 - 14
			content.Size = UDim2.new(1, 0, 0, math.max(380, h))
		end
	end
	table.insert(conns, body:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitContent))

	local function flow()
		pinned = false
		content.AutomaticSize = Enum.AutomaticSize.Y
		content.Size = UDim2.new(1, 0, 0, 0)
	end

	local function message(textValue: string, retry: (() -> ())?)
		clear()
		flow()
		local card = Kit.card({ Name = "Message", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = content })
		Kit.pad(card, 20, 20, 28, 28)
		Kit.list(card, false, 14, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
		Kit.text({
			Name = "Text",
			Text = textValue,
			FontFace = F.BOLD,
			TextSize = 16,
			TextColor3 = C.MUTED,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = card,
		})
		if retry then
			Kit.button("secondary", "Try again", { icon = "Refresh", height = 40, layoutOrder = 2, parent = card, onActivated = retry })
		end
		return card
	end

	-- One row of the table: rank, name (rich text), then right-aligned columns.
	local function cells(r: GuiObject, rank: string, rankColor: Color3?, nameRich: string, right: { string }, header: boolean?, colW: number?)
		local n = #right
		local W = colW or RIGHT_W
		Kit.text({
			Name = "Rank",
			Text = rank,
			FontFace = if header then F.BOLD else F.TITLE,
			TextSize = if header then 13 else 18,
			TextColor3 = if header then C.MUTED else (rankColor or C.MUTED),
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(14, 0),
			Size = UDim2.new(0, 46, 1, 0),
			Parent = r,
		})
		Kit.text({
			Name = "Name",
			Text = nameRich,
			RichText = true,
			FontFace = F.BOLD,
			TextSize = if header then 13 else 16,
			TextColor3 = if header then C.MUTED else C.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(62, 0),
			Size = UDim2.new(1, -(62 + n * W + 14), 1, 0),
			Parent = r,
		})
		for i, v in right do
			Kit.text({
				Name = "Col" .. i,
				Text = v,
				FontFace = if header then F.BOLD elseif i == 1 then F.TITLE else F.BOLD,
				TextSize = if header then 13 elseif i == 1 then 18 else 15,
				TextColor3 = if header or i > 1 then C.MUTED else C.TEXT,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -14 - (n - i) * W, 0, 0),
				Size = UDim2.new(0, W - 8, 1, 0),
				Parent = r,
			})
		end
	end

	local function header(parent: Instance, order: number, nameCol: string, right: { string }, colW: number?)
		local h = make("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = order, Parent = parent })
		cells(h, "#", nil, nameCol, right, true, colW)
		return h
	end

	local function rowCard(parent: Instance, order: number, mine: boolean?): Frame
		local r = Kit.card({ Name = "Row" .. order, Size = UDim2.new(1, 0, 0, 48), LayoutOrder = order, Parent = parent })
		if mine then
			local s = r:FindFirstChildOfClass("UIStroke")
			if s then
				s.Color = C.YELLOW
				s.Thickness = 2
			end
		end
		return r
	end

	local function podium(parent: Instance, list: { any }): Frame
		local card = Kit.card({ Name = "Podium", LayoutOrder = 1, Parent = parent })
		Kit.pad(card, 14, 14, 16, 14)
		local row = make("Frame", { Name = "Places", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = card })
		Kit.list(row, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalFlex = Enum.UIFlexAlignment.Fill })
		local blockH = { 0.42, 0.3, 0.21 } -- share of the podium height, so tall screens get tall blocks
		for i, place in { 2, 1, 3 } do
			local e = list[place]
			local col = make("Frame", { Name = "Place" .. place, BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1), LayoutOrder = i, Parent = row })
			Kit.list(col, false, 6, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom })
			if e then
				if place == 1 then
					Kit.icon("Crown", { Name = "Crown", Size = UDim2.fromOffset(30, 30), ImageColor3 = C.YELLOW, LayoutOrder = 1, Parent = col })
				end
				local size = if place == 1 then 78 else 64
				local av = make("ImageLabel", { Name = "Avatar", BackgroundColor3 = C.RAISED, BorderSizePixel = 0, Size = UDim2.fromOffset(size, size), LayoutOrder = 2, Parent = col })
				Kit.corner(av)
				Kit.stroke(av, MEDAL[place], 3)
				local ph = Kit.icon("User", { Name = "Placeholder", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.5, 0.5), ImageColor3 = C.MUTED, Parent = av })
				thumb(av, ph, e.u)
				Kit.text({ Name = "Name", Text = tostring(e.n or "?"), FontFace = F.BOLD, TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 3, Parent = col })
				Kit.text({ Name = "Wins", Text = plural(tonumber(e.v) or 0, "win"), FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 4, Parent = col })
			end
			local block = make("Frame", {
				Name = "Block",
				BackgroundColor3 = MEDAL[place],
				BackgroundTransparency = if e then 0 else 0.75,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(1, blockH[place]),
				LayoutOrder = 5,
				Parent = col,
			})
			Kit.corner(block, 10)
			Kit.text({ Name = "Place", Text = tostring(place), FontFace = F.TITLE, TextSize = if place == 1 then 40 else 32, TextColor3 = C.BG, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Parent = block })
		end
		return card
	end

	-- Most wins / This week -------------------------------------------------------------------------

	local function drawWins(data: any, weekly: boolean?)
		local colW = if weekly then (if phone then 110 else 130) else nil
		local list = if type(data.list) == "table" then data.list else {}
		local you = if type(data.you) == "table" then data.you else {}
		clear()
		local listCol, rows
		if phone then
			flow()
			Kit.list(content, false, 14)
			if #list > 0 then
				podium(content, list).Size = UDim2.new(1, 0, 0, 330)
			end
			listCol = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = content })
			rows = make("Frame", { Name = "Rows", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = listCol })
		else
			-- Desktop: the list scrolls by itself so your row stays pinned under it.
			pinned = true
			content.AutomaticSize = Enum.AutomaticSize.None
			fitContent()
			Kit.list(content, true, 14)
			if #list > 0 then
				podium(content, list).Size = UDim2.new(0, 340, 1, 0)
			end
			listCol = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 2, Parent = content })
			Kit.flex(listCol)
			rows = make("ScrollingFrame", {
				Name = "Rows",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 0),
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = C.LINE,
				SelectionImageObject = Kit.ring,
				LayoutOrder = 2,
				Parent = listCol,
			})
			Kit.flex(rows)
			Kit.pad(rows, 2, 12, 2, 2)
		end
		Kit.list(listCol, false, 8)
		Kit.list(rows, false, 8)
		if weekly then
			local left = untilText(you.resetIn)
			if left then
				Kit.text({ Name = "Reset", Text = "New week in " .. left, FontFace = F.BODY, TextSize = 14, TextColor3 = C.MUTED, Size = UDim2.new(1, 0, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 0, Parent = listCol })
			end
			header(listCol, 1, "Player", { "Wins this week" }, colW)
		else
			header(listCol, 1, "Player", { "Wins", "Battles" })
		end

		if #list == 0 then
			Kit.text({ Name = "Empty", Text = if weekly then "No wins yet this week. Win a battle to top the board!" else "No one is on the board yet. Win a battle to be the first!", FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = rows })
		end
		-- The podium already shows the top 3.
		local first = if #list > 3 then 4 else 1
		for i = first, #list do
			local e = list[i]
			local mine = e.u == myId and myId ~= 0
			local r = rowCard(rows, i, mine)
			cells(r, "#" .. i, MEDAL[i], esc(e.n) .. (if mine then ' <font color="#ffc94d">(you)</font>' else ""), if weekly then { short(e.v) } else { short(e.v), short(e.g) }, nil, colW)
		end

		-- "⋮" between the list and your row (drawn: the fonts have no such glyph).
		local more = make("Frame", { Name = "More", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Parent = listCol })
		Kit.list(more, false, 3, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center })
		for d = 1, 3 do
			Kit.corner(make("Frame", { BackgroundColor3 = C.MUTED, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 4), LayoutOrder = d, Parent = more }))
		end

		-- Your row
		local rank = tonumber(you.rank)
		local yourCard = Kit.card({ Name = "You", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = listCol })
		local s = yourCard:FindFirstChildOfClass("UIStroke")
		if s then
			s.Color = C.YELLOW
			s.Thickness = 2
		end
		Kit.list(yourCard, false, 0)
		local line1 = make("Frame", { Name = "Line", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 48), LayoutOrder = 1, Parent = yourCard })
		local myName = if lp then lp.DisplayName else "You"
		cells(
			line1,
			if rank then "#" .. rank else "–",
			if rank then (MEDAL[rank] or C.YELLOW) else C.MUTED,
			esc(myName) .. ' <font color="#ffc94d">(you)</font>',
			if weekly then { if you.v ~= nil then short(you.v) else "–" } else { if you.v ~= nil then short(you.v) else "–", if you.g ~= nil then short(you.g) else "–" },
			nil,
			colW
		)
		local goal = goalLine(list, you)
		local note = (if rank then "" else "Not in the top 100 yet. ") .. (goal or "")
		if note ~= "" then
			local t = Kit.text({
				Name = "Goal",
				Text = note,
				FontFace = F.BODY,
				TextSize = 14,
				TextColor3 = C.MUTED,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 2,
				Parent = yourCard,
			})
			Kit.pad(t, 62, 14, 0, 12)
		end
	end

	local function loadBoard(which: string)
		gen += 1
		local my = gen
		message("Loading rankings…")
		task.spawn(function()
			local ok, data = ctx.meta("leaderboard", which)
			if not alive or my ~= gen then
				return
			end
			if not ok or type(data) ~= "table" then
				message("Couldn't load the rankings. Try again in a moment.", function()
					loadBoard(which)
				end)
				return
			end
			drawWins(data, which == "week")
		end)
	end
	local function loadWins()
		loadBoard("wins")
	end

	-- Clans ----------------------------------------------------------------------------------------

	local loadClans
	loadClans = function()
		gen += 1
		local my = gen
		message("Loading clans…")
		task.spawn(function()
			local ok, clans = M.clanCall("list", "")
			if not alive or my ~= gen then
				return
			end
			if not ok or type(clans) ~= "table" then
				message("Couldn't load the clans. Try again in a moment.", loadClans)
				return
			end
			clear()
			flow()
			Kit.list(content, false, 8)
			Kit.text({
				Name = "Note",
				Text = "Clans rank by wins: a clan gets a win when any of its members wins a battle.",
				FontFace = F.BODY,
				TextSize = 14,
				TextColor3 = C.MUTED,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 1,
				Parent = content,
			})
			if #clans == 0 then
				Kit.text({ Name = "Empty", Text = "No clans yet. Make one from Clans on the home screen.", FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = content })
				return
			end
			header(content, 2, "Clan", { "Wins", "Battles", "Members" })
			local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
			local myTag = pg and pg:GetAttribute("WFClanTag")
			for i, c in clans do
				local mine = type(myTag) == "string" and myTag ~= "" and c.t == myTag
				local r = rowCard(content, 2 + i, mine)
				cells(r, "#" .. i, MEDAL[i], '<font color="#bcc8e6">[' .. esc(c.t) .. "]</font> " .. esc(c.n), { short(c.w), short(c.g), tostring(c.m or "–") })
			end
		end)
	end

	local tabs = Kit.tabs({ { "wins", "Most wins" }, { "week", "This week" }, { "clans", "Clans" } }, "wins", function(key)
		if key == "clans" then
			loadClans()
		elseif key == "week" then
			loadBoard("week")
		else
			loadWins()
		end
	end)
	tabs.LayoutOrder = 1
	tabs.Parent = top
	if not phone then
		local spacer = make("Frame", { Name = "Spacer", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 2, Parent = top })
		Kit.flex(spacer)
		Kit.text({ Name = "Note", Text = "Updates every minute", FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = top })
	end

	loadWins()

	return function()
		alive = false
		for _, c in conns do
			c:Disconnect()
		end
	end
end

return M
