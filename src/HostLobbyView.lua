-- Create Lobby presentation only. Settings and network actions stay in LobbyPages.
local Kit=require(script.Parent:WaitForChild("MenuKit"))
local C,F,make=Kit.C,Kit.F,Kit.make
local View={}
local SWITCH_ON=Color3.fromRGB(33,190,110)
local SWITCH_OFF=Color3.fromRGB(220,65,77)
local favourites={} -- Kept when the page is reopened during this session.

function View.stylePage(page)
 if page.hostLayout then return end
 local layout,clear=page.layout,page.clear
 local frame,header=page.frame,page.header
 local divider=header:FindFirstChild("Divider")
 local saved={alpha=frame.BackgroundTransparency,colour=frame.BackgroundColor3,headerAlpha=header.BackgroundTransparency,headerColour=header.BackgroundColor3,divider=divider and divider.Visible,bodyAlpha=page.body.BackgroundTransparency,bodyColour=page.body.BackgroundColor3}
 page.layout=function(self,mobile)
  layout(self,mobile)
  self.frame.BackgroundColor3=Color3.fromRGB(5,22,40);self.frame.BackgroundTransparency=0;self.border.Enabled=false
  self.header.BackgroundColor3=Color3.fromRGB(5,22,40);self.header.BackgroundTransparency=0
  self.body.BackgroundColor3=Color3.fromRGB(5,22,40);self.body.BackgroundTransparency=0
  if divider then divider.Visible=false end
 end
 page.clear=function(self)
  self.layout=layout;self.clear=clear;self.hostLayout=nil
  frame.BackgroundTransparency=saved.alpha;frame.BackgroundColor3=saved.colour
  header.BackgroundTransparency=saved.headerAlpha;header.BackgroundColor3=saved.headerColour
  self.body.BackgroundTransparency=saved.bodyAlpha;self.body.BackgroundColor3=saved.bodyColour
  if divider then divider.Visible=saved.divider end
  clear(self);layout(self,self.mobile)
 end
 page.hostLayout=true;page:layout(page.mobile)
end

local THUMBNAIL_ASSET="rbxassetid://123526786397636"
local THUMBNAIL_REGIONS={
 World={0,0,800,400,"rbxassetid://131085760210363"},NorthAmerica={0,0,704,608,"rbxassetid://127645978925542"},Britannia={0,0,480,640,"rbxassetid://89887823831230"},
 Europe={0,0,704,640,"rbxassetid://83361553562776"},
 Africa={0,0,640,608,"rbxassetid://121858660429391"},
 UnitedStates={0,0,704,392,"rbxassetid://127821727590057"},
 Alps={0,0,704,448,"rbxassetid://72288144375553"},
 Italia={0,0,544,640,"rbxassetid://90980522725639"},
}

local function responsiveGrid(parent,order,minWidth,height,name)
 local frame=make("Frame",{Name=name,LayoutOrder=order,BackgroundTransparency=1,Size=UDim2.new(1,0,0,0),Parent=parent})
 local layout=make("UIGridLayout",{CellPadding=UDim2.fromOffset(10,10),SortOrder=Enum.SortOrder.LayoutOrder,Parent=frame})
 local function fit()
  local w=math.max(100,frame.AbsoluteSize.X)
  local count=0;for _,x in frame:GetChildren() do if x:IsA("GuiObject") and x.Visible then count+=1 end end
  local maximum=if name=="EnabledUnits" then 5 elseif name=="AllMaps" then 4 else math.max(1,count)
  local columns=math.max(1,math.min(maximum,math.max(1,count),math.floor((w+10)/(minWidth+10))))
  layout.CellSize=UDim2.fromOffset(math.floor((w-10*(columns-1))/columns),height)
  local rows=math.ceil(count/columns)
  frame.Size=UDim2.new(frame.Size.X.Scale,frame.Size.X.Offset,0,if rows==0 then 0 else rows*height+math.max(0,rows-1)*10)
 end
 frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
 return frame,fit
