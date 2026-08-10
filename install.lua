-- CC Miner V2 online installer/updater
-- Usage:
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
--   ccm update

local args = { ... }
local action = string.lower(tostring(args[1] or ""))
local VERSION = "2.0.0"
local BASE_URL = "https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/"
local ROOT = "/ccminer"
local TEMP = "/ccminer.update"
local BACKUP = "/ccminer.backup"

local files = {
  { source = "src/ccminer/lib/common.lua", target = "lib/common.lua" },
  { source = "src/ccminer/lib/protocol.lua", target = "lib/protocol.lua" },
  { source = "src/ccminer/lib/quarry.lua", target = "lib/quarry.lua" },
  { source = "src/ccminer/worker.lua", target = "worker.lua" },
  { source = "src/ccminer/controller.lua", target = "controller.lua" },
  { source = "src/ccminer/setup.lua", target = "setup.lua" },
  { source = "src/ccminer/boot.lua", target = "boot.lua" },
  { source = "src/ccminer/command.lua", target = "command.lua" },
}

local function ensureDir(path)
  if not path or path == "" or fs.exists(path) then return end
  local parent = fs.getDir(path)
  if parent and parent ~= "" then ensureDir(parent) end
  fs.makeDir(path)
end

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local text = handle.readAll()
  handle.close()
  return text
end

local function writeFile(path, text)
  ensureDir(fs.getDir(path))
  local handle = fs.open(path, "w")
  if not handle then return false, "Cannot write " .. path end
  handle.write(text)
  handle.close()
  return true
end

local function download(url)
  if not http then return nil, "HTTP API is disabled in the server configuration." end
  local ok, response = pcall(http.get, url, nil, true)
  if not ok or not response then return nil, "Request failed: " .. tostring(response) end
  local code = response.getResponseCode and response.getResponseCode() or 200
  local body = response.readAll()
  response.close()
  if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) .. " for " .. url end
  if not body or body == "" then return nil, "Empty download: " .. url end
  return body
end

local function copyIfPresent(source, target)
  local text = readFile(source)
  if text then return writeFile(target, text) end
  return true
end

local function usage()
  print("CC Miner V2 installer " .. VERSION)
  print("")
  print("Install on a mining turtle:")
  print("  install.lua worker")
  print("")
  print("Install on a controller computer:")
  print("  install.lua controller")
  print("")
  print("Update an existing installation:")
  print("  install.lua update")
end

if action == "" then
  if turtle then action = "worker" else action = "controller" end
end

if action ~= "worker" and action ~= "controller" and action ~= "update" then
  usage()
  return
end

if action == "worker" and not turtle then error("Worker installation requires a turtle.", 0) end
if action == "controller" and turtle then print("Warning: controller role is normally installed on a computer, not a turtle.") end
if action == "update" and not fs.exists(ROOT .. "/config.db") then
  error("No existing installation found. Use worker or controller instead.", 0)
end

term.clear()
term.setCursorPos(1, 1)
print("CC MINER V2 " .. string.upper(action))
print("Source: nononoyuyuyu/CC_Miner")
print("")

if fs.exists(TEMP) then fs.delete(TEMP) end
ensureDir(TEMP)

for index, file in ipairs(files) do
  write(("[%d/%d] %s ... "):format(index, #files, file.target))
  local body, err = download(BASE_URL .. file.source)
  if not body then
    printError("FAILED")
    fs.delete(TEMP)
    error(err, 0)
  end
  local ok, writeError = writeFile(TEMP .. "/" .. file.target, body)
  if not ok then
    printError("FAILED")
    fs.delete(TEMP)
    error(writeError, 0)
  end
  print("OK")
end

-- Preserve configuration, state, and logs during an update/reinstall.
local preserved = {
  { ROOT .. "/config.db", TEMP .. "/config.db" },
  { ROOT .. "/config.db.bak", TEMP .. "/config.db.bak" },
  { ROOT .. "/data/state.db", TEMP .. "/data/state.db" },
  { ROOT .. "/data/state.db.bak", TEMP .. "/data/state.db.bak" },
  { ROOT .. "/data/ccminer.log", TEMP .. "/data/ccminer.log" },
  { ROOT .. "/data/ccminer.log.1", TEMP .. "/data/ccminer.log.1" },
}
for _, pair in ipairs(preserved) do
  local ok, err = copyIfPresent(pair[1], pair[2])
  if not ok then
    fs.delete(TEMP)
    error("Cannot preserve existing data: " .. tostring(err), 0)
  end
end

-- Compile every downloaded Lua file before replacing the current release.
-- This catches truncated downloads and syntax errors while the working copy
-- and its state are still untouched.
for _, file in ipairs(files) do
  local target = TEMP .. "/" .. file.target
  local compiled, compileError = loadfile(target)
  if not compiled then
    fs.delete(TEMP)
    error("Downloaded file failed syntax validation: " .. file.target .. ": " .. tostring(compileError), 0)
  end
end

if fs.exists(BACKUP) then fs.delete(BACKUP) end
if fs.exists(ROOT) then fs.move(ROOT, BACKUP) end
local moved, moveError = pcall(fs.move, TEMP, ROOT)
if not moved then
  if fs.exists(ROOT) then fs.delete(ROOT) end
  if fs.exists(BACKUP) then fs.move(BACKUP, ROOT) end
  error("Install swap failed: " .. tostring(moveError), 0)
end

print("")
if action == "update" then
  print("Update installed successfully: " .. VERSION)
  print("The previous files remain in /ccminer.backup.")
  print("Reboot with: reboot")
else
  local setupOk = shell.run(ROOT .. "/setup.lua", action)
  if not setupOk then
    printError("Setup did not complete. Run: " .. ROOT .. "/setup.lua " .. action)
  else
    print("")
    print("Installation complete.")
  end
end
