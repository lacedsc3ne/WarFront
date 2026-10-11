-- War Front independent engine test client. Copyright (C) 2026 Liam (lacedsc3ne).
-- GNU AGPL v3 or later. Separate test surface; never edits the existing UI.
local RunService=game:GetService("RunService")
if not RunService:IsStudio() or workspace:GetAttribute("WFIndependentEngineTest")~=true then return end
local Players=game:GetService("Players")
local Replicated=game:GetService("ReplicatedStorage")
local Input=game:GetService("UserInputService")
local AssetService=game:GetService("AssetService")
local remote=Replicated:WaitForChild("WFOwnEngineNet")
local gui=Instance.new("ScreenGui");gui.Name="WFOwnEngineTestUI";gui.DisplayOrder=1000;gui.IgnoreGuiInset=true;gui.ResetOnSpawn=false;gui.Parent=Players.LocalPlayer.PlayerGui
local function make(class,props,parent)
 local obj=Instance.new(class);for k,v in props do obj[k]=v end;obj.Parent=parent;return obj
end
local root=make("Frame",{Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.fromRGB(14,25,36),BorderSizePixel=0},gui)
local info=make("TextLabel",{Position=UDim2.fromOffset(14,10),Size=UDim2.new(1,-28,0,30),BackgroundTransparency=1,TextColor3=Color3.new(1,1,1),TextXAlignment=Enum.TextXAlignment.Left,TextSize=17,Text="Independent War Front engine test"},root)
local message=make("TextLabel",{Position=UDim2.fromOffset(14,43),Size=UDim2.new(1,-28,0,25),BackgroundTransparency=1,TextColor3=Color3.fromRGB(245,217,135),TextXAlignment=Enum.TextXAlignment.Left,TextSize=14,Text="Choose empty land to spawn. Use the toolbar, then click a tile."},root)
local toolbar=make("ScrollingFrame",{Position=UDim2.fromOffset(12,74),Size=UDim2.new(1,-24,0,50),BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.fromOffset(1680,0),ScrollBarThickness=4},root)
local view=make("ImageButton",{Position=UDim2.fromOffset(14,134),Size=UDim2.new(1,-28,1,-178),BackgroundColor3=Color3.fromRGB(3,34,69),BorderSizePixel=0,AutoButtonColor=false,ScaleType=Enum.ScaleType.Fit},root)
local status=make("TextLabel",{Position=UDim2.new(0,14,1,-35),Size=UDim2.new(1,-28,0,28),BackgroundTransparency=1,TextColor3=Color3.fromRGB(170,186,195),TextSize=13,TextXAlignment=Enum.TextXAlignment.Left,Text=""},root)
local mode="attack";local selectedKind=nil;local map=nil;local image=nil;local owners=nil;local colours={};local myId=0;local phase="Spawn";local session=0;local currentMap="Europe";local compact=false;local dirty=false;local states=nil;local palette=nil
local buttons=0
local function button(label,callback)
 local b=make("TextButton",{Position=UDim2.fromOffset(buttons*102,0),Size=UDim2.fromOffset(96,38),BackgroundColor3=Color3.fromRGB(39,57,69),BorderSizePixel=0,TextColor3=Color3.new(1,1,1),TextSize=14,Text=label},toolbar)
 buttons+=1;b.Activated:Connect(callback);return b
