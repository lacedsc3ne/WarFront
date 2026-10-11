--[[
 War Front - clan presentation, using the existing ClanPages server actions.
 Copyright (C) 2026 Liam (lacedsc3ne). Licensed under GNU AGPL v3 or later.
 Based on OpenFront: © OpenFront and Contributors.
]]
local Kit=require(script.Parent:WaitForChild("MenuKit"))
local make=Kit.make
local View={}
local NAVY=Color3.fromRGB(5,22,40)
local BLUE=Color3.fromRGB(0,177,235)
local MUTED=Color3.fromRGB(155,184,219)
local TEAL=Color3.fromRGB(69,214,178)
local RED=Color3.fromRGB(225,74,91)
local BOLD=Font.fromEnum(Enum.Font.GothamBold)
local BLACK=Font.fromEnum(Enum.Font.GothamBlack)
local function rect(o,x,y,w,h) o.Position=UDim2.fromOffset(x,y);o.Size=UDim2.fromOffset(math.max(0,w),math.max(0,h)) end
local function text(p,n,s,size,c)
 return Kit.text({Name=n,Text=s,FontFace=BOLD,TextSize=size or 16,TextColor3=c or Color3.new(1,1,1),TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,Parent=p})
end
local function bind(o,fit)
 local conn=o:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
 o.Destroying:Connect(function() conn:Disconnect() end)
 fit();task.defer(function() if o.Parent then fit() end end)
end
function View.surface(p,name)
 local f=make("Frame",{Name=name,BackgroundColor3=NAVY,BackgroundTransparency=0,BorderSizePixel=0,Parent=p})
 Kit.corner(f,8);Kit.stroke(f,0.2,Color3.fromRGB(63,131,187),1.5)
 return f
end
function View.panel(p,order,name,gap)
 local f=View.surface(p,name)
 f.LayoutOrder=order;f.Size=UDim2.new(1,0,0,0);f.AutomaticSize=Enum.AutomaticSize.Y
 Kit.pad(f,16,16,14,14);Kit.list(f,false,gap or 8)
 return f
end
function View.action(b,style)
 b:SetAttribute("ClanStyled",true)
 local colour=if style=="danger" then RED elseif style=="accept" then TEAL elseif style=="medals" then Color3.fromRGB(255,158,40) elseif style=="secondary" then NAVY else BLUE
 b.FontFace=BOLD;b.AutoButtonColor=false;b.BackgroundColor3=colour
 b.TextTruncate=Enum.TextTruncate.AtEnd;b.TextWrapped=false
 b.BackgroundTransparency=0
 b.TextColor3=if style=="danger" then RED elseif style=="secondary" then Color3.new(1,1,1) else NAVY
 for _,c in b:GetChildren() do if c:IsA("UIGradient") then c:Destroy() end end
 local stroke=b:FindFirstChildWhichIsA("UIStroke") or Kit.stroke(b,0,colour,1)
 stroke.Color=if style=="secondary" then Color3.fromRGB(63,131,187) else colour;stroke.Transparency=0.12
 Kit.corner(b,6)
 if style~="danger" and style~="secondary" then make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(129,194,221)),Parent=b}) end
 return b
end
function View.button(p,name,caption,style)
 return View.action(Kit.button("secondary",{Name=name,Text=caption,FontFace=BOLD,TextSize=14,BorderSizePixel=0,Parent=p}),style)
end
local shieldImage
local function shield()
 if shieldImage then return shieldImage end
 local ok,img=pcall(function()
  local image=game:GetService("AssetService"):CreateEditableImage({Size=Vector2.new(80,96)})
  if not image then return end
  local pixels=buffer.create(80*96*4)
  for y=0,95 do for x=0,79 do
   local span=if y<60 then 35 else 35*(94-y)/34
   local top=8+math.abs(x-39.5)*0.16
   if y>=top and math.abs(x-39.5)<=span then buffer.writeu32(pixels,(y*80+x)*4,4294967295) end
  end end
  image:WritePixelsBuffer(Vector2.zero,image.Size,pixels);return image
 end)
 if ok then shieldImage=img end
 return shieldImage
