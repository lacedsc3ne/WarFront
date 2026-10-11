-- Server-only persistence for the existing flat War Front profile format.
-- Copyright (C) 2026 Liam (lacedsc3ne). GNU AGPL v3 or later.
-- Dependencies are injected so failure/concurrency tests never contact DataStoreService.
local ProfileData = {}
local function copy(v)
 if type(v) ~= "table" then return v end
 local out = {}
 for k, value in v do out[k] = copy(value) end
 return out
end
ProfileData.copy = copy
local function remember(data)
 data.receiptLedger = if type(data.receiptLedger) == "table" then data.receiptLedger else {}
 data._wfApplied = if type(data._wfApplied) == "table" then data._wfApplied else {}
 for _, id in data.purchases or {} do
  if type(id) == "string" and not data.receiptLedger[id] then data.receiptLedger[id] = { legacy = true } end
 end
end
local function grant(data, receipt)
 if receipt.coins then data.coins += receipt.coins end
 if receipt.boost then
  data.boosts = if type(data.boosts) == "table" then data.boosts else {}
  data.boosts[receipt.boost] = (tonumber(data.boosts[receipt.boost]) or 0) + (receipt.count or 1)
 end
end
ProfileData.grant = grant
local function ordered(pending)
 local list = {}
 for id, op in pending or {} do table.insert(list, {id=id, op=op}) end
 table.sort(list, function(a,b)
  local x,y = a.op.sequence or 0, b.op.sequence or 0
  return if x == y then a.id < b.id else x < y
 end)
 return list
end
function ProfileData.new(store, reconcile, applyOperation, deps)
 deps = deps or {}
 local now = deps.now or os.time
 local wait = deps.wait or task.wait
 local ttl = deps.ttl or 600
 local service = {}
 local function request(fn)
  local err
  for attempt = 1, 3 do
   local ok, result = pcall(fn)
   if ok then return true, result end
   err = result
   if attempt < 3 then wait(0.5 * 2 ^ (attempt - 1)) end
  end
  return false, err
 end
 local function active(session)
  return type(session) == "table" and type(session.expires) == "number" and session.expires > now()
 end
 local function prepare(value)
  local data = reconcile(copy(value))
  remember(data)
  return data
 end
 -- Retry callbacks build fresh tables, never mutate the store's old value.
 function service.acquire(key, token, uid)
  local ok, result = request(function()
   return store:UpdateAsync(key, function(old)
    local data = prepare(old)
    if active(data._wfSession) and data._wfSession.id ~= token then return nil end
    data._wfSession = { id = token, expires = now() + ttl }
    data._wfReleased = nil
    for _, entry in ordered(data._wfPending) do
     local id, op = entry.id, entry.op
     if not data._wfApplied[id] then applyOperation(data, op); data._wfApplied[id] = true end
    end
    data._wfPending = nil
    return data, { uid }
   end)
  end)
  if not ok then return false, result end
  if type(result) ~= "table" or not result._wfSession or result._wfSession.id ~= token then return false, "Profile is still owned by another server" end
  return true, result
 end
 function service.save(key, token, snapshot, uid, release)
  local ok, result = request(function()
   return store:UpdateAsync(key, function(old)
    if release and type(old) == "table" and old._wfReleased == token then return copy(old), { uid } end
    if type(old) ~= "table" or not active(old._wfSession) or old._wfSession.id ~= token then return nil end
    local data = prepare(snapshot)
    data._wfOperationSeq = old._wfOperationSeq or 0
    -- A failed request has an unknown outcome. Preserve committed receipts that
    -- did not reach the caller, rather than overwriting them on the next save.
    for id, receipt in old.receiptLedger or {} do
     if not data.receiptLedger[id] then
      grant(data, receipt)
      data.receiptLedger[id] = copy(receipt)
     end
    end
    local pending = {}
    for _, entry in ordered(old._wfPending) do
     local id, op = entry.id, entry.op
     if not data._wfApplied[id] then
      applyOperation(data, op); data._wfApplied[id] = true
      -- Retain until a later snapshot acknowledges adoption into live memory.
      -- This also makes a commit-with-lost-response safe to retry.
      pending[id] = copy(op)
     end
    end
    data._wfPending = if next(pending) then pending else nil
    data._wfSession = if release then nil else { id = token, expires = now() + ttl }
    data._wfReleased = if release then token else nil
    return data, { uid }
   end)
  end)
  if not ok then return false, result end
  if type(result) ~= "table" or (release and result._wfReleased ~= token)
   or (not release and (not result._wfSession or result._wfSession.id ~= token)) then
   return false, "Profile session ownership was lost"
  end
  return true, result
 end
 function service.adopt(live, saved)
  remember(live)
  for id, receipt in saved.receiptLedger or {} do
   if not live.receiptLedger[id] then grant(live, receipt); live.receiptLedger[id] = copy(receipt) end
  end
  for _, entry in ordered(saved._wfPending) do
   local id, op = entry.id, entry.op
   if not live._wfApplied[id] then applyOperation(live, op); live._wfApplied[id] = true end
  end
 end
 -- The same profile key owns both the lease and durable pending operations.
 -- Offline edits cannot overwrite an active session, even if messaging is lost.
 function service.operation(key, id, op, uid)
  local ok, result = request(function()
   return store:UpdateAsync(key, function(old)
    if type(old) ~= "table" then return nil end
    local data = prepare(old)
    if data._wfApplied[id] or (data._wfPending and data._wfPending[id]) then return data, { uid } end
    data._wfOperationSeq = (data._wfOperationSeq or 0) + 1
    local operation = copy(op); operation.sequence = data._wfOperationSeq
    if active(data._wfSession) then
     data._wfPending = if type(data._wfPending) == "table" then data._wfPending else {}
     data._wfPending[id] = operation
    else
     applyOperation(data, operation); data._wfApplied[id] = true
    end
    return data, { uid }
   end)
  end)
  return ok and type(result) == "table" and ((result._wfApplied and result._wfApplied[id])
   or (result._wfPending and result._wfPending[id])) ~= nil, result
 end
 -- Release only the matching lease. No data writes: used if acquisition completes
 -- after the player leaves, or to compensate a failed handoff.
 function service.release(key, token)
  return request(function()
   return store:UpdateAsync(key, function(old)
    if type(old) ~= "table" or not old._wfSession or old._wfSession.id ~= token then return nil end
    local data = copy(old); data._wfSession = nil; return data
   end)
  end)
 end
 return service
end
return ProfileData
