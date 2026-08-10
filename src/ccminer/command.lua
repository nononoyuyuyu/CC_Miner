-- CC Miner V2 local command launcher

local args = { ... }
local common = dofile("/ccminer/lib/common.lua")
local command = string.lower(tostring(args[1] or "help"))

local function printHelp()
  print("CC Miner V2 " .. common.VERSION)
  print("")
  print("ccm help                 Show this help")
  print("ccm setup [worker|controller]")
  print("ccm dashboard            Open controller dashboard")
  print("ccm discover             List workers from controller")
  print("ccm status               Show local configuration/state")
  print("ccm logs                 Show recent local log entries")
  print("ccm update               Download the latest release")
  print("ccm version              Show installed version")
  print("ccm rehome RESET         Local worker recovery after Ctrl+T")
  print("")
  print("Controller CLI:")
  print("ccm start <id> <W> <L> <D>")
  print("ccm pause|resume|recall|service|abort|clear <id>")
  print("ccm rehome <id> RESET     Reset coordinates after physical recovery")
end

if command == "help" or command == "?" then
  printHelp()
elseif command == "version" then
  print("CC Miner V2 " .. common.VERSION)
elseif command == "setup" then
  shell.run("/ccminer/setup.lua", args[2])
elseif command == "dashboard" then
  shell.run("/ccminer/controller.lua")
elseif command == "discover" then
  shell.run("/ccminer/controller.lua", "discover")
elseif command == "rehome" then
  local config, configError = common.loadConfig()
  if not config then
    printError(configError or "Not configured.")
  elseif config.role == "worker" then
    if args[2] ~= "RESET" then
      printError("Dangerous operation. Physically place the turtle in its dock, face the quarry, then run: ccm rehome RESET")
    else
      local previous = common.loadTable(common.STATE_PATH, common.defaultState())
      local reset = common.defaultState()
      if previous and previous.stats then reset.stats = previous.stats end
      local ok, err = common.saveTable(common.STATE_PATH, reset)
      if not ok then
        printError("Cannot reset worker state: " .. tostring(err))
      else
        print("Worker coordinates and job were reset to home.")
        print("Run: reboot")
      end
    end
  elseif config.role == "controller" then
    if not tonumber(args[2]) or args[3] ~= "RESET" then
      printError("Usage on controller: ccm rehome <id> RESET")
    else
      local unpackArguments = table.unpack or unpack
      shell.run("/ccminer/controller.lua", unpackArguments(args))
    end
  else
    printError("Unknown configured role.")
  end
elseif command == "start" or command == "pause" or command == "resume" or command == "recall" or command == "service" or command == "abort" or command == "clear" then
  local config = common.loadConfig()
  if not config or config.role ~= "controller" then
    printError("These commands must run on the controller computer.")
  else
    local forwarded = {}
    for i = 1, #args do forwarded[i] = args[i] end
    local unpackArguments = table.unpack or unpack
    shell.run("/ccminer/controller.lua", unpackArguments(forwarded))
  end
elseif command == "status" then
  local config, configError = common.loadConfig()
  if not config then printError(configError or "Not configured."); return end
  print("CC Miner V2 " .. common.VERSION)
  print("Role: " .. tostring(config.role))
  print("Computer ID: " .. tostring(os.getComputerID()))
  print("Label: " .. tostring(os.getComputerLabel and os.getComputerLabel() or "-"))
  print("Network key: " .. tostring(config.networkKey))
  if config.role == "worker" then
    local state, stateError = common.loadTable(common.STATE_PATH, common.defaultState())
    if stateError then printError(stateError) end
    print("Status: " .. tostring(state.status) .. " / " .. tostring(state.phase))
    if state.pose then print(("Pose: x=%s y=%s z=%s dir=%s"):format(state.pose.x, state.pose.y, state.pose.z, state.pose.dir)) end
    if state.job then print(("Job: %s %s/%s"):format(tostring(state.job.name), tostring(state.job.cursor), tostring(state.job.total))) end
    if state.lastError then print("Error: " .. tostring(state.lastError)) end
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
  if not http then printError("HTTP API is disabled."); return end
  shell.run("wget", "run", "https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua", "update")
else
  printError("Unknown command: " .. command)
  printHelp()
end