end
function View.emblem(p,tag)
 local holder=make("Frame",{Name="ClanEmblem",BackgroundTransparency=1,Parent=p})
 local image=shield()
 if image then
  make("ImageLabel",{Name="ShieldBorder",BackgroundTransparency=1,ImageContent=Content.fromObject(image),ImageColor3=Color3.fromRGB(222,233,245),Size=UDim2.fromScale(1,1),Parent=holder})
  make("ImageLabel",{Name="ShieldFill",BackgroundTransparency=1,ImageContent=Content.fromObject(image),ImageColor3=Color3.fromRGB(27,63,89),Position=UDim2.fromScale(0.055,0.055),Size=UDim2.fromScale(0.89,0.86),Parent=holder})
 else holder.BackgroundColor3=NAVY;holder.BackgroundTransparency=0;Kit.corner(holder,8);Kit.stroke(holder,0.1,MUTED,2) end
 local mark=text(holder,"ShieldMark","★",32)
 mark.TextXAlignment=Enum.TextXAlignment.Center;mark.Position=UDim2.fromScale(0.1,0.16);mark.Size=UDim2.fromScale(0.8,0.6);mark.TextScaled=true
 return holder
end
local function input(p,name,placeholder,multi)
 local b=make("TextBox",{Name=name,Text="",PlaceholderText=placeholder,PlaceholderColor3=MUTED,TextColor3=Color3.new(1,1,1),FontFace=BOLD,TextSize=15,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=if multi then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,TextWrapped=multi or false,ClearTextOnFocus=false,BackgroundColor3=Color3.fromRGB(11,37,63),BorderSizePixel=0,Parent=p})
 Kit.corner(b,6);Kit.stroke(b,0.35,Color3.fromRGB(63,131,187),1);Kit.pad(b,12,12,if multi then 10 else 0,0)
 return b
