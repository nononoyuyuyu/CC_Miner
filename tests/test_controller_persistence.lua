-- Persistence regression tests for CC:Tweaked's table serializer.
-- The real serializer rejects recursive and repeated table references, while
-- ordinary Lua table traversal (and the old test mock) silently accepts them.
-- V4 adds independent group/dock/bay/job/lease registries; keep this test
-- aligned with the detached roots assembled by controller saveControllerDb.

local root = arg[1]

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function parts(directory, count)
  local out = {}
  for index = 1, count do
    out[#out + 1] = read(directory .. "/" .. ("%02d"):format(index) .. ".part")
  end
  return table.concat(out, "\n")
end

local controller = parts("src/ccminer/controller_parts", 3)
assert(controller:find("local function persistentDraft(source)", 1, true), "controller draft sanitizer is missing")
assert(controller:find("local function persistentGroupValue(source)", 1, true), "V4 group sanitizer is missing")
assert(controller:find("db.activeLeases = common.copy(db.leases or {})", 1, true), "controller lease detachment is missing")
assert(not controller:find("db.activeLeases = db.leases", 1, true), "controller still aliases active leases")
assert(not controller:find("db.activeLeases = kept", 1, true), "controller still aliases released leases")
assert(controller:find("db.lastDraft = persistentDraft(draft)", 1, true), "last draft is not sanitized before save")
assert(controller:find("local item = persistentDraft(draft)", 1, true), "queue draft is not sanitized before save")
assert(controller:find("local draftValue = persistentDraft(source or draft or db.lastDraft or {})", 1, true), "preset draft is not sanitized before save")
assert(controller:find("local persistedGroups, persistedDocks, persistedBays, persistedJobs, persistedGroupLeases = {}, {}, {}, {}, {}", 1, true), "V4 DB roots are not detached")
assert(controller:find("persistedDb.groups, persistedDb.docks, persistedDb.bays = persistedGroups, persistedDocks, persistedBays", 1, true), "V4 group/dock/bay roots are not persisted independently")
assert(controller:find("persistedDb.groupJobs, persistedDb.groupLeases = persistedJobs, persistedGroupLeases", 1, true), "V4 group job/lease roots are not persisted independently")
assert(controller:find("persistedDb.activeLeases = common.copy(db.leases or {})", 1, true), "V4 active lease snapshot is not detached")
assert(not controller:find("persistedDb.groups = db.groups", 1, true), "V4 persisted groups still alias live groups")
assert(not controller:find("persistedDb.groupJobs = db.groupJobs", 1, true), "V4 persisted jobs still alias live jobs")
assert(not controller:find("persistedDb.groupLeases = db.groupLeases", 1, true), "V4 persisted leases still alias live group leases")

-- Approximate CC:Tweaked textutils.serialize's reference check.  It is enough
-- to walk every key/value table and reject a table encountered twice.
local function ccSerialize(value)
  local seen = {}
  local function visit(item)
    local kind = type(item)
    if kind == "function" or kind == "thread" or kind == "userdata" then
      error("Cannot serialize " .. kind, 0)
    end
    if kind ~= "table" then return end
    if seen[item] then error("Cannot serialize table with recursive entries", 0) end
    seen[item] = true
    for key, nested in pairs(item) do
      visit(key)
      visit(nested)
    end
  end
  visit(value)
  return "{}"
end

local common = dofile(root .. "/src/ccminer/lib/common.lua")
local quarry = dofile(root .. "/src/ccminer/lib/quarry.lua")

-- Reproduce the original failures: the lease compatibility alias and a
-- persisted preflight plan both contain repeated table references.
local leases = { { jobId = "job-1", chunks = { "L:0:0" } } }
local aliasedDb = { leases = leases, activeLeases = leases }
local bad, badError = pcall(ccSerialize, aliasedDb)
assert(not bad and tostring(badError):find("recursive", 1, true), "serializer mock did not reject lease alias")

local plan = assert(quarry.buildChunkPlan({ width = 40, length = 40, depth = 3, chunkMode = "local" }))
local draft = { width = 40, length = 40, depth = 3, preflight = { plan = plan, estimate = { plan = plan } } }
bad, badError = pcall(ccSerialize, draft)
assert(not bad and tostring(badError):find("recursive", 1, true), "serializer mock did not reject preflight alias")

-- Mirror the production sanitizer's contract: preflight and dispatch-only
-- fields are omitted, and each durable field is copied independently.
local function persistentDraft(source)
  local value = {}
  for key, item in pairs(source or {}) do
    if key ~= "preflight" and key ~= "queueIndex" and key ~= "awaiting" then
      value[key] = common.copy(item)
    end
  end
  return value
end

local persisted = {
  lastDraft = persistentDraft(draft),
  queue = { persistentDraft(draft) },
  activeLeases = common.copy(leases),
  leases = leases,
}
assert(persisted.lastDraft.preflight == nil and persisted.queue[1].preflight == nil)
assert(persisted.activeLeases ~= persisted.leases)
assert(pcall(ccSerialize, persisted), "sanitized controller DB is not serializable")

-- V4 durable group state: every registry owns an independent copy of its
-- nested records.  This catches the common failure where group jobs retain a
-- live assignment/lease table that is also reachable through db.leases.
local groupRecord = {
  id = "miners", workerIds = { 1 }, workerBays = { ["1"] = "bay-1" },
  workerDocks = { ["1"] = "dock-1" }, mode = "world", partition = "stripe",
}
local dockRecord = { id = "dock-1", world = { x = 0, y = 64, z = 0 }, facing = 0, maxDepth = 32 }
local bayRecord = { id = "bay-1", world = { x = 0, y = 64, z = 0 }, facing = 0, maxDepth = 32 }
local assignment = {
  assignmentId = "group-1:1", workerId = 1, chunkKeys = { "world:0:0" }, transitKeys = {},
  homeY = 64, bottomY = 32, layers = 33,
}
local groupJob = {
  groupJobId = "group-1", groupId = "miners", status = "working", bottomY = 32,
  profile = "balanced", waterMode = "seal", lighting = { mode = "safe", interval = 10 },
  partition = "stripe", catalog = { mode = "world", rootKey = "world:0:0", chunks = { { key = "world:0:0", cx = 0, cz = 0 } } },
  assignments = { ["1"] = assignment },
}
local v4MineLease = {
  groupJobId = "group-1", assignmentId = "group-1:1", workerId = 1,
  mode = "world", kind = "mine", chunks = { "world:0:0" },
}
local v4TransitLease = {
  groupJobId = "group-1", assignmentId = "group-1:1", workerId = 1,
  mode = "world", kind = "transit", chunks = {},
}
local v4Db = {
  groups = { miners = common.copy(groupRecord) },
  docks = { ["dock-1"] = common.copy(dockRecord) },
  bays = { ["bay-1"] = common.copy(bayRecord) },
  groupJobs = { ["group-1"] = common.copy(groupJob) },
  leases = { common.copy(v4MineLease), common.copy(v4TransitLease) },
  groupLeases = { common.copy(v4MineLease), common.copy(v4TransitLease) },
  activeLeases = { common.copy(v4MineLease), common.copy(v4TransitLease) },
}
assert(pcall(ccSerialize, v4Db), "V4 group DB tree is not serializable")
assert(v4Db.leases ~= v4Db.groupLeases and v4Db.leases ~= v4Db.activeLeases, "V4 lease roots still alias")
assert(v4Db.groupJobs["group-1"].assignments["1"] ~= assignment, "V4 group job assignment was not copied")

-- Reproduce a V4 alias failure: the same assignment and lease table cannot be
-- reachable from multiple durable roots, even when no cycle is present.
local aliasedV4 = {
  groups = { miners = groupRecord },
  docks = { ["dock-1"] = dockRecord },
  bays = { ["bay-1"] = bayRecord },
  groupJobs = { ["group-1"] = groupJob },
  leases = { v4MineLease },
  groupLeases = { v4MineLease },
}
bad, badError = pcall(ccSerialize, aliasedV4)
assert(not bad and tostring(badError):find("recursive", 1, true), "serializer mock did not reject V4 registry aliases")

-- Worker state persists a chunk plan directly.  The plan itself must be a
-- tree, independent of controller draft sanitization.
assert(pcall(ccSerialize, plan), "worker chunk plan is not serializable")

print("controller/worker persistence shared-reference regression passed")
