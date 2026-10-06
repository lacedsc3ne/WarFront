--[[
	Frontlines (working title) - defeat screen (free revive / new country / watch / leave).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.DefeatScreen (ModuleScript), set up by GameClient.
-- Listens on Shared.Net for "defeated", "revived", "reviveDenied", "shields", "init", "me",
-- "phase" and sends "revive" / "newCountry" / "leave" / "buyRevive" (see ServerScriptService.Revive).
-- EXIT GAME fires PlayerGui.FrontlinesMenuShow (BindableEvent; MainMenu listens and shows itself).
-- The first revive of a round is free. After that REVIVE turns into a bought revive
-- (MetaConfig.REVIVE): it spends an Extra Revive you own ("x2" badge), or buys one with Robux (the
-- server revives you as soon as the purchase goes through) or, while the product has no id, coins.
-- Look: OpenFront's WinModal as it shows on death ("You died"): bg-gray-800/70 rounded-lg panel,
-- 26 px title, bg-black/30 content box, a row of o-button primaries (malibu-blue -> aquarius,
-- rounded-xl, bold uppercase). Revive / new country are War Front additions in the same row.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local SimClock = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SimClock")) -- game clock (speed / pause)
local MarketplaceService = game:GetService("MarketplaceService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MetaConfig = require(Shared:WaitForChild("MetaConfig"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))

local DefeatScreen = {}

local FONT = MenuKit.F.REGULAR
local FONT_BOLD = MenuKit.F.BOLD
local FONT_BLACK = MenuKit.F.BOLD
local K = MenuKit.C
local C = {
	NAVY = K.GRAY800, -- WinModal bg-gray-800/70
	NAVY_LIGHT = K.SURFACE, -- secondary action card bg-surface
	BLUE = K.MALIBU, -- --color-malibu-blue
	BLUE_DARK = K.AQUARIUS,
	YELLOW = K.CYBER, -- --color-cyber-yellow
	SLATE = K.WHITE,
	GRAY = K.GRAY300,
	GRAY_DARK = K.GRAY600, -- o-button disabled:bg-gray-600
	RED = K.RED500,
	WHITE = K.WHITE,
}

local B_ACTION = "FrontlinesDefeatB"
local UP_ACTION = "FrontlinesDefeatUp"

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

local function corner(parent: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function short(n: number): string
	if n >= 1e6 then
		return (string.format("%.1fM", n / 1e6):gsub("%.0M", "M"))
	elseif n >= 1e3 then
		return (string.format("%.1fK", n / 1e3):gsub("%.0K", "K"))
	end
	return tostring(math.floor(n))
end

-- State
local net: RemoteEvent
local focusTile: ((number) -> ())? = nil
local myId = 0
local info: any = nil -- last "defeated" payload
local mode = "hidden" -- hidden | panel | watching
local shields: { [number]: number } = {} -- player id -> server time the shield ends
local busy = false -- request sent, waiting for the server
local buy = { tokens = 0, price = nil :: number?, phase = "Lobby" } -- Extra Revives owned, Robux price, round phase

-- GUI
local gui = make("ScreenGui", {
	Name = "FrontlinesDefeat",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 8, -- above the match HUD, below the main menu (9/10) and shop (20)
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

-- WinModal.ts panel: fixed centre, bg-gray-800/70, p-4 md:p-6, rounded-lg, shadow-2xl,
-- w-[min(90vw,700px)]; h2 26 px title; content box bg-black/30 p-2.5 rounded-sm (h3 text-xl
-- font-semibold, p text-white); a row of o-button primaries (flex-1, gap-2.5).
local card = make("Frame", {
	Name = "DefeatCard",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(640, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = C.NAVY,
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Active = true,
	Visible = false,
	Parent = gui,
})
corner(card, 8)
local cardScale = make("UIScale", { Parent = card })
local cardPad = make("UIPadding", {
	PaddingTop = UDim.new(0, 24),
	PaddingBottom = UDim.new(0, 24),
	PaddingLeft = UDim.new(0, 24),
	PaddingRight = UDim.new(0, 24),
	Parent = card,
})
make("UIListLayout", {
	SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	Padding = UDim.new(0, 16),
	Parent = card,
})

local title = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundTransparency = 1,
	FontFace = FONT,
	Text = "You died", -- win_modal.died
	TextColor3 = C.WHITE,
	TextSize = 26,
	LayoutOrder = 1,
	Parent = card,
})

-- Content box (bg-black/30 p-2.5 rounded-sm text-center).
local box = make("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.7,
	BorderSizePixel = 0,
	LayoutOrder = 2,
	Parent = card,
})
corner(box, 2)
make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = box })
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 12), Parent = box })

