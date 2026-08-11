-- CC Miner V4 online role-scoped installer/updater.
--
-- The installer intentionally carries the manifest locally.  A ComputerCraft
-- computer cannot import a repository-local Lua module before the runtime has
-- been installed, so ``FILES`` is kept in lock-step with manifest.lua.
-- Existing V2 wire/startup markers are not read or modified here.

local args = { ... }
local action = string.lower(tostring(args[1] or ""))
local VERSION, SCHEMA = "4.0.0", 4
local BASE_URL = "https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/"
local ROOT = "/ccminer"
local LOW_MARKER = "/ccminer.update.low-space.marker"
local LOW_MARKER_TMP, LOW_MARKER_BAK = LOW_MARKER .. ".tmp", LOW_MARKER .. ".bak"
-- Compatibility name retained for tooling that labels the online marker;
-- persisted records use the V4 {version, role, next, phase} shape below.
local LOW_SPACE_MARKER = LOW_MARKER
local ROLE_TEMP_PREFIX, ROLE_BACKUP_PREFIX = "/ccminer.update.", "/ccminer.backup."

local ROLES = { worker = true, controller = true, gps = true }

-- Source/target/roles are explicit by design.  Keep this list byte-for-byte
-- aligned with manifest.lua and tools/build_offline_bundle.py's source list;
-- only the selected role entries are ever downloaded.
local FILES = {
  { source = "src/ccminer/lib/common.lua", target = "lib/common.lua", roles = { worker = true, controller = true, gps = true } },
  { source = "src/ccminer/lib/protocol.lua", target = "lib/protocol.lua", roles = { worker = true, controller = true, gps = true } },
  { source = "src/ccminer/setup.lua", target = "setup.lua", roles = { worker = true, controller = true, gps = true } },
  { source = "src/ccminer/boot.lua", target = "boot.lua", roles = { worker = true, controller = true, gps = true } },
  { source = "src/ccminer/command.lua", target = "command.lua", roles = { worker = true, controller = true, gps = true } },
  { source = "src/ccminer/lib/geo.lua", target = "lib/geo.lua", roles = { worker = true } },
  { source = "src/ccminer/lib/quarry.lua", target = "lib/quarry.lua", roles = { worker = true, controller = true } },
  { source = "src/ccminer/worker.lua", target = "worker.lua", roles = { worker = true } },
  { source = "src/ccminer/worker_parts/01.part", target = "worker_parts/01.part", roles = { worker = true } },
  { source = "src/ccminer/worker_parts/02.part", target = "worker_parts/02.part", roles = { worker = true } },
  { source = "src/ccminer/worker_parts/03.part", target = "worker_parts/03.part", roles = { worker = true } },
  { source = "src/ccminer/worker_parts/04.part", target = "worker_parts/04.part", roles = { worker = true } },
  { source = "src/ccminer/worker_parts/05.part", target = "worker_parts/05.part", roles = { worker = true } },
  { source = "src/ccminer/controller.lua", target = "controller.lua", roles = { controller = true } },
  { source = "src/ccminer/controller_parts/01.part", target = "controller_parts/01.part", roles = { controller = true } },
  { source = "src/ccminer/controller_parts/02.part", target = "controller_parts/02.part", roles = { controller = true } },
  { source = "src/ccminer/controller_parts/03.part", target = "controller_parts/03.part", roles = { controller = true } },
  { source = "src/ccminer/gps_host.lua", target = "gps_host.lua", roles = { gps = true } },
}

local function fail(message)
  error(tostring(message), 0)
end

local function ensureDir(path)
  if not path or path == "" or path == "/" or fs.exists(path) then return true end
  local parent = fs.getDir(path)
  if parent and parent ~= path and parent ~= "" then ensureDir(parent) end
  local ok, err = pcall(fs.makeDir, path)
  if not ok and not fs.exists(path) then return false, tostring(err) end
  return fs.exists(path)
end

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  -- Keep downloaded source byte-for-byte identical on older CC versions.
  -- Text handles may decode/re-encode data, while HTTP is read in binary mode.
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local ok, text = pcall(handle.readAll)
  pcall(handle.close)
  if not ok then return nil end
  return text
end

local function writeFile(path, text)
  local parent = fs.getDir(path)
  local made, makeError = ensureDir(parent)
  if not made then return false, "Cannot create " .. tostring(parent) .. ": " .. tostring(makeError) end
  local handle = fs.open(path, "wb")
  if not handle then return false, "Cannot write " .. path end
  local ok, err = pcall(handle.write, text or "")
  pcall(handle.close)
  if not ok then return false, tostring(err) end
  return true
end

local function deleteKnown(path)
  if not fs.exists(path) then return true end
  local ok, err = pcall(fs.delete, path)
  if not ok or fs.exists(path) then return false, tostring(err or ("Cannot delete " .. path)) end
  return true
end

local function moveChecked(source, target)
  local ok, err = pcall(fs.move, source, target)
  if not ok or not fs.exists(target) then return false, tostring(err or ("Move destination is missing: " .. target)) end
  return true
