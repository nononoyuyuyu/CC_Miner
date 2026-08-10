-- CC Miner V2 - fleet controller dashboard

local args = { ... }
local common = dofile("/ccminer/lib/common.lua")
local protocol = dofile("/ccminer/lib/protocol.lua")

local config, configError = common.loadConfig()
if not config or config.role ~= "controller" then
  error(configError or "Controller configuration not found. Run: ccm setup controller", 0)
end

if not os.getComputerLabel or not os.getComputerLabel() then
  if os.setComputerLabel then os.setComputerLabel(config.controllerName) end
end

local networkReady, modemNames = protocol.open()
if not networkReady then error("No wireless modem found next to the controller.", 0) end

local workers = {}
local selected = 1
local notice = "Controller ready. Press D to discover workers."
local noticeIsError = false
local lastDiscovery = 0
local running = true
local monitor = common.findPeripheral("monitor")
if monitor and monitor.setTextScale then pcall(monitor.setTextScale, config.monitorTextScale or 0.5) end

local function orderedIds()
  local ids = {}
  for id in pairs(workers) do ids[#ids + 1] = tonumber(id) or id end
  table.sort(ids, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  if #ids == 0 then selected = 1 else selected = common.clamp(selected, 1, #ids) end
  return ids
end

local function selectedWorker()
  local ids = orderedIds()
  local id = ids[selected]
  return id, id and workers[id] or nil
end

local function statusOf(worker)
  if not worker then return "offline" end
  if common.nowSeconds() - (worker.lastSeen or 0) > (config.workerTimeoutSeconds or 10) then return "offline" end
  return worker.data.status or "unknown"
end

local function workerLabel(worker, id)
  if worker and worker.data and worker.data.label then return worker.data.label end
  return "Miner-" .. tostring(id)
end

local function handleMessage(sender, message)
  local valid = protocol.validate(message, config.networkKey, os.getComputerID())
  if not valid then return false end
  if message.kind == "status" then
    local payload = message.payload or {}
    local id = tonumber(payload.id) or tonumber(sender)
    workers[id] = workers[id] or {}
    workers[id].data = payload
    workers[id].lastSeen = common.nowSeconds()
    workers[id].sender = sender
    return true
  elseif message.kind == "ack" then
    local payload = message.payload or {}
    notice = (payload.ok and "OK: " or "ERROR: ") .. tostring(payload.message or "")
    noticeIsError = not payload.ok
    if payload.status and payload.status.id then
      local id = tonumber(payload.status.id) or tonumber(sender)
      workers[id] = workers[id] or {}
      workers[id].data = payload.status
      workers[id].lastSeen = common.nowSeconds()
      workers[id].sender = sender
    end
    return true
  end
  return false
end

local function discover()
  local message = protocol.message("discover", config.networkKey, {
    controllerName = config.controllerName,
  })
  protocol.broadcast(message)
  lastDiscovery = common.nowSeconds()
  notice = "Discovery broadcast sent."
  noticeIsError = false
end

local function sendCommand(id, command, payload)
  if not id then
    notice, noticeIsError = "No worker selected.", true
    return false
  end
  payload = payload or {}
  payload.command = command
  local message = protocol.message("command", config.networkKey, payload, id)
  local ok, err = protocol.send(id, message)
  if ok then
    notice, noticeIsError = ("Command '%s' sent to #%s."):format(command, tostring(id)), false
  else
    notice, noticeIsError = "Send failed: " .. tostring(err), true
  end
  return ok
end

local function progressText(data)
  if not data or not data.job then return "-" end
  return ("%3d%% %s/%s"):format(
    tonumber(data.job.percent) or 0,
    common.humanNumber(data.job.cursor or 0),
    common.humanNumber(data.job.total or 0)
  )
end

local function renderOne(target, compact)
  local width, height = target.getSize()
  common.withTerm(target, function()
    common.clear(colors and colors.black or nil, colors and colors.white or nil)
    common.writeAt(1, 1, common.center("CC MINER V2 CONTROL", width), colors and colors.black or nil, colors and colors.cyan or nil)
    local ids = orderedIds()
    local online = 0
    for _, id in ipairs(ids) do if statusOf(workers[id]) ~= "offline" then online = online + 1 end end
    common.writeAt(1, 2, common.fit(("Controller #%d | Workers %d/%d | v%s"):format(os.getComputerID(), online, #ids, common.VERSION), width), colors and colors.lightGray or nil, colors and colors.black or nil)

    local headerY = 4
    if width >= 48 then
      common.writeAt(1, headerY, common.fit("  ID    NAME           STATUS       PROGRESS          FUEL", width), colors and colors.yellow or nil)
    else
      common.writeAt(1, headerY, common.fit("  ID   NAME       STATUS   PROGRESS", width), colors and colors.yellow or nil)
    end

    local maxRows = math.max(1, height - 9)
    if #ids == 0 then
      common.writeAt(2, headerY + 2, "No workers found. Press D.", colors and colors.lightGray or nil)
    else
      local first = 1
      if selected > maxRows then first = selected - maxRows + 1 end
      for row = 1, maxRows do
        local index = first + row - 1
        local id = ids[index]
        if not id then break end
        local worker = workers[id]
        local data = worker.data or {}
        local status = statusOf(worker)
        local marker = index == selected and ">" or " "
        local line
        if width >= 48 then
          line = ("%s %-5s %-14s %-12s %-17s %s"):format(
            marker,
            tostring(id),
            common.fit(workerLabel(worker, id), 14),
            common.fit(status, 12),
            common.fit(progressText(data), 17),
            tostring(data.fuel or "-")
          )
        else
          line = ("%s%-5s %-10s %-8s %s"):format(
            marker,
            tostring(id),
            common.fit(workerLabel(worker, id), 10),
            common.fit(status, 8),
            progressText(data)
          )
        end
        local fg = index == selected and (colors and colors.black or nil) or common.statusColor(status)
        local bg = index == selected and (colors and colors.white or nil) or (colors and colors.black or nil)
        common.writeAt(1, headerY + row, common.fit(line, width), fg, bg)
      end
    end

    local helpY = height - 3
    local help1 = "N:new P:pause R:resume H:recall X:abort S:service"
    local help2 = "D:discover C:clear I:info G:rehome Q:quit  Up/Down:select"
    if compact or width < 50 then
      help1 = "N new | P pause | R resume | H recall | X abort"
      help2 = "D find | S svc | I info | C clear | Q quit"
    end
    common.writeAt(1, helpY, common.fit(help1, width), colors and colors.lightBlue or nil)
    common.writeAt(1, helpY + 1, common.fit(help2, width), colors and colors.lightBlue or nil)
    local noticeColor = noticeIsError and (colors and colors.red or nil) or (colors and colors.lime or nil)
    common.writeAt(1, height, common.fit(notice, width), noticeColor)
  end)
end

local function render()
  renderOne(term.current(), false)
  if monitor then renderOne(monitor, true) end
end

local function pumpFor(seconds)
  local deadline = common.nowSeconds() + (seconds or 1)
  while common.nowSeconds() <= deadline do
    local sender, message = protocol.receive(0.25)
    if sender then handleMessage(sender, message) end
  end
end

local function inputNumber(label, defaultValue, minimum, maximum)
  term.setCursorBlink(true)
  return common.promptNumber(label, defaultValue, minimum, maximum)
end

local function newJobWizard()
  local id, worker = selectedWorker()
  if not id or not worker then notice, noticeIsError = "Select a worker first.", true; return end
  local status = statusOf(worker)
  if status == "offline" then notice, noticeIsError = "Selected worker is offline.", true; return end

  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("NEW QUARRY JOB")
  print("Worker: #" .. tostring(id) .. " " .. workerLabel(worker, id))
  print("The turtle mines a full rectangular volume.")
  print("Width = blocks to its right; Length = blocks forward; Depth = blocks down.")
  print("")
  local width = inputNumber("Width", 8, 1, 128)
  local length = inputNumber("Length", 32, 1, 512)
  local depth = inputNumber("Depth", 16, 1, 128)
  local volume = width * length * depth
  print("")
  print(("Volume: %d blocks"):format(volume))
  print("The worker will return automatically for fuel and unloading.")
  if not common.promptYesNo("Start this job", false) then
    notice, noticeIsError = "Job creation cancelled.", false
    return
  end
  sendCommand(id, "start", {
    width = width,
    length = length,
    depth = depth,
    name = ("Quarry %dx%dx%d"):format(width, length, depth),
    jobId = ("q-%d-%d"):format(id, common.nowMillis()),
  })
end

local function confirmCommand(command, warning)
  local id, worker = selectedWorker()
  if not id or not worker then notice, noticeIsError = "No worker selected.", true; return end
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print(string.upper(command) .. " WORKER #" .. tostring(id))
  print("")
  print(warning)
  print("")
  if common.promptYesNo("Continue", false) then sendCommand(id, command) else notice = "Cancelled." end
end

local function showInfo()
  local id, worker = selectedWorker()
  if not id or not worker then notice, noticeIsError = "No worker selected.", true; return end
  local data = worker.data or {}
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("WORKER DETAILS")
  print(("ID: %s  Name: %s"):format(tostring(id), workerLabel(worker, id)))
  print(("Status: %s / %s"):format(statusOf(worker), tostring(data.phase or "-")))
  if data.pose then print(("Pose: x=%s y=%s z=%s dir=%s"):format(data.pose.x, data.pose.y, data.pose.z, data.pose.dir)) end
  print(("Fuel: %s / %s"):format(tostring(data.fuel or "-"), tostring(data.fuelLimit or "-")))
  print(("Inventory: %s used, %s empty, %s items"):format(tostring(data.inventoryUsed or "-"), tostring(data.inventoryEmpty or "-"), tostring(data.inventoryItems or "-")))
  if data.job then
    print(("Job: %s (%dx%dx%d)"):format(tostring(data.job.name), data.job.width, data.job.length, data.job.depth))
    print(("Progress: %s/%s (%s%%)"):format(data.job.cursor, data.job.total, data.job.percent))
  else
    print("Job: none")
  end
  if data.lastError then print("Error: " .. tostring(data.lastError)) end
  if data.completionReason then print("Completion: " .. tostring(data.completionReason)) end
  print("")
  print("Press any key to return.")
  os.pullEvent("key")
end

local function rehomeWizard()
  local id = selectedWorker()
  if not id then notice, noticeIsError = "No worker selected.", true; return end
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("DANGEROUS: REHOME WORKER #" .. tostring(id))
  print("")
  print("Use only after physically placing the turtle in its dock")
  print("and facing the quarry entrance. This erases the active job.")
  print("")
  write("Type RESET to continue: ")
  local confirmation = read()
  if confirmation == "RESET" then
    sendCommand(id, "rehome", { confirm = "RESET" })
  else
    notice, noticeIsError = "Rehome cancelled.", false
  end
end

local function processChar(character)
  character = string.lower(character or "")
  local id = selectedWorker()
  if character == "d" then discover()
  elseif character == "n" then newJobWizard()
  elseif character == "p" then sendCommand(id, "pause")
  elseif character == "r" then sendCommand(id, "resume")
  elseif character == "h" then sendCommand(id, "recall")
  elseif character == "s" then sendCommand(id, "service")
  elseif character == "x" then confirmCommand("abort", "The worker returns home and the current job cannot be resumed.")
  elseif character == "c" then confirmCommand("clear", "Clear the completed/aborted job record. The worker must be at home.")
  elseif character == "i" then showInfo()
  elseif character == "g" then rehomeWizard()
  elseif character == "q" then running = false end
end

local function commandLineMode()
  local command = string.lower(args[1] or "")
  if command == "discover" or command == "status" then
    discover()
    pumpFor(3)
    local ids = orderedIds()
    if #ids == 0 then print("No workers found."); return true end
    for _, id in ipairs(ids) do
      local data = workers[id].data or {}
      print(("#%s %-16s %-14s %s"):format(id, workerLabel(workers[id], id), statusOf(workers[id]), progressText(data)))
    end
    return true
  elseif command == "start" then
    local id, width, length, depth = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    if not id or not width or not length or not depth then
      print("Usage: controller.lua start <id> <width> <length> <depth>")
      return true
    end
    sendCommand(id, "start", { width = width, length = length, depth = depth, name = "CLI Quarry" })
    pumpFor(2)
    print(notice)
    return true
  elseif command == "pause" or command == "resume" or command == "recall" or command == "service" or command == "abort" or command == "clear" then
    local id = tonumber(args[2])
    if not id then print("Usage: controller.lua " .. command .. " <id>"); return true end
    sendCommand(id, command)
    pumpFor(2)
    print(notice)
    return true
  elseif command == "rehome" then
    local id = tonumber(args[2])
    if not id or args[3] ~= "RESET" then
      print("Usage: controller.lua rehome <id> RESET")
      return true
    end
    sendCommand(id, "rehome", { confirm = "RESET" })
    pumpFor(2)
    print(notice)
    return true
  end
  return false
end

if #args > 0 and commandLineMode() then return end

discover()
local refreshTimer = os.startTimer(1)

while running do
  render()
  local event, a, b, c = os.pullEvent()
  if event == "rednet_message" and c == common.PROTOCOL then
    handleMessage(a, b)
  elseif event == "char" then
    processChar(a)
  elseif event == "key" then
    local ids = orderedIds()
    if keys and a == keys.up then selected = math.max(1, selected - 1)
    elseif keys and a == keys.down then selected = math.min(math.max(1, #ids), selected + 1)
    elseif keys and a == keys.enter then showInfo() end
  elseif event == "monitor_touch" then
    -- The monitor is display-only in this release. Use the controller keyboard.
    notice, noticeIsError = "Use the controller keyboard for commands.", false
  elseif event == "timer" and a == refreshTimer then
    if common.nowSeconds() - lastDiscovery >= (config.discoverySeconds or 5) then discover() end
    refreshTimer = os.startTimer(1)
  elseif event == "term_resize" or event == "monitor_resize" then
    if monitor and monitor.setTextScale then pcall(monitor.setTextScale, config.monitorTextScale or 0.5) end
  end
end

common.clear(colors and colors.black or nil, colors and colors.white or nil)
print("CC Miner controller stopped. Run 'ccm dashboard' to reopen it.")
