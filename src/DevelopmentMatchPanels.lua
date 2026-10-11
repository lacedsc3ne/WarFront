-- Development-only match panels; existing gameplay and event handlers are reused.
-- Copyright (C) 2026 Liam (lacedsc3ne). AGPL-3.0-or-later.
local GuiService=game:GetService("GuiService")
local RunService=game:GetService("RunService")
local Panels={}
local C={panel=Color3.fromRGB(17,60,99),raised=Color3.fromRGB(29,88,136),border=Color3.fromRGB(71,145,197),
 white=Color3.fromRGB(241,248,255),muted=Color3.fromRGB(155,184,219),cyan=Color3.fromRGB(0,177,235),amber=Color3.fromRGB(255,196,50)}
local function make(class,props)
 local v=Instance.new(class);for k,value in props do if k~="Parent" then v[k]=value end end;v.Parent=props.Parent;return v
end
local function label(parent,name,value,x,y,w,h,size,colour)
 return make("TextLabel",{Name=name,Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),
  BackgroundTransparency=1,BorderSizePixel=0,Font=Enum.Font.GothamBold,TextSize=size,
  TextColor3=colour or C.white,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ZIndex=64,Parent=parent})
end
local function panel(parent,name,w,h)
 local f=make("Frame",{Name=name,Size=UDim2.fromOffset(w,h),BackgroundColor3=C.panel,BorderSizePixel=0,ZIndex=60,Parent=parent})
 make("UICorner",{CornerRadius=UDim.new(0,9),Parent=f})
 make("UIStroke",{Color=C.border,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=f})
 make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(190,210,235)),Rotation=90,Parent=f})
 return f
end
local function chevron(parent)
 local f=make("Frame",{Name="ExpandArrow",AnchorPoint=Vector2.new(1,.5),Position=UDim2.new(1,-10,.5,0),Size=UDim2.fromOffset(14,10),BackgroundTransparency=1,Visible=false,ZIndex=66,Parent=parent})
 for i,angle in {45,-45} do
  make("Frame",{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromOffset(if i==1 then 4 else 10,4),Size=UDim2.fromOffset(8,2),Rotation=angle,BorderSizePixel=0,BackgroundColor3=C.white,ZIndex=67,Parent=f})
 end
 return f
end
local function touchTarget(parent,name)
 return make("TextButton",{Name=name,Text="",BackgroundTransparency=1,BorderSizePixel=0,AutoButtonColor=false,Size=UDim2.fromScale(1,1),ZIndex=65,Parent=parent})
end
local function button(parent,name,value,x,y,w,h)
 local b=make("TextButton",{Name=name,Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),
  BackgroundColor3=C.raised,BorderSizePixel=0,AutoButtonColor=false,Font=Enum.Font.GothamBold,
  TextSize=12,TextColor3=C.white,ZIndex=63,Parent=parent})
 make("UICorner",{CornerRadius=UDim.new(0,6),Parent=b})
 return b