local subtitle = make("TextLabel", { -- h3 text-xl font-semibold
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	FontFace = FONT_BOLD,
	Text = "",
	TextColor3 = C.WHITE,
	TextSize = 20,
	TextWrapped = true,
	LayoutOrder = 1,
	Parent = box,
})

local reviveDetail = make("TextLabel", { -- p text-white
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	FontFace = FONT,
	Text = "",
	TextColor3 = C.WHITE,
	TextSize = 16,
	TextWrapped = true,
	LayoutOrder = 2,
	Parent = box,
})

local footer = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	FontFace = FONT,
	Text = "",
	TextColor3 = C.GRAY,
	TextSize = 13,
	TextWrapped = true,
	LayoutOrder = 3,
	Parent = box,
})

-- Button row (mt-4 flex justify-between gap-2.5).
local row = make("Frame", {
	Size = UDim2.new(1, 0, 0, 48),
	BackgroundTransparency = 1,
	LayoutOrder = 3,
	Parent = card,
})
local rowLayout = make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 10),
	Parent = row,
})

-- o-button variant="primary" width="block": bg-malibu-blue hover:bg-aquarius, rounded-xl,
-- font-bold uppercase tracking-wider, py-3 px-4 text-base; disabled:bg-gray-600 text-gray-300.
local function oButton(text: string, order: number): (TextButton, TextLabel)
	local b = make("TextButton", {
		Size = UDim2.new(0.25, -8, 1, 0),
		BackgroundColor3 = C.BLUE,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = order,
		Parent = row,
	}) :: TextButton
	corner(b, 12)
	b:SetAttribute("Base", C.BLUE)
	MenuKit.hover(b, function(s)
		local base = b:GetAttribute("Base") or C.BLUE
		if b.Selectable == false or base ~= C.BLUE then
			b.BackgroundColor3 = base
		else
			b.BackgroundColor3 = if s == "idle" then C.BLUE elseif s == "press" then C.BLUE:Lerp(Color3.new(), 0.2) else C.BLUE_DARK
		end
	end)
	local l = make("TextLabel", {
		Size = UDim2.new(1, -8, 1, 0),
		Position = UDim2.fromOffset(4, 0),
		BackgroundTransparency = 1,
		FontFace = FONT_BOLD,
		Text = text,
		TextColor3 = C.WHITE,
		TextSize = 16,
		TextWrapped = true,
		Parent = b,
	}) :: TextLabel
	return b, l
end

local leaveBtn, leaveLabel = oButton("EXIT GAME", 1) -- win_modal.exit
local newBtn, newLabel = oButton("NEW COUNTRY", 2)
local reviveBtn, reviveTitle = oButton("REVIVE", 3)
local watchBtn, watchLabel = oButton("SPECTATE", 4) -- win_modal.spectate
local freeBadge = make("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -4, 0, 4),
	Size = UDim2.fromOffset(0, 14),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = C.YELLOW,
	BorderSizePixel = 0,
	FontFace = FONT_BLACK,
	Text = "FREE",
	TextColor3 = K.GRAY900,
	TextSize = 10,
	Parent = reviveBtn,
})
corner(freeBadge, 4)
make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), Parent = freeBadge })

