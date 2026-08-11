-- CC Miner V3 online installer/updater
-- Usage:
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua gps
--   ccm update
--   wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua update-low-space

local args = { ... }
local action = string.lower(tostring(args[1] or ""))
local VERSION = "3.0.0"
local BASE_URL = "https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/"
local ROOT, TEMP, BACKUP = "/ccminer", "/ccminer.update", "/ccminer.backup"
local LOW_SPACE_MARKER = "/ccminer.update.low-space.marker"

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

local function moveChecked(source, target)
  local ok, moveError = pcall(fs.move, source, target)
  if not ok or not fs.exists(target) then
    return false, tostring(moveError or ("Move destination is missing: " .. target))
  end
  return true
end

local function usage()
  print("CC Miner V3 installer " .. VERSION)
  print("  install.lua worker      Mining turtle")
  print("  install.lua controller  Touch controller")
  print("  install.lua gps         GPS host computer")
  print("  install.lua update      Existing installation")
  print("  install.lua update-low-space  Existing installation (low disk space)")
end

if action == "" then action = turtle and "worker" or "controller" end
if action ~= "worker" and action ~= "controller" and action ~= "gps"
    and action ~= "update" and action ~= "update-low-space" then usage(); return end
if action == "worker" and not turtle then error("Worker installation requires a turtle.", 0) end
if (action == "update" or action == "update-low-space") and not fs.exists(ROOT .. "/config.db") then
  error("No existing installation found.", 0)
end
if action == "update" and fs.exists(LOW_SPACE_MARKER) then
  error("A low-space update is incomplete. Resume it with: wget run " .. BASE_URL
    .. "install.lua update-low-space (marker: " .. LOW_SPACE_MARKER .. ")", 0)
end

if action ~= "update-low-space" then
  term.clear(); term.setCursorPos(1, 1)
  print("CC MINER V3 " .. string.upper(action))
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
end

if action ~= "update-low-space" then
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
end

-- The regular updater swaps the complete tree through BACKUP.  That gives a
-- strong rollback but needs another copy of the entire installation.  On a
-- nearly-full computer that copy can fail before the swap starts.  The
-- explicit low-space mode stages and validates only runtime files, leaves all
-- user data in place, and records the current file so an interrupted write can
-- be retried safely.
local function lowSpaceFreeText()
  if fs.getFreeSpace then
    local ok, free = pcall(fs.getFreeSpace, ROOT)
    if ok and free then return " Free space reported by the filesystem: " .. tostring(free) .. " bytes." end
  end
  return ""
end

local function lowSpaceFailure(message)
  printError("LOW-SPACE UPDATE PAUSED")
  error(tostring(message) .. "\nRecovery marker: " .. LOW_SPACE_MARKER .. "."
    .. lowSpaceFreeText() .. "\nFree space, then rerun: wget run " .. BASE_URL
    .. "install.lua update-low-space", 0)
end

local function readLowSpaceMarker()
  local text = readFile(LOW_SPACE_MARKER)
  if not text then return nil end
  local version = text:match("version=([^\r\n]+)")
  local state = text:match("state=([^\r\n]+)")
  local nextIndex = tonumber(text:match("next=(%d+)")) or 1
  if not state then return "invalid", nextIndex, version end
  return state, nextIndex, version
end

local function writeLowSpaceMarker(state, nextIndex)
  local marker = table.concat({
    "version=" .. VERSION,
    "state=" .. tostring(state),
    "next=" .. tostring(nextIndex or 1),
    "", -- Keep the marker human-readable and line-oriented.
  }, "\n")
  local ok, wrote, writeError = pcall(writeFile, LOW_SPACE_MARKER, marker)
  if not ok then return false, tostring(wrote) end
  if not wrote then return false, tostring(writeError) end
  return true
end

local function safeWrite(path, text)
  local ok, wrote, writeError = pcall(writeFile, path, text)
  if not ok then return false, tostring(wrote) end
  if not wrote then return false, tostring(writeError) end
  return true
end

local function validateLowSpaceFile(target)
  local compiled, compileError = loadfile(TEMP .. "/" .. target)
  if not compiled then
    return false, "Downloaded file failed syntax validation: " .. target .. ": " .. tostring(compileError)
  end
  return true
