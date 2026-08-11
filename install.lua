-- CC Miner V2 online installer/updater
-- Usage:
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua gps
--   ccm update

local args = { ... }
local action = string.lower(tostring(args[1] or ""))
local VERSION = "2.1.0"
local BASE_URL = "https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/"
local ROOT, TEMP, BACKUP = "/ccminer", "/ccminer.update", "/ccminer.backup"

local files = {
  { source = "src/ccminer/lib/common.lua", target = "lib/common.lua" },
  { source = "src/ccminer/lib/protocol.lua", target = "lib/protocol.lua" },
  { source = "src/ccminer/lib/geo.lua", target = "lib/geo.lua" },
  { source = "src/ccminer/lib/quarry.lua", target = "lib/quarry.lua" },
  { source = "src/ccminer/worker.lua", target = "worker.lua" },
  { source = "src/ccminer/worker_parts/01.part", target = "worker_parts/01.part" },
  { source = "src/ccminer/worker_parts/02.part", target = "worker_parts/02.part" },
  { source = "src/ccminer/worker_parts/03.part", target = "worker_parts/03.part" },
  { source = "src/ccminer/worker_parts/04.part", target = "worker_parts/04.part" },
  { source = "src/ccminer/worker_parts/05.part", target = "worker_parts/05.part" },
  { source = "src/ccminer/controller.lua", target = "controller.lua" },
  { source = "src/ccminer/controller_parts/01.part", target = "controller_parts/01.part" },
  { source = "src/ccminer/controller_parts/02.part", target = "controller_parts/02.part" },
  { source = "src/ccminer/controller_parts/03.part", target = "controller_parts/03.part" },
  { source = "src/ccminer/gps_host.lua", target = "gps_host.lua" },
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
  local text = handle.readAll(); handle.close(); return text
end

local function writeFile(path, text)
  ensureDir(fs.getDir(path))
  local handle = fs.open(path, "w")
  if not handle then return false, "Cannot write " .. path end
  handle.write(text); handle.close(); return true
end

local function download(url)
  if not http then return nil, "HTTP API is disabled in the server configuration." end
  local ok, response = pcall(http.get, url, nil, true)
  if not ok or not response then return nil, "Request failed: " .. tostring(response) end
  local code = response.getResponseCode and response.getResponseCode() or 200
  local body = response.readAll(); response.close()
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
  print("  install.lua worker      Mining turtle")
  print("  install.lua controller  Touch controller")
  print("  install.lua gps         GPS host computer")
  print("  install.lua update      Existing installation")
end

if action == "" then action = turtle and "worker" or "controller" end
if action ~= "worker" and action ~= "controller" and action ~= "gps" and action ~= "update" then usage(); return end
if action == "worker" and not turtle then error("Worker installation requires a turtle.", 0) end
if action == "update" and not fs.exists(ROOT .. "/config.db") then error("No existing installation found.", 0) end

term.clear(); term.setCursorPos(1, 1)
print("CC MINER V2 " .. string.upper(action))
print("Source: nononoyuyuyu/CC_Miner")
print("")
if fs.exists(TEMP) then fs.delete(TEMP) end
ensureDir(TEMP)

for index, file in ipairs(files) do
  write(("[%d/%d] %s ... "):format(index, #files, file.target))
  local body, downloadError = download(BASE_URL .. file.source)
  if not body then fs.delete(TEMP); printError("FAILED"); error(downloadError, 0) end
  local ok, writeError = writeFile(TEMP .. "/" .. file.target, body)
  if not ok then fs.delete(TEMP); printError("FAILED"); error(writeError, 0) end
  print("OK")
end

local preserved = {
  { ROOT .. "/config.db", TEMP .. "/config.db" },
  { ROOT .. "/config.db.bak", TEMP .. "/config.db.bak" },
  { ROOT .. "/data/state.db", TEMP .. "/data/state.db" },
  { ROOT .. "/data/state.db.bak", TEMP .. "/data/state.db.bak" },
  { ROOT .. "/data/ccminer.log", TEMP .. "/data/ccminer.log" },
  { ROOT .. "/data/ccminer.log.1", TEMP .. "/data/ccminer.log.1" },
}
for _, pair in ipairs(preserved) do
  local ok, preserveError = copyIfPresent(pair[1], pair[2])
  if not ok then fs.delete(TEMP); error("Cannot preserve existing data: " .. tostring(preserveError), 0) end
end

local function compileFile(target)
  local compiled, compileError = loadfile(TEMP .. "/" .. target)
  if not compiled then
    fs.delete(TEMP)
    error("Downloaded file failed syntax validation: " .. target .. ": " .. tostring(compileError), 0)
  end
end

local function compileParts(label, targets)
  local source = {}
  for index, target in ipairs(targets) do
    local text = readFile(TEMP .. "/" .. target)
    if not text then fs.delete(TEMP); error("Downloaded runtime part is missing: " .. target, 0) end
    source[index] = text
  end
  local loader = loadstring or load
  local compiled, compileError = loader(table.concat(source), "@" .. label .. ".assembled.lua")
  if not compiled then
    fs.delete(TEMP)
    error("Assembled source failed syntax validation: " .. label .. ": " .. tostring(compileError), 0)
  end
end

for _, target in ipairs({
  "lib/common.lua", "lib/protocol.lua", "lib/geo.lua", "lib/quarry.lua",
  "worker.lua", "controller.lua", "gps_host.lua", "setup.lua", "boot.lua", "command.lua",
}) do
  compileFile(target)
end
compileParts("worker", {
  "worker_parts/01.part", "worker_parts/02.part", "worker_parts/03.part",
  "worker_parts/04.part", "worker_parts/05.part",
})
compileParts("controller", {
  "controller_parts/01.part", "controller_parts/02.part", "controller_parts/03.part",
})

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
  print("Previous files: /ccminer.backup")
  print("Reboot with: reboot")
else
  local setupOk = shell.run(ROOT .. "/setup.lua", action)
  if not setupOk then printError("Setup did not complete. Run: " .. ROOT .. "/setup.lua " .. action)
  else print(""); print("Installation complete.") end
end
