-- Source contracts for the V4 interactive setup wizard.  Setup itself is
-- deliberately not executed: it needs a live CC:Tweaked terminal/turtle and
-- would write configuration/startup files.  These checks keep the safety
-- prompts and generated wrapper contract reviewable on a host machine.

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
local common = read("src/ccminer/lib/common.lua")

-- The setup wizard is the V4 entry point and must write the V4 schema through
-- common.saveConfig for every interactive role.
marker(setup, "-- CC Miner V4 - interactive configuration", "V4 setup header")
marker(common, 'M.VERSION = "4.0.0"', "V4 product version")
marker(common, "M.SCHEMA = 4", "V4 config schema")
marker(setup, "common.saveConfig(config)", "config save")
marker(setup, 'config.role = "gps"', "GPS role assignment")
marker(setup, 'config.role, config.networkKey = "worker", key', "worker role assignment")
marker(setup, 'config.role, config.networkKey = "controller", key', "controller role assignment")
marker(setup, 'if requestedRole == "worker" then', "worker setup branch")
marker(setup, 'else\n    config = common.merge(common.defaultControllerConfig()', "controller setup branch")
marker(setup, 'requestedRole ~= "worker" and requestedRole ~= "controller" and requestedRole ~= "gps"', "role selection guard")

-- Worker prompts and fields: malformed stored values are normalized before
-- prompting, and every new V4 nested record is materialized for a rerun.
for _, expected in ipairs({
  'local discard = ensureTable(config, "discard", workerDefaults.discard)',
  'local performance = ensureTable(config, "performance", workerDefaults.performance)',
  'local dock = ensureTable(config, "dock", workerDefaults.dock)',
  'local group = ensureTable(config, "group", workerDefaults.group)',
  'ensureTable(config, "service", workerDefaults.service)',
  'local journal = ensureTable(config, "journal", workerDefaults.journal)',
  'discardModePrompt(discard.mode)',
  'allowlistPrompt(discard.allowlist)',
  'discard.retainSealTarget',
  'discard.triggerEmptySlots',
  'discard.direction',
  'config.profile = enumPrompt("Operating profile (safe/balanced/turbo)"',
  'config.waterMode = enumPrompt("Water behavior (ignore/stop/seal)"',
  'config.maxContinuousSeal = common.promptNumber',
  'config.workerName = common.prompt(',
  'config.fuelTarget = common.promptNumber',
  'config.reserveEmptySlots = common.promptNumber',
  'dock.id = identifierPrompt("Dock ID"',
  'dock.groupId = identifierPrompt("Worker group ID"',
  'dock.bayId = identifierPrompt("Dock bay ID"',
  'dock.requireSameFloor = common.promptYesNo',
  'config.lavaMode = enumPrompt("Lava behavior (seal/stop)"',
  'config.sealSide = enumPrompt("Seal-block chest side (right/left)"',
  'lighting.mode = enumPrompt("Lighting mode (off/safe/custom)"',
  'torchSidePrompt(lighting.side',
  'config.gps.enabled = common.promptYesNo',
  'config.gps.required = common.promptYesNo',
}) do
  marker(setup, expected, "worker setup field/prompt")
end

-- Disposal defaults to no world drops.  Custom entries are complete IDs only,
-- while the physical drop direction and torch/seal sides are safety-gated.
marker(setup, "Disposal is deliberately a short, explicit safety wizard", "discard explanation")
marker(setup, "KEEP_ALL = true", "KEEP_ALL discard mode")
marker(setup, "DISCARD_EXCESS_STONE = true", "stone discard mode")
marker(setup, "CUSTOM_ALLOWLIST = true", "custom discard mode")
marker(setup, "no wildcard or partial names", "allowlist safety explanation")
marker(setup, "if sealSide and side == sealSide then", "torch/seal side collision guard")
marker(setup, "until side ~= sealSide", "torch side collision retry")
marker(setup, "Warning: torch chest side must not match the seal-block chest side.", "torch side warning")
marker(setup, "現場廃棄方向", "discard direction explanation")
marker(setup, "設定方向に inventory が見つかった場合は、誤投入防止のため world 廃棄をスキップします。", "discard side safety explanation")

-- Controller prompts expose group capacity, service concurrency, explicit
-- partition mode, GPS safety gate, and dock floor checks.
for _, expected in ipairs({
  'local group = ensureTable(config, "group", controllerDefaults.group)',
  'local dock = ensureTable(config, "dock", controllerDefaults.dock)',
  'group.maxWorkers = common.promptNumber',
  'group.maxConcurrentService = common.promptNumber',
  'group.partitionMode = enumPrompt("Partition mode (stripe/round_robin)"',
  'stripe = true, round_robin = true',
  'group.requireGpsForPartition = common.promptYesNo',
  'dock.baySpacing = common.promptNumber',
  'dock.requireSameFloor = common.promptYesNo',
  'config.historyLimit = common.promptNumber',
  'config.queueEnabled = common.promptYesNo',
  'config.overlapProtection = common.promptYesNo',
  'config.adaptiveRefresh = common.promptYesNo',
  'config.controllerName = common.prompt(',
  'config.monitorTextScale = tonumber(common.prompt(',
  'config.touchEnabled = common.promptYesNo',
}) do
  marker(setup, expected, "controller setup field/prompt")
end

-- Startup wrapper contract: retain the V2 marker, put the body on the next
-- line, preserve an existing user startup, and hand off to V4 boot atomically.
local startupMarker = "-- CC_MINER_V2_STARTUP"
local startupPrefix = 'local startup = startupMarker .. "\\n" .. [['
local prefixStart = assert(
  setup:find(startupPrefix, 1, true),
  "startup generation must add an explicit newline after the V2 marker"
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

marker(setup, 'local startupMarker = "-- CC_MINER_V2_STARTUP"', "V2 startup marker")
marker(setup, 'if existingStartup and not existingStartup:find(startupMarker, 1, true) then', "legacy startup marker guard")
marker(setup, 'common.writeAllAtomic("/startup.user.lua", existingStartup)', "legacy startup preservation")
marker(setup, 'common.writeAllAtomic("/startup.lua", startup)', "atomic startup write")
marker(setup, 'if existingStartup and not existingStartup:find(startupMarker, 1, true) then', "V2 marker migration guard")
marker(setup, 'common.writeAllAtomic("/ccm.lua", [[', "ccm launcher write")

print("V4 setup worker/controller prompts, discard safety, partition, and startup contracts passed")
