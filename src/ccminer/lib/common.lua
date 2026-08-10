-- CC Miner V2 - shared helpers
-- Compatible with CC: Restitched / CC:Tweaked 1.100.x (Minecraft 1.18.2).

local M = {}

M.VERSION = "2.0.0"
M.SCHEMA = 2
M.ROOT = "/ccminer"
M.CONFIG_PATH = M.ROOT .. "/config.db"
M.STATE_PATH = M.ROOT .. "/data/state.db"
M.LOG_PATH = M.ROOT .. "/data/ccminer.log"
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
  for key, item in pairs(value) do
    out[M.copy(key, seen)] = M.copy(item, seen)
  end
  return out
end

function M.merge(defaults, loaded)
  local out = M.copy(defaults or {})
  if type(loaded) ~= "table" then return out end
  for key, value in pairs(loaded) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = M.merge(out[key], value)
    else
      out[key] = value
    end
  end
  return out
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
  local temp = path .. ".tmp"
  local backup = path .. ".bak"
  if fs.exists(temp) then fs.delete(temp) end
  local handle = fs.open(temp, "w")
  if not handle then return false, "Cannot open temporary file: " .. temp end
  handle.write(text or "")
  handle.close()

  -- ComputerCraft's virtual filesystem cannot replace an existing file with a
  -- single rename. Keep the previous complete file as .bak so a power loss in
  -- the swap window never leaves configuration/state without a recoverable
  -- copy.
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
    if hadCurrent and fs.exists(backup) then pcall(fs.move, backup, path) end
    if fs.exists(temp) then fs.delete(temp) end
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

  -- Recover the previous known-good snapshot after an interrupted atomic
  -- write. Restoration is best-effort; callers can still continue from the
  -- decoded backup even if the repair write itself fails.
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
  if not fs.exists(path) or fs.isDir(path) then return end
  if fs.getSize(path) < maxBytes then return end
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
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
end

function M.trim(text)
  text = tostring(text or "")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
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
  local abs = math.abs(value)
  if abs >= 1000000000 then return ("%.1fB"):format(value / 1000000000) end
  if abs >= 1000000 then return ("%.1fM"):format(value / 1000000) end
  if abs >= 1000 then return ("%.1fK"):format(value / 1000) end
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
  for i = 1, length do
    local index = math.random(1, #alphabet)
    out[i] = alphabet:sub(index, index)
  end
  return table.concat(out)
end

function M.prompt(label, defaultValue, validator, secret)
  while true do
    if defaultValue ~= nil and tostring(defaultValue) ~= "" then
      write(('%s [%s]: '):format(label, tostring(defaultValue)))
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
  local defaultText = defaultValue and "Y" or "N"
  local value = M.prompt(label .. " (y/n)", defaultText, function(text)
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

function M.findPeripheral(peripheralType)
  if not peripheral then return nil, nil end
  for _, name in ipairs(peripheral.getNames()) do
    local matches = peripheral.getType(name) == peripheralType
    if not matches and peripheral.hasType then
      local ok, result = pcall(peripheral.hasType, name, peripheralType)
      matches = ok and result == true
    end
    if matches then return peripheral.wrap(name), name end
  end
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
    paused = colors.yellow,
    waiting_fuel = colors.orange,
    waiting_output = colors.orange,
    blocked = colors.red,
    complete = colors.cyan,
    aborted = colors.red,
    offline = colors.gray,
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
    stopOnLava = true,
    attackEntities = false,
    maxWidth = 128,
    maxLength = 512,
    maxDepth = 128,
    maxVolume = 2000000,
    outputSide = "back",
    fuelSide = "top",
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
  }
end

function M.defaultState()
  return {
    schema = M.SCHEMA,
    version = M.VERSION,
    status = "idle",
    phase = "home",
    pose = { x = 0, y = 0, z = 0, dir = 0 },
    job = nil,
    checkpoint = nil,
    request = nil,
    lastError = nil,
    completionReason = nil,
    pendingAction = nil,
    updatedAt = M.nowSeconds(),
    stats = {
      moves = 0,
      turns = 0,
      blocksDug = 0,
      unloads = 0,
      refuels = 0,
      jobsCompleted = 0,
      startedAt = M.nowSeconds(),
    },
    recentCommands = {},
  }
end

function M.loadConfig()
  local raw, err = M.loadTable(M.CONFIG_PATH, {})
  if err then return nil, err end
  local role = raw and raw.role or nil
  if role == "worker" then return M.merge(M.defaultWorkerConfig(), raw), nil end
  if role == "controller" then return M.merge(M.defaultControllerConfig(), raw), nil end
  return raw, nil
end

function M.saveConfig(config)
  config.schema = M.SCHEMA
  config.version = M.VERSION
  return M.saveTable(M.CONFIG_PATH, config)
end

return M
