-- CC Miner V4 - interactive configuration

local args = { ... }
local common = dofile("/ccminer/lib/common.lua")
local current = common.loadConfig()
local requestedRole = string.lower(tostring(args[1] or (current and current.role) or ""))

-- Setup is intentionally forgiving when it reads a hand-edited/old config:
-- malformed values are replaced by a safe default before they are passed to
-- the interactive validators.  This prevents an invalid stored default from
-- trapping a user in a prompt loop while preserving every valid old value.
local function validInteger(value, fallback, minimum, maximum)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) then return fallback end
  if minimum and number < minimum then return fallback end
  if maximum and number > maximum then return fallback end
  return number
end

local function validNumber(value, fallback, minimum, maximum)
  local number = tonumber(value)
  if not number then return fallback end
  if minimum and number < minimum then return fallback end
  if maximum and number > maximum then return fallback end
  return number
end

local function ensureTable(config, key, defaults)
  if type(config[key]) ~= "table" then config[key] = common.copy(defaults) end
  config[key] = common.merge(defaults, config[key])
  return config[key]
end

local function enumPrompt(label, defaultValue, values, fallback)
  local normalized = string.lower(common.trim(tostring(defaultValue or "")))
  if not values[normalized] then
    fallback = string.lower(common.trim(tostring(fallback or "")))
    if values[fallback] then
      normalized = fallback
    else
      local options = {}
      for value in pairs(values) do options[#options + 1] = value end
      table.sort(options)
      normalized = options[1]
    end
  end
  return string.lower(common.prompt(label, normalized, function(value)
    value = string.lower(common.trim(value))
    if values[value] then return true end
    local options = {}
    for option in pairs(values) do options[#options + 1] = option end
    table.sort(options)
    return false, "Enter one of: " .. table.concat(options, "/") .. "."
  end))
end

local function sidePrompt(label, defaultValue)
  return enumPrompt(label, defaultValue or "back", {
    front = true, back = true, left = true, right = true, top = true, bottom = true,
  }, "back")
end

local function torchSidePrompt(defaultValue, sealSide)
  local choices = { left = true, right = true }
  local safeSide = sealSide == "left" and "right" or "left"
  local side = enumPrompt("Torch chest side (left/right)", defaultValue or safeSide, choices, safeSide)
  if sealSide and side == sealSide then
    print("Warning: torch chest side must not match the seal-block chest side.")
    local fallback = safeSide
    repeat
      side = enumPrompt("Re-select torch chest side", fallback, choices, fallback)
      if side == sealSide then print("Warning: choose a side different from " .. sealSide .. ".") end
    until side ~= sealSide
  end
  return side
end

local function peripheralNamePrompt(label, defaultValue)
  local fallback = type(defaultValue) == "string" and defaultValue or ""
  return common.prompt(label, fallback, function(value)
    if #value > 64 or value:find("[%c]") then return false, "Use 0 to 64 printable characters." end
    if #value == 0 then return false, "Enter a peripheral name." end
    return true
  end)
end

local function identifierPrompt(label, defaultValue, fallback)
  local safeDefault = type(defaultValue) == "string" and defaultValue or fallback
  return common.prompt(label, safeDefault, function(value)
    if #value < 1 or #value > 64 or value:find("[%c%s]") then
      return false, "Use 1 to 64 non-space characters."
    end
    return true
  end)
end

local function discardModePrompt(defaultValue)
  local value = string.upper(common.trim(tostring(defaultValue or "KEEP_ALL")))
  local allowed = {
    KEEP_ALL = true,
    DISCARD_EXCESS_STONE = true,
    CUSTOM_ALLOWLIST = true,
  }
  if not allowed[value] then value = "KEEP_ALL" end
  value = common.prompt("Discard mode (KEEP_ALL/DISCARD_EXCESS_STONE/CUSTOM_ALLOWLIST)", value, function(text)
    text = string.upper(common.trim(text))
    if allowed[text] then return true end
    return false, "Enter KEEP_ALL, DISCARD_EXCESS_STONE, or CUSTOM_ALLOWLIST."
  end)
  return string.upper(common.trim(value))
end

local function allowlistText(value)
  local names = {}
  if type(value) == "table" then
    for name, enabled in pairs(value) do
      if enabled == true then names[#names + 1] = tostring(name) end
    end
  end
  table.sort(names)
  return table.concat(names, ",")
end

local function allowlistPrompt(defaultValue)
  local text = common.prompt("Discard allowlist (item IDs, comma-separated; blank=none)", allowlistText(defaultValue), function(value)
    if #value > 2048 or value:find("[%c]") then return false, "Use comma-separated item IDs only." end
    if value ~= "" and (value:match("^[,;]") or value:match("[,;]$") or value:find("[,;][,;]")) then
      return false, "Do not leave empty entries in the allowlist."
    end
    for item in value:gmatch("[^,;]+") do
      local trimmed = common.trim(item)
      if trimmed ~= item then return false, "Do not include spaces around item IDs." end
      item = trimmed
      if item == "" or #item > 128 or not item:match("^[a-z0-9_.%-]+:[a-z0-9_./%-]+$") then
        return false, "Use complete item IDs such as minecraft:stone (no wildcard or partial names)."
      end
    end
    return true
  end)
  local out = {}
  for item in text:gmatch("[^,;]+") do
    item = common.trim(item)
    if item ~= "" then out[item] = true end
  end
  return out
end

if requestedRole ~= "worker" and requestedRole ~= "controller" and requestedRole ~= "gps" then
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("CC MINER " .. tostring(common.VERSION) .. " SETUP")
  print("")
  print("1. Worker (mining turtle)")
  print("2. Controller (computer + touch monitor)")
  print("3. GPS host (computer + wireless modem)")
  print("")
  local choice = common.promptNumber("Role", turtle and 1 or 2, 1, 3)
  requestedRole = choice == 1 and "worker" or choice == 2 and "controller" or "gps"
end

if requestedRole == "worker" and not turtle then error("Worker role can only be configured on a turtle.", 0) end
if requestedRole == "gps" and turtle then print("Warning: use a stationary computer for a GPS host.") end

common.clear(colors and colors.black or nil, colors and colors.white or nil)
print("CC MINER " .. tostring(common.VERSION) .. " SETUP - " .. string.upper(requestedRole))
print("")

local config
if requestedRole == "gps" then
  config = common.merge(common.defaultGPSConfig(), current and current.role == "gps" and current or {})
  config.role = "gps"
  config.gpsName = common.prompt("GPS host name", config.gpsName or common.safeComputerLabel("GPS"), function(value)
    return #value >= 1 and #value <= 20, "Use 1 to 20 characters."
  end)
  print("Enter the WORLD coordinates of the wireless modem block.")
  print("GPS needs at least four hosts at different 3D positions.")
  config.x = common.promptNumber("World X", config.x or 0, -30000000, 30000000)
  config.y = common.promptNumber("World Y", config.y or 0, -2048, 2048)
  config.z = common.promptNumber("World Z", config.z or 0, -30000000, 30000000)
  if os.setComputerLabel then os.setComputerLabel(config.gpsName) end
else
  print("All workers and the controller must use the SAME network key.")
  print("Use only ASCII letters, numbers, '-' and '_'.")
  print("")
  local previousKey = current and current.networkKey
  if previousKey == "CHANGE_ME" then previousKey = nil end
  local key = common.prompt("Network key", previousKey or common.randomToken(16), function(value)
    if #value < 8 or #value > 40 then return false, "Use 8 to 40 characters." end
    if value:find("[^%w_-]") then return false, "Use only letters, numbers, '-' and '_'." end
    return true
  end)

  if requestedRole == "worker" then
    config = common.merge(common.defaultWorkerConfig(), current and current.role == "worker" and current or {})
    config.role, config.networkKey = "worker", key
    local workerDefaults = common.defaultWorkerConfig()
    local discard = ensureTable(config, "discard", workerDefaults.discard)
    local performance = ensureTable(config, "performance", workerDefaults.performance)
    local dock = ensureTable(config, "dock", workerDefaults.dock)
    local group = ensureTable(config, "group", workerDefaults.group)
    local lighting = ensureTable(config, "lighting", workerDefaults.lighting)
    local materials = ensureTable(config, "materials", workerDefaults.materials)
    ensureTable(config, "service", workerDefaults.service)
    local journal = ensureTable(config, "journal", workerDefaults.journal)
    ensureTable(config, "alerts", workerDefaults.alerts)
    config.profile = enumPrompt("Operating profile (safe/balanced/turbo)", config.profile or "balanced", {
      safe = true, balanced = true, turbo = true,
    }, "balanced")
    config.waterMode = enumPrompt("Water behavior (ignore/stop/seal)", config.waterMode or "seal", {
      ignore = true, stop = true, seal = true,
    }, "seal")
    config.maxContinuousSeal = common.promptNumber(
      "Maximum continuous fluid seals",
      validInteger(config.maxContinuousSeal, 32, 1, 4096),
      1,
      4096
    )
    config.workerName = common.prompt("Worker name", config.workerName or common.safeComputerLabel("Miner"), function(value)
      return #value >= 1 and #value <= 20, "Use 1 to 20 characters."
    end)
    config.fuelTarget = common.promptNumber("Fuel target", validInteger(config.fuelTarget, 12000, 500, 100000), 500, 100000)
    config.reserveEmptySlots = common.promptNumber("Reserved empty slots", validInteger(config.reserveEmptySlots, 3, 1, 8), 1, 8)

    -- Disposal is deliberately a short, explicit safety wizard.  KEEP_ALL is
    -- the default; the stone mode keeps only its built-in stone candidates,
    -- while CUSTOM_ALLOWLIST considers only complete IDs entered by the user.
    discard.mode = discardModePrompt(discard.mode)
    if discard.mode == "CUSTOM_ALLOWLIST" then
      discard.allowlist = allowlistPrompt(discard.allowlist)
    else
      discard.allowlist = type(discard.allowlist) == "table" and discard.allowlist or {}
    end
    discard.retainSealTarget = validInteger(discard.retainSealTarget or config.retainSealTarget, 64, 1, 512)
    discard.triggerEmptySlots = common.promptNumber(
      "Discard when empty slots reach",
      validInteger(discard.triggerEmptySlots, config.reserveEmptySlots or 3, 0, 16),
      0,
      16
    )
    print("設定方向に inventory が見つかった場合は、誤投入防止のため world 廃棄をスキップします。")
    discard.direction = enumPrompt("現場廃棄方向 (front/back/left/right/top/bottom)", discard.direction or config.outputSide or "back", {
      front = true, back = true, left = true, right = true, top = true, bottom = true,
    }, "back")
    discard.maxStacksPerPass = validInteger(discard.maxStacksPerPass, 8, 1, 64)
    config.retainSealTarget = discard.retainSealTarget
    materials.retainSealTarget = discard.retainSealTarget
    materials.discard = common.copy(discard)

    -- Dock/group identity is intentionally simple for first-time users.  GPS
    -- calibration later fills homeWorld/facing; existing calibration is copied
    -- here so a setup rerun cannot erase it.
    dock.id = identifierPrompt("Dock ID", dock.id, "main")
    dock.groupId = identifierPrompt("Worker group ID", dock.groupId, "default")
    dock.bayId = identifierPrompt("Dock bay ID", dock.bayId, "main")
    dock.requireSameFloor = common.promptYesNo("Require same-floor dock checks", dock.requireSameFloor ~= false)
    dock.sameFloor, dock.verifySameFloor = dock.requireSameFloor, dock.requireSameFloor
    group.id, group.groupId = dock.groupId, dock.groupId
    if type(config.gps) == "table" and config.gps.calibration and config.gps.calibration.home then
      dock.homeWorld = common.copy(config.gps.calibration.home)
    end
    config.lavaMode = enumPrompt("Lava behavior (seal/stop)", config.lavaMode or "seal", {
      seal = true, stop = true,
    }, "seal")
    if config.lavaMode == "seal" then
      config.sealSide = enumPrompt("Seal-block chest side (right/left)", config.sealSide or "right", {
        right = true, left = true,
      }, "right")
      config.sealTarget = common.promptNumber("Seal-block target count", validInteger(config.sealTarget, 64, 16, 512), 16, 512)
      local reserveMaximum = math.min(64, config.sealTarget - 1)
      config.sealReserve = common.promptNumber("Return when seal blocks reach", validInteger(config.sealReserve, 8, 1, reserveMaximum), 1, reserveMaximum)
    end
    lighting.mode = enumPrompt("Lighting mode (off/safe/custom)", lighting.mode or "safe", {
      off = true, safe = true, custom = true,
    }, "safe")
    if lighting.mode == "custom" then
      lighting.interval = common.promptNumber("Torch interval (moves)", validInteger(lighting.interval, 10, 1, 4096), 1, 4096)
      lighting.temporaryFloor = common.promptYesNo("Use temporary lighting floor", lighting.temporaryFloor ~= false)
      lighting.torchTarget = common.promptNumber("Torch target count", validInteger(lighting.torchTarget, 64, 1, 512), 1, 512)
      local torchReserveMaximum = math.min(128, lighting.torchTarget - 1)
      lighting.torchReserve = common.promptNumber("Return when torches reach", validInteger(lighting.torchReserve, 8, 0, torchReserveMaximum), 0, torchReserveMaximum)
    end
    if lighting.mode ~= "off" then
      lighting.side = torchSidePrompt(lighting.side or config.torchSide or "left", config.lavaMode == "seal" and config.sealSide or nil)
      config.torchSide = lighting.side
    else
      lighting.side = lighting.side or config.torchSide or "left"
      config.torchSide = lighting.side
    end
    materials.compactEveryMoves = validInteger(materials.compactEveryMoves, 32, 1, 100000)
    materials.retainSealTarget = validInteger(materials.retainSealTarget, 64, 1, 512)
    materials.retainSealTarget = discard.retainSealTarget
    config.retainSealTarget = discard.retainSealTarget
    materials.discard = common.copy(discard)
    materials.recycleMinedBlocks = common.promptYesNo("Recycle mined blocks", materials.recycleMinedBlocks ~= false)
    journal.checkpointEvery = validInteger(journal.checkpointEvery, 32, 1, 100000)
    journal.maxEntries = validInteger(journal.maxEntries, 256, 1, 10000)
    journal.enabled = common.promptYesNo("Enable resumable journal", journal.enabled ~= false)
    performance.gpsVerifyEveryMoves = validInteger(performance.gpsVerifyEveryMoves, 32, 32, 64)
    performance.gpsVerifyMoves = performance.gpsVerifyEveryMoves
    performance.gpsVerifyCadence = performance.gpsVerifyEveryMoves
    performance.lightweightCheckpointEveryMoves = validInteger(
      performance.lightweightCheckpointEveryMoves,
      16,
      1,
      100000
    )
    performance.lightweightCheckpointCadence = performance.lightweightCheckpointEveryMoves
    performance.journalEveryMoves = performance.lightweightCheckpointEveryMoves
    performance.checkpointEveryMoves = validInteger(performance.checkpointEveryMoves, journal.checkpointEvery, 1, 100000)
    performance.checkpointCadence = performance.checkpointEveryMoves
    config.gps = ensureTable(config, "gps", workerDefaults.gps)
    config.gps.enabled = common.promptYesNo("Use GPS when available", config.gps.enabled ~= false)
    if config.gps.enabled then
      config.gps.required = common.promptYesNo("Require GPS for mining", config.gps.required == true)
    else
      config.gps.required = false
    end
    config.gps.verifyEveryMoves = performance.gpsVerifyEveryMoves
    if config.gps.calibration and common.promptYesNo("Clear stored GPS calibration for a relocated dock", false) then
      config.gps.calibration = nil
      dock.homeWorld = { x = nil, y = nil, z = nil }
    end
    config.attackEntities = common.promptYesNo("Attack blocking entities", config.attackEntities == true)
    config.outputSide, config.fuelSide = "back", "top"
    if os.setComputerLabel then os.setComputerLabel(config.workerName) end
  else
    config = common.merge(common.defaultControllerConfig(), current and current.role == "controller" and current or {})
    config.role, config.networkKey = "controller", key
    local controllerDefaults = common.defaultControllerConfig()
    local group = ensureTable(config, "group", controllerDefaults.group)
    local dock = ensureTable(config, "dock", controllerDefaults.dock)
    local alerts = ensureTable(config, "alerts", controllerDefaults.alerts)
    config.historyLimit = common.promptNumber("History entries to retain", validInteger(config.historyLimit, 50, 1, 1000), 1, 1000)
    config.queueEnabled = common.promptYesNo("Enable job queue", config.queueEnabled ~= false)
    config.overlapProtection = common.promptYesNo("Protect overlapping jobs", config.overlapProtection ~= false)
    config.adaptiveRefresh = common.promptYesNo("Enable adaptive refresh", config.adaptiveRefresh ~= false)
    -- Keep group setup approachable: one worker-capacity value, one service
    -- concurrency value, and an explicit GPS safety gate for partitioning.
    group.maxWorkers = common.promptNumber("Maximum workers in a group", validInteger(group.maxWorkers, 16, 1, 256), 1, 256)
    group.maxConcurrentService = common.promptNumber(
      "Maximum concurrent service returns",
      validInteger(group.maxConcurrentService, 1, 1, 64),
      1,
      64
    )
    group.partitionMode = enumPrompt("Partition mode (stripe/round_robin)", group.partitionMode or "stripe", {
      stripe = true, round_robin = true,
    }, "stripe")
    group.requireGpsForPartition = common.promptYesNo(
      "Require GPS for multi-worker partitioning",
      group.requireGpsForPartition ~= false
    )
    dock.baySpacing = common.promptNumber("Dock bay spacing", validInteger(dock.baySpacing, 4, 1, 256), 1, 256)
    dock.requireSameFloor = common.promptYesNo("Require same-floor dock checks", dock.requireSameFloor ~= false)
    local sorting = ensureTable(config, "sorting", controllerDefaults.sorting)
    sorting.enabled = common.promptYesNo("Enable automatic item sorting", sorting.enabled == true)
    if sorting.enabled then
      sorting.interval = common.promptNumber("Sorting interval (seconds)", validInteger(sorting.interval, 30, 1, 86400), 1, 86400)
      sorting.source = peripheralNamePrompt("Sorting source inventory", sorting.source)
      sorting.valuableTarget = peripheralNamePrompt("Valuable-items inventory", sorting.valuableTarget)
      sorting.bulkTarget = peripheralNamePrompt("Bulk-items inventory", sorting.bulkTarget)
      sorting.sealTarget = peripheralNamePrompt("Seal-block inventory", sorting.sealTarget)
    end
    config.controllerName = common.prompt("Controller name", config.controllerName or common.safeComputerLabel("Control"), function(value)
      return #value >= 1 and #value <= 20, "Use 1 to 20 characters."
    end)
    config.monitorTextScale = tonumber(common.prompt("Monitor text scale", validNumber(config.monitorTextScale, 0.5, 0.5, 5), function(value)
      local number = tonumber(value)
      if not number or number < 0.5 or number > 5 or number * 2 ~= math.floor(number * 2) then
        return false, "Use 0.5, 1.0, 1.5 ... 5.0."
      end
      return true
    end))
    config.touchEnabled = common.promptYesNo("Enable monitor touch controls", config.touchEnabled ~= false)
    alerts.enabled = common.promptYesNo("Enable controller alerts", alerts.enabled ~= false)
    if alerts.enabled then
      alerts.speaker = common.promptYesNo("Use speaker alerts", alerts.speaker ~= false)
      alerts.redstone = common.promptYesNo("Use redstone alerts", alerts.redstone ~= false)
      if alerts.redstone then alerts.redstoneSide = sidePrompt("Redstone alert side", alerts.redstoneSide or "back") end
      alerts.cooldownSeconds = common.promptNumber(
        "Alert cooldown (seconds)",
        validInteger(alerts.cooldownSeconds, 10, 0, 3600),
        0,
        3600
      )
    else
      -- Keep disabled outputs explicit so old controllers do not emit a
      -- notification merely because a peripheral was attached later.
      alerts.speaker, alerts.redstone = false, false
    end
    if os.setComputerLabel then os.setComputerLabel(config.controllerName) end
  end
end

local ok, err = common.saveConfig(config)
if not ok then error("Cannot save configuration: " .. tostring(err), 0) end

if requestedRole == "worker" and (not fs.exists(common.STATE_PATH) or not current or current.role ~= "worker") then
  common.saveTable(common.STATE_PATH, common.defaultState())
end

-- Keep the legacy marker: treating an existing V2 startup as user-owned
-- during update would make the new startup wrapper invoke itself recursively.
local startupMarker = "-- CC_MINER_V2_STARTUP"
local existingStartup = fs.exists("/startup.lua") and common.readAll("/startup.lua") or nil
if existingStartup and not existingStartup:find(startupMarker, 1, true) then
  local backupOk, backupError = common.writeAllAtomic("/startup.user.lua", existingStartup)
  if not backupOk then error("Cannot preserve existing startup.lua: " .. tostring(backupError), 0) end
end

local startup = startupMarker .. "\n" .. [[
if fs.exists("/startup.user.lua") then
  local ok, err = pcall(function() shell.run("/startup.user.lua") end)
  if not ok then printError("User startup failed: " .. tostring(err)) end
end
shell.run("/ccminer/boot.lua")
]]
local startupOk, startupError = common.writeAllAtomic("/startup.lua", startup)
if not startupOk then error("Cannot install startup.lua: " .. tostring(startupError), 0) end
local commandOk, commandError = common.writeAllAtomic("/ccm.lua", [[
shell.run("/ccminer/command.lua", ...)
]])
if not commandOk then error("Cannot install ccm.lua: " .. tostring(commandError), 0) end

common.clear(colors and colors.black or nil, colors and colors.white or nil)
print("SETUP COMPLETE")
print("")
print("Role: " .. requestedRole)
if requestedRole == "worker" then
  print("Output chest: BEHIND the turtle")
  print("Fuel chest: ABOVE the turtle")
  if config.lavaMode == "seal" then print("Seal-block chest: " .. string.upper(config.sealSide) .. " of the turtle") end
  if config.lighting and config.lighting.mode ~= "off" then
    print("Torch chest: " .. string.upper(config.lighting.side or config.torchSide or "left") .. " of the turtle")
  end
  print("Turtle front: quarry entrance")
  if config.gps.enabled then print("After GPS hosts are online: controller -> GPS CAL") end
elseif requestedRole == "controller" then
  print("Attach a wireless modem and optional Advanced Monitor.")
  print("Monitor touches and terminal mouse clicks are enabled.")
else
  print(("GPS host coordinates: %d, %d, %d"):format(config.x, config.y, config.z))
  print("Keep this computer and its wireless modem chunk-loaded.")
end
print("")
print("Reboot with: reboot")
