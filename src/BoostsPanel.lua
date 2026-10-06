--[[
	War Front - in-match Boosts button and panel (one-use boosts, MetaConfig.BOOSTS).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

-- StarterPlayer.StarterPlayerScripts.BoostsPanel (ModuleScript), used by HudSidebars.
-- An always-visible strip under the top-right bar (same look as the game speed panel): one tile per
-- boost with its icon, how many you own and Use / Robux buy; hovering a tile shows what it does.
-- Server rules are in ServerScriptService.Perks; this only asks ("boost", key) and shows the answer
-- ("boostResult"). Shown in every match (hidden only while watching a replay); a boost that can't
-- be used right now has a greyed-out button that says why ("Ranked", "In 12s" = unlock delay or
-- cooldown). Boosts can be used again and again (one per BOOST_COOLDOWN each); with none left the
-- button buys one with Robux, and the server uses it as soon as the purchase goes through. The crown
-- button in the top-right bar folds the strip away and back.
-- BoostsPanel.setup({ button = GuiButton, gui = ScreenGui, net = RemoteEvent }) -> strip Frame
--   (HudSidebars stacks the strip under the top-right bar, with the speed and clock panels)

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))

local BoostsPanel = {}

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(31, 41, 55)
local C = MenuKit.C

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local state = {
	counts = {} :: { [string]: number },
	readyAt = {} :: { [string]: number }, -- key -> game seconds of fighting when it's usable again
	prices = {} :: { [string]: number },
	phase = "Lobby",
	ranked = false,
	msg = "",
	elapsed = 0, -- game seconds of fighting when the last phase message came
	elapsedAt = 0, -- os.clock() of that message
	speed = 1,
	collapsed = false, -- folded away with the crown button
}
local ui: any = {}

local function make(className: string, props: { [string]: any })
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(o: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = o })
end

local function visible(): boolean
	-- Whole match (spawn phase included), not in menus, lobbies or replays.
	return (state.phase == "Spawn" or state.phase == "Play") and playerGui:GetAttribute("WFReplay") ~= true
end

local function elapsedNow(): number
	return state.elapsed + (os.clock() - state.elapsedAt) * state.speed
end

-- Why boosts can't be used right now (short, fits the button), or nil.
local function blocked(): string?
	if state.ranked then
		return "Ranked"
	end
	if state.phase ~= "Play" then
		return if state.phase == "Spawn" then "Spawn" else "Not now" -- usable once the fighting starts
	end
	local left = MetaConfig.BOOST_DELAY - elapsedNow()
	if left > 0 then
		return "In " .. math.ceil(left) .. "s"
	end
	return nil
end

local function grey(act: TextButton, text: string)
	act.Text = text
	act.BackgroundColor3 = C.GRAY600
	act.TextTransparency = 0.35
	act.AutoButtonColor = false
end

local function refresh()
	if not ui.button then
		return
	end
	local show = visible()
	ui.button.Visible = show
	ui.panel.Visible = show and not state.collapsed
	for _, b in MetaConfig.BOOSTS do
		local row = ui.rows[b.key]
		local n = state.counts[b.key] or 0
		row.count.Text = "x" .. n
		row.count.Visible = n > 0
		local act = row.action
		local why = blocked()
		local cool = (state.readyAt[b.key] or 0) - elapsedNow()
		if not why and cool > 0 then
			why = math.ceil(cool) .. "s"
		end
		act.TextTransparency = 0
		if state.ranked then
			grey(act, "Ranked")
		elseif n > 0 and why then
			grey(act, why)
		elseif n > 0 then
			act.Text = "Use"
			act.BackgroundColor3 = C.MALIBU
			act.AutoButtonColor = true
		elseif b.id == 0 then
			grey(act, "Store")
		else
			-- None owned: buy one now (works any time outside ranked).
			local price = state.prices[b.key]
			act.Text = if price then "R$ " .. price else "Buy"
			act.BackgroundColor3 = C.EMERALD500
			act.AutoButtonColor = true
		end
		row.icon.ImageTransparency = if act.AutoButtonColor then 0 else 0.4
	end
	ui.status.Text = state.msg
	ui.status.Visible = state.msg ~= "" or ui.tipFor ~= nil
	if ui.tipFor then
		ui.status.Text = ui.tipFor.name .. ": " .. ui.tipFor.desc .. (if state.msg ~= "" then "\n" .. state.msg else "")
		ui.status.TextColor3 = if state.msg ~= "" then C.AMBER300 else C.GRAY300
	else
		ui.status.TextColor3 = C.AMBER300
	end
end

local function onAction(b)
	if state.ranked then
		return
	end
	if (state.counts[b.key] or 0) > 0 then
		if blocked() then
			return
		end
		state.msg = ""
		ui.net:FireServer("boost", b.key)
	elseif b.id ~= 0 then
		MarketplaceService:PromptProductPurchase(localPlayer, b.id)
	end
end

