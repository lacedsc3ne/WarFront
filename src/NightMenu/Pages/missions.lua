-- War Front Night menu: Missions. Copyright (C) 2026 Liam (lacedsc3ne).
-- Daily and weekly missions from Progression's MetaFn ops "missions" (Quests.view) and "claimMission"
-- (Quests.claim: medals + season XP). The server pushes a new profile after a claim and after every
-- battle, which refreshes this page through ctx.onProfile.

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local Art = require(script.Parent.Parent:WaitForChild("Art"))

local C, F = Kit.C, Kit.F
local make = Kit.make
local AUTO_Y = Enum.AutomaticSize.Y
local CENTER = Enum.HorizontalAlignment.Center
local MIDDLE = Enum.VerticalAlignment.Center

local function numberText(n: any): string
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

local function timeText(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d, h, m = sec // 86400, (sec % 86400) // 3600, (sec % 3600) // 60
	if d > 0 then
		return d .. "d " .. h .. "h"
	elseif h > 0 then
		return h .. "h " .. m .. "m"
	elseif m > 0 then
		return m .. "m " .. (sec % 60) .. "s"
	end
	return sec .. "s"
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

-- Small icon + text line (rewards, "Collected").
local function iconLine(parent: Instance, order: number, icon: string, text: string, color: Color3, size: number, font: Font?): Frame
	local f = make("Frame", { Name = "Line", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, size + 4), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, Parent = parent })
	Kit.list(f, true, 4, { VerticalAlignment = MIDDLE })
	Kit.icon(icon, { Size = UDim2.fromOffset(size + 1, size + 1), ImageColor3 = color, LayoutOrder = 1, Parent = f })
	Kit.text({ Text = text, FontFace = font or F.BOLD, TextSize = size, TextColor3 = color, LayoutOrder = 2, Parent = f })
	return f
end

