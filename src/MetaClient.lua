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
local FavoriteGame = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("FavoriteGame")) -- group rewards: join + favourite
local DeviceLayout = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("DeviceLayout"))
-- Same look as the main menu (OpenFront home screen tokens): MenuKit.
local MenuKit = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("MenuKit"))

local FONT = MenuKit.F.MEDIUM
local FONT_BOLD = MenuKit.F.BOLD
local PANEL = MenuKit.C.ZINC900 -- nav / footer bg-zinc-900/90
local ACCENT = Color3.fromRGB(0, 177, 235)
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
	local t = make("Frame", { Name = "RewardToast", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -160), Size = UDim2.fromOffset(420, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = MenuKit.C.PANEL, BackgroundTransparency = 0.04, BorderSizePixel = 0, Visible = false, ClipsDescendants = true, Parent = gui })
	corner(t, 8)
	make("UISizeConstraint", { MaxSize = Vector2.new(420, 400), Parent = t })
	toastUi.stroke = make("UIStroke", { Color = ACCENT, Transparency = 0.15, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = t })
	make("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 18), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 16), Parent = t })
	local tile = make("Frame", { Name = "IconTile", Size = UDim2.fromOffset(52, 52), BackgroundColor3 = GOLD, BackgroundTransparency = 0.82, BorderSizePixel = 0, Parent = t })
	corner(tile, 6)
	toastUi.tileStroke = make("UIStroke", { Color = GOLD, Transparency = 0.6, Thickness = 1, Parent = tile })
	toastUi.tile = tile
	toastUi.icon = IconKit.image("Crown", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(30, 30), ImageColor3 = GOLD, Parent = tile })
	local col = make("Frame", { Name = "Text", Position = UDim2.fromOffset(66, 0), Size = UDim2.new(1, -66, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = t })
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = col })
	toastUi.kicker = label({ LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 14), FontFace = FONT_BOLD, TextSize = 11, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = col })
	toastUi.title = label({ LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, FontFace = FONT_BOLD, TextSize = 19, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = col }) -- wraps (long announcements)
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
local toastHook: ((any) -> ())? = nil -- Night menu: swaps in the full-colour art after each render
local toastShownAt = function(): UDim2
	return UDim2.new(0.5, 0, 0, if DeviceLayout.state.profile == "phone" then 126 else 160)
end
local toastHiddenAt = UDim2.new(0.5, 0, 0, -160)

-- opts: { kicker = "DAILY REWARD", icon = IconKit name, color = Color3, pills = { { text, icon?, color? } } }
local function renderToast(title: string, body: string, opts: any)
	local color = opts.color or GOLD
	toastUi.kicker.Text = string.upper(opts.kicker or "")
	toastUi.kicker.Visible = (opts.kicker or "") ~= ""
	toastUi.kicker.TextColor3 = ACCENT
	toastUi.title.Text = title
	toastUi.body.Text = body
	toastUi.body.Visible = body ~= ""
	toastUi.stroke.Color = ACCENT
	toastUi.tile.BackgroundColor3 = color
	toastUi.tileStroke.Color = color
	IconKit.set(toastUi.icon, opts.icon or "Crown")
	toastUi.icon.ImageColor3 = color
	toastUi.bar.BackgroundColor3 = ACCENT
	for _, c in toastUi.pills:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	toastUi.pills.Visible = opts.pills ~= nil and #opts.pills > 0
	for i, pill in opts.pills or {} do
		local pc = pill.color or color
		local f = make("Frame", { LayoutOrder = i, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = pc, BackgroundTransparency = 0.84, BorderSizePixel = 0, Parent = toastUi.pills })
		corner(f, 5)
		make("UIStroke", { Color = pc, Transparency = 0.55, Thickness = 1, Parent = f })
		make("UIPadding", { PaddingLeft = UDim.new(0, if pill.icon then 6 else 10), PaddingRight = UDim.new(0, 10), Parent = f })
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
		if pill.icon then
			IconKit.image(pill.icon, { LayoutOrder = 1, Size = UDim2.fromOffset(16, 16), ImageColor3 = pc, Parent = f })
		end
		label({ LayoutOrder = 2, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, FontFace = FONT_BOLD, TextSize = 13, TextColor3 = pc, Text = pill.text, Parent = f })
	end
	if toastHook then
		toastHook(opts)
	end
