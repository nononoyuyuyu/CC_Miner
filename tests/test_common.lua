-- Deterministic V4 common/config tests.  The mock fs intentionally has no
-- host filesystem dependency so this test remains portable to CC:Tweaked.

local root = assert(arg[1], "repository root is required")
local files, directories = {}, { [""] = true }

local function normalized(path)
  return tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
end

fs = {}
function fs.exists(path)
  path = normalized(path)
  return files[path] ~= nil or directories[path] == true
end
function fs.isDir(path)
  return directories[normalized(path)] == true
end
function fs.getDir(path)
  local cleaned = normalized(path)
  return cleaned:match("^(.*)/[^/]+$") or ""
end
function fs.makeDir(path)
  path = normalized(path)
  if path == "" then directories[path] = true; return end
  local parent = fs.getDir(path)
  if not directories[parent] then fs.makeDir(parent) end
  directories[path] = true
end
function fs.delete(path)
  path = normalized(path)
  files[path] = nil
  for candidate in pairs(files) do
    if candidate:sub(1, #path + 1) == path .. "/" then files[candidate] = nil end
  end
  for candidate in pairs(directories) do
    if candidate == path or candidate:sub(1, #path + 1) == path .. "/" then directories[candidate] = nil end
  end
end
function fs.move(source, target)
  source, target = normalized(source), normalized(target)
  local targetDir = fs.getDir(target)
  if targetDir ~= "" then fs.makeDir(targetDir) end
  if files[source] ~= nil then
    files[target], files[source] = files[source], nil
    return
  end
  error("mock move source is missing: " .. source)
end
function fs.getSize(path)
  return #(files[normalized(path)] or "")
end
function fs.open(path, mode)
  path = normalized(path)
  local targetDir = fs.getDir(path)
  if targetDir ~= "" then fs.makeDir(targetDir) end
  if mode == "r" and files[path] == nil then return nil end
  local content = mode == "a" and (files[path] or "") or mode == "r" and files[path] or ""
  local position = 1
  return {
    readAll = function() position = #content + 1; return content end,
    readLine = function()
      if position > #content then return nil end
      local nextLine = content:find("\n", position, true)
      local line = content:sub(position, nextLine and nextLine - 1 or #content)
      position = nextLine and nextLine + 1 or #content + 1
      return line
    end,
    write = function(text) content = content .. tostring(text or "") end,
    writeLine = function(text) content = content .. tostring(text or "") .. "\n" end,
    close = function() files[path] = content end,
  }
end

-- ComputerCraft's serializer rejects recursive/shared table references on
-- some builds.  Keep that behavior in the mock so saveConfig must detach the
-- legacy materials.discard alias before serializing a worker config.
textutils = {}
function textutils.serialize(value)
  local seen = {}
  local function encode(item)
    if type(item) == "table" then
      if seen[item] then error("shared table reference") end
      seen[item] = true
      local parts = { "{" }
      for key, nested in pairs(item) do
        parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(nested) .. ","
      end
      parts[#parts + 1] = "}"
      return table.concat(parts)
    elseif type(item) == "string" then
      return string.format("%q", item)
    elseif item == nil then
      return "nil"
    else
      return tostring(item)
    end
  end
  return encode(value)
end
function textutils.unserialize(text)
  local loader = loadstring or load
  local fn = assert(loader("return " .. text))
  return fn()
end

os.getComputerID = function() return 1 end
os.getComputerLabel = function() return "Test" end
os.epoch = function() return 123456 end

local common = dofile(root .. "/src/ccminer/lib/common.lua")
assert(common.VERSION == "4.0.0")
assert(common.SCHEMA == 4)
assert(common.PROTOCOL == "ccminer:v2")

local function count(value)
  local total = 0
  for _ in pairs(value or {}) do total = total + 1 end
  return total
end

local function writeTable(path, value)
  fs.delete(path)
  local handle = assert(fs.open(path, "w"))
  handle.write(textutils.serialize(value))
  handle.close()
end

local function loadConfigFrom(raw)
  fs.delete(common.CONFIG_PATH)
  fs.delete(common.CONFIG_PATH .. ".bak")
  writeTable(common.CONFIG_PATH, raw)
  local config, err = common.loadConfig()
  assert(not err, err)
  return config
end

-- Atomic persistence and backup recovery use only the in-memory fs above.
local ok, err = common.writeAllAtomic("/state.db", "{[\"value\"] = \"one\",}")
assert(ok, err)
ok, err = common.writeAllAtomic("/state.db", "{[\"value\"] = \"two\",}")
assert(ok, err)
assert(fs.exists("/state.db") and fs.exists("/state.db.bak"))
assert(not fs.exists("/state.db.tmp"))
fs.delete("/state.db")
local recovered, recoveryError = common.loadTable("/state.db", {})
assert(not recoveryError, recoveryError)
assert(recovered.value == "one")
assert(fs.exists("/state.db"))

local saved, saveError = common.saveTable("/table.db", { role = "worker", nested = { state = "idle" } })
assert(saved, saveError)
local loaded, loadError = common.loadTable("/table.db", {})
assert(not loadError, loadError)
assert(loaded.role == "worker" and loaded.nested.state == "idle")

-- V4 worker defaults: disposal is opt-in, cadence is bounded, and the dock
-- identity is explicit.  Side defaults keep the torch chest away from seal.
local workerDefaults = common.defaultWorkerConfig()
assert(workerDefaults.schema == 4 and workerDefaults.version == "4.0.0" and workerDefaults.role == "worker")
assert(workerDefaults.profile == "balanced" and workerDefaults.waterMode == "seal")
assert(workerDefaults.discard.mode == "KEEP_ALL")
assert(count(workerDefaults.discard.allowlist) == 0)
assert(workerDefaults.discard.stoneAllowlist["minecraft:stone"] == true)
assert(workerDefaults.discard.retainSealTarget == 64)
assert(workerDefaults.discard.triggerEmptySlots == 3)
assert(workerDefaults.discard.direction == "back" and workerDefaults.discard.maxStacksPerPass == 8)
assert(workerDefaults.performance.gpsVerifyEveryMoves == 32)
assert(workerDefaults.performance.gpsVerifyMoves == 32)
assert(workerDefaults.performance.gpsVerifyCadence == 32)
assert(workerDefaults.performance.lightweightCheckpointEveryMoves == 16)
assert(workerDefaults.performance.lightweightCheckpointCadence == 16)
assert(workerDefaults.performance.journalEveryMoves == 16)
assert(workerDefaults.performance.checkpointEveryMoves == 32)
assert(workerDefaults.dock.id == "main" and workerDefaults.dock.groupId == "default" and workerDefaults.dock.bayId == "main")
assert(workerDefaults.dock.homeWorld.x == nil and workerDefaults.dock.homeWorld.y == nil and workerDefaults.dock.homeWorld.z == nil)
assert(workerDefaults.dock.requireSameFloor and workerDefaults.dock.sameFloor and workerDefaults.dock.verifySameFloor)
assert(workerDefaults.service.adaptive and workerDefaults.service.finishCurrentChunk)
assert(workerDefaults.torchSide == "left" and workerDefaults.sealSide == "right")
assert(workerDefaults.alerts.enabled == true and workerDefaults.alerts.onWaiting == true)
assert(workerDefaults.materials.sealSlots[1] == 13 and workerDefaults.materials.sealSlots[2] == 14)
assert(workerDefaults.materials.torchSlots[1] == 15 and workerDefaults.materials.torchSlots[2] == 16)

-- V4 controller defaults centralize group/service/partition limits and dock
-- floor checks in nested records.
local controllerDefaults = common.defaultControllerConfig()
assert(controllerDefaults.schema == 4 and controllerDefaults.version == "4.0.0" and controllerDefaults.role == "controller")
assert(controllerDefaults.group.maxWorkers == 16)
assert(controllerDefaults.group.maxConcurrentService == 1)
assert(controllerDefaults.group.partitionMode == "stripe")
assert(controllerDefaults.group.requireGpsForPartition == true)
assert(controllerDefaults.dock.baySpacing == 4 and controllerDefaults.dock.requireSameFloor == true)
assert(controllerDefaults.touchEnabled == true)
assert(controllerDefaults.presets.safe.profile == "safe")
assert(controllerDefaults.presets.balanced.profile == "balanced")
assert(controllerDefaults.presets.turbo.profile == "turbo")
assert(common.defaultGPSConfig().schema == 4 and common.defaultGPSConfig().role == "gps")

-- State defaults include durable return/resume markers, independent discard
-- counters, route/time metrics, and a lightweight journal stream.
local state = common.defaultState()
assert(state.schema == 4 and state.version == "4.0.0")
assert(state.status == "idle" and state.phase == "home")
assert(state.pose.x == 0 and state.pose.y == 0 and state.pose.z == 0 and state.pose.dir == 0)
assert(state.returnReason == nil and state.lastReturnReason == nil and state.resumeToken == nil)
assert(type(state.resume) == "table" and state.resume.token == nil and state.resume.issuedAt == nil and state.resume.consumedAt == nil)
assert(state.discardStats.mode == "KEEP_ALL" and state.discardStats.enabled == false)
assert(state.discardStats.passes == 0 and state.discardStats.attempts == 0 and state.discardStats.stacks == 0)
assert(state.discardStats.discarded == 0 and state.discardStats.items == 0)
assert(state.discardStats.skipped == 0 and state.discardStats.held == 0)
assert(state.discardStats.unknown == 0 and state.discardStats.overflow == 0)
assert(type(state.discardStats.byName) == "table" and state.discardStats.lastAt == nil and state.discardStats.lastError == nil)
assert(state.discard ~= state.discardStats and state.discard.mode == "KEEP_ALL")
state.discard.discarded = 1
assert(state.discardStats.discarded == 0)
assert(state.routeMetrics.moves == 0 and state.routeMetrics.turns == 0 and state.routeMetrics.distance == 0)
assert(state.routeMetrics.routeLength == 0 and state.routeMetrics.detours == 0 and state.routeMetrics.services == 0)
assert(state.metrics.route ~= state.routeMetrics and state.metrics.route.moves == 0)
assert(state.timeMetrics.startedAt == nil and state.timeMetrics.updatedAt == nil)
assert(state.timeMetrics.elapsedSeconds == 0 and state.timeMetrics.activeSeconds == 0)
assert(state.timeMetrics.serviceSeconds == 0 and state.timeMetrics.returnSeconds == 0 and state.timeMetrics.lastMoveAt == nil)
assert(state.metrics.time ~= state.timeMetrics and state.metrics.time.elapsedSeconds == 0)
assert(state.journal.enabled == true and state.journal.seq == 0 and state.journal.checkpoints == 0)
assert(type(state.journal.lightweight) == "table" and state.journal.lightweight.enabled == true)
assert(state.journal.lightweight.seq == 0 and state.journal.lightweight.writes == 0 and state.journal.lightweight.checkpoints == 0)
assert(state.lighting.mode == "safe" and state.lighting.torchesPlaced == 0 and state.lighting.torchShortages == 0)
assert(state.water.mode == "seal" and state.water.continuousSeals == 0)
assert(state.recycle.enabled and state.recycle.recycled == 0)
assert(state.serviceStats.started == 0 and state.serviceStats.completed == 0)
assert(state.stats.jobsCompleted == 0 and state.stats.waterSealed == 0)
assert(state.report == nil and state.jobReport == nil and state.pendingAction == nil)

-- A V3 worker file is accepted and upgraded to schema 4 while preserving
-- valid legacy values and creating independent nested aliases.
local migratedWorker = loadConfigFrom({
  role = "worker",
  schema = 3,
  version = "3.0.0",
  networkKey = "legacy-key",
  workerName = "Legacy",
  retainSealTarget = 48,
  torchSide = "left",
  sealSide = "right",
  lighting = { side = "left" },
  discard = { mode = "CUSTOM_ALLOWLIST", allowlist = { "minecraft:stone" }, retainSealTarget = 48 },
  dock = { id = "dock-old", groupId = "group-old", bayId = "bay-old" },
})
assert(migratedWorker.schema == 4 and migratedWorker.version == "4.0.0" and migratedWorker.role == "worker")
assert(migratedWorker.networkKey == "legacy-key" and migratedWorker.workerName == "Legacy")
assert(migratedWorker.discard.mode == "CUSTOM_ALLOWLIST")
assert(migratedWorker.discard.allowlist["minecraft:stone"] == true)
assert(migratedWorker.discard.retainSealTarget == 48 and migratedWorker.materials.retainSealTarget == 48)
assert(migratedWorker.materials.discard ~= migratedWorker.discard)
assert(migratedWorker.dock.id == "dock-old" and migratedWorker.dock.groupId == "group-old" and migratedWorker.dock.bayId == "bay-old")
local migratedSaved, migratedSaveError = common.saveConfig(migratedWorker)
assert(migratedSaved, migratedSaveError)
local migratedStored, migratedStoredError = common.loadTable(common.CONFIG_PATH, {})
assert(not migratedStoredError, migratedStoredError)
assert(migratedStored.schema == 4 and migratedStored.version == "4.0.0")

-- Controller V3 names are migrated from the older top-level service,
-- partition, and dock records into the canonical V4 group/dock contract.
local migratedController = loadConfigFrom({
  role = "controller",
  schema = 3,
  version = "3.0.0",
  networkKey = "legacy-key",
  group = { maxWorkers = 4 },
  service = { maxConcurrentService = 3 },
  partition = { mode = "round-robin", requireGps = false },
  dock = { baySpacing = 8, sameFloor = false },
})
assert(migratedController.schema == 4 and migratedController.version == "4.0.0")
assert(migratedController.group.maxWorkers == 4)
assert(migratedController.group.maxConcurrentService == 3)
assert(migratedController.group.partitionMode == "round_robin")
assert(migratedController.group.requireGpsForPartition == false)
assert(migratedController.dock.baySpacing == 8 and migratedController.dock.requireSameFloor == false)

-- Malformed nested values are repaired from safe defaults.  The requested
-- torch side is moved off the seal side when sealing is enabled.
local malformed = loadConfigFrom({
  role = "worker",
  schema = 3,
  version = "3.0.0",
  networkKey = "short",
  workerName = 99,
  profile = "unknown",
  waterMode = "bad",
  maxWidth = "wide",
  reserveEmptySlots = 99,
  sealSide = "right",
  torchSide = "right",
  lavaMode = "seal",
  discard = {
    mode = "bad",
    allowlist = { "minecraft:*", "stone" },
    retainSealTarget = "bad",
    triggerEmptySlots = 99,
    direction = "diagonal",
    maxStacksPerPass = 0,
  },
  performance = {
    gpsVerifyEveryMoves = 999,
    lightweightCheckpointEveryMoves = 0,
    checkpointEveryMoves = "bad",
  },
  dock = {
    id = "bad id",
    groupId = " ",
    bayId = {},
    homeWorld = { x = "x", y = 1, z = 1 },
    facing = "diagonal",
    lane = "bad",
    requireSameFloor = "yes",
  },
  lighting = {
    mode = "invalid",
    interval = -2,
    preferredSlots = { 13, 13 },
    torchBlocks = { ["minecraft:torch"] = 1 },
    side = "right",
  },
  materials = {
    sealSlots = { 1, 1 },
    torchSlots = { 0 },
    fuelReserveSlots = "not-a-list",
  },
  journal = { enabled = "yes", checkpointEvery = -1, lightweightCheckpointEveryMoves = 0 },
  alerts = { enabled = "yes", redstoneSide = "invalid", cooldownSeconds = -1 },
  gps = { enabled = "yes", timeout = -1, calibration = "not-a-table" },
})
assert(malformed.networkKey == "CHANGE_ME" and malformed.workerName == "Test")
assert(malformed.profile == "balanced" and malformed.waterMode == "seal")
assert(malformed.maxWidth == workerDefaults.maxWidth and malformed.reserveEmptySlots == workerDefaults.reserveEmptySlots)
assert(malformed.discard.mode == "KEEP_ALL" and count(malformed.discard.allowlist) == 0)
assert(malformed.discard.retainSealTarget == 64 and malformed.discard.triggerEmptySlots == 3)
assert(malformed.discard.direction == "back" and malformed.discard.maxStacksPerPass == 8)
assert(malformed.performance.gpsVerifyEveryMoves == 32)
assert(malformed.performance.lightweightCheckpointEveryMoves == 16)
assert(malformed.performance.checkpointEveryMoves == 32)
assert(malformed.dock.id == "main" and malformed.dock.groupId == "default" and malformed.dock.bayId == "main")
assert(malformed.dock.facing == 0 and malformed.dock.lane == 0 and malformed.dock.requireSameFloor == true)
assert(malformed.dock.homeWorld.x == nil and malformed.dock.homeWorld.y == nil and malformed.dock.homeWorld.z == nil)
assert(malformed.lighting.mode == "safe" and malformed.lighting.interval == 10)
assert(malformed.lighting.preferredSlots[1] == 15 and malformed.lighting.preferredSlots[2] == 16)
assert(malformed.lighting.torchBlocks["minecraft:torch"] == true)
assert(malformed.lighting.side == "left" and malformed.torchSide == "left")
assert(malformed.materials.sealSlots[1] == 13 and malformed.materials.sealSlots[2] == 14)
assert(malformed.materials.torchSlots[1] == 15 and malformed.materials.torchSlots[2] == 16)
assert(malformed.materials.discard ~= malformed.discard)
assert(malformed.journal.enabled == true and malformed.journal.checkpointEvery == 32)
assert(malformed.alerts.enabled == true and malformed.alerts.redstoneSide == "back" and malformed.alerts.cooldownSeconds == 10)
assert(malformed.gps.enabled == true and malformed.gps.timeout == 2 and malformed.gps.calibration == nil)

-- Controller nested enum/number repair keeps the service and partition
-- defaults safe when malformed values are supplied.
local malformedController = loadConfigFrom({
  role = "controller",
  schema = 4,
  version = "4.0.0",
  group = {
    maxWorkers = 0,
    maxConcurrentService = "many",
    partitionMode = "invalid",
    requireGpsForPartition = "yes",
  },
  service = { maxConcurrentService = 99 },
  partition = { mode = "invalid" },
  dock = { baySpacing = 0, requireSameFloor = "yes" },
  alerts = { speaker = "yes", redstoneSide = "diagonal" },
})
assert(malformedController.group.maxWorkers == 16)
assert(malformedController.group.maxConcurrentService == 1)
assert(malformedController.group.partitionMode == "stripe")
assert(malformedController.group.requireGpsForPartition == true)
assert(malformedController.dock.baySpacing == 4 and malformedController.dock.requireSameFloor == true)
assert(malformedController.alerts.speaker == true and malformedController.alerts.redstoneSide == "back")

-- Allowlist entries are grants only for complete namespace:item IDs.  A bad
-- entry invalidates the supplied list rather than widening permissions.
local validAllowlist = loadConfigFrom({
  role = "worker", schema = 4, version = "4.0.0",
  discard = { mode = "CUSTOM_ALLOWLIST", allowlist = { "minecraft:stone", "mod_name:item.path-1" } },
})
assert(validAllowlist.discard.allowlist["minecraft:stone"] == true)
assert(validAllowlist.discard.allowlist["mod_name:item.path-1"] == true)

local invalidAllowlists = {
  { "minecraft:*" },
  { "stone" },
  { ":stone" },
  { "minecraft:" },
  { "minecraft:stone withspace" },
  { " minecraft:stone" },
  { "minecraft:stone " },
  "minecraft:stone, minecraft:dirt",
}
for index, invalid in ipairs(invalidAllowlists) do
  local rejected = loadConfigFrom({
    role = "worker", schema = 4, version = "4.0.0",
    discard = { mode = "CUSTOM_ALLOWLIST", allowlist = invalid },
  })
  assert(count(rejected.discard.allowlist) == 0, "unsafe allowlist accepted at case " .. tostring(index))
end

-- The legacy material alias must be detached even after normalization.
malformed.materials.discard.retainSealTarget = 7
assert(malformed.discard.retainSealTarget == 64)

-- saveConfig must survive a ComputerCraft serializer that rejects shared
-- tables.  The in-memory config may still use the legacy live alias.
local shared = common.defaultWorkerConfig()
shared.materials.discard = shared.discard
local sharedSaved, sharedSaveError = common.saveConfig(shared)
assert(sharedSaved, sharedSaveError)
local stored, storedError = common.loadTable(common.CONFIG_PATH, {})
assert(not storedError, storedError)
assert(stored.schema == 4 and stored.version == "4.0.0" and stored.role == "worker")
assert(type(stored.materials) == "table" and type(stored.discard) == "table")
assert(stored.materials.discard ~= stored.discard)

print("common V4 defaults, migration, normalization, persistence, and portable fs tests passed")
