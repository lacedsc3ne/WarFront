-- War Front Night menu: Your battle (make your own battle / battle room). Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). State and actions: LobbyPages.night (unchanged server flow:
-- lobbyCreate -> lobby view -> lobbySettings / lobbyVisibility / lobbyKick / lobbyStart / lobbyLeave).

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local BattleSettings = require(script.Parent.Parent:WaitForChild("BattleSettings"))
local LobbyPages = require(script.Parent.Parent.Parent:WaitForChild("LobbyPages"))
local C, F = Kit.C, Kit.F
local make = Kit.make

local function stateOf(api): string
	local lobby = api.lobby()
	if lobby then
		return if lobby.isHost then "host" else "member"
	end
	return if api.creating() then "creating" else "setup"
end

local function hostName(lobby): string
	for _, m in lobby.members or {} do
		if m.host then
			return tostring(m.name)
		end
	end
	return tostring(lobby.hostName or "Your friend")
end

return {
	title = "Your battle",
	render = function(page, ctx)
		local api = LobbyPages.night
		local phone = ctx.layout() == "phone"
		local body = page.body
		Kit.list(body, false, 14)
		local state = stateOf(api)
		local refreshers: { () -> () } = {}
		local alive = true
		local function refreshAll()
			for _, f in refreshers do
				f()
			end
		end
		LobbyPages.attach("host", function()
			if not alive then
				return
			end
			if stateOf(api) ~= state then
				ctx.rerender()
			else
				refreshAll()
			end
		end)

		local title = page.header:FindFirstChild("Title")

		if state == "creating" then
			local box = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 200), LayoutOrder = 1, Parent = body })
			Kit.text({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Text = "Making your battle…", FontFace = F.TITLE, TextSize = 26, TextColor3 = C.YELLOW, Parent = box })
			return function()
				alive = false
			end
		end

		if state == "setup" then
			BattleSettings.muted(body, 0, "Pick how your battle works, then invite your friends.")
			local refresh, order = BattleSettings.build(body, 0, {
				api = api,
				editable = true,
				pool = ctx.mapPool,
				preview = ctx.preview,
				phone = phone,
			})
			table.insert(refreshers, refresh)
			local card = Kit.card({ Name = "Create", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order + 1, Parent = body })
			Kit.pad(card, 16, 16, 14, 16)
			-- Desktop: "who can join" on the left, a normal-width Create button on the right.
			Kit.list(card, not phone, if phone then 10 else 16, { VerticalAlignment = Enum.VerticalAlignment.Center })
			local who = make("Frame", { Name = "Who", BackgroundTransparency = 1, Size = UDim2.new(if phone then 1 else 0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
			if not phone then
				Kit.flex(who)
			end
			Kit.list(who, false, 8)
			Kit.text({ Text = "Who can join?", FontFace = F.BOLD, TextSize = 16, LayoutOrder = 1, Parent = who })
			local vis, setVis = Kit.segmented({ { "private", "Only with the code" }, { "public", "Anyone" } }, api.visibility(), function(v)
				api.setVisibility(v)
			end)
			vis.LayoutOrder = 2
			vis.Parent = who
			table.insert(refreshers, function()
				setVis(api.visibility())
			end)
			Kit.button("primary", "Create battle", {
				name = "CreateBattle",
				height = 56,
				textSize = 24,
				padX = 48,
				size = if phone then UDim2.new(1, 0, 0, 56) else nil,
				layoutOrder = 3,
				parent = card,
				onActivated = function()
					api.create()
				end,
			})
			return function()
				alive = false
			end
		end

		-- In a battle room (host or member)
		local lobby = api.lobby()
		local hosting = state == "host"
		if title and lobby and not hosting then
			title.Text = hostName(lobby) .. "'s battle"
		end
		local columns = make("Frame", { Name = "Columns", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
		Kit.list(columns, not phone, 16)
		local left = make("Frame", { Name = "Left", BackgroundTransparency = 1, Size = if phone then UDim2.new(1, 0, 0, 0) else UDim2.new(1, -376, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = if phone then 2 else 1, Parent = columns })
		Kit.list(left, false, 14)
		local right = make("Frame", { Name = "Right", BackgroundTransparency = 1, Size = if phone then UDim2.new(1, 0, 0, 0) else UDim2.new(0, 360, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = if phone then 1 else 2, Parent = columns })
		Kit.list(right, false, 12)

		local refreshSettings = BattleSettings.build(left, 0, {
			api = api,
			editable = hosting,
			pool = ctx.mapPool,
			preview = ctx.preview,
			phone = phone,
		})
		table.insert(refreshers, refreshSettings)
		table.insert(refreshers, BattleSettings.room(right, 1, { api = api, ctx = ctx }))

		if hosting then
			local start
			start = Kit.button("primary", "Start battle", {
				name = "StartBattle",
				height = 58,
				textSize = 26,
				size = UDim2.new(1, 0, 0, 58),
				layoutOrder = 2,
				parent = right,
				onActivated = function()
					api.start()
					Kit.setButtonText(start, "Starting…")
					task.delay(6, function()
						if start.Parent then
							Kit.setButtonText(start, "Start battle")
						end
					end)
				end,
			})
		else
			local wait = Kit.card({ Name = "Waiting", Size = UDim2.new(1, 0, 0, 52), LayoutOrder = 2, Parent = right })
			Kit.pad(wait, 14)
			Kit.list(wait, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Center })
			Kit.icon("Hourglass", { Size = UDim2.fromOffset(18, 18), ImageColor3 = C.MUTED, LayoutOrder = 1, Parent = wait })
			local label = Kit.text({ Text = "", FontFace = F.TITLE, TextSize = 16, TextColor3 = C.MUTED, LayoutOrder = 2, Parent = wait })
			table.insert(refreshers, function()
				local l = api.lobby()
				label.Text = "Waiting for " .. (if l then hostName(l) else "the host") .. " to start…"
			end)
		end
		Kit.button("danger", "Leave battle", {
			name = "LeaveBattle",
			height = 44,
			size = UDim2.new(1, 0, 0, 44),
			layoutOrder = 3,
			parent = right,
			onActivated = function()
				api.leave()
				ctx.close()
			end,
		})
		refreshAll()
		return function()
			alive = false
		end
	end,
}
