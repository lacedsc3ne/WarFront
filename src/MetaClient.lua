--[[
	Frontlines (working title) - profile, rewards and shop UI.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))
local metaEvent = Shared:WaitForChild("Meta")
local metaFn = Shared:WaitForChild("MetaFn")
local DeviceLayout = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("DeviceLayout"))
-- Same look as the main menu (OpenFront home screen tokens): MenuKit.
local MenuKit = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("MenuKit"))

local FONT = MenuKit.F.MEDIUM
local FONT_BOLD = MenuKit.F.BOLD
local PANEL = MenuKit.C.ZINC900 -- nav / footer bg-zinc-900/90
local ACCENT = MenuKit.C.MALIBU
local GOLD = MenuKit.C.CYBER

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

local function corner(parent, r)
	make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.TextSize = props.TextSize or 15
	return make("TextLabel", props)
end

local function button(props)
	props.BackgroundColor3 = props.BackgroundColor3 or ACCENT
	props.BorderSizePixel = 0
	props.FontFace = props.FontFace or FONT_BOLD
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.TextSize = props.TextSize or 15
	local b = make("TextButton", props)
	corner(b, 6)
	return b
end

local gui = make("ScreenGui", {
	Name = "FrontlinesMeta",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 20, -- above the main menu (10) so shop/stats/toasts open on top of it
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = localPlayer:WaitForChild("PlayerGui"),
})

local profile = nil

-- Profile chip (top-left)
local chip = make("Frame", { Name = "ProfileChip", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(250, 92), BackgroundColor3 = PANEL, BackgroundTransparency = 0.1, BorderSizePixel = 0, Active = true, Parent = gui })
corner(chip, 12)
MenuKit.stroke(chip, 0.9)
local levelText = label({ Position = UDim2.fromOffset(12, 8), Size = UDim2.fromOffset(150, 20), FontFace = FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = "Level 1", Parent = chip })
local coinsText = label({ Position = UDim2.new(1, -112, 0, 8), Size = UDim2.fromOffset(100, 20), FontFace = FONT_BOLD, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right, Text = "0 medals", Parent = chip })
local xpBg = make("Frame", { Position = UDim2.fromOffset(12, 32), Size = UDim2.new(1, -24, 0, 8), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = chip })
corner(xpBg, 99)
local xpFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = MenuKit.C.MALIBU, BorderSizePixel = 0, Parent = xpBg })
corner(xpFill, 99)
local shopButton = button({ Position = UDim2.fromOffset(12, 50), Size = UDim2.fromOffset(110, 32), Text = "STORE", Parent = chip })
local statsButton = button({ Position = UDim2.fromOffset(128, 50), Size = UDim2.fromOffset(110, 32), BackgroundColor3 = MenuKit.C.GRAY700, Text = "STATS", Parent = chip })

-- Reward popup (rewards, level ups, daily, group): a card that drops in under the top bar with an
-- icon tile, title, one line of text, reward pills and a bar that runs down while it's shown.
local IconKit = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("IconKit"))
local TOAST_SECONDS = 4.5
local toastUi: any = {}
do
	local t = make("Frame", { Name = "RewardToast", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -160), Size = UDim2.fromOffset(420, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = MenuKit.C.GRAY900, BackgroundTransparency = 0.04, BorderSizePixel = 0, Visible = false, ClipsDescendants = true, Parent = gui })
	corner(t, 14)
	make("UISizeConstraint", { MaxSize = Vector2.new(420, 400), Parent = t })
	toastUi.stroke = make("UIStroke", { Color = GOLD, Transparency = 0.55, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = t })
	make("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 18), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 16), Parent = t })
	local tile = make("Frame", { Name = "IconTile", Size = UDim2.fromOffset(52, 52), BackgroundColor3 = GOLD, BackgroundTransparency = 0.82, BorderSizePixel = 0, Parent = t })
	corner(tile, 12)
	toastUi.tileStroke = make("UIStroke", { Color = GOLD, Transparency = 0.6, Thickness = 1, Parent = tile })
	toastUi.tile = tile
	toastUi.icon = IconKit.image("Crown", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(30, 30), ImageColor3 = GOLD, Parent = tile })
	local col = make("Frame", { Name = "Text", Position = UDim2.fromOffset(66, 0), Size = UDim2.new(1, -66, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = t })
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = col })
	toastUi.kicker = label({ LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 14), FontFace = FONT_BOLD, TextSize = 11, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = col })
	toastUi.title = label({ LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 22), FontFace = FONT_BOLD, TextSize = 19, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = col })
	toastUi.body = label({ LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 13, TextTransparency = 0.3, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = col })
	local pills = make("Frame", { Name = "Pills", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = col })
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = pills })
	make("UIPadding", { PaddingTop = UDim.new(0, 4), Parent = pills })
	toastUi.pills = pills
	local track = make("Frame", { Name = "Timer", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, -14, 1, 18), Size = UDim2.new(1, 30, 0, 3), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.92, BorderSizePixel = 0, Parent = t })
	toastUi.bar = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = GOLD, BorderSizePixel = 0, Parent = track })
	toastUi.frame = t