end
function View.prepare(page)
 if page.clanLayout then return end
 local original=page.layout
 local selectTab=page.selectTab
 local tabLayout=page.tabBar:FindFirstChildWhichIsA("UIListLayout")
 local base={background=page.frame.BackgroundColor3,alpha=page.frame.BackgroundTransparency,clips=page.frame.ClipsDescendants,tabAlpha=page.tabBar.BackgroundTransparency}
 local function paint(self)
  for key,b in self.tabButtons do
   local on=self.active==key
   b.BackgroundTransparency=if on then 0 else 1;b.BackgroundColor3=BLUE
   b.TextColor3=if on then NAVY else MUTED;b.FontFace=BOLD;b.TextTransparency=0
   Kit.corner(b,6)
   local line=b:FindFirstChild("Underline");if line then line.Visible=false end
  end
 end
 page.selectTab=function(self,key) selectTab(self,key);if self.title.Text=="CLANS" then paint(self) end end
 page.layout=function(self,mobile)
  if self.clanWasShowing then
   self.header.Visible=true;self.title.Visible=true;self.back.Visible=true
   self.frame.BackgroundColor3=base.background;self.frame.BackgroundTransparency=base.alpha;self.frame.ClipsDescendants=base.clips
   self.tabBar.BackgroundTransparency=base.tabAlpha
   local border=self.tabBar:FindFirstChildWhichIsA("UIStroke");if border then border.Enabled=false end
  end
  if tabLayout then tabLayout.Parent=self.tabBar end
  original(self,mobile)
  self.clanWasShowing=self.title.Text=="CLANS"
  if not self.clanWasShowing then return end
  self.frame.BackgroundTransparency=1;self.frame.ClipsDescendants=false;self.border.Enabled=false
  self.header.Visible=false;self.title.Visible=false;self.back.Visible=false
  if tabLayout then tabLayout.Parent=nil end
  local w=self.frame.AbsoluteSize.X
  local nw=math.min(w,620);local h=if mobile then 44 else 52
  rect(self.tabBar,(w-nw)/2,0,nw,h)
  self.tabBar.BackgroundColor3=NAVY;self.tabBar.BackgroundTransparency=0
  local st=self.tabBar:FindFirstChildWhichIsA("UIStroke") or Kit.stroke(self.tabBar,0.2,Color3.fromRGB(63,131,187),1.5)
  st.Enabled=true;st.Color=Color3.fromRGB(63,131,187);st.Transparency=0.2;Kit.corner(self.tabBar,8)
  for j,t in self.tabs do local b=self.tabButtons[t.key];b.AutomaticSize=Enum.AutomaticSize.None;rect(b,(j-1)*nw/#self.tabs+4,4,nw/#self.tabs-8,h-8);b.TextSize=if mobile then 13 else 17;local pad=b:FindFirstChildWhichIsA("UIPadding");if pad then pad.PaddingLeft=UDim.new();pad.PaddingRight=UDim.new() end end
  paint(self)
  self.body.Position=UDim2.fromOffset(0,h+14);self.body.Size=UDim2.new(1,0,1,-h-22)
  self.body.BackgroundTransparency=1;self.body.ScrollingEnabled=true;self.body.Active=true;self.body.ClipsDescendants=true
  self.body.AutomaticCanvasSize=Enum.AutomaticSize.Y;self.body.ScrollBarThickness=6;self.body.ScrollBarImageColor3=BLUE
  self.bodyPad.PaddingLeft=UDim.new();self.bodyPad.PaddingRight=UDim.new(0,8);self.bodyPad.PaddingTop=UDim.new();self.bodyPad.PaddingBottom=UDim.new(0,8)
 end
 page.clanLayout=page.layout
end
function View.browse(page)
 local root=View.panel(page.body,1,"ClanBrowser",8)
 local searchRow=make("Frame",{Name="SearchRow",LayoutOrder=1,Size=UDim2.new(1,0,0,42),BackgroundTransparency=1,Parent=root})
 local search=input(searchRow,"ClanSearch","Search clans...",false)
 local filter=View.button(searchRow,"ClanFilter","ALL CLANS ▾","secondary")
 bind(searchRow,function() local w=searchRow.AbsoluteSize.X;local fw=if w<600 then 126 else 190;rect(search,0,0,w-fw-12,42);rect(filter,w-fw,0,fw,42) end)
 local list=make("Frame",{Name="ClanRows",LayoutOrder=2,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1,Parent=root});Kit.list(list,false,8)
 local pager=make("Frame",{Name="ClanPagination",LayoutOrder=3,Size=UDim2.new(1,0,0,40),BackgroundTransparency=1,Parent=root})
 local prev=View.button(pager,"PreviousPage","‹","secondary")
 local next=View.button(pager,"NextPage","›","secondary")
 local count=text(pager,"PageCount","1 / 1",16,BLUE);count.TextXAlignment=Enum.TextXAlignment.Center
 bind(pager,function() local w=pager.AbsoluteSize.X;rect(prev,w/2-106,2,42,36);rect(count,w/2-60,0,120,40);rect(next,w/2+64,2,42,36) end)
 return {root=root,search=search,filter=filter,list=list,prev=prev,next=next,count=count}
end
function View.browseRow(p,order,c,maxMembers,open)
 local row=View.surface(p,"ClanRow");row.LayoutOrder=order;row.Size=UDim2.new(1,0,0,86)
 local emblem=View.emblem(row,c.t)
 local title=text(row,"ClanName",tostring(c.n),18)
 local tag=text(row,"ClanTag","["..tostring(c.t).."]",14,BLUE)
 local members=text(row,"Members",tostring(c.m).." / "..tostring(maxMembers),15)
 local wins=text(row,"Wins",tostring(c.w).." wins",14,MUTED)
 local state=text(row,"JoinPolicy",if c.o then "OPEN" else "BY REQUEST",11,if c.o then TEAL else MUTED);state.TextXAlignment=Enum.TextXAlignment.Center
 state.BackgroundColor3=if c.o then Color3.fromRGB(9,49,49) else Color3.fromRGB(17,47,74);state.BackgroundTransparency=0;Kit.corner(state,5)
 local view=View.button(row,"ViewClan","VIEW");view.Activated:Connect(open)
 bind(row,function()
  local w=row.AbsoluteSize.X;local small=w<680;local h=if small then 118 else 86;row.Size=UDim2.new(1,0,0,h)
  rect(emblem,12,12,46,58);rect(title,72,12,if small then w-184 else w*0.40-82,26);rect(tag,72,40,if small then w-184 else w*0.40-82,20)
  rect(members,if small then 12 else w*0.43,if small then 80 else 16,if small then (w-136)/2 else 94,22);rect(wins,if small then 18+(w-136)/2 else w*0.43,if small then 80 else 46,if small then (w-136)/2 else 104,20)
  rect(state,if small then w-112 else w-238,if small then 74 else 28,100,26);rect(view,w-104,16,92,40)
 end)
 return row
end
function View.clanStatus(parent,order,get,set)
 local row=make("Frame",{Name="ClanStatus",LayoutOrder=order,BackgroundTransparency=1,Size=UDim2.new(1,0,0,68),Parent=parent})
 local title=text(row,"StatusLabel","Clan status",16)
 local button=make("TextButton",{Name="StatusToggle",Text="",FontFace=BOLD,TextSize=16,AutoButtonColor=false,BackgroundTransparency=0,BorderSizePixel=0,TextColor3=NAVY,Parent=row})
 Kit.corner(button,8);local stroke=Kit.stroke(button,0.15,TEAL,1.5)
 make("UIGradient",{Rotation=90,Color=ColorSequence.new(Color3.new(1,1,1),Color3.fromRGB(195,211,231)),Parent=button})
 local function refresh()
  local open=get()
  button.Text=if open then "Open (1/2)" else "Closed (2/2)"
  button.BackgroundColor3=if open then Color3.fromRGB(46,209,125) else Color3.fromRGB(246,70,89)
  stroke.Color=button.BackgroundColor3:Lerp(Color3.new(1,1,1),0.4)
 end
 button.Activated:Connect(function() set(not get());refresh() end)
 bind(row,function()
  local w=row.AbsoluteSize.X
  row.Size=UDim2.new(1,0,0,84)
  rect(title,0,0,w,24)
  rect(button,0,32,math.min(172,w),40)
 end)
 refresh()
 return row
end
function View.create(page,me,player)
 local root=View.surface(page.body,"CreateClanForm");root.LayoutOrder=1;root.Size=UDim2.new(1,0,0,440)
 local left=make("Frame",{Name="CreateFields",BackgroundTransparency=1,Parent=root})
 local labels={text(left,"NameLabel","Clan name",16),text(left,"TagLabel","Clan tag",16),text(left,"DescriptionLabel","Description",16)}
 local name=input(left,"ClanName","Clan name",false);local tag=input(left,"ClanTag","Clan tag",false);local desc=input(left,"ClanDescription","Description (optional)",true)
 local tips={text(left,"NameHelp","3–24 characters",12,MUTED),text(left,"TagHelp","2–5 letters or numbers",12,MUTED),text(left,"DescriptionHelp","Up to 120 characters",12,MUTED)}
 local toggle=make("Frame",{Name="OpenClanRow",BackgroundTransparency=1,Parent=left})
 local preview=View.surface(root,"LivePreview")
 local pt=text(preview,"PreviewHeading","LIVE PREVIEW",15,MUTED);pt.TextXAlignment=Enum.TextXAlignment.Center
 local emblem=View.emblem(preview,"")
 local clanName=text(preview,"PreviewClan","YOUR CLAN",20);clanName.TextXAlignment=Enum.TextXAlignment.Center
 local avatar=make("ImageLabel",{Name="PlayerAvatar",Image="rbxthumb://type=AvatarHeadShot&id="..player.UserId.."&w=100&h=100",BackgroundTransparency=1,Parent=preview});Kit.round(avatar)
 local matchName=text(preview,"MatchName",player.DisplayName,14);matchName.TextXAlignment=Enum.TextXAlignment.Center
 local actions=make("Frame",{Name="CreateActions",BackgroundTransparency=1,Parent=root})
 local status=text(root,"CreateStatus","",14,Color3.fromRGB(255,190,83));status.TextWrapped=true
 local function fit()
  local w=root.AbsoluteSize.X;local phone=w<700;local lw=if phone then w-32 else (w-64)*0.57;local rw=if phone then w-32 else w-lw-48
  local leftH=390
  rect(left,16,16,lw,leftH)
  for j,y in {0,86,172} do rect(labels[j],0,y,lw,24);rect(tips[j],0,y+(if j==3 then 100 else 62),lw,20) end
  rect(name,0,26,lw,34);rect(tag,0,112,lw,34);rect(desc,0,198,lw,70);rect(toggle,0,306,lw,84)
  local previewY=if phone then leftH+32 else 16
  rect(preview,if phone then 16 else lw+32,previewY,rw,if phone then 250 else leftH)
  local ph=preview.Size.Y.Offset;rect(pt,12,12,rw-24,28)
  local ew=if phone then 72 else 112;local eh=if phone then 86 else 134
  rect(emblem,(rw-ew)/2,44,ew,eh);rect(clanName,12,ph-108,rw-24,30);rect(avatar,(rw-36)/2,ph-74,36,36);rect(matchName,12,ph-36,rw-24,26)
  local ay=if phone then previewY+268 else leftH+32
  local buttons={} for _,c in actions:GetChildren() do if c:IsA("TextButton") then table.insert(buttons,c) end end
  local stacked=w<550
  local ah=if stacked then math.max(1,#buttons)*56-12 else 44
  rect(actions,16,ay,w-32,ah);rect(status,16,ay+ah+8,w-32,40);root.Size=UDim2.new(1,0,0,ay+ah+60)
  local bw=if stacked then w-32 else (w-32-math.max(0,#buttons-1)*12)/math.max(1,#buttons)
  for j,c in buttons do rect(c,if stacked then 0 else (j-1)*(bw+12),if stacked then (j-1)*56 else 0,bw,44);c.TextSize=if bw<210 then 12 else 15;View.action(c,if c.Text:find("MEDALS",1,true) then "medals" else "secondary") end
 end
 actions.ChildAdded:Connect(function() task.defer(function() if root.Parent then fit() end end) end)
 bind(root,fit)
 return {root=root,name=name,tag=tag,desc=desc,toggle=toggle,matchName=matchName,actions=actions,status=status,update=function(n,t) clanName.Text=if n~="" then n else "YOUR CLAN";matchName.Text=if t~="" then "["..t.."] "..player.DisplayName else player.DisplayName end}
end
function View.summary(page,clan,order)
 local head=View.surface(page.body,"ClanSummary");head.LayoutOrder=order;head.Size=UDim2.new(1,0,0,126)
 local emblem=View.emblem(head,clan.tag)
 local name=text(head,"ClanName",string.upper(clan.name),23)
 local tag=text(head,"ClanTag","["..clan.tag.."]",15,BLUE)
 local desc=text(head,"ClanDescription",clan.desc or "",13,MUTED)
 local stats=text(head,"ClanStats",#clan.members.." / "..clan.max.." MEMBERS   •   "..clan.wins.." WINS",15)
 local policy=text(head,"JoinPolicy",if clan.role then "MEMBER" elseif clan.open then "OPEN" else "BY REQUEST",12,if clan.role or clan.open then TEAL else MUTED)
 policy.BackgroundColor3=Color3.fromRGB(9,49,49);policy.BackgroundTransparency=0;policy.TextXAlignment=Enum.TextXAlignment.Center;Kit.corner(policy,5)
 local actions=make("Frame",{Name="ClanActions",BackgroundTransparency=1,Parent=head});Kit.list(actions,true,8,{HorizontalAlignment=Enum.HorizontalAlignment.Right})
 bind(head,function()
  local w=head.AbsoluteSize.X;local phone=w<800;local narrow=w<400;head.Size=UDim2.new(1,0,0,if narrow then 244 elseif phone then 194 else 126)
  rect(emblem,16,16,60,80);rect(name,92,16,if phone then w-112 else w*0.48-92,30);rect(tag,92,49,if phone then w-112 else w*0.48-92,22);rect(desc,92,77,if phone then w-112 else w*0.46-92,26)
  rect(stats,if phone then 16 else w*0.5,if phone then 112 else 18,if phone then w-32 else w*0.5-24,26)
  rect(policy,if phone then 16 else w*0.5,if phone then 148 else 68,130,32)
  rect(actions,if narrow then 16 elseif phone then 158 else w-222,if narrow then 192 elseif phone then 144 else 64,if narrow then w-32 elseif phone then w-174 else 206,40)
 end)
 return head,actions
end
function View.sections(page,names,active,onSelect)
 local nav=View.surface(page.body,"ClanSections");nav.LayoutOrder=2;nav.Size=UDim2.new(1,0,0,48)
 local buttons={}
 for j,t in names do local b=View.button(nav,t.key,t.label,if active==t.key then nil else "secondary");buttons[j]=b;b.Activated:Connect(function() onSelect(t.key) end) end
 bind(nav,function() local w=nav.AbsoluteSize.X;for j,b in buttons do rect(b,(j-1)*w/#buttons+5,5,w/#buttons-10,38);b.TextSize=if w<600 then 12 else 15 end end)
 return nav
end
function View.memberRow(parent,m,isSelf,role,colour)
 local inner=make("Frame",{Name="MemberRow",BackgroundTransparency=1,Size=UDim2.new(1,0,0,64),Parent=parent})
 local avatar=make("ImageLabel",{Name="MemberAvatar",Image="rbxthumb://type=AvatarHeadShot&id="..m.u.."&w=100&h=100",BackgroundTransparency=1,Parent=inner});Kit.round(avatar)
 local name=text(inner,"MemberName",tostring(m.n)..(if isSelf then " (you)" else ""),16)
 local label=text(inner,"MemberRole",role,12,colour)
 local actions=make("Frame",{Name="MemberActions",BackgroundTransparency=1,Parent=inner});Kit.list(actions,true,6,{HorizontalAlignment=Enum.HorizontalAlignment.Right})
 local function fit()
  local w=inner.AbsoluteSize.X;local aw=0;local count=0;local buttons={}
  for _,c in actions:GetChildren() do if c:IsA("TextButton") then
   local natural=c:GetAttribute("ClanBaseWidth") or c.Size.X.Offset;c:SetAttribute("ClanBaseWidth",natural);aw+=natural;count+=1;table.insert(buttons,c)
  end end
  local available=math.max(0,w-math.max(0,count-1)*6)
  for _,c in buttons do c.Size=UDim2.fromOffset(math.floor(c:GetAttribute("ClanBaseWidth")*math.min(1,available/math.max(1,aw))),32) end
  aw=math.min(aw,available)+math.max(0,count-1)*6;local small=w<800
  inner.Size=UDim2.new(1,0,0,if small and count>0 then 102 else 64)
  rect(avatar,0,8,44,44);rect(name,58,8,if small then w-160 else w-aw-184,28)
  rect(label,if small then w-100 else w-aw-110,18,94,24)
  rect(actions,w-aw,if small then 66 else 16,aw,32)
 end
 actions.ChildAdded:Connect(function() task.defer(function() if inner.Parent then fit() end end) end);bind(inner,fit)
 return actions
end
function View.requestRow(parent,r)
 local inner=make("Frame",{Name="RequestRow",Size=UDim2.new(1,0,0,64),BackgroundTransparency=1,Parent=parent})
 local avatar=make("ImageLabel",{Name="RequestAvatar",Image="rbxthumb://type=AvatarHeadShot&id="..r.u.."&w=100&h=100",BackgroundTransparency=1,Parent=inner});Kit.round(avatar)
 local name=text(inner,"RequestName",tostring(r.n),16)
 local hint=text(inner,"RequestHint","Wants to join your clan.",12,MUTED)
 local accept=View.button(inner,"AcceptRequest","ACCEPT","accept")
 local decline=View.button(inner,"DeclineRequest","DECLINE","danger")
 bind(inner,function() local w=inner.AbsoluteSize.X;local small=w<600;inner.Size=UDim2.new(1,0,0,if small then 104 else 64);rect(avatar,0,8,44,44);rect(name,58,7,w-(if small then 64 else 298),25);rect(hint,58,32,w-(if small then 64 else 298),22);local bw=if small then math.min(104,(w-12)/2) else 104;rect(accept,w-2*bw-12,if small then 66 else 16,bw,32);rect(decline,w-bw,if small then 66 else 16,bw,32) end)
 return accept,decline
end
function View.decorate(root)
 for _,o in root:GetDescendants() do
  if o:IsA("TextButton") and o.Text~="" and not o:GetAttribute("ClanStyled") then
   local caption=o.Text
   View.action(o,if caption=="KICK" or caption=="DISBAND" or caption=="LEAVE CLAN" or caption=="DECLINE" then "danger" elseif caption=="ACCEPT" then "accept" elseif caption=="PROMOTE" or caption=="DEMOTE" or caption=="MAKE LEADER" then "secondary" else nil)
   o:SetAttribute("ClanStyled",true)
  elseif o:IsA("TextBox") then o.BackgroundColor3=Color3.fromRGB(11,37,63);o.BackgroundTransparency=0;o.FontFace=BOLD
  end
 end
end
return View
