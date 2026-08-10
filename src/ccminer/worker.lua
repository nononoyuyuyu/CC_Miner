-- CC Miner V2 - autonomous quarry worker
-- Place the turtle at its dock, facing the quarry entrance.
-- Local coordinates: home=(0,0,0), forward=+Z, right=+X, down=-Y.

local common = dofile("/ccminer/lib/common.lua")
local protocol = dofile("/ccminer/lib/protocol.lua")
local quarry = dofile("/ccminer/lib/quarry.lua")

if not turtle then error("worker.lua must run on a turtle", 0) end

local config, configError = common.loadConfig()
if not config or config.role ~= "worker" then
  error(configError or "Worker configuration not found. Run: ccm setup worker", 0)
end

local rawState, stateError = common.loadTable(common.STATE_PATH, common.defaultState())
local state = common.merge(common.defaultState(), rawState)
if stateError then common.log("WARN", stateError) end

local lastHeartbeat = 0
local networkReady = false
local pollNetwork

local function saveState()
  state.schema = common.SCHEMA
  state.version = common.VERSION
  state.updatedAt = common.nowSeconds()
  local ok, err = common.saveTable(common.STATE_PATH, state)
  if not ok then
    common.log("ERROR", "State save failed: " .. tostring(err))
    error("State save failed: " .. tostring(err), 0)
  end
end

local function poseCopy(pose)
  pose = pose or state.pose
  return { x = pose.x or 0, y = pose.y or 0, z = pose.z or 0, dir = pose.dir or 0 }
end

local function beginPhysicalAction(kind, details)
  if state.pendingAction then
    return false, "An unresolved physical action is already recorded. Rehome the turtle before continuing."
  end
  state.pendingAction = {
    kind = tostring(kind or "unknown"),
    poseBefore = poseCopy(),
    details = details or {},
    startedAt = common.nowSeconds(),
  }
  saveState()
  return true
end

local function cancelPhysicalAction()
  state.pendingAction = nil
  saveState()
end

local function commitPhysicalAction()
  state.pendingAction = nil
  saveState()
end

local function isHome()
  return state.pose.x == 0 and state.pose.y == 0 and state.pose.z == 0
end

local function distance(a, b)
  a, b = a or state.pose, b or { x = 0, y = 0, z = 0 }
  return math.abs((a.x or 0) - (b.x or 0))
    + math.abs((a.y or 0) - (b.y or 0))
    + math.abs((a.z or 0) - (b.z or 0))
end

local function inventoryStats()
  local used, empty, items = 0, 0, 0
  for slot = 1, 16 do
    local count = turtle.getItemCount(slot)
    if count > 0 then
      used = used + 1
      items = items + count
    else
      empty = empty + 1
    end
  end
  return used, empty, items
end

local function fuelLevel()
  local ok, level = pcall(turtle.getFuelLevel)
  if not ok then return 0 end
  return level
end

local function fuelLimit()
  local ok, limit = pcall(turtle.getFuelLimit)
  if not ok then return 0 end
  return limit
end

local function jobSnapshot()
  if not state.job then return nil end
  return {
    id = state.job.id,
    name = state.job.name,
    kind = state.job.kind,
    width = state.job.width,
    length = state.job.length,
    depth = state.job.depth,
    cursor = state.job.cursor or 0,
    total = state.job.total or 0,
    percent = common.percent(state.job.cursor or 0, state.job.total or 0),
    startedAt = state.job.startedAt,
  }
end

local function statusPayload()
  local used, empty, items = inventoryStats()
  return {
    id = os.getComputerID(),
    label = config.workerName or common.safeComputerLabel("Miner"),
    status = state.status,
    phase = state.phase,
    pose = poseCopy(),
    atHome = isHome(),
    job = jobSnapshot(),
    fuel = fuelLevel(),
    fuelLimit = fuelLimit(),
    inventoryUsed = used,
    inventoryEmpty = empty,
    inventoryItems = items,
    lastError = state.lastError,
    completionReason = state.completionReason,
    recoveryRequired = state.pendingAction ~= nil,
    pendingAction = state.pendingAction and {
      kind = state.pendingAction.kind,
      startedAt = state.pendingAction.startedAt,
    } or nil,
    request = state.request,
    stats = common.copy(state.stats),
    version = common.VERSION,
    updatedAt = state.updatedAt,
  }
end

local function sendStatus(target, request)
  if not networkReady then return false end
  local message = protocol.message("status", config.networkKey, statusPayload(), target)
  if request and request.id then message.replyTo = request.id end
  if target then return protocol.send(target, message) end
  return protocol.broadcast(message)
