local root = arg[1]
local sandbox = os.tmpname() .. "-ccminer"
os.execute("mkdir -p " .. string.format("%q", sandbox))

local function full(path)
  return sandbox .. "/" .. tostring(path):gsub("^/+", "")
end

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
function fs.makeDir(path)
  os.execute("mkdir -p " .. string.format("%q", full(path)))
end
function fs.delete(path)
  os.execute("rm -rf " .. string.format("%q", full(path)))
end
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
  local parts = { "{" }
  for key, item in pairs(value) do
    parts[#parts + 1] = ("[%q]=%q,"):format(tostring(key), tostring(item))
  end
  parts[#parts + 1] = "}"
  return table.concat(parts)
end
function textutils.unserialize(text)
  local loader = loadstring or load
  local fn = assert(loader("return " .. text))
  return fn()
end

os.getComputerID = function() return 1 end
os.getComputerLabel = function() return "Test" end

local common = dofile(root .. "/src/ccminer/lib/common.lua")

local ok, err = common.writeAllAtomic("/state.db", "{[\"value\"]=\"one\",}")
assert(ok, err)
ok, err = common.writeAllAtomic("/state.db", "{[\"value\"]=\"two\",}")
assert(ok, err)
assert(fs.exists("/state.db"))
assert(fs.exists("/state.db.bak"))

fs.delete("/state.db")
local recovered, recoveryError = common.loadTable("/state.db", {})
assert(not recoveryError, recoveryError)
assert(recovered.value == "one")
assert(fs.exists("/state.db"))

local saved, saveError = common.saveTable("/table.db", { role = "worker", state = "idle" })
assert(saved, saveError)
local loaded, loadError = common.loadTable("/table.db", {})
assert(not loadError, loadError)
assert(loaded.role == "worker")
assert(loaded.state == "idle")

os.execute("rm -rf " .. string.format("%q", sandbox))
print("common persistence tests passed")
