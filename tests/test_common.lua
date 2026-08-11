local root = arg[1]
local files, directories = {}, { [""] = true }
local function normalized(path)
  return tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
end
fs = {}
function fs.exists(path)
  path = normalized(path)
  return files[path] ~= nil or directories[path] == true
end
function fs.isDir(path)
  return directories[normalized(path)] == true
end
function fs.getDir(path)
  local cleaned = normalized(path)
  return cleaned:match("^(.*)/[^/]+$") or ""
end
function fs.makeDir(path)
  path = normalized(path)
  if path == "" then directories[path] = true; return end
  local parent = fs.getDir(path)
  if not directories[parent] then fs.makeDir(parent) end
  directories[path] = true
end
function fs.delete(path)
  path = normalized(path)
  files[path] = nil
  for candidate in pairs(files) do
    if candidate:sub(1, #path + 1) == path .. "/" then files[candidate] = nil end
  end
  for candidate in pairs(directories) do
    if candidate == path or candidate:sub(1, #path + 1) == path .. "/" then directories[candidate] = nil end
  end
end
function fs.move(source, target)
  source, target = normalized(source), normalized(target)
  local targetDir = fs.getDir(target)
  if targetDir ~= "" then fs.makeDir(targetDir) end
  if files[source] ~= nil then
    files[target], files[source] = files[source], nil
    return
  end
  error("mock move source is missing: " .. source)
end
function fs.getSize(path)
  return #(files[normalized(path)] or "")
end
function fs.open(path, mode)
  path = normalized(path)
  local targetDir = fs.getDir(path)
  if targetDir ~= "" then fs.makeDir(targetDir) end
  if mode == "r" and files[path] == nil then return nil end
  local content = mode == "a" and (files[path] or "") or mode == "r" and files[path] or ""
  local position = 1
  return {
    readAll = function() position = #content + 1; return content end,
    readLine = function()
      if position > #content then return nil end
      local nextLine = content:find("\n", position, true)
      local line = content:sub(position, nextLine and nextLine - 1 or #content)
      position = nextLine and nextLine + 1 or #content + 1
      return line
    end,
    write = function(text) content = content .. tostring(text or "") end,
    writeLine = function(text) content = content .. tostring(text or "") .. "\n" end,
    close = function() files[path] = content end,
  }
end

textutils = {}
function textutils.serialize(value)
  local function encode(item)
    if type(item) == "table" then
      local parts = { "{" }
      for key, value in pairs(item) do parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(value) .. "," end
      parts[#parts + 1] = "}"
      return table.concat(parts)
    elseif type(item) == "string" then return string.format("%q", item)
    else return tostring(item) end
  end
  return encode(value)
end
function textutils.unserialize(text)
  local loader = loadstring or load
  local fn = assert(loader("return " .. text))
  return fn()
end
os.getComputerID = function() return 1 end
os.getComputerLabel = function() return "Test" end

local common = dofile(root .. "/src/ccminer/lib/common.lua")
assert(common.VERSION == "2.1.0")
assert(common.SCHEMA == 3)

local ok, err = common.writeAllAtomic("/state.db", "{[\"value\"]=\"one\",}")
assert(ok, err)
ok, err = common.writeAllAtomic("/state.db", "{[\"value\"]=\"two\",}")
assert(ok, err)
assert(fs.exists("/state.db") and fs.exists("/state.db.bak"))
fs.delete("/state.db")
local recovered, recoveryError = common.loadTable("/state.db", {})
assert(not recoveryError, recoveryError)
assert(recovered.value == "one")
assert(fs.exists("/state.db"))

local saved, saveError = common.saveTable("/table.db", { role = "worker", nested = { state = "idle" } })
assert(saved, saveError)
local loaded, loadError = common.loadTable("/table.db", {})
assert(not loadError, loadError)
assert(loaded.role == "worker" and loaded.nested.state == "idle")

local worker = common.defaultWorkerConfig()
assert(worker.lavaMode == "seal")
assert(worker.gps.enabled == true)
assert(worker.sealBlocks["minecraft:cobblestone"])
assert(common.defaultControllerConfig().touchEnabled == true)
assert(common.defaultGPSConfig().role == "gps")
assert(common.defaultState().stats.lavaSealed == 0)

print("common persistence and defaults tests passed")