end

local function copyFile(source, target)
  local body = readFile(source)
  if body == nil then return false, "Cannot read " .. source end
  local ok, err = writeFile(target, body)
  if not ok then return false, err end
  if readFile(target) ~= body then return false, "Copy verification failed for " .. target end
  return true
end

local function download(url)
  if not http or type(http.get) ~= "function" then return nil, "HTTP API is disabled." end
  local ok, response = pcall(http.get, url, nil, true)
  if not ok or not response then return nil, "Request failed: " .. tostring(response) end
  local code = response.getResponseCode and response.getResponseCode() or 200
  local readOk, body = pcall(response.readAll)
  pcall(response.close)
  if not readOk then return nil, "Cannot read response for " .. url end
  if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) .. " for " .. url end
  if not body or body == "" then return nil, "Empty download: " .. url end
  return body
end

local function compileText(text, label)
  if type(text) ~= "string" or text == "" then return false, "Empty source: " .. tostring(label) end
  local loader = loadstring or load
  local ok, chunk, compileError = pcall(loader, text, "@" .. tostring(label))
  if not ok or not chunk then return false, tostring(compileError or chunk) end
  return true
end

local function compileFile(path, label)
  local body = readFile(path)
  if body == nil then return false, "Missing runtime file: " .. tostring(label or path) end
  return compileText(body, label or path)
end

local function compileParts(bodies, label, targets)
  local source = {}
  for index, target in ipairs(targets) do
    local body = bodies[target]
    if body == nil then return false, "Missing runtime part: " .. target end
    source[index] = body
  end
  return compileText(table.concat(source), label .. ".assembled.lua")
end

local function pathFor(base, target)
  return base .. "/" .. target
end

