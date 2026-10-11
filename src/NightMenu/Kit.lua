-- War Front Night menu UI kit. Copyright (C) 2026 Liam (lacedsc3ne).
-- The building blocks every Night menu screen is made from (approved "B / Night map" mockups,
-- 11 October 2026). Sizes are desktop points; the menu root scales them per device with a UIScale.
--
-- Kit.C / Kit.F                               colour and font tokens
-- Kit.make(class, props) / corner / stroke / pad / list / flex     instance helpers
-- Kit.text(props) -> TextLabel                 defaults: transparent, body font, TEXT colour
-- Kit.icon(name, props) -> ImageLabel          NightMenu.Icons (white; tint with ImageColor3)
-- Kit.card(props) -> Frame                     raised card (CARD fill, LINE border, 12 px corners)
-- Kit.button(kind, text, opts) -> TextButton   kind "primary" | "robux" | "secondary" | "danger" | "ghost"
--     opts: icon, size (UDim2), height, textSize, onActivated(), layoutOrder, parent
--     returns the button; button:SetAttribute("Disabled", true) greys it out and ignores clicks
-- Kit.iconButton(icon, opts) -> TextButton     round icon-only button (back arrow, close, menu)
-- Kit.chip(text, opts) -> Frame                small pill (medals counter, tags); opts.icon, iconColor, color, textColor
-- Kit.toggle(on, onChanged) -> (Frame, set(on))
-- Kit.segmented(options, selected, onChanged, opts) -> (Frame, set(key))   options = { {key, text} }, opts.fill
-- Kit.number(parent, text, size, color) -> TextLabel   text centred in its parent (level circles, counters)
-- Kit.plusBadge(size) -> Frame             small round green "+" (add / buy more)
-- Kit.slider(min, max, value, step, onChanged) -> (Frame, set(value))
-- Kit.progress(fraction, color) -> (Frame, set(fraction))
-- Kit.tabs(list, active, onTab) -> (Frame, set(key))                 list = { {key, text} }
-- Kit.page(parent, title, opts) -> page   back-arrow header + scrolling body
--     opts: onBack(), right (GuiObject in the header), scroll (default true)
--     page.frame, page.header, page.body, page.back
-- Kit.popup(screenGui, opts) -> popup     dimmed backdrop + centred card; opts.width, onClose()
--     popup.frame (backdrop), popup.card, popup:close()
-- Kit.toast(screenGui, text, kind)        bottom message bubble, fades after 3 s; kind "ok" | "error" | "info"
-- Kit.hover(button, fn(state))            state "idle" | "hover" | "press" (gamepad selection counts as hover)
-- Kit.ring                                white gamepad selection outline (SelectionImageObject)

local TweenService = game:GetService("TweenService")

local Icons = require(script.Parent:WaitForChild("Icons"))
local Art = require(script.Parent:WaitForChild("Art")) -- the medal picture on medal prices / counters

local Kit = {}

