-- War Front match UI foundation. Copyright (C) 2026 Liam. AGPL-3.0-or-later.
local MenuStyle=require(script.Parent:WaitForChild("MenuStyle"))
local IconKit=require(script.Parent:WaitForChild("IconKit"))
local Skin={}
Skin.C={panel=Color3.fromRGB(5,22,40),raised=Color3.fromRGB(14,43,64),cyan=Color3.fromRGB(0,177,235),white=Color3.fromRGB(241,248,255),muted=Color3.fromRGB(155,184,219),gold=Color3.fromRGB(255,211,35),red=Color3.fromRGB(255,102,119),mint=Color3.fromRGB(102,223,181)}
local panels={HoverPanel=true,HeadsUpMessage=true,Toast=true,PlayerPanel=true,SendResource=true,EmojiTable=true,BuildMenu=true,QuickChat=true,RadialTooltip=true,BoostsPanel=true,BoostCard=true,Request=true,Events=true,Important=true,WinModal=true,DefeatCard=true,SpectatePill=true,DoomsdayClockPanel=true,OvertimePanel=true,BuildTip=true,Tutorial=true}
local modalNames={PlayerPanel=true,SendResource=true,EmojiTable=true,QuickChat=true,WinModal=true,DefeatCard=true}
local modalRefs=setmetatable({},{__mode="k"})
local savedMeta={}
local function shown(v)
 local p=v
 while p and p~=game.Players.LocalPlayer.PlayerGui do
  if p:IsA("GuiObject") and not p.Visible then return false end
  if p:IsA("ScreenGui") and not p.Enabled then return false end
  p=p.Parent
 end
 return p~=nil
end
local function blocking()
 local open=false
 for v in modalRefs do if v.Parent and shown(v) then open=true;break end end
 local pg=game.Players.LocalPlayer.PlayerGui
 pg:SetAttribute("WFMatchModal",open)
 for _,name in {"FrontlinesMeta","FrontlinesMenuButton"} do
  local g=pg:FindFirstChild(name)
  if g and g:IsA("ScreenGui") then
   if open then if savedMeta[g]==nil then savedMeta[g]=g.Enabled end;g.Enabled=false
   elseif savedMeta[g]~=nil then g.Enabled=savedMeta[g];savedMeta[g]=nil end
  end
 end
end
local function round(v,r)
 local c=v:FindFirstChildWhichIsA("UICorner")
 if not c then c=Instance.new("UICorner");c.Parent=v end
 c.CornerRadius=UDim.new(0,r)
end
local function paint(bg,color)
 for _,v in bg:GetChildren() do
  if v:IsA("ImageLabel") then v.ImageColor3=color
  elseif v:IsA("Frame") and v.ZIndex==0 then v.BackgroundColor3=color end
 end
end
function Skin.panel(v)
 if v:GetAttribute("WFPanelSkin") then return end
 v:SetAttribute("WFPanelSkin",true)
 if modalNames[v.Name] or v.Name=="MatchStats" then
  modalRefs[v]=true
  local a=v
  while a and a~=game.Players.LocalPlayer.PlayerGui do
   if a:IsA("GuiObject") then a:GetPropertyChangedSignal("Visible"):Connect(blocking) end
   a=a.Parent
  end
  v.Destroying:Connect(function() modalRefs[v]=nil;blocking() end);blocking()
  if v.Name=="WinModal" or v.Name=="DefeatCard" then
   v.ZIndex=math.max(2,v.ZIndex)
   local dim=Instance.new("Frame");dim.Name="ResultBackdrop";dim.Size=UDim2.fromScale(1,1);dim.BackgroundColor3=Color3.new();dim.BackgroundTransparency=.4;dim.BorderSizePixel=0;dim.Active=false;dim.ZIndex=math.max(1,v.ZIndex-1);dim.Visible=v.Visible;dim.Parent=v.Parent
   v:GetPropertyChangedSignal("Visible"):Connect(function() dim.Visible=v.Visible end)
  end
 end
 v.BackgroundColor3=Skin.C.panel;v.BackgroundTransparency=0
 if v.AutomaticSize==Enum.AutomaticSize.None and v:IsA("Frame") then
  MenuStyle.panel(v,Skin.C.panel,8)
 else
  round(v,5)
  local s=v:FindFirstChildWhichIsA("UIStroke") or Instance.new("UIStroke")
  s.Color=Skin.C.cyan;s.Transparency=.4;s.Thickness=1;s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border;s.Parent=v
 end