end
function Panels.mount(api,s)
 local p={rows={},boardCollapsed=false,feedCollapsed=false,borrowed={},styled={},lastRoster=0}
 s.panels=p
 local owner=api.root:FindFirstAncestorOfClass("ScreenGui")
 p.controlsGui=make("ScreenGui",{Name="DevelopmentTopRightHud",IgnoreGuiInset=true,ScreenInsets=Enum.ScreenInsets.None,ClipToDeviceSafeArea=false,ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,DisplayOrder=owner.DisplayOrder+1,Parent=owner.Parent})
 table.insert(s.created,p.controlsGui)
 p.player=panel(s.layer,"PlayerChip",216,54)
 p.marker=make("Frame",{Name="Colour",Position=UDim2.fromOffset(12,15),Size=UDim2.fromOffset(24,24),
  BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=62,Parent=p.player})
 make("UICorner",{CornerRadius=UDim.new(0,5),Parent=p.marker})
 p.name=label(p.player,"Name","",46,7,158,23,16)
 p.share=label(p.player,"Share","",46,29,158,17,11,C.muted)
 p.menuButton=button(p.controlsGui,"MenuButton","",0,0,120,34)
 p.exitButton=button(p.controlsGui,"ExitButton","EXIT",0,0,120,34)
 for _,b in {p.menuButton,p.exitButton} do
  b.BackgroundColor3=C.panel;b.TextSize=13;b.TextXAlignment=Enum.TextXAlignment.Center;b.TextYAlignment=Enum.TextYAlignment.Center
  make("UIStroke",{Color=Color3.new(0,0,0),Thickness=1.5,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=b})
  make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(190,210,235)),Rotation=90,Parent=b})
  b:FindFirstChildWhichIsA("UICorner").CornerRadius=UDim.new(0,9)
 end
 local exitArmed=0
 p.exitButton.Activated:Connect(function()
  if os.clock()<exitArmed then
   exitArmed=0;p.menu.Visible=false;api.close()
   require(script.Parent:WaitForChild("PauseMenu")).exitGame()
  else
   exitArmed=os.clock()+3;p.exitButton.Text="CONFIRM?";p.exitButton.BackgroundColor3=Color3.fromRGB(220,55,55)
   task.delay(3,function() if p.exitButton.Parent and os.clock()>=exitArmed then p.exitButton.Text="EXIT";p.exitButton.BackgroundColor3=C.panel end end)
  end
 end)
 local menuContents=make("Frame",{Name="Contents",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(64,20),BackgroundTransparency=1,ZIndex=64,Parent=p.menuButton})
 local menuCaption=label(menuContents,"Caption","MENU",20,0,44,20,13);menuCaption.TextXAlignment=Enum.TextXAlignment.Center;menuCaption.TextYAlignment=Enum.TextYAlignment.Center
 for i=0,2 do make("Frame",{Name="MenuLine"..i,Position=UDim2.fromOffset(0,3+i*6),Size=UDim2.fromOffset(14,2),BackgroundColor3=C.white,BorderSizePixel=0,ZIndex=64,Parent=menuContents}) end
 p.menu=panel(p.controlsGui,"MatchMenu",216,80);p.menu.Visible=false
 p.menuButton.Activated:Connect(function() p.menu.Visible=not p.menu.Visible end)
 local settings=button(p.menu,"Settings","Settings / Exit",6,6,204,30)
 settings.Activated:Connect(function() p.menu.Visible=false;api.close();api.ctx.openMenu() end)
 local credits=button(p.menu,"Credits","Credits",6,40,204,30)
 credits.Activated:Connect(function() p.menu.Visible=false;api.close();api.creditsPop.Visible=true;api.layout() end)
 p.gamepassContent=nil
 p.clock=panel(p.controlsGui,"MatchClock",128,34)
 local clockOutline=p.clock:FindFirstChildWhichIsA("UIStroke");clockOutline.Color=Color3.new(0,0,0);clockOutline.Thickness=1.5
 p.time=label(p.clock,"Time","00:00",8,0,112,34,20);p.time.TextXAlignment=Enum.TextXAlignment.Center;p.time.TextYAlignment=Enum.TextYAlignment.Center
 p.goalTrack=panel(s.layer,"VictoryProgress",300,12)
 local goalOutline=p.goalTrack:FindFirstChildWhichIsA("UIStroke");goalOutline.Color=Color3.new(0,0,0);goalOutline.Thickness=2
 p.leaderFill=make("Frame",{Name="LeaderProgress",Size=UDim2.fromScale(0,1),BackgroundColor3=Color3.fromRGB(255,211,55),BorderSizePixel=0,ZIndex=61,Parent=p.goalTrack})
 make("UICorner",{CornerRadius=UDim.new(0,3),Parent=p.leaderFill})
 p.goalFill=make("Frame",{Name="Progress",Size=UDim2.fromScale(0,1),BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=62,Parent=p.goalTrack})
 make("UICorner",{CornerRadius=UDim.new(0,3),Parent=p.goalFill})
 p.goal=label(s.layer,"VictoryGoal","VICTORY 80%",0,0,300,20,14,Color3.fromRGB(255,211,55));p.goal.TextXAlignment=Enum.TextXAlignment.Center
 p.goal.Font=Enum.Font.GothamBlack;p.goal.TextStrokeColor3=Color3.new(0,0,0);p.goal.TextStrokeTransparency=0
 p.leaderMark=make("Frame",{Name="LeaderMarker",AnchorPoint=Vector2.new(.5,0),Position=UDim2.fromScale(0,0),Size=UDim2.fromOffset(2,8),BackgroundColor3=C.amber,BorderSizePixel=0,ZIndex=65,Parent=p.goalTrack})
 p.ownMark=make("Frame",{Name="YourMarker",AnchorPoint=Vector2.new(.5,0),Position=UDim2.fromScale(0,0),Size=UDim2.fromOffset(2,8),BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=65,Parent=p.goalTrack})
 for _,line in {p.leaderMark,p.ownMark} do make("UIStroke",{Color=Color3.new(0,0,0),Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=line}) end
 p.leaderLabel=label(p.goalTrack,"LeaderLabel","#1",155,18,140,18,13,C.amber);p.leaderLabel.TextXAlignment=Enum.TextXAlignment.Center
 p.ownLabel=label(p.goalTrack,"YourLabel","YOU",5,18,140,18,13,C.cyan);p.ownLabel.TextXAlignment=Enum.TextXAlignment.Center
 for _,caption in {p.ownLabel,p.leaderLabel} do caption.TextStrokeColor3=Color3.new(0,0,0);caption.TextStrokeTransparency=0 end
 p.board=panel(s.layer,"DevelopmentLeaderboard",360,226)
 p.boardHeader=label(p.board,"Heading","LEADERBOARD",12,4,336,26,12)
 p.boardHeader.TextXAlignment=Enum.TextXAlignment.Left
 label(p.board,"PlayerHeading","PLAYER",58,33,128,16,10,C.muted)
 label(p.board,"GoldHeading","GOLD",186,33,78,16,10,C.muted)
 label(p.board,"TroopsHeading","TROOPS",266,33,80,16,10,C.muted)
 for i=1,5 do
  local b=button(p.board,"Row"..i,"",6,52+(i-1)*32,348,30)
  local rank=label(b,"Rank","",6,0,22,28,11,C.muted)
  local colour=make("Frame",{Name="Colour",Position=UDim2.fromOffset(30,7),Size=UDim2.fromOffset(14,14),
   BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=64,Parent=b})
  make("UICorner",{CornerRadius=UDim.new(0,3),Parent=colour})
  local name=label(b,"Player","",52,0,128,30,11)
  local gold=label(b,"Gold","",180,0,78,30,11,C.amber)
  local troops=label(b,"Troops","",260,0,80,30,11)
  local r={button=b,rank=rank,colour=colour,name=name,gold=gold,troops=troops}
  p.rows[i]=r
  b.Activated:Connect(function() if r.id and api.ctx.focusPlayer then api.ctx.focusPlayer(r.id) end end)
 end
 p.feed=panel(s.layer,"MatchUpdates",360,160)
 p.feedHeader=label(p.feed,"Heading","INBOX",4,4,352,32,14)
 p.feedHeader.BackgroundColor3=Color3.fromRGB(11,39,68);p.feedHeader.BackgroundTransparency=0
 p.feedHeader.TextXAlignment=Enum.TextXAlignment.Center;p.feedHeader.Font=Enum.Font.GothamBlack
 p.feedHeader.TextStrokeColor3=Color3.new(0,0,0);p.feedHeader.TextStrokeTransparency=0
 make("UICorner",{CornerRadius=UDim.new(0,6),Parent=p.feedHeader})
 p.boardToggle=touchTarget(p.board,"TouchLeaderboardToggle");p.boardToggle.BackgroundTransparency=1;p.boardToggle.Visible=false
 p.boardArrow=chevron(p.boardToggle)
 p.boardToggle.Activated:Connect(function()if p.touchLayout then p.touchBoardOpen=not p.touchBoardOpen;p.touchInboxOpen=false;Panels.layout(api)end end)
 p.inboxToggle=touchTarget(p.feed,"TouchInboxToggle");p.inboxToggle.BackgroundTransparency=1;p.inboxToggle.Visible=false
 p.inboxArrow=chevron(p.inboxToggle)
 p.inboxToggle.Activated:Connect(function()if p.touchLayout then p.touchInboxOpen=not p.touchInboxOpen;p.touchBoardOpen=false;Panels.layout(api)end end)
 p.requests=make("ScrollingFrame",{Name="AllianceRequestsAboveInbox",BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=3,ScrollingDirection=Enum.ScrollingDirection.Y,ClipsDescendants=true,Visible=false,ZIndex=64,Parent=s.layer})
 p.feedBody=make("Frame",{Name="Body",Position=UDim2.fromOffset(8,42),Size=UDim2.new(1,-16,1,-50),BackgroundTransparency=1,ClipsDescendants=true,ZIndex=61,Parent=p.feed})
 p.empty=label(p.feedBody,"Empty","No recent updates",0,3,224,24,11,C.muted)
 for _,v in {api.round,api.utility,api.creditsButton} do s.change(v,{Visible=false}) end
 local oldAlerts,oldSide=api.layoutAlerts,api.sideStep
 api.layoutAlerts=function(...) oldAlerts(...);Panels.layoutFeed(api) end
 api.sideStep=function(...) oldSide(...);Panels.layout(api);Panels.update(api) end
 local acc=0
 local connection=RunService.Heartbeat:Connect(function(dt)
  acc+=dt;if acc<.2 then return end;acc=0
  if not s.layer.Parent then return end
  Panels.update(api)
 end)
 local rootDestroyed=api.root.Destroying:Connect(function() p.controlsGui:Destroy() end)
 return function()
  rootDestroyed:Disconnect()
  connection:Disconnect()
  api.layoutAlerts=oldAlerts;api.sideStep=oldSide
  if api.refs and p.oldLayoutHiddenSaved then api.refs.feedFrame:SetAttribute("WFLayoutHidden",p.oldLayoutHidden) end
 end
