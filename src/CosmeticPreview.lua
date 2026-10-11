-- War Front cosmetic prototypes. Original artwork and animation code.
-- Test-experience-only presentation; no equip, purchases, remotes or profile writes.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local AssetService = game:GetService("AssetService")
if game.GameId ~= 10769671248 or workspace:GetAttribute("WFEnableCosmeticTesting") ~= true then return end
local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")
local C = { ink=Color3.fromRGB(3,20,37), panel=Color3.fromRGB(6,27,47), row=Color3.fromRGB(12,39,62), cyan=Color3.fromRGB(0,177,235), white=Color3.fromRGB(238,247,255), muted=Color3.fromRGB(158,187,211), gold=Color3.fromRGB(255,207,65) }
local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local BOLD = Font.fromEnum(Enum.Font.GothamBold)
local function make(class, props)
 local v=Instance.new(class)
 for k,value in props do if k~="Parent" then v[k]=value end end
 v.Parent=props.Parent
 return v
end
local function corner(v,r) make("UICorner",{CornerRadius=UDim.new(0,r or 8),Parent=v}) end
local function border(v,color,alpha) return make("UIStroke",{Color=color or C.cyan,Transparency=alpha or .55,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Parent=v}) end
local function text(parent,name,value,size,color)
 return make("TextLabel",{Name=name,Text=value,TextSize=size,FontFace=FONT,TextColor3=color or C.white,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,BackgroundTransparency=1,Parent=parent})
end
local function button(parent,name,value)
 local b=make("TextButton",{Name=name,Text=value,FontFace=BOLD,TextSize=14,TextColor3=C.white,BackgroundColor3=C.row,BorderSizePixel=0,AutoButtonColor=false,Parent=parent})
 corner(b,6);border(b,C.cyan,.7)
 b.MouseEnter:Connect(function() b.BackgroundColor3=Color3.fromRGB(18,55,82) end)
 b.MouseLeave:Connect(function() b.BackgroundColor3=C.row end)
 return b
end
local styles={
 {name="Aurora",tag="DRIFTING LIGHT",desc="Soft green and violet lights drift across deep blue territory.",colors={Color3.fromRGB(18,48,89),Color3.fromRGB(61,213,178),Color3.fromRGB(147,98,227)}},
 {name="Obsidian",tag="GOLD VEINS",desc="Dark stone with fine gold cracks that glow in slow pulses.",colors={Color3.fromRGB(31,31,43),Color3.fromRGB(239,188,59),Color3.fromRGB(86,65,43)}},
 {name="Radar",tag="TACTICAL SWEEP",desc="A subtle grid and a moving cyan radar sweep over navy territory.",colors={Color3.fromRGB(14,43,66),Color3.fromRGB(26,180,188),Color3.fromRGB(74,222,227)}}
}
local selected=1
local motion=true
local speed=1
local time=0
local gui=make("ScreenGui",{Name="WarFrontCosmeticPreview",IgnoreGuiInset=true,ResetOnSpawn=false,DisplayOrder=85,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,Parent=pg})
local launch=button(gui,"OpenCosmeticPreview","COSMETIC PREVIEW")
launch.AnchorPoint=Vector2.new(0,1);launch.Position=UDim2.new(0,24,1,-20);launch.Size=UDim2.fromOffset(184,38)
local shade=make("Frame",{Name="Overlay",Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(0,0,0),BackgroundTransparency=.25,BorderSizePixel=0,Active=true,Visible=false,Parent=gui})
local panel=make("Frame",{Name="PreviewWindow",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(1020,650),BackgroundColor3=C.ink,BorderSizePixel=0,Active=true,Parent=shade})
corner(panel,10);border(panel,C.cyan,.2)
local panelScale=make("UIScale",{Parent=panel})
local title=text(panel,"Title","TERRITORY COLLECTION",24);title.FontFace=BOLD
local subtitle=text(panel,"Subtitle","Three animated prototypes. Try each style before it reaches the shop.",13,C.muted)
local close=button(panel,"Close","X")
local collection=make("Frame",{Name="Collection",BackgroundTransparency=1,Parent=panel})
local cards={}
for i,s in styles do
 local b=button(collection,s.name,s.name:upper())
 b.Text="";cards[i]=b
 local stripe=make("Frame",{Name="Palette",BackgroundColor3=s.colors[1],BorderSizePixel=0,Parent=b});corner(stripe,5)
 make("UIGradient",{Color=ColorSequence.new({ColorSequenceKeypoint.new(0,s.colors[1]),ColorSequenceKeypoint.new(.5,s.colors[2]),ColorSequenceKeypoint.new(1,s.colors[3])}),Rotation=30,Parent=stripe})
 local name=text(b,"Name",s.name:upper(),18);name.FontFace=BOLD
 local tag=text(b,"Tag",s.tag,10,C.muted)
 b:SetAttribute("StyleIndex",i)