-- Spectating pill (bottom centre): brings the options back.
local pill = make("TextButton", {
	Name = "SpectatePill",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -128),
	Size = UDim2.fromOffset(0, 40),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = C.NAVY,
	BackgroundTransparency = 0.08,
	BorderSizePixel = 0,
	FontFace = FONT_BOLD,
	Text = "",
	RichText = true,
	TextColor3 = C.WHITE,
	TextSize = 15,
	Visible = false,
	Parent = gui,
})
corner(pill, 8)
stroke(pill, C.WHITE, 1, 0.9)
make("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18), Parent = pill })

-- Own spawn shield countdown (top centre, under the banner).
-- Shield badge: shield icon, "Protected" + countdown, and a bar that drains as it runs out.
local SKY = Color3.fromRGB(125, 211, 252) -- sky-300
local shieldPill = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 92),
	Size = UDim2.fromOffset(0, 36),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = C.NAVY,
	BackgroundTransparency = 0.08,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Visible = false,
	Parent = gui,
})
corner(shieldPill, 8)
stroke(shieldPill, SKY, 1, 0.5)
local shieldRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, Parent = shieldPill })
make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 12), Parent = shieldRow })
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = shieldRow })
require(script.Parent:WaitForChild("IconKit")).image("Defense", { Size = UDim2.fromOffset(20, 20), ImageColor3 = SKY, LayoutOrder = 1, Parent = shieldRow })
local shieldText = make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = C.WHITE, Text = "Protected", LayoutOrder = 2, Parent = shieldRow })
local shieldTime = make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = SKY, Text = "", LayoutOrder = 3, Parent = shieldRow })
local shieldBar = make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = SKY, BorderSizePixel = 0, Parent = shieldPill })
make("UIGradient", { Parent = shieldBar }) -- (Transparency drives the drain, see updateShieldPill)
local shieldSpan = { ends = 0, len = 1 }

DeviceLayout.attachScreenGui(gui)

-- Layout per device
local function layout()
	local profile = DeviceLayout.state.profile
	local screen = gui.AbsoluteSize
	-- w-[min(90vw,700px)] max-w-[90%]; p-4 below md, p-6 from md.
	local width = math.min(700, math.floor(screen.X * 0.9))
	local scale = 1
	if profile == "phone" then
		width = math.max(260, screen.X - 32)
		-- Landscape phones are short: shrink the whole card to fit.
		scale = math.clamp((screen.Y - 24) / 320, 0.7, 1)
	elseif profile == "console" then
		scale = DeviceLayout.state.scale or 1.2
		width = math.min(width, math.floor(screen.X * 0.9 / scale))
	end
	card.Size = UDim2.fromOffset(width, 0)
	cardScale.Scale = scale
	local pad = if screen.X < 768 then 16 else 24
	cardPad.PaddingTop = UDim.new(0, pad)
	cardPad.PaddingBottom = UDim.new(0, pad)
	cardPad.PaddingLeft = UDim.new(0, pad)
	cardPad.PaddingRight = UDim.new(0, pad)
	local compact = width < 480
	local ts = if compact then 12 else 16 -- text-base (lg:text-lg on o-button md stays 16 here)
	newLabel.TextSize = ts
	watchLabel.TextSize = ts
	leaveLabel.TextSize = ts
	reviveTitle.TextSize = ts
	row.Size = UDim2.new(1, 0, 0, if compact then 44 else 48)
	pill.Position = UDim2.new(0.5, 0, 1, if profile == "phone" then -96 else -128)
	pill.TextSize = if profile == "console" then 18 else 15
	rowLayout.Padding = UDim.new(0, if compact then 6 else 10)
end

-- Show / hide
local function menuOpen(): boolean
	return playerGui:GetAttribute("FrontlinesMenuOpen") == true
end

local function clearSelection()
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
end

local function canComeBack(): boolean
	return info ~= nil and info.canRevive == true and not busy
