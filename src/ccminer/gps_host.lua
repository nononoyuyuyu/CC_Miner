-- CC Miner V3 - managed GPS host launcher.

local common = dofile("/ccminer/lib/common.lua")
local config, err = common.loadConfig()
if not config or config.role ~= "gps" then error(err or "GPS host is not configured. Run: ccm setup gps", 0) end

if os.setComputerLabel then os.setComputerLabel(config.gpsName or common.safeComputerLabel("GPS")) end
local opened = common.openWirelessModems()
if #opened == 0 then error("No wireless modem found. Attach a wireless modem to this GPS host.", 0) end

common.clear(colors and colors.black or nil, colors and colors.white or nil)
print("CC Miner V3 GPS Host " .. common.VERSION)
print("Name: " .. tostring(config.gpsName))
print(("Coordinates: %d, %d, %d"):format(config.x, config.y, config.z))
print("Modem: " .. table.concat(opened, ", "))
print("")
print("Hosting GPS. Keep this chunk loaded.")
common.log("INFO", ("GPS host started at %d,%d,%d"):format(config.x, config.y, config.z))

local ok = shell.run("gps", "host", tostring(config.x), tostring(config.y), tostring(config.z))
if not ok then error("The built-in GPS host program exited unexpectedly.", 0) end
