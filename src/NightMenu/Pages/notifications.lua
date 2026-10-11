-- War Front Night menu: Notifications. Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). Shows NightMenu.Feed (this session's battle rewards,
-- level ups, gifts), newest first, and marks everything read while the page is open.

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local Art = require(script.Parent.Parent:WaitForChild("Art"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local function timeAgo(t: any): string
	local d = os.time() - (tonumber(t) or os.time())
	if d < 60 then
		return "just now"
	elseif d < 3600 then
		return (d // 60) .. " min ago"
	elseif d < 86400 then
		return (d // 3600) .. " h ago"
	end
	return (d // 86400) .. " d ago"
end

local function itemCard(parent: Instance, order: number, item: any, fresh: boolean)
	local color = if typeof(item.color) == "Color3" then item.color else C.CYAN
	local c = Kit.card({ Name = "Item_" .. tostring(item.id), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	Kit.pad(c, 14, 14, 12, 12)
	Kit.list(c, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Top })
	local icon = if type(item.icon) == "string" then item.icon else "Bell"
	if Art.has(icon) then
		Art.image(icon, { Name = "Tile", Size = UDim2.fromOffset(36, 36), LayoutOrder = 1, Parent = c })
	else
		local tile = make("Frame", { Name = "Tile", BackgroundColor3 = color, BackgroundTransparency = 0.8, BorderSizePixel = 0, Size = UDim2.fromOffset(30, 30), LayoutOrder = 1, Parent = c })
		Kit.corner(tile, 8)
		Kit.icon(icon, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), ImageColor3 = color, Parent = tile })
	end
	local info = make("Frame", { Name = "Info", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = c })
	Kit.flex(info)
	Kit.list(info, false, 3)
	Kit.text({ Name = "Title", Text = tostring(item.title or ""), FontFace = F.TITLE, TextSize = 15, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = info })
	if item.body and item.body ~= "" then
		Kit.text({ Name = "Body", Text = tostring(item.body), FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = info })
	end
	Kit.text({ Name = "Time", Text = timeAgo(item.t), FontFace = F.BODY, TextSize = 13, TextColor3 = C.MUTED, LayoutOrder = 3, Parent = info })
	if fresh then
		-- New since the page was opened (or arrived while it is open).
		local dot = make("Frame", { Name = "New", BackgroundColor3 = C.CYAN, BorderSizePixel = 0, Size = UDim2.fromOffset(8, 8), LayoutOrder = 3, Parent = c })
		Kit.corner(dot)
	end
end

return {
	title = "Notifications",
	render = function(page, ctx)
		local Feed = require(script.Parent.Parent:WaitForChild("Feed"))
		local body = page.body
		Kit.list(body, false, 14)
		local fresh = {}
		local closed = false

		local function draw()
			if closed then
				return
			end
			local items = Feed.items()
			local scroll = body.CanvasPosition
			task.defer(function()
				if body.Parent then
					body.CanvasPosition = scroll
				end
			end)
			for i = 1, math.min(Feed.unread(), #items) do
				fresh[items[i].id] = true
			end
			for _, ch in body:GetChildren() do
				if ch:IsA("GuiObject") then
					ch:Destroy()
				end
			end
			if #items == 0 then
				local c = Kit.card({ Name = "Empty", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
				Kit.pad(c, 20, 20, 26, 26)
				Kit.list(c, false, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
				Art.image("Bell", { Size = UDim2.fromOffset(72, 72), LayoutOrder = 1, Parent = c })
				Kit.text({ Text = "Nothing new yet. Your battle rewards, level ups and gifts will show up here.", FontFace = F.BOLD, TextSize = 15, TextColor3 = C.MUTED, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = c })
			else
				local list = make("Frame", { Name = "Items", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
				Kit.list(list, false, 8)
				for i, item in items do
					itemCard(list, i, item, fresh[item.id] == true)
				end
			end
			Kit.button("secondary", "Game updates", { name = "GameUpdates", icon = "News", height = 42, layoutOrder = 2, parent = body, onActivated = function()
				ctx.open("news")
			end })
		end

		-- Feed.markRead fires Changed itself, so redraws are batched to one per frame.
		local queued = false
		local function refresh()
			if queued or closed then
				return
			end
			queued = true
			task.defer(function()
				queued = false
				if closed then
					return
				end
				draw()
				Feed.markRead()
			end)
		end

		draw()
		Feed.markRead()
		local conn = Feed.Changed:Connect(refresh)
		-- Keep "5 min ago" current.
		task.spawn(function()
			while not closed do
				task.wait(30)
				if not closed then
					draw()
				end
			end
		end)
		return function()
			closed = true
			conn:Disconnect()
		end
	end,
}
