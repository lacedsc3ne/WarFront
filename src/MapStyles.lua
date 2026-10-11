-- War Front. Copyright (C) 2026 Liam (lacedsc3ne). GNU AGPL v3 or later.
local Factory = require(script.Parent:WaitForChild("FinishedMapStyle"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local MapStyles = {}
function MapStyles.palette(name)
 local visuals=script.Parent:WaitForChild("OriginalMapVisuals")
 if type(name)=="string" and visuals:FindFirstChild(name) then return Factory.palette(name) end
 return Theme
end
function MapStyles.previewPixels(name) return MapStyles.palette(name).pixels end
return MapStyles
