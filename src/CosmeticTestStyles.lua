-- Original War Front animated territory prototypes. Test-only client presentation.
local Styles={}
function Styles.valid(name) return name=="Aurora" or name=="Obsidian" or name=="Radar" end
function Styles.sample(name,u,v,time)
 if name=="Aurora" then
  local band=((math.sin(u*12+v*10+math.sin(u*9+time*.24)*1.8-time*.55)+1)*.5)^5
  local violet=(math.sin(u*7+time*.18)+1)*.5
  return 18+band*(24+violet*79),47+band*(146-violet*76),87+band*(78+violet*39)
 elseif name=="Obsidian" then
  local vein=math.min(math.abs(math.sin(u*41+math.sin(v*23)*1.8)),math.abs(math.sin(v*37+math.sin(u*19)*1.7)))
  local glow=if vein<.055 then .45+.55*(math.sin(time*.75+u*11+v*6)+1)*.5 else 0
  return 29+glow*186,30+glow*132,39+glow*23
 elseif name=="Radar" then
  local dx,dy=u-.5,v-.53
  local radius=math.sqrt(dx*dx+dy*dy)
  local delta=(math.atan2(dy,dx)-time*.65)%(math.pi*2)
  local beam=math.exp(-delta*3.5)*math.clamp(1-radius/.38,0,1)
  local grid=if math.min(math.abs((u*16)%1-.5),math.abs((v*16)%1-.5))<.035 then 1 else 0
  local ring=if math.abs((radius*16)%1-.5)<.025 then 1 else 0
  return 12+beam*17,41+grid*14+ring*12+beam*106,64+grid*15+ring*13+beam*115
 end
 return nil
end
return Styles