end

local function label(parent,value,props)
 props=props or {};props.Text=value;props.Parent=parent;return Kit.text(props)
end

local function choice(parent,value,order,onClick)
 local b=Kit.button("secondary",{Name=value,LayoutOrder=order,Size=UDim2.new(1,0,0,44),Text=value,FontFace=F.BOLD,TextSize=15,Parent=parent})
 b.Activated:Connect(onClick)
 return b
end

local function highlight(button,on,colour)
 button.BackgroundColor3=if on then colour or C.BLUE600 else Color3.fromRGB(17,35,55)
 button.BackgroundTransparency=if on then 0.08 else 0.15
 local stroke=button:FindFirstChildWhichIsA("UIStroke")
 if stroke then stroke.Color=if on then colour or C.MALIBU else Color3.fromRGB(63,87,112);stroke.Transparency=if on then 0 else 0.3 end
end

function View.build(body,base,args)
 if args.page then View.stylePage(args.page) end
 local get,set=args.get,args.set
 local refreshers=args.refreshers
 local pool=args.pool()
 local order=base
 local function heading(title)
  order+=1;Kit.heading(body,order,nil,title)
 end
 local function addRefresh(fn) table.insert(refreshers,fn) end
 local function refreshAll() for _,fn in refreshers do fn() end end
 local function mapName()
  local s=get();if s.randomMap then return "Random map" end
  for _,m in pool do if m.id==s.map then return m.name end end
  return s.map or "World"
 end
 local images={}
 local function mapArt(parent,id,props)
  local image=make("ImageLabel",props);image.Name="MapPicture";image.BackgroundTransparency=1;image.ScaleType=Enum.ScaleType.Fit;image.Parent=parent
  local last=nil
  local function update(mapId)
   if last==mapId then return end
   local region=THUMBNAIL_REGIONS[mapId]
   if region then
    image.Image=region[5] or THUMBNAIL_ASSET
    image.ImageRectOffset=Vector2.new(region[1],region[2]);image.ImageRectSize=Vector2.new(region[3],region[4])
    last=mapId
   else
    local art=images[mapId]
    if not art then art=args.preview(mapId,300);if art then images[mapId]=art end end
    if art then image.ImageRectOffset=Vector2.zero;image.ImageRectSize=Vector2.zero;image.ImageContent=Content.fromObject(art);last=mapId end
   end
  end
  if id then addRefresh(function() update(id) end) end
  return image,update
 end

 heading("Map")
 order+=1
 local options,fitOptions
 local mapRow=make("Frame",{Name="MapRow",LayoutOrder=order,BackgroundTransparency=1,Size=UDim2.new(1,0,0,190),Parent=body})
 local hero=make("TextButton",{Name="MapHero",Text="",AutoButtonColor=false,Size=UDim2.fromOffset(190,190),BackgroundColor3=Color3.fromRGB(8,32,52),BorderSizePixel=0,Parent=mapRow})
 Kit.corner(hero,12);Kit.stroke(hero,0.2,C.MALIBU,1.5)
 local heroImage,updateHero=mapArt(hero,nil,{Position=UDim2.fromOffset(8,8),Size=UDim2.new(1,-16,1,-64)})
 local heroName=label(hero,"",{Name="CurrentMap",Position=UDim2.new(0,8,1,-55),Size=UDim2.new(1,-16,0,30),FontFace=F.BOLD,TextSize=16,TextWrapped=true})
 label(hero,"CHANGE  v",{AnchorPoint=Vector2.new(0.5,1),Position=UDim2.new(0.5,0,1,-5),Size=UDim2.new(1,-16,0,20),FontFace=F.BOLD,TextSize=12,TextColor3=C.MALIBU})
 local favColumn=make("Frame",{Name="FavouritesColumn",BackgroundColor3=Color3.fromRGB(14,39,62),BackgroundTransparency=0,BorderSizePixel=0,Parent=mapRow})
 Kit.corner(favColumn,10);Kit.stroke(favColumn,0.5,Color3.fromRGB(66,104,138),1)
 label(favColumn,"FAVOURITE MAPS",{Position=UDim2.fromOffset(12,10),Size=UDim2.new(1,-24,0,24),TextXAlignment=Enum.TextXAlignment.Left,FontFace=F.BOLD,TextSize=14})
 local visibility="public"
 local function visibilityValue() return if args.getVisibility then args.getVisibility() else visibility end
 local tooltip=label(mapRow,"",{Name="FavouriteTooltip",Visible=false,BackgroundColor3=Color3.fromRGB(8,25,43),BackgroundTransparency=0.05,Size=UDim2.fromOffset(160,28),FontFace=F.BOLD,TextSize=14,ZIndex=10});Kit.corner(tooltip,6)
 addRefresh(function() heroName.Text=mapName();heroImage.Visible=not get().randomMap;if heroImage.Visible then updateHero(get().map) end end)

 order+=1
 local picker=Kit.card(body,order,12,12,10);picker.Name="MapPicker";picker.Visible=false
 Kit.paragraph(picker,1,"Choose a map",{FontFace=F.BOLD,TextSize=18})
 local pickerGrid,fitPicker=responsiveGrid(picker,2,132,138,"AllMaps")
 local favouritesGrid,fitFavourites
 local function selectMap(id)
  set({map=id,randomMap=false});picker.Visible=false
 end
 local function mapTile(parent,m,index,star)
  local b=make("TextButton",{Name=m.id,LayoutOrder=index,Text="",AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(12,31,50),BorderSizePixel=0,Parent=parent})
  Kit.corner(b,10);Kit.stroke(b,0.3,Color3.fromRGB(63,87,112),1)
  mapArt(b,m.id,{Position=UDim2.fromOffset(6,6),Size=if star then UDim2.new(1,-12,1,-46) else UDim2.new(1,-12,1,-12)})
  if star then
   label(b,m.name,{Name="MapName",Position=UDim2.new(0,6,1,-35),Size=UDim2.new(1,-12,0,30),FontFace=F.BOLD,TextSize=14,TextWrapped=true})
  else
   local function showName()
    tooltip.Text=m.name;tooltip.Visible=true
    local width=math.min(mapRow.AbsoluteSize.X,game:GetService("TextService"):GetTextSize(m.name,14,Enum.Font.GothamBold,Vector2.new(1000,28)).X+20)
    tooltip.Size=UDim2.fromOffset(width,28)
    tooltip.Position=UDim2.fromOffset(math.clamp(b.AbsolutePosition.X-mapRow.AbsolutePosition.X,0,math.max(0,mapRow.AbsoluteSize.X-width)),b.AbsolutePosition.Y-mapRow.AbsolutePosition.Y-30)
   end
   local function hideName() tooltip.Visible=false end
   b.MouseEnter:Connect(showName);b.SelectionGained:Connect(showName)
   b.MouseLeave:Connect(hideName);b.SelectionLost:Connect(hideName)
   local remove=make("TextButton",{Name="RemoveFavourite",AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-2,0,2),Size=UDim2.fromOffset(20,20),Text="x",FontFace=F.BOLD,TextSize=14,TextColor3=C.WHITE,BackgroundColor3=Color3.fromRGB(5,22,40),BorderSizePixel=0,ZIndex=5,Parent=b});Kit.corner(remove,5)
   remove.Activated:Connect(function() favourites[m.id]=nil;tooltip.Visible=false;refreshAll();fitFavourites() end)
  end
  b.Activated:Connect(function() selectMap(m.id) end)
  if star then
   local save=make("TextButton",{Name="Favourite",AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-6,0,6),Size=UDim2.fromOffset(56,26),BackgroundColor3=Color3.fromRGB(8,22,37),BackgroundTransparency=0.1,BorderSizePixel=0,Text="SAVE",FontFace=F.BOLD,TextSize=11,TextColor3=C.WHITE,ZIndex=4,Parent=b})
   Kit.corner(save,6)
   save.Activated:Connect(function() favourites[m.id]=not favourites[m.id];refreshAll();fitFavourites() end)
   addRefresh(function() save.Text=if favourites[m.id] then "SAVED" else "SAVE";save.TextColor3=if favourites[m.id] then Color3.fromRGB(255,209,85) else C.WHITE end)
  end
  addRefresh(function() highlight(b,not get().randomMap and get().map==m.id);if not star then b.BackgroundColor3=Color3.fromRGB(5,22,40);b.BackgroundTransparency=0 end end)
  return b
 end
 for i,m in pool do mapTile(pickerGrid,m,i,true) end
 fitPicker()
 local random=choice(picker,"Random map",3,function() set({randomMap=true});picker.Visible=false end)
 addRefresh(function() highlight(random,get().randomMap==true) end)
 hero.Activated:Connect(function() picker.Visible=not picker.Visible;fitPicker() end)

 favouritesGrid=make("Frame",{Name="FavouriteMaps",BackgroundTransparency=1,Position=UDim2.fromOffset(12,42),Size=UDim2.new(1,-24,0,0),Parent=favColumn})
 local favouriteLayout=make("UIGridLayout",{CellSize=UDim2.fromOffset(68,68),CellPadding=UDim2.fromOffset(8,8),SortOrder=Enum.SortOrder.LayoutOrder,Parent=favouritesGrid})
 fitFavourites=function()
  local mobile=require(script.Parent.DeviceLayout).state.touch==true
  local width=if mobile then math.max(100,mapRow.AbsoluteSize.X) else math.max(260,mapRow.AbsoluteSize.X)
  local side=math.clamp(math.floor(width*0.28),if mobile then 96 else 128,190)
  hero.Size=UDim2.fromOffset(side,side)
  local remaining=width-side-16
  local favWidth=if remaining<300 then remaining else math.min(420,remaining-150)
  local columns=math.max(1,math.floor((favWidth-24+8)/76))
  local count=0;for _,b in favouritesGrid:GetChildren() do if b:IsA("GuiObject") and b.Visible then count+=1 end end
  local rows=math.ceil(count/columns);local height=if rows==0 then 0 else rows*76-8
  favouritesGrid.Size=UDim2.new(1,-24,0,height)
  local favHeight=math.max(128,54+height)
  favColumn.Position=UDim2.fromOffset(side+16,0);favColumn.Size=UDim2.fromOffset(favWidth,favHeight)
  local rowHeight=math.max(side,favHeight)
  if options then
   local narrow=remaining<300
   options.Position=UDim2.fromOffset(if narrow then 0 else side+16,if narrow then rowHeight+12 else favHeight+12)
   options.Size=UDim2.new(0,if narrow then width else math.min(420,remaining),0,options.Size.Y.Offset)
   rowHeight=math.max(rowHeight,options.Position.Y.Offset+options.Size.Y.Offset)
  end
  mapRow.Size=UDim2.new(1,0,0,rowHeight)
 end
 mapRow:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitFavourites)
 local favTiles={}
 for i,m in pool do local b=mapTile(favouritesGrid,m,i,false);favTiles[m.id]=b;b.Visible=false end
 local favEmpty=label(favColumn,"Save maps in the map picker to add them here.",{Name="FavouriteEmpty",Position=UDim2.fromOffset(12,44),Size=UDim2.new(1,-24,0,74),TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,TextWrapped=true,TextSize=14,TextTransparency=0.4})
 addRefresh(function()
  local count=0
  for id,b in favTiles do b.Visible=favourites[id]==true;if b.Visible then count+=1 end end
  favEmpty.Visible=count==0;fitFavourites()
 end)

 if not args.solo then
 options=make("Frame",{Name="GameOptions",BackgroundTransparency=1,Size=UDim2.new(1,0,0,68),Parent=mapRow})
 local function cycleButton(value,onClick)
  local button=make("TextButton",{Text="",AutoButtonColor=false,BackgroundTransparency=0,BorderSizePixel=0,Parent=options})
  Kit.corner(button,8);Kit.stroke(button,0.15,C.MALIBU,1.5);button.Activated:Connect(onClick)
  local content=make("Frame",{Name="Content",AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),AutomaticSize=Enum.AutomaticSize.X,Size=UDim2.fromOffset(0,24),BackgroundTransparency=1,Parent=button})
  make("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,VerticalAlignment=Enum.VerticalAlignment.Center,Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder,Parent=content})
  local text=label(content,value,{Name="Value",LayoutOrder=2,AutomaticSize=Enum.AutomaticSize.X,Size=UDim2.fromOffset(0,24),FontFace=F.BOLD,TextSize=16,TextColor3=Color3.fromRGB(9,25,38)})
  return button,text
 end
 label(options,"Game mode",{Name="ModeLabel",Position=UDim2.fromOffset(0,0),Size=UDim2.fromOffset(200,22),TextXAlignment=Enum.TextXAlignment.Left,FontFace=F.BOLD,TextSize=14})
 local visibilityLabel=label(options,"Visibility",{Name="VisibilityLabel",Size=UDim2.fromOffset(140,22),TextXAlignment=Enum.TextXAlignment.Left,FontFace=F.BOLD,TextSize=14})
 local modeButton,modeText=cycleButton("Free for All",function()
  if get().mode=="Team" then set({mode="FFA"}) else set({mode="Team",donateGold=true,donateTroops=true}) end
 end);modeButton.Name="GameModeToggle"
 local function modeColour() return if get().mode=="Team" then Color3.fromRGB(142,111,235) else Color3.fromRGB(35,172,230) end
 make("UIGradient",{Name="SurfaceGradient",Rotation=90,Color=ColorSequence.new(C.WHITE,Color3.fromRGB(195,211,231)),Parent=modeButton})
 Kit.hover(modeButton,function(state) local colour=modeColour();modeButton.BackgroundColor3=if state=="idle" then colour else colour:Lerp(C.WHITE,0.12);modeButton.BackgroundTransparency=0 end)
 addRefresh(function() modeText.Text=if get().mode=="Team" then "Teams (2/2)" else "Free for All (1/2)";modeButton.BackgroundColor3=modeColour();modeButton.BackgroundTransparency=0 end)
 local visibilityButton,visibilityText=cycleButton("Public",function()
  local value=if visibilityValue()=="public" then "private" else "public"
  if args.setVisibility then args.setVisibility(value) else visibility=value end
  refreshAll()
 end);visibilityButton.Name="LobbyVisibility"
 local function visibilityColour() return if visibilityValue()=="public" then Color3.fromRGB(46,209,125) else Color3.fromRGB(246,70,89) end
 make("UIGradient",{Name="SurfaceGradient",Rotation=90,Color=ColorSequence.new(C.WHITE,Color3.fromRGB(195,211,231)),Parent=visibilityButton})
 Kit.hover(visibilityButton,function(state) local colour=visibilityColour();visibilityButton.BackgroundColor3=if state=="idle" then colour else colour:Lerp(C.WHITE,0.12);visibilityButton.BackgroundTransparency=0 end)
 addRefresh(function()
  visibilityText.Text=if visibilityValue()=="public" then "Public (1/2)" else "Private (2/2)"
  visibilityButton.BackgroundColor3=visibilityColour();visibilityButton.BackgroundTransparency=0
  local stroke=visibilityButton:FindFirstChildWhichIsA("UIStroke");if stroke then stroke.Color=visibilityColour():Lerp(C.WHITE,0.4);stroke.Transparency=0.1;stroke.Thickness=1.5 end
 end)
 fitOptions=function()
  local width=if require(script.Parent.DeviceLayout).state.touch then math.max(100,options.AbsoluteSize.X) else math.max(260,options.AbsoluteSize.X)
  local visibilityWidth=math.min(140,math.floor((width-12)*0.44))
  local modeWidth=math.min(230,width-visibilityWidth-12)
  modeText.TextSize=if modeWidth<175 then 13 else 16
  visibilityText.TextSize=if visibilityWidth<130 then 12 else 16
  modeButton.Position=UDim2.fromOffset(0,26);modeButton.Size=UDim2.fromOffset(modeWidth,40)
  visibilityButton.Position=UDim2.fromOffset(modeWidth+12,26);visibilityButton.Size=UDim2.fromOffset(visibilityWidth,40)
  visibilityLabel.Position=UDim2.fromOffset(modeWidth+12,0)
  options.Size=UDim2.new(options.Size.X.Scale,options.Size.X.Offset,0,70)
  fitFavourites()
 end
 options:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitOptions)
 fitOptions()
 order+=1
 local teams=Kit.card(body,order,12,12,8);teams.Name="TeamFormats"
 Kit.paragraph(teams,1,"Team format",{FontFace=F.BOLD,TextSize=16})
 local teamGrid,fitTeams=responsiveGrid(teams,2,140,44,"Formats")
 for i,t in args.teams do
  local b=choice(teamGrid,t[2],i,function() set({teams=t[1]}) end)
  addRefresh(function() highlight(b,get().teams==t[1]) end)
 end
 addRefresh(function() teams.Visible=get().mode=="Team";fitTeams() end)
 end

 heading("Nation difficulty")
 order+=1
 local difficulty,fitDifficulty=responsiveGrid(body,order,125,56,"NationDifficulty")
 for i,d in {"Easy","Medium","Hard","Impossible"} do
  local colour=({Color3.fromRGB(46,209,125),Color3.fromRGB(255,203,42),Color3.fromRGB(255,143,45),Color3.fromRGB(246,70,89)})[i]
  local b=make("TextButton",{Name=d,LayoutOrder=i,Text="",AutoButtonColor=false,BorderSizePixel=0,BackgroundTransparency=0,ClipsDescendants=true,Parent=difficulty})
  Kit.corner(b,8);Kit.stroke(b,0.15,colour,1.5)
  b.Activated:Connect(function() if get().nations~=false then set({difficulty=d}) end end)
  make("UIGradient",{Name="SurfaceGradient",Rotation=90,Color=ColorSequence.new(C.WHITE,Color3.fromRGB(195,211,231)),Parent=b})
  local name=label(b,d,{Name="DifficultyName",Size=UDim2.fromScale(1,1),FontFace=F.BOLD,TextSize=16,TextColor3=Color3.fromRGB(9,25,38),ZIndex=3})
  addRefresh(function()
   local selected=get().difficulty==d
   b.BackgroundColor3=colour;b.BackgroundTransparency=0
   local stroke=b:FindFirstChildWhichIsA("UIStroke")
   if stroke then stroke.Color=if selected then C.WHITE else colour:Lerp(C.WHITE,0.4);stroke.Thickness=if selected then 3 else 1.5;stroke.Transparency=if selected then 0 else 0.15 end
   b.Active=get().nations~=false;name.TextTransparency=if b.Active then 0 else 0.5
  end)
  Kit.hover(b,function(state) b.BackgroundColor3=if state=="idle" or get().nations==false then colour else colour:Lerp(C.WHITE,0.08);b.BackgroundTransparency=0 end)
 end
 fitDifficulty()

 heading("Main options")
 local function toggle(parent,at,key,title,invert,default)
  local function read() local v=get()[key];if v==nil then v=default end;return if invert then not v else v==true end
  local row=make("TextButton",{Name=key,LayoutOrder=at,Size=UDim2.new(1,0,0,56),Text="",AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(12,31,50),BorderSizePixel=0,Parent=parent});Kit.corner(row,10)
  label(row,title,{Position=UDim2.fromOffset(16,0),Size=UDim2.new(1,-96,1,0),TextXAlignment=Enum.TextXAlignment.Left,FontFace=F.BOLD,TextSize=16,TextWrapped=true})
  local track=make("Frame",{Name="Toggle",AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-16,0.5,0),Size=UDim2.fromOffset(50,26),BorderSizePixel=0,Parent=row});Kit.round(track)
  local knob=make("Frame",{Name="Knob",AnchorPoint=Vector2.new(0,0.5),Size=UDim2.fromOffset(20,20),BackgroundColor3=C.WHITE,BorderSizePixel=0,Parent=track});Kit.round(knob)
  row.Activated:Connect(function() local on=not read();set({[key]=if invert then not on else on}) end)
  addRefresh(function() local on=read();track:SetAttribute("Enabled",on);track.BackgroundColor3=if on then SWITCH_ON else SWITCH_OFF;knob.Position=UDim2.new(0,if on then 27 else 3,0.5,0) end)
 end
 order+=1;toggle(body,order,"nations","Nations",false,true)
 order+=1
 local tribes=make("Frame",{Name="Tribes",LayoutOrder=order,Size=UDim2.new(1,0,0,58),BackgroundColor3=Color3.fromRGB(17,35,55),BorderSizePixel=0,Parent=body});Kit.corner(tribes,12)
 label(tribes,"Tribes",{Position=UDim2.fromOffset(16,0),Size=UDim2.new(1,-170,1,0),TextXAlignment=Enum.TextXAlignment.Left,FontFace=F.BOLD,TextSize=16})
 local value=label(tribes,"",{AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-58,0,0),Size=UDim2.fromOffset(52,58),FontFace=F.BOLD,TextSize=16})
 for _,delta in {-10,10} do
  local b=make("TextButton",{Name=if delta<0 then "Less" else "More",AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,if delta<0 then -112 else -12,0.5,0),Size=UDim2.fromOffset(34,34),Text=if delta<0 then "-" else "+",FontFace=F.BOLD,TextSize=22,TextColor3=C.WHITE,BackgroundColor3=C.BLUE600,BorderSizePixel=0,Parent=tribes});Kit.corner(b,8)
  b.Activated:Connect(function() set({bots=math.clamp((get().bots or 400)+delta,0,400)}) end)
 end
 addRefresh(function() value.Text=if get().bots==0 then "Off" else tostring(get().bots or 400) end)
 order+=1;toggle(body,order,"randomSpawn","Random spawn",false,false)
 order+=1;toggle(body,order,"noAlliances","Alliances",true,false)

 heading("Enabled options")
 order+=1
 local units,fitUnits=responsiveGrid(body,order,240,62,"EnabledUnits")
 local IconKit=require(script.Parent:WaitForChild("IconKit"))
 local SpriteKit=require(script.Parent:WaitForChild("SpriteKit"))
 local enabledOptions=table.clone(args.units)
 table.insert(enabledOptions,{"InfiniteTroops","Infinite troops","Troops","infiniteTroops"})
 table.insert(enabledOptions,{"InfiniteGold","Infinite gold","Gold","infiniteGold"})
 for i,u in enabledOptions do
  local kind=u[1]
  local tile=make("Frame",{Name=kind,LayoutOrder=i,BackgroundColor3=Color3.fromRGB(12,31,50),BorderSizePixel=0,Parent=units});Kit.corner(tile,10);Kit.stroke(tile,0.5,C.MALIBU,1)
  local props={Name="UnitPicture",AnchorPoint=Vector2.new(0,0.5),Position=UDim2.new(0,12,0.5,0),Size=UDim2.fromOffset(34,34),ZIndex=2,Parent=tile}
  if kind=="Warship" or kind=="AtomBomb" or kind=="HydrogenBomb" or kind=="MIRV" then
   local picture=SpriteKit.unit(kind,props);SpriteKit.paint(picture,Color3.fromRGB(171,207,220),Color3.fromRGB(76,118,148))
  else
   if u[3] then props.ImageColor3=if u[3]=="Gold" then Color3.fromRGB(255,202,56) else Color3.fromRGB(153,211,241) end
   IconKit.image(u[3] or IconKit.KIND[kind] or kind,props)
  end
  label(tile,u[2],{Name="UnitName",Position=UDim2.fromOffset(56,0),Size=UDim2.new(1,-126,1,0),TextXAlignment=Enum.TextXAlignment.Left,FontFace=F.BOLD,TextSize=14,TextWrapped=true})
  local switch=make("TextButton",{Name="Toggle",AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,-12,0.5,0),Size=UDim2.fromOffset(50,26),Text="",AutoButtonColor=false,BorderSizePixel=0,Parent=tile});Kit.round(switch)
  local knob=make("Frame",{Name="Knob",AnchorPoint=Vector2.new(0,0.5),Size=UDim2.fromOffset(20,20),BackgroundColor3=C.WHITE,BorderSizePixel=0,Parent=switch});Kit.round(knob)
  local function enabled() return if u[4] then get()[u[4]]==true else not table.find(get().disabledUnits or {},kind) end
  switch.Activated:Connect(function()
   if u[4] then set({[u[4]]=not enabled()});return end
   local list=table.clone(get().disabledUnits or {});local index=table.find(list,kind)
   if index then table.remove(list,index) else table.insert(list,kind) end
   set({disabledUnits=list})
  end)
  addRefresh(function() local on=enabled();switch:SetAttribute("Enabled",on);switch.BackgroundColor3=if on then SWITCH_ON else SWITCH_OFF;knob.Position=UDim2.new(0,if on then 27 else 3,0.5,0) end)
 end
 fitUnits()

 order+=1
 local advancedButton=choice(body,"ADVANCED OPTIONS  v",order,function() end);advancedButton.Name="AdvancedOptions"
 order+=1
 local advanced=Kit.card(body,order,12,12,8);advanced.Name="AdvancedSettings";advanced.Visible=false
 advancedButton.Activated:Connect(function() advanced.Visible=not advanced.Visible;advancedButton.Text=if advanced.Visible then "ADVANCED OPTIONS  ^" else "ADVANCED OPTIONS  v" end)
 local at=0
 for _,opt in {{"instantBuild","Instant build"},{"donateGold","Donate gold"},{"donateTroops","Donate troops"},{"compact","Compact map"},{"waterNukes","Water nukes"},{"overtime","Overtime"}} do
  at+=1;toggle(advanced,at,opt[1],opt[2],false,false)
 end
 for _,sel in {
  {"doomsday","Doomsday Clock",{{"off","Off"},{"slow","Slow"},{"normal","Normal"},{"fast","Fast"},{"veryfast","Very fast"}},"off"},
  {"goldMultiplier","Gold multiplier",{{1,"Off"},{1.5,"x1.5"},{2,"x2"},{3,"x3"},{5,"x5"}},1},
  {"startingGold","Starting gold",{{0,"Off"},{1000000,"1M"},{5000000,"5M"},{25000000,"25M"}},0},
  {"allianceMinutes","Alliance duration",{{0,"5 min"},{2,"2 min"},{3,"3 min"},{10,"10 min"},{15,"15 min"},{30,"30 min"}},0},
  {"immunitySeconds","Spawn immunity",{{5,"5 s"},{30,"30 s"},{60,"1 min"},{120,"2 min"},{300,"5 min"}},5},
 } do
  at+=1
  addRefresh(Kit.selectRow(advanced,at,sel[2],nil,sel[3],function() local v=get()[sel[1]];return if v==nil then sel[4] else v end,function(v) set({[sel[1]]=v}) end))
 end
 return order
end

return View