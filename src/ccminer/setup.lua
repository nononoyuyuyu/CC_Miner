-- CC Miner V2 - interactive configuration

local args = { ... }
local common = dofile("/ccminer/lib/common.lua")
local current = common.loadConfig()
local requestedRole = string.lower(tostring(args[1] or (current and current.role) or ""))

if requestedRole ~= "worker" and requestedRole ~= "controller" and requestedRole ~= "gps" then
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("CC MINER V2 SETUP")
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
print("CC MINER V2 SETUP - " .. string.upper(requestedRole))
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
  local key = common.prompt("Network key", previousKey or "ASTRAL-MINE-01", function(value)
    if #value < 8 or #value > 40 then return false, "Use 8 to 40 characters." end
    if value:find("[^%w_-]") then return false, "Use only letters, numbers, '-' and '_'." end
    return true
  end)

  if requestedRole == "worker" then
    config = common.merge(common.defaultWorkerConfig(), current and current.role == "worker" and current or {})
    config.role, config.networkKey = "worker", key
    config.workerName = common.prompt("Worker name", config.workerName or common.safeComputerLabel("Miner"), function(value)
      return #value >= 1 and #value <= 20, "Use 1 to 20 characters."
    end)
    config.fuelTarget = common.promptNumber("Fuel target", config.fuelTarget or 12000, 500, 100000)
    config.reserveEmptySlots = common.promptNumber("Reserved empty slots", config.reserveEmptySlots or 3, 1, 8)
    local lavaChoice = common.prompt("Lava behavior (seal/stop)", config.lavaMode or "seal", function(value)
      value = string.lower(value)
      return value == "seal" or value == "stop", "Enter seal or stop."
    end)
    config.lavaMode = string.lower(lavaChoice)
    if config.lavaMode == "seal" then
      config.sealSide = common.prompt("Seal-block chest side (right/left)", config.sealSide or "right", function(value)
        value = string.lower(value)
        return value == "right" or value == "left", "Enter right or left."
      end):lower()
      config.sealTarget = common.promptNumber("Seal-block target count", config.sealTarget or 64, 16, 512)
      config.sealReserve = common.promptNumber("Return when seal blocks reach", config.sealReserve or 8, 1, math.min(64, config.sealTarget - 1))
    end
    config.gps = config.gps or common.defaultWorkerConfig().gps
    config.gps.enabled = common.promptYesNo("Use GPS when available", config.gps.enabled ~= false)
    if config.gps.enabled then
      config.gps.required = common.promptYesNo("Require GPS for mining", config.gps.required == true)
    else
      config.gps.required = false
    end
    config.attackEntities = common.promptYesNo("Attack blocking entities", config.attackEntities == true)
    config.outputSide, config.fuelSide = "back", "top"
    if os.setComputerLabel then os.setComputerLabel(config.workerName) end
  else
    config = common.merge(common.defaultControllerConfig(), current and current.role == "controller" and current or {})
    config.role, config.networkKey = "controller", key
    config.controllerName = common.prompt("Controller name", config.controllerName or common.safeComputerLabel("Control"), function(value)
      return #value >= 1 and #value <= 20, "Use 1 to 20 characters."
    end)
    config.monitorTextScale = tonumber(common.prompt("Monitor text scale", config.monitorTextScale or 0.5, function(value)
      local number = tonumber(value)
      if not number or number < 0.5 or number > 5 or number * 2 ~= math.floor(number * 2) then
        return false, "Use 0.5, 1.0, 1.5 ... 5.0."
      end
      return true
    end))
    config.touchEnabled = common.promptYesNo("Enable monitor touch controls", config.touchEnabled ~= false)
    if os.setComputerLabel then os.setComputerLabel(config.controllerName) end
  end
end

local ok, err = common.saveConfig(config)
if not ok then error("Cannot save configuration: " .. tostring(err), 0) end

if requestedRole == "worker" and (not fs.exists(common.STATE_PATH) or not current or current.role ~= "worker") then
  common.saveTable(common.STATE_PATH, common.defaultState())
end

local startupMarker = "-- CC_MINER_V2_STARTUP"
local existingStartup = fs.exists("/startup.lua") and common.readAll("/startup.lua") or nil
if existingStartup and not existingStartup:find(startupMarker, 1, true) then
  local backupOk, backupError = common.writeAllAtomic("/startup.user.lua", existingStartup)
  if not backupOk then error("Cannot preserve existing startup.lua: " .. tostring(backupError), 0) end
end

local startup = startupMarker .. [[
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