end
local function borrowMenu(api,s,p,b,title,y)
 if not b then return end
 if not p.borrowed[b] then
  p.borrowed[b]=label(b,"DevelopmentMenuLabel",title,38,0,158,30,12)
  table.insert(s.created,p.borrowed[b])
  for _,v in b:GetChildren() do
   if v:IsA("ImageLabel") then s.change(v,{Position=UDim2.fromOffset(12,7),AnchorPoint=Vector2.zero,Size=UDim2.fromOffset(16,16),ZIndex=64})
   elseif v.Name=="Caption" or v.Name=="AngularShape" then s.change(v,{Visible=false}) end
  end
 end
 s.change(b,{Parent=p.menu,Position=UDim2.fromOffset(6,y),AnchorPoint=Vector2.zero,Size=UDim2.fromOffset(204,30),
  BackgroundColor3=C.raised,BackgroundTransparency=0,Visible=true,ZIndex=63,Text=""})
 p.borrowed[b].ZIndex=65
end
function Panels.layoutFeed(api)
 local s=api.development;local p=s and s.panels;local r=api.refs
 if not p or not r then return end
 if not p.oldLayoutHiddenSaved then p.oldLayoutHidden=r.feedFrame:GetAttribute("WFLayoutHidden");p.oldLayoutHiddenSaved=true end
 r.feedFrame:SetAttribute("WFLayoutHidden",false)
 s.change(r.feedFrame,{Parent=p.feedBody,AnchorPoint=Vector2.zero,Position=UDim2.fromOffset(0,0),
  Size=UDim2.fromScale(1,1),ClipsDescendants=true,ZIndex=62})
 local scale=r.feedFrame:FindFirstChildWhichIsA("UIScale");if scale then s.change(scale,{Scale=1}) end
 local requests=p.requests:FindFirstChild("Requests") or r.feedFrame:FindFirstChild("Requests")
 if requests then
  s.change(requests,{Parent=p.requests,AnchorPoint=Vector2.zero,Position=UDim2.fromOffset(0,0),Size=UDim2.new(1,0,0,0)})
  p.requests.Visible=requests.Visible and api.root.Visible
  for _,v in requests:GetDescendants() do
   if v:IsA("GuiObject") then
    s.change(v,{ZIndex=if v.Name=="AllianceActionLabel" then 67 elseif v.Name=="AllianceActionSurface" then 66 else 65})
    if v.Name=="AngularShape" or v.Name=="ActionCaption" then s.change(v,{Visible=false}) end
   end
   if v:IsA("TextButton") then
    local styles={
     ACCEPT={1,Color3.fromRGB(68,211,103),Color3.fromRGB(25,125,65)},
     DECLINE={2,Color3.fromRGB(255,96,96),Color3.fromRGB(170,38,48)},
     FOCUS={3,Color3.fromRGB(153,166,180),Color3.fromRGB(73,89,106)},
    }
    local style=styles[v.Name]
    if style then
     s.change(v,{LayoutOrder=style[1],BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,TextColor3=C.white,AutoButtonColor=false})
     if not p.styled[v] then
      local gradient=v:FindFirstChildWhichIsA("UIGradient")
      if gradient then s.change(gradient,{Enabled=false}) end
      local text=v.Text
      local width=game:GetService("TextService"):GetTextSize(text,v.TextSize,Enum.Font.GothamBold,Vector2.new(1000,100)).X+24
      s.change(v,{Text="",AutomaticSize=Enum.AutomaticSize.None,Size=UDim2.fromOffset(width,v.Size.Y.Offset),BackgroundTransparency=1})
      local face=make("Frame",{Name="AllianceActionSurface",Position=UDim2.fromOffset(-12,0),Size=UDim2.new(1,24,1,0),BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0,ZIndex=66,Parent=v})
      make("UICorner",{CornerRadius=UDim.new(0,4),Parent=face})
      make("UIGradient",{Name="AllianceActionFade",Color=ColorSequence.new(style[2],style[3]),Rotation=90,Parent=face})
      local caption=make("TextLabel",{Name="AllianceActionLabel",Position=UDim2.fromOffset(-12,0),Size=UDim2.new(1,24,1,0),BackgroundTransparency=1,FontFace=v.FontFace,TextSize=v.TextSize,Text=text,TextColor3=C.white,TextStrokeColor3=Color3.new(0,0,0),TextStrokeTransparency=.5,TextTransparency=0,ZIndex=67,Parent=v})
      table.insert(s.created,face);table.insert(s.created,caption)
     end
     p.styled[v]=true
    end
   end
   if v:IsA("GuiObject") and v.Name=="Request" then s.change(v,{BackgroundColor3=C.panel,BackgroundTransparency=0})
    local accent=v:FindFirstChild("Accent");if accent then s.change(accent,{Visible=false})end
    local title=v:FindFirstChild("Title",true)
    if title then
     s.change(title,{BackgroundTransparency=0,BackgroundColor3=Color3.fromRGB(11,39,65),Font=Enum.Font.GothamBold,TextColor3=C.white,TextStrokeColor3=Color3.new(0,0,0),TextStrokeTransparency=0,TextXAlignment=Enum.TextXAlignment.Center})
     if not p.styled[title] then
      p.styled[title]=true
      local pad=make("UIPadding",{PaddingTop=UDim.new(0,7),PaddingBottom=UDim.new(0,7),PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),Parent=title});table.insert(s.created,pad)
      local round=make("UICorner",{CornerRadius=UDim.new(0,6),Parent=title});table.insert(s.created,round)
     end
    end
   end
  end
 end
 -- Development messages are separate cards; restore all original properties on cleanup.
 for _,v in r.feedFrame:GetDescendants() do
  if v:IsA("GuiObject") and (v.Name=="Events" or v.Name=="Important") then
   s.change(v,{BackgroundTransparency=1})
  elseif v:IsA("GuiObject") and (v.Name=="Event" or v.Name=="Request") then
   s.change(v,{BackgroundColor3=Color3.fromRGB(13,48,80),BackgroundTransparency=0})
   if not p.styled[v] then
    p.styled[v]=true
    if not v:FindFirstChildWhichIsA("UICorner") then
     local round=make("UICorner",{CornerRadius=UDim.new(0,5),Parent=v});table.insert(s.created,round)
    end
   end
  elseif v:IsA("UIListLayout") and v.Parent and v.Parent.Name=="Content" then
   s.change(v,{Padding=UDim.new(0,6)})
  end
 end
 -- Preserve the real scrollable feed, event focus callbacks, expiry, and alliance requests.
 for _,v in r.feedFrame:GetDescendants() do if v:IsA("GuiObject") then s.change(v,{ZIndex=63}) end end
 local has=false
 for _,v in r.feedFrame:GetChildren() do
  if v:IsA("GuiObject") and v.Visible then has=true;break end
 end
 p.empty.Visible=not has
 p.feedBody.Visible=true