-- Always-visible strip of boost tiles (icon, owned count, Use / price / greyed-out reason). The
-- crown button in the top-right bar folds it away and back.
local function build(c)
	ui.button, ui.net = c.button, c.net
	local panel = make("Frame", {
		Name = "BoostsPanel",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = GRAY800,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		ZIndex = 40,
		Parent = c.gui,
	})
	corner(panel, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = panel })
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 4), Parent = panel })
	local tiles = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 62), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, ZIndex = 41, Parent = panel })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = tiles })
	ui.rows = {}
	for i, b in MetaConfig.BOOSTS do
		local tile = make("Frame", { BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.95, Size = UDim2.fromOffset(56, 62), LayoutOrder = i, ZIndex = 41, Parent = tiles })
		corner(tile, 6)
		make("UIStroke", { Color = C.WHITE, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tile })
		local icon = IconKit.image(b.icon or "Gold", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(24, 24), ZIndex = 42, Parent = tile })
		local count = make("TextLabel", { BackgroundColor3 = C.CYBER, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -2, 0, 2), Size = UDim2.fromOffset(0, 14), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 10, TextColor3 = C.BLACK, Text = "x0", Visible = false, ZIndex = 43, Parent = tile })
		corner(count, 7)
		make("UIPadding", { PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3), Parent = count })
		local action = make("TextButton", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -6, 0, 22), BackgroundColor3 = C.MALIBU, FontFace = FONT_BOLD, TextSize = 11, TextColor3 = WHITE, Text = "Use", ZIndex = 42, Parent = tile })
		corner(action, 5)
		action.Activated:Connect(function()
			onAction(b)
		end)
		-- Hovering a tile shows what the boost does under the strip.
		local hit = make("TextButton", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -26), Text = "", ZIndex = 44, Parent = tile })
		hit.MouseEnter:Connect(function()
			ui.tipFor = b
			refresh()
		end)
		hit.MouseLeave:Connect(function()
			if ui.tipFor == b then
				ui.tipFor = nil
				refresh()
			end
		end)
		hit.Activated:Connect(function()
			-- Touch / gamepad: tapping the icon shows the description.
			ui.tipFor = if ui.tipFor == b then nil else b
			refresh()
		end)
		ui.rows[b.key] = { count = count, action = action, icon = icon }
	end
	ui.status = make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(4 * 56 + 3 * 4, 0), AutomaticSize = Enum.AutomaticSize.Y, FontFace = FONT, TextSize = 11, TextColor3 = C.AMBER300, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Visible = false, LayoutOrder = 2, ZIndex = 41, Parent = panel })
	ui.panel = panel

	ui.button.Activated:Connect(function()
		state.collapsed = not state.collapsed
		refresh()
	end)
end

-- Robux prices (shown when you have none of a boost).
local function fetchPrices()
	for _, b in MetaConfig.BOOSTS do
		if b.id ~= 0 then
			task.spawn(function()
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(b.id, Enum.InfoType.Product)
				end)
				if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
					state.prices[b.key] = tonumber(info.PriceInRobux)
					refresh()
				end
			end)
		end
	end
end

function BoostsPanel.setup(c)
	build(c)
	fetchPrices()
	local metaEvent = Shared:WaitForChild("Meta")
	metaEvent.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "profile" and type(data) == "table" and type(data.boosts) == "table" then
			for _, b in MetaConfig.BOOSTS do
				state.counts[b.key] = tonumber(data.boosts[b.key]) or 0
			end
			refresh()
		end
	end)
	task.spawn(function()
		local ok, success, p = pcall(function()
			return Shared:WaitForChild("MetaFn"):InvokeServer("get")
		end)
		if ok and success and type(p) == "table" and type(p.boosts) == "table" then
			for _, b in MetaConfig.BOOSTS do
				state.counts[b.key] = tonumber(p.boosts[b.key]) or 0
			end
			refresh()
		end
	end)
	local function applyPhase(data: any)
		local was = state.phase
		state.phase = data.phase or state.phase
		state.ranked = data.matchKind == "ranked"
		state.elapsed = tonumber(data.elapsed) or 0
		state.elapsedAt = os.clock()
		state.speed = tonumber(data.speed) or 1
		if state.phase == "Spawn" and was ~= "Spawn" then
			table.clear(state.readyAt) -- new round
		end
	end
	c.net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "phase" and type(data) == "table" then
			applyPhase(data)
			refresh()
		elseif kind == "init" then
			table.clear(state.readyAt)
			if type(data) == "table" and type(data.phase) == "table" then
				applyPhase(data.phase)
			end
			refresh()
		elseif kind == "boostResult" and type(data) == "table" then
			state.msg = tostring(data.text or "")
			if data.ok and tonumber(data.cooldown) then
				state.readyAt[data.key] = elapsedNow() + tonumber(data.cooldown)
			end
			local msg = state.msg
			task.delay(6, function()
				if state.msg == msg then
					state.msg = ""
					refresh()
				end
			end)
			refresh()
		end
	end)
	playerGui:GetAttributeChangedSignal("WFReplay"):Connect(refresh)
	refresh()
	-- Count down "In 12s".
	task.spawn(function()
		while true do
			task.wait(0.5)
			if ui.panel.Visible then
				refresh()
			end
		end
	end)
	return ui.panel
end

return BoostsPanel
