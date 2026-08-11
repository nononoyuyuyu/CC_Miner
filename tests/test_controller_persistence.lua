-- Persistence regression tests for CC:Tweaked's table serializer.
-- The real serializer rejects recursive and repeated table references, while
-- ordinary Lua table traversal (and the old test mock) silently accepts them.

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
assert(controller:find("db.activeLeases = common.copy(db.leases or {})", 1, true), "controller lease detachment is missing")
assert(controller:find("db.lastDraft = persistentDraft(draft)", 1, true), "last draft is not sanitized before save")
assert(controller:find("local item = persistentDraft(draft)", 1, true), "queue draft is not sanitized before save")
assert(controller:find("local draftValue = persistentDraft(source or draft or db.lastDraft or {})", 1, true), "preset draft is not sanitized before save")

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

-- Worker state persists a chunk plan directly.  The plan itself must be a
-- tree, independent of controller draft sanitization.
assert(pcall(ccSerialize, plan), "worker chunk plan is not serializable")

print("controller/worker persistence shared-reference regression passed")