end
local preview=make("Frame",{Name="MapPreview",BackgroundColor3=C.panel,ClipsDescendants=true,BorderSizePixel=0,Parent=panel});corner(preview,8);border(preview,C.cyan,.65)
local mapImage=make("ImageLabel",{Name="TerritoryArtwork",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,ScaleType=Enum.ScaleType.Fit,Parent=preview})
local stamp=text(preview,"PreviewStamp","TERRITORY PREVIEW",10,C.muted);stamp.Position=UDim2.fromOffset(16,12);stamp.Size=UDim2.fromOffset(220,20)
local nation=text(preview,"PlayerName",player.DisplayName,19);nation.FontFace=BOLD;nation.TextXAlignment=Enum.TextXAlignment.Center;nation.TextStrokeColor3=C.ink;nation.TextStrokeTransparency=.12;nation.AnchorPoint=Vector2.new(.5,.5);nation.Position=UDim2.fromScale(.5,.53);nation.Size=UDim2.new(.6,0,0,28);nation.TextTruncate=Enum.TextTruncate.AtEnd;nation.TextWrapped=false
local army=text(preview,"Army","72.4K",12,C.white);army.AnchorPoint=Vector2.new(.5,.5);army.Position=UDim2.fromScale(.5,.53);army.Size=UDim2.new(.3,0,0,22);army.TextXAlignment=Enum.TextXAlignment.Center;army.Position=UDim2.new(.5,0,.53,24);army.TextStrokeTransparency=.2;army.TextStrokeColor3=C.ink
local detailTitle=text(panel,"SelectedName","",21);detailTitle.FontFace=BOLD
local detail=text(panel,"Description","",14,C.muted)
local note=text(panel,"PreviewOnly","PREVIEW ONLY  /  No purchases or equipment changes",11,C.cyan)
local pause=button(panel,"ToggleAnimation","ANIMATION: ON")
local speedButton=button(panel,"AnimationSpeed","SPEED: 1x")
local equip=button(panel,"EquipTerritory","EQUIP FOR TEST")
local restore=button(panel,"RestoreTerritory","NORMAL COLOUR")
local function equippedLabel()
 local name=pg:GetAttribute("WFTestTerritoryStyle")
 equip.Text=if name==styles[selected].name then "EQUIPPED" else "EQUIP FOR TEST"
 note.Text=if name then "TEST EQUIPPED: "..string.upper(name).."  /  Visible only to you; not saved" else "PREVIEW ONLY  /  No purchases or equipment changes"
end
equip.Activated:Connect(function() pg:SetAttribute("WFTestTerritoryStyle",styles[selected].name);equippedLabel() end)
restore.Activated:Connect(function() pg:SetAttribute("WFTestTerritoryStyle",nil);equippedLabel() end)
local fallback=text(preview,"Unavailable","",16,C.muted);fallback.Size=UDim2.new(1,-32,0,50);fallback.Position=UDim2.new(0,16,1,-60);fallback.Visible=false

-- Hand-drawn fictional coastlines. All pixel geometry is authored here.
local W,H=256,160
local polygons={
 {{9,52},{31,24},{70,20},{88,39},{73,68},{54,81},{42,117},{20,108},{25,80}},
 {{66,31},{105,19},{120,37},{151,25},{177,43},{188,63},{171,82},{179,110},{155,131},{127,124},{109,140},{80,126},{84,107},{63,94},{78,76},{65,59}},
 {{181,17},{207,27},{220,48},{246,64},{234,97},{213,113},{188,102},{200,79},{189,61},{195,39}},
 {{22,135},{35,128},{47,140},{33,152}},{{204,132},{221,129},{231,143},{211,151}}
}
local ownersForPolygon={2,1,3,2,3}
local function inside(poly,x,y)
 local hit=false;local last=#poly
 for i,p in poly do
  local q=poly[last]
  if (p[2]>y)~=(q[2]>y) and x<(q[1]-p[1])*(y-p[2])/(q[2]-p[2])+p[1] then hit=not hit end
  last=i
 end
 return hit
end
local owners=table.create(W*H,0)
for y=0,H-1 do for x=0,W-1 do
 for i,p in polygons do if inside(p,x+.5,y+.5) then owners[y*W+x+1]=ownersForPolygon[i];break end end
end end
local base=buffer.create(W*H*4)
local pixels=buffer.create(W*H*4)
local animated={}
local function put(b,at,r,g,bl)
 buffer.writeu8(b,at,math.clamp(math.floor(r+.5),0,255));buffer.writeu8(b,at+1,math.clamp(math.floor(g+.5),0,255));buffer.writeu8(b,at+2,math.clamp(math.floor(bl+.5),0,255));buffer.writeu8(b,at+3,255)
