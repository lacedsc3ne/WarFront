-- War Front corner command HUD. Copyright (C) 2026 Liam (lacedsc3ne). AGPL-3.0-or-later.
-- Presentation only: commands, balance, purchases and match state remain in the existing systems.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SimClock = require(Shared:WaitForChild("SimClock"))
local IconKit = require(script.Parent:WaitForChild("IconKit"))
local MenuStyle = require(script.Parent:WaitForChild("MenuStyle"))
local ContextActionService = game:GetService("ContextActionService")
local KeybindData = require(script.Parent:WaitForChild("KeybindData"))
local CornerHud = {}
local C = { panel=Color3.fromRGB(5,22,40), raised=Color3.fromRGB(14,43,64),
 cyan=Color3.fromRGB(0,177,235), white=Color3.fromRGB(241,248,255),
 muted=Color3.fromRGB(155,184,219), gold=Color3.fromRGB(255,211,35), mint=Color3.fromRGB(102,223,181),
 red=Color3.fromRGB(240,91,80) } -- red: can't afford (the Night HUD maps it to its pink-red)
local function make(class,props)
 local v=Instance.new(class)
 for k,value in props do if k~="Parent" then v[k]=value end end
 v.Parent=props.Parent
 return v
end
local function round(v,r)
 local existing=v:FindFirstChildWhichIsA("UICorner")
 if existing then existing.CornerRadius=UDim.new(0,r or 6) else make("UICorner",{CornerRadius=UDim.new(0,r or 6),Parent=v}) end
end
local function skin(v,fill,cut)
 if v.AutomaticSize~=Enum.AutomaticSize.None or v:IsA("ScrollingFrame") then
  v.BackgroundColor3=fill;v.BackgroundTransparency=0
  round(v,5)
  if not v:FindFirstChildWhichIsA("UIStroke") then make("UIStroke",{Color=C.cyan,Transparency=.35,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=v}) end
  return
 end
 if v:FindFirstChild("AngularShape") then return end
 local bg=MenuStyle.panel(v,fill,cut or 10)
 for _,part in bg:GetChildren() do
  if part:IsA("ImageLabel") or (part:IsA("Frame") and part.ZIndex==0) then
   make("UIGradient",{Color=ColorSequence.new(Color3.new(1,1,1),Color3.new(.88,.88,.88)),Rotation=90,Parent=part})
  end
 end
end
local function paint(v,fill)
 local bg=v:FindFirstChild("AngularShape")
 if bg then for _,part in bg:GetChildren() do
  if part:IsA("ImageLabel") then part.ImageColor3=fill
  elseif part:IsA("Frame") and part.ZIndex==0 then part.BackgroundColor3=fill end
 end else v.BackgroundColor3=fill end
end
local function frame(parent,name,w,h)
 local v=make("Frame",{Name=name,Size=UDim2.fromOffset(w,h),BackgroundColor3=C.panel,BorderSizePixel=0,ZIndex=50,Parent=parent})
 skin(v,C.panel,10);return v
end
local function text(parent,name,value,x,y,w,h,size,color)
 return make("TextLabel",{Name=name,Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),
 BackgroundTransparency=1,Font=if (size or 12)>=18 then Enum.Font.GothamBlack else Enum.Font.GothamBold,TextSize=size or 12,TextColor3=color or C.white,
 TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ZIndex=52,Parent=parent})
end
local function button(parent,name,caption,icon,w,h)
 local b=make("TextButton",{Name=name,Size=UDim2.fromOffset(w,h),BackgroundColor3=C.panel,BorderSizePixel=0,
 Text="",AutoButtonColor=false,ZIndex=55,Parent=parent})
 skin(b,C.panel,7)
 if icon then IconKit.image(icon,{Name="Icon",Size=UDim2.fromOffset(18,18),AnchorPoint=Vector2.new(0,0.5),Position=UDim2.new(0,10,0.5,0),ZIndex=56,Parent=b}) end
 if caption~="" then text(b,"Caption",string.upper(caption),if icon then 34 else 10,0,w-(if icon then 40 else 20),h,12) end
 b.MouseEnter:Connect(function() paint(b,if b:GetAttribute("Primary") then C.cyan:Lerp(C.white,.12) else C.raised) end)
 b.MouseLeave:Connect(function() paint(b,if b:GetAttribute("Primary") then C.cyan else C.panel) end)
 return b
