-- Selects match-only presentation without rebuilding game state or command handlers.
local Settings = require(script.Parent:WaitForChild("Settings"))
local Catalog = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("InGameLayoutCatalog"))
local InGameUI = {}
function InGameUI.attach(api)
 local active, cleanup
 local baseLayout = api.layout
 local baseUpdate = api.update
 local latest
 local applying = false
 api.layout = function(...)
  baseLayout(...)
  if active and not applying then
   applying = true
   active.layout(api)
   applying = false
  end
 end
 api.update = function(mine, me, phase, ratio)
  latest={mine=mine,me=me,phase=phase,ratio=ratio}
  baseUpdate(mine,me,phase,ratio)
  if active and active.update then active.update(api,mine,me,phase,ratio) end
 end
 local function selectLayout()
  local id = Catalog.resolve(Settings.values.inGameUILayout)
  if api.root:GetAttribute("InGameUILayout") == id then return end
  if cleanup then cleanup(); cleanup = nil end
  local entry = Catalog.find(id)
  local module = if entry.night and workspace:GetAttribute("WFNightMenu") ~= false and workspace:GetAttribute("WFNightHudOff") ~= true then entry.night else entry.module
  active = require(script.Parent:WaitForChild(module))
  cleanup = active.mount(api)
  api.root:SetAttribute("InGameUILayout", id)
  api.layout()
  if latest and active.update then active.update(api,latest.mine,latest.me,latest.phase,latest.ratio) end
 end
 local conn = Settings.Changed:Connect(function(key)
  if key == "inGameUILayout" then selectLayout() end
 end)
 api.root.Destroying:Connect(function()
  conn:Disconnect()
  if cleanup then cleanup(); cleanup = nil end
 end)
 selectLayout()
end
return InGameUI
