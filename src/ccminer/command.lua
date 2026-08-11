-- CC Miner command launcher (V2/V3 compatible)

local args = { ... }
local common = dofile("/ccminer/lib/common.lua")
local command = string.lower(tostring(args[1] or "help"))

local function reportError(message)
  if printError then printError(tostring(message or "")) else print(tostring(message or "")) end
end

local function unpackArgs(values)
  local unpackFunction = table.unpack or unpack
  return unpackFunction(values)
end

local function printHelp()
  print("CC Miner " .. tostring(common.VERSION or ""))
  print("")
  print("ccm help | version | status | report | doctor | logs")
  print("ccm setup [worker|controller|gps]")
  print("ccm dashboard | discover | update")
  print("ccm rehome RESET                 Local worker recovery")
  print("")
  print("Controller CLI:")
  print("ccm start <id> <W> <L> <D>")
  print("ccm queue [list|add|run|remove|clear] [args...]")
  print("ccm preset(s) [list|save|use|delete] [args...]")
  print("ccm stop <id> <now|row|layer|home|abort>")
  print("ccm pause|resume|recall|service|abort|clear <id>")
  print("ccm gps <id>                    Request GPS fix")
  print("ccm calibrate <id>              Calibrate worker GPS")
  print("ccm rehome <id> RESET")
end

local function forwardController(forwarded)
  forwarded = forwarded or {}
  if #forwarded == 0 then
    for index = 1, #args do forwarded[index] = args[index] end
  end
  shell.run("/ccminer/controller.lua", unpackArgs(forwarded))
end

local function loadConfigForCommand()
  local config, configError = common.loadConfig()
  if not config then
    reportError(configError or "Not configured.")
    return nil
  end
  return config
end

-- This loader intentionally never rotates a .bak file or writes a recovery
-- copy.  `doctor` is a read-only diagnostic and must not change on-disk state.
local function readTableNoWrite(path)
  if not fs or not fs.exists or not fs.exists(path) then return nil, "missing" end
  if fs.isDir and fs.isDir(path) then return nil, "directory" end
  local handle = fs.open(path, "r")
  if not handle then return nil, "unreadable" end
  local text = handle.readAll()
  handle.close()
  if type(textutils) ~= "table" or type(textutils.unserialize) ~= "function" then
    return nil, "unserialize unavailable"
  end
  local ok, value = pcall(textutils.unserialize, text)
  if not ok or type(value) ~= "table" then return nil, "invalid" end
  return value
end

local function tableValue(value, ...)
  local current = value
  for index = 1, select("#", ...) do
    if type(current) ~= "table" then return nil end
    current = current[select(index, ...)]
  end
  return current
end