local function filesForRole(role)
  local selected = {}
  for _, file in ipairs(FILES) do
    if file.roles[role] then selected[#selected + 1] = file end
  end
  return selected
end

local function targetsForRole(role)
  local selected = {}
  for _, file in ipairs(filesForRole(role)) do selected[file.target] = true end
  return selected
end

local function knownTargets()
  local result = {}
  for _, file in ipairs(FILES) do result[file.target] = true end
  return result
end

local ALL_TARGETS = knownTargets()

local function partTargets(role)
  if role == "worker" then
    return { "worker_parts/01.part", "worker_parts/02.part", "worker_parts/03.part", "worker_parts/04.part", "worker_parts/05.part" }
  elseif role == "controller" then
    return { "controller_parts/01.part", "controller_parts/02.part", "controller_parts/03.part" }
  end
  return nil
end

local function loaderTarget(role)
  if role == "worker" then return "worker.lua" end
  if role == "controller" then return "controller.lua" end
  if role == "gps" then return "gps_host.lua" end
  return nil
end

local function freeSpace(path)
  if not fs.getFreeSpace then return nil end
  local ok, value = pcall(fs.getFreeSpace, path)
  if ok and type(value) == "number" then return value end
  return nil
end

local function formatBytes(value)
  value = tonumber(value) or 0
  if value < 1024 then return string.format("%d B", value) end
  if value < 1024 * 1024 then return string.format("%.1f KiB", value / 1024) end
  return string.format("%.1f MiB", value / (1024 * 1024))
end

local function showCapacity(role, bytes, label)
  local free = freeSpace(ROOT)
  local suffix = free and ("; free " .. formatBytes(free)) or "; free-space API unavailable"
  print(("Role %s runtime %s (%d files)%s%s"):format(
    role, formatBytes(bytes or 0), #filesForRole(role), suffix, label and ("; " .. label) or ""
  ))
end

-- Read only the role field.  Updating with a hand-edited or malformed config
-- is refused; silently guessing a role could delete another role's runtime.
local function configRole(optionalRole)
  local configPath = ROOT .. "/config.db"
  if not fs.exists(configPath) then return nil, "No existing installation found (missing " .. configPath .. ")." end
  local text = readFile(configPath)
  if not text then return nil, "Cannot read " .. configPath end
  if not textutils or type(textutils.unserialize) ~= "function" then
    return nil, "ComputerCraft textutils.unserialize is unavailable." end
  local ok, value = pcall(textutils.unserialize, text)
  if not ok or type(value) ~= "table" then return nil, "config.db is not a serialized table." end
  local role = value.role
  if type(role) ~= "string" or not ROLES[role] then
    return nil, "config.db has an unknown role; refusing a role-scoped update." end
  if optionalRole ~= nil and tostring(optionalRole) ~= role then
    return nil, "Requested role " .. tostring(optionalRole) .. " does not match config.db role " .. role .. "." end
  return role, value
end

local function validateExistingRoleForInstall(role)
  if not fs.exists(ROOT .. "/config.db") then return true end
  local existing, err = configRole(nil)
  if not existing then return false, err end
  if existing ~= role then
    return false, "Existing config.db is for role " .. existing .. "; refusing to replace it with " .. role .. "."
  end
  return true
end

local function validateStage(role, base, selected)
  local bodies, total = {}, 0
  local parts = partTargets(role)
  for _, file in ipairs(selected) do
    local path = pathFor(base, file.target)
    local body = readFile(path)
    if not body then return false, "Staged file is missing: " .. file.target end
    bodies[file.target] = body
    total = total + #body
    if not file.target:match("%.part$") then
      local valid, err = compileText(body, file.target)
      if not valid then return false, "Syntax validation failed for " .. file.target .. ": " .. tostring(err) end
    end
  end
  if parts then
    local valid, err = compileParts(bodies, role, parts)
    if not valid then return false, "Assembled " .. role .. " validation failed: " .. tostring(err) end
  end
  return true, total, bodies
end

-- A worker/controller loader is replaced by this safe stopper before any
-- assembled part is swapped.  If power fails mid-transaction, boot.lua sees
-- a harmless program instead of a mixed set of parts; the marker resumes the
-- transaction on the next invocation.
local SENTINEL = [[-- CC Miner update sentinel: runtime replacement is in progress.
printError("CC Miner runtime update is incomplete; rerun install.lua update-low-space.")
return
]]

local function stageRegular(role)
  local base = ROLE_TEMP_PREFIX .. role
  if fs.exists(base) then
    local removed, removeError = deleteKnown(base)
    if not removed then return nil, nil, "Cannot clear stale role staging: " .. tostring(removeError) end
  end
  local made, makeError = ensureDir(base)
  if not made then return nil, nil, "Cannot create role staging: " .. tostring(makeError) end
  print("Downloading " .. role .. " runtime (role-scoped; user data is untouched).")
  local selected = filesForRole(role)
  for index, file in ipairs(selected) do
    write(("[%d/%d] %s ... "):format(index, #selected, file.target))
    local body, err = download(BASE_URL .. file.source)
    if not body then printError("FAILED"); deleteKnown(base); return nil, nil, err end
    local stagedPath = pathFor(base, file.target)
    local freeBefore = freeSpace(base)
    local required = #body + 4096
    if freeBefore and freeBefore < required then
      printError("NOT ENOUGH SPACE")
      deleteKnown(base)
      return nil, nil, ("Regular update staging needs at least %s for %s, but only %s is free. "
        .. "The installer can continue with update-low-space mode."):format(
          formatBytes(required), file.target, formatBytes(freeBefore)
        ), nil, true
    end
    local ok, writeError = writeFile(stagedPath, body)
    local stagedBody = readFile(stagedPath)
    if not ok or stagedBody ~= body then
      printError("FAILED"); deleteKnown(base)
      local wrote = stagedBody and #stagedBody or 0
      -- A shorter readback is not proof of an out-of-space condition when
      -- the filesystem reports ample free space. Older CC text handles can
      -- also transform a byte, which is why readFile/writeFile use rb/wb.
      local likelyOutOfSpace = (freeBefore and freeBefore < required)
        or (freeBefore == nil and stagedBody ~= nil and wrote < #body)
      local detail = ("Staging verification failed for %s (expected %s [%d bytes], wrote %s [%d bytes]%s)."):format(
        file.target, formatBytes(#body), #body, formatBytes(wrote), wrote,
        freeBefore and (", free before write " .. formatBytes(freeBefore)) or ""
      )
      if likelyOutOfSpace then
        detail = detail .. " The file was truncated, which normally means the computer is out of space."
      elseif stagedBody ~= nil and wrote ~= #body then
        detail = detail .. " The filesystem changed the byte count despite having enough free space."
      elseif stagedBody ~= nil then
        detail = detail .. " The byte count matches, but the saved contents differ."
      elseif writeError then
        detail = detail .. " " .. tostring(writeError)
      end
      return nil, nil, detail, nil, likelyOutOfSpace
    end
    print("OK")
  end
  local valid, bytes, bodies = validateStage(role, base, selected)
  if not valid then deleteKnown(base); return nil, nil, bytes end
  showCapacity(role, bytes, "downloaded and validated")
  return base, selected, nil, bytes, bodies
end

local function backupRuntime(role)
  local base = ROLE_BACKUP_PREFIX .. role
  if fs.exists(base) then return nil, "Backup path already exists: " .. base .. ". Inspect it before retrying." end
  local made, makeError = ensureDir(base)
  if not made then return nil, "Cannot create file-level backup: " .. tostring(makeError) end
  local records = {}
  for target in pairs(ALL_TARGETS) do
    local path = pathFor(ROOT, target)
    if fs.exists(path) then
      if fs.isDir(path) then
        deleteKnown(base)
        return nil, "Known runtime target is a directory; refusing to delete user data: " .. path
      end
      local backup = pathFor(base, target)
      local copied, copyError = copyFile(path, backup)
      if not copied then deleteKnown(base); return nil, copyError end
      records[target] = { target = target, existed = true, backup = backup, touched = false }
    else
      records[target] = { target = target, existed = false, backup = pathFor(base, target), touched = false }
    end
  end
  return base, records
end

local function internalPaths(target)
  local path = pathFor(ROOT, target)
  return path .. ".new", path .. ".old"
end

local function removeInternal(target)
  local newPath, oldPath = internalPaths(target)
  -- A directory at either suffix may be user-owned data.  Never recurse into
  -- it as part of a rollback; callers will report the stale artifact instead.
  if fs.exists(newPath) and not fs.isDir(newPath) then deleteKnown(newPath) end
  if fs.exists(oldPath) and not fs.isDir(oldPath) then deleteKnown(oldPath) end
end

local function replaceRegular(target, body, record)
  local path = pathFor(ROOT, target)
  local newPath, oldPath = internalPaths(target)
  if fs.exists(newPath) or fs.exists(oldPath) then
    return false, "Stale transaction artifact exists for " .. target
  end
  local wrote, writeError = writeFile(newPath, body)
  if not wrote or readFile(newPath) ~= body then
    removeInternal(target)
    return false, writeError or ("Write verification failed for " .. target)
  end
  record.touched = true
  local hadCurrent = fs.exists(path)
  if hadCurrent then
    local moved, moveError = moveChecked(path, oldPath)
    if not moved then removeInternal(target); record.touched = false; return false, moveError end
  end
  local movedNew, moveNewError = moveChecked(newPath, path)
  if not movedNew or readFile(path) ~= body then
    if fs.exists(path) then deleteKnown(path) end
    if hadCurrent and fs.exists(oldPath) then moveChecked(oldPath, path) end
    removeInternal(target)
    return false, moveNewError or ("Install verification failed for " .. target)
  end
  return true
end

local function restoreRecord(record)
  local path = pathFor(ROOT, record.target)
  removeInternal(record.target)
  if fs.exists(path) then
    local removed = deleteKnown(path)
    if not removed then return false, "Cannot remove changed runtime target " .. path end
  end
  if record.existed then
    local restored, restoreError = copyFile(record.backup, path)
    if not restored then return false, restoreError end
    if readFile(path) ~= readFile(record.backup) then return false, "Rollback verification failed for " .. path end
  end
  record.touched = false
  return true
end

local function rollback(records)
  local errors = {}
  for index = #records, 1, -1 do
    local record = records[index]
    if record.touched then
      local ok, err = restoreRecord(record)
      if not ok then errors[#errors + 1] = tostring(err) end
    else
      removeInternal(record.target)
    end
  end
  return #errors == 0, table.concat(errors, "; ")
end

local function regularCommit(role, base, selected)
  local backup, recordsByTarget = backupRuntime(role)
  if not backup then deleteKnown(base); return false, recordsByTarget end
  local records = {}
  for _, file in ipairs(FILES) do records[#records + 1] = recordsByTarget[file.target] end
  local selectedSet = targetsForRole(role)
  local function abort(message)
    local restored, restoreError = rollback(records)
    deleteKnown(base)
    if fs.exists(backup) then deleteKnown(backup) end
    if not restored then return false, tostring(message) .. "; rollback failed: " .. tostring(restoreError) end
    return false, tostring(message) .. "; previous runtime was restored."
  end
  local commitPlan = {}
  local loader = loaderTarget(role)
  if loader then commitPlan[#commitPlan + 1] = { target = loader, sentinel = true } end
  for _, file in ipairs(selected) do
    if file.target ~= loader then commitPlan[#commitPlan + 1] = file end
  end
  if loader then
    for _, file in ipairs(selected) do
      if file.target == loader then commitPlan[#commitPlan + 1] = file end
    end
  end
  for _, file in ipairs(commitPlan) do
    local body = file.sentinel and SENTINEL or readFile(pathFor(base, file.target))
    local ok, err = replaceRegular(file.target, body, recordsByTarget[file.target])
    if not ok then return abort("Cannot install " .. file.target .. ": " .. tostring(err)) end
    if file.sentinel then
      -- The original bytes are already in the transaction backup.  Drop the
      -- sentinel's per-file .old copy so the final real loader can be swapped
      -- through the same target later in this transaction.
      local _, sentinelOld = internalPaths(file.target)
      if fs.exists(sentinelOld) then
        local removed, removeError = deleteKnown(sentinelOld)
        if not removed then return abort("Cannot release sentinel backup for " .. file.target .. ": " .. tostring(removeError)) end
      end
    end
  end
  -- Remove only known runtime targets which do not belong to this role.  A
  -- directory at a known path was rejected while making the backup above.
  for _, file in ipairs(FILES) do
    if not selectedSet[file.target] then
      local path = pathFor(ROOT, file.target)
      if fs.exists(path) then
        local removed, removeError = deleteKnown(path)
        if not removed then return abort("Cannot remove obsolete runtime " .. file.target .. ": " .. tostring(removeError)) end
        recordsByTarget[file.target].touched = true
      end
    end
  end
  for _, record in ipairs(records) do
    removeInternal(record.target)
  end
  local backupRemoved = deleteKnown(backup)
  deleteKnown(base)
  if not backupRemoved then
    printError("Warning: runtime installed but file-level backup remains at " .. backup)
  end
  return true
end

local function encodeMarker(marker)
  if not textutils or type(textutils.serialize) ~= "function" then return nil, "textutils.serialize is unavailable." end
  local ok, text = pcall(textutils.serialize, marker)
  if not ok or type(text) ~= "string" then return nil, "Cannot serialize recovery marker." end
  return text
end

local function decodeMarker(path)
  local text = readFile(path)
  if not text or not textutils or type(textutils.unserialize) ~= "function" then return nil end
  local ok, marker = pcall(textutils.unserialize, text)
  if not ok or type(marker) ~= "table" then return nil end
  if marker.version ~= VERSION or not ROLES[marker.role] then return nil end
  if type(marker.next) ~= "number" or marker.next ~= math.floor(marker.next) or marker.next < 1 then return nil end
  if marker.phase ~= "prepare" and marker.phase ~= "commit" then return nil end
  return marker
end

local function readMarker()
  local marker = decodeMarker(LOW_MARKER)
  if marker then return marker end
  marker = decodeMarker(LOW_MARKER_BAK)
  if marker then return marker end
  marker = decodeMarker(LOW_MARKER_TMP)
  if marker then return marker end
  if fs.exists(LOW_MARKER) or fs.exists(LOW_MARKER_BAK) or fs.exists(LOW_MARKER_TMP) then
    return false, "Recovery marker is malformed or belongs to another release. Do not delete it." end
  return nil
end

local function writeMarker(role, nextIndex, phase)
  local marker = { version = VERSION, role = role, next = nextIndex, phase = phase }
  local text, encodeError = encodeMarker(marker)
  if not text then return false, encodeError end
  for _, markerPath in ipairs({ LOW_MARKER, LOW_MARKER_TMP, LOW_MARKER_BAK }) do
    if fs.exists(markerPath) and fs.isDir(markerPath) then
      return false, "Recovery marker path is a directory: " .. markerPath
    end
  end
  if fs.exists(LOW_MARKER_TMP) then
    local removed, removeError = deleteKnown(LOW_MARKER_TMP)
    if not removed then return false, removeError end
  end
  local wrote, writeError = writeFile(LOW_MARKER_TMP, text)
  if not wrote then return false, writeError end
  if fs.exists(LOW_MARKER_BAK) then
    local oldBak = decodeMarker(LOW_MARKER_BAK)
    if not oldBak then return false, "Unknown file exists at " .. LOW_MARKER_BAK end
    deleteKnown(LOW_MARKER_BAK)
  end
  local hadMarker = fs.exists(LOW_MARKER)
  if hadMarker then
    local oldMarker = decodeMarker(LOW_MARKER)
    if not oldMarker then return false, "Cannot replace malformed recovery marker." end
    local moved, moveError = moveChecked(LOW_MARKER, LOW_MARKER_BAK)
    if not moved then return false, moveError end
  end
  local movedNew, moveNewError = moveChecked(LOW_MARKER_TMP, LOW_MARKER)
  if not movedNew or not decodeMarker(LOW_MARKER) then
    if fs.exists(LOW_MARKER) then deleteKnown(LOW_MARKER) end
    if hadMarker and fs.exists(LOW_MARKER_BAK) then moveChecked(LOW_MARKER_BAK, LOW_MARKER) end
    if fs.exists(LOW_MARKER_TMP) then deleteKnown(LOW_MARKER_TMP) end
    return false, moveNewError or "Recovery marker verification failed"
  end
  if fs.exists(LOW_MARKER_BAK) then deleteKnown(LOW_MARKER_BAK) end
  return true
end

local function lowFailure(message)
  local free = freeSpace(ROOT)
  local suffix = free and (" Free space: " .. formatBytes(free) .. ".") or ""
  local retryAction = (action == "worker" or action == "controller" or action == "gps")
    and action or "update-low-space"
  error(tostring(message) .. "\nRecovery marker: " .. LOW_MARKER .. "." .. suffix
    .. "\nFree space or repair the reported path, then rerun:\n  wget run "
    .. BASE_URL .. "install.lua " .. retryAction, 0)
end

local function lowPlan(role)
  local selected = filesForRole(role)
  local plan, loader = {}, loaderTarget(role)
  if loader then plan[#plan + 1] = { target = loader, sentinel = true } end
  for _, file in ipairs(selected) do
    if file.target ~= loader then plan[#plan + 1] = file end
  end
  local selectedSet = targetsForRole(role)
  for _, file in ipairs(FILES) do
    if not selectedSet[file.target] then plan[#plan + 1] = { target = file.target, obsolete = true } end
  end
  -- The real loader is the final commit step.  Until then the sentinel keeps
  -- boot.lua from executing a mixed loader/parts set, including while known
  -- obsolete runtime files are removed.
  if loader then
    for _, file in ipairs(selected) do
      if file.target == loader then plan[#plan + 1] = file end
    end
  end
  return plan, selected
end

local function lowBodyForTarget(role, entry, partCache)
  if entry.sentinel then return SENTINEL end
  if entry.obsolete then return nil end
  if partCache and partCache[entry.target] then return partCache[entry.target] end
  local body, err = download(BASE_URL .. entry.source)
  if not body then return nil, err end
  return body
end

local function restoreLowOld(target, hadOld)
  local path = pathFor(ROOT, target)
  local newPath, oldPath = internalPaths(target)
  if fs.exists(path) then deleteKnown(path) end
  if hadOld and fs.exists(oldPath) then
    local moved = moveChecked(oldPath, path)
    return moved
  end
  if fs.exists(oldPath) then deleteKnown(oldPath) end
  if fs.exists(newPath) then deleteKnown(newPath) end
  return true
end

local function lowSwap(role, index, entry, body)
  local target, path = entry.target, pathFor(ROOT, entry.target)
  if fs.exists(path) and fs.isDir(path) then return false, "Known runtime target is a directory: " .. path end
  local newPath, oldPath = internalPaths(target)
  if fs.exists(newPath) and fs.isDir(newPath) then return false, "Stale .new artifact is a directory: " .. newPath end
  if fs.exists(oldPath) and fs.isDir(oldPath) then return false, "Stale .old artifact is a directory: " .. oldPath end
  local existingBody = fs.exists(path) and readFile(path) or nil
  local hadOld = fs.exists(oldPath)
  if hadOld and existingBody == body then
    -- Power failed after the swap but before marker advancement.  Keep the
    -- old copy until the marker is durably advanced, then finish cleanup.
    local marked, markerError = writeMarker(role, index + 1, "commit")
    if not marked then return false, "Cannot advance recovery marker: " .. tostring(markerError) end
    local removed, removeError = deleteKnown(oldPath)
    if not removed then return false, "Cannot remove completed .old backup for " .. target .. ": " .. tostring(removeError) end
    return true
  elseif hadOld and existingBody ~= body then
    restoreLowOld(target, true)
  end
  local stagedBody = fs.exists(newPath) and readFile(newPath) or nil
  if fs.exists(newPath) and stagedBody ~= body then
    return false, "Stale .new artifact exists for " .. target .. "; refusing to overwrite it"
  end
  if not stagedBody then
    local wrote, writeError = writeFile(newPath, body)
    if not wrote or readFile(newPath) ~= body then
      if fs.exists(newPath) then deleteKnown(newPath) end
      return false, writeError or ("Write verification failed for " .. target)
    end
  end
  local marked, markerError = writeMarker(role, index, "commit")
  if not marked then deleteKnown(newPath); return false, "Cannot record recovery marker: " .. tostring(markerError) end
  local hadTarget = fs.exists(path)
  if hadTarget then
    local moved, moveError = moveChecked(path, oldPath)
    if not moved then deleteKnown(newPath); return false, moveError end
  end
  local movedNew, moveNewError = moveChecked(newPath, path)
  if not movedNew or readFile(path) ~= body then
    restoreLowOld(target, hadTarget)
    return false, moveNewError or ("Install verification failed for " .. target)
  end
  marked, markerError = writeMarker(role, index + 1, "commit")
  if not marked then
    -- The previous marker still points at this file.  Restore the old bytes
    -- now; a rerun can safely retry this exact index.
    restoreLowOld(target, hadTarget)
    return false, "Cannot advance recovery marker after installing " .. target .. ": " .. tostring(markerError)
  end
  if fs.exists(oldPath) then
    local removed, removeError = deleteKnown(oldPath)
    if not removed then return false, "Installed " .. target .. " but cannot remove its .old backup: " .. tostring(removeError) end
  end
  return true
end

local function lowRemoveObsolete(role, index, entry)
  local path, target = pathFor(ROOT, entry.target), entry.target
  if fs.exists(path) and fs.isDir(path) then return false, "Refusing to delete directory at known runtime target: " .. path end
  local newPath, oldPath = internalPaths(target)
  if fs.exists(newPath) and fs.isDir(newPath) then return false, "Stale .new artifact is a directory: " .. newPath end
  if fs.exists(oldPath) and fs.isDir(oldPath) then return false, "Stale .old artifact is a directory: " .. oldPath end
  if fs.exists(oldPath) and not fs.exists(path) then
    local marked, markerError = writeMarker(role, index + 1, "commit")
    if not marked then return false, "Cannot advance recovery marker: " .. tostring(markerError) end
    return deleteKnown(oldPath)
  end
  if not fs.exists(path) then
    return writeMarker(role, index + 1, "commit")
  end
  local marked, markerError = writeMarker(role, index, "commit")
  if not marked then return false, "Cannot record obsolete-file marker: " .. tostring(markerError) end
  local moved, moveError = moveChecked(path, oldPath)
  if not moved then return false, moveError end
  marked, markerError = writeMarker(role, index + 1, "commit")
  if not marked then
    if fs.exists(oldPath) then moveChecked(oldPath, path) end
    return false, "Cannot advance marker after removing obsolete " .. target .. ": " .. tostring(markerError)
  end
  local removed, removeError = deleteKnown(oldPath)
  if not removed then return false, "Cannot remove obsolete backup " .. target .. ": " .. tostring(removeError) end
  return true
end

local function lowValidateInstalled(role)
  local selected = filesForRole(role)
  local bodies = {}
  for _, file in ipairs(selected) do
    local body = readFile(pathFor(ROOT, file.target))
    if not body then return false, "Installed runtime file is missing: " .. file.target end
    bodies[file.target] = body
    if not file.target:match("%.part$") then
      local valid, err = compileText(body, file.target)
      if not valid then return false, "Installed syntax validation failed for " .. file.target .. ": " .. tostring(err) end
    end
  end
  local parts = partTargets(role)
  if parts then
    local valid, err = compileParts(bodies, role, parts)
    if not valid then return false, "Installed assembled validation failed for " .. role .. ": " .. tostring(err) end
  end
  return true
end

-- Keep the validation boundary named explicitly for source-contract tooling.
-- It validates only the selected role and its assembled parts.
local function validateLowSpaceStage(role)
  return lowValidateInstalled(role)
end

local function cleanupCommittedOld(plan, nextIndex)
  for index = 1, math.min(nextIndex - 1, #plan) do
    local entry = plan[index]
    local _, oldPath = internalPaths(entry.target)
    if fs.exists(oldPath) then
      if fs.isDir(oldPath) then return false, "Completed .old artifact is a directory: " .. oldPath end
      local removed, removeError = deleteKnown(oldPath)
      if not removed then return false, "Cannot remove completed .old backup for " .. entry.target .. ": " .. tostring(removeError) end
    end
  end
  return true
end

local function runLowSpace(role, installing)
  local plan, selected = lowPlan(role)
  local marker, markerError = readMarker()
  if marker == false then lowFailure(markerError) end
  if marker and marker.role ~= role then lowFailure("Recovery marker role " .. tostring(marker.role) .. " does not match config.db role " .. role .. ".") end
  if not marker then
    local made, makeError = writeMarker(role, 1, "prepare")
    if not made then lowFailure("Cannot create recovery marker; no runtime files were changed: " .. tostring(makeError)) end
    marker = { version = VERSION, role = role, next = 1, phase = "prepare" }
  end
  if marker.phase == "prepare" and marker.next ~= 1 then lowFailure("Recovery marker prepare phase has an invalid next index.") end
  if marker.next > #plan + 1 then lowFailure("Recovery marker next index is outside this role's commit plan.") end
  if marker.phase == "prepare" then
    local marked, writeError = writeMarker(role, 1, "commit")
    if not marked then lowFailure("Cannot enter commit phase: " .. tostring(writeError)) end
    marker.phase, marker.next = "commit", 1
  end
  local cleaned, cleanupError = cleanupCommittedOld(plan, marker.next)
  if not cleaned then lowFailure(cleanupError) end

  print("CC MINER V4 " .. (installing and "INSTALL" or "UPDATE") .. "-LOW-SPACE " .. string.upper(role))
  print("Per-file mode: no complete runtime staging tree is created.")
  local currentBytes = 0
  for _, file in ipairs(selected) do
    local currentBody = readFile(pathFor(ROOT, file.target))
    if currentBody then currentBytes = currentBytes + #currentBody end
  end
  showCapacity(role, currentBytes, "current runtime; free space checked before each file")
  local partCache, partLoaded = nil, false
  local totalBytes = 0
  local parts = partTargets(role)
  local partSet = {}
  for _, target in ipairs(parts or {}) do partSet[target] = true end
  for index = marker.next, #plan do
    local entry = plan[index]
    local body, bodyError
    if entry.obsolete then
      local removed, removeError = lowRemoveObsolete(role, index, entry)
      if not removed then lowFailure(removeError) end
    else
      if parts and partSet[entry.target] and not partLoaded then
        partCache = {}
        local partError
        for _, target in ipairs(parts) do
          local partFile
          for _, candidate in ipairs(selected) do if candidate.target == target then partFile = candidate end end
          if not partFile then lowFailure("Manifest is missing part " .. target) end
          local free = freeSpace(ROOT)
          write(("[part %s] %s (%s; free %s) ... "):format(target, target, free and formatBytes(0) or "size?", free and formatBytes(free) or "unknown"))
          local downloaded, downloadError = download(BASE_URL .. partFile.source)
          partError = downloadError
          if not downloaded then printError("FAILED"); lowFailure(partError) end
          partCache[target] = downloaded; totalBytes = totalBytes + #downloaded; print("OK")
        end
        local valid, assembledError = compileParts(partCache, role, parts)
        if not valid then lowFailure("Downloaded assembled " .. role .. " source failed validation: " .. tostring(assembledError)) end
        partLoaded = true
      end
      body, bodyError = lowBodyForTarget(role, entry, partCache)
      if not body then lowFailure(bodyError or ("Cannot download " .. tostring(entry.target))) end
      if not entry.target:match("%.part$") then
        local valid, syntaxError = compileText(body, entry.target)
        if not valid then lowFailure("Downloaded syntax validation failed for " .. entry.target .. ": " .. tostring(syntaxError)) end
      end
      totalBytes = totalBytes + (partCache and partCache[entry.target] and 0 or #body)
      local free = freeSpace(ROOT)
      print(("[%d/%d] %s (%s; free %s) ..."):format(index, #plan, entry.target, formatBytes(#body), free and formatBytes(free) or "unknown"))
      local ok, swapError = lowSwap(role, index, entry, body)
      if not ok then printError("FAILED"); lowFailure(swapError) end
      print("OK")
    end
    marker.next = index + 1
  end
  local valid, validationError = validateLowSpaceStage(role)
  if not valid then lowFailure(validationError) end
  local removedMarker, markerDeleteError = deleteKnown(LOW_MARKER)
  if not removedMarker or fs.exists(LOW_MARKER) then lowFailure("Runtime is valid but recovery marker could not be cleared: " .. tostring(markerDeleteError)) end
  local removedBak, backupDeleteError = deleteKnown(LOW_MARKER_BAK)
  if not removedBak or fs.exists(LOW_MARKER_BAK) then lowFailure("Runtime is valid but marker backup could not be cleared: " .. tostring(backupDeleteError)) end
  local removedTmp, tempDeleteError = deleteKnown(LOW_MARKER_TMP)
  if not removedTmp or fs.exists(LOW_MARKER_TMP) then lowFailure("Runtime is valid but marker temporary file could not be cleared: " .. tostring(tempDeleteError)) end
  showCapacity(role, totalBytes, "installed and assembled-validated")
  print("Low-space " .. (installing and "installation" or "update") .. " completed: " .. VERSION)
  if installing then
    print("Starting first-time setup.")
  else
    print("User data under /ccminer was left in place. Reboot with: reboot")
  end
end

local function usage()
  print("CC Miner V4 installer " .. VERSION .. " (schema " .. SCHEMA .. ")")
  print("  install.lua worker")
  print("  install.lua controller")
  print("  install.lua gps")
  print("  install.lua update [worker|controller|gps]")
  print("  install.lua update-low-space [worker|controller|gps]")
end

if action == "" then action = turtle and "worker" or "controller" end
if action ~= "worker" and action ~= "controller" and action ~= "gps"
    and action ~= "update" and action ~= "update-low-space" then usage(); return end
if action == "worker" and not turtle then fail("Worker installation requires a turtle.") end
if args[3] ~= nil then fail("Unexpected extra argument; see installer usage.") end
if (action == "worker" or action == "controller" or action == "gps") and args[2] ~= nil then
  fail("Role is selected by the first argument; do not pass a second role.")
end

local role, roleError
if action == "update" or action == "update-low-space" then
  if args[2] ~= nil and not ROLES[tostring(args[2])] then fail("Unknown requested role: " .. tostring(args[2])) end
  role, roleError = configRole(args[2] and tostring(args[2]) or nil)
  if not role then fail(roleError) end
else
  role = action
  local validExisting, existingError = validateExistingRoleForInstall(role)
  if not validExisting then fail(existingError) end
end

local function finishFirstInstall(installRole)
  local setupOk, setupError = pcall(shell.run, ROOT .. "/setup.lua", installRole)
  if not setupOk or setupError == false then
    printError("Setup did not complete. Run: " .. ROOT .. "/setup.lua " .. installRole)
  else
    print("Installation complete for role " .. installRole .. ".")
    print("Reboot with: reboot")
  end
end

-- A complete controller or worker runtime is roughly half of a standard
-- ComputerCraft computer's 1 MiB disk. A staging tree plus the installed
-- files cannot fit reliably, even on a fresh computer. Initial installs
-- therefore use the same verified, resumable per-file transaction as the
-- low-space updater from the outset.
if action == "worker" or action == "controller" or action == "gps" then
  runLowSpace(role, true)
  finishFirstInstall(role)
  return
end

if action == "update-low-space" then
  runLowSpace(role, false)
  return
end

if action == "update" then
  local pendingMarker, pendingError = readMarker()
  if pendingMarker or pendingMarker == false then
    fail("A low-space update is incomplete; resume it with install.lua update-low-space. "
      .. tostring(pendingError or ("Recovery marker: " .. LOW_SPACE_MARKER)))
  end
end

local base, selected, stageError, payloadBytes, lowSpaceRecommended = stageRegular(role)
if not base and action == "update" and lowSpaceRecommended then
  printError(stageError)
  print("Regular staging does not fit. Switching automatically to update-low-space mode.")
  print("No complete second copy of /ccminer will be created.")
  runLowSpace(role, false)
  return
end
if not base then fail(stageError) end
local committed, commitError = regularCommit(role, base, selected)
if not committed then fail(commitError) end

print("Update installed successfully: " .. VERSION .. " (role " .. role .. ")")
print("User data under /ccminer (config/state/journal/log files) and unknown files were left in place.")
print("Reboot with: reboot")
