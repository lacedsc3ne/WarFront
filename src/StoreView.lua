-- War Front store presentation. Product IDs, prices and purchase actions stay in MenuPages.
local Kit = require(script.Parent:WaitForChild("MenuKit"))
local Icons = require(script.Parent:WaitForChild("IconKit"))
local make = Kit.make
local View = {}
local NAVY = Color3.fromRGB(5, 22, 40)
local BLUE = Color3.fromRGB(0, 177, 235)
local MUTED = Color3.fromRGB(155, 184, 219)
local GOLD = Color3.fromRGB(255, 211, 35)
local ORANGE = Color3.fromRGB(255, 158, 40)
local BLACK = Font.fromEnum(Enum.Font.GothamBlack)
local BOLD = Font.fromEnum(Enum.Font.GothamBold)
local territoryImage
local function territory()
	if territoryImage then return territoryImage end
	local ok,img=pcall(function()
		local image=game:GetService("AssetService"):CreateEditableImage({Size=Vector2.new(96,96)})
		if not image then return nil end
		local points={{45,4},{54,4},{54,13},{63,13},{63,20},{73,20},{73,32},{83,32},{83,46},{91,46},{91,57},{81,57},{81,70},{69,70},{69,84},{57,84},{57,92},{44,92},{44,82},{29,82},{29,70},{16,70},{16,58},{7,58},{7,43},{17,43},{17,29},{29,29},{29,16},{45,16}}
		local pixels=buffer.create(96*96*4)
		for y=0,95 do for x=0,95 do
			local inside=false;local j=#points
			for i=1,#points do
				local a,b=points[i],points[j]
				if (a[2]>y)~=(b[2]>y) and x<(b[1]-a[1])*(y-a[2])/(b[2]-a[2])+a[1] then inside=not inside end
				j=i
			end
			if inside then buffer.writeu32(pixels,(y*96+x)*4,4294967295) end
		end end
		image:WritePixelsBuffer(Vector2.zero,image.Size,pixels)
		return image
	end)
	if ok then territoryImage=img end
	return territoryImage
end

local function label(parent, name, text, size, colour)
	return Kit.text({Name=name, Text=text, TextSize=size, FontFace=BLACK, TextColor3=colour or Color3.new(1,1,1), TextXAlignment=Enum.TextXAlignment.Left, Parent=parent})
end
local function rect(o,x,y,w,h)
	o.Position=UDim2.fromOffset(x,y);o.Size=UDim2.fromOffset(w,h)
end
local function surface(parent, name)
	local f=make("Frame",{Name=name,BackgroundColor3=NAVY,BackgroundTransparency=0,BorderSizePixel=0,Parent=parent})
	Kit.corner(f,4);Kit.stroke(f,0.2,Color3.fromRGB(63,131,187),1.5)
	make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.fromRGB(255,255,255),Color3.fromRGB(157,193,224)),Parent=f})
	return f
end

-- Shared generated medal artwork for shop balances and medal packs.
local MEDAL_IMAGE="rbxassetid://98450321632062"
function View.medal(parent, name)
 local holder=make("Frame",{Name=name or "Medal",BackgroundTransparency=1,ZIndex=2,Parent=parent})
 local art=make("ImageLabel",{Name="Medallion",Image=MEDAL_IMAGE,BackgroundTransparency=1,
  AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromScale(1,1),
  ScaleType=Enum.ScaleType.Fit,ZIndex=3,Parent=holder})
 make("UIAspectRatioConstraint",{AspectRatio=1,Parent=art})
 return holder
end

local purchaseImage
local function purchaseShape()
	if purchaseImage then return purchaseImage end
	local ok,img=pcall(function()
		local image=game:GetService("AssetService"):CreateEditableImage({Size=Vector2.new(320,64)})
		if not image then return nil end
		local pixels=buffer.create(320*64*4)
		for y=0,63 do for x=0,319 do
			if x+y>=12 and (319-x)+(63-y)>=12 then buffer.writeu32(pixels,(y*320+x)*4,4294967295) end
		end end
		image:WritePixelsBuffer(Vector2.zero,image.Size,pixels)
		return image
	end)
	if ok then purchaseImage=img end
	return purchaseImage
end