end

-- Free revives are used up, but one can be bought (or an owned Extra Revive spent).
local function canBuy(): boolean
	return info ~= nil and info.canRevive ~= true and info.canBuy == true and not busy
end

local function buyBadge(): string
	if buy.tokens > 0 then
		return "x" .. buy.tokens
	elseif MetaConfig.REVIVE.id ~= 0 then
		return if buy.price then "R$ " .. buy.price else "R$"
	end
	return short(MetaConfig.REVIVE.coins) .. " medals"
end

local function render()
	local canRevive = canComeBack()
	local buyable = canBuy()
	local troops, gold, secs = 0, 0, 0
	if info then
		troops, gold, secs = info.reviveTroops or 0, info.reviveGold or 0, info.shieldSeconds or 0
		subtitle.Text = if info.by then "Your land was taken by " .. info.by else "Your country has fallen"
	end
	if canRevive or buyable then
		reviveDetail.Text = string.format("%s troops  ·  %s gold  ·  %ds shield", short(troops), short(gold), secs)
	elseif busy then
		reviveDetail.Text = "Finding free land..."
	else
		reviveDetail.Text = (info and info.reason) or "Not available"
	end
	-- o-button disabled: bg-gray-600 text-gray-300 opacity-70
	local on = canRevive or buyable or busy
	reviveBtn.BackgroundColor3 = if on then C.BLUE else C.GRAY_DARK
	reviveBtn:SetAttribute("Base", reviveBtn.BackgroundColor3)
	reviveBtn.Selectable = canRevive or buyable
	reviveBtn.BackgroundTransparency = if on then 0 else 0.3
	reviveTitle.TextColor3 = if on then C.WHITE else C.GRAY
	freeBadge.Visible = canRevive or buyable
	freeBadge.Text = if canRevive then "FREE" else buyBadge()
	freeBadge.BackgroundColor3 = if canRevive then C.YELLOW elseif buy.tokens > 0 then K.EMERALD300 else K.EMERALD500
	newBtn.BackgroundColor3 = if canRevive then C.BLUE else C.GRAY_DARK
	newBtn:SetAttribute("Base", newBtn.BackgroundColor3)
	newBtn.Selectable = canRevive
	newBtn.BackgroundTransparency = if canRevive then 0 else 0.3
	newLabel.TextColor3 = if canRevive then C.WHITE else C.GRAY

	local gamepad = DeviceLayout.usingGamepad()
	local parts = {}
	if info and canRevive then
		parts[1] = "New country starts far away and also uses your revive"
	elseif info and buyable then
		local left = tonumber(info.buyLeft) or 0
		parts[1] = "Free revives used. Buy up to " .. left .. " more this round"
	end
	if gamepad then
		parts[#parts + 1] = "B  Spectate"
	end
	footer.Text = table.concat(parts, "   ·   ")
	footer.Visible = #parts > 0

	local gp = if gamepad then '<font color="#ffd700">D-pad up</font>  ' else ""
	pill.Text = gp .. "SPECTATING  ·  " .. (if canRevive or buyable then '<font color="#ffd700">REVIVE</font>' else "OPTIONS")
end

local function bindKeys()
	ContextActionService:UnbindAction(B_ACTION)
	ContextActionService:UnbindAction(UP_ACTION)
	if mode == "panel" then
		ContextActionService:BindActionAtPriority(B_ACTION, function(_n, inputState)
			if inputState == Enum.UserInputState.Begin and mode == "panel" and not menuOpen() then
				DefeatScreen.watch()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value + 5, Enum.KeyCode.ButtonB)
	elseif mode == "watching" then
		ContextActionService:BindActionAtPriority(UP_ACTION, function(_n, inputState)
			if inputState == Enum.UserInputState.Begin and mode == "watching" and not menuOpen() and GuiService.SelectedObject == nil then
				DefeatScreen.showPanel()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value + 5, Enum.KeyCode.DPadUp)
	end
end

local function selectDefault()
	if mode ~= "panel" or not DeviceLayout.usingGamepad() or menuOpen() then
		return
	end
	task.defer(function()
		if mode ~= "panel" then
			return
		end
		local target = if reviveBtn.Selectable then reviveBtn elseif newBtn.Selectable then newBtn else watchBtn
		GuiService.SelectedObject = target
	end)
end

local function apply()
	gui.Enabled = not menuOpen()
	card.Visible = mode == "panel"
	pill.Visible = mode == "watching"
	if mode ~= "panel" then
		clearSelection()
	end
	render()
	bindKeys()
end

function DefeatScreen.showPanel()
	if info == nil then
		return
	end
	mode = "panel"
	apply()
	card.Position = UDim2.new(0.5, 0, 0.5, 24)
	TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(0.5, 0.5),
	}):Play()
	selectDefault()
