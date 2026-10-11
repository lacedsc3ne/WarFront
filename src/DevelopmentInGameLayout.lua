-- War Front Development match navbar. Copyright (C) 2026 Liam (lacedsc3ne).
-- AGPL-3.0-or-later. Presentation only; existing buttons and slider own their commands.
local RunService = game:GetService("RunService")
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local Panels=require(script.Parent:WaitForChild("DevelopmentMatchPanels"))
local Layout = {}
local C = {
 panel=Color3.fromRGB(17,60,99), raised=Color3.fromRGB(29,88,136),
 border=Color3.fromRGB(71,145,197), white=Color3.fromRGB(241,248,255),
 muted=Color3.fromRGB(155,184,219), cyan=Color3.fromRGB(0,177,235),
 coral=Color3.fromRGB(255,196,50), gold=Color3.fromRGB(255,211,55),
 red=Color3.fromRGB(240,91,80), orange=Color3.fromRGB(255,177,67),
 green=Color3.fromRGB(91,220,142),
}
local W,H=870,144
local GROUPS={
 {label="BUILD",width=330,kinds={"City","Factory","DefensePost","MissileSilo"}},
 {label="SEA",width=162,kinds={"Port","Warship"}},
 {label="DEFENSE",width=330,kinds={"SAM","AtomBomb","HydrogenBomb","MIRV"}},
}
local NAMES={DefensePost="Defense",MissileSilo="Missile Silo",AtomBomb="Atom Bomb",HydrogenBomb="Hydrogen Bomb"}
local function make(class,props)
 local v=Instance.new(class)
 for k,value in props do if k~="Parent" then v[k]=value end end
 v.Parent=props.Parent
 return v
end
local function text(parent,name,value,size,color)
 return make("TextLabel",{Name=name,Text=value,TextSize=size,Font=Enum.Font.GothamBold,
  TextColor3=color or C.white,BackgroundTransparency=1,BorderSizePixel=0,
  Size=UDim2.fromOffset(0,26),AutomaticSize=Enum.AutomaticSize.X,
  TextXAlignment=Enum.TextXAlignment.Left,ZIndex=57,Parent=parent})
end
local function rule(parent,x,y,w,h,color)
 return make("Frame",{Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),
  BackgroundColor3=color or C.border,BorderSizePixel=0,ZIndex=56,Parent=parent})
end
local function row(parent,name,x,y,w)
 local f=make("Frame",{Name=name,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,28),
  BackgroundTransparency=1,ZIndex=56,Parent=parent})
 make("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,VerticalAlignment=Enum.VerticalAlignment.Center,
  Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder,Parent=f})
 return f
end
-- Continuous red -> orange -> green ramp, independent of display framerate.
function Layout.populationColor(fraction)
 local f=math.clamp(fraction,0,1)
 return if f<=.5 then C.red:Lerp(C.orange,f*2) else C.orange:Lerp(C.green,(f-.5)*2)