local hexImage
local function hexPattern()
	if hexImage then return hexImage end
	local ok,img=pcall(function()
		local im=game:GetService("AssetService"):CreateEditableImage({Size=Vector2.new(128,64)})
		if not im then return nil end
		local pixels=buffer.create(128*64*4)
		for cy=-16,80,32 do for cx=-24,152,48 do
			local offset=if math.floor(cy/32)%2==0 then 24 else 0
			for k=0,5 do
				local a=math.rad(k*60);local b=math.rad((k+1)*60)
				local ax,ay=cx+offset+18*math.cos(a),cy+18*math.sin(a)
				local bx,by=cx+offset+18*math.cos(b),cy+18*math.sin(b)
				for q=0,24 do
					local x,y=math.floor(ax+(bx-ax)*q/24),math.floor(ay+(by-ay)*q/24)
					if x>=0 and x<128 and y>=0 and y<64 then buffer.writeu32(pixels,(y*128+x)*4,0x22FFFFFF) end
				end
			end
		end end
		im:WritePixelsBuffer(Vector2.zero,im.Size,pixels);return im
	end)
	if ok then hexImage=img end
	return hexImage
end

function View.action(button,style,medalPurchase)
	if button:GetAttribute("StoreStyled") then return end
	button:SetAttribute("StoreStyled",true)
	local base=if style=="owned" then Color3.fromRGB(35,123,93) elseif medalPurchase then (if style=="gray" then ORANGE:Lerp(NAVY,0.25) else ORANGE) elseif style=="primary" then BLUE else Color3.fromRGB(39,61,85)
	button.AutoButtonColor=false;button.BackgroundColor3=base;button.BackgroundTransparency=0
	button.FontFace=BLACK;button.TextSize=18;button.TextTransparency=1
	local caption=label(button,"PriceLabel",button.Text,18)
	caption.TextXAlignment=Enum.TextXAlignment.Center;caption.Size=UDim2.fromScale(1,1);caption.ZIndex=4
	if medalPurchase then caption.TextColor3=NAVY;button:SetAttribute("Currency","Medals") end
	caption.TextTruncate=Enum.TextTruncate.AtEnd
	caption.TextScaled=true;caption.TextWrapped=false
	make("UITextSizeConstraint",{MinTextSize=12,MaxTextSize=44,Parent=caption})
	button:GetPropertyChangedSignal("Text"):Connect(function() caption.Text=button.Text end)
	button:GetPropertyChangedSignal("TextSize"):Connect(function() caption.TextSize=button.TextSize end)
	local shape=purchaseShape()
	local fill
	if shape then
		for _,child in button:GetChildren() do if child:IsA("UICorner") or child:IsA("UIStroke") or child:IsA("UIGradient") then child:Destroy() end end
		button.BackgroundTransparency=1
		make("ImageLabel",{Name="PurchaseOutline",BackgroundTransparency=1,ImageContent=Content.fromObject(shape),ImageColor3=if medalPurchase then Color3.fromRGB(255,206,110) elseif style=="primary" then Color3.fromRGB(75,218,255) else MUTED,Size=UDim2.fromScale(1,1),ZIndex=1,Parent=button})
		fill=make("ImageLabel",{Name="PurchaseSurface",BackgroundTransparency=1,ImageContent=Content.fromObject(shape),ImageColor3=base,Position=UDim2.fromOffset(2,2),Size=UDim2.new(1,-4,1,-4),ZIndex=2,Parent=button})
		make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),(if medalPurchase then Color3.fromRGB(255,155,80) else Color3.fromRGB(117,182,222))),Parent=fill})
	else
		Kit.corner(button,8)
	end
	local pattern=hexPattern()
	if pattern then make("ImageLabel",{Name="HexPattern",BackgroundTransparency=1,ImageContent=Content.fromObject(pattern),Position=UDim2.fromOffset(12,3),Size=UDim2.new(1,-24,1,-6),ScaleType=Enum.ScaleType.Tile,TileSize=UDim2.fromOffset(128,64),ZIndex=3,Parent=button}) end
	Kit.hover(button,function(state)
		local colour=if state=="press" then base:Lerp(Color3.new(0,0,0),0.12) elseif state=="hover" then base:Lerp(Color3.new(1,1,1),0.12) else base
		button.BackgroundColor3=colour
		if fill then fill.ImageColor3=colour end
	end)