local function rgb(hex: number): Color3
	return Color3.fromRGB(hex // 65536, (hex // 256) % 256, hex % 256)
end

-- Palette: medium blue (11 Oct 2026). Between the old dark navy and the bright blue "A" (too
-- strong) / slate (too grey): clearly blue, but darker and calmer. Old values:
-- ServerStorage.WarFrontTestUIBackups.20261011_before_palette_A (Night navy).
Kit.C = {
	BG = rgb(0x1e2f5c), -- screen background
	BACKDROP = rgb(0x0f1833), -- behind popups
	PAGE = rgb(0x243a6e), -- page / popup surface
	CARD = rgb(0x2a437c), -- cards and secondary buttons
	RAISED = rgb(0x36528f), -- selected rows, round icon buttons
	DEEP = rgb(0x18264a), -- wells: inputs, tracks, empty bars
	LINE = rgb(0x5670ad), -- borders
	MAP_LAND = rgb(0x22365f),
	MAP_EDGE = rgb(0x2d4573),
	TEXT = rgb(0xf4f7ff),
	MUTED = rgb(0xbcc8e6),
	YELLOW = rgb(0xffc94d), -- the one main action, highlights, medals
	YELLOW_TEXT = rgb(0x2a1d00),
	YELLOW_EDGE = rgb(0xc9951c),
	CYAN = rgb(0x84dcff), -- season / progress
	PINK = rgb(0xff6b8a), -- danger, leave, live
	GREEN = rgb(0x7ee2a8), -- done, owned, Robux prices
	GREEN_TEXT = rgb(0x073a1d),
	GREEN_EDGE = rgb(0x3fae6f),
	PURPLE = rgb(0xb39cff),
	WHITE = Color3.new(1, 1, 1),
}
local C = Kit.C

local function builder(weight: Enum.FontWeight): Font
	local ok, f = pcall(Font.fromName, "BuilderSans", weight)
	return if ok and f then f else Font.fromEnum(Enum.Font.GothamBold)
end

Kit.F = {
	TITLE = Font.new("rbxasset://fonts/families/FredokaOne.json"), -- headings, buttons, big numbers
	BOLD = builder(Enum.FontWeight.Bold), -- labels, rows
	BODY = builder(Enum.FontWeight.Medium), -- descriptions, small print
}
local F = Kit.F

-- Instance helpers ---------------------------------------------------------------------------

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
Kit.make = make

function Kit.corner(o: Instance, r: number?): UICorner
	return make("UICorner", { CornerRadius = if r then UDim.new(0, r) else UDim.new(0.5, 0), Parent = o })
end

function Kit.stroke(o: Instance, color: Color3?, thickness: number?): UIStroke
	return make("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = color or C.LINE,
		Thickness = thickness or 1.5,
		Parent = o,
	})
end

function Kit.pad(o: Instance, l: number, r: number?, t: number?, b: number?): UIPadding
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, l),
		PaddingRight = UDim.new(0, r or l),
		PaddingTop = UDim.new(0, t or 0),
		PaddingBottom = UDim.new(0, b or t or 0),
		Parent = o,
	})
end

function Kit.list(o: Instance, horizontal: boolean?, gap: number?, props: { [string]: any }?): UIListLayout
	local p = props or {}
	p.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	p.Padding = UDim.new(0, gap or 0)
	p.SortOrder = Enum.SortOrder.LayoutOrder
	p.Parent = o
	return make("UIListLayout", p)
end

-- Makes a list child fill the space left in its UIListLayout row / column.
function Kit.flex(o: Instance): UIFlexItem
	return make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill, Parent = o })
end

function Kit.text(props: { [string]: any }): TextLabel
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	props.BorderSizePixel = 0
	props.FontFace = props.FontFace or F.BOLD
	props.TextColor3 = props.TextColor3 or C.TEXT
	props.TextSize = props.TextSize or 16
	if props.Size == nil and props.AutomaticSize == nil then
		props.AutomaticSize = Enum.AutomaticSize.XY
		props.Size = UDim2.new()
	end
	return make("TextLabel", props)
end

-- Number or short word exactly centred in a circle / badge (fills the parent, centred both ways).
-- The title font draws digits a touch low, and a "1" leans right of its box, so the label is nudged
-- to put the ink in the middle.
function Kit.number(parent: Instance, text: string, size: number, color: Color3?): TextLabel
	local label = make("TextLabel", {
		Name = "Number",
		Text = text,
		FontFace = F.TITLE,
		TextSize = size,
		TextColor3 = color or C.TEXT,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = parent,
	})
	local function nudge()
		local dx = if string.sub(label.Text, 1, 1) == "1" then -math.floor(size * 0.07 + 0.5) else 0
		label.Position = UDim2.fromOffset(dx, -math.floor(size * 0.05 + 0.5))
	end
	label:GetPropertyChangedSignal("Text"):Connect(nudge)
	nudge()
	return label
end

function Kit.icon(name: string, props: { [string]: any }?): ImageLabel
	return Icons.image(name, props)
end
Kit.setIcon = Icons.set

