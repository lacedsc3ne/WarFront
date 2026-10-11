-- War Front. Copyright (C) 2026 Liam (lacedsc3ne). GNU AGPL v3 or later.
local Shared = script.Parent
local cache = {}
local Factory = {}

-- Map look "E: Soft shore" (owner's pick, 11 Oct 2026): the natural land colours a little richer and
-- brighter, a lighter friendly sea with pale shallows along the coast, and a soft darker coastline.
-- Approved on World, then rolled out to every map (11 Oct 2026). All maps also had lakes and
-- islands under 40 tiles removed from their terrain (ServerStorage.WarFrontTestUIBackups.20261011_before_map_E).
-- Off with workspace attribute WFMapStyleE = false (back to the original look).
local STYLE_E_MAPS = { World = true, Europe = true, NorthAmerica = true, Africa = true, UnitedStates = true, Alps = true, Britannia = true, Italia = true }
local function hex(n) return { n // 65536, (n // 256) % 256, n % 256 } end
local E_SEA = { hex(0x8fd3f5), hex(0x56b2ea), hex(0x2c7cc4) } -- shallows, edge, open sea
local E_LAKE = hex(0x5cb6ea)
local E_COAST = hex(0x24476b)
local E_COAST_MIX = 0.22
local function richer(c)
 local h, s, v = Color3.fromRGB(c[1], c[2], c[3]):ToHSV()
 local o = Color3.fromHSV(h, math.min(1, s * 1.08), math.min(1, v * 1.08))
 return { math.floor(o.R * 255 + 0.5), math.floor(o.G * 255 + 0.5), math.floor(o.B * 255 + 0.5) }
end
function Factory.palette(name)
 if cache[name] then return cache[name] end
 local def = require(Shared.OriginalMapVisuals:WaitForChild(name))
 local encoded = game:GetService("EncodingService"):Base64Decode(buffer.fromstring(def.rle))
 local visual = buffer.create(def.width * def.height)
 local pos = 0
 for i = 0, buffer.len(encoded)-1, 3 do
  local run, colour = buffer.readu16(encoded,i), buffer.readu8(encoded,i+2)
  assert(run > 0 and colour < #def.colours and pos+run <= buffer.len(visual), "Invalid map appearance")
  buffer.fill(visual,pos,colour,run)
  pos += run
 end
 assert(pos == buffer.len(visual), "Truncated map appearance")
 local style = {}
 local styleE = STYLE_E_MAPS[name] == true and workspace:GetAttribute("WFMapStyleE") ~= false
 local eLand = {}
 if styleE then
  for i, c in def.colours do eLand[i] = richer(c) end
  eLand[10] = eLand[4] -- old lake speckle -> grass
 end
 local function rgb(byte,x,y,w,h,flat)
  local m = bit32.band(byte,31)
  if styleE then
   if byte < 128 then
    if not bit32.btest(byte,32) then return E_LAKE[1],E_LAKE[2],E_LAKE[3] end
    local c = E_SEA[if m <= 1 then 1 elseif m <= 2 then 2 else 3]
    return c[1],c[2],c[3]
   end
   local index = 3
   if x and y then
    local sx=math.clamp(math.floor((x+0.5)*def.width/(w or def.width)),0,def.width-1)
    local sy=math.clamp(math.floor((y+0.5)*def.height/(h or def.height)),0,def.height-1)
    index=buffer.readu8(visual,sy*def.width+sx)
   end
   local c = if flat and index < 6 then eLand[4] else (eLand[index+1] or eLand[4])
   if bit32.btest(byte,64) then -- soft coastline on land touching water
    local f = E_COAST_MIX
    return math.floor(c[1]+(E_COAST[1]-c[1])*f), math.floor(c[2]+(E_COAST[2]-c[2])*f), math.floor(c[3]+(E_COAST[3]-c[3])*f)
   end
   return c[1],c[2],c[3]
  end
  if byte < 128 then
   if m <= 1 then return 15,86,142 end
   if m <= 3 then return 9,68,119 end
   if m <= 6 then return 6,48,92 end
   return 3,34,69
  end
  local index = 3
  if x and y then
   local sx=math.clamp(math.floor((x+0.5)*def.width/(w or def.width)),0,def.width-1)
   local sy=math.clamp(math.floor((y+0.5)*def.height/(h or def.height)),0,def.height-1)
   index=buffer.readu8(visual,sy*def.width+sx)
  end
  -- Filled raster speckles are now land; avoid retaining the old blue lake tint.
  if index == 9 then index = 3 end
  if flat and index < 6 then return 151,171,55 end
  local c=def.colours[index+1]
  return c[1],c[2],c[3]
 end
 function style.tileRGB(byte,x,y,w,h) return rgb(byte,x,y,w,h,false) end
 style.terrainRGB=style.tileRGB
 function style.flatTerrainRGB(byte,x,y,w,h) return rgb(byte,x,y,w,h,true) end
 function style.pixelAt(byte,x,y,w,h)
  local r,g,b=rgb(byte,x,y,w,h,false)
  return r+g*256+b*65536+255*16777216
 end
 style.pixels=table.create(256)
 for byte=0,255 do style.pixels[byte+1]=style.pixelAt(byte) end
 cache[name]=style
 return style
end
return Factory
