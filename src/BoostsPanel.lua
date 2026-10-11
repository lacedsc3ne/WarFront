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

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local WHITE = Color3.new(1, 1, 1)
local GRAY800 = Color3.fromRGB(14, 43, 64)
local C = MenuKit.C

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local state = {
	counts = {} :: { [string]: number },
	readyAt = {} :: { [string]: number }, -- key -> game seconds of fighting when it's usable again
	prices = {} :: { [string]: number },
	icons = {} :: { [string]: number }, -- Night: product picture ids (from the same product lookup)
	phase = "Lobby",
	ranked = false,
	msg = "",
	elapsed = 0, -- game seconds of fighting when the last phase message came
	elapsedAt = 0, -- os.clock() of that message
	speed = 1,
	collapsed = false, -- folded away with the crown button
}
local ui: any = {}

local MatchSkin=require(script.Parent:WaitForChild("MatchSkin"))
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
	MatchSkin.decorate(inst)
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

-- Night names (same as the shop).
local NIGHT_NAMES = { goldCrate = "Gold crate", reinforcements = "Reinforcements", shield = "Shield", nukeVoucher = "Free nuke", revive = "Extra revive" }

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
			act.Text = "Use " .. n .. "x"
			act.BackgroundColor3 = MatchSkin.C.cyan
			act.AutoButtonColor = true
		elseif b.id == 0 then
			grey(act, "Store")
		else
			-- None owned: buy one now (works any time outside ranked).
			local price = state.prices[b.key]
			act.Text = if price then "R$ " .. price else "Buy"
			act.BackgroundColor3 = MatchSkin.C.gold
			act.AutoButtonColor = true
		end
		-- Owning some no longer hides buying: a small Robux button sits next to Use (owner, 11 Oct 2026).
		local canBuy = n > 0 and b.id ~= 0 and not state.ranked
		local price = state.prices[b.key]
		row.buy.Visible = canBuy
		row.buy.Text = if price then "R$ " .. price else "Buy"
		if canBuy then
			act.AnchorPoint, act.Position, act.Size = Vector2.new(0, 1), UDim2.new(0, 8, 1, -4), UDim2.new(1, -80, 0, 25)
		else
			act.AnchorPoint, act.Position, act.Size = Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -4), UDim2.new(1, -16, 0, 25)
		end
		act.TextColor3=if act.AutoButtonColor then Color3.new(0,0,0) else MatchSkin.C.white
		row.icon.ImageTransparency = if act.AutoButtonColor then 0 else 0.4
		if MatchSkin.night then
			-- Night: yellow "Use", green Robux price (like the shop), the boost's own picture.
			local K = MatchSkin.Kit.C
			if act.AutoButtonColor then
				local using = n > 0
				act.Text = if using then (if n > 1 then "Use (" .. n .. ")" else "Use") else act.Text
				act.BackgroundColor3 = if using then K.YELLOW else K.GREEN
				act.TextColor3 = if using then K.YELLOW_TEXT else K.GREEN_TEXT
			else
				act.BackgroundColor3, act.TextColor3 = K.DEEP, K.MUTED
			end
			row.buy.BackgroundColor3, row.buy.TextColor3 = K.GREEN, K.GREEN_TEXT
			local image = state.icons[b.key]
			if row.art then
				row.art.Visible = image ~= nil
				row.art.Image = if image then "rbxassetid://" .. image else ""
				row.art.ImageTransparency = row.icon.ImageTransparency
				row.icon.Visible = image == nil
			end
		end
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
		if blocked() or (state.readyAt[b.key] or 0) > elapsedNow() then
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
	local panel = make("ScrollingFrame", {
  CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ScrollBarThickness=3,ClipsDescendants=true,
		Name = "BoostsPanel",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(320, 232),
		AutomaticSize = Enum.AutomaticSize.None,
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
	local header=make("Frame",{Name="Header",Size=UDim2.fromOffset(308,24),BackgroundTransparency=1,LayoutOrder=0,ZIndex=41,Parent=panel})
 make("TextLabel",{BackgroundTransparency=1,Text="BOOSTS",FontFace=FONT_BOLD,TextSize=13,TextColor3=MatchSkin.C.white,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.fromOffset(240,24),ZIndex=42,Parent=header})
 local back=make("TextButton",{Name="Close",BackgroundTransparency=1,Text="",Position=UDim2.fromOffset(280,0),Size=UDim2.fromOffset(24,24),ZIndex=43,Parent=header})
 back.Activated:Connect(function() state.collapsed=true;refresh() end)
 local tiles = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(308,192), LayoutOrder = 1, ZIndex = 41, Parent = panel })
	make("UIGridLayout",{CellSize=UDim2.fromOffset(150,92),CellPadding=UDim2.fromOffset(8,8),SortOrder=Enum.SortOrder.LayoutOrder,Parent=tiles})
	ui.rows = {}
	for i, b in MetaConfig.BOOSTS do
		local tile = make("Frame", { Name="BoostCard",BackgroundColor3 = MatchSkin.C.raised, BackgroundTransparency = 0, Size = UDim2.fromOffset(150,92), LayoutOrder = i, ZIndex = 41, Parent = tiles })
 make("TextLabel",{BackgroundTransparency=1,Size=UDim2.fromOffset(102,16),Position=UDim2.fromOffset(10,8),FontFace=FONT_BOLD,TextSize=10,TextColor3=MatchSkin.C.white,Text=string.upper(b.name),TextTruncate=Enum.TextTruncate.AtEnd,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=43,Parent=tile})
		corner(tile, 6)
		make("UIStroke", { Color = C.WHITE, Transparency = 0.9, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tile })
		local icon = IconKit.image(b.icon or "Gold", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 29), Size = UDim2.fromOffset(25, 25), ZIndex = 42, Parent = tile })
		local count = make("TextLabel", { BackgroundColor3 = C.CYBER, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -2, 0, 2), Size = UDim2.fromOffset(0, 14), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 10, TextColor3 = C.BLACK, Text = "x0", Visible = false, ZIndex = 43, Parent = tile })
		corner(count, 7)
		make("UIPadding", { PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3), Parent = count })
		local action = make("TextButton", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -16, 0, 25), BackgroundColor3 = C.MALIBU, FontFace = FONT_BOLD, TextSize = 11, TextColor3 = WHITE, Text = "Use", ZIndex = 42, Parent = tile })
		corner(action, 5)
		action.Activated:Connect(function()
			onAction(b)
		end)
		-- The whole card activates the same use/purchase action; hover still shows its description.
		local hit = make("TextButton", { Name="CardClickTarget", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "", ZIndex = 44, Parent = tile })
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
			onAction(b)
		end)
		-- Robux buy button beside Use (only shown while you own some; above the card's click target).
		local buy = make("TextButton", { Name = "Buy", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -8, 1, -4), Size = UDim2.fromOffset(62, 25), BackgroundColor3 = MatchSkin.C.gold, FontFace = FONT_BOLD, TextSize = 11, TextColor3 = Color3.new(0, 0, 0), Text = "Buy", Visible = false, ZIndex = 45, Parent = tile })
		corner(buy, 5)
		buy.Activated:Connect(function()
			if not state.ranked and b.id ~= 0 then
				MarketplaceService:PromptProductPurchase(localPlayer, b.id)
			end
		end)
		local art = nil
		if MatchSkin.night then
			buy.FontFace = MatchSkin.Kit.F.TITLE
			buy.TextSize = 12
			buy:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
			-- Night: plain name, the product's own picture (filled in by fetchPrices), pill buttons.
			for _, v in tile:GetChildren() do
				if v:IsA("TextLabel") and v.Text == string.upper(b.name) then
					v.Text = NIGHT_NAMES[b.key] or b.name
					v.TextSize = 13
					v.FontFace = MatchSkin.Kit.F.TITLE
				end
			end
			art = make("ImageLabel", { Name = "BoostArt", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 25), Size = UDim2.fromOffset(34, 34), ScaleType = Enum.ScaleType.Fit, Visible = false, ZIndex = 42, Parent = tile })
			corner(art, 8)
			action.FontFace = MatchSkin.Kit.F.TITLE
			action.TextSize = 13
			action:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(0.5, 0)
		end
		ui.rows[b.key] = { count = count, action = action, icon = icon, art = art, buy = buy }
	end
	ui.status = make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(308, 0), AutomaticSize = Enum.AutomaticSize.Y, FontFace = FONT, TextSize = 11, TextColor3 = C.AMBER300, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Visible = false, LayoutOrder = 2, ZIndex = 41, Parent = panel })
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
					return MarketplaceService:GetProductInfoAsync(b.id, Enum.InfoType.Product)
				end)
				if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
					state.prices[b.key] = tonumber(info.PriceInRobux)
					local image = tonumber(info.IconImageAssetId)
					if image and image > 0 then
						state.icons[b.key] = image
					end
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
 playerGui:GetAttributeChangedSignal("WFMatchModal"):Connect(function() if playerGui:GetAttribute("WFMatchModal") then BoostsPanel.collapse() end end)
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

function BoostsPanel.collapse()
 state.collapsed=true
 if ui.panel then ui.panel.Visible=false end
end

return BoostsPanel