function Kit.card(props: { [string]: any }?): Frame
	local p = props or {}
	p.BackgroundColor3 = p.BackgroundColor3 or C.CARD
	p.BorderSizePixel = 0
	local f = make("Frame", p)
	Kit.corner(f, 12)
	Kit.stroke(f, p.BorderColor3 ~= nil and p.BorderColor3 or nil)
	return f
end

-- Interaction feedback -----------------------------------------------------------------------

-- White rounded outline shown around whatever a controller has selected (console mockup).
Kit.ring = (function()
	local ring = make("Frame", {
		Name = "NightSelection",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 8, 1, 8),
		Position = UDim2.fromOffset(-4, -4),
	})
	Kit.corner(ring, 16)
	make("UIStroke", { Color = C.WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ring })
	return ring
end)()

function Kit.hover(b: GuiButton, fn: (string) -> ())
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
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			down = true
			update()
		end
	end)
	b.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			down = false
			update()
		end
	end)
	update()
end

local QUICK = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Buttons ------------------------------------------------------------------------------------

Kit.HOVER_RED = Color3.fromRGB(214, 64, 86) -- hover colour of Leave / danger buttons

local BUTTON = {
	primary = { face = C.YELLOW, edge = C.YELLOW_EDGE, text = C.YELLOW_TEXT, depth = 5 },
	robux = { face = C.GREEN, edge = C.GREEN_EDGE, text = C.GREEN_TEXT, depth = 4 },
	secondary = { face = C.CARD, edge = C.LINE, text = C.TEXT, depth = 0, stroke = true },
	danger = { face = C.CARD, edge = C.LINE, text = C.PINK, depth = 0, stroke = true },
	ghost = { face = C.CARD, edge = C.CARD, text = C.MUTED, depth = 0, transparent = true },
}

-- A pill button. Primary / robux have a darker bottom edge that the face sinks into on press.
function Kit.button(kind: string, text: string, opts: { [string]: any }?): TextButton
	local o = opts or {}
	local style = BUTTON[kind] or BUTTON.secondary
	local height = o.height or 44
	local depth = style.depth
	local b = make("TextButton", {
		Name = o.name or ("Button_" .. text),
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = style.edge,
		BackgroundTransparency = if style.transparent then 1 else 0,
		BorderSizePixel = 0,
		Size = o.size or UDim2.fromOffset(0, height),
		AutomaticSize = if o.size then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		LayoutOrder = o.layoutOrder or 0,
		SelectionImageObject = Kit.ring,
	})
	Kit.corner(b)
	local face = make("Frame", {
		Name = "Face",
		BackgroundColor3 = style.face,
		BackgroundTransparency = if style.transparent then 1 else 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -depth),
		AutomaticSize = b.AutomaticSize,
		Parent = b,
	})
	Kit.corner(face)
	if style.stroke then
		Kit.stroke(face)
	end
	Kit.pad(face, o.padX or (if height >= 52 then 32 else 18))
	Kit.list(face, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Center })
	local textSize = o.textSize or math.floor(height * 0.42)
	if o.icon == "Medal" then
		Art.image("Medal", { Name = "Icon", Size = UDim2.fromOffset(textSize + 6, textSize + 6), LayoutOrder = 1, Parent = face })
	elseif o.icon then
		Kit.icon(o.icon, {
			Name = "Icon",
			Size = UDim2.fromOffset(textSize + 2, textSize + 2),
			ImageColor3 = o.iconColor or style.text,
			LayoutOrder = 1,
			Parent = face,
		})
	end
	local label = Kit.text({
		Name = "Label",
		Text = text,
		FontFace = F.TITLE,
		TextSize = textSize,
		TextColor3 = style.text,
		LayoutOrder = 2,
		Parent = face,
	})
	if text == "" then
		label.Visible = false
	end
	local function disabled(): boolean
		return b:GetAttribute("Disabled") == true
	end
	-- Leave / danger buttons (and opts.redHover) turn red on hover.
	local redHover = kind == "danger" or o.redHover == true
	Kit.hover(b, function(state)
		local pressed = state == "press" and not disabled()
		local lit = state ~= "idle" and not disabled()
		local face3 = if lit and redHover then Kit.HOVER_RED elseif lit and not style.transparent then style.face:Lerp(C.WHITE, 0.12) else style.face
		TweenService:Create(face, QUICK, {
			Position = UDim2.fromOffset(0, if pressed then depth else 0),
			BackgroundColor3 = face3,
			BackgroundTransparency = if style.transparent then (if lit then 0 else 1) else 0,
		}):Play()
		if redHover then
			label.TextColor3 = if lit then C.WHITE else style.text
			local ic = face:FindFirstChild("Icon")
			if ic and ic:IsA("ImageLabel") and not o.iconColor then
				ic.ImageColor3 = if lit then C.WHITE else style.text
			end
		end
	end)
	b:GetAttributeChangedSignal("Disabled"):Connect(function()
		local off = disabled()
		face.BackgroundTransparency = if style.transparent then 1 elseif off then 0.5 else 0
		b.BackgroundTransparency = if style.transparent then 1 elseif off then 0.5 else 0
		label.TextTransparency = if off then 0.4 else 0
	end)
	if o.onActivated then
		b.Activated:Connect(function()
			if not disabled() then
				o.onActivated()
			end
		end)
	end
	if o.parent then
		b.Parent = o.parent
	end
	return b