end

local function buyButton(parent, text, owned, click)
	local button=make("TextButton",{Name="Purchase",Text=text,BorderSizePixel=0,Parent=parent})
	View.action(button,if owned then "owned" else "primary")
	if not owned then button.Activated:Connect(click) end
	return button
end

local function colours(parent)
	local art=make("Frame",{Name="TerritoryColours",BackgroundTransparency=1,Parent=parent})
	for i,c in {Color3.fromRGB(85,186,41),Color3.fromRGB(46,128,247),Color3.fromRGB(224,61,74),GOLD,Color3.fromRGB(158,69,235),Color3.fromRGB(255,141,34)} do
		local shape=territory()
		local cell=make("Frame",{Name="Colour"..i,Position=UDim2.new((i-1)%3/3,3,math.floor((i-1)/3)/2,3),Size=UDim2.new(1/3,-6,0.5,-6),BackgroundColor3=if shape then NAVY else c,BorderSizePixel=0,Parent=art})
		Kit.corner(cell,8);Kit.stroke(cell,0.25,c:Lerp(Color3.new(1,1,1),0.5),1.5)
		if shape then make("ImageLabel",{Name="Territory",BackgroundTransparency=1,ImageContent=Content.fromObject(shape),ImageColor3=c,Position=UDim2.fromScale(0.08,0.08),Size=UDim2.fromScale(0.84,0.84),ScaleType=Enum.ScaleType.Fit,Parent=cell}) end
		make("UIGradient",{Rotation=45,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(145,173,190)),Parent=cell})
	end
	return art
end

local STORE_ART="rbxassetid://130927865622719"
local function illustration(parent,name,x,y,w,h)
 return make("ImageLabel",{Name=name,BackgroundTransparency=1,Image=STORE_ART,ImageRectOffset=Vector2.new(math.round(x*1023/1672),math.round(y*576/941)),ImageRectSize=Vector2.new(math.round(w*1023/1672),math.round(h*576/941)),Parent=parent})
end
local function referencePurchase(parent,caption,owned,click)
 local b=buyButton(parent,caption,owned,click)
 local price=b:FindFirstChild("PriceLabel")
 local hex=b:FindFirstChild("HexPattern");if hex then hex.ImageTransparency=0.8 end
 if not owned then
  local icon=illustration(b,"RobuxIcon",657,499,33,32);icon.ZIndex=4
  local function fitPrice()
   local bh=b.Size.Y.Offset
   local fs=b.TextSize
   local tw=game:GetService("TextService"):GetTextSize(b.Text,fs,Enum.Font.GothamBlack,Vector2.new(2000,100)).X
   local ih=math.max(18,bh*0.57)
   local start=(b.Size.X.Offset-tw-ih-12)/2
   rect(icon,start,(bh-ih)/2,ih,ih)
   rect(price,start+ih+12,0,tw,bh)
  end
  b:GetPropertyChangedSignal("Size"):Connect(fitPrice)
  b:GetPropertyChangedSignal("Text"):Connect(fitPrice)
  b:GetPropertyChangedSignal("TextSize"):Connect(fitPrice)
  fitPrice()
 end
 return b
end
function View.colourPreview(parent,rgb)
 local colour=Color3.fromRGB(rgb[1],rgb[2],rgb[3])
 local shape=territory()
 local f=make("Frame",{Name="OwnedColourPreview",BackgroundColor3=NAVY,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Parent=parent})
 if shape then make("ImageLabel",{Name="Territory",BackgroundTransparency=1,ImageContent=Content.fromObject(shape),ImageColor3=colour,Position=UDim2.fromScale(0.08,0.08),Size=UDim2.fromScale(0.84,0.84),ScaleType=Enum.ScaleType.Fit,Parent=f})
 else local swatch=make("Frame",{BackgroundColor3=colour,BorderSizePixel=0,Position=UDim2.fromScale(0.2,0.1),Size=UDim2.fromScale(0.6,0.8),Parent=f});Kit.corner(swatch,8) end
 return f