end

local function mobileDevice()
 local st=DeviceLayout.state
 return (st.touch==true or st.input=="Touch") and (st.profile=="phone" or st.profile=="tablet")
end
local function showToast(title: string, body: string, opts: any?)
 if mobileDevice() then
  local key=string.lower(title.." "..tostring(opts and opts.kicker or ""))
  if key:find("group",1,true) or key:find("rate war front",1,true) or key:find("support war front",1,true) or key:find("rating unavailable",1,true) or key:find("streak",1,true) then return end
 end
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
			TweenService:Create(t, TweenInfo.new(0.4, Enum.EasingStyle.Back), { Position = toastShownAt() }):Play()
			local seconds = item[3].seconds or TOAST_SECONDS
			TweenService:Create(toastUi.bar, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) }):Play()
			task.wait(seconds)
			TweenService:Create(t, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = toastHiddenAt }):Play()
			task.wait(0.35)
		end
		t.Visible = false
		toastBusy = false
	end)
end

-- Group rewards popup: tells players about the group rewards and lets them join without leaving
-- the game (GroupService:PromptJoinAsync). Opens once per session for non-members when the main
-- menu is up, and from the main menu's REWARDS news item (PlayerGui.FrontlinesGroupPopup).
local groupPopup: any = { shown = false, busy = false }
do
	local G = MetaConfig.GROUP
 local NAVY=Color3.fromRGB(5,22,40)
 local BORDER=Color3.fromRGB(71,145,197)
 local shade=make("Frame",{Name="GroupPopup",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Active=false,Visible=false,ZIndex=50,Parent=gui})
 local card=make("Frame",{Name="Card",AnchorPoint=Vector2.new(0,1),Position=UDim2.new(0,18,1,-18),Size=UDim2.fromOffset(420,166),BackgroundColor3=NAVY,BorderSizePixel=0,Active=true,ZIndex=50,Parent=shade})
 corner(card,6)
 make("UIStroke",{Color=BORDER,Thickness=1.5,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=card})
 local scale=make("UIScale",{Parent=card})
 local function fitPrompt()
  scale.Scale=math.min(1,math.max(.5,(gui.AbsoluteSize.X-36)/420))
 end
 gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPrompt);fitPrompt()
 IconKit.image("Alliance",{Position=UDim2.fromOffset(18,16),Size=UDim2.fromOffset(38,38),ImageColor3=ACCENT,ZIndex=51,Parent=card})
 label({Name="Heading",Position=UDim2.fromOffset(68,16),Size=UDim2.fromOffset(302,34),FontFace=Font.fromEnum(Enum.Font.GothamBlack),TextSize=23,TextXAlignment=Enum.TextXAlignment.Left,TextStrokeColor3=Color3.new(0,0,0),TextStrokeTransparency=.25,Text="JOIN OUR GROUP",ZIndex=51,Parent=card})
 make("ImageLabel",{Name="Medal",Image="rbxassetid://98450321632062",BackgroundTransparency=1,Position=UDim2.fromOffset(18,64),Size=UDim2.fromOffset(34,38),ScaleType=Enum.ScaleType.Fit,ZIndex=51,Parent=card})
 label({Name="Rewards",Position=UDim2.fromOffset(64,64),Size=UDim2.fromOffset(340,36),FontFace=FONT_BOLD,TextSize=17,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Text="Get "..G.MEDALS.." medals + daily rewards",ZIndex=51,Parent=card})
 label({Name="GroupName",Position=UDim2.fromOffset(18,118),Size=UDim2.fromOffset(146,36),TextSize=13,TextColor3=Color3.fromRGB(155,184,219),TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,Text=G.name,ZIndex=51,Parent=card})
 local join=button({Name="Join",Position=UDim2.fromOffset(178,112),Size=UDim2.fromOffset(226,38),BackgroundColor3=ACCENT,TextColor3=NAVY,FontFace=Font.fromEnum(Enum.Font.GothamBlack),TextSize=19,Text="JOIN GROUP",AutoButtonColor=false,ZIndex=51,Parent=card})
 MenuKit.stroke(join,.15,Color3.fromRGB(56,213,255),1)
 make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(0,161,220)),Parent=join})
 MenuKit.hover(join,function(st)join.BackgroundColor3=if st=="idle" then ACCENT elseif st=="press" then ACCENT:Lerp(Color3.new(0,0,0),.15) else ACCENT:Lerp(Color3.new(1,1,1),.15) end)
 local later=button({Name="Close",Position=UDim2.new(1,-36,0,10),Size=UDim2.fromOffset(26,26),BackgroundTransparency=1,TextColor3=BORDER,TextSize=23,Text="×",ZIndex=52,Parent=card})
 local status=label({Name="Status",Position=UDim2.fromOffset(18,160),Size=UDim2.fromOffset(384,38),TextSize=12,TextColor3=MenuKit.C.AMBER300,TextWrapped=true,Text="",Visible=false,ZIndex=51,Parent=card})
 status:GetPropertyChangedSignal("Visible"):Connect(function()card.Size=UDim2.fromOffset(420,if status.Visible then 206 else 166)end)
	local B_ACTION = "WFGroupPopupBack"
	local function close()
		shade.Visible = false
  groupPopup.dismissed=true
		ContextActionService:UnbindAction(B_ACTION)
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(shade) then
			GuiService.SelectedObject = nil
		end
	end
	groupPopup.close = close
	function groupPopup.open()
  if mobileDevice() then return end
		-- Group rewards need the group and a favourite: open for anyone missing either.
		if not profile or profile.groupKnown ~= true or (profile.inGroup ~= false and profile.favorited == true) then return end
		groupPopup.shown = true
  groupPopup.dismissed=false
		status.Visible = false
		join.Text = "JOIN GROUP"
		shade.Visible = true
		if DeviceLayout.usingGamepad() then
			GuiService.SelectedObject = join
		end
	end
	later.Activated:Connect(close)
	join.Activated:Connect(function()
		if groupPopup.busy then
			return
		end
		groupPopup.busy = true
		join.Text = "..."
		local prompted = true
		if not (profile and profile.inGroup) then
			prompted = pcall(function()
				game:GetService("GroupService"):PromptJoinAsync(G.id)
			end)
		end
		if not (profile and profile.favorited) and FavoriteGame.prompt() == true then
			pcall(function()
				metaFn:InvokeServer("favorited")
			end)
		end
		local ok, _, msg = pcall(function()
			return metaFn:InvokeServer("groupCheck")
		end)
		groupPopup.busy = false
		join.Text = "JOIN GROUP"
		if profile and profile.inGroup and profile.favorited then
			close() -- the reward popup shows what they got
			return
		end
		status.Text = if not prompted then "Search for " .. G.name .. " on Roblox, join it, then press Join again." elseif ok and typeof(msg) == "string" then msg else "Not in the group yet."
		status.Visible = true
	end)
	local ev = Instance.new("BindableEvent")
	ev.Name = "FrontlinesGroupPopup"
	ev.Event:Connect(function()
		groupPopup.open()
	end)
	ev.Parent = localPlayer:WaitForChild("PlayerGui")
	groupPopup.shade = shade
	groupPopup.card = card