end
function Layout.mount(api)
 local s={saved={},connections={},created={},cards={},groups={},selectedGroup=1,target=C.red,colour=C.red}
 api.development=s
 local function change(v,props)
  local original=s.saved[v]
  if not original then original={};s.saved[v]=original end
  for key,value in props do
   if original[key]==nil then original[key]=v[key] end
   v[key]=value
  end
 end
 s.change=change
 local layer=make("Frame",{Name="DevelopmentLayout",BackgroundTransparency=1,
  Size=UDim2.fromOffset(api.ctx.gui.AbsoluteSize.X,api.ctx.gui.AbsoluteSize.Y),ZIndex=55,Parent=api.root})
 s.layer=layer
 local bar=make("Frame",{Name="DevelopmentNavbar",AnchorPoint=Vector2.new(.5,1),
  BackgroundColor3=C.panel,BorderSizePixel=0,Size=UDim2.fromOffset(W,H),ZIndex=55,Parent=layer})
 s.bar=bar
 make("UICorner",{CornerRadius=UDim.new(0,12),Parent=bar})
 make("UIStroke",{Color=C.border,Thickness=1.5,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=bar})
 make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(200,215,235)),Rotation=90,Parent=bar})
 s.scale=make("UIScale",{Scale=1,Parent=bar})
 s.separators={rule(bar,1,36,W-2,1),rule(bar,318,10,1,18),rule(bar,538,10,1,18)}
 local troops=row(bar,"Population",18,5,290);s.population=troops
 local ti=make("ImageLabel",{Name="PopulationIcon",Image="rbxassetid://112831062230992",Size=UDim2.fromOffset(24,24),BackgroundTransparency=1,ScaleType=Enum.ScaleType.Fit,LayoutOrder=1,ZIndex=57,Parent=troops})
 s.current=text(troops,"CurrentPopulation","0",16,C.red);s.current.LayoutOrder=2
 s.maximum=text(troops,"MaximumPopulation","/ 0",14,C.green);s.maximum.LayoutOrder=3
 s.growth=text(troops,"PopulationGrowth","",13,C.cyan);s.growth.LayoutOrder=4
 local gold=row(bar,"Money",334,5,185);s.goldRow=gold
 make("ImageLabel",{Name="GoldIcon",Image="rbxassetid://122263341747372",Size=UDim2.fromOffset(24,24),BackgroundTransparency=1,ScaleType=Enum.ScaleType.Fit,LayoutOrder=1,ZIndex=57,Parent=gold})
 s.money=text(gold,"Gold","0",16,C.gold);s.money.LayoutOrder=2
 local goldCaption=text(gold,"GoldHeading","GOLD",11,C.muted);goldCaption.LayoutOrder=3;s.goldCaption=goldCaption
 s.ratio=text(bar,"AttackRatio","ATTACK 20%",14,C.coral)
 s.attackIcon=make("ImageLabel",{Name="AttackIcon",Image="rbxassetid://128733455210710",Position=UDim2.fromOffset(555,7),Size=UDim2.fromOffset(22,22),BackgroundTransparency=1,ScaleType=Enum.ScaleType.Fit,ZIndex=57,Parent=bar})
 s.ratio.Position=UDim2.fromOffset(582,5)
 -- Reparent the actual ratio slider: its existing mouse/touch and command handlers stay attached.
 change(api.slider,{Parent=bar,Position=UDim2.fromOffset(687,6),AnchorPoint=Vector2.zero,
  Size=UDim2.fromOffset(167,25),ZIndex=57})
 change(api.fill,{BackgroundColor3=C.coral})
 change(api.knob,{BackgroundColor3=C.coral})
 for _,control in {api.fill,api.knob} do
  local gradient=make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(255,194,90)),Rotation=90,Parent=control})
  table.insert(s.created,gradient)
 end
 local byKind={}
 for _,entry in api.choices do byKind[entry.action.kind]=entry end
 local x=12
 for groupIndex,g in GROUPS do
  local group=make("Frame",{Name=g.label,Position=UDim2.fromOffset(x,41),
   Size=UDim2.fromOffset(g.width,91),BackgroundTransparency=1,ZIndex=56,Parent=bar})
  local heading=text(group,"Heading",g.label,13,C.muted)
  heading.Size=UDim2.fromOffset(g.width,18);heading.AutomaticSize=Enum.AutomaticSize.None
  heading.TextXAlignment=Enum.TextXAlignment.Center
  local headingRule=rule(group,0,20,g.width,1)
  local under=rule(group,g.width/2-26,19,52,3,C.coral)
  make("UICorner",{CornerRadius=UDim.new(0,2),Parent=under})
  make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(255,194,90)),Rotation=90,Parent=under})
  local divider=if groupIndex>1 then rule(bar,x-6,42,1,90) else nil
  local tab=make("TextButton",{Name="TouchTab"..g.label,Text=g.label,Font=Enum.Font.GothamBold,TextSize=12,TextColor3=C.white,BackgroundColor3=C.raised,BorderSizePixel=0,Visible=false,ZIndex=59,Parent=bar})
  make("UICorner",{CornerRadius=UDim.new(0,5),Parent=tab})
  tab.Activated:Connect(function()s.selectedGroup=groupIndex;Layout.layout(api)end)
  table.insert(s.groups,{frame=group,heading=heading,headingRule=headingRule,underline=under,tab=tab,divider=divider,design=g,x=x,cards={}})
  local bw=(g.width-(#g.kinds-1)*6)/#g.kinds
  for i,kind in g.kinds do
   local entry=byKind[kind]
   if entry then
    local b=entry.button
    change(b,{Parent=group,Position=UDim2.fromOffset((i-1)*(bw+6),26),
     Size=UDim2.fromOffset(bw,70),AnchorPoint=Vector2.zero,
     AutomaticSize=Enum.AutomaticSize.None,Visible=true,BackgroundTransparency=0,
     BackgroundColor3=C.panel,ZIndex=57})
    local shape=b:FindFirstChild("AngularShape")
    if shape then change(shape,{Visible=false}) end
    local corner=b:FindFirstChildWhichIsA("UICorner")
    if corner then change(corner,{CornerRadius=UDim.new(0,6)})
    else local c=make("UICorner",{CornerRadius=UDim.new(0,6),Parent=b});table.insert(s.created,c) end
    local border=make("UIStroke",{Color=C.border,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=b})
    table.insert(s.created,border)
    local gradient=make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(190,210,235)),Rotation=90,Parent=b})
    table.insert(s.created,gradient)
    local icon=b:FindFirstChildWhichIsA("ImageLabel")
    if icon then change(icon,{Size=UDim2.fromOffset(23,23),Position=UDim2.new(.5,0,0,7),
     AnchorPoint=Vector2.new(.5,0),ImageColor3=C.white,ZIndex=58}) end
    local label=b:FindFirstChild("Name")
    if label then change(label,{Position=UDim2.fromOffset(3,32),Size=UDim2.fromOffset(bw-6,19),
     Text=NAMES[kind] or entry.action.def.name,TextSize=if kind=="HydrogenBomb" then 9 else 10,TextTruncate=Enum.TextTruncate.None,
     TextWrapped=true,ZIndex=58}) end
    change(entry.cost,{Position=UDim2.fromOffset(3,51),Size=UDim2.fromOffset(bw-6,15),
     TextSize=13,TextColor3=C.gold,ZIndex=58})
    local accent=rule(b,3,66,bw-6,3,C.coral);table.insert(s.created,accent)
    make("UICorner",{CornerRadius=UDim.new(0,2),Parent=accent})
    local badge=text(b,"DevelopmentHotkey","",8,C.muted)
    badge.Position=UDim2.fromOffset(4,3);badge.Size=UDim2.fromOffset(12,12)
    badge.AutomaticSize=Enum.AutomaticSize.None;badge.ZIndex=59;table.insert(s.created,badge)
    local card={entry=entry,badge=badge,accent=accent,icon=icon,label=label,group=groupIndex,index=i}
    table.insert(s.cards,card);table.insert(s.groups[groupIndex].cards,card)
    table.insert(s.connections,b.MouseEnter:Connect(function() b.BackgroundColor3=C.raised end))
    table.insert(s.connections,b.MouseLeave:Connect(function() b.BackgroundColor3=C.panel end))
   end
  end
  x+=g.width+12
 end
 for _,v in {api.resources,api.attack,api.commands,api.buildPop} do change(v,{Visible=false}) end
 local cleanupPanels=Panels.mount(api,s)
 -- Smooth the displayed colour over time as well as across the population percentage.
 table.insert(s.connections,RunService.RenderStepped:Connect(function(dt)
  if not s.layer.Parent then return end
  s.colour=s.colour:Lerp(s.target,1-math.exp(-dt/.18))
  s.current.TextColor3=s.colour
 end))
 Layout.layout(api)
 Layout.update(api)
 return function()
  cleanupPanels()
  for _,connection in s.connections do connection:Disconnect() end
  -- Restore borrowed controls before destroying our containers.
  for v,props in s.saved do if v.Parent then
   for key,value in props do v[key]=value end
  end end
  for _,v in s.created do v:Destroy() end
  layer:Destroy()
  api.development=nil
 end
