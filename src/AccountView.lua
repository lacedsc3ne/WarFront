-- Account presentation. Name validation/filtering stays in the existing NameInput controller.
local Kit=require(script.Parent:WaitForChild("MenuKit"))
local Players=game:GetService("Players")
local C,F,make=Kit.C,Kit.F,Kit.make
local View={}
function View.render(page,ctx)
 local player=Players.LocalPlayer
 local controller=ctx.nameController and ctx.nameController()
 local identity=Kit.card(page.body,1,16,16,8);identity.Name="AccountIdentity"
 local head=make("Frame",{Name="Identity",BackgroundTransparency=1,Size=UDim2.new(1,0,0,70),Parent=identity})
 local avatar=make("ImageLabel",{Name="Avatar",Image="rbxthumb://type=AvatarHeadShot&id="..player.UserId.."&w=150&h=150",BackgroundColor3=C.PANEL,BackgroundTransparency=0,BorderSizePixel=0,Size=UDim2.fromOffset(64,64),Parent=head})
 Kit.corner(avatar,8);Kit.stroke(avatar,0.2,C.AQUARIUS,1)
 local name=Kit.text({Name="DisplayName",Text=if controller then controller.get() else player.DisplayName,FontFace=F.BOLD,TextSize=22,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,Position=UDim2.fromOffset(80,4),Size=UDim2.new(1,-80,0,30),Parent=head})
 local tag=Kit.text({Name="RobloxAccount",Text="",TextSize=14,TextColor3=Color3.fromRGB(155,184,219),TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,Position=UDim2.fromOffset(80,40),Size=UDim2.new(1,-80,0,22),Parent=head})
 local function showTag()
  local clan=player.PlayerGui:GetAttribute("WFClanTag")
  tag.Text="@"..player.Name..(if type(clan)=="string" and clan~="" then "  ·  ["..clan.."]" else "")
 end
 showTag()
 local tagConn=player.PlayerGui:GetAttributeChangedSignal("WFClanTag"):Connect(showTag)
 identity.Destroying:Connect(function() tagConn:Disconnect() end)
 local card=Kit.card(page.body,2,16,16,10);card.Name="NameCustomisation"
 Kit.paragraph(card,1,"IN-GAME NAME",{FontFace=F.BOLD,TextSize=16,TextColor3=C.AQUARIUS})
 Kit.paragraph(card,2,"Choose the name players see in War Front.",{TextSize=14,TextColor3=Color3.fromRGB(186,207,229)})
 local row=make("Frame",{Name="NameEditor",LayoutOrder=3,BackgroundTransparency=1,Size=UDim2.new(1,0,0,48),Parent=card})
 local box=make("TextBox",{Name="CustomName",Text=if controller then controller.get() else player.DisplayName,PlaceholderText="Enter your name",ClearTextOnFocus=false,FontFace=F.BOLD,TextSize=20,TextColor3=C.WHITE,PlaceholderColor3=C.GRAY400,TextXAlignment=Enum.TextXAlignment.Left,BackgroundColor3=C.PANEL,BackgroundTransparency=0,BorderSizePixel=0,Size=UDim2.new(1,-142,0,48),Parent=row})
 Kit.corner(box,6);Kit.stroke(box,0.2,Color3.fromRGB(63,131,187),1.5);Kit.pad(box,12,12,0,0)
 local save=Kit.button("primary",{Name="SaveName",Text="SAVE NAME",FontFace=F.BOLD,TextSize=15,AnchorPoint=Vector2.new(1,0),Position=UDim2.fromScale(1,0),Size=UDim2.fromOffset(128,48),Parent=row})
 make("UIGradient",{Rotation=90,Color=ColorSequence.new(C.WHITE,Color3.fromRGB(133,200,231)),Parent=save})
 local status=Kit.paragraph(card,4,"3–20 characters: letters, numbers, spaces, _ - .",{TextSize=13,TextColor3=Color3.fromRGB(155,184,219)});status.Name="NameStatus"
 Kit.paragraph(card,5,"Names are filtered by Roblox. Changes apply to your next round.",{TextSize=13,TextColor3=Color3.fromRGB(155,184,219)})
 local reset=Kit.button("secondary",{Name="ResetName",Text="USE ROBLOX DISPLAY NAME",LayoutOrder=6,Size=UDim2.new(1,0,0,40),FontFace=F.BOLD,TextSize=14,Parent=card})
 local pending=false
 local function commit(value)
  if pending or not controller then return end
  local ok,result=controller.submit(value)
  if not ok then box.Text=controller.get();status.Text=tostring(result);status.TextColor3=C.RED400;return end
  pending=result=="pending"
  status.Text=if pending then "Saving name…" else "Your name is up to date."
  status.TextColor3=if pending then C.AQUARIUS else C.EMERALD300
  save.Text=if pending then "SAVING…" else "SAVE NAME"
 end
 box.FocusLost:Connect(function() commit(box.Text) end)
 save.Activated:Connect(function() if box:IsFocused() then box:ReleaseFocus() else commit(box.Text) end end)
 reset.Activated:Connect(function() commit("") end)
 local resultConn
 if controller then
  resultConn=controller.Changed:Connect(function(result)
   pending=false;save.Text="SAVE NAME"
   if not box:IsFocused() then box.Text=result.name end
   name.Text=result.name
   status.Text=if result.ok then "Name saved." else tostring(result.error or "Could not save your name.")
   status.TextColor3=if result.ok then C.EMERALD300 else C.RED400
  end)
 end
 local function fit()
  local narrow=row.AbsoluteSize.X<480
  row.Size=UDim2.new(1,0,0,if narrow then 104 else 48)
  box.Size=UDim2.new(1,if narrow then 0 else -142,0,48)
  save.Position=UDim2.new(1,0,0,if narrow then 56 else 0)
 end
 local sizeConn=row:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
 card.Destroying:Connect(function() sizeConn:Disconnect();if resultConn then resultConn:Disconnect() end end)
 fit();task.defer(function() if row.Parent then fit() end end)
end
return View
