-- CC Miner V3 - shared helpers
-- Compatible with CC: Restitched / CC:Tweaked 1.100.x (Minecraft 1.18.2).

local M = {}

M.VERSION = "3.0.0"
M.SCHEMA = 3
M.ROOT = "/ccminer"
M.CONFIG_PATH = M.ROOT .. "/config.db"
M.STATE_PATH = M.ROOT .. "/data/state.db"
M.LOG_PATH = M.ROOT .. "/data/ccminer.log"
-- Keep the legacy wire identifiers stable; the release version is carried
-- separately in each message and advances with the V3 release.
M.PROTOCOL = "ccminer:v2"
M.MAGIC = "CCMINER_V2"

local function nowMillis()
  if os.epoch then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return value end
  end
  return math.floor((os.clock() or 0) * 1000)
end

M.nowMillis = nowMillis

function M.nowSeconds()
  return math.floor(nowMillis() / 1000)
end

function M.timestamp()
  if os.date then
    local ok, value = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if ok and value then return value end
  end
  return tostring(M.nowSeconds())
end

function M.copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do out[M.copy(key, seen)] = M.copy(item, seen) end
  return out
end

function M.merge(defaults, loaded)
  local out = M.copy(defaults or {})
  if type(loaded) ~= "table" then return out end
  for key, value in pairs(loaded) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = M.merge(out[key], value)
    else
      out[key] = M.copy(value)
    end
  end
  return out
end

function M.tableCount(value)
  local count = 0
  if type(value) == "table" then for _ in pairs(value) do count = count + 1 end end
  return count
end