end

local function sendAck(target, request, ok, text)
  return protocol.reply(target, config.networkKey, request, "ack", {
    ok = ok == true,
    message = tostring(text or ""),
    status = statusPayload(),
  })
end

local function markBlocked(message)
  state.status = "blocked"
  state.phase = "blocked"
  state.lastError = tostring(message or "Unknown error")
  common.log("ERROR", state.lastError)
  saveState()
  sendStatus()
end

local function commandSeen(id)
  if not id then return false end
  state.recentCommands = state.recentCommands or {}
  for _, existing in ipairs(state.recentCommands) do
    if existing == id then return true end
  end
  state.recentCommands[#state.recentCommands + 1] = id
  while #state.recentCommands > 32 do table.remove(state.recentCommands, 1) end
  return false
end

local function validateJob(payload)
  payload = payload or {}
  local width = tonumber(payload.width)
  local length = tonumber(payload.length)
  local depth = tonumber(payload.depth)
  if not width or width ~= math.floor(width) then return nil, "Width must be a whole number." end
  if not length or length ~= math.floor(length) then return nil, "Length must be a whole number." end
  if not depth or depth ~= math.floor(depth) then return nil, "Depth must be a whole number." end
  if width < 1 or width > config.maxWidth then return nil, "Width out of range (1-" .. config.maxWidth .. ")." end
  if length < 1 or length > config.maxLength then return nil, "Length out of range (1-" .. config.maxLength .. ")." end
  if depth < 1 or depth > config.maxDepth then return nil, "Depth out of range (1-" .. config.maxDepth .. ")." end
  local total = width * length * depth
  if total > config.maxVolume then return nil, "Volume exceeds limit " .. tostring(config.maxVolume) .. "." end
  return {
    kind = "quarry",
    id = tostring(payload.jobId or ("job-" .. common.nowMillis())),
    name = tostring(payload.name or "Quarry"),
    width = width,
    length = length,
    depth = depth,
    cursor = 0,
    total = total,
    startedAt = common.nowSeconds(),
  }
end

local function startJob(payload)
  if state.pendingAction then return false, "Recovery required after an interrupted physical action. Place the turtle in its dock and use REHOME." end
  if not isHome() then return false, "Worker is not at home. Recall or physically recover it first." end
  if state.status == "working" or state.status == "waiting_fuel" or state.status == "waiting_output" then
    return false, "Worker is busy."
  end
  local job, err = validateJob(payload)
  if not job then return false, err end
  state.job = job
  state.checkpoint = nil
  -- Always clean the inventory and top up fuel before entering a new quarry.
  -- At home there is no checkpoint, so this service finishes directly into mining.
  state.service = {
    resumeAfter = true,
    finalStatus = "working",
    preserveCheckpoint = false,
    reason = "job_start",
    startedAt = common.nowSeconds(),
  }
  state.request = nil
  state.status = "working"
  state.phase = "starting_service"
  state.lastError = nil
  state.completionReason = nil
  state.pose = { x = 0, y = 0, z = 0, dir = state.pose.dir or 0 }
  saveState()
  common.log("INFO", ("Job started: %s %dx%dx%d"):format(job.id, job.width, job.length, job.depth))
  return true, "Job accepted."
end

local function applyControlCommand(command, payload)
  payload = payload or {}
  if state.pendingAction and command ~= "rehome" and command ~= "ping" and command ~= "status" then
    return false, "Recovery required: physically return the turtle to its dock, face it toward the quarry, then use REHOME."
  end
  if command == "start" then
    return startJob(payload)
  elseif command == "pause" then
    if state.status == "working" or state.status == "waiting_fuel" or state.status == "waiting_output" then
      -- A service route may be between home and the quarry. Keep the service
      -- object intact so resume can safely finish the return/resupply cycle.
      state.status = "paused"
      state.phase = state.service and "service_paused" or "paused"
      state.request = nil
      saveState()
      return true, "Pause accepted. Current route state was preserved."
    end
    return false, "Worker is not running."
  elseif command == "resume" then
    if state.status == "paused" or state.status == "blocked" then
      state.lastError = nil
      if state.service then
        state.status = "working"
        state.phase = "service_requested"
      elseif isHome() and state.checkpoint and state.job then
        state.service = {
          resumeAfter = true,
          finalStatus = "working",
          preserveCheckpoint = false,
          reason = "resume",
        }
        state.status = "working"
        state.phase = "resume_service"
      else
        state.status = "working"
        state.phase = "mining"
      end
      state.request = nil
      saveState()
      return true, "Resume accepted."
    elseif state.status == "waiting_fuel" or state.status == "waiting_output" then
      state.status = "working"
      saveState()
      return true, "Service retry accepted."
    end
    return false, "Worker is not paused or blocked."
  elseif command == "recall" then
    if not state.job then return false, "No active job." end
    state.request = "recall"
    if state.status ~= "working" then state.status = "working" end
    saveState()
    return true, "Recall accepted. Worker will return and pause."
  elseif command == "service" then
    state.request = "service"
    if state.status ~= "working" then state.status = "working" end
    saveState()
    return true, "Service return accepted."
  elseif command == "abort" then
    if not state.job then return false, "No job to abort." end
    state.request = "abort"
    if state.status ~= "working" then state.status = "working" end
    saveState()
    return true, "Abort accepted. Worker will return home."
  elseif command == "clear" then
    if state.pendingAction then return false, "Cannot clear while physical position is uncertain. Use REHOME." end
    if not isHome() then return false, "Worker must be at home." end
    if state.status == "working" or state.status == "waiting_fuel" or state.status == "waiting_output" then
      return false, "Worker is busy."
    end
    state.job = nil
    state.checkpoint = nil
    state.service = nil
    state.request = nil
    state.pendingAction = nil
    state.status = "idle"
    state.phase = "home"
    state.lastError = nil
    state.completionReason = nil
    saveState()
    return true, "Job record cleared."
  elseif command == "rehome" then
    if payload.confirm ~= "RESET" then return false, "Rehome requires confirm=RESET." end
    if state.status == "working" or state.status == "waiting_fuel" or state.status == "waiting_output" then
      return false, "Stop the worker before rehoming."
    end
    state.pose = { x = 0, y = 0, z = 0, dir = 0 }
    state.job = nil
    state.checkpoint = nil
    state.service = nil
    state.request = nil
    state.pendingAction = nil
    state.status = "idle"
    state.phase = "home"
    state.lastError = nil
    state.completionReason = nil
    saveState()
    return true, "Local position reset to home."
  elseif command == "ping" or command == "status" then
    return true, "Status sent."
  end
  return false, "Unknown command: " .. tostring(command)
end

local function handleMessage(sender, message)
  local valid = protocol.validate(message, config.networkKey, os.getComputerID())
  if not valid then return end
  if tonumber(config.controllerId or 0) > 0 and tonumber(sender) ~= tonumber(config.controllerId) then return end

  if message.kind == "discover" then
    sendStatus(sender, message)
    return
  end

  if message.kind ~= "command" then return end
  if commandSeen(message.id) then
    sendAck(sender, message, true, "Duplicate command ignored; previous result retained.")
    return
  end

  local payload = message.payload or {}
  local command = tostring(payload.command or "")
  local ok, text = applyControlCommand(command, payload)
  sendAck(sender, message, ok, text)
  if command == "status" or command == "ping" then sendStatus(sender, message) end
end

pollNetwork = function(timeout)
  if not networkReady then return false end
  local sender, message = protocol.receive(timeout)
  if not sender then return false end
  handleMessage(sender, message)
  return true
end

local function drainNetwork(limit)
  limit = limit or 8
  for _ = 1, limit do
    if not pollNetwork(0) then break end
  end
end

local function heartbeat(force)
  local now = common.nowSeconds()
  if force or now - lastHeartbeat >= (config.heartbeatSeconds or 2) then
    sendStatus()
    lastHeartbeat = now
  end
end

local function updatePoseForForward()
  local dir = state.pose.dir % 4
  if dir == 0 then state.pose.z = state.pose.z + 1
  elseif dir == 1 then state.pose.x = state.pose.x + 1
  elseif dir == 2 then state.pose.z = state.pose.z - 1
  else state.pose.x = state.pose.x - 1 end
end

local function turnRight()
  local prepared, prepareError = beginPhysicalAction("turn_right")
  if not prepared then return false, prepareError end
  local ok, err = turtle.turnRight()
  if not ok then
    cancelPhysicalAction()
    return false, err or "Turn right failed."
  end
  state.pose.dir = (state.pose.dir + 1) % 4
  state.stats.turns = (state.stats.turns or 0) + 1
  commitPhysicalAction()
  heartbeat(false)
  drainNetwork(2)
  return true
end

local function turnLeft()
  local prepared, prepareError = beginPhysicalAction("turn_left")
  if not prepared then return false, prepareError end
  local ok, err = turtle.turnLeft()
  if not ok then
    cancelPhysicalAction()
    return false, err or "Turn left failed."
  end
  state.pose.dir = (state.pose.dir + 3) % 4
  state.stats.turns = (state.stats.turns or 0) + 1
  commitPhysicalAction()
  heartbeat(false)
  drainNetwork(2)
  return true
end

local function turnTo(targetDir)
  targetDir = targetDir % 4
  local diff = (targetDir - state.pose.dir) % 4
  if diff == 1 then return turnRight() end
  if diff == 2 then
    local ok, err = turnRight()
    if not ok then return false, err end
    return turnRight()
  end
  if diff == 3 then return turnLeft() end
  return true
end

local movement = {
  forward = { move = turtle.forward, inspect = turtle.inspect, dig = turtle.dig, attack = turtle.attack, side = "front" },
  up = { move = turtle.up, inspect = turtle.inspectUp, dig = turtle.digUp, attack = turtle.attackUp, side = "top" },
  down = { move = turtle.down, inspect = turtle.inspectDown, dig = turtle.digDown, attack = turtle.attackDown, side = "bottom" },
}

local function blockName(data)
  return type(data) == "table" and tostring(data.name or "unknown") or "unknown"
end

local function isProtected(data)
  local name = blockName(data)
  return config.protectedBlocks and config.protectedBlocks[name] == true, name
end

local function isLava(data)
  local name = string.lower(blockName(data))
  return name:find("lava", 1, true) ~= nil
end

local function isInventoryBlock(side, data)
  if peripheral and peripheral.hasType then
    local ok, result = pcall(peripheral.hasType, side, "inventory")
    if ok and result == true then return true end
  end
  local wrapped = peripheral and peripheral.wrap(side) or nil
  if wrapped and (type(wrapped.list) == "function" or type(wrapped.size) == "function") then
    return true
  end
  local name = string.lower(blockName(data))
  local markers = { "chest", "barrel", "shulker_box", "drawer", "crate", "vault" }
  for _, marker in ipairs(markers) do
    if name:find(marker, 1, true) then return true end
  end
  return false
end

local function movementInterrupted(context)
  if context ~= "mining" and context ~= "service" then return false end
  if state.status ~= "working" then return true end
  return state.request ~= nil
end

local function updatePoseAfterMove(direction)
  if direction == "forward" then updatePoseForForward()
  elseif direction == "up" then state.pose.y = state.pose.y + 1
  elseif direction == "down" then state.pose.y = state.pose.y - 1 end
  state.stats.moves = (state.stats.moves or 0) + 1
end

local function moveOne(direction, context)
  local action = movement[direction]
  if not action then return false, "Unknown movement: " .. tostring(direction) end
  local retries = tonumber(config.moveRetries) or 20
  local delay = tonumber(config.moveRetryDelay) or 0.4
  local lastReason = "Movement failed."

  for _ = 1, retries do
    drainNetwork(3)
    if movementInterrupted(context) then return false, "control_request" end

    local level = fuelLevel()
    if level ~= "unlimited" and tonumber(level or 0) <= 0 then return false, "out_of_fuel" end

    local hasBlock, data = action.inspect()
    if hasBlock then
      local protected, name = isProtected(data)
      if protected then return false, "protected:" .. name, data end
      if isInventoryBlock(action.side, data) then return false, "protected_inventory:" .. name, data end
      if config.stopOnLava and isLava(data) then return false, "lava:" .. name, data end
      local _, emptySlots = inventoryStats()
      if emptySlots <= 0 then
        return false, "inventory_full"
      end
      local prepared, prepareError = beginPhysicalAction("dig_" .. direction, { block = name })
      if not prepared then return false, prepareError end
      local dug, digReason = action.dig()
      if dug then
        state.stats.blocksDug = (state.stats.blocksDug or 0) + 1
        commitPhysicalAction()
        sleep(0.1)
      else
        cancelPhysicalAction()
        lastReason = digReason or ("Cannot dig " .. name)
        sleep(delay)
      end
    end

    local prepared, prepareError = beginPhysicalAction("move_" .. direction)
    if not prepared then return false, prepareError end
    local moved, moveReason = action.move()
    if moved then
      updatePoseAfterMove(direction)
      commitPhysicalAction()
      heartbeat(false)
      return true
    end

    cancelPhysicalAction()

    lastReason = moveReason or lastReason
    local blockedNow = action.inspect()
    if not blockedNow then
      if config.attackEntities and action.attack then
        pcall(action.attack)
      end
      sleep(delay)
    else
      sleep(0.1)
    end
  end
  return false, lastReason
end

local function moveX(targetX, context)
  while state.pose.x ~= targetX do
    local targetDir = state.pose.x < targetX and 1 or 3
    local ok, err = turnTo(targetDir)
    if not ok then return false, err end
    ok, err = moveOne("forward", context)
    if not ok then return false, err end
  end
  return true
end

local function moveZ(targetZ, context)
  while state.pose.z ~= targetZ do
    local targetDir = state.pose.z < targetZ and 0 or 2
    local ok, err = turnTo(targetDir)
    if not ok then return false, err end
    ok, err = moveOne("forward", context)
    if not ok then return false, err end
  end
  return true
end

local function moveY(targetY, context)
  while state.pose.y < targetY do
    local ok, err = moveOne("up", context)
    if not ok then return false, err end
  end
  while state.pose.y > targetY do
    local ok, err = moveOne("down", context)
    if not ok then return false, err end
  end
  return true
end

local function navigateTo(target, route, context)
  target = target or { x = 0, y = 0, z = 0 }
  local ok, err
  if route == "home" then
    ok, err = moveY(target.y or 0, context); if not ok then return false, err end
    ok, err = moveX(target.x or 0, context); if not ok then return false, err end
    ok, err = moveZ(target.z or 0, context); if not ok then return false, err end
  else
    -- This is the exact reverse of the home route. It stays inside cells which
    -- were already traversed instead of cutting across an unfinished row.
    ok, err = moveZ(target.z or 0, context); if not ok then return false, err end
    ok, err = moveX(target.x or 0, context); if not ok then return false, err end
    ok, err = moveY(target.y or 0, context); if not ok then return false, err end
  end
  return true
end

local function firstEmptySlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then return slot end
  end
  return nil
end

local function looksLikeInventoryBlock(data)
  -- Conservative fallback used only when generic inventory peripherals are
  -- unavailable. Limiting this to known vanilla containers prevents drop()
  -- from ejecting items in front of a block which merely sounds like storage.
  local name = string.lower(blockName(data))
  if name == "minecraft:chest" or name == "minecraft:trapped_chest" or name == "minecraft:barrel" then
    return true
  end
  return name:match("^minecraft:[%w_]+shulker_box$") ~= nil
end

local function inventoryPresent(side, inspectFunction)
  if peripheral and peripheral.hasType then
    local ok, result = pcall(peripheral.hasType, side, "inventory")
    if ok and result == true then return true end
  end
  local wrapped = peripheral and peripheral.wrap(side) or nil
  if wrapped and (type(wrapped.list) == "function" or type(wrapped.size) == "function") then
    return true
  end
  if inspectFunction then
    local ok, present, data = pcall(inspectFunction)
    if ok and present and looksLikeInventoryBlock(data) then return true end
  end
  return false
end

local function unloadAtHome()
  state.phase = "unloading"
  state.status = "working"
  saveState()
  local originalSlot = turtle.getSelectedSlot()
  local outputSide = config.outputSide or "back"
  local restoreDir = state.pose.dir
  local dropFunction
  local checkSide
  local inspectFunction

  if outputSide == "back" then
    local ok, err = turnTo(2)
    if not ok then return false, err end
    dropFunction = turtle.drop
    checkSide = "front"
    inspectFunction = turtle.inspect
  elseif outputSide == "front" then
    local ok, err = turnTo(0)
    if not ok then return false, err end
    dropFunction = turtle.drop
    checkSide = "front"
    inspectFunction = turtle.inspect
  elseif outputSide == "top" then
    dropFunction = turtle.dropUp
    checkSide = "top"
    inspectFunction = turtle.inspectUp
  elseif outputSide == "bottom" then
    dropFunction = turtle.dropDown
    checkSide = "bottom"
    inspectFunction = turtle.inspectDown
  else
    return false, "Unsupported output side: " .. tostring(outputSide)
  end

  if not inventoryPresent(checkSide, inspectFunction) then
    if outputSide == "back" or outputSide == "front" then turnTo(restoreDir) end
    turtle.select(originalSlot)
    return false, "Output inventory missing on configured side " .. outputSide .. "."
  end

  local allDropped = true
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      dropFunction()
      if turtle.getItemCount(slot) > 0 then allDropped = false end
    end
  end

  if outputSide == "back" or outputSide == "front" then
    local ok, err = turnTo(restoreDir)
    if not ok then return false, err end
  end
  turtle.select(originalSlot)

  if not allDropped then return false, "Output inventory is full." end
  state.stats.unloads = (state.stats.unloads or 0) + 1
  saveState()
  return true
end

local function targetFuelForService()
  local target = tonumber(config.fuelTarget) or 12000
  if state.service and state.service.resumeAfter and state.checkpoint then
    local checkpointDistance = distance({ x = 0, y = 0, z = 0 }, state.checkpoint)
    -- Reserve enough for the trip back to the checkpoint and a complete
    -- emergency return, plus the configured operating buffer.
    target = math.max(target, checkpointDistance * 2 + (tonumber(config.fuelBuffer) or 256))
  end
  local limit = fuelLimit()
  if limit == "unlimited" then return "unlimited" end
  if type(limit) == "number" and limit > 0 then target = math.min(target, limit) end
  return math.max(1, math.floor(target))
end

local function refuelAtHome()
  state.phase = "refueling"
  state.status = "working"
  saveState()
  local current = fuelLevel()
  if current == "unlimited" then return true end
  local target = targetFuelForService()
  local fuelSide = config.fuelSide or "top"
  if fuelSide ~= "top" then return false, "This release supports a fuel inventory above the turtle only." end
  if not inventoryPresent("top", turtle.inspectUp) then return false, "Fuel inventory missing above the turtle." end
  if target == "unlimited" or current >= target then return true end

  local originalSlot = turtle.getSelectedSlot()
  local attempts = 0
  while fuelLevel() ~= "unlimited" and fuelLevel() < target do
    drainNetwork(3)
    if movementInterrupted("service") then
      turtle.select(originalSlot)
      return false, "control_request"
    end
    attempts = attempts + 1
    if attempts > 1024 then
      turtle.select(originalSlot)
      return false, "Fuel loading safety limit reached."
    end
    local slot = firstEmptySlot()
    if not slot then
      turtle.select(originalSlot)
      return false, "No empty slot available while refueling."
    end
    turtle.select(slot)
    local sucked = turtle.suckUp(1)
    if not sucked then
      turtle.select(originalSlot)
      return false, "Fuel inventory is empty."
    end
    local validFuel = turtle.refuel(0)
    if not validFuel then
      turtle.dropUp()
      turtle.select(originalSlot)
      return false, "Fuel chest contains a non-fuel item. Keep only valid turtle fuel in it."
    end
    local before = fuelLevel()
    local consumed = turtle.refuel(1)
    local after = fuelLevel()
    if not consumed then
      turtle.dropUp()
      turtle.select(originalSlot)
      return false, "Turtle refused the selected fuel item."
    end
    if turtle.getItemCount(slot) > 0 then turtle.dropUp() end
    if type(before) == "number" and type(after) == "number" and after > before then
      state.stats.refuels = (state.stats.refuels or 0) + 1
    end
  end
  turtle.select(originalSlot)
  saveState()
  return true
end

local function beginService(resumeAfter, finalStatus, reason, preserveCheckpoint)
  if not state.service then
    if not isHome() and not state.checkpoint then state.checkpoint = poseCopy() end
    state.service = {
      resumeAfter = resumeAfter == true,
      finalStatus = finalStatus or (resumeAfter and "working" or "paused"),
      preserveCheckpoint = preserveCheckpoint == true,
      reason = reason or "service",
      startedAt = common.nowSeconds(),
    }
  else
    if resumeAfter == false then state.service.resumeAfter = false end
    if finalStatus then state.service.finalStatus = finalStatus end
    if preserveCheckpoint ~= nil then state.service.preserveCheckpoint = preserveCheckpoint == true end
    if reason then state.service.reason = reason end
  end
  state.status = "working"
  state.phase = "service_requested"
  state.request = nil
  saveState()
end

local function finishService()
  local service = state.service or {}
  local finalStatus = service.finalStatus or (service.resumeAfter and "working" or "paused")
  local preserveCheckpoint = service.preserveCheckpoint == true
  state.service = nil
  state.request = nil
  state.lastError = nil

  if finalStatus == "complete" then
    state.stats.jobsCompleted = (state.stats.jobsCompleted or 0) + 1
    state.checkpoint = nil
    state.status = "complete"
    state.phase = "home"
  elseif finalStatus == "aborted" then
    state.checkpoint = nil
    state.status = "aborted"
    state.phase = "home"
  elseif finalStatus == "paused" then
    if not preserveCheckpoint then state.checkpoint = nil end
    state.status = "paused"
    state.phase = "home_paused"
  else
    state.checkpoint = nil
    state.status = "working"
    state.phase = "mining"
  end
  saveState()
  heartbeat(true)
end

local function continueService()
  if not state.service then return true end
  state.status = "working"

  if not isHome() then
    state.phase = "returning"
    saveState()
    local ok, err = navigateTo({ x = 0, y = 0, z = 0 }, "home", "service")
    if not ok then
      if err == "control_request" then return false end
      markBlocked("Return to home failed: " .. tostring(err))
      return false
    end
  end

  local ok, err = turnTo(0)
  if not ok then markBlocked("Cannot face quarry at home: " .. tostring(err)); return false end
  if movementInterrupted("service") then return false end

  ok, err = unloadAtHome()
  if not ok then
    if err == "control_request" then return false end
    state.status = "waiting_output"
    state.phase = "waiting_output"
    state.lastError = err
    saveState()
    heartbeat(true)
    return false
  end

  if movementInterrupted("service") then return false end

  ok, err = refuelAtHome()
  if not ok then
    if err == "control_request" then return false end
    state.status = "waiting_fuel"
    state.phase = "waiting_fuel"
    state.lastError = err
    saveState()
    heartbeat(true)
    return false
  end

  if movementInterrupted("service") then return false end

  if state.service.resumeAfter and state.checkpoint then
    local checkpoint = poseCopy(state.checkpoint)
    state.phase = "going_back"
    state.status = "working"
    state.lastError = nil
    saveState()
    ok, err = navigateTo(checkpoint, "work", "service")
    if not ok then
      if err == "control_request" then return false end
      markBlocked("Return to work point failed: " .. tostring(err))
      return false
    end
    ok, err = turnTo(checkpoint.dir)
    if not ok then markBlocked("Cannot restore work direction: " .. tostring(err)); return false end
    if movementInterrupted("service") then return false end
    state.checkpoint = nil
  end

  finishService()
  return true
end

local function quarryCell(job, index)
  return quarry.cellForJob(job, index)
end

local function requiredDirectionTo(target)
  local dx = target.x - state.pose.x
  local dy = target.y - state.pose.y
  local dz = target.z - state.pose.z
  local manhattan = math.abs(dx) + math.abs(dy) + math.abs(dz)
  if manhattan ~= 1 then return nil, "path_desync:" .. tostring(manhattan) end
  if dy == 1 then return "up", nil, dy end
  if dy == -1 then return "down", nil, dy end
  if dx == 1 then return "forward", 1, 0 end
  if dx == -1 then return "forward", 3, 0 end
  if dz == 1 then return "forward", 0, 0 end
  if dz == -1 then return "forward", 2, 0 end
  return nil, "invalid_delta"
end

local function shouldService()
  local _, empty = inventoryStats()
  if empty <= (tonumber(config.reserveEmptySlots) or 3) then return true, "inventory" end
  local level = fuelLevel()
  if level ~= "unlimited" then
    local needed = distance(state.pose, { x = 0, y = 0, z = 0 }) + (tonumber(config.fuelBuffer) or 256)
    if tonumber(level or 0) <= needed then return true, "fuel" end
  end
  return false
end

local function handlePendingRequest()
  if state.request == "recall" then
    beginService(false, "paused", "recall", true)
    return true
  elseif state.request == "service" then
    beginService(false, "paused", "manual_service", true)
    return true
  elseif state.request == "abort" then
    beginService(false, "aborted", "abort", false)
    return true
  end
  return false
end

local function runMiningStep()
  if handlePendingRequest() then return end
  if state.service then continueService(); return end
  if not state.job then
    state.status = "idle"
    state.phase = isHome() and "home" or "unknown_position"
    saveState()
    return
  end

  local job = state.job
  job.cursor = tonumber(job.cursor) or 0
  job.total = tonumber(job.total) or (job.width * job.length * job.depth)
  if job.cursor >= job.total then
    state.completionReason = state.completionReason or "completed"
    beginService(false, "complete", "job_complete", false)
    continueService()
    return
  end

  local serviceNeeded, reason = shouldService()
  if serviceNeeded then
    beginService(true, "working", "automatic_" .. tostring(reason), false)
    continueService()
    return
  end

  state.phase = "mining"
  state.status = "working"
  state.lastError = nil
  local target = quarryCell(job, job.cursor)
  local direction, targetDir, verticalDelta = requiredDirectionTo(target)
  if not direction then
    markBlocked("Quarry path/state mismatch at cell " .. tostring(job.cursor) .. ". Do not move the turtle by hand. " .. tostring(targetDir))
    return
  end

  if targetDir ~= nil then
    local ok, err = turnTo(targetDir)
    if not ok then markBlocked("Turn failed: " .. tostring(err)); return end
  end

  local ok, err = moveOne(direction, "mining")
  if not ok then
    if err == "control_request" then return end
    if verticalDelta == -1 and common.startsWith(err or "", "protected:minecraft:bedrock") then
      job.total = job.cursor
      state.completionReason = "bedrock_reached"
      saveState()
      beginService(false, "complete", "bedrock", false)
      continueService()
      return
    end
    markBlocked("Mining stopped at cell " .. tostring(job.cursor) .. ": " .. tostring(err))
    return
  end

  job.cursor = job.cursor + 1
  saveState()
  heartbeat(false)
end

local function displayLocalStatus()
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("CC Miner V2 Worker")
  print("ID: " .. os.getComputerID() .. "  " .. tostring(config.workerName))
  print("Status: " .. tostring(state.status) .. " / " .. tostring(state.phase))
  print(("Pose: x=%d y=%d z=%d d=%d"):format(state.pose.x, state.pose.y, state.pose.z, state.pose.dir))
  local level = fuelLevel()
  print("Fuel: " .. tostring(level) .. " / " .. tostring(fuelLimit()))
  local used, empty, items = inventoryStats()
  print(("Inventory: %d slots, %d empty, %d items"):format(used, empty, items))
  if state.job then
    print(("Job: %s %dx%dx%d"):format(tostring(state.job.name), state.job.width, state.job.length, state.job.depth))
    print(("Progress: %d/%d (%d%%)"):format(state.job.cursor or 0, state.job.total or 0, common.percent(state.job.cursor or 0, state.job.total or 0)))
  else
    print("Job: none")
  end
  if state.lastError then print("Error: " .. common.fit(state.lastError, 50)) end
  print("")
  print("Remote control is active. Hold Ctrl+T to stop locally.")
end

local function preflight()
  if not os.getComputerLabel or not os.getComputerLabel() then
    if os.setComputerLabel then os.setComputerLabel(config.workerName) end
  end
  local opened, names = protocol.open()
  networkReady = opened
  if not opened then
    common.log("ERROR", "No wireless modem found.")
    printError("No wireless modem found. Equip one on the turtle.")
  else
    common.log("INFO", "Wireless modem opened: " .. table.concat(names, ","))
  end
  state.pose.dir = (tonumber(state.pose.dir) or 0) % 4
  state.pose.x = tonumber(state.pose.x) or 0
  state.pose.y = tonumber(state.pose.y) or 0
  state.pose.z = tonumber(state.pose.z) or 0
  state.stats = common.merge(common.defaultState().stats, state.stats)
  if state.pendingAction then
    local pending = state.pendingAction
    state.status = "blocked"
    state.phase = "recovery_required"
    state.request = nil
    state.service = nil
    state.lastError = ("Power loss occurred during '%s' from x=%s y=%s z=%s dir=%s. Physical position is uncertain. Return the turtle to its dock, face the quarry, then use REHOME."):format(
      tostring(pending.kind or "unknown"),
      tostring(pending.poseBefore and pending.poseBefore.x or "?"),
      tostring(pending.poseBefore and pending.poseBefore.y or "?"),
      tostring(pending.poseBefore and pending.poseBefore.z or "?"),
      tostring(pending.poseBefore and pending.poseBefore.dir or "?")
    )
    common.log("ERROR", state.lastError)
  end
  saveState()
  displayLocalStatus()
  heartbeat(true)
end

preflight()

while true do
  drainNetwork(12)
  if state.request and state.status ~= "working" then state.status = "working" end

  if state.status == "working" then
    if state.request then handlePendingRequest() end
    if state.service then continueService() else runMiningStep() end
  elseif state.status == "waiting_output" or state.status == "waiting_fuel" then
    if state.service then
      continueService()
      if state.status == "waiting_output" or state.status == "waiting_fuel" then sleep(3) end
    else
      markBlocked("Service state is missing while waiting.")
    end
  else
    pollNetwork(0.5)
  end

  heartbeat(false)
  if state.status ~= "working" then displayLocalStatus() end
end