end
function Skin.decorate(v)
 if not v:IsA("GuiObject") then return end
 if v:GetAttribute("WFMatchStyled") then return end
 v:SetAttribute("WFMatchStyled",true)
 if v:IsA("TextLabel") or v:IsA("TextButton") or v:IsA("TextBox") then
  v.FontFace=Font.fromEnum(if v.TextSize>=24 then Enum.Font.GothamBlack else Enum.Font.GothamBold)
 end
 local c=v.BackgroundColor3
 if v.BackgroundTransparency<1 and math.max(c.R,c.G,c.B)<.48 then
  v.BackgroundColor3=if math.max(c.R,c.G,c.B)<.19 then Skin.C.panel else Skin.C.raised
 end
 task.defer(function()
  if not v.Parent then return end
  if panels[v.Name] then Skin.panel(v) end
  if v:IsA("TextButton") then
   if v.Name=="Close" or v.Text=="X" or v.Text=="✕" or v.Text=="×" then
    v.Text="";v.BackgroundTransparency=1;round(v,4)
    IconKit.image("Back",{Name="BackArrow",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(16,16),ImageColor3=Skin.C.muted,ZIndex=v.ZIndex+1,Parent=v})
   elseif not v.Name:find("Backdrop") and not v.Name:find("Dim") and not v.Name:find("Blocker") and not v.Name:find("Catcher") and not (v.Text=="" and v.Size.X.Scale==1 and v.Size.Y.Scale==1) and v.BackgroundTransparency<.7 and v.AutomaticSize==Enum.AutomaticSize.None and not v:FindFirstChild("AngularShape") then
    local fill=v.BackgroundColor3
    local bg=MenuStyle.panel(v,fill,5)
    if v.Text~="" then
     local caption=Instance.new("TextLabel");caption.Name="ActionCaption"
     caption.Size=UDim2.fromScale(1,1);caption.BackgroundTransparency=1;caption.ZIndex=v.ZIndex+3
     local hiding=false
     local function update()
      caption.Text=v.Text;caption.FontFace=v.FontFace;caption.TextSize=v.TextSize;caption.TextColor3=v.TextColor3
      caption.RichText=v.RichText;caption.TextWrapped=v.TextWrapped;caption.TextXAlignment=v.TextXAlignment;caption.TextYAlignment=v.TextYAlignment
     end
     caption.TextTransparency=v.TextTransparency;caption.Parent=v;update();v.TextTransparency=1
     for _,prop in {"Text","FontFace","TextSize","TextColor3","RichText"} do v:GetPropertyChangedSignal(prop):Connect(update) end
     v:GetPropertyChangedSignal("TextTransparency"):Connect(function()
      if hiding or v.TextTransparency==1 then return end
      caption.TextTransparency=v.TextTransparency;hiding=true;v.TextTransparency=1;hiding=false
     end)
    end
    v:GetPropertyChangedSignal("BackgroundColor3"):Connect(function() paint(bg,v.BackgroundColor3) end)
    local setting=false
    v:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
     if setting or v.BackgroundTransparency==1 then return end
     local alpha=v.BackgroundTransparency;setting=true;v.BackgroundTransparency=1
     for _,o in bg:GetChildren() do if o:IsA("ImageLabel") then o.ImageTransparency=alpha elseif o:IsA("Frame") and o.ZIndex==0 then o.BackgroundTransparency=alpha end end
     setting=false
    end)
   end
  end
 end)
end
function Skin.decorateTree(root)
 Skin.decorate(root)
 for _,v in root:GetDescendants() do Skin.decorate(v) end
end