function M.sortedKeys(value)
  local keysOut = {}
  for key in pairs(value or {}) do keysOut[#keysOut + 1] = key end
  table.sort(keysOut, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keysOut
end

function M.ensureDir(path)
  if not path or path == "" then return true end
  if fs.exists(path) then return fs.isDir(path) end
  local parent = fs.getDir(path)
  if parent and parent ~= "" and parent ~= path then M.ensureDir(parent) end
  fs.makeDir(path)
  return fs.exists(path) and fs.isDir(path)
end

function M.readAll(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, "File not found: " .. tostring(path) end
  local handle = fs.open(path, "r")
  if not handle then return nil, "Cannot open: " .. tostring(path) end
  local text = handle.readAll()
  handle.close()
  return text
end

function M.writeAllAtomic(path, text)
  local dir = fs.getDir(path)
  if dir and dir ~= "" then M.ensureDir(dir) end
  local temp, backup = path .. ".tmp", path .. ".bak"
  if fs.exists(temp) then fs.delete(temp) end
  local handle = fs.open(temp, "w")
  if not handle then return false, "Cannot open temporary file: " .. temp end
  handle.write(text or "")
  handle.close()

  local hadCurrent = fs.exists(path)
  if hadCurrent then
    if fs.exists(backup) then fs.delete(backup) end
    local movedOld, moveOldError = pcall(fs.move, path, backup)
    if not movedOld then
      fs.delete(temp)
      return false, "Cannot rotate previous file: " .. tostring(moveOldError)
    end
  end

  local movedNew, moveNewError = pcall(fs.move, temp, path)
  if not movedNew or not fs.exists(path) then
    if fs.exists(path) then fs.delete(path) end
    local restored, restoreError = true, nil
    if hadCurrent then
      if fs.exists(backup) then
        restored, restoreError = pcall(fs.move, backup, path)
        restored = restored and fs.exists(path)
      else
        restored, restoreError = false, "Backup file is missing."
      end
    end
    if fs.exists(temp) then fs.delete(temp) end
    if not restored then
      return false, "Atomic move failed and backup restore failed: " .. tostring(moveNewError or path)
        .. "; restore: " .. tostring(restoreError or "destination missing")
    end
    return false, "Atomic move failed: " .. tostring(moveNewError or path)
  end
  return true
end

function M.saveTable(path, value)
  local ok, serialized = pcall(textutils.serialize, value)
  if not ok then return false, "Serialize failed: " .. tostring(serialized) end
  return M.writeAllAtomic(path, serialized)
end

function M.loadTable(path, fallback)
  local function decode(candidate)
    if not fs.exists(candidate) or fs.isDir(candidate) then return nil, "missing" end
    local text, readError = M.readAll(candidate)
    if not text then return nil, readError end
    local ok, value = pcall(textutils.unserialize, text)
    if not ok or type(value) ~= "table" then return nil, "invalid" end
    return value, nil, text
  end

  local value, err = decode(path)
  if value then return value, nil end
  local recovered, backupError, backupText = decode(path .. ".bak")
  if recovered then
    if fs.exists(path) then fs.delete(path) end
    M.writeAllAtomic(path, backupText)
    return recovered, nil
  end
  if err == "missing" and backupError == "missing" then return M.copy(fallback), nil end
  return M.copy(fallback), "Invalid table data: " .. path
end

function M.rotateLog(path, maxBytes)
  maxBytes = tonumber(maxBytes) or 65536
  if not fs.exists(path) or fs.isDir(path) or fs.getSize(path) < maxBytes then return end
  local old = path .. ".1"
  if fs.exists(old) then fs.delete(old) end
  fs.move(path, old)
end

function M.log(level, message, path)
  path = path or M.LOG_PATH
  M.ensureDir(fs.getDir(path))
  M.rotateLog(path, 65536)
  local handle = fs.open(path, "a")
  if handle then
    handle.writeLine(("[%s] %-5s %s"):format(M.timestamp(), tostring(level or "INFO"), tostring(message or "")))
    handle.close()
  end
end

function M.clamp(value, minimum, maximum)
  value = tonumber(value) or minimum
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

function M.round(value)
  value = tonumber(value) or 0
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
end

function M.trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.startsWith(text, prefix)
  text, prefix = tostring(text or ""), tostring(prefix or "")
  return text:sub(1, #prefix) == prefix
end

function M.endsWith(text, suffix)
  text, suffix = tostring(text or ""), tostring(suffix or "")
  if suffix == "" then return true end
  return text:sub(-#suffix) == suffix
end

function M.fit(text, width)
  text = tostring(text or "")
  width = math.max(0, tonumber(width) or 0)
  if #text > width then
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
  end
  return text .. string.rep(" ", width - #text)
end

function M.center(text, width)
  text = tostring(text or "")
  width = tonumber(width) or #text
  if #text >= width then return text:sub(1, width) end
  local left = math.floor((width - #text) / 2)
  return string.rep(" ", left) .. text .. string.rep(" ", width - #text - left)
end

function M.percent(done, total)
  done, total = tonumber(done) or 0, tonumber(total) or 0
  if total <= 0 then return 0 end
  return M.clamp(math.floor((done / total) * 100 + 0.5), 0, 100)
end

function M.humanNumber(value)
  value = tonumber(value) or 0
  local absolute = math.abs(value)
  if absolute >= 1000000000 then return ("%.1fB"):format(value / 1000000000) end
  if absolute >= 1000000 then return ("%.1fM"):format(value / 1000000) end
  if absolute >= 1000 then return ("%.1fK"):format(value / 1000) end
  return tostring(math.floor(value))
end

function M.humanDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60
  if hours > 0 then return ("%dh %02dm %02ds"):format(hours, minutes, secs) end
  if minutes > 0 then return ("%dm %02ds"):format(minutes, secs) end
  return ("%ds"):format(secs)
end

function M.safeComputerLabel(defaultPrefix)
  local label = os.getComputerLabel and os.getComputerLabel() or nil
  if label and label ~= "" then return label end
  return (defaultPrefix or "CCMiner") .. "-" .. tostring(os.getComputerID())
end

function M.randomToken(length)
  length = M.clamp(length or 16, 8, 48)
  local seed = nowMillis() + (os.getComputerID and os.getComputerID() or 0) * 104729
  math.randomseed(seed)
  math.random(); math.random(); math.random()
  local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
  local out = {}
  for index = 1, length do
    local position = math.random(1, #alphabet)
    out[index] = alphabet:sub(position, position)
  end
  return table.concat(out)
end

function M.prompt(label, defaultValue, validator, secret)
  while true do
    if defaultValue ~= nil and tostring(defaultValue) ~= "" then
      write(("%s [%s]: "):format(label, tostring(defaultValue)))
    else
      write(label .. ": ")
    end
    local value = read(secret and "*" or nil)
    value = M.trim(value)
    if value == "" and defaultValue ~= nil then value = tostring(defaultValue) end
    if not validator then return value end
    local ok, message = validator(value)
    if ok then return value end
    if printError then printError(message or "Invalid value") else print(message or "Invalid value") end
  end
end

function M.promptNumber(label, defaultValue, minimum, maximum)
  local value = M.prompt(label, defaultValue, function(text)
    local number = tonumber(text)
    if not number or number ~= math.floor(number) then return false, "Enter a whole number." end
    if minimum and number < minimum then return false, "Minimum: " .. tostring(minimum) end
    if maximum and number > maximum then return false, "Maximum: " .. tostring(maximum) end
    return true
  end)
  return tonumber(value)
end

function M.promptYesNo(label, defaultValue)
  local value = M.prompt(label .. " (y/n)", defaultValue and "Y" or "N", function(text)
    text = string.lower(M.trim(text))
    return text == "y" or text == "yes" or text == "n" or text == "no", "Enter y or n."
  end)
  value = string.lower(value)
  return value == "y" or value == "yes"
end

function M.openWirelessModems()
  local opened = {}
  if not peripheral or not rednet then return opened end
  for _, name in ipairs(peripheral.getNames()) do
    local isModem = peripheral.getType(name) == "modem"
    if not isModem and peripheral.hasType then
      local ok, result = pcall(peripheral.hasType, name, "modem")
      isModem = ok and result
    end
    if isModem then
      local wrapped = peripheral.wrap(name)
      local wireless = false
      if wrapped and wrapped.isWireless then
        local ok, result = pcall(wrapped.isWireless)
        wireless = ok and result == true
      end
      if wireless then
        local ok = pcall(rednet.open, name)
        if ok then opened[#opened + 1] = name end
      end
    end
  end
  return opened
end

function M.findPeripherals(peripheralType)
  local found = {}
  if not peripheral then return found end
  for _, name in ipairs(peripheral.getNames()) do
    local matches = peripheral.getType(name) == peripheralType
    if not matches and peripheral.hasType then
      local ok, result = pcall(peripheral.hasType, name, peripheralType)
      matches = ok and result == true
    end
    if matches then found[#found + 1] = { name = name, device = peripheral.wrap(name) } end
  end
  table.sort(found, function(a, b) return a.name < b.name end)
  return found
end

function M.findPeripheral(peripheralType, preferredName)
  local all = M.findPeripherals(peripheralType)
  if preferredName and preferredName ~= "" then
    for _, entry in ipairs(all) do if entry.name == preferredName then return entry.device, entry.name end end
  end
  if all[1] then return all[1].device, all[1].name end
  return nil, nil
end

function M.isInventorySide(side)
  if not peripheral or not side then return false end
  local wrapped = peripheral.wrap(side)
  if not wrapped then return false end
  return type(wrapped.list) == "function" or type(wrapped.size) == "function"
end

function M.withTerm(target, callback)
  if not target or not term or not term.redirect then return callback() end
  local old = term.redirect(target)
  local ok, a, b, c = pcall(callback)
  term.redirect(old)
  if not ok then error(a, 0) end
  return a, b, c
end

function M.setColors(background, foreground)
  if term and term.isColor and term.isColor() then
    if background and term.setBackgroundColor then term.setBackgroundColor(background) end
    if foreground and term.setTextColor then term.setTextColor(foreground) end
  end
end

function M.clear(background, foreground)
  M.setColors(background, foreground)
  term.clear()
  term.setCursorPos(1, 1)
end

function M.writeAt(x, y, text, foreground, background)
  if background and term.isColor and term.isColor() then term.setBackgroundColor(background) end
  if foreground and term.isColor and term.isColor() then term.setTextColor(foreground) end
  term.setCursorPos(math.max(1, x), math.max(1, y))
  term.write(tostring(text or ""))
end

function M.statusColor(status)
  if not colors then return nil end
  local map = {
    idle = colors.lightGray,
    working = colors.lime,
    calibrating = colors.lightBlue,
    paused = colors.yellow,
    waiting_fuel = colors.orange,
    waiting_output = colors.orange,
    waiting_seal = colors.orange,
    dormant = colors.gray,
    waiting_torch = colors.orange,
    waiting_water = colors.blue,
    recovering = colors.lightBlue,
    blocked = colors.red,
    complete = colors.cyan,
    aborted = colors.red,
    offline = colors.gray,
    hosting = colors.lime,
  }
  return map[status] or colors.white
end

function M.defaultWorkerConfig()
  return {
    schema = M.SCHEMA,
    version = M.VERSION,
    role = "worker",
    networkKey = "CHANGE_ME",
    workerName = M.safeComputerLabel("Miner"),
    controllerId = 0,
    reserveEmptySlots = 3,
    fuelBuffer = 256,
    fuelTarget = 12000,
    moveRetries = 20,
    moveRetryDelay = 0.4,
    heartbeatSeconds = 2,
    attackEntities = false,
    -- V3 operating profile.  These fields are additive so a V2 config can
    -- still be loaded and merged with the defaults below.
    profile = "balanced",
    waterMode = "seal",
    maxContinuousSeal = 32,
    maxWidth = 128,
    maxLength = 512,
    maxDepth = 128,
    maxVolume = 2000000,
    outputSide = "back",
    fuelSide = "top",
    -- Keep the torch chest separate from the output/seal chest by default.
    torchSide = "left",
    lavaMode = "seal",
    sealSide = "right",
    sealTarget = 64,
    sealReserve = 8,
    sealBlocks = {
      ["minecraft:cobblestone"] = true,
      ["minecraft:cobbled_deepslate"] = true,
      ["minecraft:stone"] = true,
      ["minecraft:netherrack"] = true,
      ["minecraft:dirt"] = true,
    },
    lighting = {
      mode = "safe",
      interval = 10,
      temporaryFloor = true,
      torchTarget = 64,
      torchReserve = 8,
      preferredSlots = { 15, 16 },
      torchBlocks = {
        ["minecraft:torch"] = true,
      },
      reserve = 8,
      -- Runtime compatibility knobs.  The V3 planner primarily uses the
      -- fields above; these make an explicitly configured side/slot safe for
      -- older worker code as well.
      slot = 16,
      side = "left",
    },
    materials = {
      sealSlots = { 13, 14 },
      torchSlots = { 15, 16 },
      fuelReserveSlots = { 12 },
      compactEveryMoves = 32,
      recycleMinedBlocks = true,
      retainSealTarget = 64,
    },
    service = {
      adaptive = true,
      finishCurrentChunk = true,
      stations = {},
    },
    journal = {
      enabled = true,
      checkpointEvery = 32,
      maxEntries = 256,
      path = M.ROOT .. "/data/state.journal",
    },
    alerts = {
      enabled = true,
      speaker = false,
      redstone = false,
      redstoneSide = "back",
      cooldownSeconds = 10,
      onWaiting = true,
      onComplete = true,
      onError = true,
    },
    gps = {
      enabled = true,
      required = false,
      timeout = 2,
      verifyEveryMoves = 16,
      autoResolvePending = true,
      calibration = nil,
    },
    protectedBlocks = {
      ["minecraft:bedrock"] = true,
      ["minecraft:end_portal"] = true,
      ["minecraft:end_portal_frame"] = true,
      ["minecraft:nether_portal"] = true,
      ["minecraft:reinforced_deepslate"] = true,
      ["computercraft:turtle_normal"] = true,
      ["computercraft:turtle_advanced"] = true,
      ["computercraft:computer_normal"] = true,
      ["computercraft:computer_advanced"] = true,
    },
  }
end

function M.defaultControllerConfig()
  return {
    schema = M.SCHEMA,
    version = M.VERSION,
    role = "controller",
    networkKey = "CHANGE_ME",
    controllerName = M.safeComputerLabel("Control"),
    workerTimeoutSeconds = 10,
    discoverySeconds = 5,
    monitorTextScale = 0.5,
    monitorName = "",
    touchEnabled = true,
    historyLimit = 50,
    queueEnabled = true,
    overlapProtection = true,
    adaptiveRefresh = true,
    alerts = {
      enabled = true,
      speaker = true,
      redstone = true,
      redstoneSide = "back",
      cooldownSeconds = 10,
    },
    presets = {
      safe = {
        profile = "safe",
        waterMode = "stop",
        maxContinuousSeal = 8,
      },
      balanced = {
        profile = "balanced",
        waterMode = "seal",
        maxContinuousSeal = 32,
      },
      turbo = {
        profile = "turbo",
        waterMode = "seal",
        maxContinuousSeal = 64,
      },
    },
    sorting = {
      enabled = false,
      interval = 30,
      source = "",
      valuableTarget = "",
      bulkTarget = "",
      sealTarget = "",
      valuableItems = {},
      sealBlocks = {
        ["minecraft:cobblestone"] = true,
        ["minecraft:cobbled_deepslate"] = true,
        ["minecraft:stone"] = true,
        ["minecraft:netherrack"] = true,
        ["minecraft:dirt"] = true,
      },
    },
  }
end

function M.defaultGPSConfig()
  return {
    schema = M.SCHEMA,
    version = M.VERSION,
    role = "gps",
    gpsName = M.safeComputerLabel("GPS"),
    x = 0,
    y = 0,
    z = 0,
  }
end

function M.defaultState()
  return {
    schema = M.SCHEMA,
    version = M.VERSION,
    status = "idle",
    phase = "home",
    pose = { x = 0, y = 0, z = 0, dir = 0 },
    gps = {
      available = false,
      lastFix = nil,
      lastFixAt = nil,
      lastError = nil,
      corrections = 0,
    },
    job = nil,
    checkpoint = nil,
    request = nil,
    service = nil,
    stagedStop = false,
    journal = {
      enabled = true,
      -- Compact runtime counters are retained alongside descriptive metadata.
      seq = 0,
      writes = 0,
      checkpoints = 0,
      sequence = 0,
      entries = 0,
      lastCheckpointAt = nil,
      lastCheckpointMove = 0,
      lastEntryAt = nil,
      lastError = nil,
      recovered = false,
    },
    lighting = {
      mode = "safe",
      interval = 10,
      temporaryFloor = true,
      placed = 0,
      torchesPlaced = 0,
      torchesRecovered = 0,
      torchRefills = 0,
      torchShortages = 0,
      shortages = 0,
      lastPlacedAt = nil,
      lastError = nil,
      lastAt = nil,
      lastPose = nil,
    },
    water = {
      mode = "seal",
      detected = 0,
      sealed = 0,
      blocked = 0,
      stopped = 0,
      ignored = 0,
      continuousSeals = 0,
      lastAt = nil,
      lastError = nil,
      last = nil,
      lastRun = 0,
    },
    recycle = {
      enabled = true,
      attempts = 0,
      recycled = 0,
      skipped = 0,
      held = 0,
      cap = 64,
      overflow = 0,
      compressed = 0,
      byName = {},
      lastAt = nil,
      lastError = nil,
    },
    serviceStats = {
      started = 0,
      completed = 0,
      interrupted = 0,
      moves = 0,
      adaptive = 0,
    },
    -- `report` is the current/last job report.  `jobReport` is kept as an
    -- explicit alias for controllers written against the V3 draft API.
    report = nil,
    lastReport = nil,
    jobReport = nil,
    estimate = { estimated = 0, actual = 0, variance = 0 },
    lastError = nil,
    completionReason = nil,
    pendingAction = nil,
    updatedAt = M.nowSeconds(),
    stats = {
      moves = 0,
      turns = 0,
      blocksDug = 0,
      lavaSealed = 0,
      gpsFixes = 0,
      gpsRecoveries = 0,
      unloads = 0,
      refuels = 0,
      sealRefills = 0,
      torchesPlaced = 0,
      torchesRecovered = 0,
      torchRefills = 0,
      torchShortages = 0,
      waterDetected = 0,
      waterSealed = 0,
      waterBlocked = 0,
      waterStopped = 0,
      waterIgnored = 0,
      recycledBlocks = 0,
      recycled = 0,
      recycleRuns = 0,
      sealOverflow = 0,
      compressions = 0,
      services = 0,
      serviceReturns = 0,
      serviceMoves = 0,
      journalRecoveries = 0,
      journalWrites = 0,
      powerRecoveries = 0,
      jobsStarted = 0,
      jobsAborted = 0,
      jobsFailed = 0,
      jobReports = 0,
      jobsCompleted = 0,
      startedAt = M.nowSeconds(),
    },
    recentCommands = {},
  }
end

local function normalizeEnum(value, allowed, fallback)
  value = string.lower(M.trim(value))
  return allowed[value] and value or fallback
end

local function normalizeInteger(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not value or value ~= math.floor(value) then return fallback end
  if minimum and value < minimum then return fallback end
  if maximum and value > maximum then return fallback end
  return value
end

local function normalizeNumber(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not value then return fallback end
  if minimum and value < minimum then return fallback end
  if maximum and value > maximum then return fallback end
  return value
end

local function normalizeBoolean(value, fallback)
  if type(value) == "boolean" then return value end
  return fallback
end

local function normalizeString(value, fallback, minimum, maximum)
  if type(value) ~= "string" then return fallback end
  if minimum and #value < minimum then return fallback end
  if maximum and #value > maximum then return fallback end
  return value
end

local function normalizePeripheralName(value, fallback)
  value = normalizeString(value, fallback, 0, 64)
  if type(value) ~= "string" then return "" end
  if value:find("[%c]") then return fallback or "" end
  return value
end

local function normalizeSlotList(value, fallback)
  if type(value) ~= "table" then return M.copy(fallback) end
  local out, seen = {}, {}
  for index = 1, #value do
    local slot = normalizeInteger(value[index], 1, 16, nil)
    if not slot or seen[slot] then return M.copy(fallback) end
    seen[slot] = true
    out[#out + 1] = slot
  end
  if #out == 0 and #fallback > 0 then return M.copy(fallback) end
  return out
end

local function normalizeBlockMap(value, fallback)
  if type(value) ~= "table" then return M.copy(fallback) end
  local out = {}
  for name, enabled in pairs(value) do
    if type(name) ~= "string" or type(enabled) ~= "boolean" then return M.copy(fallback) end
    out[name] = enabled
  end
  return out
end

local function normalizeTable(defaults, loaded)
  if type(loaded) ~= "table" then return M.copy(defaults) end
  return M.merge(defaults, loaded)
end

local function normalizeWorkerConfig(raw)
  local defaults = M.defaultWorkerConfig()
  local config = normalizeTable(defaults, raw)
  config.role = "worker"

  config.networkKey = normalizeString(config.networkKey, defaults.networkKey, 8, 40)
  config.workerName = normalizeString(config.workerName, defaults.workerName, 1, 20)
  config.profile = normalizeEnum(config.profile, { safe = true, balanced = true, turbo = true }, defaults.profile)
  config.waterMode = normalizeEnum(config.waterMode, { ignore = true, stop = true, seal = true }, defaults.waterMode)
  config.maxContinuousSeal = normalizeInteger(config.maxContinuousSeal, 1, 4096, defaults.maxContinuousSeal)
  config.reserveEmptySlots = normalizeInteger(config.reserveEmptySlots, 1, 8, defaults.reserveEmptySlots)
  config.fuelBuffer = normalizeInteger(config.fuelBuffer, 0, 100000, defaults.fuelBuffer)
  config.fuelTarget = normalizeInteger(config.fuelTarget, 500, 100000, defaults.fuelTarget)
  config.moveRetries = normalizeInteger(config.moveRetries, 0, 100, defaults.moveRetries)
  config.moveRetryDelay = normalizeNumber(config.moveRetryDelay, 0, 10, defaults.moveRetryDelay)
  config.heartbeatSeconds = normalizeNumber(config.heartbeatSeconds, 0.1, 60, defaults.heartbeatSeconds)
  config.maxWidth = normalizeInteger(config.maxWidth, 1, 4096, defaults.maxWidth)
  config.maxLength = normalizeInteger(config.maxLength, 1, 4096, defaults.maxLength)
  config.maxDepth = normalizeInteger(config.maxDepth, 1, 4096, defaults.maxDepth)
  config.maxVolume = normalizeInteger(config.maxVolume, 1, 100000000, defaults.maxVolume)
  config.lavaMode = normalizeEnum(config.lavaMode, { seal = true, stop = true }, defaults.lavaMode)
  config.sealSide = normalizeEnum(config.sealSide, { right = true, left = true }, defaults.sealSide)
  config.outputSide = normalizeEnum(config.outputSide,
    { front = true, back = true, left = true, right = true, top = true, bottom = true }, defaults.outputSide)
  config.fuelSide = normalizeEnum(config.fuelSide,
    { front = true, back = true, left = true, right = true, top = true, bottom = true }, defaults.fuelSide)
  config.torchSide = normalizeEnum(config.torchSide,
    { left = true, right = true }, defaults.torchSide)
  config.sealTarget = normalizeInteger(config.sealTarget, 16, 512, defaults.sealTarget)
  config.sealReserve = normalizeInteger(config.sealReserve, 1, math.max(1, config.sealTarget - 1), defaults.sealReserve)
  config.attackEntities = normalizeBoolean(config.attackEntities, defaults.attackEntities)

  config.lighting = normalizeTable(defaults.lighting, config.lighting)
  config.lighting.mode = normalizeEnum(config.lighting.mode, { off = true, safe = true, custom = true }, defaults.lighting.mode)
  config.lighting.interval = normalizeInteger(config.lighting.interval, 1, 4096, defaults.lighting.interval)
  config.lighting.temporaryFloor = normalizeBoolean(config.lighting.temporaryFloor, defaults.lighting.temporaryFloor)
  config.lighting.torchTarget = normalizeInteger(config.lighting.torchTarget, 1, 512, defaults.lighting.torchTarget)
  config.lighting.torchReserve = normalizeInteger(config.lighting.torchReserve, 0, math.max(0, config.lighting.torchTarget - 1), defaults.lighting.torchReserve)
  config.lighting.reserve = normalizeInteger(config.lighting.reserve, 0, 512, defaults.lighting.reserve)
  config.lighting.preferredSlots = normalizeSlotList(config.lighting.preferredSlots, defaults.lighting.preferredSlots)
  config.lighting.torchBlocks = normalizeBlockMap(config.lighting.torchBlocks, defaults.lighting.torchBlocks)
  config.lighting.slot = normalizeInteger(config.lighting.slot, 1, 16, defaults.lighting.slot)
  local loadedLighting = type(raw) == "table" and raw.lighting or nil
  local requestedTorchSide = type(loadedLighting) == "table" and loadedLighting.side or nil
  if requestedTorchSide == nil and type(raw) == "table" then requestedTorchSide = raw.torchSide end
  config.lighting.side = normalizeEnum(requestedTorchSide or config.lighting.side,
    { left = true, right = true }, defaults.lighting.side)
  if config.lavaMode == "seal" and config.lighting.side == config.sealSide then
    config.lighting.side = config.sealSide == "left" and "right" or "left"
  end
  -- V3 uses lighting.side; retain the flat alias for older draft configs.
  config.torchSide = config.lighting.side

  config.materials = normalizeTable(defaults.materials, config.materials)
  for _, key in ipairs({ "sealSlots", "torchSlots", "fuelReserveSlots" }) do
    config.materials[key] = normalizeSlotList(config.materials[key], defaults.materials[key])
  end
  config.materials.compactEveryMoves = normalizeInteger(config.materials.compactEveryMoves, 1, 100000, defaults.materials.compactEveryMoves)
  config.materials.recycleMinedBlocks = normalizeBoolean(config.materials.recycleMinedBlocks, defaults.materials.recycleMinedBlocks)
  config.materials.retainSealTarget = normalizeInteger(config.materials.retainSealTarget, 1, 512, defaults.materials.retainSealTarget)

  config.service = normalizeTable(defaults.service, config.service)
  config.service.adaptive = normalizeBoolean(config.service.adaptive, defaults.service.adaptive)
  config.service.finishCurrentChunk = normalizeBoolean(config.service.finishCurrentChunk, defaults.service.finishCurrentChunk)
  if type(config.service.stations) ~= "table" then config.service.stations = M.copy(defaults.service.stations) end

  config.journal = normalizeTable(defaults.journal, config.journal)
  config.journal.enabled = normalizeBoolean(config.journal.enabled, defaults.journal.enabled)
  config.journal.checkpointEvery = normalizeInteger(config.journal.checkpointEvery, 1, 100000, defaults.journal.checkpointEvery)
  config.journal.maxEntries = normalizeInteger(config.journal.maxEntries, 1, 10000, defaults.journal.maxEntries)
  if type(config.journal.path) ~= "string" or M.trim(config.journal.path) == "" then config.journal.path = defaults.journal.path end

  config.alerts = normalizeTable(defaults.alerts, config.alerts)
  config.alerts.enabled = normalizeBoolean(config.alerts.enabled, defaults.alerts.enabled)
  config.alerts.speaker = normalizeBoolean(config.alerts.speaker, defaults.alerts.speaker)
  config.alerts.redstone = normalizeBoolean(config.alerts.redstone, defaults.alerts.redstone)
  config.alerts.redstoneSide = normalizeEnum(config.alerts.redstoneSide,
    { front = true, back = true, left = true, right = true, top = true, bottom = true }, defaults.alerts.redstoneSide)
  config.alerts.cooldownSeconds = normalizeInteger(config.alerts.cooldownSeconds, 0, 3600, defaults.alerts.cooldownSeconds)
  config.alerts.onWaiting = normalizeBoolean(config.alerts.onWaiting, defaults.alerts.onWaiting)
  config.alerts.onComplete = normalizeBoolean(config.alerts.onComplete, defaults.alerts.onComplete)
  config.alerts.onError = normalizeBoolean(config.alerts.onError, defaults.alerts.onError)

  config.gps = normalizeTable(defaults.gps, config.gps)
  config.gps.enabled = normalizeBoolean(config.gps.enabled, defaults.gps.enabled)
  config.gps.required = normalizeBoolean(config.gps.required, defaults.gps.required)
  config.gps.timeout = normalizeNumber(config.gps.timeout, 0.1, 60, defaults.gps.timeout)
  config.gps.verifyEveryMoves = normalizeInteger(config.gps.verifyEveryMoves, 1, 100000, defaults.gps.verifyEveryMoves)
  config.gps.autoResolvePending = normalizeBoolean(config.gps.autoResolvePending, defaults.gps.autoResolvePending)
  if config.gps.calibration ~= nil and type(config.gps.calibration) ~= "table" then config.gps.calibration = nil end
  if type(config.protectedBlocks) ~= "table" then config.protectedBlocks = M.copy(defaults.protectedBlocks) end
  if type(config.sealBlocks) ~= "table" then config.sealBlocks = M.copy(defaults.sealBlocks) end
  return config
end

local function normalizeControllerConfig(raw)
  local defaults = M.defaultControllerConfig()
  local config = normalizeTable(defaults, raw)
  config.role = "controller"
  config.networkKey = normalizeString(config.networkKey, defaults.networkKey, 8, 40)
  config.controllerName = normalizeString(config.controllerName, defaults.controllerName, 1, 20)
  config.monitorName = normalizePeripheralName(config.monitorName, defaults.monitorName)
  config.workerTimeoutSeconds = normalizeInteger(config.workerTimeoutSeconds, 1, 3600, defaults.workerTimeoutSeconds)
  config.discoverySeconds = normalizeInteger(config.discoverySeconds, 1, 3600, defaults.discoverySeconds)
  config.monitorTextScale = normalizeNumber(config.monitorTextScale, 0.5, 5, defaults.monitorTextScale)
  if config.monitorTextScale * 2 ~= math.floor(config.monitorTextScale * 2) then config.monitorTextScale = defaults.monitorTextScale end
  config.touchEnabled = normalizeBoolean(config.touchEnabled, defaults.touchEnabled)
  config.historyLimit = normalizeInteger(config.historyLimit, 1, 1000, defaults.historyLimit)
  config.queueEnabled = normalizeBoolean(config.queueEnabled, defaults.queueEnabled)
  config.overlapProtection = normalizeBoolean(config.overlapProtection, defaults.overlapProtection)
  config.adaptiveRefresh = normalizeBoolean(config.adaptiveRefresh, defaults.adaptiveRefresh)
  config.alerts = normalizeTable(defaults.alerts, config.alerts)
  config.alerts.enabled = normalizeBoolean(config.alerts.enabled, defaults.alerts.enabled)
  config.alerts.speaker = normalizeBoolean(config.alerts.speaker, defaults.alerts.speaker)
  config.alerts.redstone = normalizeBoolean(config.alerts.redstone, defaults.alerts.redstone)
  config.alerts.redstoneSide = normalizeEnum(config.alerts.redstoneSide,
    { front = true, back = true, left = true, right = true, top = true, bottom = true }, defaults.alerts.redstoneSide)
  config.alerts.cooldownSeconds = normalizeInteger(config.alerts.cooldownSeconds, 0, 3600, defaults.alerts.cooldownSeconds)
  config.presets = normalizeTable(defaults.presets, config.presets)
  for _, name in ipairs({ "safe", "balanced", "turbo" }) do
    config.presets[name] = normalizeTable(defaults.presets[name], config.presets[name])
    config.presets[name].profile = normalizeEnum(config.presets[name].profile,
      { safe = true, balanced = true, turbo = true }, defaults.presets[name].profile)
    config.presets[name].waterMode = normalizeEnum(config.presets[name].waterMode,
      { ignore = true, stop = true, seal = true }, defaults.presets[name].waterMode)
    config.presets[name].maxContinuousSeal = normalizeInteger(config.presets[name].maxContinuousSeal, 1, 4096,
      defaults.presets[name].maxContinuousSeal)
  end
  config.sorting = normalizeTable(defaults.sorting, config.sorting)
  config.sorting.enabled = normalizeBoolean(config.sorting.enabled, defaults.sorting.enabled)
  config.sorting.interval = normalizeInteger(config.sorting.interval, 1, 86400, defaults.sorting.interval)
  config.sorting.source = normalizePeripheralName(config.sorting.source, defaults.sorting.source)
  config.sorting.valuableTarget = normalizePeripheralName(config.sorting.valuableTarget, defaults.sorting.valuableTarget)
  config.sorting.bulkTarget = normalizePeripheralName(config.sorting.bulkTarget, defaults.sorting.bulkTarget)
  config.sorting.sealTarget = normalizePeripheralName(config.sorting.sealTarget, defaults.sorting.sealTarget)
  config.sorting.valuableItems = normalizeBlockMap(config.sorting.valuableItems, defaults.sorting.valuableItems)
  config.sorting.sealBlocks = normalizeBlockMap(config.sorting.sealBlocks, defaults.sorting.sealBlocks)
  return config
end

function M.loadConfig()
  local raw, err = M.loadTable(M.CONFIG_PATH, {})
  if err then return nil, err end
  local role = raw and raw.role or nil
  if role == "worker" then return normalizeWorkerConfig(raw), nil end
  if role == "controller" then return normalizeControllerConfig(raw), nil end
  if role == "gps" then return M.merge(M.defaultGPSConfig(), raw), nil end
  return raw, nil
end

function M.saveConfig(config)
  config.schema = M.SCHEMA
  config.version = M.VERSION
  return M.saveTable(M.CONFIG_PATH, config)
end

return M