end

local toastQueue = {}
local toastBusy = false

-- opts: { kicker = "DAILY REWARD", icon = IconKit name, color = Color3, pills = { { text, icon?, color? } } }
local function renderToast(title: string, body: string, opts: any)
	local color = opts.color or GOLD
	toastUi.kicker.Text = string.upper(opts.kicker or "")
	toastUi.kicker.Visible = (opts.kicker or "") ~= ""
	toastUi.kicker.TextColor3 = color
	toastUi.title.Text = title
	toastUi.body.Text = body
	toastUi.body.Visible = body ~= ""
	toastUi.stroke.Color = color
	toastUi.tile.BackgroundColor3 = color
	toastUi.tileStroke.Color = color
	IconKit.set(toastUi.icon, opts.icon or "Crown")
	toastUi.icon.ImageColor3 = color
	toastUi.bar.BackgroundColor3 = color
	for _, c in toastUi.pills:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	toastUi.pills.Visible = opts.pills ~= nil and #opts.pills > 0
	for i, pill in opts.pills or {} do
		local pc = pill.color or color
		local f = make("Frame", { LayoutOrder = i, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = pc, BackgroundTransparency = 0.84, BorderSizePixel = 0, Parent = toastUi.pills })
		corner(f, 13)
		make("UIStroke", { Color = pc, Transparency = 0.55, Thickness = 1, Parent = f })
		make("UIPadding", { PaddingLeft = UDim.new(0, if pill.icon then 6 else 10), PaddingRight = UDim.new(0, 10), Parent = f })
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
		if pill.icon then
			IconKit.image(pill.icon, { LayoutOrder = 1, Size = UDim2.fromOffset(16, 16), ImageColor3 = pc, Parent = f })
		end
		label({ LayoutOrder = 2, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 13, TextColor3 = pc, Text = pill.text, Parent = f })
	end
end

local function showToast(title: string, body: string, opts: any?)
	table.insert(toastQueue, { title, body, opts or {} })
	if toastBusy then
		return
	end
	toastBusy = true
	task.spawn(function()
		local t = toastUi.frame
		while #toastQueue > 0 do
			local item = table.remove(toastQueue, 1)
			renderToast(item[1], item[2], item[3])
			t.Visible = true -- hidden while idle: on scaled/TV layouts the off-screen spot can peek in
			toastUi.bar.Size = UDim2.fromScale(1, 1)
			TweenService:Create(t, TweenInfo.new(0.4, Enum.EasingStyle.Back), { Position = UDim2.new(0.5, 0, 0, 96) }):Play()
			TweenService:Create(toastUi.bar, TweenInfo.new(TOAST_SECONDS, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) }):Play()
			task.wait(TOAST_SECONDS)
			TweenService:Create(t, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.new(0.5, 0, 0, -160) }):Play()
			task.wait(0.35)
		end
		t.Visible = false
		toastBusy = false
	end)
end

-- Store / stats window: an OpenFront o-modal (MenuKit.modal) showing the same pages as the
-- main menu (MenuPages "store" and "profile"), so the store looks identical everywhere.
local MenuPages = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("MenuPages"))
local modal = MenuKit.modal(gui, "MetaWindow")
local window = modal.holder -- "MetaWindow": MainMenu / PauseMenu watch its Visible
local currentTab = "shop"