end

function DefeatScreen.watch()
	if info == nil then
		return
	end
	mode = "watching"
	apply()
end

function DefeatScreen.hide()
	mode = "hidden"
	info = nil
	busy = false
	apply()
end

local function request(kind: string)
	if not canComeBack() then
		return
	end
	busy = true
	render()
	net:FireServer(kind)
	-- If the server never answers (e.g. the round ended), let the player try again.
	task.delay(4, function()
		if busy then
			busy = false
			render()
		end
	end)
end

local function leave()
	net:FireServer("leave")
	DefeatScreen.hide()
	local ev = playerGui:FindFirstChild("FrontlinesMenuShow")
	if not ev then
		ev = Instance.new("BindableEvent")
		ev.Name = "FrontlinesMenuShow"
		ev.Parent = playerGui
	end
	if ev:IsA("BindableEvent") then
		ev:Fire()
	end
end

-- Bought revive: spend an owned Extra Revive, else buy one (Robux; coins while there's no product).
local function buyRevive()
	if not canBuy() then
		return
	end
	busy = true
	render()
	local function done()
		task.delay(6, function()
			if busy then
				busy = false
				render()
			end
		end)
	end
	if buy.tokens > 0 then
		net:FireServer("buyRevive")
		done()
	elseif MetaConfig.REVIVE.id ~= 0 then
		busy = false -- the purchase prompt is up; the server revives us when it's paid
		render()
		MarketplaceService:PromptProductPurchase(localPlayer, MetaConfig.REVIVE.id)
	else
		task.spawn(function()
			local ok, success, msg = pcall(function()
				return Shared:WaitForChild("MetaFn"):InvokeServer("buyBoost", MetaConfig.REVIVE.key)
			end)
			if ok and success then
				net:FireServer("buyRevive")
				done()
			else
				busy = false
				if info then
					reviveDetail.Text = if ok and type(msg) == "string" then msg else "Couldn't buy a revive"
				end
				task.delay(2.5, render)
			end
		end)
	end
end

reviveBtn.Activated:Connect(function()
	if canComeBack() then
		request("revive")
	else
		buyRevive()
	end
end)
newBtn.Activated:Connect(function()
	request("newCountry")
end)
watchBtn.Activated:Connect(DefeatScreen.watch)
leaveBtn.Activated:Connect(leave)
pill.Activated:Connect(DefeatScreen.showPanel)

-- Shields
-- Prefix for a player's map name label while their spawn shield is up.
function DefeatScreen.shieldTag(id: number): string
	local ends = shields[id]
	if ends and ends > SimClock.now() then
		return "🛡 "
	end
	return ""
end

function DefeatScreen.isShielded(id: number): boolean
	return DefeatScreen.shieldTag(id) ~= ""
end

local function updateShieldPill()
	local ends = shields[myId]
	local left = if ends then ends - SimClock.now() else 0
	if left > 0 and buy.phase == "Play" then
		local s = math.ceil(left)
		if math.abs(ends - shieldSpan.ends) > 0.5 then
			shieldSpan.ends, shieldSpan.len = ends, math.max(left, 1) -- a new or extended shield
		end
		shieldText.Text = "Protected from attacks"
		shieldTime.Text = string.format("%d:%02d", s // 60, s % 60)
		-- Drain the bar from the right: hide the part past the remaining fraction.
		local f = math.clamp(left / shieldSpan.len, 0, 1)
		shieldBar:FindFirstChildOfClass("UIGradient").Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(math.clamp(f, 0.001, 0.998), 0),
			NumberSequenceKeypoint.new(math.clamp(f + 0.001, 0.002, 0.999), 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		shieldPill.Visible = true
	else
		shieldPill.Visible = false
	end
end

-- Setup
-- opts: { net: RemoteEvent, focusTile: ((tile: number) -> ())? }
function DefeatScreen.setup(opts)
	net = opts.net
	focusTile = opts.focusTile

	net.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "init" then
			myId = if type(data) == "table" then tonumber(data.myId) or 0 else 0
			if type(data) == "table" and type(data.phase) == "table" then
				buy.phase = data.phase.phase or buy.phase
			end
			table.clear(shields)
			DefeatScreen.hide()
		elseif kind == "me" then
			if type(data) == "table" and tonumber(data.id) then
				myId = data.id
			end
		elseif kind == "phase" then
			if type(data) == "table" then
				buy.phase = data.phase or buy.phase
			end
			if type(data) == "table" and data.phase ~= "Play" and mode ~= "hidden" then
				DefeatScreen.hide()
			end
			updateShieldPill()
		elseif kind == "defeated" then
			if type(data) == "table" then
				info = data
				busy = false
				DefeatScreen.showPanel()
			end
		elseif kind == "reviveDenied" then
			busy = false
			if info and type(data) == "table" then
				info.canRevive = false
				info.reason = data.reason
				info.canBuy = data.canBuy == true and info.canBuy == true
			end
			render()
			selectDefault()
		elseif kind == "revived" then
			DefeatScreen.hide()
			if focusTile and type(data) == "table" and type(data.tile) == "number" then
				focusTile(data.tile)
			end
		elseif kind == "left" then
			DefeatScreen.hide()
		elseif kind == "shields" then
			table.clear(shields)
			if type(data) == "table" then
				for _, e in data do
					if type(e) == "table" and type(e[1]) == "number" and type(e[2]) == "number" then
						shields[e[1]] = e[2]
					end
				end
			end
			updateShieldPill()
		end
	end)

	playerGui:GetAttributeChangedSignal("FrontlinesMenuOpen"):Connect(function()
		apply()
		if not menuOpen() then
			selectDefault()
		end
	end)
	DeviceLayout.Changed:Connect(function()
		layout()
		render()
		if mode == "panel" and GuiService.SelectedObject == nil then
			selectDefault()
		end
	end)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	layout()
	apply()

	-- Extra Revives owned (profile.boosts.revive) and the product's Robux price.
	local function setTokens(boosts: any)
		if type(boosts) == "table" then
			buy.tokens = tonumber(boosts[MetaConfig.REVIVE.key]) or 0
			render()
		end
	end
	Shared:WaitForChild("Meta").OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "profile" and type(data) == "table" then
			setTokens(data.boosts)
		end
	end)
	task.spawn(function()
		local ok, success, p = pcall(function()
			return Shared:WaitForChild("MetaFn"):InvokeServer("get")
		end)
		if ok and success and type(p) == "table" then
			setTokens(p.boosts)
		end
		if MetaConfig.REVIVE.id ~= 0 then
			local okInfo, pinfo = pcall(function()
				return MarketplaceService:GetProductInfo(MetaConfig.REVIVE.id, Enum.InfoType.Product)
			end)
			if okInfo and type(pinfo) == "table" then
				buy.price = tonumber(pinfo.PriceInRobux)
				render()
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.5)
			updateShieldPill()
		end
	end)
end

return DefeatScreen