end

-- Night menu look (test experience with Workspace.WFNightMenu on, like MainMenu): the same reward
-- popups and group invite, recoloured with NightMenu.Kit. renderToast reads ACCENT / GOLD per call.
do
	local Config = require(Shared:WaitForChild("Config"))
	if workspace:GetAttribute("WFNightMenu") ~= false then
		local Kit = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("NightMenu"):WaitForChild("Kit"))
		local C, F = Kit.C, Kit.F
		ACCENT, GOLD = C.CYAN, C.YELLOW
		local t = toastUi.frame
		t.BackgroundColor3, t.BackgroundTransparency = C.PAGE, 0
		t:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 16)
		toastUi.stroke.Thickness = 2
		toastUi.tile:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 12)
		toastUi.kicker.FontFace, toastUi.kicker.TextSize = F.TITLE, 13
		toastUi.title.FontFace, toastUi.title.TextSize = F.TITLE, 21
		toastUi.body.FontFace, toastUi.body.TextSize = F.BOLD, 14
		toastUi.body.TextColor3, toastUi.body.TextTransparency = C.MUTED, 0
		local card = groupPopup.card
		card.BackgroundColor3 = C.PAGE
		card:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 16)
		card:FindFirstChildOfClass("UIStroke").Color = C.YELLOW
		local heading = card:FindFirstChild("Heading")
		if heading then
			heading.FontFace, heading.Text, heading.TextStrokeTransparency = F.TITLE, "Join our group", 1
		end
		local rewards = card:FindFirstChild("Rewards")
		if rewards then
			rewards.FontFace = F.BOLD
		end
		local groupName = card:FindFirstChild("GroupName")
		if groupName then
			groupName.TextColor3 = C.MUTED
		end
		local join = card:FindFirstChild("Join")
		if join then
			local gradient = join:FindFirstChildOfClass("UIGradient")
			if gradient then
				gradient:Destroy()
			end
			join.FontFace, join.TextColor3 = F.TITLE, C.YELLOW_TEXT
			join:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0.5, 0)
			join:FindFirstChildOfClass("UIStroke").Color = C.YELLOW_EDGE
			join:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
				if join.BackgroundColor3 ~= C.YELLOW and join.BackgroundColor3 ~= C.YELLOW:Lerp(C.WHITE, 0.12) then
					join.BackgroundColor3 = C.YELLOW -- the old hover recolour uses the old accent
				end
			end)
			join.BackgroundColor3 = C.YELLOW
			join.Text = "Join group"
		end
		local later = card:FindFirstChild("Close")
		if later then
			later.TextColor3 = C.MUTED
		end

		-- Full-colour art and a cleaner layout (same buttons and logic as above).
		local Art = require(localPlayer.PlayerScripts.NightMenu:WaitForChild("Art"))
		local ART_FOR = { Gold = "Gift", Crown = "WinBattle", Leaderboard = "PlayBattles", UpperLimit = "Season", Alliance = "Friends", Info = "Bell" }
		-- Rises from the bottom middle (the top would cover the battle name and Play).
		t.AnchorPoint = Vector2.new(0.5, 1)
		toastHiddenAt = UDim2.new(0.5, 0, 1, 240)
		t.Position = toastHiddenAt
		toastShownAt = function(): UDim2
			return UDim2.new(0.5, 0, 1, if DeviceLayout.state.profile == "phone" then -84 else -96)
		end
		toastUi.tile.BackgroundTransparency = 1
		toastUi.tileStroke.Enabled = false
		toastUi.icon.Visible = false
		local toastArt = Art.image(nil, { Name = "Art", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = toastUi.tile })
		toastHook = function(opts)
			local artName = opts.art or ART_FOR[opts.icon or "Crown"]
			Art.set(toastArt, artName)
			toastUi.icon.Visible = artName == nil
			toastUi.tile.BackgroundTransparency = if artName then 1 else 0.82
			for _, f in toastUi.pills:GetChildren() do
				if f:IsA("Frame") then
					local pill = opts.pills and opts.pills[f.LayoutOrder]
					f.BackgroundColor3, f.BackgroundTransparency = C.CARD, 0
					f:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0.5, 0)
					local s = f:FindFirstChildOfClass("UIStroke")
					s.Color, s.Transparency = C.LINE, 0
					for _, d in f:GetChildren() do
						if d:IsA("TextLabel") then
							d.FontFace = F.TITLE
							d.TextSize = 14
						elseif d:IsA("ImageLabel") and pill and pill.icon == "Gold" then
							d:Destroy()
							Art.image("Medal", { LayoutOrder = 1, Size = UDim2.fromOffset(20, 20), Parent = f })
						end
					end
				end
			end
		end

		-- Group card: picture, title, group name, one line of rewards, a full-width yellow pill.
		for _, d in card:GetChildren() do
			if d:IsA("ImageLabel") and d.Name ~= "Medal" then
				d.Visible = false -- old Alliance icon
			end
		end
		Art.image("Friends", { Name = "GroupArt", Position = UDim2.fromOffset(16, 14), Size = UDim2.fromOffset(50, 50), ZIndex = 51, Parent = card })
		if heading then
			heading.Position, heading.Size, heading.TextSize = UDim2.fromOffset(76, 14), UDim2.fromOffset(290, 28), 24
		end
		if groupName then
			groupName.Position, groupName.Size = UDim2.fromOffset(76, 42), UDim2.fromOffset(290, 18)
			groupName.FontFace, groupName.TextSize, groupName.TextWrapped = F.BOLD, 14, false
			groupName.TextXAlignment = Enum.TextXAlignment.Left
			groupName.TextTruncate = Enum.TextTruncate.AtEnd
		end
		local medal = card:FindFirstChild("Medal")
		if medal then
			medal.Position, medal.Size = UDim2.fromOffset(18, 74), UDim2.fromOffset(28, 28)
			Art.set(medal, "Medal")
		end
		if rewards then
			rewards.Position, rewards.Size, rewards.TextSize = UDim2.fromOffset(54, 72), UDim2.fromOffset(350, 32), 16
			rewards.Text = "Join + favourite the game: +" .. MetaConfig.GROUP.MEDALS .. " medals, a free boost every day and a group colour"
		end
		if join then
			join.Position, join.Size, join.TextSize = UDim2.fromOffset(16, 114), UDim2.new(1, -32, 0, 40), 20
		end
		if later then
			later.Text = ""
			later.BackgroundColor3, later.BackgroundTransparency = C.RAISED, 0
			later.Size, later.Position = UDim2.fromOffset(30, 30), UDim2.new(1, -42, 0, 12)
			later:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0.5, 0)
			Kit.icon("Close", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.55, 0.55), ImageColor3 = C.TEXT, ZIndex = 53, Parent = later })
		end
		local status = card:FindFirstChild("Status")
		if status then
			status.Position = UDim2.fromOffset(16, 160)
			status.FontFace, status.TextSize, status.TextColor3 = F.BOLD, 13, C.YELLOW
		end
		card.Size = UDim2.fromOffset(420, 168)

		-- Placement: under the Daily gift card in the home screen's right column, the same width as the
		-- cards there (narrow layout: rewards wrap, Join spans the card). Bottom right above the page
		-- buttons as a fallback.
		local cardScale = card:FindFirstChildOfClass("UIScale")
		local narrowW: number? = nil
		local function layout()
			local w = narrowW or 420
			local narrow = narrowW ~= nil
			if heading then
				heading.Size = UDim2.fromOffset(w - 76 - 50, 28)
				local size = if narrow then 21 else 24
				heading.TextSize = size
				while size > 14 and heading.TextBounds.X > heading.AbsoluteSize.X - 1 do
					size -= 1
					heading.TextSize = size
				end
			end
			if groupName then
				groupName.Size = UDim2.fromOffset(w - 76 - 50, 18)
			end
			if medal then
				medal.Position, medal.Size = UDim2.fromOffset(16, if narrow then 76 else 74), UDim2.fromOffset(if narrow then 24 else 28, if narrow then 24 else 28)
			end
			if rewards then
				rewards.Text = (if w < 250 then "+" else "Join + favourite the game: +") .. MetaConfig.GROUP.MEDALS .. " medals, a free boost every day and a group colour"
				rewards.Position = UDim2.fromOffset(if narrow then 48 else 54, 72)
				rewards.Size = UDim2.fromOffset(w - (if narrow then 64 else 70), if narrow then 52 else 36)
				rewards.TextSize = if narrow then 14 else 16
			end
			local joinY = if narrow then 132 else 116
			if join then
				join.Position, join.Size = UDim2.fromOffset(16, joinY), UDim2.new(1, -32, 0, 40)
			end
			local status = card:FindFirstChild("Status")
			local h = joinY + 40 + 14
			if status then
				status.Position, status.Size = UDim2.fromOffset(16, h - 4), UDim2.fromOffset(w - 32, 36)
				if status.Visible then
					h += 38
				end
			end
			card.Size = UDim2.fromOffset(w, h)
		end
		local statusLabel = card:FindFirstChild("Status")
		if statusLabel then
			statusLabel:GetPropertyChangedSignal("Visible"):Connect(function()
				task.defer(layout) -- after the old handler, which resets the size to 420 wide
			end)
		end
		local function findLeft(): GuiObject?
			local pg = localPlayer:FindFirstChild("PlayerGui")
			local home = pg and pg:FindFirstChild("WarFrontNight")
			if not home then
				return nil
			end
			for _, d in home:GetDescendants() do
				if d.Name == "Right" and d:IsA("GuiObject") and d:FindFirstChild("Gift") then
					return d
				end
			end
			-- Phones: no side columns; the card sits above the left-hand tiles (Missions / Gift / Friends).
			for _, d in home:GetDescendants() do
				if d.Name == "LeftTiles" and d:IsA("GuiObject") then
					return d
				end
			end
			return nil
		end
		local function placeCard()
			local left = findLeft()
			local s = if cardScale then math.max(cardScale.Scale, 0.01) else 1
			if left and left.AbsoluteSize.X > 0 then
				local origin = gui.AbsolutePosition
				narrowW = math.floor(left.AbsoluteSize.X / s + 0.5)
				if left.Name == "LeftTiles" then
					card.AnchorPoint = Vector2.new(0, 1)
					card.Position = UDim2.fromOffset(math.floor(left.AbsolutePosition.X - origin.X), math.floor(left.AbsolutePosition.Y - origin.Y - 10))
				else
					card.AnchorPoint = Vector2.zero
					card.Position = UDim2.fromOffset(
						math.floor(left.AbsolutePosition.X - origin.X),
						math.floor(left.AbsolutePosition.Y + left.AbsoluteSize.Y + 12 - origin.Y)
					)
				end
			else
				narrowW = nil
				card.AnchorPoint = Vector2.new(1, 1)
				card.Position = UDim2.new(1, -24, 1, -80)
			end
			layout()
		end
		-- Button and heading say what is still missing (group, favourite or both).
		local function labels()
			local inGroup = profile and profile.inGroup == true
			local fav = profile and profile.favorited == true
			if heading then
				heading.Text = if inGroup then "Favourite the game" else "Join our group"
			end
			if join and join.Text ~= "..." then
				join.Text = if inGroup then "Favourite the game" elseif fav then "Join group" else "Join group + favourite"
			end
		end
		if join then
			join:GetPropertyChangedSignal("Text"):Connect(function()
				if join.Text == "JOIN GROUP" or join.Text == "Join group" and profile and (profile.inGroup or profile.favorited ~= true) then
					labels()
				end
			end)
		end
		local baseOpen = groupPopup.open
		groupPopup.open = function()
			placeCard()
			baseOpen()
			labels()
			layout()
		end
		-- Group + favourite card, two ways (Night menu):
		--   modal  once, centred over a dimmed screen, the first time a player who has done the
		--          tutorial reaches the main menu without the rewards; closing it is saved
		--          (MetaFn "groupModalSeen", profile.groupModalSeen)
		--   docked after that, always on the home screen under the Daily gift card, no close button,
		--          until the player is in the group and has favourited the game
		-- Hidden on menu pages and in battle, and while a brand-new player is sent to the tutorial.
		-- (applyProfile's one-time timer is not used in this look.)
		groupPopup.waiting = true
		local shade = groupPopup.shade
		local mode: string? = nil
		local modalClosed = false
		local function needsRewards(): boolean
			local p = profile
			-- (Studio test switch: PlayerGui attribute WFForceGroupCard = true shows it anyway)
			if game:GetService("RunService"):IsStudio() and localPlayer.PlayerGui:GetAttribute("WFForceGroupCard") == true then
				return p ~= nil
			end
			return p ~= nil and p.saving == true and p.groupKnown == true and (p.inGroup ~= true or p.favorited ~= true)
		end
		local function goingToTutorial(): boolean
			return profile ~= nil and profile.tutorialSeen ~= true and (tonumber(profile.games) or 0) == 0
		end
		local function onHome(): boolean
			local left = findLeft()
			local home = left ~= nil and left.AbsoluteSize.X > 0
			local a: Instance? = left
			while home and a and not a:IsA("ScreenGui") do
				if a:IsA("GuiObject") and not a.Visible then
					home = false
				end
				a = a.Parent
			end
			if home and a and a:IsA("ScreenGui") and not a.Enabled then
				home = false
			end
			-- not over a home-screen pop-up (Ways to play, menu, friends...): Kit.popup backdrops
			if home and a then
				for _, c in a:GetChildren() do
					if c:IsA("TextButton") and c.Visible and c.ZIndex >= 50 and c.Size == UDim2.fromScale(1, 1) then
						home = false
						break
					end
				end
			end
			return home
		end
		local function setMode(newMode: string)
			if mode == newMode then
				return
			end
			mode = newMode
			if newMode == "modal" then
				shade.BackgroundColor3, shade.BackgroundTransparency, shade.Active = C.BACKDROP, 0.35, true
				narrowW = nil
				card.AnchorPoint, card.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
				if later then
					later.Visible = true
				end
			else
				shade.BackgroundTransparency, shade.Active = 1, false
				if later then
					later.Visible = false -- docked: stays until the rewards are earned
				end
				placeCard()
			end
			labels()
			layout()
		end
		if later then
			later.Activated:Connect(function()
				if mode == "modal" then
					modalClosed = true
					task.spawn(function()
						pcall(function()
							metaFn:InvokeServer("groupModalSeen")
						end)
					end)
				end
			end)
		end
		task.spawn(function()
			local pg = localPlayer:WaitForChild("PlayerGui")
			while gui.Parent do
				task.wait(0.2)
				local show = false
				if needsRewards() and not goingToTutorial() and onHome() and pg:GetAttribute("FrontlinesMenuOpen") == true then
					if not modalClosed and profile.groupModalSeen ~= true then
						setMode("modal")
					else
						setMode("dock")
						placeCard() -- follows the column if the screen size changes
						layout()
					end
					show = true
				end
				shade.Visible = show
				if show then
					groupPopup.shown = true
				end
			end
		end)
	end
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
 if mobileDevice() then groupPopup.shade.Visible=false;toastUi.frame.Visible=false end
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
	-- Fit the join card on short landscape/mobile viewports as well as desktop.
	DeviceLayout.setScale(groupPopup.card, math.min(s, math.max(0.4, (gui.AbsoluteSize.X - 24) / 440), math.max(0.4, (gui.AbsoluteSize.Y - 24) / 580)))
	if window.Visible then
		modal.layout()
	end
	selectInWindow()
end
DeviceLayout.attachScreenGui(gui)
DeviceLayout.Changed:Connect(applyMetaLayout)
applyMetaLayout()

-- All menu group invitation entry points use one non-modal bottom-left prompt.
do
 local pg=localPlayer:WaitForChild("PlayerGui")
 local function update()
  local eligible=not mobileDevice() and pg:GetAttribute("FrontlinesMenuOpen")==true and pg:GetAttribute("WFInGroup")==false and not window.Visible
  if not eligible then groupPopup.shade.Visible=false
  elseif not groupPopup.dismissed and not groupPopup.shade.Visible then groupPopup.open() end
 end
 pg:GetAttributeChangedSignal("FrontlinesMenuOpen"):Connect(update)
 pg:GetAttributeChangedSignal("WFInGroup"):Connect(update)
 window:GetPropertyChangedSignal("Visible"):Connect(update)
 update()
end

-- Server messages
local feedbackPromptAttempted = false
local feedbackPromptBusy = false
local function offerGroupFeedback()
 if mobileDevice() then return end
	if feedbackPromptAttempted or feedbackPromptBusy or not profile or not profile.groupFeedbackNeeded or not profile.saving then return end
	feedbackPromptAttempted = true
	task.spawn(function()
		local pg = localPlayer:WaitForChild("PlayerGui")
		while pg.Parent and profile and profile.groupFeedbackNeeded do
			if pg:GetAttribute("FrontlinesMenuOpen") == true and not window.Visible and not groupPopup.shade.Visible then break end
			task.wait(1)
		end
		if not pg.Parent or not profile or not profile.groupFeedbackNeeded then return end
		if game:GetService("RunService"):IsStudio() then
			showToast("Rate War Front", "Roblox's rating prompt is available in the Roblox app. Your group rewards can be claimed there.", { kicker = "GROUP REWARDS", icon = "Alliance", color = ACCENT, seconds = 6 })
			return
		end
		feedbackPromptBusy = true
		showToast("Support War Front", "Please rate the game in Roblox's prompt, then collect your group rewards.", { kicker = "GROUP REWARDS", icon = "Alliance", color = ACCENT, seconds = 6 })
		local opened, err = pcall(function()
			game:GetService("SocialService"):PromptFeedbackSubmissionAsync()
		end)
		if opened and pg.Parent then
			-- A just-completed join check uses the same five-second server cooldown.
			task.wait(5.1)
			local ok, result, message = pcall(function() return metaFn:InvokeServer("groupCheck", "feedbackPromptClosed") end)
			if not ok or result ~= true then
				showToast("Group rewards", "Please open Rewards and try claiming again.", { icon = "Alliance", color = ACCENT })
				task.delay(30, function() feedbackPromptAttempted = false end)
			end
		else
			showToast("Rating unavailable", "Roblox could not open the rating prompt. Try Rewards again later.", { icon = "Alliance", color = ACCENT })
			warn("[War Front] Rating prompt unavailable: " .. tostring(err))
			-- A manual Rewards check may retry after the cooldown; do not loop prompts.
			task.delay(30, function() feedbackPromptAttempted = false end)
		end
		feedbackPromptBusy = false
	end)
end

local favoriteChecked = false
local function applyProfile(p)
	if not p then
		return
	end
	profile = p
	offerGroupFeedback()
	if p.saving == true and p.favorited ~= true and not favoriteChecked then
		favoriteChecked = true -- once per session: already a favourite -> tell the server (rewards follow)
		task.spawn(FavoriteGame.report, metaFn)
	end
	local pg = localPlayer:FindFirstChild("PlayerGui")
	if pg then
		pg:SetAttribute("WFInGroup", if p.groupKnown == true then p.inGroup == true else nil)
	end
	if p.inGroup == true and p.favorited == true and groupPopup.close then groupPopup.close() end
	if p.groupKnown == true and (p.inGroup == false or p.favorited ~= true) and p.saving and not groupPopup.shown and not groupPopup.waiting then
		-- Once per session: as soon as the main menu is up after joining (never mid-match). A brand-new
		-- player is sent to the tutorial first, so it waits until they're back from it.
		groupPopup.waiting = true
		task.spawn(function()
			while not groupPopup.shown do
				if profile and profile.inGroup and profile.favorited then
					return
				end
				local tutorialFirst = profile and profile.tutorialSeen ~= true and (tonumber(profile.games) or 0) == 0
				if profile and not tutorialFirst and profile.groupKnown == true and (profile.inGroup == false or profile.favorited ~= true) and pg and pg:GetAttribute("FrontlinesMenuOpen") == true and not window.Visible then
					groupPopup.open()
					return
				end
				task.wait(0.25)
			end
		end)
	end
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
		local title = if data.won then "Victory!" elseif not place then "Participation saved" else string.format("You placed %d%s", place, suffix)
		showToast(title, if data.vip and data.event then "VIP and event bonus included." elseif data.vip then "VIP bonus included." elseif data.event then "Event bonus included." else "", {
			kicker = "Match rewards",
			icon = if data.won then "Crown" else "Leaderboard",
			pills = { { text = "+" .. data.xp .. " XP", color = MenuKit.C.MALIBU }, { text = "+" .. data.coins .. " medals", icon = "Gold" } },
		})
	elseif kind == "levelUp" then
		showToast("Level " .. data, "New colours may be unlocked in the store.", { kicker = "Level up", icon = "UpperLimit", color = MenuKit.C.MALIBU })
	elseif kind == "daily" then
		local day = tonumber(data.day) or 1
		local step = (day - 1) % 7 + 1
		showToast("Day " .. day .. " streak!", if step == 7 then "Big gift day! A new week of gifts starts tomorrow." else "Come back tomorrow for day " .. (day + 1) .. ". Day 7 is the big gift.", {
			kicker = "Daily gift",
			icon = "Gold",
			art = if step == 7 then "GiftBig" else "Gift",
			pills = { { text = "+" .. data.coins .. " medals", icon = "Gold" } },
		})
	elseif kind == "announce" and type(data) == "table" then
		-- From the developers (admin menu): this server, every server, or just this player.
		showToast(tostring(data.text), if data.from then "From " .. tostring(data.from) else "", {
			kicker = "Announcement",
			icon = "Info",
			color = Color3.fromRGB(255, 99, 99),
			seconds = 9,
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
			color = ACCENT,
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