end
function Layout.layout(api)
 local s=api.development;if not s then return end
 local size=api.ctx.gui.AbsoluteSize
 local state=api.ctx.device.state or {}
 local pg=game.Players.LocalPlayer.PlayerGui
 local key=table.concat({tostring(size),tostring(api.ctx.gui.AbsolutePosition),tostring(api.root.AbsolutePosition),
  tostring(api.root.Visible),tostring(api.ctx.device.userScale),tostring(state.profile),tostring(state.input),tostring(state.touch),
  tostring(s.selectedGroup),tostring(pg:GetAttribute("FrontlinesTutorial")),tostring(pg:GetAttribute("FrontlinesTutorialStep"))},"|")
 if s.layoutKey==key then return end
 s.layoutKey=key
 s.layer.Size=UDim2.fromOffset(size.X,size.Y)
 local deviceState=api.ctx.device.state
 local profile=deviceState and deviceState.profile
 s.mobileLayout=deviceState~=nil and (deviceState.touch==true or deviceState.input=="Touch") and (profile=="phone" or profile=="tablet")
 -- Align mobile controls to the safe-area canvas rather than a shifted HUD wrapper.
 s.layer.Position=if s.mobileLayout then UDim2.fromOffset(api.ctx.gui.AbsolutePosition.X-api.root.AbsolutePosition.X,api.ctx.gui.AbsolutePosition.Y-api.root.AbsolutePosition.Y) else UDim2.fromOffset(0,0)
 s.touchLayout=profile=="phone" or profile=="tablet" or size.X<700 or size.Y<500
 if s.touchLayout then
  local mobileScale=1
  local width=if s.mobileLayout then math.min(600,size.X*.84/mobileScale,(size.X-32)/mobileScale) else math.min(620,size.X-24)
  local wide=width>=560
  local height=if wide then 160 else 188
  s.scale.Scale=mobileScale;s.bar.Size=UDim2.fromOffset(width,height)
  s.population.Position=UDim2.fromOffset(10,3);s.population.Size=UDim2.fromOffset(if wide then 210 else width*.6,24)
  s.current.TextSize=14;s.maximum.TextSize=12;s.growth.Visible=false
  s.goldRow.Position=UDim2.fromOffset(if wide then 230 else width*.6+4,3)
  s.goldRow.Size=UDim2.fromOffset(110,24);s.money.TextSize=14;s.goldCaption.Visible=false
  local attackY=if wide then 4 else 29
  local attackX=if wide then 345 else 10
  s.attackIcon.Position=UDim2.fromOffset(attackX,attackY);s.attackIcon.Size=UDim2.fromOffset(20,20)
  s.ratio.Position=UDim2.fromOffset(attackX+24,attackY-1);s.ratio.TextSize=if s.mobileLayout then 14 else 12
  api.slider.Position=UDim2.fromOffset(attackX+122,attackY);api.slider.Size=UDim2.fromOffset(width-attackX-132,24)
  local tabsY=if wide then 43 else 68
  for _,v in s.separators do v.Visible=false end
  for i,g in s.groups do
   g.tab.Visible=true;g.tab.Position=UDim2.fromOffset(10+(i-1)*(width-20)/3,tabsY)
   g.tab.Size=UDim2.fromOffset((width-20)/3-4,44)
   g.tab.BackgroundColor3=if i==s.selectedGroup then C.cyan else C.raised
   g.tab.TextColor3=if i==s.selectedGroup then C.panel else C.white
   g.frame.Visible=i==s.selectedGroup;g.frame.Position=UDim2.fromOffset(10,tabsY+49);g.frame.Size=UDim2.fromOffset(width-20,68)
   g.heading.Visible=false;g.headingRule.Visible=false;g.underline.Visible=false;if g.divider then g.divider.Visible=false end
   local bw=(width-20-(#g.cards-1)*6)/math.max(1,#g.cards)
   for _,c in g.cards do
    local b=c.entry.button;b.Position=UDim2.fromOffset((c.index-1)*(bw+6),0);b.Size=UDim2.fromOffset(bw,60)
    if c.icon then c.icon.Position=UDim2.new(.5,0,0,3);c.icon.Size=UDim2.fromOffset(20,20)end
    if c.label then c.label.Position=UDim2.fromOffset(2,25);c.label.Size=UDim2.fromOffset(bw-4,17);c.label.TextSize=12 end
    c.entry.cost.Position=UDim2.fromOffset(2,43);c.entry.cost.Size=UDim2.fromOffset(bw-4,if s.mobileLayout then 15 else 13);c.entry.cost.TextSize=if s.mobileLayout then 14 else 12
    c.accent.Position=UDim2.fromOffset(3,57);c.accent.Size=UDim2.fromOffset(bw-6,3);c.badge.Visible=false
   end
  end
 else
  s.scale.Scale=math.max(.25,math.min(.94*(api.ctx.device.userScale or 1),(size.X-24)/W));s.bar.Size=UDim2.fromOffset(W,H)
  s.population.Position=UDim2.fromOffset(18,5);s.population.Size=UDim2.fromOffset(290,28)
  s.current.TextSize=16;s.maximum.TextSize=14;s.growth.Visible=true
  s.goldRow.Position=UDim2.fromOffset(334,5);s.goldRow.Size=UDim2.fromOffset(185,28);s.money.TextSize=16;s.goldCaption.Visible=true
  s.attackIcon.Position=UDim2.fromOffset(555,7);s.attackIcon.Size=UDim2.fromOffset(22,22)
  s.ratio.Position=UDim2.fromOffset(582,5);s.ratio.TextSize=14
  api.slider.Position=UDim2.fromOffset(687,6);api.slider.Size=UDim2.fromOffset(167,25)
  for _,v in s.separators do v.Visible=true end
  for _,g in s.groups do
   g.tab.Visible=false;g.frame.Visible=true;g.frame.Position=UDim2.fromOffset(g.x,41);g.frame.Size=UDim2.fromOffset(g.design.width,91)
   g.heading.Visible=true;g.headingRule.Visible=true;g.underline.Visible=true;if g.divider then g.divider.Visible=true end
   local bw=(g.design.width-(#g.cards-1)*6)/math.max(1,#g.cards)
   for _,c in g.cards do
    local b=c.entry.button;b.Position=UDim2.fromOffset((c.index-1)*(bw+6),26);b.Size=UDim2.fromOffset(bw,70)
    if c.icon then c.icon.Position=UDim2.new(.5,0,0,7);c.icon.Size=UDim2.fromOffset(23,23)end
    if c.label then c.label.Position=UDim2.fromOffset(3,32);c.label.Size=UDim2.fromOffset(bw-6,19);c.label.TextSize=if c.entry.action.kind=="HydrogenBomb" then 9 else 10 end
    c.entry.cost.Position=UDim2.fromOffset(3,51);c.entry.cost.Size=UDim2.fromOffset(bw-6,15);c.entry.cost.TextSize=13
    c.accent.Position=UDim2.fromOffset(3,66);c.accent.Size=UDim2.fromOffset(bw-6,3);c.badge.Visible=true
   end
  end
 end
 local lesson=game.Players.LocalPlayer.PlayerGui:GetAttribute("FrontlinesTutorialStep")
 local learning=game.Players.LocalPlayer.PlayerGui:GetAttribute("FrontlinesTutorial")==true
 if learning and (lesson=="spawn" or lesson=="expand" or lesson=="ratio" or lesson=="cancel") then
  for _,g in s.groups do g.frame.Visible=false;g.tab.Visible=false end
  s.bar.Size=UDim2.fromOffset(s.bar.Size.X.Offset,if s.touchLayout then 66 else 38)
 end
 s.bar.Position=UDim2.new(.5,0,1,-(if size.Y<500 then 10 else 20))
 for _,v in {api.resources,api.attack,api.commands,api.buildPop} do v.Visible=false end
 Panels.layout(api)
end
function Layout.update(api,mine,me,phase,ratio)
 local s=api.development;if not s then return end
 mine=mine or api.ctx.getMine()
 local stats=mine and mine.stats
 s.bar.Visible=stats~=nil and (not phase or phase.phase=="Play" or phase.phase=="Ended" or phase.phase=="Spawn")
 s.current.Text=api.troops.Text
 s.maximum.Text=api.max.Text
 s.growth.Text=api.growth.Text
 s.money.Text=api.gold.Text
 s.ratio.Text="ATTACK "..api.ratio.Text
 if not s.deploy then
  s.deploy=text(s.bar,"DeploymentCount","",12,C.white)
  s.deploy.AutomaticSize=Enum.AutomaticSize.None
 end
 s.deploy.Position=UDim2.fromOffset(s.ratio.Position.X.Offset,s.ratio.Position.Y.Offset+17)
 s.deploy.Size=UDim2.fromOffset(110,15)
 s.deploy.Text=if stats then api.ctx.fmtTroops(math.floor((tonumber(stats.troops) or 0)*(ratio or .2))).." troops" else ""
 s.deploy.Visible=stats~=nil
 if stats then
  local max=tonumber(stats.maxTroops) or 0
  local current=tonumber(stats.troops) or 0
  local fraction=if max>0 then current/max else 0
  if fraction~=fraction then fraction=0 end
  s.target=Layout.populationColor(fraction)
 end
 for _,card in s.cards do
  local b=card.entry.button
  b.Visible=true
  local affordable=stats~=nil and (tonumber(stats.gold) or 0)>=api.ctx.cost(card.entry.action)
  local colour=if affordable then C.green else C.red
  card.entry.cost.TextColor3=colour
  card.entry.cost.TextTransparency=0
  card.accent.BackgroundColor3=colour
  b.BackgroundColor3=C.panel
  if api.refs and api.refs.actionButtons then
   for _,original in api.refs.actionButtons do
    if original.action.kind==card.entry.action.kind then card.badge.Text=original.hotkey.Text;break end
   end
  end
 end
 for _,v in {api.resources,api.attack,api.commands,api.buildPop} do v.Visible=false end
 Layout.layout(api)
 Panels.update(api)
end
Layout.layout=require(game.ReplicatedStorage.Shared.Perf).wrap("hud:layout",Layout.layout)
return Layout
