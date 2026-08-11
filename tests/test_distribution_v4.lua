-- CC Miner V4 role-scoped distribution contracts.
--
-- These checks deliberately inspect the manifest, online installer source and
-- offline bundle generator without running an installer or rebuilding dist/.
-- The three copies of the distribution list must stay byte/order compatible,
-- while each role receives only the files it is allowed to execute.

local root = assert(arg[1], "repository root is required")

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function requireText(text, needle, label)
  assert(text:find(needle, 1, true), "missing " .. label .. ": " .. needle)
end

local function requireOrdered(text, needles, label)
  local cursor = 1
  for _, needle in ipairs(needles) do
    local found = assert(text:find(needle, cursor, true),
      label .. " is missing or out of order: " .. needle)
    cursor = found + #needle
  end
end

local function roleMap(worker, controller, gps)
  local result = {}
  if worker then result.worker = true end
  if controller then result.controller = true end
  if gps then result.gps = true end
  return result
end

local expected = {
  { "src/ccminer/lib/common.lua", "lib/common.lua", roleMap(true, true, true) },
  { "src/ccminer/lib/protocol.lua", "lib/protocol.lua", roleMap(true, true, true) },
  { "src/ccminer/setup.lua", "setup.lua", roleMap(true, true, true) },
  { "src/ccminer/boot.lua", "boot.lua", roleMap(true, true, true) },
  { "src/ccminer/command.lua", "command.lua", roleMap(true, true, true) },
  { "src/ccminer/lib/geo.lua", "lib/geo.lua", roleMap(true, false, false) },
  { "src/ccminer/lib/quarry.lua", "lib/quarry.lua", roleMap(true, true, false) },
  { "src/ccminer/worker.lua", "worker.lua", roleMap(true, false, false) },
  { "src/ccminer/worker_parts/01.part", "worker_parts/01.part", roleMap(true, false, false) },
  { "src/ccminer/worker_parts/02.part", "worker_parts/02.part", roleMap(true, false, false) },
  { "src/ccminer/worker_parts/03.part", "worker_parts/03.part", roleMap(true, false, false) },
  { "src/ccminer/worker_parts/04.part", "worker_parts/04.part", roleMap(true, false, false) },
  { "src/ccminer/worker_parts/05.part", "worker_parts/05.part", roleMap(true, false, false) },
  { "src/ccminer/controller.lua", "controller.lua", roleMap(false, true, false) },
  { "src/ccminer/controller_parts/01.part", "controller_parts/01.part", roleMap(false, true, false) },
  { "src/ccminer/controller_parts/02.part", "controller_parts/02.part", roleMap(false, true, false) },
  { "src/ccminer/controller_parts/03.part", "controller_parts/03.part", roleMap(false, true, false) },
  { "src/ccminer/gps_host.lua", "gps_host.lua", roleMap(false, false, true) },
}

local roles = { "worker", "controller", "gps" }
local function assertExactRoles(actual, wanted, label)
  local seen = {}
  for key, value in pairs(actual or {}) do
    assert(type(key) == "string" and wanted[key] ~= nil,
      label .. " has an unknown role key: " .. tostring(key))
    assert(value == true, label .. " role " .. key .. " is not true")
    assert(not seen[key], label .. " repeats role " .. key)
    seen[key] = true
  end
  for key, value in pairs(wanted) do
    assert((actual or {})[key] == value, label .. " role mismatch for " .. key)
  end
  for key in pairs(actual or {}) do
    assert(wanted[key] == true, label .. " has an unexpected role " .. tostring(key))
  end
end

