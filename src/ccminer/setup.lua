-- CC Miner V2 - interactive configuration

local args = { ... }
local common = dofile("/ccminer/lib/common.lua")

local current = common.loadConfig()
local requestedRole = string.lower(tostring(args[1] or (current and current.role) or ""))
if requestedRole ~= "worker" and requestedRole ~= "controller" then
  common.clear(colors and colors.black or nil, colors and colors.white or nil)
  print("CC MINER V2 SETUP")
  print("")
  print("1. Worker (mining turtle)")
  print("2. Controller (computer)")
  print("")
  local choice = common.promptNumber("Role", turtle and 1 or 2, 1, 2)
  requestedRole = choice == 1 and "worker" or "controller"
end

if requestedRole == "worker" and not turtle then
  error("Worker role can only be configured on a turtle.", 0)
end

local previousKey = current and current.networkKey
if previousKey == "CHANGE_ME" then previousKey = nil end
local suggestedKey = previousKey or "ASTRAL-MINE-01"

common.clear(colors and colors.black or nil, colors and colors.white or nil)
print("CC MINER V2 SETUP - " .. string.upper(requestedRole))
print("")
print("All devices in one mining system must use the SAME network key.")
print("Use only ASCII letters, numbers, '-' and '_'.")
print("")

local key = common.prompt("Network key", suggestedKey, function(value)
  if #value < 8 or #value > 40 then return false, "Use 8 to 40 characters." end
  if value:find("[^%w_-]") then return false, "Use only letters, numbers, '-' and '_'." end
  return true
end)

local config
if requestedRole == "worker" then
  config = common.merge(common.defaultWorkerConfig(), current and current.role == "worker" and current or {})
  config.role = "worker"
  config.networkKey = key
  config.workerName = common.prompt("Worker name", config.workerName or common.safeComputerLabel("Miner"), function(value)
    return #value >= 1 and #value <= 20, "Use 1 to 20 characters."
  end)
  config.fuelTarget = common.promptNumber("Fuel target", config.fuelTarget or 12000, 500, 100000)
  config.reserveEmptySlots = common.promptNumber("Reserved empty inventory slots", config.reserveEmptySlots or 3, 1, 8)
  config.stopOnLava = common.promptYesNo("Stop before lava", config.stopOnLava ~= false)
  config.attackEntities = common.promptYesNo("Attack entities blocking movement", config.attackEntities == true)
  config.outputSide = "back"
  config.fuelSide = "top"
  if os.setComputerLabel then os.setComputerLabel(config.workerName) end
else
  config = common.merge(common.defaultControllerConfig(), current and current.role == "controller" and current or {})
  config.role = "controller"
  config.networkKey = key
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
  if os.setComputerLabel then os.setComputerLabel(config.controllerName) end
end

local ok, err = common.saveConfig(config)
if not ok then error("Cannot save configuration: " .. tostring(err), 0) end

if requestedRole == "worker" and (not fs.exists(common.STATE_PATH) or not current or current.role ~= "worker") then
  common.saveTable(common.STATE_PATH, common.defaultState())
end

local startupMarker = "-- CC_MINER_V2_STARTUP"
local existingStartup = nil
if fs.exists("/startup.lua") then existingStartup = common.readAll("/startup.lua") end
if existingStartup and not existingStartup:find(startupMarker, 1, true) then
  local startupBackupOk, startupBackupError = common.writeAllAtomic("/startup.user.lua", existingStartup)
  if not startupBackupOk then error("Cannot preserve existing startup.lua: " .. tostring(startupBackupError), 0) end
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
print("Network key: " .. key)
if requestedRole == "worker" then
  print("Output chest: BEHIND the turtle at home")
  print("Fuel chest: ABOVE the turtle at home")
  print("Turtle front: face the quarry entrance")
else
  print("Place a wireless modem next to this computer.")
end
print("")
print("Reboot with: reboot")