end
function Panels.layout(api)
 local s=api.development;local p=s and s.panels;if not p or p.layingOut then return end
 p.layingOut=true
 local size=api.ctx.gui.AbsoluteSize;local X,Y=size.X,size.Y
 local touch=s.touchLayout or (api.ctx.device.state and api.ctx.device.state.profile=="tablet") or X<700 or Y<500
 p.touchLayout=touch
 local u=if touch then 1 else math.min(api.ctx.device.userScale or 1,math.max(.65,X/700))
 p.controlsGui.ScreenInsets=if touch then Enum.ScreenInsets.CoreUISafeInsets else Enum.ScreenInsets.None
 p.controlsGui.ClipToDeviceSafeArea=touch
 local inset=GuiService:GetGuiInset()
 local top=math.max(12,math.min(64,inset.Y+6))
 -- Preserve the desktop top row; touch controls use Roblox and device safe areas.
 local controlsTop=if touch then 8 else 12
 local function scale(v)
  local existing=v:FindFirstChildWhichIsA("UIScale")
  if not existing then existing=make("UIScale",{Parent=v}) end
  existing.Scale=u
 end
 for _,v in {p.player,p.menuButton,p.exitButton,p.menu,p.clock,p.goalTrack,p.goal,p.board,p.feed,p.requests} do scale(v) end
 p.player.Position=UDim2.fromOffset(12,top)
 local centreTop=if X<900 then top+306*u else 12
 p.clock.AnchorPoint=Vector2.zero;p.clock.Position=UDim2.fromOffset(220,controlsTop)
 p.goalTrack.AnchorPoint=Vector2.new(.5,0);p.goalTrack.Position=UDim2.new(.5,0,0,centreTop+26*u)
 p.goal.AnchorPoint=Vector2.new(.5,0);p.goal.Position=UDim2.new(.5,0,0,centreTop)
 p.board.AnchorPoint=Vector2.zero
 local boardTop=top
 p.board.Position=UDim2.fromOffset(12,boardTop)
 p.boardCollapsed=touch and not p.touchBoardOpen
 local n=0;for _,r in p.rows do if r.id then n+=1 end;r.button.Visible=not p.boardCollapsed and r.id~=nil end
 p.board.Size=UDim2.fromOffset(360,if p.boardCollapsed then 34 else 58+math.max(1,n)*32)
 for _,name in {"PlayerHeading","GoldHeading","TroopsHeading"} do p.board[name].Visible=not p.boardCollapsed end
 p.menuButton.AnchorPoint=Vector2.new(1,0);p.menuButton.Position=UDim2.new(1,-12-256*u,0,controlsTop)
 p.exitButton.AnchorPoint=Vector2.new(1,0);p.exitButton.Position=UDim2.new(1,-12,0,controlsTop)
 p.menu.AnchorPoint=Vector2.new(1,0);p.menu.Position=UDim2.new(1,-12-256*u,0,controlsTop+40*u)
 p.boardHeader.Text=if touch then (if p.boardCollapsed then "LEADERBOARD ▾" else "LEADERBOARD ▴") else "LEADERBOARD"
 local barWidth,barHeight=s.bar.Size.X.Offset*s.scale.Scale,s.bar.Size.Y.Offset*s.scale.Scale
 local bottom=if Y<500 then 10 else 20
 local navbarLift=if touch then 0 else math.max(0,(160*u-barHeight)/2)
 s.bar.Position=UDim2.new(.5,0,1,-bottom-navbarLift)
 local sideGap=(X-barWidth)/2-24
 local beside=sideGap>=360*u
 local feedW=if beside then math.min(360,sideGap/u) else math.min(360,(X-24)/u)
 p.feed.AnchorPoint=Vector2.new(1,1)
 p.feed.Position=UDim2.new(1,-12,1,-(if beside then bottom else bottom+navbarLift+barHeight+12))
 p.feed.Size=UDim2.fromOffset(feedW,160)
 p.feedHeader.Size=UDim2.new(1,-8,0,32)
 p.feedHeader.Text="INBOX"
 p.empty.Size=UDim2.new(1,0,0,24)
 local menuHeight=76
 local ui=api.sidebar
 if ui then
  if ui.boosts and ui.boostsPanel then
   local b=ui.boosts
   if not p.gamepassContent then
    -- Reuse the real button and purchase panel; only their presentation moves.
    require(script.Parent:WaitForChild("BoostsPanel")).collapse()
    p.gamepassContent=true
    for _,v in b:GetChildren() do
     if (v:IsA("ImageLabel") or v.Name=="Caption" or v.Name=="AngularShape") then s.change(v,{Visible=false})end
    end
    local corner=make("UICorner",{CornerRadius=UDim.new(0,9),Parent=b});table.insert(s.created,corner)
    local stroke=make("UIStroke",{Color=Color3.new(0,0,0),Thickness=1.5,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=b});table.insert(s.created,stroke)
    local gradient=make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(190,210,235)),Rotation=90,Parent=b});table.insert(s.created,gradient)
    table.insert(s.connections,b.Activated:Connect(function() p.menu.Visible=false end))
   end
   s.change(b,{Parent=p.controlsGui,AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-12-128*u,0,controlsTop),Size=UDim2.fromOffset(120,34),BackgroundColor3=C.panel,BackgroundTransparency=0,Text="Boosts",TextSize=13,Font=Enum.Font.GothamBold,TextColor3=C.white,TextXAlignment=Enum.TextXAlignment.Center,TextYAlignment=Enum.TextYAlignment.Center,Visible=api.root.Visible,ZIndex=63})
   local function scaleBorrowed(v)
    local existing=v:FindFirstChildWhichIsA("UIScale")
    if existing then s.change(existing,{Scale=u})
    else local created=make("UIScale",{Scale=u,Parent=v});table.insert(s.created,created) end
   end
   scaleBorrowed(b)
   s.change(ui.boostsPanel,{Parent=p.controlsGui,AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-12-128*u,0,controlsTop+40*u),Size=UDim2.fromOffset(320,math.min(232,math.max(100,(Y-70)/u))),BackgroundColor3=C.panel,BackgroundTransparency=0,ZIndex=70})
   scaleBorrowed(ui.boostsPanel)
   for _,v in ui.boostsPanel:GetDescendants()do if v:IsA("GuiObject") and v.Name~="DefaultCardSurface" and not v:FindFirstAncestor("DefaultCardSurface") then
    if v.Name=="AngularShape" then s.change(v,{Visible=false}) end
    if (v.Name=="BoostCard" or (v:IsA("TextButton") and v.Name~="CardClickTarget")) and not p.styled[v] then
     p.styled[v]=true
     s.change(v,{Rotation=0})
     local face=make("Frame",{Name="DefaultCardSurface",Size=UDim2.fromScale(1,1),BackgroundColor3=v.BackgroundColor3,BorderSizePixel=0,ZIndex=v.ZIndex+30,Parent=v})
     make("UICorner",{CornerRadius=UDim.new(0,6),Parent=face})
     make("UIStroke",{Color=C.border,Transparency=.3,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=face})
     make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(190,210,235)),Parent=face})
     table.insert(s.created,face)
     table.insert(s.connections,v:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()face.BackgroundColor3=v.BackgroundColor3 end))
    end
    local original=s.saved[v] and s.saved[v].ZIndex or v.ZIndex
    s.change(v,{ZIndex=original+30})
   end end
  end
  if ui.speedBtn.Visible then borrowMenu(api,s,p,ui.speedBtn,"Game speed",menuHeight);menuHeight+=34 end
  if ui.pauseBtn.Visible then borrowMenu(api,s,p,ui.pauseBtn,"Pause / resume",menuHeight);menuHeight+=34 end
 end
 p.menu.Size=UDim2.fromOffset(216,menuHeight+6)
 if api.refs then
  local r=api.refs
  api.infoTop=centreTop+128*u;api.infoBottom=api.infoTop+30*u
  local spectating=r.bannerText and string.find(string.lower(r.bannerText.Text),"spectating",1,true)~=nil
  s.change(r.banner,{AnchorPoint=Vector2.new(.5,0),Position=if spectating then UDim2.new(.5,0,1,-bottom-navbarLift-barHeight-38) else UDim2.new(.5,0,0,api.infoTop)})
  for _,v in {r.zoomIn,r.zoomOut,r.board} do s.change(v,{Visible=false}) end
  Panels.layoutFeed(api)
  local attacks=api.attackBody:FindFirstChild("AttacksDisplay") or r.stack:FindFirstChild("AttacksDisplay")
  if attacks then s.change(attacks,{Parent=r.stack,Position=UDim2.fromOffset(0,0)}) end
  local stackBottom=bottom+navbarLift+barHeight+8
  if not beside and X<1000 then stackBottom+=p.feed.Size.Y.Offset*u+12 end
  s.change(r.stack,{AnchorPoint=Vector2.new(.5,1),Position=UDim2.new(.5,0,1,-stackBottom),Size=UDim2.fromOffset(math.min(390,(X-24)/u),112)})
  local ss=r.stack:FindFirstChildWhichIsA("UIScale");if ss then s.change(ss,{Scale=u}) end
 end
 if ui then
  -- Keep timed immunity/overtime information available above the right panel.
  s.change(ui.clocks,{AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-12,0,boardTop+p.board.Size.Y.Offset*u+8)})
 end
 for _,v in {api.round,api.utility,api.creditsButton,api.attacksPop} do s.change(v,{Visible=false}) end
 -- Touch panels are deliberately compact; expanding a table/feed is an explicit tap.
 p.boardToggle.Visible=touch;p.inboxToggle.Visible=touch
 p.boardArrow.Visible=s.mobileLayout==true;p.inboxArrow.Visible=s.mobileLayout==true
 p.boardArrow.Rotation=if p.touchBoardOpen then 180 else 0;p.inboxArrow.Rotation=if p.touchInboxOpen then 180 else 0
 if touch then
  local portrait=X<600
  local controlY=if portrait then math.max(48,inset.Y)+6 else 12
  local bw=if portrait then math.min(90,(X-36)/3) else 90
  local stride=bw+6
  for _,b in {p.menuButton,p.exitButton} do b.Size=UDim2.fromOffset(bw,32)end
  p.menuButton.Position=UDim2.new(1,-12-2*stride,0,controlY)
  p.exitButton.Position=UDim2.new(1,-12,0,controlY)
  p.menu.Position=UDim2.new(1,-12-2*stride,0,controlY+38)
  p.clock.Size=UDim2.fromOffset(if portrait then 96 else 112,32)
  p.time.Size=UDim2.new(1,-16,1,0);p.time.TextSize=16
  p.clock.Position=UDim2.fromOffset(if portrait then 12 else 220,if portrait then controlY+38 else controlY)
  local rowY=controlY+38
  local boardWidth=if p.touchBoardOpen then math.min(360,X-24) elseif portrait then math.max(110,X-252) else 180
  p.board.Position=UDim2.fromOffset(if portrait and not p.touchBoardOpen then 116 else 12,if p.touchBoardOpen then rowY+38 else rowY)
  p.board.Size=UDim2.fromOffset(boardWidth,if p.touchBoardOpen then 58+math.max(1,n)*32 else 32)
  p.boardHeader.Size=UDim2.new(1,-24,0,26);p.boardHeader.TextSize=if portrait then 10 else 12
  p.boardToggle.Size=UDim2.new(1,0,0,34)
  p.feed.AnchorPoint=Vector2.new(1,0);p.feed.Position=UDim2.new(1,-12,0,if p.touchInboxOpen then rowY+38 else rowY)
  p.feed.Size=UDim2.fromOffset(if p.touchInboxOpen then math.min(320,X-24) elseif portrait then 116 else 160,if p.touchInboxOpen then 160 else 32)
  p.feedHeader.Size=UDim2.new(1,-8,0,24);p.feedHeader.TextSize=12;p.feedHeader.Text=if p.touchInboxOpen then "INBOX ▴" else "INBOX ▾"
  p.inboxToggle.Size=UDim2.new(1,0,0,32)
  p.feedBody.Visible=p.touchInboxOpen==true;p.feed.Visible=api.root.Visible and not p.touchBoardOpen
  p.board.Visible=api.root.Visible and not p.touchInboxOpen
  if s.mobileLayout then
   p.clock.Visible=false;p.exitButton.Visible=false
   p.menuButton.Position=UDim2.new(1,-12-stride,0,controlY)
   if ui and ui.boosts then ui.boosts.Position=UDim2.new(1,-12,0,controlY)end
   p.board.Position=UDim2.fromOffset(12,if p.touchBoardOpen then rowY+50 else rowY+12)
   p.board.Size=UDim2.fromOffset(if p.touchBoardOpen then math.min(360,X-24) else math.min(160,(X-36)/2),p.board.Size.Y.Offset)
   p.boardHeader.Text="LEADERBOARD"
   p.feedHeader.Text="INBOX"
  end
  local goalY=if s.mobileLayout then (if portrait then rowY+30 else controlY+4) elseif portrait then rowY+42 else rowY
  p.goal.Position=UDim2.new(.5,0,0,goalY);p.goalTrack.Position=UDim2.new(.5,0,0,goalY+24)
  p.goalTrack.Size=UDim2.fromOffset(220,12)
  p.ownLabel.Position=UDim2.fromOffset(0,18);p.ownLabel.Size=UDim2.fromOffset(105,18)
  p.leaderLabel.Position=UDim2.fromOffset(115,18);p.leaderLabel.Size=UDim2.fromOffset(105,18)
  p.goal.Visible=p.goal.Visible and not p.touchBoardOpen and not p.touchInboxOpen
  p.goalTrack.Visible=p.goalTrack.Visible and not p.touchBoardOpen and not p.touchInboxOpen
  if ui and ui.boosts then
   ui.boosts.Size=UDim2.fromOffset(bw,32);ui.boosts.Position=UDim2.new(1,if s.mobileLayout then -12 else -12-stride,0,controlY)
   ui.boosts.TextSize=11
    p.menu.Position=UDim2.new(1,-12,0,controlY+38)
   s.change(ui.boostsPanel,{Position=UDim2.new(1,-12,0,controlY+38),Size=UDim2.fromOffset(math.min(320,X-24),math.min(232,math.max(90,Y-controlY-barHeight-56)))})
  end
 else
  p.menuButton.Size=UDim2.fromOffset(120,34);p.exitButton.Size=UDim2.fromOffset(120,34)
  p.clock.Size=UDim2.fromOffset(128,34);p.time.Size=UDim2.fromOffset(112,34);p.time.TextSize=20
  p.boardHeader.Size=UDim2.fromOffset(336,26);p.boardHeader.TextSize=12
  p.goalTrack.Size=UDim2.fromOffset(300,12)
  p.ownLabel.Position=UDim2.fromOffset(5,18);p.ownLabel.Size=UDim2.fromOffset(140,18)
  p.leaderLabel.Position=UDim2.fromOffset(155,18);p.leaderLabel.Size=UDim2.fromOffset(140,18)
 end
 local requestContent=p.requests:FindFirstChild("Requests")
 local requestHeight=if requestContent and requestContent.Visible then requestContent.AbsoluteSize.Y/math.max(.01,u) else 0
 p.requests.Visible=api.root.Visible and requestHeight>0
 if p.requests.Visible then
  local feedTop=p.feed.Position.Y.Offset-p.feed.Size.Y.Offset*p.feed.AnchorPoint.Y*u
  local maxHeight=if touch then math.max(48,(Y-barHeight-100)/u) else math.max(48,(Y+feedTop-100)/u)
  local height=math.min(requestHeight,maxHeight)
  p.requests.AnchorPoint=Vector2.new(1,1)
  p.requests.Size=UDim2.fromOffset(if touch then math.min(320,X-24) else feedW,height)
  if touch then
   local y=(if X<600 then math.max(48,inset.Y)+6 else 12)+38
   p.requests.Position=UDim2.new(1,-12,0,y+height*u)
   p.feed.Position=UDim2.new(1,-12,0,math.max(p.feed.Position.Y.Offset,y+height*u+8))
  else
   p.requests.Position=UDim2.new(1,-12,p.feed.Position.Y.Scale,feedTop-8)
  end
 end
 if game.Players.LocalPlayer.PlayerGui:GetAttribute("FrontlinesTutorial")==true then
  p.board.Visible=false;p.goal.Visible=false;p.goalTrack.Visible=false
 end
 p.layingOut=false