end

function Kit.setButtonText(b: TextButton, text: string)
	local label = b:FindFirstChild("Label", true) :: TextLabel?
	if label then
		label.Text = text
		label.Visible = text ~= ""
	end
end

function Kit.iconButton(icon: string, opts: { [string]: any }?): TextButton
	local o = opts or {}
	local size = o.size or 36
	local b = make("TextButton", {
		Name = o.name or ("IconButton_" .. icon),
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = o.color or C.RAISED,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		LayoutOrder = o.layoutOrder or 0,
		SelectionImageObject = Kit.ring,
	})
	Kit.corner(b)
	Kit.icon(icon, {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.55, 0.55),
		ImageColor3 = o.iconColor or C.TEXT,
		Parent = b,
	})
	local base = b.BackgroundColor3
	Kit.hover(b, function(state)
		TweenService:Create(b, QUICK, {
			BackgroundColor3 = if state == "idle" then base else base:Lerp(C.WHITE, if state == "press" then 0.05 else 0.12),
		}):Play()
	end)
	if o.onActivated then
		b.Activated:Connect(o.onActivated)
	end
	if o.parent then
		b.Parent = o.parent
	end
	return b
end

function Kit.plusBadge(size: number): Frame
	local f = make("Frame", { Name = "Plus", BackgroundColor3 = C.GREEN, BorderSizePixel = 0, Size = UDim2.fromOffset(size, size) })
	Kit.corner(f)
	Kit.icon("Plus", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		ImageColor3 = C.GREEN_TEXT,
		Parent = f,
	})
	return f
end