local pageCtx = {
	toast = function(_msg: string) end,
	startTutorial = function()
		modal.close()
		localPlayer.PlayerGui:SetAttribute("FrontlinesTutorial", true)
	end,
	getProfile = function()
		return profile
	end,
	close = function()
		modal.close()
	end,
}

local function render()
	if not window.Visible then
		return
	end
	MenuPages.render(if currentTab == "shop" then "store" else "profile", modal.page, pageCtx)
end

local function selectInWindow()
	if not window.Visible or not DeviceLayout.usingGamepad() then
		return
	end
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(window) then
		return
	end
	task.defer(function()
		if window.Visible then
			GuiService.SelectedObject = modal.page:firstSelectable()
		end
	end)
end

local function openTab(tab: string)
	if window.Visible and currentTab == tab then
		modal.close()
		return
	end
	currentTab = tab
	modal.open()
	render()
	selectInWindow()
end

shopButton.Activated:Connect(function()
	openTab("shop")
end)
statsButton.Activated:Connect(function()
	openTab("stats")
end)

-- Devices: gamepad (B closes, LB/RB switch the page's tab) and per-device layout
local WINDOW_ACTION = "FrontlinesMetaWindow"
window:GetPropertyChangedSignal("Visible"):Connect(function()
	if window.Visible then
		ContextActionService:BindActionAtPriority(WINDOW_ACTION, function(_name, inputState, input)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.ButtonB or k == Enum.KeyCode.ButtonSelect then
				modal.close() -- View/Select is the console menu button (Start belongs to Roblox)
			elseif k == Enum.KeyCode.ButtonL1 or k == Enum.KeyCode.ButtonR1 then
				local page = modal.page
				local tabs = page.tabs
				local idx = 1
				for i, t in tabs do
					if t.key == page.active then
						idx = i
					end
				end
				if #tabs > 0 then
					idx = (idx - 1 + (if k == Enum.KeyCode.ButtonR1 then 1 else -1)) % #tabs + 1
					page:selectTab(tabs[idx].key)
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 50, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1, Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonSelect)
		selectInWindow()
	else
		ContextActionService:UnbindAction(WINDOW_ACTION)
	end
end)

-- Esc closes it (BaseModal closes on Escape).
game:GetService("UserInputService").InputBegan:Connect(function(input)
	if window.Visible and input.KeyCode == Enum.KeyCode.Escape then
		modal.close()
	end
end)

-- The main menu / pause menu open these windows through this hook:
-- Open:Fire("shop" | "stats" | "close").
local openEvent = Instance.new("BindableEvent")
openEvent.Name = "Open"
openEvent.Parent = gui
openEvent.Event:Connect(function(tab: string)
	if tab == "close" then
		modal.close()
	elseif tab == "shop" or tab == "stats" then
		currentTab = tab
		modal.open()
		render()
		selectInWindow()
	end
end)

local function applyMetaLayout()
	local st = DeviceLayout.state
	local phone = st.profile == "phone"
	local s = if st.profile == "console" then st.scale else 1

	if phone then
		local w, h = DeviceLayout.PHONE_CHIP_WIDTH, DeviceLayout.PHONE_CHIP_HEIGHT
		chip.AnchorPoint = Vector2.new(1, 0) -- top-right: the leaderboard owns the top-left
		chip.Position = UDim2.new(1, -6, 0, 6)
		chip.Size = UDim2.fromOffset(w, h)
		levelText.Position, levelText.Size, levelText.TextSize = UDim2.fromOffset(8, 4), UDim2.fromOffset(100, 16), 13
		coinsText.Position, coinsText.Size, coinsText.TextSize = UDim2.fromOffset(8, 21), UDim2.fromOffset(100, 14), 12
		coinsText.TextXAlignment = Enum.TextXAlignment.Left
		xpBg.Position, xpBg.Size = UDim2.fromOffset(8, 39), UDim2.fromOffset(96, 5)
		shopButton.Position, shopButton.Size = UDim2.fromOffset(112, 5), UDim2.fromOffset(58, 40)
		statsButton.Position, statsButton.Size = UDim2.fromOffset(174, 5), UDim2.new(1, -180, 0, 40)
		shopButton.TextSize, statsButton.TextSize = 14, 14
		DeviceLayout.setScale(chip, 1)

		DeviceLayout.setScale(toastUi.frame, 0.75)
	else
		chip.AnchorPoint = Vector2.new(1, 0) -- top-right: the leaderboard owns the top-left
		chip.Position = UDim2.new(1, -12, 0, 12)
		chip.Size = UDim2.fromOffset(250, 92)
		levelText.Position, levelText.Size, levelText.TextSize = UDim2.fromOffset(12, 8), UDim2.fromOffset(150, 20), 15
		coinsText.Position, coinsText.Size, coinsText.TextSize = UDim2.new(1, -112, 0, 8), UDim2.fromOffset(100, 20), 15
		coinsText.TextXAlignment = Enum.TextXAlignment.Right
		xpBg.Position, xpBg.Size = UDim2.fromOffset(12, 32), UDim2.new(1, -24, 0, 8)
		shopButton.Position, shopButton.Size = UDim2.fromOffset(12, 50), UDim2.fromOffset(110, 32)
		statsButton.Position, statsButton.Size = UDim2.fromOffset(128, 50), UDim2.fromOffset(110, 32)
		shopButton.TextSize, statsButton.TextSize = 15, 15
		DeviceLayout.setScale(chip, s)

		DeviceLayout.setScale(toastUi.frame, s)
	end
	if window.Visible then
		modal.layout()
	end
	selectInWindow()
end
DeviceLayout.attachScreenGui(gui)
DeviceLayout.Changed:Connect(applyMetaLayout)
applyMetaLayout()

-- Server messages
local function applyProfile(p)
	if not p then
		return
	end
	profile = p
	levelText.Text = (if p.vip then "VIP · " else "") .. "Level " .. p.level
	coinsText.Text = p.coins .. " medals"
	xpFill.Size = UDim2.fromScale(math.clamp(p.xpInto / math.max(1, p.xpNeed), 0, 1), 1)
	if currentTab == "stats" then
		render()
	end
end

metaEvent.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "profile" then
		applyProfile(data)
	elseif kind == "reward" then
		local place = data.placement
		local suffix = if place == 1 then "st" elseif place == 2 then "nd" elseif place == 3 then "rd" else "th"
		local title = if data.won then "Victory!" else string.format("You placed %d%s", place, suffix)
		showToast(title, if data.vip then "VIP bonus included." else "", {
			kicker = "Match rewards",
			icon = if data.won then "Crown" else "Leaderboard",
			pills = { { text = "+" .. data.xp .. " XP", color = MenuKit.C.MALIBU }, { text = "+" .. data.coins .. " medals", icon = "Gold" } },
		})
	elseif kind == "levelUp" then
		showToast("Level " .. data, "New colours may be unlocked in the store.", { kicker = "Level up", icon = "UpperLimit", color = MenuKit.C.MALIBU })
	elseif kind == "daily" then
		showToast("Day " .. data.day .. " streak", "Come back tomorrow to keep your streak going.", {
			kicker = "Daily reward",
			icon = "Gold",
			pills = { { text = "+" .. data.coins .. " medals", icon = "Gold" } },
		})
	elseif kind == "group" and type(data) == "table" then
		local pills = {}
		if (tonumber(data.medals) or 0) > 0 then
			pills[#pills + 1] = { text = "+" .. data.medals .. " medals", icon = "Gold" }
		end
		if type(data.boost) == "string" then
			local b = MetaConfig.boost(data.boost)
			pills[#pills + 1] = { text = "+1 " .. (if b then b.name else "boost"), icon = if b then b.icon else "Gold", color = MenuKit.C.MALIBU }
		end
		showToast("Thanks for being in the group!", if data.boost then "A new free boost every day you play." else "", {
			kicker = MetaConfig.GROUP.name .. " reward",
			icon = "Alliance",
			color = Color3.fromRGB(20, 205, 185),
			pills = pills,
		})
	end
end)

task.spawn(function()
	local ok, success, p = pcall(function()
		return metaFn:InvokeServer("get")
	end)
	if ok and success then
		applyProfile(p)
	end
end)