-- The manifest is executable Lua, so compare its decoded table exactly.  This
-- catches duplicate sources/targets, omitted role keys, false values and list
-- reordering rather than merely checking that a few names occur in the file.
local manifest = dofile(root .. "/manifest.lua")
assert(manifest.name == "CC Miner V4", "manifest product name must be CC Miner V4")
assert(manifest.version == "4.0.0", "manifest version must be 4.0.0")
assert(manifest.schema == 4, "manifest schema must be 4")
assert(manifest.repository == "nononoyuyuyu/CC_Miner", "manifest repository scope changed")
assert(#manifest.files == #expected, "manifest file count changed")
local manifestSources, manifestTargets = {}, {}
for index, file in ipairs(manifest.files) do
  local wanted = expected[index]
  assert(type(file) == "table", "manifest entry " .. index .. " is not a table")
  assert(file.source == wanted[1], "manifest source order mismatch at " .. index)
  assert(file.target == wanted[2], "manifest target order mismatch at " .. index)
  assert(not manifestSources[file.source], "manifest source is duplicated: " .. file.source)
  assert(not manifestTargets[file.target], "manifest target is duplicated: " .. file.target)
  manifestSources[file.source], manifestTargets[file.target] = true, true
  assertExactRoles(file.roles, wanted[3], "manifest entry " .. index)
end
for key in pairs(manifest.files) do
  assert(type(key) == "number" and key >= 1 and key <= #expected and key % 1 == 0,
    "manifest.files contains an unexpected non-array key")
end

local function filesForRole(role)
  local result = {}
  for _, file in ipairs(manifest.files) do
    if file.roles[role] then result[#result + 1] = file.target end
  end
  return result
end

local expectedTargets = {
  worker = {
    "lib/common.lua", "lib/protocol.lua", "setup.lua", "boot.lua", "command.lua",
    "lib/geo.lua", "lib/quarry.lua", "worker.lua",
    "worker_parts/01.part", "worker_parts/02.part", "worker_parts/03.part",
    "worker_parts/04.part", "worker_parts/05.part",
  },
  controller = {
    "lib/common.lua", "lib/protocol.lua", "setup.lua", "boot.lua", "command.lua",
    "lib/quarry.lua", "controller.lua",
    "controller_parts/01.part", "controller_parts/02.part", "controller_parts/03.part",
  },
  gps = { "lib/common.lua", "lib/protocol.lua", "setup.lua", "boot.lua", "command.lua", "gps_host.lua" },
}
for _, role in ipairs(roles) do
  local actual = filesForRole(role)
  local wanted = expectedTargets[role]
  assert(#actual == #wanted, role .. " role file count changed")
  for index, target in ipairs(wanted) do
    assert(actual[index] == target, role .. " target order mismatch at " .. index)
  end
end
assert(#expectedTargets.worker == 13 and #expectedTargets.controller == 10 and #expectedTargets.gps == 6,
  "role count contract was edited accidentally")
for _, target in ipairs(expectedTargets.controller) do
  assert(target ~= "lib/geo.lua" and target ~= "worker.lua" and not target:match("^worker_parts/"),
    "controller must not receive worker/geo runtime")
end
for _, target in ipairs(expectedTargets.gps) do
  assert(target ~= "lib/geo.lua" and target ~= "lib/quarry.lua" and target ~= "worker.lua"
    and target ~= "controller.lua" and not target:match("_parts/"),
    "gps role must stay minimal")
end

-- The online installer embeds the same source/target/roles list because a
-- ComputerCraft machine cannot import manifest.lua from the repository.
local installer = read("install.lua")
requireText(installer, 'local VERSION, SCHEMA = "4.0.0", 4', "online VERSION/schema")
requireText(installer, 'local ROLES = { worker = true, controller = true, gps = true }', "online role enum")
local online = {}
for line in installer:gmatch("[^\r\n]+") do
  local source, target, body = line:match(
    '{%s*source%s*=%s*"([^"]+)"%s*,%s*target%s*=%s*"([^"]+)"%s*,%s*roles%s*=%s*{%s*(.-)%s*}%s*}%s*,?')
  if source then
    local roleValues = {}
    for key, value in body:gmatch("([%a_][%w_]*)%s*=%s*([%a_][%w_]*)") do
      assert(key == "worker" or key == "controller" or key == "gps",
        "online FILES contains an unknown role: " .. key)
      assert(value == "true", "online FILES role values must be true")
      assert(not roleValues[key], "online FILES repeats role " .. key)
      roleValues[key] = true
    end
    online[#online + 1] = { source, target, roleValues }
  end
end
assert(#online == #expected, "online FILES entry count differs from manifest")
for index, file in ipairs(online) do
  local wanted = expected[index]
  assert(file[1] == wanted[1] and file[2] == wanted[2],
    "online FILES source/target order mismatch at " .. index)
  assertExactRoles(file[3], wanted[3], "online FILES entry " .. index)
end
local onlineSources, onlineTargets = {}, {}
for _, file in ipairs(online) do
  assert(not onlineSources[file[1]] and not onlineTargets[file[2]], "online FILES contains a duplicate")
  onlineSources[file[1]], onlineTargets[file[2]] = true, true
end
requireText(installer, "local function filesForRole(role)", "online role filtering")
requireText(installer, "if file.roles[role] then selected[#selected + 1] = file end", "online role filtering predicate")

-- Updates read the existing role as an authority.  An omitted optional role
-- is accepted; a supplied role must match exactly, and unknown/malformed
-- config values fail closed before any staging or swap starts.
requireText(installer, "local function configRole(optionalRole)", "online config role decoder")
requireText(installer, "if optionalRole ~= nil and tostring(optionalRole) ~= role then", "online optional role mismatch")
requireText(installer, "Requested role \" .. tostring(optionalRole) .. \" does not match config.db role \"", "online mismatch error")
requireText(installer, "if type(role) ~= \"string\" or not ROLES[role] then", "online strict role validation")
requireText(installer, "role, roleError = configRole(args[2] and tostring(args[2]) or nil)", "online update role authority")
requireText(installer, "local function validateExistingRoleForInstall(role)", "online install role guard")
requireText(installer, "Existing config.db is for role \" .. existing .. \"; refusing to replace it with \" .. role", "online install mismatch")

-- Regular online updates stage and validate only the selected role, put a
-- harmless sentinel in front of parts, restore the real loader last, remove
-- only known obsolete targets, and retain a per-file rollback path.
local regularStart = assert(installer:find("local function regularCommit", 1, true), "online regular commit boundary")
local regularEnd = assert(installer:find("local function encodeMarker", regularStart, true), "online marker boundary")
local regular = installer:sub(regularStart, regularEnd - 1)
requireOrdered(regular, {
  "local commitPlan = {}",
  "commitPlan[#commitPlan + 1] = { target = loader, sentinel = true }",
  "if file.target ~= loader then commitPlan[#commitPlan + 1] = file end",
  "if file.target == loader then commitPlan[#commitPlan + 1] = file end",
  "local body = file.sentinel and SENTINEL or readFile(pathFor(base, file.target))",
  "local ok, err = replaceRegular(file.target, body, recordsByTarget[file.target])",
  "if not selectedSet[file.target] then",
}, "online regular commit")
requireText(installer, "local SENTINEL = [[-- CC Miner update sentinel", "online update sentinel")
requireText(installer, "local function replaceRegular(target, body, record)", "online per-file replacement")
requireText(installer, "local newPath, oldPath = internalPaths(target)", "online .new/.old transaction paths")
requireText(installer, "local function rollback(records)", "online rollback helper")
requireText(installer, "local restored, restoreError = rollback(records)", "online rollback on commit failure")
requireText(installer, "previous runtime was restored.", "online rollback confirmation")
requireText(installer, "local function backupRuntime(role)", "online known-target backup")
requireText(installer, "for target in pairs(ALL_TARGETS) do", "online known-target backup scope")
assert(not regular:find("fs.delete(ROOT)", 1, true) and not regular:find("moveChecked(ROOT", 1, true),
  "regular update must not replace/delete the complete installation tree")
requireText(installer, "User data under /ccminer", "online user-data preservation message")

-- Python source contracts are read only.  Parse the explicit tuple lists so a
-- role cannot accidentally gain another role's implementation through a
-- generator-only edit.
local builder = read("tools/build_offline_bundle.py")
requireText(builder, 'VERSION = "4.0.0"', "offline VERSION")
requireText(builder, "SCHEMA = 4", "offline schema")
requireText(builder, 'ROLE_ORDER = ("worker", "controller", "gps")', "offline role order")

local function section(startNeedle, endNeedle)
  local start = assert(builder:find(startNeedle, 1, true), "builder section is missing: " .. startNeedle)
  local finish = assert(builder:find(endNeedle, start + #startNeedle, true),
    "builder section terminator is missing: " .. endNeedle)
  return builder:sub(start, finish - 1)
end

local function tupleList(text)
  local result = {}
  for source, target in text:gmatch('%("([^"]+)"%s*,%s*"([^"]+)"%)') do
    result[#result + 1] = { source, target }
  end
  return result
end

local commonSection = section("COMMON_FILES = [", "WORKER_FILES = COMMON_FILES + [")
local commonTuples = tupleList(commonSection)
assert(#commonTuples == 5, "offline COMMON_FILES count changed")
for index = 1, 5 do
  assert(commonTuples[index][1] == expected[index][1] and commonTuples[index][2] == expected[index][2],
    "offline COMMON_FILES order mismatch at " .. index)
end

local roleSections = {
  worker = section("WORKER_FILES = COMMON_FILES + [", "CONTROLLER_FILES = COMMON_FILES + ["),
  controller = section("CONTROLLER_FILES = COMMON_FILES + [", "GPS_FILES = COMMON_FILES + ["),
  gps = section("GPS_FILES = COMMON_FILES + [", "ROLE_FILES: dict"),
}
local roleExtras = {
  worker = { 6, 7, 8, 9, 10, 11, 12, 13 },
  controller = { 7, 14, 15, 16, 17 },
  gps = { 18 },
}
for _, role in ipairs(roles) do
  requireText(roleSections[role], "COMMON_FILES + [", "offline " .. role .. " common list")
  local tuples = tupleList(roleSections[role])
  local expectedIndexes = roleExtras[role]
  assert(#tuples == #expectedIndexes, "offline " .. role .. " role-specific count changed")
  for index, expectedIndex in ipairs(expectedIndexes) do
    assert(tuples[index][1] == expected[expectedIndex][1] and tuples[index][2] == expected[expectedIndex][2],
      "offline " .. role .. " tuple order mismatch at " .. index)
  end
end
requireText(builder, '"worker": WORKER_FILES', "offline ROLE_FILES worker mapping")
requireText(builder, '"controller": CONTROLLER_FILES', "offline ROLE_FILES controller mapping")
requireText(builder, '"gps": GPS_FILES', "offline ROLE_FILES gps mapping")
requireText(builder, "seen_targets: set[str] = set()", "offline duplicate target rejection")
requireText(builder, "if target in seen_targets:", "offline duplicate target guard")

-- Each role has a generated loader and parts directory plus the compatibility
-- dispatcher.  The builder validates UTF-8 byte limits, per-part and
-- assembled SHA-256 digests, count/order, and rejects extra parts.
requireText(builder, "PART_LIMIT_BYTES = 12_000", "offline part byte limit")
requireText(builder, "def split_text(text: str, maximum_bytes: int = PART_LIMIT_BYTES)", "offline splitter")
requireText(builder, "len(part.encode(\"utf-8\")) > maximum_bytes", "offline UTF-8 byte limit")
requireText(builder, "hashlib.sha256(content.encode(\"utf-8\")).hexdigest()", "offline file digest")
requireText(builder, "def _role_digest(role: str, files: list[dict[str, str]])", "offline role aggregate digest")
requireText(builder, "def render_role_bundle(role: str)", "offline role bundle renderer")
requireText(builder, "ccminer-offline-%ROLE%.parts", "offline role parts directory")
requireText(builder, "ccminer-offline-%ROLE%.lua", "offline role loader")
requireText(builder, "def build_dispatcher()", "offline compatibility dispatcher")
requireText(builder, 'stage_dispatcher = stage / "ccminer-offline.lua"', "offline dispatcher output")
requireText(builder, "for role, (parts, names, loader) in bundles.items():", "offline three-role output loop")
requireText(builder, "if #text ~= item.bytes then", "offline part byte verification")
requireText(builder, "if digest(text) ~= string.lower(item.digest) then", "offline part digest verification")
requireText(builder, "if item.name ~= expectedName then", "offline part order verification")
requireText(builder, "for extra in pairs(found) do error(\"Unexpected offline installer part:", "offline extra-part rejection")
requireText(builder, "if #source ~= #partManifest then error(\"Offline installer part count mismatch\"", "offline part count verification")
requireText(builder, "if digest(assembled) ~= string.lower(EXPECTED_ASSEMBLED_DIGEST) then", "offline assembled digest verification")
requireText(builder, "if path.stat().st_size <= 0 or path.stat().st_size > PART_LIMIT_BYTES:", "offline --check byte bound")
requireText(builder, "def check_all_outputs()", "offline --check all roles")
local outputCheck = section("def check_all_outputs() -> None:", "def check_outputs")
local legacyAssignment = assert(outputCheck:match("legacy_parts%s*=%s*([^\r\n]+)"),
  "offline legacy parts path assignment is missing")
assert(legacyAssignment:find("ccminer-offline.parts", 1, true),
  "offline legacy parts path must target ccminer-offline.parts")
requireText(outputCheck, "if legacy_parts.exists():", "offline legacy parts rejection")

-- The loader is fail-closed: cleanup occurs only after every part and the
-- assembled program has been verified, and the in-memory program is not run
-- if either loader/parts self-delete fails.
local loaderStart = assert(builder:find("loader = r'''", 1, true), "offline loader template")
local loaderEnd = assert(builder:find("'''", loaderStart + #"loader = r'''", true), "offline loader template end")
local loader = builder:sub(loaderStart, loaderEnd - 1)
requireOrdered(loader, {
  "if not fs.isDir(partDir) then error(\"Missing offline installer parts directory:",
  "if #text ~= item.bytes then error(\"Offline installer part size mismatch:",
  "if digest(text) ~= string.lower(item.digest) then error(\"Offline installer part digest mismatch:",
  "for extra in pairs(found) do error(\"Unexpected offline installer part:",
  "if digest(assembled) ~= string.lower(EXPECTED_ASSEMBLED_DIGEST) then",
  "local program, compileError = loadSource(assembled",
  "if fs.exists(partDir) then fs.delete(partDir) end",
  "if fs.exists(partDir) then error(\"Offline bundle cleanup failed: parts directory remains.",
  "if fs.exists(loaderPath) then fs.delete(loaderPath) end",
  "if fs.exists(loaderPath) then error(\"Offline bundle cleanup failed: loader remains.",
  "return program(unpackArgs(args))",
}, "offline loader fail-closed order")

-- The generated installer is role-fixed and refuses update actions when the
-- existing config role differs.  Keep this check in the template rather than
-- trusting generated dist files (the bundle itself is intentionally not built
-- by this test).
local installerTemplateStart = assert(builder:find("template = r'''", 1, true), "offline installer template")
local installerTemplateEnd = assert(builder:find("'''", installerTemplateStart + #"template = r'''", true), "offline installer template end")
local template = builder:sub(installerTemplateStart, installerTemplateEnd - 1)
requireText(template, "local ROLE = \"%ROLE%\"", "offline fixed role")
requireText(template, "local function readConfigRole()", "offline config role decoder")
requireText(template, "local function validateAction()", "offline action validator")
requireText(template, "if configRole ~= ROLE then", "offline role/config mismatch")
requireText(template, "Refusing \" .. action .. \": existing config role is", "offline mismatch failure")
requireText(template, "if action ~= ROLE and action ~= \"update\" and action ~= \"update-low-space\" then", "offline fixed-role action guard")

-- Atomic output replacement and legacy bundle retirement are source-level
-- contracts; no generated files are touched here.
requireText(builder, "def _replace_target(source: Path, target: Path) -> None:", "offline atomic target replacement")
requireText(builder, "with tempfile.TemporaryDirectory(prefix=\".ccminer-offline.", "offline temporary output staging")
requireText(builder, "backup_root = Path(tempfile.mkdtemp(prefix=\".ccminer-offline-backup.", "offline backup staging")
requireText(builder, "for target in reversed(installed):", "offline atomic rollback installed outputs")
requireText(builder, "for backup, target in reversed(moved_backups):", "offline atomic rollback previous outputs")
requireText(builder, "committed = True", "offline atomic commit flag")
requireText(builder, "if committed and backup_root.exists():", "offline atomic backup cleanup")

print("V4 manifest, role-scoped online/offline distribution, and fail-closed bundle contracts passed")
