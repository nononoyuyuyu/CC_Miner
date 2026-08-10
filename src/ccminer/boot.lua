-- CC Miner V2 boot dispatcher

local common = dofile("/ccminer/lib/common.lua")
local config, err = common.loadConfig()
if not config or not config.role then
  printError(err or "CC Miner is not configured.")
  print("Run: ccm setup")
  return
end

local program = config.role == "worker" and "/ccminer/worker.lua" or "/ccminer/controller.lua"
if config.role == "controller" then
  local ok, runError = pcall(dofile, program)
  if not ok then
    common.log("ERROR", "Controller stopped: " .. tostring(runError))
    printError(runError)
  end
  return
end

while true do
  local ok, runError = pcall(dofile, program)
  if ok then return end
  local text = tostring(runError)
  common.log("ERROR", "Worker crashed: " .. text)
  printError("CC Miner worker stopped: " .. text)
  if text == "Terminated" or text:find("Terminated", 1, true) then
    print("Worker stopped locally. Run 'reboot' to restart.")
    return
  end
  print("Restarting worker in 5 seconds...")
  sleep(5)
end