function Kit.chip(text: string, opts: { [string]: any }?): Frame
	local o = opts or {}
	local f = make("Frame", {
		Name = o.name or "Chip",
		BackgroundColor3 = o.color or C.CARD,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, o.height or 32),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = o.layoutOrder or 0,
		Parent = o.parent,
	})
	Kit.corner(f)
	if o.stroke ~= false then
		Kit.stroke(f, o.strokeColor)
	end
	-- Line icons have some empty space round them, so the icon side gets a little less padding.
	Kit.pad(f, if o.icon then 9 else 12, 12)
	Kit.list(f, true, if o.icon then 4 else 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local ts = o.textSize or 15
	if o.icon == "Medal" then
		Art.image("Medal", { Name = "Icon", Size = UDim2.fromOffset(ts + 8, ts + 8), LayoutOrder = 1, Parent = f })
	elseif o.icon then
		Kit.icon(o.icon, { Name = "Icon", Size = UDim2.fromOffset(ts + 2, ts + 2), ImageColor3 = o.iconColor or C.TEXT, LayoutOrder = 1, Parent = f })
	end
	Kit.text({ Name = "Label", Text = text, FontFace = F.TITLE, TextSize = ts, TextColor3 = o.textColor or C.TEXT, LayoutOrder = 2, Parent = f })
	return f
end

-- Inputs -------------------------------------------------------------------------------------

function Kit.toggle(on: boolean, onChanged: ((boolean) -> ())?): (TextButton, (boolean) -> ())
	local b = make("TextButton", {
		Name = "Toggle",
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(46, 26),
		SelectionImageObject = Kit.ring,
	})
	Kit.corner(b)
	local knob = make("Frame", {
		Name = "Knob",
		BackgroundColor3 = C.WHITE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(20, 20),
		Parent = b,
	})
	Kit.corner(knob)
	local state = on
	local function set(v: boolean, animate: boolean?)
		state = v
		local goal = {
			Position = UDim2.new(0, if v then 23 else 3, 0.5, 0),
		}
		if animate then
			TweenService:Create(knob, QUICK, goal):Play()
			TweenService:Create(b, QUICK, { BackgroundColor3 = if v then C.GREEN else C.LINE }):Play()
		else
			knob.Position = goal.Position
			b.BackgroundColor3 = if v then C.GREEN else C.LINE
		end
	end
	set(on)
	b.Activated:Connect(function()
		set(not state, true)
		if onChanged then
			onChanged(state)
		end
	end)
	return b, function(v)
		set(v, true)
	end
end

-- A row of choices in a dark well; the chosen one is yellow. options = { {key, text} }.
-- Each choice is as wide as its words; opts.fill makes the choices share the well's full width instead.
function Kit.segmented(options: { any }, selected: any, onChanged: ((any) -> ())?, opts: { [string]: any }?): (Frame, (any) -> ())
	local compact = not (opts ~= nil and opts.fill == true)
	local well = make("Frame", {
		Name = "Segmented",
		BackgroundColor3 = C.DEEP,
		BorderSizePixel = 0,
		Size = if compact then UDim2.fromOffset(0, 38) else UDim2.new(1, 0, 0, 36),
		AutomaticSize = if compact then Enum.AutomaticSize.X else Enum.AutomaticSize.None,
	})
	Kit.corner(well, 12)
	Kit.pad(well, 3, 3, 3, 3)
	Kit.list(well, true, 3, { HorizontalFlex = if compact then Enum.UIFlexAlignment.None else Enum.UIFlexAlignment.Fill })
	local buttons = {}
	local current = selected
	local function paint()
		for key, btn in buttons do
			local on = key == current
			btn.BackgroundTransparency = if on then 0 else 1
			btn.TextColor3 = if on then C.YELLOW_TEXT else C.MUTED
		end
	end
	for i, opt in options do
		local key, label = opt[1], opt[2]
		local btn = make("TextButton", {
			Name = "Option_" .. tostring(key),
			Text = label,
			FontFace = F.TITLE,
			TextSize = 15,
			AutoButtonColor = false,
			BackgroundColor3 = C.YELLOW,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = if compact then Enum.AutomaticSize.X else Enum.AutomaticSize.None,
			LayoutOrder = i,
			SelectionImageObject = Kit.ring,
			Parent = well,
		})
		Kit.corner(btn, 10)
		if compact then
			Kit.pad(btn, 18)
		end
		buttons[key] = btn
		btn.Activated:Connect(function()
			if current ~= key then
				current = key
				paint()
				if onChanged then
					onChanged(key)
				end
			end
		end)
	end
	paint()
	return well, function(key)
		current = key
		paint()
	end
end

function Kit.progress(fraction: number, color: Color3?): (Frame, (number) -> ())
	local track = make("Frame", {
		Name = "Progress",
		BackgroundColor3 = C.DEEP,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 10),
		ClipsDescendants = true,
	})
	Kit.corner(track)
	local fill = make("Frame", {
		Name = "Fill",
		BackgroundColor3 = color or C.CYAN,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1),
		Parent = track,
	})
	Kit.corner(fill)
	return track, function(f)
		TweenService:Create(fill, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(math.clamp(f, 0, 1), 1) }):Play()
	end
