-- Custom lobby waiting bar. LobbyPages owns the existing network actions.
local Kit=require(script.Parent:WaitForChild("MenuKit"))
local Config=require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Settings=require(script.Parent:WaitForChild("Settings"))
local TweenService=game:GetService("TweenService")
local C,F,make=Kit.C,Kit.F,Kit.make
local Bar={}
local ctx,ui,data=nil,{},nil
local editing,starting,teleporting,revealed=false,false,false,false
local settingsSignature=""
local regions={
 World={0,0,800,400,"rbxassetid://131085760210363"},NorthAmerica={0,0,704,608,"rbxassetid://127645978925542"},Britannia={0,0,480,640,"rbxassetid://89887823831230"},
 Europe={0,0,704,640,"rbxassetid://83361553562776"},Africa={0,0,640,608,"rbxassetid://121858660429391"},
 UnitedStates={0,0,704,392,"rbxassetid://127821727590057"},Alps={0,0,704,448,"rbxassetid://72288144375553"},Italia={0,0,544,640,"rbxassetid://90980522725639"},
}
local function rect(o,x,y,w,h)
 o.Position=UDim2.fromOffset(x,y);o.Size=UDim2.fromOffset(math.max(0,w),math.max(0,h))
end
local function label(name,size,colour)
 return Kit.text({Name=name,Text="",FontFace=F.BOLD,TextSize=size,TextColor3=colour or C.WHITE,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=3,Parent=ui.root})
end
local function shape()
 local w,h,cut=1024,240,40
 local img=game:GetService("AssetService"):CreateEditableImage({Size=Vector2.new(w,h)})
 if not img then return nil end
 local pixels=buffer.create(w*h*4)
 for y=0,h-1 do
  local left=cut*(1-y/(h-1));local right=w-1-cut*y/(h-1)
  for x=math.ceil(left),math.floor(right) do
   local edge=math.min(y,h-1-y,(x-left)/1.05,(right-x)/1.05)
   local colour=if edge<2 then C.MALIBU else Color3.fromRGB(5,22,40)
   local o=(y*w+x)*4
   buffer.writeu8(pixels,o,math.round(colour.R*255));buffer.writeu8(pixels,o+1,math.round(colour.G*255));buffer.writeu8(pixels,o+2,math.round(colour.B*255));buffer.writeu8(pixels,o+3,255)
  end
 end
 img:WritePixelsBuffer(Vector2.zero,img.Size,pixels)
 return img
end
local function action(name,text,colour,callback)
 local b=make("TextButton",{Name=name,Text=text,FontFace=F.BOLD,TextSize=13,TextColor3=C.WHITE,AutoButtonColor=false,BackgroundColor3=colour,BackgroundTransparency=0,BorderSizePixel=0,ZIndex=4,Parent=ui.root})
 Kit.corner(b,6);Kit.stroke(b,0.2,colour:Lerp(C.WHITE,0.35),1)
 make("UIGradient",{Rotation=90,Color=ColorSequence.new(C.WHITE,Color3.fromRGB(190,209,230)),Parent=b})
 Kit.hover(b,function(state) b.BackgroundColor3=if state=="idle" then colour else colour:Lerp(C.WHITE,0.08);b.BackgroundTransparency=0 end)
 b.Activated:Connect(callback)
 return b
