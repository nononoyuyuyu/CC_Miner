-- Startup wrapper generation and legacy migration source contracts.

local root = assert(arg[1], "repository root is required")

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function marker(text, expected, label)
  assert(text:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

local setup = read("src/ccminer/setup.lua")
local startupMarker = "-- CC_MINER_V2_STARTUP"
local startupPrefix = 'local startup = startupMarker .. "\\n" .. [['
local prefixStart = assert(
  setup:find(startupPrefix, 1, true),
  "startup generation must add an explicit newline after the marker"
)
local bodyStart = prefixStart + #startupPrefix
assert(setup:sub(bodyStart, bodyStart) == "\n", "startup body must start on the next source line")
local bodyEnd = assert(setup:find("]]", bodyStart + 1, true), "startup long string is not closed")
local body = setup:sub(bodyStart + 1, bodyEnd - 1)
local generated = startupMarker .. "\n" .. body

local expected = table.concat({
  startupMarker,
  'if fs.exists("/startup.user.lua") then',
  '  local ok, err = pcall(function() shell.run("/startup.user.lua") end)',
  '  if not ok then printError("User startup failed: " .. tostring(err)) end',
  "end",
  'shell.run("/ccminer/boot.lua")',
}, "\n") .. "\n"
assert(generated == expected, "generated startup wrapper changed unexpectedly")

local loader = loadstring or load
local compiled, compileError = loader(generated, "@startup.lua")
assert(compiled, "generated startup.lua failed syntax validation: " .. tostring(compileError))

-- Preserve the marker-based migration guard and atomic handoff for old startup files.
marker(setup, 'local startupMarker = "-- CC_MINER_V2_STARTUP"', "startup marker")
local guard = assert(
  setup:find("if existingStartup and not existingStartup:find(startupMarker, 1, true) then", 1, true),
  "startup migration guard"
)
local migration = assert(
  setup:find('common.writeAllAtomic("/startup.user.lua", existingStartup)', 1, true),
  "legacy startup migration"
)
assert(guard < migration, "legacy startup migration must remain guarded by the marker check")
marker(setup, 'common.writeAllAtomic("/startup.lua", startup)', "startup atomic write")

print("startup wrapper and migration contracts passed")