end

-- Drag (mouse / touch) or Left / Right (gamepad while selected) to change a value.
function Kit.slider(min: number, max: number, value: number, step: number?, onChanged: ((number) -> ())?): (TextButton, (number) -> ())
	local st = step or 1
	local b = make("TextButton", {
		Name = "Slider",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(200, 26),
		SelectionImageObject = Kit.ring,
	})
	local track = make("Frame", {
		Name = "Track",
		BackgroundColor3 = C.DEEP,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = b,
	})
	Kit.corner(track)
	local fill = make("Frame", { Name = "Fill", BackgroundColor3 = C.CYAN, BorderSizePixel = 0, Parent = track })
	Kit.corner(fill)
	local knob = make("Frame", {
		Name = "Knob",
		BackgroundColor3 = C.WHITE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(20, 20),
		Parent = track,
	})
	Kit.corner(knob)
	local current = value
	local function set(v: number, fire: boolean?)
		v = math.clamp(math.floor((v - min) / st + 0.5) * st + min, min, max)
		local changed = v ~= current
		current = v
		local f = if max > min then (v - min) / (max - min) else 0
		fill.Size = UDim2.fromScale(f, 1)
		knob.Position = UDim2.fromScale(f, 0.5)
		if fire and changed and onChanged then
			onChanged(v)
		end
	end
	set(value)
	local dragging = false
	local function fromX(x: number)
		local f = (x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X)
		set(min + f * (max - min), true)
	end
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			fromX(input.Position.X)
		elseif input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.Left then
			set(current - st, true)
		elseif input.KeyCode == Enum.KeyCode.DPadRight or input.KeyCode == Enum.KeyCode.Right then
			set(current + st, true)
		end
	end)
	b.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			fromX(input.Position.X)
		end
	end)
	b.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	return b, function(v)
		set(v)
	end
end

-- Pill tabs (Shop: For you / Boosts / ...). list = { {key, text} }.
function Kit.tabs(list: { any }, active: any, onTab: ((any) -> ())?): (Frame, (any) -> ())
	local row = make("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	Kit.list(row, true, 4, { VerticalAlignment = Enum.VerticalAlignment.Center })
	local buttons = {}
	local current = active
	local function paint()
		for key, btn in buttons do
			local on = key == current
			btn.BackgroundTransparency = if on then 0 else 1
			btn.TextColor3 = if on then C.YELLOW_TEXT else C.MUTED
		end
	end
	for i, t in list do
		local key = t[1]
		local btn = make("TextButton", {
			Name = "Tab_" .. tostring(key),
			Text = t[2],
			FontFace = F.TITLE,
			TextSize = 16,
			AutoButtonColor = false,
			BackgroundColor3 = C.YELLOW,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(0, 32),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = i,
			SelectionImageObject = Kit.ring,
			Parent = row,
		})
		Kit.corner(btn)
		Kit.pad(btn, 14)
		buttons[key] = btn
		btn.Activated:Connect(function()
			if current ~= key then
				current = key
				paint()
				if onTab then
					onTab(key)
				end
			end
		end)
	end
	paint()
	return row, function(key)
		current = key
		paint()
	end
end

-- Pages and popups ---------------------------------------------------------------------------

function Kit.page(parent: Instance, title: string, opts: { [string]: any }?)
	local o = opts or {}
	local frame = make("Frame", {
		Name = "Page_" .. title,
		BackgroundColor3 = C.PAGE,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	Kit.corner(frame, 16)
	Kit.stroke(frame)
	local header = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 58),
		Parent = frame,
	})
	Kit.pad(header, 16, 16)
	Kit.list(header, true, 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
	make("Frame", {
		Name = "Divider",
		BackgroundColor3 = C.LINE,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 57),
		Size = UDim2.new(1, 0, 0, 1.5),
		Parent = frame,
	})
	local back = Kit.iconButton("Back", { name = "Back", layoutOrder = 1, parent = header, onActivated = o.onBack })
	Kit.text({ Name = "Title", Text = title, FontFace = F.TITLE, TextSize = 24, LayoutOrder = 2, Parent = header })
	if o.right then
		local spacer = make("Frame", { Name = "Spacer", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 1), LayoutOrder = 3, Parent = header })
		Kit.flex(spacer)
		o.right.LayoutOrder = 4
		o.right.Parent = header
	end
	local body
	if o.scroll == false then
		body = make("Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 59),
			Size = UDim2.new(1, 0, 1, -59),
			Parent = frame,
		})
	else
		body = make("ScrollingFrame", {
			Name = "Body",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, 59),
			Size = UDim2.new(1, 0, 1, -59),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = C.LINE,
			Selectable = false,
			Parent = frame,
		})
	end
	Kit.pad(body, 16, 16, 12, 16)
	return { frame = frame, header = header, body = body, back = back }
