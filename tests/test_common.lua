-- Deterministic common/config tests.  The mock fs intentionally has no host
-- filesystem dependency so this test is portable to CC:Tweaked.

local root = arg[1]
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

textutils = {}
function textutils.serialize(value)
  local function encode(item)
    if type(item) == "table" then
      local parts = { "{" }
      for key, nested in pairs(item) do
        parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(nested) .. ","
      end
      parts[#parts + 1] = "}"
      return table.concat(parts)
    elseif type(item) == "string" then
      return string.format("%q", item)
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
assert(common.VERSION == "3.0.0")
assert(common.SCHEMA == 3)
assert(common.PROTOCOL == "ccminer:v2")

-- Atomic persistence and backup recovery use only the in-memory fs above.
local ok, err = common.writeAllAtomic("/state.db", "{[\"value\"] = \"one\",}")
assert(ok, err)
ok, err = common.writeAllAtomic("/state.db", "{[\"value\"] = \"two\",}")
assert(ok, err)
assert(fs.exists("/state.db") and fs.exists("/state.db.bak"))
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

-- V3 defaults and profile/preset enums.
local worker = common.defaultWorkerConfig()
assert(worker.schema == 3 and worker.version == "3.0.0" and worker.role == "worker")
assert(worker.profile == "balanced")
assert(worker.waterMode == "seal" and worker.lavaMode == "seal")
assert(worker.sealSide == "right" and worker.torchSide == "left")
assert(worker.lighting.side == "left" and worker.sealSide ~= worker.lighting.side)
assert(worker.materials.sealSlots[1] == 13 and worker.materials.sealSlots[2] == 14)
assert(worker.materials.torchSlots[1] == 15 and worker.materials.torchSlots[2] == 16)
assert(worker.alerts.enabled == true and worker.alerts.onWaiting == true)
assert(common.defaultControllerConfig().touchEnabled == true)
assert(common.defaultControllerConfig().presets.safe.profile == "safe")
assert(common.defaultControllerConfig().presets.balanced.profile == "balanced")
assert(common.defaultControllerConfig().presets.turbo.profile == "turbo")
assert(common.defaultGPSConfig().role == "gps")

local state = common.defaultState()
assert(state.schema == 3 and state.version == "3.0.0")
assert(state.status == "idle" and state.phase == "home")
assert(state.pose.x == 0 and state.pose.y == 0 and state.pose.z == 0 and state.pose.dir == 0)
assert(state.journal.enabled and state.journal.seq == 0 and state.journal.checkpoints == 0)
assert(state.lighting.mode == "safe" and state.lighting.torchesPlaced == 0 and state.lighting.torchShortages == 0)
assert(state.water.mode == "seal" and state.water.continuousSeals == 0)
assert(state.recycle.enabled and state.recycle.recycled == 0)
assert(state.serviceStats.started == 0 and state.serviceStats.completed == 0)
assert(state.stats.jobsCompleted == 0 and state.stats.waterSealed == 0)
assert(state.report == nil and state.jobReport == nil and state.pendingAction == nil)

-- Malformed nested values are repaired from defaults.  The requested torch
-- side is also moved off the seal side when sealing is enabled.
fs.delete(common.CONFIG_PATH)
fs.delete(common.CONFIG_PATH .. ".bak")
local malformed = {
  role = "worker",
  networkKey = "short",
  workerName = 99,
  profile = "unknown",
  waterMode = "bad",
  maxWidth = "wide",
  reserveEmptySlots = 99,
  sealSide = "left",
  torchSide = "left",
  lighting = {
    mode = "invalid",
    interval = -2,
    preferredSlots = { 13, 13 },
    torchBlocks = { ["minecraft:torch"] = 1 },
    side = "left",
  },
  materials = {
    sealSlots = { 1, 1 },
    torchSlots = { 0 },
    fuelReserveSlots = "not-a-list",
  },
  alerts = { enabled = "yes", redstoneSide = "invalid", cooldownSeconds = -1 },
  gps = { enabled = "yes", timeout = -1, calibration = "not-a-table" },
}
local malformedText = textutils.serialize(malformed)
local handle = assert(fs.open(common.CONFIG_PATH, "w"))
handle.write(malformedText)
handle.close()
local repaired, repairedError = common.loadConfig()
assert(not repairedError, repairedError)
assert(repaired.role == "worker" and repaired.schema == 3 and repaired.version == "3.0.0")
assert(repaired.networkKey == "CHANGE_ME" and repaired.workerName == worker.workerName)
assert(repaired.profile == "balanced" and repaired.waterMode == "seal")
assert(repaired.maxWidth == worker.maxWidth and repaired.reserveEmptySlots == worker.reserveEmptySlots)
assert(repaired.sealSide == "left" and repaired.lighting.side == "right" and repaired.torchSide == "right")
assert(repaired.lighting.mode == "safe" and repaired.lighting.interval == 10)
assert(repaired.lighting.preferredSlots[1] == 15 and repaired.lighting.preferredSlots[2] == 16)
assert(repaired.lighting.torchBlocks["minecraft:torch"] == true)
assert(repaired.materials.sealSlots[1] == 13 and repaired.materials.sealSlots[2] == 14)
assert(repaired.materials.torchSlots[1] == 15 and repaired.materials.torchSlots[2] == 16)
assert(repaired.alerts.enabled == true and repaired.alerts.redstoneSide == "back" and repaired.alerts.cooldownSeconds == 10)
assert(repaired.gps.enabled == true and repaired.gps.timeout == 2 and repaired.gps.calibration == nil)

-- Controller nested enum repair and independent profile defaults.
local controllerRaw = {
  role = "controller",
  profile = "not-a-controller-field",
  touchEnabled = "yes",
  monitorTextScale = 0.75,
  alerts = { speaker = "yes", redstoneSide = "diagonal" },
  presets = {
    safe = { profile = "nope", waterMode = "bad", maxContinuousSeal = 0 },
    balanced = { profile = "turbo", waterMode = "stop", maxContinuousSeal = 7 },
  },
}
fs.delete(common.CONFIG_PATH)
handle = assert(fs.open(common.CONFIG_PATH, "w"))
handle.write(textutils.serialize(controllerRaw))
handle.close()
local controller, controllerError = common.loadConfig()
assert(not controllerError, controllerError)
assert(controller.role == "controller" and controller.schema == 3)
assert(controller.touchEnabled == true and controller.monitorTextScale == 0.5)
assert(controller.alerts.speaker == true and controller.alerts.redstoneSide == "back")
assert(controller.presets.safe.profile == "safe" and controller.presets.safe.waterMode == "stop")
assert(controller.presets.balanced.profile == "turbo" and controller.presets.balanced.waterMode == "stop")
assert(controller.presets.balanced.maxContinuousSeal == 7)
assert(controller.presets.turbo.profile == "turbo" and controller.presets.turbo.waterMode == "seal")

print("common V3 defaults, normalization, persistence, and portable fs tests passed")
