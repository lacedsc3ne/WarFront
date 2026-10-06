--[[
	War Front - shared look of the main menu, its pages and the menu-styled windows.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Colours, sizes and component looks follow OpenFront's home screen (src/client/styles.css theme,
	components/baseComponents/Modal.ts, components/ui/ModalHeader.ts, baseComponents/setting/*,
	baseComponents/Button.ts). Modified version re-implemented in Luau for Roblox; not affiliated
	with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.MenuKit (ModuleScript), used by MainMenu, MenuPages,
-- MetaClient and DefeatScreen.
-- MenuKit.C            colour tokens (OpenFront theme names)
-- MenuKit.F            fonts (Builder Sans, the closest Roblox match to OpenFront's system sans)
-- MenuKit.make / corner / stroke / pad / text / list   instance helpers
-- MenuKit.icon(name, props) -> ImageLabel     white icon from MenuIconsData (tint with ImageColor3)
-- MenuKit.setIcon(label, name)
-- MenuKit.hover(guiButton, fn(state))         state "idle" | "hover" | "press" (gamepad selection = hover)
-- MenuKit.button(kind, props) -> TextButton   kind "primary" | "secondary" | "tutorial" | "accent" | "gray"
-- MenuKit.page(parent, title, onBack) -> page  OpenFront inline page (o-modal inline + modalHeader)
--      page.frame, page.body (ScrollingFrame), page.back, page:setTabs(list, active, onTab),
--      page:clear(), page:layout(mobile), page.firstSelectable()
-- MenuKit.toggleRow / sliderRow / navRow / heading / card / paragraph / keycap / comingSoon   page content
-- MenuKit.modal(screenGui, name) -> modal   o-modal: backdrop + centred page (see the function)

local AssetService = game:GetService("AssetService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local MenuIconsData = require(script.Parent:WaitForChild("MenuIconsData"))

local MenuKit = {}

local function rgb(hex: number): Color3
	return Color3.fromRGB(hex // 65536, (hex // 256) % 256, hex % 256)
end

MenuKit.C = {
	MALIBU = rgb(0x0084d1), -- --color-malibu-blue
	AQUARIUS = rgb(0x3fa9f5), -- --color-aquarius
	CYBER = rgb(0xffd700), -- --color-cyber-yellow
	SURFACE = rgb(0x0a1628), -- --color-surface
	SURFACE_HI = rgb(0x152338), -- surface + hover:brightness-[1.08]
	ZINC900 = rgb(0x18181b),
	NEUTRAL800 = rgb(0x262626),
	GRAY900 = rgb(0x111827),
	GRAY800 = rgb(0x1f2937),
	GRAY700 = rgb(0x374151),
	GRAY600 = rgb(0x4b5563),
	GRAY400 = rgb(0x9ca3af),
	GRAY300 = rgb(0xd1d5db),
	GRAY200 = rgb(0xe5e7eb),
	BLUE100 = rgb(0xdbeafe),
	BLUE200 = rgb(0xbfdbfe),
	BLUE300 = rgb(0x93c5fd),
	BLUE400 = rgb(0x60a5fa),
	BLUE500 = rgb(0x3b82f6),
	BLUE600 = rgb(0x2563eb),
	SKY300 = rgb(0x7dd3fc),
	EMERALD300 = rgb(0x6ee7b7),
	EMERALD500 = rgb(0x10b981),
	AMBER300 = rgb(0xfcd34d),
	AMBER500 = rgb(0xf59e0b),
	RED300 = rgb(0xfca5a5),
	RED400 = rgb(0xf87171),
	RED500 = rgb(0xef4444),
	RED600 = rgb(0xdc2626),
	YELLOW300 = rgb(0xfde047),
	YELLOW400 = rgb(0xfacc15),
	KEY = rgb(0x2a2a2a),
	KEY_EDGE = rgb(0x1a1a1a),
	WHITE = Color3.new(1, 1, 1),
	BLACK = Color3.new(0, 0, 0),
}
local C = MenuKit.C

local function fontOf(weight: Enum.FontWeight, fallback: Enum.Font): Font
	local ok, f = pcall(Font.fromName, "BuilderSans", weight)
	if ok and f then
		return f
	end
	return Font.fromEnum(fallback)
end

MenuKit.F = {
	REGULAR = fontOf(Enum.FontWeight.Regular, Enum.Font.Gotham),
	MEDIUM = fontOf(Enum.FontWeight.Medium, Enum.Font.GothamMedium),
	SEMIBOLD = fontOf(Enum.FontWeight.SemiBold, Enum.Font.GothamMedium),
	BOLD = fontOf(Enum.FontWeight.Bold, Enum.Font.GothamBold),
	BLACK = fontOf(Enum.FontWeight.ExtraBold, Enum.Font.GothamBlack),
	MONO = Font.fromEnum(Enum.Font.RobotoMono),
	-- The "WAR FRONT" wordmark (stands in for OpenFront's logo image).
	LOGO = Font.fromEnum(Enum.Font.GothamBlack),
}
local F = MenuKit.F

-- Instance helpers
local function make(className: string, props: { [string]: any }?): any
	local inst = Instance.new(className)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(inst :: any)[k] = v
			end
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
MenuKit.make = make

function MenuKit.corner(o: Instance, r: number?): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = o })
end

function MenuKit.round(o: Instance): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = o })
end

-- Border; colour white with the given transparency by default (border-white/10 = 0.9).
function MenuKit.stroke(o: Instance, transparency: number?, color: Color3?, thickness: number?): UIStroke
	return make("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = color or C.WHITE,
		Transparency = transparency or 0.9,
		Thickness = thickness or 1,
		Parent = o,
	})
end

function MenuKit.pad(o: Instance, l: number, r: number?, t: number?, b: number?): UIPadding
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, l),
		PaddingRight = UDim.new(0, r or l),
		PaddingTop = UDim.new(0, t or 0),
		PaddingBottom = UDim.new(0, b or t or 0),
		Parent = o,
	})
end

function MenuKit.text(props: { [string]: any }): TextLabel
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	props.BorderSizePixel = 0
	props.FontFace = props.FontFace or F.REGULAR
	props.TextColor3 = props.TextColor3 or C.WHITE
	props.TextSize = props.TextSize or 14
	return make("TextLabel", props)
end

function MenuKit.list(parent: Instance, horizontal: boolean?, gap: number?, props: { [string]: any }?): UIListLayout
	local p = props or {}
	p.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	p.Padding = UDim.new(0, gap or 0)
	p.SortOrder = Enum.SortOrder.LayoutOrder
	p.Parent = parent
	return make("UIListLayout", p)
end

-- Wrapped paragraph that grows to fit its text.
function MenuKit.paragraph(parent: Instance, order: number, str: string, props: { [string]: any }?): TextLabel
	local p = props or {}
	p.LayoutOrder = order
	p.Size = p.Size or UDim2.new(1, 0, 0, 0)
	p.AutomaticSize = Enum.AutomaticSize.Y
	p.TextWrapped = true
	p.TextXAlignment = p.TextXAlignment or Enum.TextXAlignment.Left
	p.TextYAlignment = Enum.TextYAlignment.Top
	p.TextColor3 = p.TextColor3 or C.GRAY300
	p.TextSize = p.TextSize or 14
	p.LineHeight = p.LineHeight or 1.15
	p.Text = str
	p.Parent = parent
	return MenuKit.text(p)
end

-- Icons (MenuIconsData, decoded once per name into a shared EditableImage)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = table.create(256, 0)
for i = 1, 64 do
	DEC[string.byte(B64, i)] = i - 1
end

local function decode(s: string): buffer
	local n = #s
	local pad = 0
	if string.sub(s, -2) == "==" then
		pad = 2
	elseif string.sub(s, -1) == "=" then
		pad = 1
	end
	local len = n // 4 * 3 - pad
	local out = buffer.create(len)
	local o = 0
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = DEC[a] * 262144 + DEC[b] * 4096 + DEC[c or 61] * 64 + DEC[d or 61]
		if o < len then
			buffer.writeu8(out, o, v // 65536)
		end
		if o + 1 < len then
			buffer.writeu8(out, o + 1, (v // 256) % 256)
		end
		if o + 2 < len then
			buffer.writeu8(out, o + 2, v % 256)
		end
		o += 3
	end
	return out
end

-- ASCII stand-ins if EditableImage is unavailable (Studio: Allow Mesh / Image APIs off).
local GLYPH = {
	Bell = "!",
	Help = "?",
	Gear = "*",
	Menu = "=",
	Back = "<",
	Chevron = ">",
	Caret = "v",
	People = "",
	Lock = "",
	CheckCircle = "v",
	X = "X",
	Check = "v",
	PlayTri = ">",
	Keyboard = "#",
	Warning = "!",
	Layout = "#",
	Radial = "o",
	Info = "i",
	Building = "B",
	User = "@",
	Github = "GH",
	LangFlag = "EN",
}

local iconCache: { [string]: any } = {}
local iconsUnavailable = false

local function editable(name: string): any
	local cached = iconCache[name]
	if cached ~= nil then
		return cached or nil
	end
	iconCache[name] = false
	if iconsUnavailable then
		return nil
	end
	local entry = (MenuIconsData :: any)[name]
	if type(entry) ~= "table" then
		return nil
	end
	local size = MenuIconsData.SIZE
	local ok, img = pcall(function()
		local raw = decode(entry[2])
		local px = raw
		if entry[1] == "A" then
			px = buffer.create(size * size * 4)
			buffer.fill(px, 0, 255)
			for i = 0, size * size - 1 do
				buffer.writeu8(px, i * 4 + 3, buffer.readu8(raw, i))
			end
		end
		local ei = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
		if not ei then
			error("CreateEditableImage returned nil")
		end
		ei:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), px)
		return ei
	end)
	if ok and img then
		iconCache[name] = img
		return img
	end
	iconsUnavailable = true
	warn("[War Front] menu icons fall back to text (EditableImage unavailable): " .. tostring(img))
	return nil
end

function MenuKit.setIcon(label: ImageLabel, name: string)
	local ei = editable(name)
	local glyph = label:FindFirstChild("Glyph") :: TextLabel?
	if ei then
		label.ImageContent = Content.fromObject(ei)
		if glyph then
			glyph:Destroy()
		end
		return
	end
	if not glyph then
		local g = MenuKit.text({ Name = "Glyph", Size = UDim2.fromScale(1, 1), FontFace = F.BOLD, TextScaled = true, Parent = label })
		g.TextColor3 = label.ImageColor3
		label:GetPropertyChangedSignal("ImageColor3"):Connect(function()
			g.TextColor3 = label.ImageColor3
		end)
		label:GetPropertyChangedSignal("ImageTransparency"):Connect(function()
			g.TextTransparency = label.ImageTransparency
		end)
		glyph = g
	end
	(glyph :: TextLabel).Text = GLYPH[name] or "?"
end

function MenuKit.icon(name: string, props: { [string]: any }?): ImageLabel
	local p = props or {}
	local parent = p.Parent
	p.Parent = nil
	p.Name = p.Name or ("Icon_" .. name)
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.ScaleType = Enum.ScaleType.Fit
	p.Size = p.Size or UDim2.fromOffset(24, 24)
	local img = make("ImageLabel", p)
	MenuKit.setIcon(img, name)
	if parent then
		img.Parent = parent
	end
	return img
end

-- Interaction feedback (mouse hover, touch press, gamepad selection)
function MenuKit.hover(b: GuiButton, fn: (string) -> ())
	local over, sel, down = false, false, false
	local function update()
		fn(if down then "press" elseif over or sel then "hover" else "idle")
	end
	b.MouseEnter:Connect(function()
		over = true
		update()
	end)
	b.MouseLeave:Connect(function()
		over, down = false, false
		update()
	end)
	b.SelectionGained:Connect(function()
		sel = true
		update()
	end)
	b.SelectionLost:Connect(function()
		sel = false
		update()
	end)
	b.MouseButton1Down:Connect(function()
		down = true
		update()
	end)
	b.MouseButton1Up:Connect(function()
		down = false
		update()
	end)
	update()
end

-- Action buttons (GameModeSelector PRIMARY_ACTION / SECONDARY_ACTION / TUTORIAL_ACTION,
-- o-button variants, HelpModal's accent button).
function MenuKit.button(kind: string, props: { [string]: any }): TextButton
	props.AutoButtonColor = false
	props.BorderSizePixel = 0
	props.FontFace = props.FontFace or F.MEDIUM
	props.TextSize = props.TextSize or 16
	props.Text = props.Text or ""
	props.TextColor3 = if kind == "tutorial" then C.GRAY900 elseif kind == "accent" then C.AQUARIUS else C.WHITE
	local b = make("TextButton", props)
	MenuKit.corner(b, 8)
	local glow: UIStroke? = nil
	if kind == "secondary" then
		glow = MenuKit.stroke(b, 1, C.MALIBU, 1)
	elseif kind == "accent" then
		glow = MenuKit.stroke(b, 0.7, C.MALIBU, 1)
	end
	local base, hi, press
	if kind == "primary" then
		base, hi, press = C.MALIBU, C.AQUARIUS, C.MALIBU:Lerp(C.BLACK, 0.2)
	elseif kind == "tutorial" then
		base, hi, press = C.CYBER, C.YELLOW300, C.CYBER:Lerp(C.BLACK, 0.2)
	elseif kind == "secondary" then
		base, hi, press = C.SURFACE, C.SURFACE_HI, C.SURFACE:Lerp(C.BLACK, 0.05)
	elseif kind == "gray" then
		base, hi, press = C.GRAY700, C.GRAY600, C.GRAY800
	else -- accent: bg-malibu-blue/20
		base, hi, press = C.MALIBU, C.MALIBU, C.MALIBU
	end
	MenuKit.hover(b, function(s)
		if kind == "accent" then
			b.BackgroundColor3 = C.MALIBU
			b.BackgroundTransparency = if s == "idle" then 0.8 else 0.65
		else
			b.BackgroundColor3 = if s == "press" then press elseif s == "hover" then hi else base
		end
		if glow and kind == "secondary" then
			glow.Transparency = if s == "idle" then 1 else 0
		end
	end)
	return b
end

-- Round icon button of the nav bars (NavUtilityIcons: w-10 h-10 rounded-full, white/70 ->
-- malibu-blue on hover / when its page is active).
function MenuKit.iconButton(name: string, size: number, props: { [string]: any }?): (TextButton, ImageLabel)
	local p = props or {}
	p.Text = ""
	p.AutoButtonColor = false
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.Size = UDim2.fromOffset(size, size)
	local b = make("TextButton", p)
	MenuKit.round(b)
	local img = MenuKit.icon(name, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(24, 24),
		ImageColor3 = C.WHITE,
		ImageTransparency = 0.3,
		Parent = b,
	})
	local active = false
	local state = "idle"
	local function paint()
		local lit = active or state ~= "idle"
		img.ImageColor3 = if lit then C.MALIBU else C.WHITE
		img.ImageTransparency = if lit then 0 else 0.3
	end
	MenuKit.hover(b, function(s)
		state = s
		paint()
	end)
	b:SetAttribute("Active", false)
	b:GetAttributeChangedSignal("Active"):Connect(function()
		active = b:GetAttribute("Active") == true
		paint()
	end)
	return b, img
end

-- Small red notification dot (NavUtilityIcons renderDot).
function MenuKit.dot(parent: Instance, color: Color3?): Frame
	local d = make("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = color or C.RED500,
		BorderSizePixel = 0,
		Parent = parent,
	})
	MenuKit.round(d)
	return d
end

-- Inline page (o-modal inline: bg-black/70, lg:rounded-2xl, lg:border white/10) with
-- modalHeader (round back button + uppercase title, border-b) and optional tab strip.
export type Page = {
	frame: Frame,
	header: Frame,
	title: TextLabel,
	back: TextButton,
	tabBar: Frame,
	body: ScrollingFrame,
	tabs: { any },
	tabButtons: { [string]: TextButton },
	active: string?,
	onTab: ((string) -> ())?,
	setTabs: (Page, { any }, string?, ((string) -> ())?) -> (),
	selectTab: (Page, string) -> (),
	clear: (Page) -> (),
	layout: (Page, boolean) -> (),
	firstSelectable: (Page) -> GuiObject?,
	mobile: boolean,
}

local Page = {}
Page.__index = Page

function MenuKit.page(parent: Instance, title: string, onBack: () -> ()): Page
	local self: any = setmetatable({}, Page)
	self.mobile = false
	self.tabs = {}
	self.tabButtons = {}
	local frame = make("Frame", {
		Name = "Page",
		BackgroundColor3 = C.BLACK,
		BackgroundTransparency = 0.15, -- bg-black/70 + backdrop-blur (no blur here, so a bit darker)
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Visible = false,
		Active = true,
		Parent = parent,
	})
	self.corner = MenuKit.corner(frame, 16)
	self.border = MenuKit.stroke(frame, 0.9)
	self.frame = frame

	local header = make("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 88), Parent = frame })
	self.header = header
	make("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = C.WHITE,
		BackgroundTransparency = 0.9,
		BorderSizePixel = 0,
		Parent = header,
	})
	local back = make("TextButton", {
		Name = "Back",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.WHITE,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(40, 40),
		Parent = header,
	})
	MenuKit.round(back)
	MenuKit.stroke(back, 0.9)
	local arrow = MenuKit.icon("Back", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(20, 20),
		ImageColor3 = C.GRAY400,
		Parent = back,
	})
	MenuKit.hover(back, function(s)
		back.BackgroundTransparency = if s == "idle" then 0.95 else 0.9
		arrow.ImageColor3 = if s == "idle" then C.GRAY400 else C.WHITE
	end)
	back.Activated:Connect(onBack)
	self.back = back
	self.title = MenuKit.text({
		Name = "Title",
		AnchorPoint = Vector2.new(0, 0.5),
		FontFace = F.BOLD,
		TextSize = 24,
		Text = string.upper(title),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})

	local tabBar = make("Frame", { Name = "Tabs", BackgroundTransparency = 1, Visible = false, Parent = frame })
	MenuKit.list(tabBar, true, 4, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	make("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = C.WHITE,
		BackgroundTransparency = 0.9,
		BorderSizePixel = 0,
		Parent = frame,
		Visible = false,
	})
	self.tabBar = tabBar

	local body = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.WHITE,
		ScrollBarImageTransparency = 0.7,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		Parent = frame,
	})
	self.body = body
	self.bodyPad = MenuKit.pad(body, 22, 22, 22, 22)
	MenuKit.list(body, false, 8)
	self:layout(false)
	return self
end

function Page.layout(self: any, mobile: boolean)
	self.mobile = mobile
	local hp = if mobile then 16 else 24 -- p-4 lg:p-6
	local headerH = 40 + 2 * hp
	self.header.Size = UDim2.new(1, 0, 0, headerH)
	self.back.Position = UDim2.new(0, hp, 0.5, 0)
	self.title.Position = UDim2.new(0, hp + 40 + 16, 0.5, 0)
	self.title.Size = UDim2.new(1, -(2 * hp + 56), 0, 32)
	self.title.TextSize = if mobile then 20 else 24
	self.corner.CornerRadius = UDim.new(0, if mobile then 0 else 16)
	self.border.Enabled = not mobile
	local y = headerH
	local hasTabs = #self.tabs > 0
	self.tabBar.Visible = hasTabs
	if hasTabs then
		self.tabBar.Position = UDim2.fromOffset(0, y)
		self.tabBar.Size = UDim2.new(1, 0, 0, 44)
		y += 44
	end
	self.body.Position = UDim2.fromOffset(0, y)
	self.body.Size = UDim2.new(1, 0, 1, -y)
	local bp = if mobile then 16 else 22
	self.bodyPad.PaddingLeft = UDim.new(0, bp)
	self.bodyPad.PaddingRight = UDim.new(0, bp)
	self.bodyPad.PaddingTop = UDim.new(0, bp)
	self.bodyPad.PaddingBottom = UDim.new(0, bp)
end

function Page.clear(self: any)
	for _, c in self.body:GetChildren() do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
			c:Destroy()
		end
	end
	self.body.CanvasPosition = Vector2.zero
end

-- tabs = { { key = "gameplay", label = "Gameplay" }, ... } (Modal.ts renderTabs)
function Page.setTabs(self: any, tabs: { any }, active: string?, onTab: ((string) -> ())?)
	for _, b in self.tabButtons do
		b:Destroy()
	end
	self.tabButtons = {}
	self.tabs = tabs
	self.onTab = onTab
	for i, t in tabs do
		local b = make("TextButton", {
			Name = t.key,
			LayoutOrder = i,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			FontFace = F.BOLD,
			TextSize = 14,
			Text = string.upper(t.label),
			TextColor3 = C.WHITE,
			Parent = self.tabBar,
		})
		MenuKit.pad(b, 16, 16, 0, 0)
		make("Frame", {
			Name = "Underline",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 2),
			BackgroundColor3 = C.MALIBU,
			BorderSizePixel = 0,
			Visible = false,
			Parent = b,
		})
		local key = t.key
		MenuKit.hover(b, function(s)
			if self.active ~= key then
				b.TextTransparency = if s == "idle" then 0.6 else 0.3
			end
		end)
		b.Activated:Connect(function()
			self:selectTab(key)
		end)
		self.tabButtons[key] = b
	end
	self:layout(self.mobile)
	if active then
		self:selectTab(active)
	end
end

function Page.selectTab(self: any, key: string)
	self.active = key
	for k, b in self.tabButtons do
		local on = k == key
		b.TextColor3 = if on then C.AQUARIUS else C.WHITE
		b.TextTransparency = if on then 0 else 0.6
		local u = b:FindFirstChild("Underline")
		if u then
			u.Visible = on
		end
	end
	if self.onTab then
		self.onTab(key)
	end
end

function Page.firstSelectable(self: any): GuiObject?
	local best, bestY = nil, math.huge
	for _, d in self.body:GetDescendants() do
		if d:IsA("GuiButton") and d.Selectable and d.Visible and d.AbsolutePosition.Y < bestY then
			best, bestY = d, d.AbsolutePosition.Y
		end
	end
	return best or self.back
end

-- Page content pieces
-- HelpModal section heading: blue-400 icon, text-xl bold uppercase white/90, gradient rule.
function MenuKit.heading(parent: Instance, order: number, iconName: string?, title: string): Frame
	local row = make("Frame", { Name = "Heading", LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = parent })
	MenuKit.pad(row, 0, 0, 12, 4)
	local x = 0
	if iconName then
		MenuKit.icon(iconName, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(22, 22), ImageColor3 = C.BLUE400, Parent = row })
		x = 34
	end
	local t = MenuKit.text({
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		FontFace = F.BOLD,
		TextSize = 20,
		TextTransparency = 0.1,
		Text = string.upper(title),
		Parent = row,
	})
	local line = make("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(1, -x, 0, 1),
		BackgroundColor3 = C.BLUE500,
		BorderSizePixel = 0,
		Parent = row,
	})
	make("UIGradient", {
		Transparency = NumberSequence.new(0.5, 1),
		Parent = line,
	})
	local function fit()
		line.Size = UDim2.new(1, -(x + t.TextBounds.X + 12), 0, 1)
	end
	t:GetPropertyChangedSignal("TextBounds"):Connect(fit)
	fit()
	return row
end

-- bg-white/5 rounded-xl border-white/10 box that grows with its content.
function MenuKit.card(parent: Instance, order: number, padX: number?, padY: number?, gap: number?): Frame
	local f = make("Frame", {
		Name = "Card",
		LayoutOrder = order,
		BackgroundColor3 = C.WHITE,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	MenuKit.corner(f, 12)
	MenuKit.stroke(f, 0.9)
	MenuKit.pad(f, padX or 16, padX or 16, padY or 16, padY or 16)
	MenuKit.list(f, false, gap or 8)
	return f
end

-- HelpModal renderKey: bg-[#2a2a2a] border-b-2 border-[#1a1a1a] font-mono text-xs bold.
function MenuKit.keycap(parent: Instance, label: string, order: number?): TextLabel
	local k = MenuKit.text({
		Name = "Key",
		LayoutOrder = order or 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(32, 24),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.KEY,
		FontFace = F.MONO,
		TextSize = 12,
		Text = label,
		Parent = parent,
	})
	k.FontFace = Font.new(F.MONO.Family, Enum.FontWeight.Bold)
	MenuKit.corner(k, 4)
	MenuKit.pad(k, 8, 8, 0, 0)
	make("UISizeConstraint", { MinSize = Vector2.new(32, 24), Parent = k })
	MenuKit.stroke(k, 0, C.KEY_EDGE, 1)
	return k
end

-- Row shell shared by toggles and sliders (setting-toggle / setting-slider: p-4 bg-white/5
-- border-white/10 rounded-xl, hover bg-white/10; label bold base, description white/50 sm).
local function settingRow(parent: Instance, order: number, label: string, desc: string?, rightW: number): (TextButton, Frame)
	local b = make("TextButton", {
		Name = "Setting",
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.WHITE,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	MenuKit.corner(b, 12)
	local st = MenuKit.stroke(b, 0.9)
	MenuKit.pad(b, 16, 16, 16, 16)
	MenuKit.hover(b, function(s)
		b.BackgroundTransparency = if s == "idle" then 0.95 else 0.9
		st.Color = if GuiService.SelectedObject == b then C.MALIBU else C.WHITE
		st.Transparency = if GuiService.SelectedObject == b then 0.2 else 0.9
	end)
	local col = make("Frame", { Name = "Text", BackgroundTransparency = 1, Size = UDim2.new(1, -(rightW + 16), 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = b })
	MenuKit.list(col, false, 4)
	MenuKit.paragraph(col, 1, label, { FontFace = F.BOLD, TextSize = 16, TextColor3 = C.WHITE })
	if desc and desc ~= "" then
		MenuKit.paragraph(col, 2, desc, { TextSize = 14, TextColor3 = C.WHITE, TextTransparency = 0.5 })
	end
	local right = make("Frame", {
		Name = "Control",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(rightW, 28),
		BackgroundTransparency = 1,
		Parent = b,
	})
	return b, right
end

-- setting-toggle: 52x28 switch, bg black/60 -> blue-600 when on, knob white/40 -> white.
function MenuKit.toggleRow(parent: Instance, order: number, label: string, desc: string?, get: () -> boolean, set: (boolean) -> ()): () -> ()
	local b, right = settingRow(parent, order, label, desc, 52)
	local track = make("Frame", { Size = UDim2.fromOffset(52, 28), BackgroundColor3 = C.BLACK, BackgroundTransparency = 0.4, BorderSizePixel = 0, Parent = right })
	MenuKit.round(track)
	local tStroke = MenuKit.stroke(track, 0.9)
	local knob = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(20, 20), BackgroundColor3 = C.WHITE, BorderSizePixel = 0, Parent = track })
	MenuKit.round(knob)
	local function refresh()
		local on = get() == true
		track.BackgroundColor3 = if on then C.BLUE600 else C.BLACK
		track.BackgroundTransparency = if on then 0 else 0.4
		tStroke.Color = if on then C.BLUE500 else C.WHITE
		tStroke.Transparency = if on then 0 else 0.9
		knob.Position = UDim2.new(0, if on then 27 else 3, 0.5, 0)
		knob.BackgroundTransparency = if on then 0 else 0.6
	end
	b.Activated:Connect(function()
		set(not get())
		refresh()
	end)
	refresh()
	return refresh
end

-- setting-slider: value text + 8 px malibu track with an 18 px thumb, 200 px wide. Mouse / touch
-- drag the track; with a gamepad the row is selected and left / right change the value.
function MenuKit.sliderRow(
	parent: Instance,
	order: number,
	label: string,
	desc: string?,
	min: number,
	max: number,
	step: number,
	get: () -> number,
	set: (number) -> (),
	fmt: ((number) -> string)?
): () -> ()
	local b, right = settingRow(parent, order, label, desc, 200)
	b.NextSelectionLeft = b
	b.NextSelectionRight = b
	local valueText = MenuKit.text({ Size = UDim2.fromOffset(44, 28), FontFace = F.BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, Parent = right })
	local hit = make("TextButton", {
		Name = "Track",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(52, 0),
		Size = UDim2.new(1, -52, 1, 0),
		Parent = right,
	})
	local track = make("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = C.WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Parent = hit })
	MenuKit.corner(track, 4)
	local fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.MALIBU, BorderSizePixel = 0, Parent = track })
	MenuKit.corner(fill, 4)
	local thumb = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = C.MALIBU, BorderSizePixel = 0, ZIndex = 2, Parent = track })
	MenuKit.round(thumb)
	MenuKit.stroke(thumb, 0.8, C.MALIBU, 4)

	local function refresh()
		local v = get()
		local f = math.clamp((v - min) / math.max(1e-6, max - min), 0, 1)
		fill.Size = UDim2.fromScale(f, 1)
		thumb.Position = UDim2.fromScale(f, 0.5)
		valueText.Text = if fmt then fmt(v) else tostring(v)
	end
	local function setFromX(x: number)
		local w = track.AbsoluteSize.X
		if w <= 0 then
			return
		end
		local f = math.clamp((x - track.AbsolutePosition.X) / w, 0, 1)
		local v = min + math.floor(f * (max - min) / step + 0.5) * step
		set(math.clamp(v, min, max))
		refresh()
	end
	local dragging = false
	hit.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	local conns = {}
	conns[1] = UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	conns[2] = UserInputService.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			if dragging then
				pcall(function()
					require(script.Parent:WaitForChild("SoundKit")).play("slider") -- UserSettingModal playCue("slider")
				end)
			end
			dragging = false
		end
	end)
	conns[3] = UserInputService.InputBegan:Connect(function(input)
		if GuiService.SelectedObject ~= b then
			return
		end
		local k = input.KeyCode
		local d = if k == Enum.KeyCode.DPadLeft or k == Enum.KeyCode.Left then -1 elseif k == Enum.KeyCode.DPadRight or k == Enum.KeyCode.Right then 1 else 0
		if d ~= 0 then
			set(math.clamp(get() + d * step, min, max))
			refresh()
		end
	end)
	b.Destroying:Connect(function()
		for _, c in conns do
			c:Disconnect()
		end
	end)
	b.Activated:Connect(function()
		-- A press on the row (gamepad A / Enter) steps up, wrapping to the minimum.
		if GuiService.SelectedObject == b then
			local v = get() + step
			set(if v > max then min else v)
			refresh()
		end
	end)
	refresh()
	return refresh
end

-- Navigation row (same shell as the setting rows) with an icon, label, description and a
-- chevron; red = the danger style (SettingsModal exit row: text-red-400, hover bg-red-600/20).
function MenuKit.navRow(parent: Instance, order: number, iconName: string?, label: string, desc: string?, red: boolean?): (TextButton, TextLabel)
	local b, right = settingRow(parent, order, label, desc, 64)
	if red then
		local col = b:FindFirstChild("Text")
		local first = col and col:FindFirstChildWhichIsA("TextLabel")
		if first then
			first.TextColor3 = C.RED400
		end
		MenuKit.hover(b, function(s)
			b.BackgroundColor3 = if s == "idle" then C.WHITE else C.RED600
			b.BackgroundTransparency = if s == "idle" then 0.95 else 0.8
		end)
	end
	if iconName then
		local col = b:FindFirstChild("Text") :: Frame
		local pad = b:FindFirstChildWhichIsA("UIPadding") :: UIPadding
		pad.PaddingLeft = UDim.new(0, 56)
		MenuKit.icon(iconName, {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -40, 0.5, 0),
			Size = UDim2.fromOffset(24, 24),
			ImageColor3 = if red then C.RED400 else C.WHITE,
			ImageTransparency = if red then 0 else 0.3,
			Parent = b,
		})
		col.Size = UDim2.new(1, -80, 0, 0)
	end
	local value = MenuKit.text({ Size = UDim2.new(1, -24, 1, 0), TextSize = 14, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = right })
	MenuKit.icon("Chevron", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(16, 16), ImageColor3 = if red then C.RED400 else C.WHITE, ImageTransparency = 0.5, Parent = right })
	return b, value
end

-- Modal (o-modal, not inline): full-screen bg-black/60 backdrop that closes on click, and a
-- centred page (w-[90%], max 900 px, max-h 100vh - 4rem, rounded-2xl). Phones get the page
-- full screen without rounding, like OpenFront below the lg breakpoint.
--   m = MenuKit.modal(screenGui, name)   m.page (MenuKit page), m.holder, m.onBack = fn
--   m.open(), m.close(), m.isOpen(), m.layout()
function MenuKit.modal(gui: Instance, name: string?): any
	local m: any = {}
	local holder = make("Frame", { Name = name or "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 50, Parent = gui })
	local dim = make("TextButton", {
		Name = "Backdrop",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundColor3 = C.BLACK,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = holder,
	})
	local box = make("Frame", { Name = "Box", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = C.GRAY900, BackgroundTransparency = 0.25, BorderSizePixel = 0, Active = true, Parent = holder })
	local boxCorner = MenuKit.corner(box, 16)
	m.onBack = function()
		m.close()
	end
	local page = MenuKit.page(box, "", function()
		m.onBack()
	end)
	page.frame.Size = UDim2.fromScale(1, 1)
	page.frame.Visible = true
	m.page, m.holder, m.box = page, holder, box
	pcall(function()
		(box :: any).SelectionGroup = true
		box.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
		box.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
		box.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
		box.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	end)
	dim.Activated:Connect(function()
		m.close()
	end)
	function m.layout()
		local root = gui :: any
		local sz = if root:IsA("GuiBase2d") then root.AbsoluteSize else Vector2.new(1280, 720)
		local mobile = sz.X < 640 or sz.Y < 420
		if mobile then
			box.Size = UDim2.fromScale(1, 1)
			boxCorner.CornerRadius = UDim.new(0, 0)
		else
			box.Size = UDim2.fromOffset(math.floor(math.min(900, sz.X * 0.9)), math.floor(math.min(760, sz.Y - 64)))
			boxCorner.CornerRadius = UDim.new(0, 16)
		end
		page:layout(mobile)
	end
	function m.isOpen(): boolean
		return holder.Visible
	end
	function m.open()
		m.layout()
		holder.Visible = true
	end
	function m.close()
		if not holder.Visible then
			return
		end
		holder.Visible = false
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(holder) then
			GuiService.SelectedObject = nil
		end
		if m.onClose then
			m.onClose()
		end
	end
	if gui:IsA("GuiBase2d") then
		(gui :: any):GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if holder.Visible then
				m.layout()
			end
		end)
	end
	return m
end

-- Centred empty state used for features that need OpenFront's backend (accounts, clans,
-- global leaderboards, cosmetics): mode_selector.coming_soon.
function MenuKit.comingSoon(parent: Instance, order: number, iconName: string, note: string?): Frame
	local f = make("Frame", { Name = "ComingSoon", LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
	MenuKit.pad(f, 24, 24, 48, 48)
	MenuKit.list(f, false, 12, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	MenuKit.icon(iconName, { LayoutOrder = 1, Size = UDim2.fromOffset(40, 40), ImageColor3 = C.WHITE, ImageTransparency = 0.6, Parent = f })
	MenuKit.text({ LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 24), FontFace = F.BOLD, TextSize = 18, Text = "COMING SOON", TextTransparency = 0.2, Parent = f })
	if note then
		MenuKit.paragraph(f, 3, note, { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.WHITE, TextTransparency = 0.6 })
	end
	return f
end

return MenuKit
