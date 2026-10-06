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

--------------------------------------------------------------------------------
-- Profile chip (top-left)
--------------------------------------------------------------------------------
local chip = make("Frame", { Name = "ProfileChip", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(250, 92), BackgroundColor3 = PANEL, BackgroundTransparency = 0.1, BorderSizePixel = 0, Active = true, Parent = gui })
corner(chip, 12)
MenuKit.stroke(chip, 0.9)
local levelText = label({ Position = UDim2.fromOffset(12, 8), Size = UDim2.fromOffset(150, 20), FontFace = FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = "Level 1", Parent = chip })
local coinsText = label({ Position = UDim2.new(1, -112, 0, 8), Size = UDim2.fromOffset(100, 20), FontFace = FONT_BOLD, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right, Text = "0 coins", Parent = chip })
local xpBg = make("Frame", { Position = UDim2.fromOffset(12, 32), Size = UDim2.new(1, -24, 0, 8), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = chip })
corner(xpBg, 99)
local xpFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = MenuKit.C.MALIBU, BorderSizePixel = 0, Parent = xpBg })
corner(xpFill, 99)
local shopButton = button({ Position = UDim2.fromOffset(12, 50), Size = UDim2.fromOffset(110, 32), Text = "STORE", Parent = chip })
local statsButton = button({ Position = UDim2.fromOffset(128, 50), Size = UDim2.fromOffset(110, 32), BackgroundColor3 = MenuKit.C.GRAY700, Text = "STATS", Parent = chip })

--------------------------------------------------------------------------------
-- Toast (rewards, level ups, daily)
--------------------------------------------------------------------------------
local toast = make("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -140), Size = UDim2.fromOffset(380, 110), BackgroundColor3 = PANEL, BorderSizePixel = 0, Visible = false, Parent = gui })
corner(toast, 10)
make("UIStroke", { Color = GOLD, Thickness = 2, Parent = toast })
local toastTitle = label({ Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 28), FontFace = FONT_BOLD, TextSize = 22, TextColor3 = GOLD, Text = "", Parent = toast })
local toastBody = label({ Position = UDim2.fromOffset(16, 44), Size = UDim2.new(1, -32, 0, 56), TextWrapped = true, Text = "", Parent = toast })

local toastQueue = {}
local toastBusy = false
local function showToast(title: string, body: string)
	table.insert(toastQueue, { title, body })
	if toastBusy then
		return
	end
	toastBusy = true
	task.spawn(function()
		while #toastQueue > 0 do
			local item = table.remove(toastQueue, 1)
			toastTitle.Text = item[1]
			toastBody.Text = item[2]
			toast.Visible = true -- hidden while idle: on scaled/TV layouts the off-screen spot can peek in
			TweenService:Create(toast, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Position = UDim2.new(0.5, 0, 0, 70) }):Play()
			task.wait(4)
			TweenService:Create(toast, TweenInfo.new(0.3), { Position = UDim2.new(0.5, 0, 0, -140) }):Play()
			task.wait(0.4)
		end
		toast.Visible = false
		toastBusy = false
	end)
end

--------------------------------------------------------------------------------
-- Store / stats window: an OpenFront o-modal (MenuKit.modal) showing the same pages as the
-- main menu (MenuPages "store" and "profile"), so the store looks identical everywhere.
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- Devices: gamepad (B closes, LB/RB switch the page's tab) and per-device layout
--------------------------------------------------------------------------------
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

		DeviceLayout.setScale(toast, 0.75)
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

		DeviceLayout.setScale(toast, s)
	end
	if window.Visible then
		modal.layout()
	end
	selectInWindow()
end
DeviceLayout.attachScreenGui(gui)
DeviceLayout.Changed:Connect(applyMetaLayout)
applyMetaLayout()

--------------------------------------------------------------------------------
-- Server messages
--------------------------------------------------------------------------------
local function applyProfile(p)
	if not p then
		return
	end
	profile = p
	levelText.Text = (if p.vip then "VIP · " else "") .. "Level " .. p.level
	coinsText.Text = p.coins .. " coins"
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
		showToast(title, string.format("+%d XP   +%d coins%s", data.xp, data.coins, if data.vip then "  (VIP bonus)" else ""))
	elseif kind == "levelUp" then
		showToast("Level up!", "You reached level " .. data .. ". New colours may be unlocked in the shop.")
	elseif kind == "daily" then
		showToast("Daily reward - day " .. data.day, string.format("+%d coins. Come back tomorrow to keep your streak!", data.coins))
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