end
for y=0,H-1 do for x=0,W-1 do
 local id=owners[y*W+x+1];local at=(y*W+x)*4
 local edge=false
 if id>0 then for _,d in {{-1,0},{1,0},{0,-1},{0,1}} do local nx,ny=x+d[1],y+d[2];if nx<0 or ny<0 or nx>=W or ny>=H or owners[ny*W+nx+1]~=id then edge=true;break end end end
 local noise=((x*17+y*31)%13)/13
 if edge then put(base,at,149,206,225)
 elseif id==1 then
  put(base,at,18,48,89)
  local u,v=x/W,y/H;local dx,dy=u-.5,v-.53
  animated[#animated+1]={at=at,u=u,v=v,noise=noise,radius=math.sqrt(dx*dx+dy*dy),angle=math.atan2(dy,dx),vein=math.min(math.abs(math.sin(u*41+math.sin(v*23)*1.8)),math.abs(math.sin(v*37+math.sin(u*19)*1.7))),grid=math.min(math.abs((u*16)%1-.5),math.abs((v*16)%1-.5))}
 elseif id==2 then put(base,at,38+noise*5,87+noise*7,105+noise*7)
 elseif id==3 then put(base,at,155+noise*9,128+noise*7,83+noise*7)
 else put(base,at,5+noise*2,29+noise*2,49+noise*3) end
end end
local ok,editable=pcall(function() return AssetService:CreateEditableImage({Size=Vector2.new(W,H)}) end)
if ok and editable then
 mapImage.ImageContent=Content.fromObject(editable)
else
 editable=nil;fallback.Visible=true;fallback.Text="Animated artwork is unavailable on this device. You can still compare the palettes."
end
local function render()
 if not editable then return end
 buffer.copy(pixels,0,base)
 for _,p in animated do
  local u,v=p.u,p.v;local r,g,b
  if selected==1 then
   local band=((math.sin(u*12+v*10+math.sin(u*9+time*.24)*1.8-time*.55)+1)*.5)^5
   local violet=(math.sin(u*7+time*.18)+1)*.5
   r=18+band*(24+violet*79);g=47+band*(146-violet*76);b=87+band*(78+violet*39)
  elseif selected==2 then
   local glow=if p.vein<.055 then .45+.55*(math.sin(time*.75+u*11+v*6)+1)*.5 else 0
   r=26+p.noise*7+glow*186;g=27+p.noise*6+glow*132;b=36+p.noise*7+glow*23
  else
   local delta=(p.angle-time*.65)%(math.pi*2)
   local beam=math.exp(-delta*3.5)*math.clamp(1-p.radius/.38,0,1)
   local grid=if p.grid<.035 then 1 else 0
   local ring=if math.abs((p.radius*16)%1-.5)<.025 then 1 else 0
   r=12+beam*17;g=41+grid*14+ring*12+beam*106;b=64+grid*15+ring*13+beam*115
  end
  put(pixels,p.at,r,g,b)
 end
 editable:WritePixelsBuffer(Vector2.zero,Vector2.new(W,H),pixels)
end
local function choose(i)
 selected=i;detailTitle.Text=styles[i].name:upper();detail.Text=styles[i].desc
 equippedLabel()
 for j,b in cards do local stroke=b:FindFirstChildWhichIsA("UIStroke");stroke.Color=if i==j then C.cyan else C.muted;stroke.Transparency=if i==j then .05 else .8;b.BackgroundColor3=if i==j then Color3.fromRGB(15,53,79) else C.row end
 render()
end
for i,b in cards do b.Activated:Connect(function() choose(i) end) end
pause.Activated:Connect(function() motion=not motion;pause.Text=if motion then "ANIMATION: ON" else "ANIMATION: PAUSED" end)
speedButton.Activated:Connect(function() speed=if speed==1 then .5 elseif speed==.5 then 1.5 else 1;speedButton.Text="SPEED: "..speed.."x" end)
local function layout()
 local sz=gui.AbsoluteSize;if sz.X<2 then return end
 local scale=math.min(1,math.max(1,sz.Y-24)/420,math.max(1,sz.X-24)/340)
 panelScale.Scale=scale
 local w,h=math.min(1020,(sz.X-24)/scale),math.min(650,(sz.Y-24)/scale)
 panel.Size=UDim2.fromOffset(w,h)
 local compact=w<720;local pad=if w<450 then 14 else 24
 title.Position=UDim2.fromOffset(pad,18);title.Size=UDim2.fromOffset(w-2*pad-48,32);title.TextSize=if compact then 18 else 24
 subtitle.Position=UDim2.fromOffset(pad,53);subtitle.Size=UDim2.fromOffset(w-2*pad,36)
 close.Position=UDim2.fromOffset(w-pad-36,18);close.Size=UDim2.fromOffset(36,32)
 local mapY=if compact then 172 else 102
 local detailY=h-(if compact then 185 else 143);local mapH=math.max(80,detailY-mapY-16)
 if compact then
  collection.Position=UDim2.fromOffset(pad,102);collection.Size=UDim2.fromOffset(w-2*pad,56)
  local cw=(w-2*pad-16)/3
  for i,b in cards do b.Position=UDim2.fromOffset((i-1)*(cw+8),0);b.Size=UDim2.fromOffset(cw,56);b.Palette.Position=UDim2.fromOffset(8,10);b.Palette.Size=UDim2.fromOffset(5,36);b:FindFirstChild("Name").Position=UDim2.fromOffset(20,7);b:FindFirstChild("Name").Size=UDim2.new(1,-24,0,24);b:FindFirstChild("Name").TextSize=if w<450 then 12 else 16;b.Tag.Visible=w>=450;b.Tag.Position=UDim2.fromOffset(20,30);b.Tag.Size=UDim2.new(1,-24,0,18) end
  preview.Position=UDim2.fromOffset(pad,mapY);preview.Size=UDim2.fromOffset(w-2*pad,mapH)
 else
  collection.Position=UDim2.fromOffset(pad,102);collection.Size=UDim2.fromOffset(210,300)
  for i,b in cards do b.Position=UDim2.fromOffset(0,(i-1)*96);b.Size=UDim2.fromOffset(210,82);b.Palette.Position=UDim2.fromOffset(12,14);b.Palette.Size=UDim2.fromOffset(38,54);b:FindFirstChild("Name").Position=UDim2.fromOffset(62,17);b:FindFirstChild("Name").Size=UDim2.fromOffset(142,25);b:FindFirstChild("Name").TextSize=18;b.Tag.Visible=true;b.Tag.Position=UDim2.fromOffset(62,44);b.Tag.Size=UDim2.fromOffset(140,20) end
  preview.Position=UDim2.fromOffset(258,mapY);preview.Size=UDim2.fromOffset(w-258-pad,mapH)
 end
 detailTitle.Position=UDim2.fromOffset(pad,detailY);detailTitle.Size=UDim2.fromOffset(w-2*pad,25)
 detail.Position=UDim2.fromOffset(pad,detailY+29);detail.Size=UDim2.fromOffset(w-2*pad,36)
 pause.Position=UDim2.fromOffset(pad,h-(if compact then 108 else 66));pause.Size=UDim2.fromOffset(if w<450 then 164 else 182,34)
 speedButton.Position=UDim2.fromOffset(pad+(if w<450 then 172 else 194),h-(if compact then 108 else 66));speedButton.Size=UDim2.fromOffset(110,34)
 equip.Position=UDim2.fromOffset(if compact then pad else pad+318,h-66);equip.Size=UDim2.fromOffset(148,34)
 restore.Position=UDim2.fromOffset(if compact then pad+156 else pad+478,h-66);restore.Size=UDim2.fromOffset(136,34)
 note.Position=UDim2.fromOffset(pad,h-26);note.Size=UDim2.fromOffset(w-2*pad,18);note.TextSize=if w<450 then 9 else 11
end
local function setOpen(open)
 shade.Visible=open
 if open then layout();render() end
end
launch.Activated:Connect(function() setOpen(true) end)
close.Activated:Connect(function() setOpen(false) end)
local function menuChanged()
 local menu=pg:GetAttribute("FrontlinesMenuOpen")==true
 launch.Visible=menu
 if not menu then setOpen(false) end
end
local inputConnection=UserInputService.InputBegan:Connect(function(input,processed)
 if processed or UserInputService:GetFocusedTextBox() then return end
 if input.KeyCode==Enum.KeyCode.F8 then setOpen(not shade.Visible)
 elseif shade.Visible and (input.KeyCode==Enum.KeyCode.Escape or input.KeyCode==Enum.KeyCode.ButtonB) then setOpen(false) end
end)
local elapsed=0
local renderConnection=RunService.RenderStepped:Connect(function(dt)
 if not shade.Visible or not motion then return end
 time+=math.min(dt,.1)*speed;elapsed+=dt
 if elapsed>=.125 then elapsed=0;render() end
end)
local sizeConnection=gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
local menuConnection=pg:GetAttributeChangedSignal("FrontlinesMenuOpen"):Connect(menuChanged)
gui.Destroying:Connect(function() inputConnection:Disconnect();renderConnection:Disconnect();sizeConnection:Disconnect();menuConnection:Disconnect();if editable then editable:Destroy() end end)
choose(1);layout();menuChanged()

