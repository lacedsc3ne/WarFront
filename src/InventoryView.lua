-- Inventory presentation only. Match cosmetics and ownership are not changed here.
local Kit=require(script.Parent:WaitForChild("MenuKit"))
local make=Kit.make
local StoreView=require(script.Parent:WaitForChild("StoreView"))
local View={}
local NAVY=Color3.fromRGB(3,20,38)
local BLUE=Color3.fromRGB(0,196,241)
local MUTED=Color3.fromRGB(157,186,223)
local BLACK=Font.fromEnum(Enum.Font.GothamBlack)
local function rect(o,x,y,w,h) o.Position=UDim2.fromOffset(x,y);o.Size=UDim2.fromOffset(w,h) end
local function text(p,n,s,size,c)
 return Kit.text({Name=n,Text=s,TextSize=size,FontFace=BLACK,TextColor3=c or Color3.new(1,1,1),TextXAlignment=Enum.TextXAlignment.Left,TextWrapped=false,Parent=p})
end
local function surface(p,n)
 local f=make("Frame",{Name=n,BackgroundColor3=NAVY,BorderSizePixel=0,Parent=p})
 Kit.corner(f,4);Kit.stroke(f,0.2,Color3.fromRGB(46,131,182),1.5)
 return f
end
function View.prepare(page)
 if page.inventoryBaseLayout then
  if page.layout~=page.inventoryInstalledLayout then
   local previous=page.layout
   page.layout=function(self,mobile)
    previous(self,mobile)
    if self.inventoryShowing and self.title.Text=="INVENTORY" then self.inventoryLayout(self,mobile) end
   end
   page.inventoryInstalledLayout=page.layout
  end
  return
 end
 page.inventoryBaseLayout=page.layout
 page.inventoryBaseSelect=page.selectTab
 local base={background=page.frame.BackgroundColor3,backgroundAlpha=page.frame.BackgroundTransparency,tabAlpha=page.tabBar.BackgroundTransparency,borderColor=page.border.Color,borderAlpha=page.border.Transparency,borderWidth=page.border.Thickness,tabLayout=page.tabBar:FindFirstChildWhichIsA("UIListLayout")}
 local function paint(self)
  for key,b in self.tabButtons do
   local active=self.active==key
   b.TextColor3=if active then BLUE else MUTED;b.TextTransparency=0;b.BackgroundTransparency=1
   local line=b:FindFirstChild("Underline")
   if line then line.Visible=active;line.BackgroundColor3=BLUE;line.Size=UDim2.new(1,-32,0,4);line.Position=UDim2.new(0,16,1,-4) end
  end
 end
 page.inventoryLeave=function(self)
  self.header.Visible=true;self.back.Visible=true;self.title.Visible=true
  self.frame.BackgroundColor3=base.background;self.frame.BackgroundTransparency=base.backgroundAlpha
  self.border.Color=base.borderColor;self.border.Transparency=base.borderAlpha;self.border.Thickness=base.borderWidth
  self.tabBar.BackgroundTransparency=base.tabAlpha
  if base.tabLayout then base.tabLayout.Parent=self.tabBar end
  local st=self.tabBar:FindFirstChildWhichIsA("UIStroke");if st then st.Enabled=false end
 end
 page.selectTab=function(self,key)
  self.inventoryBaseSelect(self,key)
  if self.inventoryShowing and self.title.Text=="INVENTORY" then paint(self) end
 end
 page.layout=function(self,mobile)
  self.header.Visible=true;self.back.Visible=true;self.title.Visible=true
  self.frame.BackgroundColor3=base.background;self.frame.BackgroundTransparency=base.backgroundAlpha;self.tabBar.BackgroundTransparency=base.tabAlpha;self.border.Color=base.borderColor;self.border.Transparency=base.borderAlpha;self.border.Thickness=base.borderWidth
  if base.tabLayout then base.tabLayout.Parent=self.tabBar end
  local st=self.tabBar:FindFirstChildWhichIsA("UIStroke");if st then st.Enabled=false end
  self.inventoryBaseLayout(self,mobile)
  if not self.inventoryShowing or self.title.Text~="INVENTORY" then return end
  self.header.Visible=false;self.back.Visible=false;self.title.Visible=false
  self.frame.BackgroundColor3=NAVY;self.frame.BackgroundTransparency=1
  self.border.Enabled=false
  self.corner.CornerRadius=UDim.new(0,4)
  if base.tabLayout then base.tabLayout.Parent=nil end
  local w=self.frame.AbsoluteSize.X
  local edge=0
  local scale=math.clamp(w/1320,0.7,1.15)
  local h=if w<650 then 84 else 54*scale
  local cols=if w<650 then 3 else #self.tabs
  local rows=math.ceil(#self.tabs/cols)
  rect(self.tabBar,edge,0,w-2*edge,h)
  self.tabBar.BackgroundColor3=Color3.fromRGB(5,22,40);self.tabBar.BackgroundTransparency=0
  if not st then st=Kit.stroke(self.tabBar,0.2,Color3.fromRGB(63,131,187),1.5);Kit.corner(self.tabBar,6) end
  st.Color=Color3.fromRGB(63,131,187);st.Transparency=0.2;st.Thickness=1.5
  st.Enabled=true
  for i,tab in self.tabs do
   local b=self.tabButtons[tab.key]
   b.AutomaticSize=Enum.AutomaticSize.None
   rect(b,((i-1)%cols)*w/cols,math.floor((i-1)/cols)*h/rows,w/cols,h/rows)
   b.FontFace=BLACK;b.TextSize=if w<650 then 13 else 20*scale
   local pad=b:FindFirstChildWhichIsA("UIPadding");if pad then pad.PaddingLeft=UDim.new();pad.PaddingRight=UDim.new() end
  end
  paint(self)
  self.body.ScrollingEnabled=true;self.body.Active=true;self.body.ClipsDescendants=true
  self.body.AutomaticCanvasSize=Enum.AutomaticSize.Y;self.body.ScrollBarThickness=6
  self.body.ScrollBarImageColor3=BLUE;self.body.ScrollBarImageTransparency=0.15
  self.body.Position=UDim2.fromOffset(edge,h+14)
  self.body.Size=UDim2.new(1,-2*edge,1,-h-22)
  self.bodyPad.PaddingLeft=UDim.new();self.bodyPad.PaddingRight=UDim.new(0,6);self.bodyPad.PaddingTop=UDim.new();self.bodyPad.PaddingBottom=UDim.new(0,6)
 end
 page.inventoryLayout=page.layout
 page.inventoryInstalledLayout=page.layout
end
function View.render(page,ctx,tab,ownedEntries,loaded)
 local body=page.body
 local entries={}
 for _,entry in ownedEntries or {} do
  if entry.owned then table.insert(entries,entry) end
 end
 if #entries==0 then
  local root=make("Frame",{Name="InventoryCollection",LayoutOrder=1,BackgroundTransparency=1,Size=UDim2.new(1,0,0,240),Parent=body})
  local container=surface(root,"OwnedItemsContainer")
  container.BackgroundTransparency=0;Kit.corner(container,8)
  local message=text(container,"EmptyInventory",if loaded==false then "Loading your inventory..." else "You don't own any "..tab.." yet.",20,MUTED)
  message.TextXAlignment=Enum.TextXAlignment.Center;message.TextYAlignment=Enum.TextYAlignment.Center;message.TextWrapped=true
  local function fit()
   local w=math.max(0,body.AbsoluteSize.X-6)
   rect(container,0,0,w,240);rect(message,20,20,math.max(0,w-40),200)
  end
  local conn=body:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
  root.Destroying:Connect(function() conn:Disconnect() end);fit()
  return
 end
 local TEAL=Color3.fromRGB(69,214,178)
 local root=make("Frame",{Name="InventoryCollection",LayoutOrder=1,BackgroundTransparency=1,Size=UDim2.new(1,0,0,300),Parent=body})
 local container=surface(root,"OwnedItemsContainer")
 container.BackgroundTransparency=0
 Kit.corner(container,8)
 local grid=make("Frame",{Name="CollectionGrid",BackgroundTransparency=1,Parent=container})
 local items={}
 local equipping=false
 for i,entry in entries do
  local card=surface(grid,"Item"..i)
  card.ClipsDescendants=true
  local stroke=card:FindFirstChildWhichIsA("UIStroke")
  stroke.Color=if entry.equipped then TEAL else Color3.fromRGB(63,131,187)
  stroke.Thickness=if entry.equipped then 2 else 1.5
  make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(157,193,224)),Parent=card})
  local art=make("Frame",{Name="Artwork",BackgroundTransparency=1,ClipsDescendants=true,Parent=card})
  if entry.fill then entry.fill(art) end
  local badge=text(card,"OwnershipBadge",if entry.equipped then "EQUIPPED" else "OWNED",11,TEAL)
  badge.BackgroundColor3=Color3.fromRGB(9,49,49);badge.BackgroundTransparency=0
  badge.TextXAlignment=Enum.TextXAlignment.Center;Kit.corner(badge,4)
  local name=text(card,"ItemName",entry.name,18)
  name.TextXAlignment=Enum.TextXAlignment.Center;name.TextTruncate=Enum.TextTruncate.AtEnd
  local action=make("TextButton",{Name="EquipAction",Text=if entry.equipped then "EQUIPPED" else "EQUIP",FontFace=BLACK,TextSize=17,TextColor3=if entry.equipped then TEAL else NAVY,BackgroundColor3=if entry.equipped then Color3.fromRGB(9,49,49) else TEAL,BorderSizePixel=0,AutoButtonColor=false,Parent=card})
  Kit.corner(action,6);Kit.stroke(action,0.15,TEAL,1)
  make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(138,201,180)),Parent=action})
  action.Activated:Connect(function()
   if equipping or entry.equipped or not entry.equip then return end
   equipping=true;action.Text="EQUIPPING..."
   entry.equip(function()
    equipping=false
    if root.Parent then action.Text=if entry.equipped then "EQUIPPED" else "EQUIP" end
   end)
  end)
  table.insert(items,{card=card,art=art,badge=badge,name=name,action=action})
 end
 local function fit()
  local w=body.AbsoluteSize.X-6
  if w<1 then return end
  local gap=16
  local innerW=w-24
  local cols=StoreView.collectionColumns(innerW)
  local rows=math.ceil(#items/cols)
  local cw=math.floor((innerW-(cols-1)*gap)/cols)
  local ch=math.clamp(cw*1.22,220,280)
  local gh=rows*(ch+gap)-gap
  rect(container,0,0,w,gh+24)
  rect(grid,12,12,innerW,gh)
  root.Size=UDim2.new(1,0,0,gh+24)
  for i,item in items do
   rect(item.card,((i-1)%cols)*(cw+gap),math.floor((i-1)/cols)*(ch+gap),cw,ch)
   rect(item.art,12,32,cw-24,ch-112)
   rect(item.badge,cw-90,8,82,22)
   rect(item.name,10,ch-76,cw-20,24);item.name.TextSize=math.clamp(cw*0.085,12,18)
   rect(item.action,12,ch-44,cw-24,32);item.action.TextSize=math.clamp(cw*0.085,12,17)
  end
 end
 local conn=body:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
 root.Destroying:Connect(function() conn:Disconnect() end)
 fit()
end
return View