-- Night look (owner approved the in-game Night mockups, 11 Oct 2026): the same panels with the main
-- menu's colours, fonts and rounded cards. Default; Workspace attribute WFNightMenu = false turns it off.
Skin.night=workspace:GetAttribute("WFNightMenu")~=false
if Skin.night then
 local Kit=require(script.Parent:WaitForChild("NightMenu"):WaitForChild("Kit"))
 local K,F=Kit.C,Kit.F
 Skin.Kit=Kit
 -- MenuKit rows (battle menu, settings): Night card / hover colours. Its hover recolours from these,
 -- so rows no longer go back to the old dark navy after the pointer leaves.
 local MenuKit=require(script.Parent:WaitForChild("MenuKit"))
 MenuKit.C.PANEL_ROW=K.CARD;MenuKit.C.PANEL_HI=K.RAISED
 -- Same keys as before, so every module that reads Skin.C gets the Night colours.
 Skin.C={panel=K.CARD,raised=K.RAISED,cyan=K.CYAN,white=K.TEXT,muted=K.MUTED,gold=K.YELLOW,red=K.PINK,mint=K.GREEN,
  page=K.PAGE,line=K.LINE,deep=K.DEEP,yellowText=K.YELLOW_TEXT,greenText=K.GREEN_TEXT}
 local function stroke(v,color,thickness)
  local s=v:FindFirstChildWhichIsA("UIStroke") or Instance.new("UIStroke")
  s.Color=color or K.LINE;s.Transparency=0;s.Thickness=thickness or 1.5;s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border;s.Parent=v
 end
 local function flat(v)
  for _,g in v:GetChildren() do if g:IsA("UIGradient") then g.Enabled=false end end
 end
 function Skin.panel(v)
  if v:GetAttribute("WFPanelSkin") then return end
  v:SetAttribute("WFPanelSkin",true)
  if modalNames[v.Name] or v.Name=="MatchStats" then
   modalRefs[v]=true
   local a=v
   while a and a~=game.Players.LocalPlayer.PlayerGui do
    if a:IsA("GuiObject") then a:GetPropertyChangedSignal("Visible"):Connect(blocking) end
    a=a.Parent
   end
   v.Destroying:Connect(function() modalRefs[v]=nil;blocking() end);blocking()
   if v.Name=="WinModal" or v.Name=="DefeatCard" then
    v.ZIndex=math.max(2,v.ZIndex)
    local dim=Instance.new("Frame");dim.Name="ResultBackdrop";dim.Size=UDim2.fromScale(1,1);dim.BackgroundColor3=K.BACKDROP;dim.BackgroundTransparency=.3;dim.BorderSizePixel=0;dim.Active=false;dim.ZIndex=math.max(1,v.ZIndex-1);dim.Visible=v.Visible;dim.Parent=v.Parent
    v:GetPropertyChangedSignal("Visible"):Connect(function() dim.Visible=v.Visible end)
   end
  end
  -- Big windows use the page colour, small panels the card colour (like the main menu).
  local big=modalNames[v.Name] or v.Name=="MatchStats" or v.Name=="PauseCard"
  v.BackgroundColor3=if big then K.PAGE else K.CARD;v.BackgroundTransparency=0
  round(v,if big then 16 else 12)
  stroke(v,if v.Name=="DefeatCard" then K.PINK elseif v.Name=="WinModal" then K.YELLOW else K.LINE,if big then 2 else 1.5)
  flat(v)
 end
 function Skin.decorate(v)
  if not v:IsA("GuiObject") then return end
  if v:GetAttribute("WFMatchStyled") then return end
  v:SetAttribute("WFMatchStyled",true)
  if v:IsA("TextLabel") or v:IsA("TextButton") or v:IsA("TextBox") then
   v.FontFace=if v.TextSize>=17 or v:IsA("TextButton") then F.TITLE else F.BOLD
  end
  local c=v.BackgroundColor3
  if v.BackgroundTransparency<1 and math.max(c.R,c.G,c.B)<.48 then
   v.BackgroundColor3=if math.max(c.R,c.G,c.B)<.19 then K.CARD else K.RAISED
  end
  task.defer(function()
   if not v.Parent then return end
   flat(v)
   if panels[v.Name] then Skin.panel(v) end
   if v:IsA("TextButton") then
    if v.Name=="Close" or v.Text=="X" or v.Text=="✕" or v.Text=="×" then
     v.Text="";v.BackgroundColor3=K.RAISED;v.BackgroundTransparency=0;round(v,999)
     Kit.icon("Close",{Name="BackArrow",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromScale(.55,.55),ImageColor3=K.TEXT,ZIndex=v.ZIndex+1,Parent=v})
    elseif not v.Name:find("Backdrop") and not v.Name:find("Dim") and not v.Name:find("Blocker") and not v.Name:find("Catcher") and not (v.Text=="" and v.Size.X.Scale==1 and v.Size.Y.Scale==1) and v.BackgroundTransparency<.7 then
     -- Rounded pill-ish buttons; the text stays on the button itself.
     round(v,if v.AbsoluteSize.Y>0 and v.AbsoluteSize.Y<=44 then 999 else 10)
    end
   end
  end)
 end
end
return Skin