end
local function place(v,x,y,w,h)
 v.AnchorPoint=Vector2.zero;v.Position=UDim2.fromOffset(x,y)
 if w then v.Size=UDim2.fromOffset(w,h) end
end
local function stamp(seconds)
 seconds=math.max(0,math.floor(seconds));return string.format("%02d:%02d",seconds//60,seconds%60)
end
function CornerHud.create(ctx)
 local api={ctx=ctx,open=nil,boardOpen=false,attackOpen=false,lastUpdate=0}
 local root=make("Frame",{Name="CornerHud",Size=UDim2.fromOffset(0,0),BackgroundTransparency=1,Visible=false,ZIndex=50,Parent=ctx.gui})
 api.root=root
 api.resources=frame(root,"Resources",230,124)
 api.name=text(api.resources,"NationName","",14,9,132,19,12)
 api.share=text(api.resources,"LandShare","",144,9,74,19,11,C.muted)
 text(api.resources,"TroopHeading","TROOPS",14,38,100,15,10,C.muted)
 text(api.resources,"GoldHeading","GOLD",133,38,80,15,10,C.muted)
 api.troops=text(api.resources,"Troops","0",14,54,100,26,22)
 api.gold=text(api.resources,"Gold","0",133,54,82,26,22,C.gold)
 api.max=text(api.resources,"Maximum","/ 0",14,81,100,16,10,C.muted)
 api.growth=text(api.resources,"Growth","",14,94,104,12,9,C.mint)
 api.goldNote=text(api.resources,"GoldNote","Spend to build",133,81,82,16,9,C.muted)
 local track=make("Frame",{Name="CapacityTrack",Position=UDim2.fromOffset(14,109),Size=UDim2.fromOffset(202,3),BackgroundColor3=C.raised,BorderSizePixel=0,ZIndex=51,Parent=api.resources})
 api.capacity=make("Frame",{Name="Capacity",Size=UDim2.fromScale(0,1),BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=52,Parent=track})
 api.round=frame(root,"RoundStatus",186,64)
 api.map=text(api.round,"MapName","",10,6,166,14,9,C.muted);api.map.TextXAlignment=Enum.TextXAlignment.Center
 api.timer=text(api.round,"Timer","00:00",14,24,80,24,19)
 api.goal=text(api.round,"Goal","GOAL 80%",98,28,77,18,10,C.gold)
 local goalTrack=make("Frame",{Position=UDim2.fromOffset(12,54),Size=UDim2.fromOffset(162,3),BackgroundColor3=C.raised,BorderSizePixel=0,ZIndex=51,Parent=api.round})
 api.progress=make("Frame",{Size=UDim2.fromScale(0,1),BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=52,Parent=goalTrack})
 api.utility=make("Frame",{Name="Utilities",Size=UDim2.fromOffset(164,38),BackgroundTransparency=1,ZIndex=55,Parent=root})
 api.boardBtn=button(api.utility,"Leaderboard","", "Leaderboard",36,36)
 api.attackBtn=button(api.utility,"Attacks","","Sword",36,36)
 api.settingsBtn=button(api.utility,"Settings","","Settings",36,36)
 api.menuBtn=button(api.utility,"Menu","",nil,36,36)
 for i=0,2 do make("Frame",{Position=UDim2.fromOffset(10,11+i*6),Size=UDim2.fromOffset(16,2),BackgroundColor3=C.white,BorderSizePixel=0,ZIndex=56,Parent=api.menuBtn}) end
 for i,b in {api.boardBtn,api.attackBtn,api.settingsBtn,api.menuBtn} do
  place(b,(i-1)*42,0);local im=b:FindFirstChild("Icon");if im then im.AnchorPoint=Vector2.new(.5,.5);im.Position=UDim2.fromScale(.5,.5) end
 end
 api.attackCount=text(api.attackBtn,"Count","",23,-3,15,15,9,C.panel)
 api.attackCount.BackgroundTransparency=0;api.attackCount.BackgroundColor3=C.cyan;api.attackCount.TextXAlignment=Enum.TextXAlignment.Center;api.attackCount.ZIndex=57;round(api.attackCount,8)
 api.attack=frame(root,"AttackControl",215,84)
 text(api.attack,"Heading","Attack ratio",14,8,130,21,12)
 api.ratio=text(api.attack,"Ratio","",151,7,51,22,19,C.cyan);api.ratio.TextXAlignment=Enum.TextXAlignment.Right
 api.send=text(api.attack,"Send","",14,59,184,16,10,C.muted)
 api.slider=make("TextButton",{Name="RatioSlider",Position=UDim2.fromOffset(14,31),Size=UDim2.fromOffset(187,26),BackgroundTransparency=1,Text="",AutoButtonColor=false,ZIndex=54,Parent=api.attack})
 local rail=make("Frame",{Position=UDim2.new(0,0,.5,-2),Size=UDim2.new(1,0,0,4),BackgroundColor3=C.raised,BorderSizePixel=0,ZIndex=54,Parent=api.slider})
 api.fill=make("Frame",{Size=UDim2.fromScale(.2,1),BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=55,Parent=rail})
 api.knob=make("Frame",{AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.2,.5),Size=UDim2.fromOffset(14,14),BackgroundColor3=C.cyan,BorderSizePixel=0,ZIndex=56,Parent=rail});round(api.knob,7)
 api.commands=make("Frame",{Name="Commands",Size=UDim2.fromOffset(308,42),BackgroundTransparency=1,ZIndex=55,Parent=root})
 api.buildBtn=button(api.commands,"Build","Build","City",95,42)
 api.buildBtn:SetAttribute("Primary",true);paint(api.buildBtn,C.cyan)
 api.militaryBtn=button(api.commands,"Military","Military","Silo",108,42)
 place(api.militaryBtn,102,0)
 api.buildPop=frame(root,"BuildPopover",306,236);api.buildPop.Visible=false
 api.buildHeading=text(api.buildPop,"Heading","Construction",13,9,180,22,13)
 api.buildClose=make("TextButton",{Name="Close",Size=UDim2.fromOffset(28,28),BackgroundColor3=C.raised,BackgroundTransparency=1,BorderSizePixel=0,Text="",AutoButtonColor=false,ZIndex=55,Parent=api.buildPop})
 place(api.buildClose,268,6);round(api.buildClose,5)
 IconKit.image("Back",{Name="BackArrow",Size=UDim2.fromOffset(16,16),AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),ImageColor3=C.muted,ZIndex=56,Parent=api.buildClose})
 api.buildClose.MouseEnter:Connect(function() api.buildClose.BackgroundTransparency=0 end)
 api.buildClose.MouseLeave:Connect(function() api.buildClose.BackgroundTransparency=1 end)
 api.buildClose.SelectionGained:Connect(function() api.buildClose.BackgroundTransparency=0 end)
 api.buildClose.SelectionLost:Connect(function() api.buildClose.BackgroundTransparency=1 end)
 api.grid=make("ScrollingFrame",{ScrollBarThickness=3,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,BorderSizePixel=0,Name="Choices",Position=UDim2.fromOffset(12,43),Size=UDim2.fromOffset(282,181),BackgroundTransparency=1,ZIndex=51,Parent=api.buildPop})
 make("UIGridLayout",{CellSize=UDim2.fromOffset(90,86),CellPadding=UDim2.fromOffset(6,7),SortOrder=Enum.SortOrder.LayoutOrder,Parent=api.grid})
 api.choices={}
 for i,a in ctx.actions do
  local b=button(api.grid,"Choose_"..a.kind,"",nil,90,86);b.LayoutOrder=i
  paint(b,C.raised)
  IconKit.image(IconKit.KIND[a.kind] or a.kind,{Size=UDim2.fromOffset(24,24),AnchorPoint=Vector2.new(.5,0),Position=UDim2.new(.5,0,0,11),ZIndex=56,Parent=b})
  local name=text(b,"Name",a.def.name,4,39,82,18,10);name.TextXAlignment=Enum.TextXAlignment.Center
  local cost=text(b,"Cost","",4,59,82,16,11,C.gold);cost.TextXAlignment=Enum.TextXAlignment.Center
  api.choices[i]={button=b,cost=cost,action=a}
  b.Activated:Connect(function()
   local mine=ctx.getMine();local gold=if mine then mine.stats.gold else 0
   if not ctx.usable(a,gold) then ctx.toast("Not enough gold, or the required structure is unavailable.","red",2);return end
   ctx.setMode({type=a.type,kind=a.kind});if game.Players.LocalPlayer.PlayerGui:GetAttribute("FrontlinesTutorial")~=true then ctx.toast(a.def.name.." selected. Choose a valid tile.",nil,2) end -- the tutorial bubble already says it
  end)
 end
 api.attacksPop=frame(root,"AttacksPopover",340,160);api.attacksPop.Visible=false
 text(api.attacksPop,"Heading","Active attacks",12,8,250,23,13)
 api.attackBody=make("Frame",{Position=UDim2.fromOffset(8,37),Size=UDim2.new(1,-16,1,-43),BackgroundTransparency=1,ZIndex=51,Parent=api.attacksPop})
 api.emptyAttacks=text(api.attacksPop,"Empty","No active attacks",13,49,290,23,12,C.muted)
 api.creditsButton=button(root,"Credits","WAR FRONT · Credits",nil,140,18)
 api.creditsButton.Caption.Text="WAR FRONT / CREDITS";api.creditsButton.Caption.TextSize=9
 api.creditsPop=frame(root,"CreditsPopover",320,100);api.creditsPop.Visible=false
 api.buildClose.Activated:Connect(function() api.close() end)
 function api.close()
  local was=api.open~=nil or api.boardOpen or api.attackOpen or api.creditsPop.Visible or (api.sidebar~=nil and (api.sidebar.boostsPanel.Visible or api.sidebar.speedPanel.Visible))
  api.open=nil;api.boardOpen=false;api.attackOpen=false;api.buildPop.Visible=false;api.attacksPop.Visible=false;api.creditsPop.Visible=false
  if api.refs then api.refs.board.Visible=false end
  if api.sidebar then require(script.Parent.BoostsPanel).collapse();api.sidebar.speedPanel.Visible=false end
  api.layout();return was
 end
 function api.toggleBoard()
  local nextOpen=not api.boardOpen;api.close();api.boardOpen=nextOpen;api.layout()
 end
 function api.openBuild(group)
  local closing=api.open==group;api.close();if closing then return end
  api.open=group;api.buildPop.Visible=true;api.buildHeading.Text=if group=="build" then "Construction" else "Military"
  for _,entry in api.choices do entry.button.Visible=(entry.action.type=="build")== (group=="build") end
  api.buildPop.Size=UDim2.fromOffset(306,if group=="build" then 236 else 236)
  api.layout()
  if UserInputService.GamepadEnabled then for _,entry in api.choices do if entry.button.Visible then GuiService.SelectedObject=entry.button;break end end end
 end
 function api.showAttacks()
  api.close();api.attackOpen=true;api.attacksPop.Visible=true;api.layout()
 end
 api.buildBtn.Activated:Connect(function() api.openBuild("build") end)
 api.militaryBtn.Activated:Connect(function() api.openBuild("military") end)
 api.boardBtn.Activated:Connect(api.toggleBoard)
 api.attackBtn.Activated:Connect(function() local on=not api.attackOpen;api.close();api.attackOpen=on;api.attacksPop.Visible=on;api.layout() end)
 api.settingsBtn.Activated:Connect(function() api.close();ctx.openMenu() end)
 api.menuBtn.Activated:Connect(function() api.close();ctx.openMenu() end)
 api.creditsButton.Activated:Connect(function() local on=not api.creditsPop.Visible;api.close();api.creditsPop.Visible=on;api.layout() end)
 local dragging=nil
 local function drag(input) local size=api.slider.AbsoluteSize.X;if size>0 then ctx.setRatio(math.clamp((input.Position.X-api.slider.AbsolutePosition.X)/size,.01,1)) end end
 api.slider.InputBegan:Connect(function(input)
  if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then dragging=input;drag(input) end
 end)
 UserInputService.InputChanged:Connect(function(input)
  if dragging and (input==dragging or input.UserInputType==Enum.UserInputType.MouseMovement) then drag(input) end
 end)
 UserInputService.InputEnded:Connect(function(input) if input==dragging or input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=nil end end)
 UserInputService.InputBegan:Connect(function(input,processed)
  if input.KeyCode==Enum.KeyCode.Escape or input.KeyCode==Enum.KeyCode.ButtonB then api.close()

  end
 end)
 function api.layout(refs)
  if refs then
   api.refs=refs
   if not api.themedLegacy then
    api.themedLegacy=true;skin(refs.board,C.panel,8);skin(refs.banner,C.panel,6)
    refs.bannerText.Font=Enum.Font.GothamBold
   end
  end
  local r=api.refs;if not r then return end
  local X,Y=ctx.gui.AbsoluteSize.X,ctx.gui.AbsoluteSize.Y;if X<2 then return end
  local user=ctx.device.userScale or 1;local s=math.min(user,math.max(.7,X/520),math.max(.65,(Y-100)/420));local phone=X<700*s
  local anyPop=api.open~=nil or api.boardOpen or api.attackOpen or api.creditsPop.Visible or (api.sidebar and (api.sidebar.boostsPanel.Visible or api.sidebar.speedPanel.Visible))
  api.focusLayout=Y<500 and anyPop
  root:SetAttribute("WFFocusLayout",api.focusLayout==true)
  api.resources.Visible=api.hasMine==true and not api.focusLayout
  api.attack.Visible=api.isAlive==true and not api.focusLayout
  api.commands.Visible=api.isAlive==true and not api.focusLayout
  local m=12;api.scale=s
  for _,v in {api.resources,api.round,api.utility,api.attack,api.commands,api.buildPop,api.attacksPop,api.creditsPop,api.creditsButton} do ctx.device.setScale(v,s) end
  local top=math.max(m,GuiService.TopbarInset.Max.Y+6)
  local soloControls=api.sidebar and (api.sidebar.speedBtn.Visible or api.sidebar.pauseBtn.Visible)
  local utilityHeight=80*s
  place(api.resources,m,top)
  place(api.utility,X-m-164*s,top)
  local roundTop=if phone and not api.focusLayout then top+124*s+8 else m
  place(api.round,X/2-93*s,roundTop)
  local infoWidth=math.min(520,X-24);local infoLeft=(X-infoWidth)/2;local infoRight=infoLeft+infoWidth
  local infoTop=roundTop+64*s+8
  if api.resources.Visible and infoLeft<m+230*s then infoTop=math.max(infoTop,top+124*s+8) end
  if infoRight>X-m-164*s then infoTop=math.max(infoTop,top+utilityHeight+8) end
  api.infoTop=infoTop;api.infoBottom=infoTop+96
  api.popupTop=math.max(top+utilityHeight+8,api.infoBottom+8)
  api.soloControls=soloControls==true
  api.creditsButton.Visible=not api.focusLayout
  local attackTop=Y-(if phone then 156 else 108)*s
  api.attackTop=attackTop
  local commandTop=Y-66*s
  place(api.attack,m,attackTop)
  place(api.commands,X-m-308*s,commandTop)
  api.lowerBottom=if api.focusLayout then Y-m else math.min(attackTop,commandTop)-8
  local popHeight=math.min(236,math.max(100,(api.lowerBottom-api.infoBottom-8)/s))
  api.buildPop.Size=UDim2.fromOffset(306,popHeight)
  api.grid.Size=UDim2.fromOffset(282,math.max(40,popHeight-54))
  place(api.buildPop,X-m-306*s,api.lowerBottom-popHeight*s)
  local attackHeight=math.min(160,math.max(84,(api.lowerBottom-api.popupTop)/s))
  api.attacksPop.Size=UDim2.fromOffset(340,attackHeight)
  place(api.attacksPop,X-m-340*s,api.popupTop)
  place(api.creditsButton,m,Y-22*s);place(api.creditsPop,m,api.lowerBottom-100*s)
  r.hud.Visible=false;r.hudHint.Visible=false;r.padHelp.Visible=false;r.barHint.Visible=false
  local il,it,ir,ib=ctx.device.insets(ctx.gui);r.backdrop.Position=UDim2.fromOffset(-il,-it);r.backdrop.Size=UDim2.new(1,il+ir,1,it+ib)
  r.board:SetAttribute("WFMaxRows",math.clamp(math.floor(((api.lowerBottom-api.popupTop)/s-72)/26),1,5))
  r.board.AnchorPoint=Vector2.new(1,0);r.board.Position=UDim2.new(1,-m,0,api.popupTop);ctx.device.setScale(r.board,math.min(s,(X-24)/math.max(1,r.boardWidth)))
  if r.setBoardOpen then r.setBoardOpen(true) end;r.board.Visible=root.Visible and api.boardOpen
  local attacks=r.stack:FindFirstChild("AttacksDisplay")
  if attacks then attacks.Parent=api.attackBody end
  r.stack.AnchorPoint=Vector2.new(0,1);r.stack.Position=UDim2.new(0,m,1,-(if phone then 162 else 114)*s);r.stack.Size=UDim2.fromOffset(math.min(390,(X-24)/s),280);ctx.device.setScale(r.stack,s)
  r.banner.AnchorPoint=Vector2.new(.5,0);r.banner.Position=UDim2.new(.5,0,0,api.infoTop);r.banner.Size=UDim2.fromOffset(math.min(420,X-24),30)
  r.feedFrame.AnchorPoint=Vector2.new(1,1);r.feedFrame.Position=UDim2.new(1,-m,1,-(if phone then 166 else 74)*s);ctx.device.setScale(r.feedFrame,math.min(s,(X-24)/420))
  r.zoomIn.AnchorPoint=Vector2.zero;r.zoomOut.AnchorPoint=Vector2.zero;r.zoomIn.Position=UDim2.fromOffset(X-m-78*s,commandTop-40*s);r.zoomOut.Position=UDim2.fromOffset(X-m-34*s,commandTop-40*s);r.zoomIn.Size=UDim2.fromOffset(34*s,34*s);r.zoomOut.Size=UDim2.fromOffset(34*s,34*s)
  r.zoomIn.Visible=ctx.device.state.input=="Touch" and not anyPop;r.zoomOut.Visible=r.zoomIn.Visible
  r.credits.Parent=api.creditsPop;r.credits.AnchorPoint=Vector2.zero;r.credits.Position=UDim2.fromOffset(12,10);r.credits.Size=UDim2.fromOffset(296,80);r.credits.TextSize=11;r.credits.Visible=true;r.credits.ZIndex=52
  if api.sidebar then api.sideStep(api.sidebar) end
  api.layoutAlerts()
 end
 function api.layoutAlerts()
  local r=api.refs;if not r then return end
  local X,Y=ctx.gui.AbsoluteSize.X,ctx.gui.AbsoluteSize.Y;local s=api.scale or 1
  -- Fixed left column above AttackControl; opening panels never moves the feed.
  local bottom=api.attackTop-8
  local top=(api.infoBottom or 180)+8
  local width=math.min(340*s,X-24)
  local height=math.min(240*s,math.max(0,bottom-top))
  r.feedFrame:SetAttribute("WFLayoutHidden",height<20)
  r.feedFrame.AnchorPoint=Vector2.new(0,1)
  r.feedFrame.Position=UDim2.fromOffset(12,bottom)
  r.feedFrame.Size=UDim2.fromOffset(width/s,height/s);ctx.device.setScale(r.feedFrame,s)
 end
 function api.sideStep(ui)
  api.sidebar=ui;ui.bar.Visible=false
  local soloControls = ui.speedBtn.Visible or ui.pauseBtn.Visible
  if api.refs and api.soloControls ~= soloControls then api.layout();return end
  if not api.adopted then
   api.adopted=true;ui.boosts.Parent=api.commands;ui.boosts.Name="Boosts";ui.boosts.AutomaticSize=Enum.AutomaticSize.None;skin(ui.boosts,C.panel,7)
   text(ui.boosts,"Caption","BOOSTS",31,0,54,42,12)
   local icon=ui.boosts:FindFirstChildWhichIsA("ImageLabel")
   if icon then icon.AnchorPoint=Vector2.new(0,.5);icon.Position=UDim2.new(0,9,.5,0);icon.Size=UDim2.fromOffset(18,18) end
   ui.speedBtn.Parent=api.utility;ui.pauseBtn.Parent=api.utility
   for _,v in {ui.speedBtn,ui.pauseBtn,ui.speedPanel,ui.boostsPanel} do skin(v,C.panel,7) end
   for _,v in ui.boostsPanel:GetDescendants() do if v:IsA("TextLabel") or v:IsA("TextButton") then v.Font=Enum.Font.GothamBold end end
   require(script.Parent.BoostsPanel).collapse()
  end
  if not api.development then
   ui.boosts.Parent=api.utility;ui.boosts.Visible=api.root.Visible
   place(ui.boosts,0,44,80,36)
   local caption=ui.boosts:FindFirstChild("Caption")
   if caption then caption.Text="BOOSTS";caption.TextSize=10;caption.Position=UDim2.fromOffset(28,0);caption.Size=UDim2.fromOffset(50,36)end
  else place(ui.boosts,217,0,91,42)end
  ui.boosts.ZIndex=55
  for _,v in ui.boosts:GetDescendants() do if v:IsA("GuiObject") then v.ZIndex=56 end end
  for _,b in {ui.speedBtn,ui.pauseBtn} do b.Size=UDim2.fromOffset(36,36) end
  -- A right-aligned second row keeps solo controls separate from match utilities.
  place(ui.speedBtn,84,44);place(ui.pauseBtn,126,44)
  local X,Y=ctx.gui.AbsoluteSize.X,ctx.gui.AbsoluteSize.Y;local s=api.scale or 1
  if ui.boostsPanel then ui.boostsPanel.AnchorPoint=Vector2.new(1,1);ui.boostsPanel.Position=UDim2.new(1,-12,0,api.lowerBottom or Y-80*s);ui.boostsPanel.Size=UDim2.fromOffset(320,math.min(232,math.max(80,((api.lowerBottom or Y-80*s)-(api.infoBottom or 180)-8)/s)));ctx.device.setScale(ui.boostsPanel,s) end
  local top=math.max(12,GuiService.TopbarInset.Max.Y+6)
  ctx.device.setScale(ui.speedPanel,s);ctx.device.setScale(ui.clocks,s);ui.clocks.AnchorPoint=Vector2.new(1,0)
  ui.speedPanel.AnchorPoint=Vector2.new(1,0);ui.speedPanel.Position=UDim2.new(1,-12,0,api.popupTop or top+88*s)
  ui.clocks.Position=UDim2.new(1,-12,0,(api.popupTop or top+88*s)+(if ui.speedPanel.Visible then ui.speedPanel.AbsoluteSize.Y+6 elseif api.attackOpen then api.attacksPop.AbsoluteSize.Y+6 elseif api.boardOpen and api.refs then api.refs.board.AbsoluteSize.Y+6 else 0))
  if ui.speedPanel.Visible then
   api.attackOpen=false;api.boardOpen=false;api.attacksPop.Visible=false
   if api.refs then api.refs.board.Visible=false end
  end
  if ui.boostsPanel.Visible then api.open=nil;api.buildPop.Visible=false;api.boardOpen=false;api.attackOpen=false;api.attacksPop.Visible=false;if api.refs then api.refs.board.Visible=false end end
  ui.clocks.Visible=Y>=500 and not (X<1100 and (api.open or api.boardOpen or api.attackOpen or api.creditsPop.Visible or ui.boostsPanel.Visible or ui.speedPanel.Visible))
  api.layoutAlerts()
  api.timer.Text=ui.timer.Text;api.timer.TextColor3=ui.timer.TextColor3
 end
 function api.update(mine,me,ph,ratio)
  local now=os.clock();if now-api.lastUpdate<.05 then return end;api.lastUpdate=now
  if Players.LocalPlayer.PlayerGui:GetAttribute("WFMatchModal") and (api.open or api.boardOpen or api.attackOpen or api.creditsPop.Visible or (api.sidebar and (api.sidebar.boostsPanel.Visible or api.sidebar.speedPanel.Visible))) then api.close() end
  local inGame=ph.phase=="Spawn" or ph.phase=="Play" or ph.phase=="Ended"
  root.Visible=inGame and Players.LocalPlayer.PlayerGui:GetAttribute("WFReplay")~=true
  local alive=mine and mine.stats.alive and (ph.phase=="Play" or ph.phase=="Ended")
  local presenceChanged=api.hasMine~=(mine~=nil) or api.isAlive~=(alive==true)
  api.hasMine=mine~=nil;api.isAlive=alive==true
  api.resources.Visible=api.hasMine and not api.focusLayout;api.attack.Visible=api.isAlive and not api.focusLayout;api.commands.Visible=api.isAlive and not api.focusLayout
  if not inGame then api.defaultBuildShown=false end
  if alive and ph.phase=="Play" and not api.defaultBuildShown then
   api.defaultBuildShown=true;api.openBuild("build")
  end
  if not alive and api.open then api.close() end
  local focus=ctx.gui.AbsoluteSize.Y<500 and (api.open~=nil or api.boardOpen or api.attackOpen or api.creditsPop.Visible or (api.sidebar and (api.sidebar.boostsPanel.Visible or api.sidebar.speedPanel.Visible)))
  if presenceChanged or (focus==true)~=(api.focusLayout==true) then api.layout() end
  api.round.Visible=inGame;api.map.Text=string.upper(ph.mapName or ph.map or ctx.getMap().name).." · "..string.upper(ph.mode or "Free for all")
  local fraction=tonumber(ph.winPercent) or Config.WIN_FRACTION
  if fraction>1 then fraction/=100 end
  api.goal.Text=string.format("GOAL %.0f%%",fraction*100)
  if mine then
   local st=mine.stats;api.name.Text=mine.name or Players.LocalPlayer.DisplayName
   local share=st.tiles/math.max(1,ctx.getMap().landTiles);api.share.Text=string.format("%.1f%% land",share*100)
   api.troops.Text=ctx.fmtTroops(st.troops);api.max.Text="/ "..ctx.fmtTroops(st.maxTroops);api.gold.Text=ctx.fmt(st.gold)
   local rate=if alive and ph.phase=="Play" then math.max(0,Config.troopGrowth(mine.kind,st.troops,math.max(1,st.maxTroops))/Config.TICK) else 0
   api.growth.Text="+"..ctx.fmtTroops(rate).."/s";api.capacity.Size=UDim2.fromScale(math.clamp(st.troops/math.max(1,st.maxTroops),0,1),1)
   api.progress.Size=UDim2.fromScale(math.clamp(share/math.max(.01,fraction),0,1),1)
   api.send.Text="Send "..ctx.fmtTroops(st.troops*ratio).." troops"
   for _,entry in api.choices do local usable=ctx.usable(entry.action,st.gold);entry.cost.Text=ctx.fmt(ctx.cost(entry.action));entry.cost.TextColor3=if usable then C.gold elseif (tonumber(st.gold) or 0)<(tonumber(ctx.cost(entry.action)) or 0) then C.red else C.muted;paint(entry.button,if usable then C.raised else C.panel) end
  end
  api.ratio.Text=string.format("%d%%",math.floor(ratio*100+.5));api.fill.Size=UDim2.fromScale(ratio,1);api.knob.Position=UDim2.fromScale(ratio,.5)
  local count=#(me.attacks or {})+#(me.boatList or {})+#(me.incoming or {})+#(me.boatsIn or {})
  api.attackCount.Text=tostring(count);api.attackCount.Visible=count>0
  api.emptyAttacks.Visible=count==0
  api.attacksPop.Visible=root.Visible and api.attackOpen
  if api.refs then api.refs.hud.Visible=false;api.refs.board.Visible=root.Visible and api.boardOpen end
 end
 -- Match shortcuts are consumed before map commands and Roblox's default player list.
 local function menuShortcut(_,state,input)
  if state~=Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
  if Players.LocalPlayer.PlayerGui:GetAttribute("WFMatchModal") or not root.Visible or UserInputService:GetFocusedTextBox() or KeybindData.capturing or GuiService.MenuIsOpen then return Enum.ContextActionResult.Pass end
  local pg=Players.LocalPlayer.PlayerGui
  local menu=pg:FindFirstChild("FrontlinesMenu")
  if menu and menu.Enabled and menu:FindFirstChild("Screen") and menu.Screen.Visible then return Enum.ContextActionResult.Pass end
  local pause=pg:FindFirstChild("FrontlinesPause")
  if pause then for _,v in pause:GetChildren() do if v:IsA("GuiObject") and v.Visible then return Enum.ContextActionResult.Pass end end end
  if input.KeyCode==Enum.KeyCode.Tab then api.toggleBoard()
  elseif (api.open or api.commands.Visible) and (input.KeyCode==Enum.KeyCode.LeftControl or input.KeyCode==Enum.KeyCode.RightControl) then
   if api.open then api.close() else api.openBuild("build") end
  elseif api.commands.Visible and input.KeyCode==Enum.KeyCode.M then api.openBuild("military")
  else return Enum.ContextActionResult.Pass end
  return Enum.ContextActionResult.Sink
 end
 ContextActionService:BindActionAtPriority("WFMatchMenus",menuShortcut,false,3001,Enum.KeyCode.Tab,Enum.KeyCode.LeftControl,Enum.KeyCode.RightControl,Enum.KeyCode.M)
 root.Destroying:Connect(function() ContextActionService:UnbindAction("WFMatchMenus") end)
 api.buildBtn.Caption.Text="BUILD";api.militaryBtn.Caption.Text="MILITARY"
 text(api.buildBtn,"Hotkey","CTRL",64,29,27,10,8,C.muted)
 text(api.militaryBtn,"Hotkey","M",89,29,12,10,8,C.muted)
 ctx.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() api.layout() end)
 ctx.device.Changed:Connect(function() api.layout() end)
 require(script.Parent:WaitForChild("InGameUI")).attach(api)
 return api
end
return CornerHud