end
function View.featured(page,profile,api,medalsOnly)
 local body=page.body
 local root=make("Frame",{Name="FeaturedOffers",LayoutOrder=2,BackgroundTransparency=1,Size=UDim2.new(1,0,0,560),Parent=body})
 local offers={}
 if not medalsOnly then
  for i,v in {{id=api.config.GAMEPASS.VIP,title="VIP",desc="1.5× XP & medals",note="Gold name • VIP tag",owned=profile.vip},{id=api.config.GAMEPASS.AllColors,title="ALL COLOURS",desc="Unlock every territory colour",owned=profile.allColors}} do
   if v.id~=0 then
    local card=surface(root,if i==1 then "VIP" else "AllColours")
    card.BackgroundTransparency=0
    local title=label(card,"OfferTitle",v.title,if i==1 then 76 else 40,if i==1 then GOLD else nil)
    local desc=label(card,"Description",v.desc,if i==1 then 27 else 19,if i==1 then Color3.new(1,1,1) else MUTED);desc.FontFace=BOLD
    local note=label(card,"Note",v.note or "",20,MUTED);note.FontFace=BOLD
    local art=make("ImageLabel",{Name=if i==1 then "Crown" else "TerritoryColours",
     BackgroundTransparency=1,Image=if i==1 then "rbxassetid://97300252123841" else "rbxassetid://128790526498593",
     ScaleType=Enum.ScaleType.Fit,Parent=card})
    local b=referencePurchase(card,if v.owned then "OWNED" else api.price(true,v.id),v.owned,function() api.buyPass(v.id) end)
    b:SetAttribute("ProductId",v.id);b:SetAttribute("PurchaseType","GamePass")
    local line=make("Frame",{Name="Divider",BackgroundColor3=Color3.fromRGB(60,132,188),BorderSizePixel=0,Parent=card})
    local tag
    if i==1 then
     make("Frame",{Name="GoldAccent",Size=UDim2.new(1,0,0,6),BackgroundColor3=GOLD,BorderSizePixel=0,Parent=card})
     tag=label(card,"GamePass","GAME PASS",16,NAVY);tag.BackgroundColor3=GOLD;tag.BackgroundTransparency=0;tag.TextXAlignment=Enum.TextXAlignment.Center
    else line.Visible=false end
    table.insert(offers,{card=card,title=title,desc=desc,note=note,art=art,b=b,line=line,tag=tag,vip=i==1})
   end
  end
 end
 local heading=label(root,"MedalPacksTitle","MEDAL PACKS",36)
 heading.TextStrokeColor3=Color3.new(0,0,0);heading.TextStrokeTransparency=0.25
 local packs=make("Frame",{Name="MedalPacks",BackgroundTransparency=1,Parent=root})
 local items={}
 for _,p in api.config.PRODUCTS do
  if p.id~=0 then
   local card=surface(packs,"MedalPack"..p.coins)
   local i=#items+1
   local art=View.medal(card,"MedalArt")
   local amount=label(card,"Amount",api.number(p.coins),48)
   local currency=label(card,"Currency","MEDALS",29,MUTED);currency.FontFace=BOLD
   local line=make("Frame",{Name="Divider",BackgroundColor3=Color3.fromRGB(60,132,188),BorderSizePixel=0,Parent=card})
   local b=referencePurchase(card,api.price(false,p.id),false,function() api.buyProduct(p.id) end)
   b:SetAttribute("ProductId",p.id);b:SetAttribute("PurchaseType","Product")
   local tag
   if p.coins==1500 then tag=label(card,"Popular","POPULAR",16,NAVY);tag.BackgroundColor3=BLUE;tag.BackgroundTransparency=0;tag.TextXAlignment=Enum.TextXAlignment.Center end
   table.insert(items,{card=card,art=art,amount=amount,currency=currency,line=line,b=b,tag=tag})
  end
 end
 local function fit()
  local w=body.AbsoluteSize.X-page.bodyPad.PaddingRight.Offset
  if w<1 then return end
  local phone=w<650
  local scale=math.clamp(w/1320,0.65,1.15)
  local gap=14*scale
  local fh=260*scale
  local ph=224*scale
  local headingH=46*scale
  local packY=if medalsOnly then headingH+gap else fh+2*gap+headingH
  if phone then fh=230;ph=224;packY=if medalsOnly then headingH+gap else #offers*(fh+gap)+headingH+gap end
  root.Size=UDim2.new(1,0,0,packY+(if phone then #items*(ph+gap)-gap else ph))
  for i,v in offers do
   local cw=if phone then w else (w-gap)*(if v.vip then 0.57 else 0.43)
   rect(v.card,if phone or i==1 then 0 else (w-gap)*0.57+gap,if phone then (i-1)*(fh+gap) else 0,cw,fh)
   if v.vip then
    local tx=cw*0.49
    rect(v.art,8,fh*0.20,cw*0.44,fh*0.76)
    rect(v.line,cw*0.46,fh*0.16,1,fh*0.70)
    rect(v.tag,16,16,128*scale,28*scale);v.tag.TextSize=16*scale
    rect(v.title,tx,fh*0.11,cw-tx-22,fh*0.28);v.title.TextSize=math.min(76*scale,(cw-tx-22)*0.3)
    rect(v.desc,tx,fh*0.43,cw-tx-22,34*scale);v.desc.TextSize=math.min(27*scale,(cw-tx-22)/12)
    rect(v.note,tx,fh*0.58,cw-tx-22,26*scale);v.note.TextSize=20*scale
    rect(v.b,tx,fh*0.72,cw-tx-22,fh*0.21);v.b.TextSize=31*scale
   else
    local textW=cw*0.53
    rect(v.title,22,fh*0.12,textW,50*scale);v.title.TextSize=math.min(40*scale,textW/7)
    rect(v.desc,22,fh*0.35,textW,28*scale);v.desc.TextSize=math.min(19*scale,textW/16)
    v.note.Visible=false
    rect(v.art,cw*0.58,fh*0.10,cw*0.39,fh*0.64)
    rect(v.b,22,fh*0.73,textW,fh*0.20);v.b.TextSize=28*scale
   end
  end
  rect(heading,0,packY-headingH-gap,w,headingH);heading.TextSize=36*scale
  rect(packs,0,packY,w,if phone then #items*(ph+gap)-gap else ph)
  local cw=if phone then w else (w-(#items-1)*gap)/math.max(1,#items)
  for i,v in items do
   rect(v.card,if phone then 0 else (i-1)*(cw+gap),if phone then (i-1)*(ph+gap) else 0,cw,ph)
   rect(v.art,16,ph*0.10,cw*0.49-18,ph*0.57)
   rect(v.line,cw*0.52,ph*0.14,1,ph*0.50)
   rect(v.amount,cw*0.58,ph*0.19,cw*0.40-8,ph*0.24);v.amount.TextSize=math.min(48*scale,cw*0.13)
   rect(v.currency,cw*0.58,ph*0.43,cw*0.40-8,ph*0.18);v.currency.TextSize=28*scale
   rect(v.b,18,ph*0.71,cw-36,ph*0.23);v.b.TextSize=28*scale
   if v.tag then rect(v.tag,0,0,115*scale,28*scale);v.tag.TextSize=16*scale end
  end
 end
 local conn=body:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
 root.Destroying:Connect(function() conn:Disconnect() end)
 fit()
end

-- Five collection cards per desktop row; keep touch cards readable on phones.
function View.collectionColumns(width)
 return if width>=650 then 5 elseif width>=360 then 2 else 1
end

function View.prepare(page)
 if page.storeLayout then return end
 page.storeLayout=page.layout
 page.storeSelectTab=page.selectTab
 local original={font=page.title.FontFace,background=page.frame.BackgroundColor3,backgroundAlpha=page.frame.BackgroundTransparency,clips=page.frame.ClipsDescendants,backCorner=page.back:FindFirstChildWhichIsA("UICorner").CornerRadius,borderColour=page.border.Color,borderAlpha=page.border.Transparency,borderWidth=page.border.Thickness,backParent=page.back.Parent,backSize=page.back.Size,backAnchor=page.back.AnchorPoint,backBG=page.back.BackgroundColor3,backAlpha=page.back.BackgroundTransparency,tabLayout=page.tabBar:FindFirstChildWhichIsA("UIListLayout"),scrollColour=page.body.ScrollBarImageColor3,scrollAlpha=page.body.ScrollBarImageTransparency}
 local backCaption=label(page.back,"BackCaption","BACK TO PLAY",18)
 backCaption.TextXAlignment=Enum.TextXAlignment.Center;backCaption.Position=UDim2.fromOffset(30,0);backCaption.Size=UDim2.new(1,-36,1,0);backCaption.Visible=false
 local function paint(self)
  for key,b in self.tabButtons do
   local on=self.active==key
   b.TextColor3=if on then BLUE else MUTED;b.TextTransparency=0;b.BackgroundTransparency=1
   local line=b:FindFirstChild("Underline")
   if line then line.Visible=on;line.BackgroundColor3=BLUE;line.Position=UDim2.new(0,18,1,-4);line.Size=UDim2.new(1,-36,0,5) end
  end
 end
 page.selectTab=function(self,key)
  self.storeSelectTab(self,key)
  if self.storeShowing and self.title.Text=="STORE" then paint(self) end
 end
 page.layout=function(self,mobile)
  self.header.Parent=self.frame;self.header.Visible=true
  self.back.Parent=original.backParent;self.back.AnchorPoint=original.backAnchor;self.back.Size=original.backSize;self.back.Visible=true;self.back.Text=""
  self.back.BackgroundColor3=original.backBG;self.back.BackgroundTransparency=original.backAlpha
  backCaption.Visible=false
  self.title.Visible=true;self.title.FontFace=original.font
  self.title.AnchorPoint=Vector2.new(0,0.5);self.title.TextXAlignment=Enum.TextXAlignment.Left
  self.frame.BackgroundColor3=original.background;self.frame.BackgroundTransparency=original.backgroundAlpha;self.frame.ClipsDescendants=original.clips
  self.back:FindFirstChildWhichIsA("UICorner").CornerRadius=original.backCorner
  self.border.Color=original.borderColour;self.border.Transparency=original.borderAlpha;self.border.Thickness=original.borderWidth
  self.tabBar.BackgroundTransparency=1
  self.body.ScrollBarImageColor3=original.scrollColour;self.body.ScrollBarImageTransparency=original.scrollAlpha
  if original.tabLayout then original.tabLayout.Parent=self.tabBar end
  local stroke=self.tabBar:FindFirstChildWhichIsA("UIStroke");if stroke then stroke.Enabled=false end
  self.storeLayout(self,mobile)
  local coins=self.header:FindFirstChild("StoreCoins")
  local active=self.storeShowing and self.title.Text=="STORE"
  if not active then if coins then coins.Visible=false end;return end
  local w=self.frame.AbsoluteSize.X
  local phone=w<650
  local scale=math.clamp(w/1320,0.7,1.15)
  local headerH=if phone then 48 else 0
  local tabsH=if phone then 84 else 54*scale
  local balanceW=if phone then math.min(w-40,220) else 262*scale
  local tabsW=if phone then w else w-balanceW-14
  self.frame.BackgroundTransparency=1;self.frame.ClipsDescendants=false;self.border.Enabled=false
  self.header.Size=UDim2.fromOffset(w,if phone then headerH else tabsH);self.header.Position=UDim2.fromOffset(0,0)
  local div=self.header:FindFirstChild("Divider");if div then div.Visible=false end
  self.title.Visible=false
  if coins then
   coins.Visible=true;coins.AnchorPoint=Vector2.zero;coins.TextTransparency=1;coins.BackgroundColor3=NAVY;coins.BackgroundTransparency=0
   local bw=balanceW
   rect(coins,w-bw,0,bw,if phone then 36 else tabsH)
   if not coins:FindFirstChildWhichIsA("UIStroke") then Kit.stroke(coins,0.2,Color3.fromRGB(63,131,187),1.5);Kit.corner(coins,6) end
   local icon=coins:FindFirstChild("CurrencyArt")
   if icon and (not icon:FindFirstChild("Medallion") or not icon.Medallion:IsA("ImageLabel") or icon.Medallion.Image~=MEDAL_IMAGE) then icon:Destroy();icon=nil end
   if not icon then icon=View.medal(coins,"CurrencyArt") end
   local balance=coins:FindFirstChild("BalanceAmount")
   if not balance then
    balance=label(coins,"BalanceAmount","",36,GOLD)
    balance.TextXAlignment=Enum.TextXAlignment.Right
    balance.TextScaled=true;make("UITextSizeConstraint",{MinTextSize=14,MaxTextSize=36,Parent=balance})
    local function update() balance.Text=coins.Text:match("^(.-)%s+[Mm][Ee][Dd][Aa][Ll][Ss]$") or (if coins.Text=="" then "—" else coins.Text) end
    coins:GetPropertyChangedSignal("Text"):Connect(update);update()
   end
   local unit=coins:FindFirstChild("BalanceCurrency")
   if not unit then unit=label(coins,"BalanceCurrency","MEDALS",22,MUTED);unit.FontFace=BOLD end
   local bh=coins.Size.Y.Offset
   rect(icon,16,bh*0.15,bh*0.7,bh*0.7)
   rect(balance,bh*0.92,0,bw-bh*0.92-102*scale,bh);balance.TextSize=32*scale
   rect(unit,bw-92*scale,0,86*scale,bh);unit.TextSize=21*scale
  end
  if original.tabLayout then original.tabLayout.Parent=nil end
  rect(self.tabBar,0,headerH,tabsW,tabsH)
  self.tabBar.BackgroundColor3=NAVY;self.tabBar.BackgroundTransparency=0
  if not stroke then stroke=Kit.stroke(self.tabBar,0.2,Color3.fromRGB(63,131,187),1.5);Kit.corner(self.tabBar,6) end
  stroke.Enabled=true
  local cols=if phone then 3 else #self.tabs
  local rows=math.ceil(#self.tabs/cols)
  for i,t in self.tabs do
   local b=self.tabButtons[t.key];b.AutomaticSize=Enum.AutomaticSize.None
   rect(b,((i-1)%cols)*tabsW/cols,math.floor((i-1)/cols)*tabsH/rows,tabsW/cols,tabsH/rows)
   b.FontFace=BLACK;b.TextSize=if phone then 13 else 20*scale
   local pad=b:FindFirstChildWhichIsA("UIPadding");if pad then pad.PaddingLeft=UDim.new();pad.PaddingRight=UDim.new() end
  end
  paint(self)
  local bodyY=headerH+tabsH+14
  self.body.Position=UDim2.fromOffset(0,bodyY);self.body.Size=UDim2.new(1,0,1,-bodyY-64)
  self.body.ScrollingEnabled=true;self.body.Active=true;self.body.ClipsDescendants=true
  self.body.AutomaticCanvasSize=Enum.AutomaticSize.Y;self.body.ScrollBarThickness=6
  self.body.ScrollBarImageColor3=BLUE;self.body.ScrollBarImageTransparency=0.2
  self.bodyPad.PaddingLeft=UDim.new();self.bodyPad.PaddingRight=UDim.new(0,8);self.bodyPad.PaddingTop=UDim.new();self.bodyPad.PaddingBottom=UDim.new(0,8)
  self.back.Parent=self.frame;self.back.AnchorPoint=Vector2.zero
  rect(self.back,24-self.frame.Position.X.Offset,self.frame.AbsoluteSize.Y-50,242*scale,44*scale)
  self.back.BackgroundColor3=NAVY;self.back.BackgroundTransparency=0
  self.back:FindFirstChildWhichIsA("UICorner").CornerRadius=UDim.new(0,4)
  backCaption.Visible=true;backCaption.TextSize=18*scale
  local arrow=self.back:FindFirstChildWhichIsA("ImageLabel");if arrow then arrow.Position=UDim2.fromOffset(16,11*scale);arrow.Size=UDim2.fromOffset(22*scale,22*scale);arrow.AnchorPoint=Vector2.zero end
 end
end

function View.decorate(page)
	for _,o in page.body:GetDescendants() do
		if o:IsA("Frame") and o.Name=="Card" then
			o.BackgroundColor3=NAVY;o.BackgroundTransparency=0
			local s=o:FindFirstChildWhichIsA("UIStroke");if s then s.Color=Color3.fromRGB(63,131,187);s.Transparency=0.2 end
		elseif o:IsA("TextLabel") or o:IsA("TextButton") then
			o.FontFace=if o.FontFace.Weight==Enum.FontWeight.Bold then BOLD else o.FontFace
		end
	end
end
return View