end
local function layout()
 if not ui.root then return end
 local scale=ctx.parent:FindFirstChildWhichIsA("UIScale")
 local w=math.min(1120,math.max(280,ctx.parent.AbsoluteSize.X/(if scale then scale.Scale else 1)-32))
 local st=require(script.Parent.DeviceLayout).state
 local mobile=st.touch and (st.profile=="phone" or st.profile=="tablet")
 if mobile then
  local portrait=w<500;local h=if portrait then 204 else 156
  ui.root.Size=UDim2.fromOffset(w,h)
  rect(ui.map,12,12,50,50)
  local infoW=if portrait then w-86 else w*.42-86
  rect(ui.mapName,74,10,infoW,26);ui.mapName.TextSize=14
  rect(ui.id,74,36,infoW,24);ui.id.TextSize=12
  rect(ui.count,12,68,if portrait then w-24 else w*.42-24,24);ui.count.TextSize=17
  rect(ui.status,12,94,if portrait then w-24 else w*.42-24,20)
  local settingsX=if portrait then 12 else w*.42
  local settingsY=if portrait then 120 else 12
  local settingsW=w-settingsX-12
  rect(ui.settingsTitle,settingsX,settingsY,settingsW,18)
  rect(ui.settings,settingsX,settingsY+20,settingsW,if portrait then 24 else 72)
  local buttons=if data and data.isHost then {ui.start,ui.edit,ui.invite,ui.leave} else {ui.invite,ui.leave}
  for _,b in {ui.start,ui.edit,ui.invite,ui.leave} do b.Visible=table.find(buttons,b)~=nil end
  local bw=(w-24-(#buttons-1)*6)/#buttons
  for i,b in buttons do rect(b,12+(i-1)*(bw+6),h-40,bw,30);b.TextSize=if bw<100 then 10 else 12 end
  ui.id.Text=if data then "LOBBY ID: "..(if Settings.values.hiddenLobbyIds and not revealed then "••••••" else tostring(data.code)) else ""
  ui.root.Visible=data~=nil and not editing
  return
 end
 local phone=w<900;local h=if phone then 326 else 210
 ui.root.Size=UDim2.fromOffset(w,h)
 local pad=math.max(18,w*0.045)
 local actionW=if phone then 118 else 146
 local actionX=w-pad-actionW
 local mapW=if phone then 70 else 138
 rect(ui.map,pad,18,mapW,if phone then 78 else 138)
 local infoX=pad+mapW+14
 local infoW=if phone then actionX-infoX-10 else math.clamp(w*0.19,145,212)
 rect(ui.mapName,infoX,18,infoW,if phone then 38 else 28);ui.mapName.TextSize=if w<440 then 12 elseif phone then 14 else 18
 rect(ui.id,infoX,if phone then 60 else 52,infoW,26);ui.id.TextSize=if phone then 12 else 15
 rect(ui.count,if phone then pad else infoX,if phone then 104 else 90,if phone then actionX-pad-10 else infoW,30);ui.count.TextSize=if phone then 18 else 24
 rect(ui.status,if phone then pad else infoX,if phone then 138 else 130,if phone then actionX-pad-10 else infoW,22)
 local settingsX=if phone then pad else infoX+infoW+18
 local settingsY=if phone then 196 else 18
 local settingsW=if phone then w-2*pad else actionX-settingsX-18
 rect(ui.settingsTitle,settingsX,settingsY,settingsW,22)
 rect(ui.settings,settingsX,settingsY+26,settingsW,h-settingsY-42)
 local y=18
 local buttons=if data and data.isHost then {ui.start,ui.edit,ui.invite,ui.leave} else {ui.invite,ui.leave}
 for _,b in {ui.start,ui.edit,ui.invite,ui.leave} do b.Visible=table.find(buttons,b)~=nil end
 for _,b in buttons do rect(b,actionX,y,actionW,34);y+=43 end
 ui.id.Text=if data then "LOBBY ID: "..(if Settings.values.hiddenLobbyIds and not revealed then "••••••" else tostring(data.code)) else ""
 ui.root.Visible=data~=nil and not editing
end
local function drawSettings(lines)
 local signature=table.concat(lines,"\n")
 if signature==settingsSignature then return end
 settingsSignature=signature
 for _,child in ui.settings:GetChildren() do if child:IsA("TextLabel") then child:Destroy() end end
 for i,line in lines do
  local t=Kit.text({Name="Setting"..i,LayoutOrder=i,Text="• "..line,FontFace=F.MEDIUM,TextSize=12,TextColor3=Color3.fromRGB(186,207,229),TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,TextWrapped=true,AutomaticSize=Enum.AutomaticSize.Y,Size=UDim2.new(1,-8,0,18),ZIndex=3,Parent=ui.settings})
 end
end
function Bar.setup(c)
 ctx=c
 ui.root=make("Frame",{Name="CustomLobbyBar",AnchorPoint=Vector2.new(0.5,1),Position=UDim2.new(0.5,0,1,-18),Size=UDim2.fromOffset(1120,210),BackgroundTransparency=1,Visible=false,ZIndex=20,Parent=c.parent})
 local bg=make("ImageLabel",{Name="Shape",BackgroundTransparency=1,Size=UDim2.fromScale(1,1),ZIndex=1,Parent=ui.root})
 local ok,img=pcall(shape)
 if ok and img then ui.shape=img;bg.ImageContent=Content.fromObject(img)
 else bg.BackgroundTransparency=0;bg.BackgroundColor3=Color3.fromRGB(5,22,40);Kit.stroke(bg,0,C.MALIBU,1.5) end
 ui.map=make("ImageLabel",{Name="Map",BackgroundTransparency=1,ScaleType=Enum.ScaleType.Fit,ZIndex=3,Parent=ui.root})
 ui.mapName=label("MapName",18);ui.mapName.TextWrapped=true
 ui.id=make("TextButton",{Name="LobbyId",Text="",FontFace=F.BOLD,TextSize=15,TextColor3=C.MALIBU,TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,AutoButtonColor=false,ZIndex=4,Parent=ui.root})
 ui.id.Activated:Connect(function() revealed=not revealed;layout() end)
 ui.count=label("PlayerCount",24)
 ui.status=label("Status",12,Color3.fromRGB(161,186,213));ui.status.TextWrapped=true
 ui.settingsTitle=label("SettingsHeading",12,C.MALIBU);ui.settingsTitle.Text="LOBBY SETTINGS"
 ui.settings=make("ScrollingFrame",{Name="Settings",BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=4,ScrollBarImageColor3=C.MALIBU,AutomaticCanvasSize=Enum.AutomaticSize.Y,CanvasSize=UDim2.new(),ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=3,Parent=ui.root})
 Kit.list(ui.settings,false,4)
 ui.start=action("StartGame","START GAME",Color3.fromRGB(24,166,99),function()
  if not data or not data.isHost or starting or teleporting then return end
  starting=true;ui.start.Text="STARTING...";ui.status.Text="Starting game..."
  ctx.start()
 end)
 ui.edit=action("EditSettings","EDIT SETTINGS",Color3.fromRGB(0,141,207),function() if not starting and not teleporting then ctx.edit() end end)
 ui.invite=action("InviteFriends","INVITE FRIENDS",Color3.fromRGB(29,62,91),function() if not teleporting then ctx.invite() end end)
 ui.leave=action("LeaveLobby","LEAVE LOBBY",Color3.fromRGB(222,62,78),function() if not teleporting then ctx.leave() end end)
 ctx.parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
 layout()
end
function Bar.show(lobby,mapName,lines)
 local new=data==nil or data.code~=lobby.code
 data=lobby
 if new then revealed=false;starting=false;teleporting=false end
 ui.mapName.Text=mapName
 ui.count.Text=tostring(#(lobby.members or {})).." / "..tostring(Config.PRIVATE_MAX_PLAYERS).." PLAYERS"
 ui.status.Text=if teleporting then "Teleporting..." elseif starting then "Starting game..." elseif lobby.isHost then "Ready when you are" else "Waiting for the host..."
 ui.start.Text=if starting then "STARTING..." else "START GAME"
 local region=regions[lobby.settings and lobby.settings.map]
 ui.map.Visible=region~=nil
 if region then
  ui.map.Image=region[5] or "rbxassetid://123526786397636"
  ui.map.ImageRectOffset=Vector2.new(region[1],region[2]);ui.map.ImageRectSize=Vector2.new(region[3],region[4])
 end
 drawSettings(lines)
 layout()
 if new then
  ui.root.Position=UDim2.new(0.5,0,1,ui.root.Size.Y.Offset+12)
  TweenService:Create(ui.root,TweenInfo.new(0.24,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Position=UDim2.new(0.5,0,1,-18)}):Play()
 end
 if ctx.changed then ctx.changed() end
end
function Bar.setEditing(value)
 editing=value==true;layout()
 if ctx and ctx.changed then ctx.changed() end
end
function Bar.teleport()
 teleporting=true;ui.status.Text="Teleporting..."
end
function Bar.retry()
 starting=false;teleporting=false
 if ui.start then ui.start.Text="START GAME";ui.status.Text="Ready when you are" end
end
function Bar.clear()
 data=nil;editing=false;starting=false;teleporting=false;revealed=false;settingsSignature=""
 if ui.root then ui.root.Visible=false end
 if ctx and ctx.changed then ctx.changed() end
end
function Bar.active() return data~=nil end
function Bar.teleporting() return teleporting end
function Bar.height() return if data and not editing and ui.root then ui.root.Size.Y.Offset+30 else 0 end
return Bar