end

function Kit.popup(screenGui: Instance, opts: { [string]: any }?)
	local o = opts or {}
	local backdrop = make("TextButton", {
		Name = o.name or "Popup",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundColor3 = C.BACKDROP,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Parent = screenGui,
	})
	local card = make("Frame", {
		Name = "Card",
		BackgroundColor3 = C.PAGE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(o.width or 440, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 51,
		Parent = backdrop,
	})
	Kit.corner(card, 16)
	Kit.stroke(card, o.accent)
	Kit.pad(card, 20, 20, 20, 20)
	local scale = make("UIScale", { Scale = 0.92, Parent = card })
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	local popup = { frame = backdrop, card = card }
	function popup.close()
		if backdrop.Parent then
			backdrop:Destroy()
			if o.onClose then
				o.onClose()
			end
		end
	end
	if o.dismissable ~= false then
		backdrop.Activated:Connect(popup.close)
	end
	return popup
end

-- Card-coloured pill with white text; the kind shows in the icon and a thin border.
local TOAST = {
	ok = { bg = C.CARD, fg = C.TEXT, line = C.GREEN_EDGE, iconColor = C.GREEN, icon = "CheckCircle" },
	error = { bg = C.CARD, fg = C.TEXT, line = rgb(0xa33a52), iconColor = C.PINK, icon = "AlertCircle" },
	info = { bg = C.CARD, fg = C.TEXT, line = C.LINE, iconColor = C.YELLOW, icon = "Info" },
}

function Kit.toast(screenGui: Instance, text: string, kind: string?)
	local style = TOAST[kind or "info"] or TOAST.info
	local holder = screenGui:FindFirstChild("NightToasts")
	if not holder then
		holder = make("Frame", {
			Name = "NightToasts",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -24),
			Size = UDim2.fromOffset(600, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			ZIndex = 80,
			Parent = screenGui,
		})
		Kit.list(holder, false, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom })
	end
	local group = make("CanvasGroup", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 46),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 80,
		Parent = holder,
	})
	-- Room round the pill: the fade draws the group as one image, which would cut off the border.
	Kit.pad(group, 3, 3, 3, 3)
	local pill = make("Frame", {
		Name = "Pill",
		BackgroundColor3 = style.bg,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = group,
	})
	Kit.corner(pill)
	Kit.stroke(pill, style.line)
	Kit.pad(pill, 16)
	Kit.list(pill, true, 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
	Kit.icon(style.icon, { Size = UDim2.fromOffset(20, 20), ImageColor3 = style.iconColor, LayoutOrder = 1, Parent = pill })
	Kit.text({ Text = text, FontFace = F.BOLD, TextSize = 15, TextColor3 = style.fg, LayoutOrder = 2, Parent = pill })
	group.GroupTransparency = 1
	TweenService:Create(group, TweenInfo.new(0.2), { GroupTransparency = 0 }):Play()
	task.delay(3, function()
		if group.Parent then
			local t = TweenService:Create(group, TweenInfo.new(0.4), { GroupTransparency = 1 })
			t.Completed:Connect(function()
				group:Destroy()
			end)
			t:Play()
		end
	end)
end

return Kit