end
local function select(action,kind) mode=action;selectedKind=kind;message.Text="Selected: "..(kind or action).." — click the map" end
button("Attack",function() select("attack") end)
local labels={DefensePost="Defence",MissileSilo="Silo",SAMLauncher="SAM"}
for _,kind in {"City","Port","DefensePost","Factory","MissileSilo","SAMLauncher"} do button(labels[kind] or kind,function() select("build",kind) end) end
button("Transport",function() select("transport") end)
button("Warship",function() select("warship") end)
button("Atom bomb",function() select("missile","AtomBomb") end)
button("Start",function() remote:FireServer("start") end)
button("Compact",function() remote:FireServer("map",currentMap,not compact) end)
local mapNames={"Europe","NorthAmerica","Africa","UnitedStates","Alps","Britannia","Italia","World"};local mapIndex=1
button("Next map",function() mapIndex=mapIndex%#mapNames+1;remote:FireServer("map",mapNames[mapIndex],compact) end)
button("Close test",function() gui.Enabled=false end)
local function pixels()
 if not image or not map or not owners then return end
 local buf=buffer.create(map.width*map.height*4)
 for t=0,map.width*map.height-1 do
  local owner=buffer.readu16(owners,t*2);local byte=buffer.readu8(map.terrain,t)
  local value=palette.pixelAt(byte,t%map.width,t//map.width,map.width,map.height)
  if owner~=0 then
   local color=colours[owner] or 0xffffff
   local r,g,b=bit32.band(color,255),bit32.band(bit32.rshift(color,8),255),bit32.band(bit32.rshift(color,16),255)
   value=r+g*256+b*65536+255*16777216
  end
  buffer.writeu32(buf,t*4,value)
 end
 if states then
  for _,s in states.structures do
   local x,y=s.tile%map.width,s.tile//map.width
   for yy=math.max(0,y-1),math.min(map.height-1,y+1) do for xx=math.max(0,x-1),math.min(map.width-1,x+1) do buffer.writeu32(buf,(yy*map.width+xx)*4,0xffe4eafa) end end
  end
  for _,u in states.units do if u.tile>=0 and u.tile<map.width*map.height then buffer.writeu32(buf,u.tile*4,0xffffffff) end end
 end
 image:WritePixelsBuffer(Vector2.zero,Vector2.new(map.width,map.height),buf);dirty=false
end
remote.OnClientEvent:Connect(function(kind,data)
 if kind=="map" then
  session=data.session;currentMap=data.id;compact=data.compact
  local def=require(Replicated.Shared.Maps[data.id]);local raw=game:GetService("EncodingService"):Base64Decode(buffer.fromstring(def.data))
  if compact then
   local small=buffer.create(data.width*data.height)
   for y=0,data.height-1 do for x=0,data.width-1 do
    local wet,depth=0,0
    for dy=0,1 do for dx=0,1 do local b=buffer.readu8(raw,(y*2+dy)*def.width+x*2+dx);if b<128 then wet+=1;depth+=bit32.band(b,31) end end end
    buffer.writeu8(small,y*data.width+x,if wet>2 then 32+math.min(31,math.max(1,math.floor(depth/wet/2))) else 128)
   end end
   raw=small
  end
  map={width=data.width,height=data.height,terrain=raw};owners=buffer.create(data.width*data.height*2)
  palette=require(Replicated.Shared.MapStyles).palette(data.id)
  if image then image:Destroy() end
  image=AssetService:CreateEditableImage({Size=Vector2.new(data.width,data.height)})
  view.ImageContent=Content.fromObject(image);dirty=true
 elseif kind=="snapshot" and data.session==session then buffer.copy(owners,data.offset,data.data);dirty=data.done
 elseif kind=="delta" and data.session==session then
  for offset=0,buffer.len(data.data)-1,6 do local tile=buffer.readu32(data.data,offset);buffer.writeu16(owners,tile*2,buffer.readu16(data.data,offset+4)) end;dirty=true
 elseif kind=="state" and data.session==session then
  states=data;myId=data.myId or 0;phase=data.phase
  local mine=nil
  for _,p in data.players do colours[p.id]=p.color;if p.id==myId then mine=p end end
  info.Text="Independent engine · "..currentMap..(if compact then " · compact" else "").." · "..phase
  status.Text=if mine then string.format("Land %d   Troops %d   Gold %d   Time %.1f s",mine.tiles,mine.troops,mine.gold,data.time) else "Waiting"
  dirty=true
 elseif kind=="result" then message.Text=data.message
 elseif kind=="event" and data.kind=="water" and map then buffer.writeu8(map.terrain,data.data.tile,33);dirty=true
 end
end)
local function tileAt(position)
 if not map then return nil end
 local size=view.AbsoluteSize;local scale=math.min(size.X/map.width,size.Y/map.height)
 local origin=view.AbsolutePosition+(size-Vector2.new(map.width,map.height)*scale)/2
 local x,y=math.floor((position.X-origin.X)/scale),math.floor((position.Y-origin.Y)/scale)
 if x>=0 and y>=0 and x<map.width and y<map.height then return y*map.width+x end
 return nil
end
view.InputBegan:Connect(function(input)
 if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch then return end
 local tile=tileAt(Vector2.new(input.Position.X,input.Position.Y));if not tile then return end
 if phase=="Spawn" then remote:FireServer("spawn",tile)
 elseif mode=="attack" or mode=="transport" then remote:FireServer(mode,tile,0.3)
 elseif mode=="warship" then remote:FireServer(mode,tile)
 else remote:FireServer(mode,tile,selectedKind) end
end)
local last=0
RunService.Heartbeat:Connect(function() if dirty and gui.Enabled and os.clock()-last>=0.2 then last=os.clock();pixels() end end)
remote:FireServer("ready")
