local root = arg[1]
local sandbox = os.tmpname() .. "-ccminer"
os.execute("mkdir -p " .. string.format("%q", sandbox))

local function full(path) return sandbox .. "/" .. tostring(path):gsub("^/+", "") end
fs = {}
function fs.exists(path)
  local handle = io.open(full(path), "rb")
  if handle then handle:close(); return true end
  local ok = os.execute("test -d " .. string.format("%q", full(path)))
  return ok == true or ok == 0
end
function fs.isDir(path)
  local ok = os.execute("test -d " .. string.format("%q", full(path)))
  return ok == true or ok == 0
end
function fs.getDir(path)
  local cleaned = tostring(path):gsub("/+$", "")
  return cleaned:match("^(.*)/[^/]+$") or ""
end
function fs.makeDir(path) os.execute("mkdir -p " .. string.format("%q", full(path))) end
function fs.delete(path) os.execute("rm -rf " .. string.format("%q", full(path))) end
function fs.move(source, target)
  local targetDir = fs.getDir(target)
  if targetDir ~= "" then fs.makeDir(targetDir) end
  assert(os.rename(full(source), full(target)))
end
function fs.getSize(path)
  local handle = assert(io.open(full(path), "rb"))
  local size = handle:seek("end")
  handle:close()
  return size
end
function fs.open(path, mode)
  local targetDir = fs.getDir(path)
  if targetDir ~= "" then fs.makeDir(targetDir) end
  local ioMode = mode == "r" and "r" or mode == "a" and "a" or "w"
  local handle = io.open(full(path), ioMode)
  if not handle then return nil end
  return {
    readAll = function() return handle:read("*a") end,
    readLine = function() return handle:read("*l") end,
    write = function(text) handle:write(text) end,
    writeLine = function(text) handle:write(text, "\n") end,
    close = function() handle:close() end,
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

os.execute("rm -rf " .. string.format("%q", sandbox))
print("common persistence and defaults tests passed")
