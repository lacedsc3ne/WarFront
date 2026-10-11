-- Match HUD layouts shared by client settings and server validation.
local Catalog = {}
Catalog.entries = {
 -- night: the Night look on top of the same layout (client; Workspace WFNightMenu = false turns it off).
 { id = "Default", label = "Default", module = "DevelopmentInGameLayout", night = "NightInGameLayout" },
 { id = "Compact", label = "Compact", module = "DefaultInGameLayout" },
}
function Catalog.find(id)
 -- Saved Development preferences now use the promoted Default layout.
 if id == "Development" then id = "Default" end
 for _,entry in Catalog.entries do if entry.id == id then return entry end end
 return nil
end
function Catalog.resolve(id)
 local entry = Catalog.find(id)
 return if entry then entry.id else "Default"
end
return Catalog