end

local function validateLowSpaceParts(label, targets)
  local source = {}
  for index, target in ipairs(targets) do
    local text = readFile(TEMP .. "/" .. target)
    if not text then return false, "Downloaded runtime part is missing: " .. target end
    source[index] = text
  end
  local loader = loadstring or load
  local compiled, compileError = loader(table.concat(source), "@" .. label .. ".assembled.lua")
  if not compiled then
    return false, "Assembled source failed syntax validation: " .. label .. ": " .. tostring(compileError)
  end
  return true
end

local function validateLowSpaceStage(firstIndex)
  for index = firstIndex, #files do
    local target = files[index].target
    if not target:match("%.part$") then
      local ok, validationError = validateLowSpaceFile(target)
      if not ok then return false, validationError end
    end
  end
  local workerParts = {
    "worker_parts/01.part", "worker_parts/02.part", "worker_parts/03.part",
    "worker_parts/04.part", "worker_parts/05.part",
  }
  local allWorkerParts = true
  for _, target in ipairs(workerParts) do allWorkerParts = allWorkerParts and fs.exists(TEMP .. "/" .. target) end
  if allWorkerParts then
    local ok, validationError = validateLowSpaceParts("worker", workerParts)
    if not ok then return false, validationError end
  end
  local controllerParts = {
    "controller_parts/01.part", "controller_parts/02.part", "controller_parts/03.part",
  }
  local allControllerParts = true
  for _, target in ipairs(controllerParts) do allControllerParts = allControllerParts and fs.exists(TEMP .. "/" .. target) end
  if allControllerParts then
    local ok, validationError = validateLowSpaceParts("controller", controllerParts)
    if not ok then return false, validationError end
  end
  return true
end