end
function Panels.update(api)
 local s=api.development;local p=s and s.panels;if not p then return end
 local mine=api.ctx.getMine();local stats=mine and mine.stats
 p.controlsGui.Enabled=api.root.Visible
 p.player.Visible=false;p.menuButton.Visible=api.root.Visible;p.exitButton.Visible=api.root.Visible;p.clock.Visible=api.root.Visible
 p.goalTrack.Visible=stats~=nil;p.goal.Visible=stats~=nil
 p.board.Visible=api.root.Visible;p.feed.Visible=api.root.Visible
 p.name.Text=api.name.Text;p.share.Text=api.share.Text:gsub(" land"," of the world")
 if mine then p.marker.BackgroundColor3=Color3.fromRGB(mine.r or 0,mine.g or 177,mine.b or 235) end
 p.time.Text=api.timer.Text;p.time.TextColor3=api.timer.TextColor3
 p.goal.Text=api.goal.Text:gsub("^GOAL","VICTORY");p.goalFill.Size=api.progress.Size
 if not api.root.Visible then p.menu.Visible=false end
 local now=os.clock()
 if now-p.lastRoster>=.35 then
  p.lastRoster=now
  local roster=api.ctx.getRoster and api.ctx.getRoster() or {}
  local myId=api.ctx.getMyId and api.ctx.getMyId() or (mine and mine.id)
  local sorted={};for _,v in roster do if v.stats and v.stats.alive and (v.stats.tiles or 0)>0 then table.insert(sorted,v) end end
  table.sort(sorted,function(a,b) if a.stats.tiles==b.stats.tiles then return a.id<b.id end;return a.stats.tiles>b.stats.tiles end)
  local ownRank;for i,v in sorted do if v.id==myId then ownRank=i;break end end
  local land=math.max(1,api.ctx.getMap().landTiles or 1)
  local target=math.max(.01,(tonumber(api.goal.Text:match("([%d%.]+)%%")) or 80)/100)
  local function marker(line,caption,v,title,y)
   local fraction=if v then (v.stats.tiles or 0)/land else 0
   local pos=math.clamp(fraction/target,0,1)
   local width=p.goalTrack.Size.X.Offset
   line.Position=UDim2.fromOffset(math.clamp(pos*width,4,width-4),2)
   caption.Text=string.format("%s %.1f%%",title,fraction*100)
   line.Visible=v~=nil;caption.Visible=v~=nil
   return pos
  end
  p.leaderFill.Size=UDim2.fromScale(marker(p.leaderMark,p.leaderLabel,sorted[1],"#1",20),1)
  marker(p.ownMark,p.ownLabel,mine,"YOU",36)
  for i,r in p.rows do
   local rank=if i==5 and ownRank and ownRank>5 then ownRank else i
   local v=sorted[rank];r.id=v and v.id
   if v then
    r.rank.Text=tostring(rank);r.name.Text=v.name;r.gold.Text=api.ctx.fmt(v.stats.gold or 0);r.troops.Text=api.ctx.fmtTroops(v.stats.troops or 0)
    r.colour.BackgroundColor3=Color3.fromRGB(v.r or 0,v.g or 177,v.b or 235)
    r.button.BackgroundColor3=if v.id==myId then C.raised:Lerp(C.cyan,.35) else C.panel
   end
  end
 end
 Panels.layout(api)
end
return Panels