local function valueString(value, depth)
  depth = depth or 0
  if value == nil then return "-" end
  if type(value) == "boolean" then return value and "true" or "false" end
  if type(value) ~= "table" then return tostring(value) end
  if depth >= 2 then return "{...}" end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = tostring(key) .. "=" .. valueString(value[key], depth + 1)
    if #parts >= 8 then
      parts[#parts + 1] = "..."
      break
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function sortedKeys(value)
  local keys = {}
  if type(value) == "table" then
    for key in pairs(value) do keys[#keys + 1] = key end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function printField(label, value)
  print(tostring(label) .. ": " .. valueString(value))
end

local function printStatusFeature(label, value, fallback)
  if value ~= nil then printField(label, value)
  elseif fallback ~= nil then printField(label, fallback)
  end
end

local function controllerDbCandidates(config)
  local paths, seen = {}, {}
  local function add(path)
    if type(path) == "string" and path ~= "" and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  if type(config) == "table" then
    add(config.controllerDbPath)
    add(config.controllerDBPath)
    add(tableValue(config.controller, "dbPath"))
    add(tableValue(config.history, "path"))
  end
  add(common.CONTROLLER_DB_PATH)
  add(common.CONTROLLER_DB)
  add(common.CONTROLLER_STATE_PATH)
  add("/ccminer/data/controller.db")
  add("/ccminer/controller.db")
  return paths
end

local function historyFromDb(db)
  if type(db) ~= "table" then return nil end
  if type(db.history) == "table" then
    if type(db.history.entries) == "table" then return db.history.entries end
    if type(db.history.rows) == "table" then return db.history.rows end
    return db.history
  end
  if type(db.jobs) == "table" then return db.jobs end
  if type(db.records) == "table" then return db.records end
  if type(db.entries) == "table" then return db.entries end
  -- Some V3 snapshots are themselves a numeric history array.
  if #db > 0 then return db end
  return nil
end

local function printReportTable(prefix, report)
  if type(report) ~= "table" then
    print(prefix .. ": none")
    return
  end
  local printed = false
  for _, key in ipairs(sortedKeys(report)) do
    local value = report[key]
    if type(value) ~= "table" then
      print(prefix .. "." .. tostring(key) .. ": " .. valueString(value))
      printed = true
    end
  end
  if not printed then print(prefix .. ": " .. valueString(report)) end
end

local function printWorkerReport(state)
  print("Worker report")
  local current = state.currentReport or state.activeReport or state.progressReport or state.currentJobReport
  local last = state.lastReport or state.report or state.lastJobReport or state.completionReport
  if current then printReportTable("Current report", current) else print("Current report: none") end
  if last then printReportTable("Last report", last) else print("Last report: none") end
  -- V3 keeps both names while older state files only have `report`; show both
  -- when they are genuinely distinct so no completion data is hidden.
  if state.report and state.report ~= last then printReportTable("Report", state.report) end
  if state.jobReport and state.jobReport ~= last and state.jobReport ~= state.report then
    printReportTable("Job report", state.jobReport)
  end
  local stats = type(state.stats) == "table" and state.stats or {}
  print("Stats")
  for _, key in ipairs(sortedKeys(stats)) do
    if type(stats[key]) ~= "table" then print("  " .. tostring(key) .. ": " .. valueString(stats[key])) end
  end
  if state.job then
    local job = state.job
    print(("Job: %s %s/%s (%s%%)"):format(
      tostring(job.name or job.id or "-"), tostring(job.cursor or 0), tostring(job.total or 0),
      tostring(common.percent and common.percent(job.cursor or 0, job.total or 0) or 0)
    ))
  else
    print("Job: none")
  end
end

local function printControllerReport(config)
  print("Controller history report")
  local loaded, loadedPath, loadError
  for _, path in ipairs(controllerDbCandidates(config)) do
    local candidate, err = readTableNoWrite(path)
    if candidate then loaded, loadedPath = candidate, path; break end
    loadError = err
  end
  if not loaded then
    print("History: none (controller.db not found)")
    if loadError and loadError ~= "missing" then print("History read warning: " .. tostring(loadError)) end
    return
  end
  local history = historyFromDb(loaded)
  print("Database: " .. tostring(loadedPath))
  if not history then
    print("History entries: 0")
    return
  end
  local historyCount = 0
  for _ in pairs(history) do historyCount = historyCount + 1 end
  print("History entries: " .. tostring(historyCount))
  local shown = 0
  if #history > 0 then
    for index = #history, 1, -1 do
      local row = history[index]
      if type(row) == "table" then
        print(("  #%d id=%s status=%s mode=%s at=%s"):format(
          index, tostring(row.id or row.jobId or row.workerId or "-"),
          tostring(row.status or row.result or row.outcome or "-"),
          tostring(row.stopMode or row.mode or row.command or "-"),
          tostring(row.updatedAt or row.finishedAt or row.completedAt or row.at or "-")))
      else
        print("  #" .. tostring(index) .. " " .. valueString(row))
      end
      shown = shown + 1
      if shown >= 10 then break end
    end
  else
    for _, key in ipairs(sortedKeys(history)) do
      local row = history[key]
      if type(row) == "table" then
        print(("  #%s id=%s status=%s mode=%s at=%s"):format(
          tostring(key), tostring(row.id or row.jobId or row.workerId or "-"),
          tostring(row.status or row.result or row.outcome or "-"),
          tostring(row.stopMode or row.mode or row.command or "-"),
          tostring(row.updatedAt or row.finishedAt or row.completedAt or row.at or "-")))
      else print("  #" .. tostring(key) .. " " .. valueString(row)) end
      shown = shown + 1
      if shown >= 10 then break end
    end
  end
end

local function runReport()
  local config = loadConfigForCommand()
  if not config then return end
  if config.role == "worker" then
    local rawState, stateError = readTableNoWrite(common.STATE_PATH)
    local state = type(rawState) == "table" and rawState or {}
    if stateError and stateError ~= "missing" then print("State read warning: " .. tostring(stateError)) end
    printWorkerReport(state)
  elseif config.role == "controller" then
    printControllerReport(config)
  else
    print("Report is available on worker or controller roles.")
  end
end

local function peripheralIsType(name, wanted)
  if not peripheral or not name then return false end
  local matches = false
  if peripheral.getType then
    local ok, value = pcall(peripheral.getType, name)
    matches = ok and value == wanted
  end
  if not matches and peripheral.hasType then
    local ok, value = pcall(peripheral.hasType, name, wanted)
    matches = ok and value == true
  end
  return matches
end

local function wirelessModems()
  local names = {}
  if not peripheral or type(peripheral.getNames) ~= "function" then return names end
  local ok, all = pcall(peripheral.getNames)
  if not ok or type(all) ~= "table" then return names end
  for _, name in ipairs(all) do
    if peripheralIsType(name, "modem") then
      local wireless = false
      local wrapped = peripheral.wrap and peripheral.wrap(name) or nil
      if wrapped and type(wrapped.isWireless) == "function" then
        local wirelessOk, result = pcall(wrapped.isWireless)
        wireless = wirelessOk and result == true
      end
      if wireless then names[#names + 1] = tostring(name) end
    end
  end
  return names
end

local function inventoryAvailable(side)
  if not side or side == "" then return false end
  if peripheralIsType(side, "inventory") then return true end
  if peripheral and peripheral.wrap then
    local ok, wrapped = pcall(peripheral.wrap, side)
    if ok and wrapped and (type(wrapped.list) == "function" or type(wrapped.size) == "function") then return true end
  end
  return false
end

local function inventorySlots(side)
  if not side or not peripheral or not peripheral.wrap then return nil end
  local ok, wrapped = pcall(peripheral.wrap, side)
  if not ok or not wrapped then return nil end
  if type(wrapped.size) == "function" then
    local sizeOk, result = pcall(wrapped.size)
    if sizeOk then return tonumber(result) end
  end
  return nil
end

local function fuelStatus()
  if not turtle or type(turtle.getFuelLevel) ~= "function" then return nil, nil end
  local ok, level = pcall(turtle.getFuelLevel)
  local limitOk, limit = false, nil
  if type(turtle.getFuelLimit) == "function" then limitOk, limit = pcall(turtle.getFuelLimit) end
  if not ok then return nil, nil end
  if limitOk ~= true then limit = nil end
  return level, limit
end

local function countInventorySlots()
  if not turtle or type(turtle.getItemCount) ~= "function" then return nil, nil end
  local used, empty = 0, 0
  for slot = 1, 16 do
    local ok, count = pcall(turtle.getItemCount, slot)
    count = ok and tonumber(count) or 0
    if count > 0 then used = used + 1 else empty = empty + 1 end
  end
  return used, empty
end

local function configuredReservedSlots(config)
  local result, seen = {}, {}
  local function add(value)
    if type(value) ~= "table" then return end
    for key, item in pairs(value) do
      local candidate
      if type(key) == "number" and type(item) == "boolean" then candidate = key
      elseif type(key) == "number" and tonumber(item) then candidate = tonumber(item)
      elseif type(key) == "number" then candidate = key
      elseif tonumber(item) then candidate = tonumber(item) end
      if candidate and candidate >= 1 and candidate <= 16 then
        candidate = math.floor(candidate)
        if not seen[candidate] then seen[candidate] = true; result[#result + 1] = candidate end
      end
    end
  end
  local materials = type(config.materials) == "table" and config.materials or {}
  local recycle = type(config.recycle) == "table" and config.recycle or {}
  local lighting = type(config.lighting) == "table" and config.lighting or {}
  add(config.reservedSlots); add(materials.reservedSlots); add(materials.sealSlots)
  add(materials.torchSlots); add(materials.fuelReserveSlots); add(recycle.reservedSlots)
  add(lighting.preferredSlots); add(config.sealSlots); add(config.torchSlots)
  table.sort(result)
  return result
end

local function runDoctor()
  local counts = { PASS = 0, WARN = 0, FAIL = 0 }
  local function finding(level, name, message)
    level = string.upper(tostring(level))
    if counts[level] == nil then level = "WARN" end
    counts[level] = counts[level] + 1
    print(("%s %-22s %s"):format(level, tostring(name), tostring(message or "")))
  end

  print("CC Miner doctor (read-only)")
  local rawConfig, configError = readTableNoWrite(common.CONFIG_PATH)
  local config = type(rawConfig) == "table" and rawConfig or {}
  local role = tostring(config.role or "")
  if not rawConfig then
    finding("FAIL", "config.file", "configuration is " .. tostring(configError or "missing"))
  else
    finding("PASS", "config.file", "readable")
  end
  if type(config.schema) ~= "number" then
    finding("FAIL", "config.schema", "schema is missing")
  elseif tonumber(common.SCHEMA) and config.schema ~= common.SCHEMA then
    finding("FAIL", "config.schema", ("expected %s, found %s"):format(tostring(common.SCHEMA), tostring(config.schema)))
  else
    finding("PASS", "config.schema", tostring(config.schema))
  end
  if role ~= "worker" and role ~= "controller" and role ~= "gps" then
    finding("FAIL", "config.role", "unknown role: " .. (role == "" and "missing" or role))
  else
    finding("PASS", "config.role", role)
  end
  if config.version == nil then finding("WARN", "config.version", "missing") else finding("PASS", "config.version", tostring(config.version)) end

  local networkKey = config.networkKey
  if role ~= "gps" then
    if type(networkKey) ~= "string" or networkKey == "" or networkKey == "CHANGE_ME" then
      finding("FAIL", "config.networkKey", "missing or still CHANGE_ME")
    else
      finding("PASS", "config.networkKey", "configured (masked)")
    end
  end
  if role == "worker" then
    local numericChecks = {
      { "config.maxWidth", config.maxWidth, 1 }, { "config.maxLength", config.maxLength, 1 },
      { "config.maxDepth", config.maxDepth, 1 }, { "config.maxVolume", config.maxVolume, 1 },
      { "config.reserveEmptySlots", config.reserveEmptySlots, 0 },
    }
    for _, check in ipairs(numericChecks) do
      if tonumber(check[2]) and tonumber(check[2]) >= check[3] then finding("PASS", check[1], tostring(check[2]))
      else finding("FAIL", check[1], "must be a number >= " .. tostring(check[3])) end
    end
    finding("PASS", "config.profile", tostring(config.profile or "balanced"))
    finding("PASS", "config.water", valueString(config.water or config.waterMode or "seal"))
    finding("PASS", "config.lighting", valueString(config.lighting or config.lightMode or "off"))
    finding("PASS", "config.materials", valueString(config.materials or {}))
  elseif role == "controller" then
    local controllerNumbers = {
      { "config.historyLimit", config.historyLimit, 1 },
      { "config.workerTimeoutSeconds", config.workerTimeoutSeconds, 1 },
      { "config.discoverySeconds", config.discoverySeconds, 1 },
    }
    for _, check in ipairs(controllerNumbers) do
      if tonumber(check[2]) and tonumber(check[2]) >= check[3] then finding("PASS", check[1], tostring(check[2]))
      else finding("FAIL", check[1], "must be a number >= " .. tostring(check[3])) end
    end
    finding("PASS", "config.queueEnabled", valueString(config.queueEnabled))
    finding("PASS", "config.overlapProtection", valueString(config.overlapProtection))
    finding("PASS", "config.adaptiveRefresh", valueString(config.adaptiveRefresh))
    finding("PASS", "config.presets", valueString(config.presets or {}))
  elseif role == "gps" then
    finding("PASS", "config.coordinates", ("%s, %s, %s"):format(tostring(config.x), tostring(config.y), tostring(config.z)))
  end

  local labelApi = os and type(os.getComputerLabel) == "function"
  local label = labelApi and os.getComputerLabel() or nil
  if not labelApi then finding("WARN", "label.api", "getComputerLabel unavailable")
  elseif label and label ~= "" then finding("PASS", "label", tostring(label))
  else finding("WARN", "label", "computer label is not set") end

  local modems = wirelessModems()
  if #modems > 0 then finding("PASS", "modem", table.concat(modems, ", "))
  elseif role == "worker" or role == "controller" or role == "gps" then finding("FAIL", "modem", "no wireless modem detected")
  else finding("WARN", "modem", "role is not configured") end

  local gpsApi = gps and type(gps.locate) == "function"
  local gpsConfig = type(config.gps) == "table" and config.gps or {}
  if role == "worker" and gpsConfig.enabled == false then finding("WARN", "gps.api", "disabled in config")
  elseif gpsApi then finding("PASS", "gps.api", "gps.locate available")
  elseif role == "worker" and gpsConfig.required == true then finding("FAIL", "gps.api", "required GPS API unavailable")
  else finding("WARN", "gps.api", "gps.locate unavailable") end

  if role == "worker" then
    if not turtle then
      finding("FAIL", "turtle", "worker role is running without a turtle API")
    else
      local sides = {
        { "inventory.output", config.outputSide or "back", true },
        { "inventory.fuel", config.fuelSide or "top", true },
      }
      if (config.lavaMode or "seal") == "seal" then sides[#sides + 1] = { "inventory.seal", config.sealSide or "right", true } end
      local usedSides = {}
      for _, item in ipairs(sides) do
        local side = tostring(item[2])
        if usedSides[side] then finding("WARN", item[1], "same side as another inventory: " .. side) end
        usedSides[side] = true
        if inventoryAvailable(side) then
          local slots = inventorySlots(side)
          finding("PASS", item[1], side .. (slots and (" (" .. slots .. " slots)") or ""))
        else finding("FAIL", item[1], "inventory missing on " .. side) end
      end
      local fuel, fuelLimit = fuelStatus()
      if fuel == nil then finding("FAIL", "fuel.api", "turtle fuel API unavailable")
      elseif fuel == "unlimited" then finding("PASS", "fuel", "unlimited")
      else
        local target = tonumber(config.fuelTarget) or 0
        local buffer = tonumber(config.fuelBuffer) or 0
        if tonumber(fuel) and target > 0 and fuel < math.min(target, buffer > 0 and buffer or target) then
          finding("WARN", "fuel", ("%s / %s (below configured reserve)"):format(tostring(fuel), tostring(fuelLimit or "-")))
        else finding("PASS", "fuel", ("%s / %s"):format(tostring(fuel), tostring(fuelLimit or "-"))) end
      end
      local used, empty = countInventorySlots()
      if used == nil then finding("FAIL", "inventory.slots", "turtle inventory API unavailable")
      else
        local reserve = tonumber(config.reserveEmptySlots) or 0
        if empty < reserve then finding("WARN", "inventory.reserve", ("%d empty (target %d)"):format(empty, reserve))
        else finding("PASS", "inventory.reserve", ("%d empty (target %d)"):format(empty, reserve)) end
        local reserved = configuredReservedSlots(config)
        if #reserved == 0 then finding("WARN", "inventory.reservedSlots", "no explicit material slots")
        else
          local present = {}
          for _, slot in ipairs(reserved) do
            local ok, count = pcall(turtle.getItemCount, slot)
            present[#present + 1] = tostring(slot) .. "=" .. tostring(ok and count or 0)
          end
          finding("PASS", "inventory.reservedSlots", table.concat(present, ", "))
        end
      end
    end
  end

  local rawState, stateError = readTableNoWrite(common.STATE_PATH)
  if role == "worker" then
    if not rawState then
      finding(stateError == "missing" and "WARN" or "FAIL", "state.file", "state is " .. tostring(stateError or "missing"))
    else
      finding("PASS", "state.file", "readable")
      local state = rawState
      if tonumber(state.schema) ~= tonumber(common.SCHEMA) then finding("FAIL", "state.schema", "schema mismatch")
      else finding("PASS", "state.schema", tostring(state.schema)) end
      local statuses = { idle = true, working = true, paused = true, blocked = true, complete = true, aborted = true,
        waiting_fuel = true, waiting_output = true, waiting_seal = true, waiting_torch = true, waiting_water = true,
        recovering = true, dormant = true, calibrating = true }
      if statuses[state.status] then finding("PASS", "state.status", tostring(state.status))
      else finding("WARN", "state.status", "unknown status: " .. tostring(state.status)) end
      if state.pendingAction ~= nil then
        if type(state.pendingAction) ~= "table" or not state.pendingAction.kind then finding("FAIL", "state.pending", "malformed pendingAction")
        elseif state.status ~= "blocked" and state.phase ~= "recovery_required" then finding("WARN", "state.pending", "pending action exists while state is not blocked")
        else finding("PASS", "state.pending", tostring(state.pendingAction.kind)) end
      else finding("PASS", "state.pending", "none") end
      local active = state.status == "working" or state.status == "waiting_fuel" or state.status == "waiting_output"
        or state.status == "waiting_seal" or state.status == "waiting_torch"
      if active and type(state.job) ~= "table" and type(state.service) ~= "table" then
        finding("FAIL", "state.job", "active state has no job or service")
      elseif type(state.job) == "table" then
        local cursor, total = tonumber(state.job.cursor), tonumber(state.job.total)
        if not cursor or not total or cursor < 0 or total <= 0 or cursor > total then
          finding("FAIL", "state.job", "cursor/total is inconsistent")
        else finding("PASS", "state.job", ("%d/%d"):format(cursor, total)) end
      else finding("PASS", "state.job", "none") end
      if state.request ~= nil and type(state.request) ~= "string" then finding("WARN", "state.request", "request is not a string") end
      if state.stagedStop ~= nil and type(state.stagedStop) ~= "table" and type(state.stagedStop) ~= "boolean" then
        finding("FAIL", "state.stagedStop", "malformed staged stop")
      elseif type(state.stagedStop) == "table" then
        finding("PASS", "state.stagedStop", valueString(state.stagedStop))
      else
        finding("PASS", "state.stagedStop", "none")
      end
    end
  elseif stateError and stateError ~= "missing" then
    finding("WARN", "state.file", "not applicable; read error " .. tostring(stateError))
  end

  if role == "controller" then
    local found = false
    for _, path in ipairs(controllerDbCandidates(config)) do
      local db, dbError = readTableNoWrite(path)
      if db then
        found = true
        local history = historyFromDb(db)
        if history then
          local historyCount = 0
          for _ in pairs(history) do historyCount = historyCount + 1 end
          finding("PASS", "controller.db", tostring(path) .. " entries=" .. tostring(historyCount))
        else finding("WARN", "controller.db", tostring(path) .. " has no history table") end
        break
      elseif dbError and dbError ~= "missing" then finding("WARN", "controller.db", tostring(path) .. ": " .. tostring(dbError)) end
    end
    if not found then finding("WARN", "controller.db", "history database not found") end
  end

  print("")
  print(("Doctor summary: PASS=%d WARN=%d FAIL=%d"):format(counts.PASS, counts.WARN, counts.FAIL))
  if counts.FAIL > 0 then print("Doctor result: FAIL")
  elseif counts.WARN > 0 then print("Doctor result: WARN")
  else print("Doctor result: PASS") end
end

if command == "help" or command == "?" then
  printHelp()
elseif command == "version" then
  print("CC Miner " .. tostring(common.VERSION or ""))
elseif command == "setup" then
  shell.run("/ccminer/setup.lua", args[2])
elseif command == "dashboard" then
  shell.run("/ccminer/controller.lua")
elseif command == "discover" then
  shell.run("/ccminer/controller.lua", "discover")
elseif command == "doctor" then
  runDoctor()
elseif command == "report" then
  runReport()
elseif command == "rehome" then
  local config, configError = common.loadConfig()
  if not config then
    reportError(configError or "Not configured.")
  elseif config.role == "worker" then
    if args[2] ~= "RESET" then
      reportError("Place the turtle in its dock facing the quarry, then run: ccm rehome RESET")
    else
      local calibration = config.gps and config.gps.calibration or nil
      if calibration and gps and gps.locate then
        local x, y, z = gps.locate(2, false)
        if not x then
          reportError("A GPS fix is required to verify the calibrated dock. Rehome was cancelled.")
          return
        end
        if common.round(x) ~= calibration.home.x or common.round(y) ~= calibration.home.y or common.round(z) ~= calibration.home.z then
          reportError("GPS position does not match the calibrated dock. Rehome was cancelled.")
          return
        end
      elseif calibration then
        reportError("GPS is unavailable, so the calibrated dock cannot be verified. Rehome was cancelled.")
        return
      end
      local previous = common.loadTable(common.STATE_PATH, common.defaultState())
      local reset = common.defaultState()
      if previous and previous.stats then reset.stats = previous.stats end
      local ok, err = common.saveTable(common.STATE_PATH, reset)
      if not ok then reportError("Cannot reset worker state: " .. tostring(err))
      else print("Worker coordinates and job were reset to home. Run: reboot") end
    end
  elseif config.role == "controller" then
    if not tonumber(args[2]) or args[3] ~= "RESET" then reportError("Usage: ccm rehome <id> RESET") else forwardController() end
  else
    reportError("Rehome is not available for role " .. tostring(config.role))
  end
elseif command == "start" or command == "pause" or command == "resume" or command == "recall"
  or command == "service" or command == "abort" or command == "clear" or command == "gps" or command == "calibrate"
  or command == "queue" or command == "preset" or command == "presets" or command == "stop" then
  local config = loadConfigForCommand()
  if config and config.role ~= "controller" then reportError("Run this command on the controller computer.")
  elseif config then
    if command == "stop" then
      local mode = string.lower(tostring(args[3] or ""))
      local stopModes = {
        now = "pause_now", row = "finish_row", layer = "finish_layer", home = "return_home",
        pause_now = "pause_now", finish_row = "finish_row", finish_layer = "finish_layer",
        return_home = "return_home", abort = "abort",
      }
      local controllerMode = stopModes[mode]
      local valid = controllerMode ~= nil
      if not tonumber(args[2]) or not valid then
        reportError("Usage: ccm stop <id> <now|row|layer|home|abort>")
      else
        local forwarded = {}
        for index = 1, #args do forwarded[index] = args[index] end
        forwarded[3] = controllerMode
        forwardController(forwarded)
      end
    else
      forwardController()
    end
  end
elseif command == "status" then
  local config, configError = common.loadConfig()
  if not config then reportError(configError or "Not configured."); return end
  print("CC Miner " .. tostring(common.VERSION or ""))
  print("Role: " .. tostring(config.role))
  print("Computer ID: " .. tostring(os.getComputerID()))
  print("Label: " .. tostring(os.getComputerLabel and os.getComputerLabel() or "-"))
  if type(config.networkKey) == "string" and config.networkKey ~= "" then print("Network key: configured (masked)") else print("Network key: not configured") end
  printStatusFeature("Profile", config.profile)
  printStatusFeature("Lighting", config.lighting, config.lightMode)
  printStatusFeature("Water", config.water, config.waterMode)
  printStatusFeature("Materials", config.materials)
  printStatusFeature("Staged stop", config.stagedStop)
  if config.role == "worker" then
    local state, stateError = common.loadTable(common.STATE_PATH, common.defaultState())
    if stateError then reportError(stateError) end
    print("Status: " .. tostring(state.status) .. " / " .. tostring(state.phase))
    if state.pose then print(("Pose: x=%s y=%s z=%s dir=%s"):format(state.pose.x, state.pose.y, state.pose.z, state.pose.dir)) end
    print("GPS calibrated: " .. tostring(config.gps and config.gps.calibration ~= nil))
    print("Lava mode: " .. tostring(config.lavaMode))
    printStatusFeature("Lighting", state.lighting, config.lighting or config.lightMode)
    printStatusFeature("Water", state.water, config.water or config.waterMode)
    printStatusFeature("Profile", state.profile, config.profile)
    printStatusFeature("Materials", state.materials, config.materials)
    printStatusFeature("Staged stop", state.stagedStop, config.stagedStop)
    if state.job then print(("Job: %s %s/%s [%s]"):format(tostring(state.job.name), tostring(state.job.cursor), tostring(state.job.total), tostring(state.job.strategy))) end
    if state.lastError then print("Error: " .. tostring(state.lastError)) end
  elseif config.role == "gps" then
    print(("Coordinates: %s, %s, %s"):format(config.x, config.y, config.z))
  end
elseif command == "logs" then
  if not fs.exists(common.LOG_PATH) then print("No log file yet."); return end
  local handle = fs.open(common.LOG_PATH, "r")
  local lines = {}
  while true do
    local line = handle.readLine()
    if not line then break end
    lines[#lines + 1] = line
    if #lines > 30 then table.remove(lines, 1) end
  end
  handle.close()
  for _, line in ipairs(lines) do print(line) end
elseif command == "update" then
  if not http then reportError("HTTP API is disabled."); return end
  shell.run("wget", "run", "https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua", "update")
else
  reportError("Unknown command: " .. command)
  printHelp()
end
