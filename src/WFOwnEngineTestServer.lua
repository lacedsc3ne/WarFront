-- War Front independent engine test host. Copyright (C) 2026 Liam (lacedsc3ne).
-- GNU AGPL v3 or later. Isolated from the current game's Net and UI.
local RunService=game:GetService("RunService")
if not RunService:IsStudio() or workspace:GetAttribute("WFIndependentEngineTest")~=true then return end
local Players=game:GetService("Players")
local Root=game.ServerStorage:WaitForChild("WFOwnEngine")
local Grid=require(Root.Grid)
local Engine=require(Root.Engine)
local Wire=require(Root.Wire)
local Rules=require(Root.Rules)
local remote=Instance.new("RemoteEvent");remote.Name="WFOwnEngineNet";remote.Parent=game.ReplicatedStorage
local session=0;local engine=nil;local users={};local host=nil;local rates={};local spawnEnd=0
local mapId="Europe";local compact=false;local accumulator=0;local lastPublish=0
local perf={total=0,count=0,worst=0}
local function state(plr)
 local data=Wire.state(engine,users[plr.UserId]);data.session=session
 remote:FireClient(plr,"state",data)
end
local function sync(plr)
 remote:FireClient(plr,"map",{version=Wire.version,session=session,id=mapId,width=engine.map.width,height=engine.map.height,compact=compact})
 Wire.snapshot(engine,function(chunk) chunk.session=session;remote:FireClient(plr,"snapshot",chunk) end)
 state(plr)
end
local function join(plr)
 local p=engine:addPlayer(plr.DisplayName,"Human",plr.UserId)
 users[plr.UserId]=p.id
 if not host then host=plr.UserId end
 return p
end
local function reset(id,small)
 local module=game.ReplicatedStorage.Shared.Maps:FindFirstChild(id)
 if not module then return false end
 session+=1;mapId=id;compact=small==true;accumulator=0
 engine=Engine.new(Grid.fromDefinition(require(module),compact),{seed=187,startGold=0,difficulty="Medium"})
 users={};for _,plr in Players:GetPlayers() do join(plr) end
 engine:seedNations();spawnEnd=os.clock()+20
 for _,plr in Players:GetPlayers() do sync(plr) end
 return true
end
reset(workspace:GetAttribute("WFIndependentMap") or "Europe",workspace:GetAttribute("WFIndependentCompact"))
local function begin()
 for _,id in users do
  local p=engine.players[id]
  if not p.spawned then
   for _=1,3000 do
    local tile=engine.rng:NextInteger(0,engine.map.size-1)
    if engine:spawn(id,tile) then break end
   end
  end
 end
 engine:start()
end
local function reply(plr,ok,message)
 remote:FireClient(plr,"result",{ok=ok==true,message=if type(message)=="string" then message else (if ok then "Accepted" else "Command rejected")})
end
remote.OnServerEvent:Connect(function(plr,command,a,b)
 if type(command)~="string" or #command>30 then return end
 local now=os.clock();local rate=rates[plr] or {tokens=20,time=now};rates[plr]=rate
 rate.tokens=math.min(20,rate.tokens+(now-rate.time)*10);rate.time=now
 local charge=if command=="ready" then 5 else 1
 if rate.tokens<charge then return end;rate.tokens-=charge
 local id=users[plr.UserId]
 if not id then join(plr);id=users[plr.UserId] end
 if command=="ready" then sync(plr);return end
 if command=="map" then
  if plr.UserId==host and type(a)=="string" and #a<32 then reply(plr,reset(a,b),"Map restarted") end
  return
 end
 if command=="start" then if plr.UserId==host then begin() end;return end
 local ok,message
 if command=="spawn" then ok,message=engine:spawn(id,a)
 elseif command=="attack" then ok,message=engine:attack(id,a,b)
 elseif command=="build" then if type(b)=="string" and #b<24 then ok,message=engine:build(id,a,b) end
 elseif command=="upgrade" then if Grid.valid(engine.map,a) then ok,message=engine:upgrade(id,a) end
 elseif command=="transport" then ok,message=engine:launchTransport(id,a,b)
 elseif command=="warship" then if Grid.valid(engine.map,a) then ok,message=engine:buildWarship(id,a) end
 elseif command=="move" then if Rules.finite(a) and Grid.valid(engine.map,b) then ok,message=engine:moveWarship(id,a,b) end
 elseif command=="missile" then if type(b)=="string" and #b<24 then ok,message=engine:launchMissile(id,a,b) end
 elseif command=="cancel" then if Rules.finite(a) then ok,message=engine:cancelAttack(id,a) end
 else return end
 reply(plr,ok,message)
end)
Players.PlayerAdded:Connect(function(plr) join(plr) end)
Players.PlayerRemoving:Connect(function(plr) rates[plr]=nil;if host==plr.UserId then host=nil;for _,other in Players:GetPlayers() do if other~=plr then host=other.UserId;break end end end end)
RunService.Heartbeat:Connect(function(dt)
 if engine.phase=="Spawn" and os.clock()>=spawnEnd then begin() end
 accumulator=math.min(accumulator+dt,0.5)
 while accumulator>=Rules.step do
  accumulator-=Rules.step
  local t=os.clock();engine:step();local ms=(os.clock()-t)*1000
  perf.total+=ms;perf.count+=1;perf.worst=math.max(perf.worst,ms)
 end
 if os.clock()-lastPublish<0.2 then return end
 lastPublish=os.clock()
 local delta=Wire.delta(engine)
 if buffer.len(delta)>0 then remote:FireAllClients("delta",{session=session,data=delta}) end
 for _,plr in Players:GetPlayers() do state(plr) end
 for _,event in engine.events do remote:FireAllClients("event",event) end;table.clear(engine.events)
 workspace:SetAttribute("WFOwnEnginePerf",string.format("%s | tick %d | mean %.2f ms | worst %.2f ms",mapId,engine.tick,perf.total/math.max(1,perf.count),perf.worst))
 workspace:SetAttribute("WFOwnEngineStatus",engine.phase)
end)