local function lowSpaceStage(firstIndex, reset)
  if reset then
    if fs.exists(TEMP) then fs.delete(TEMP) end
    ensureDir(TEMP)
  elseif not fs.exists(TEMP) then
    ensureDir(TEMP)
  end
  for index = firstIndex, #files do
    local file = files[index]
    local staged = TEMP .. "/" .. file.target
    if not fs.exists(staged) then
      -- A failed target write may have left a truncated runtime file.  It is
      -- safe to remove only that known runtime path before retrying; config,
      -- state, journal, and logs are outside this list and are never touched.
      if index == firstIndex and fs.exists(ROOT .. "/" .. file.target) then
        pcall(fs.delete, ROOT .. "/" .. file.target)
      end
      write(("[%d/%d] %s ... "):format(index, #files, file.target))
      local body, downloadError = download(BASE_URL .. file.source)
      if not body then printError("FAILED"); return false, "Download failed for " .. file.target .. ": " .. tostring(downloadError) end
      local wrote, writeError = safeWrite(staged, body)
      if not wrote then printError("FAILED"); return false, "Cannot stage " .. file.target .. ": " .. tostring(writeError) end
      print("OK")
      local marked, markerError = writeLowSpaceMarker("downloading", index + 1)
      if not marked then return false, "Cannot update recovery marker: " .. tostring(markerError) end
    end
  end
  return true
end

if action == "update-low-space" then
  term.clear(); term.setCursorPos(1, 1)
  print("CC MINER V3 UPDATE-LOW-SPACE")
  print("Source: nononoyuyu/CC_Miner")
  print("")

  local state, nextIndex, markerVersion = readLowSpaceMarker()
  if markerVersion and markerVersion ~= VERSION then
    lowSpaceFailure("Recovery marker version " .. tostring(markerVersion) .. " does not match this installer (" .. VERSION .. ").")
  end
  if state and state ~= "downloading" and state ~= "ready" and state ~= "committing" then
    lowSpaceFailure("Recovery marker has an unknown state: " .. tostring(state) .. ". Do not delete /ccminer; inspect the marker and retry.")
  end
  if not state then
    local marked, markerError = writeLowSpaceMarker("downloading", 1)
    if not marked then
      lowSpaceFailure("Cannot create the recovery marker: " .. tostring(markerError) .. ". No runtime files were changed.")
    end
    state, nextIndex = "downloading", 1
  end

  local commitStart = 1
  local resetStage = state == "downloading" or state == "ready"
  if state == "ready" then
    for _, file in ipairs(files) do
      if not fs.exists(TEMP .. "/" .. file.target) then resetStage = true; break end
    end
    if resetStage then state, nextIndex = "downloading", 1 end
  end
  if resetStage then
    local marked, markerError = writeLowSpaceMarker("downloading", 1)
    if not marked then lowSpaceFailure("Cannot update recovery marker: " .. tostring(markerError)) end
    local staged, stageError = lowSpaceStage(1, true)
    if not staged then lowSpaceFailure(stageError) end
    nextIndex = 1
  elseif state == "committing" then
    nextIndex = math.max(1, math.min(#files + 1, nextIndex))
    commitStart = nextIndex
    local staged, stageError = lowSpaceStage(nextIndex, false)
    if not staged then lowSpaceFailure(stageError) end
  end

  local valid, validationError = validateLowSpaceStage(commitStart)
  if not valid then lowSpaceFailure(validationError) end
  local marked, markerError = writeLowSpaceMarker("ready", 1)
  if not marked then lowSpaceFailure("Cannot mark the validated runtime ready: " .. tostring(markerError)) end

  -- Each staged file is read before its staging copy is deleted.  This avoids
  -- fs.move's copy semantics and therefore does not require a second runtime
  -- tree.  If the subsequent write fails, the marker points at this file and
  -- the next invocation redownloads only the missing staged file.
  for index = commitStart, #files do
    local file = files[index]
    local staged = TEMP .. "/" .. file.target
    local target = ROOT .. "/" .. file.target
    local body = readFile(staged)
    if not body then lowSpaceFailure("Staged runtime file is missing: " .. file.target) end
    marked, markerError = writeLowSpaceMarker("committing", index)
    if not marked then lowSpaceFailure("Cannot record commit progress for " .. file.target .. ": " .. tostring(markerError)) end
    pcall(fs.delete, staged)
    if fs.exists(staged) then lowSpaceFailure("Cannot release staging space for " .. file.target .. ".") end
    local wrote, writeError = safeWrite(target, body)
    if not wrote then lowSpaceFailure("Cannot install " .. file.target .. ": " .. tostring(writeError)) end
    marked, markerError = writeLowSpaceMarker("committing", index + 1)
    if not marked then lowSpaceFailure("Installed " .. file.target .. ", but cannot advance the recovery marker: " .. tostring(markerError)) end
  end
  if fs.exists(TEMP) then pcall(fs.delete, TEMP) end
  if fs.exists(LOW_SPACE_MARKER) then pcall(fs.delete, LOW_SPACE_MARKER) end
  if fs.exists(LOW_SPACE_MARKER) then
    lowSpaceFailure("Runtime files are installed, but the recovery marker could not be cleared. Re-run update-low-space.")
  end
  print("")
  print("Low-space update installed successfully: " .. VERSION)
  print("User data under /ccminer (config, state, journal, and logs) was left in place.")
  print("Reboot with: reboot")
  return
end

if fs.exists(BACKUP) then fs.delete(BACKUP) end
local hadRoot = fs.exists(ROOT)
if hadRoot then
  local backedUp, backupError = moveChecked(ROOT, BACKUP)
  if not backedUp then fs.delete(TEMP); error("Cannot back up existing installation: " .. backupError, 0) end
end
local moved, moveError = moveChecked(TEMP, ROOT)
if not moved then
  if fs.exists(ROOT) then pcall(fs.delete, ROOT) end
  local restored, restoreError = true, nil
  if hadRoot then
    if fs.exists(BACKUP) then restored, restoreError = moveChecked(BACKUP, ROOT)
    else restored, restoreError = false, "Backup directory is missing." end
  end
  if not restored then
    error("Install swap failed and rollback failed. Previous files remain at " .. BACKUP .. ": "
      .. tostring(moveError) .. "; rollback: " .. tostring(restoreError), 0)
  end
  error("Install swap failed; previous installation was restored: " .. tostring(moveError), 0)
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