-- One mission card. Finished and not collected: green border and a Collect button.
local function missionRow(parent: Instance, order: number, m: any, weekly: boolean, phone: boolean, onCollect: (any, TextButton) -> ())
	local goal = math.max(1, tonumber(m.goal) or 1)
	local n = math.clamp(tonumber(m.n) or 0, 0, goal)
	local claimed = m.claimed == true
	local ready = n >= goal and not claimed
	local accent = if weekly then C.PURPLE else C.YELLOW
	local barColor = if weekly then C.PURPLE else C.CYAN

	local card = Kit.card({
		Name = "Mission_" .. tostring(m.id),
		BackgroundColor3 = if claimed then C.CARD:Lerp(C.PAGE, 0.6) else C.CARD,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = AUTO_Y,
		LayoutOrder = order,
		Parent = parent,
	})
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke and ready then
		stroke.Color = C.GREEN
		stroke.Thickness = 2
	end
	Kit.pad(card, if phone then 12 else 16, if phone then 12 else 16, 12, 12)
	Kit.list(card, true, if phone then 10 else 14, { VerticalAlignment = MIDDLE })

	local tile = make("Frame", {
		Name = "IconTile",
		BackgroundColor3 = if claimed then C.LINE else accent,
		BackgroundTransparency = if claimed then 0.5 else 0.8,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(40, 40),
		LayoutOrder = 1,
		Parent = card,
	})
	Kit.corner(tile, 11)
	local art = Art.mission(m.id)
	if art then
		tile.Size = UDim2.fromOffset(48, 48)
		Art.image(art, {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.92, 0.92),
			ImageTransparency = if claimed then 0.5 else 0,
			Parent = tile,
		})
	else
		Kit.icon(tostring(m.icon or "Missions"), {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.58, 0.58),
			ImageColor3 = if claimed then C.MUTED else accent,
			Parent = tile,
		})
	end

	local col = make("Frame", { Name = "Info", BackgroundTransparency = 1, Size = UDim2.new(), AutomaticSize = AUTO_Y, LayoutOrder = 2, Parent = card })
	Kit.flex(col)
	Kit.list(col, false, 8)
	wrapText(col, 1, tostring(m.text or ""), 16, if claimed then C.MUTED else C.TEXT, F.TITLE)
	local bar = Kit.progress(n / goal, if claimed then barColor:Lerp(C.DEEP, 0.6) else barColor)
	bar.Size = UDim2.new(1, 0, 0, 8)
	bar.LayoutOrder = 2
	bar.Parent = col

	local side = make("Frame", {
		Name = "Side",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(if phone then 92 else 124, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		LayoutOrder = 3,
		Parent = card,
	})
	Kit.list(side, false, 2, { HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = MIDDLE })
	if claimed then
		iconLine(side, 1, "Check", "Collected", C.MUTED, 15, F.TITLE)
	elseif ready then
		local btn
		btn = Kit.button("robux", "Collect " .. numberText(m.medals), {
			name = "Collect",
			icon = "Medal",
			height = 40,
			textSize = 16,
			padX = 16,
			layoutOrder = 1,
			parent = side,
			onActivated = function()
				onCollect(m, btn)
			end,
		})
	else
		Kit.text({ Name = "Count", Text = n .. "/" .. goal, FontFace = F.TITLE, TextSize = 18, LayoutOrder = 1, Parent = side })
		iconLine(side, 2, "Medal", "+" .. numberText(m.medals) .. " medals", C.YELLOW, 13)
		Kit.text({ Text = "+" .. numberText(m.xp) .. " season XP", FontFace = F.BOLD, TextSize = 13, TextColor3 = C.CYAN, LayoutOrder = 3, Parent = side })
	end
	return card
end

local function heading(parent: Instance, order: number, text: string)
	return Kit.text({ Name = "Heading", Text = text, RichText = true, FontFace = F.TITLE, TextSize = 20, LayoutOrder = order, Parent = parent })
end

return {
	title = "Missions",
	headerRight = function()
		-- Filled in by render (headerRight gets no ctx).
		local f = make("Frame", { Name = "MissionsReset", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, Visible = false })
		Kit.list(f, true, 6, { VerticalAlignment = MIDDLE })
		Kit.icon("Clock", { Size = UDim2.fromOffset(16, 16), ImageColor3 = C.MUTED, LayoutOrder = 1, Parent = f })
		Kit.text({ Name = "Label", Text = "", FontFace = F.BOLD, TextSize = 14, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = f })
		return f
	end,
	render = function(page, ctx)
		local body = page.body
		local phone = ctx.layout() == "phone"
		local alive = true
		Kit.list(body, false, 14)
		local content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = body })
		Kit.list(content, false, 10)

		local resetFrame = page.header:FindFirstChild("MissionsReset")
		local resetLabel = resetFrame and resetFrame:FindFirstChild("Label")

		local data: any = nil
		local fetchedAt = 0
		local failed, errorText = false, nil
		local loading, again = false, false
		local resetAsked = -1 -- fetchedAt of the data we already re-fetched for after a reset
		local busy = false
		local load: () -> ()

		local function tick()
			if not data then
				if resetFrame then
					resetFrame.Visible = false
				end
				return
			end
			local elapsed = os.clock() - fetchedAt
			local daily = (tonumber(data.dailyResetIn) or 0) - elapsed
			local weekly = (tonumber(data.weeklyResetIn) or 0) - elapsed
			if resetLabel then
				resetLabel.Text = "New missions in " .. timeText(daily)
				resetFrame.Visible = true
			end
			-- New missions are rolled by the server when we ask after the reset.
			if (daily <= 0 or weekly <= 0) and resetAsked ~= fetchedAt then
				resetAsked = fetchedAt
				task.delay(1, load)
			end
		end

		local function collect(m: any, btn: TextButton)
			if busy then
				return
			end
			busy = true
			btn:SetAttribute("Disabled", true)
			Kit.setButtonText(btn, "Collecting...")
			task.spawn(function()
				local ok, res = ctx.meta("claimMission", m.id)
				busy = false
				if ok and type(res) == "table" then
					ctx.toast("+" .. numberText(res.medals or m.medals) .. " medals · +" .. numberText(res.seasonXp or m.xp) .. " season XP", "ok")
				else
					ctx.toast(if type(res) == "string" and res ~= "" then res else "Something went wrong, try again", "error")
					if btn.Parent then
						btn:SetAttribute("Disabled", false)
						Kit.setButtonText(btn, "Collect " .. numberText(m.medals))
					end
				end
				load()
			end)
		end

		local function section(order: number, title: string, list: any, weekly: boolean)
			heading(content, order, title)
			local holder = make("Frame", { Name = if weekly then "Weekly" else "Daily", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = order + 1, Parent = content })
			Kit.list(holder, false, 10)
			if type(list) ~= "table" or #list == 0 then
				wrapText(holder, 1, "No missions right now. Check back soon.", 14, C.MUTED)
				return
			end
			for i, m in list do
				missionRow(holder, i, m, weekly, phone, collect)
			end
		end

		local function errorCard()
			local card = Kit.card({ Name = "Error", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = AUTO_Y, LayoutOrder = 1, Parent = content })
			Kit.pad(card, 18, 18, 18, 18)
			Kit.list(card, false, 10, { HorizontalAlignment = CENTER })
			Kit.icon("AlertCircle", { Size = UDim2.fromOffset(30, 30), ImageColor3 = C.PINK, LayoutOrder = 1, Parent = card })
			Kit.text({ Text = "Couldn't load your missions", FontFace = F.TITLE, TextSize = 18, LayoutOrder = 2, Parent = card })
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
			for _, ch in content:GetChildren() do
				if not ch:IsA("UIListLayout") then
					ch:Destroy()
				end
			end
			if data then
				section(1, "Today", data.daily, false)
				make("Frame", { Name = "Gap", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 4), LayoutOrder = 3, Parent = content })
				section(4, 'This week <font color="#bcc8e6">· bigger prizes</font>', data.weekly, true)
			elseif failed then
				errorCard()
			else
				wrapText(content, 1, "Loading your missions...", 15, C.MUTED, F.BODY, Enum.TextXAlignment.Center)
			end
			body.CanvasPosition = y
			tick()
		end

		-- Fetch the missions; calls that arrive while one is running are folded into one more fetch.
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
					local ok, res = ctx.meta("missions")
					if not alive then
						return
					end
					if ok and type(res) == "table" then
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
			load() -- progress changes after battles and claims
		end)
		load()
		task.spawn(function()
			while alive do
				task.wait(1)
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
