-- CC Miner V4 low-space update source contracts.
--
-- The update paths are deliberately not executed here: they require a live
-- ComputerCraft fs/http/textutils environment and may replace runtime files.
-- These checks keep the transaction, marker and recovery invariants visible in
-- the online installer and in the generated offline-installer template.

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

local function block(text, startNeedle, endNeedle, label)
  local start = assert(text:find(startNeedle, 1, true), label .. " start")
  local finish = assert(text:find(endNeedle, start + #startNeedle, true), label .. " end")
  return text:sub(start, finish - 1)
end

local installer = read("install.lua")
requireText(installer, 'local VERSION, SCHEMA = "4.0.0", 4', "online VERSION/schema")
requireText(installer, 'local LOW_MARKER = "/ccminer.update.low-space.marker"', "online low-space marker")
requireText(installer, 'LOW_MARKER_TMP, LOW_MARKER_BAK = LOW_MARKER .. ".tmp", LOW_MARKER .. ".bak"',
  "online marker temporary/backup names")
requireText(installer, "local function encodeMarker(marker)", "online marker encoder")
requireText(installer, "local function decodeMarker(path)", "online marker decoder")
requireText(installer, "local marker = { version = VERSION, role = role, next = nextIndex, phase = phase }",
  "online marker version/role/next/phase fields")
requireText(installer, "if marker.version ~= VERSION or not ROLES[marker.role] then return nil end", "online marker release/role validation")
requireText(installer, "if type(marker.next) ~= \"number\" or marker.next ~= math.floor(marker.next) or marker.next < 1 then return nil end",
  "online marker next-index validation")
requireText(installer, "if marker.phase ~= \"prepare\" and marker.phase ~= \"commit\" then return nil end",
  "online marker phase validation")
requireText(installer, "local function readMarker()", "online marker recovery reader")
requireText(installer, "marker = decodeMarker(LOW_MARKER_BAK)", "online marker backup fallback")
requireText(installer, "marker = decodeMarker(LOW_MARKER_TMP)", "online marker temp fallback")
requireText(installer, "Recovery marker is malformed or belongs to another release", "online malformed-marker fail-closed")

-- Marker writes are a small atomic transaction.  A failed replacement must
-- restore the previous marker, remove only the temporary file, and report an
-- error before runtime bytes are changed.
local writeMarker = block(installer, "local function writeMarker", "local function lowFailure", "online marker writer")
requireOrdered(writeMarker, {
  "local marker = { version = VERSION, role = role, next = nextIndex, phase = phase }",
  "local text, encodeError = encodeMarker(marker)",
  "local wrote, writeError = writeFile(LOW_MARKER_TMP, text)",
  "local hadMarker = fs.exists(LOW_MARKER)",
  "local moved, moveError = moveChecked(LOW_MARKER, LOW_MARKER_BAK)",
  "local movedNew, moveNewError = moveChecked(LOW_MARKER_TMP, LOW_MARKER)",
  "if not movedNew or not decodeMarker(LOW_MARKER) then",
  "if hadMarker and fs.exists(LOW_MARKER_BAK) then moveChecked(LOW_MARKER_BAK, LOW_MARKER) end",
  "if fs.exists(LOW_MARKER_TMP) then deleteKnown(LOW_MARKER_TMP) end",
}, "online marker atomic sequence")
requireText(writeMarker, "if fs.exists(LOW_MARKER_BAK) then", "online stale marker backup handling")
requireText(writeMarker, "if fs.exists(LOW_MARKER_BAK) then deleteKnown(LOW_MARKER_BAK) end", "online marker backup cleanup")

-- Regular updates retain the full-tree transaction, but low-space updates are
-- per-file only.  The low-space path never moves/deletes /ccminer as a tree.
local runLowSpace = block(installer, "local function runLowSpace", "local function usage", "online low-space implementation")
assert(not runLowSpace:find("moveChecked(ROOT", 1, true),
  "online low-space path must not move the complete installation tree")
assert(not runLowSpace:find("fs.delete(ROOT)", 1, true),
  "online low-space path must not delete the complete installation tree")
assert(not runLowSpace:find("ensureDir(ROOT)", 1, true),
  "online low-space path must not create a complete staging tree")
requireText(runLowSpace, "local plan, selected = lowPlan(role)", "online low-space plan")
requireText(runLowSpace, "marker.next", "online marker resume index")
requireText(runLowSpace, "for index = marker.next, #plan do", "online marker resume loop")
requireText(runLowSpace, "local partSet = {}", "online part target set")
requireText(runLowSpace, "local partCache, partLoaded = nil, false", "online part cache state")
requireText(runLowSpace, "for _, target in ipairs(parts) do", "online complete part preload")
requireText(runLowSpace, "partCache[target] = downloaded", "online part cache population")
requireText(runLowSpace, "local valid, assembledError = compileParts(partCache, role, parts)", "online assembled-part prevalidation")
requireText(runLowSpace, "if not valid then lowFailure(\"Downloaded assembled \" .. role .. \" source failed validation:",
  "online assembled-part fail-closed")
local lowValidation = block(installer, "local function validateLowSpaceStage(role)",
  "local function cleanupCommittedOld", "online final assembled validation alias")
requireText(lowValidation, "return lowValidateInstalled(role)", "online final assembled validation helper")
requireText(runLowSpace, "local valid, validationError = validateLowSpaceStage(role)",
  "online final assembled validation")
requireText(runLowSpace, "if not valid then lowFailure(validationError) end", "online final validation failure")

-- `lowPlan` places the harmless sentinel first, all selected non-loader files
-- next, known obsolete targets after them, and the real loader last.  This is
-- true for both worker/controller loaders; GPS's entrypoint follows the same
-- safety rule.
local lowPlan = block(installer, "local function lowPlan", "local function lowBodyForTarget", "online low-space plan")
requireOrdered(lowPlan, {
  "local plan, loader = {}, loaderTarget(role)",
  "if loader then plan[#plan + 1] = { target = loader, sentinel = true } end",
  "if file.target ~= loader then plan[#plan + 1] = file end",
  "if not selectedSet[file.target] then plan[#plan + 1] = { target = file.target, obsolete = true } end",
  "if file.target == loader then plan[#plan + 1] = file end",
}, "online low-space commit ordering")
requireText(installer, "local SENTINEL = [[-- CC Miner update sentinel", "online update sentinel")
requireText(installer, "if entry.sentinel then return SENTINEL end", "online sentinel body")

-- Every swap is a `.new` write followed by an `.old` backup, with marker
-- advancement on both sides of the rename and restoration on any failure.
local lowSwap = block(installer, "local function lowSwap", "local function lowRemoveObsolete", "online per-file swap")
requireText(lowSwap, "local newPath, oldPath = internalPaths(target)", "online per-file .new/.old paths")
requireText(lowSwap, "local stagedBody = fs.exists(newPath) and readFile(newPath) or nil", "online resumable .new body")
requireText(lowSwap, "local wrote, writeError = writeFile(newPath, body)", "online .new write")
requireText(lowSwap, "local marked, markerError = writeMarker(role, index, \"commit\")", "online pre-swap marker")
requireText(lowSwap, "local moved, moveError = moveChecked(path, oldPath)", "online .old backup move")
requireText(lowSwap, "local movedNew, moveNewError = moveChecked(newPath, path)", "online .new commit move")
requireText(lowSwap, "restoreLowOld(target, hadTarget)", "online per-file rollback")
requireText(lowSwap, "Cannot advance recovery marker after installing", "online marker-failure safety")
requireText(lowSwap, "deleteKnown(oldPath)", "online post-commit .old cleanup")
local lowRemove = block(installer, "local function lowRemoveObsolete", "local function lowValidateInstalled", "online obsolete removal")
requireText(lowRemove, "if fs.exists(oldPath) and not fs.exists(path) then", "online obsolete resume")
requireText(lowRemove, "if fs.exists(path) and fs.isDir(path) then return false", "online obsolete directory safety")
requireText(lowRemove, "if fs.exists(oldPath) then moveChecked(oldPath, path) end", "online obsolete rollback")

requireText(installer, "local function cleanupCommittedOld(plan, nextIndex)", "online completed-old cleanup")
requireText(installer, "if fs.isDir(oldPath) then return false", "online completed-old directory safety")
requireText(installer, "local removedMarker, markerDeleteError = deleteKnown(LOW_MARKER)", "online marker final removal")
requireText(installer, "if not removedTmp or fs.exists(LOW_MARKER_TMP) then lowFailure", "online marker cleanup failure")
requireText(installer, "User data under /ccminer", "online low-space user-data preservation")

-- A regular update may not have enough room for a second complete runtime.
-- Detect a truncated staged file, explain the expected/written sizes, and
-- switch only updates (never first installs) to the fail-closed low-space
-- transaction.
local regularStage = block(installer, "local function stageRegular", "local function backupRuntime",
  "online regular staging")
requireText(regularStage, "local required = #body + 4096", "online regular staging reserve")
requireText(regularStage, "if freeBefore and freeBefore < required then", "online regular free-space precheck")
requireText(regularStage, "local stagedBody = readFile(stagedPath)", "online staged readback")
requireText(regularStage, "stagedBody ~= nil and wrote < #body", "online truncated-file detection")
requireText(regularStage, "expected %s, wrote %s", "online actionable staging error")
requireText(installer, "if not base and action == \"update\" and lowSpaceRecommended then",
  "online update-only automatic low-space fallback")
requireOrdered(installer, {
  "Regular staging does not fit. Switching automatically to update-low-space mode.",
  "runLowSpace(role)",
  "return",
}, "online automatic low-space fallback")

-- The offline generator embeds the same transaction as a source template.
-- Read the Python source only: this test never imports it or regenerates dist/.
local builder = read("tools/build_offline_bundle.py")
requireText(builder, 'VERSION = "4.0.0"', "offline VERSION")
requireText(builder, "SCHEMA = 4", "offline schema")
requireText(builder, "LOW_SPACE_MARKER", "offline recovery marker")
requireText(builder, "def _low_space_steps(role: str", "offline low-space plan generator")
requireText(builder, 'if file["target"] != entrypoint', "offline non-loader step selection")
requireText(builder, 'operations.extend({"kind": "obsolete", "target": target} for target in obsolete)', "offline known obsolete steps")
requireText(builder, "UPDATE_SENTINEL", "offline update sentinel")
requireText(builder, "LOW_SPACE_STEPS", "offline low-space steps")
requireText(builder, "ENTRYPOINT", "offline role entrypoint")
local templateStart = assert(builder:find("template = r'''", 1, true), "offline installer template start")
local templateEnd = assert(builder:find("'''", templateStart + #"template = r'''", true), "offline installer template end")
local template = builder:sub(templateStart, templateEnd - 1)
local offlineLow = block(template, "local function lowSpaceUpdate", "if action == \"update-low-space\" then", "offline low-space implementation")
requireText(template, "local function validateLowSpaceStage()", "offline assembled prevalidation helper")
requireText(template, "local function ensureUpdateSentinel()", "offline sentinel installer")
requireText(template, "local function applyLowSpaceStep(step)", "offline per-file step applicator")
requireText(template, "local function embeddedEntrypoint()", "offline embedded final loader")
local offlineSentinel = block(template, "local function ensureUpdateSentinel()",
  "local function applyLowSpaceStep", "offline sentinel implementation")
requireText(offlineLow, "validateLowSpaceStage()", "offline full assembled prevalidation")
requireText(offlineLow, "ensureUpdateSentinel()", "offline sentinel step")
requireText(offlineSentinel, "atomicWrite(path, UPDATE_SENTINEL)", "offline atomic sentinel replacement")
requireText(offlineSentinel, "if readFile(path) ~= UPDATE_SENTINEL then", "offline sentinel verification")
requireText(offlineLow, "if marker.state == \"final-ready\" then", "offline final-ready resume state")
requireText(offlineLow, "first = #LOW_SPACE_STEPS + 1", "offline final-ready resume index")
requireText(offlineLow, "first = math.max(1, math.min(#LOW_SPACE_STEPS + 1, marker.next or 1))", "offline marker resume index")
requireText(offlineLow, "for index = first, #LOW_SPACE_STEPS do", "offline marker resume loop")
requireText(offlineLow, "local step = LOW_SPACE_STEPS[index]", "offline per-file low-space step")
requireText(offlineLow, "local applied, applyError = applyLowSpaceStep(step)", "offline per-file application")
requireText(offlineLow, "local finalContent = embeddedEntrypoint()", "offline final loader body")
requireText(offlineLow, "markerWrite(\"final-ready\", #LOW_SPACE_STEPS + 1)", "offline final-ready marker")
requireText(offlineLow, "local cleared, clearError = clearMarker()", "offline marker cleanup after final loader")
requireText(offlineLow, "local finalPath = ROOT .. \"/\" .. ENTRYPOINT", "offline final loader path")
requireText(offlineLow, "local wrote, writeError = atomicWrite(finalPath, finalContent)", "offline final loader atomic replacement")
requireText(offlineLow, "if readFile(finalPath) ~= finalContent then", "offline final loader verification")
assert(not offlineLow:find("ensureDir(TEMP)", 1, true) and not offlineLow:find("fs.delete(TEMP)", 1, true),
  "offline low-space path must not allocate a complete staging tree")
requireOrdered(offlineLow, {
  "validateLowSpaceStage()",
  "ensureUpdateSentinel()",
  "markerWrite(\"ready\", first)",
  "for index = first, #LOW_SPACE_STEPS do",
  "markerWrite(\"final-ready\", #LOW_SPACE_STEPS + 1)",
  "local finalPath = ROOT .. \"/\" .. ENTRYPOINT",
  "local wrote, writeError = atomicWrite(finalPath, finalContent)",
  "if readFile(finalPath) ~= finalContent then",
  "local cleared, clearError = clearMarker()",
}, "offline sentinel/non-loader/final-loader order")

-- Offline marker writes use the same atomic temp/backup fallback and reject
-- malformed release/role/state values before touching runtime files.
requireText(template, "local function atomicWrite(path, text)", "offline atomic marker writer")
requireText(template, "local temp, backup = path .. \".tmp\", path .. \".bak\"", "offline marker temp/backup")
local atomicWrite = block(template, "local function atomicWrite", "local function readConfigRole", "offline atomic writer")
requireOrdered(atomicWrite, {
  "local wrote, writeError = writeFile(temp, text)",
  "local hadCurrent = fs.exists(path)",
  "local moved, moveError = moveChecked(path, backup)",
  "local moved, moveError = moveChecked(temp, path)",
  "if fs.exists(path) then fs.delete(path) end",
  "if hadCurrent and fs.exists(backup) then",
  "return false, \"Atomic replace failed:",
  "if fs.exists(backup) then fs.delete(backup) end",
}, "offline atomic marker failure safety")
requireText(template, "local function markerRead()", "offline marker reader")
requireText(template, "version = version, schema = schema, role = role, state = state, next = nextIndex", "offline marker fields")
requireText(template, "if marker.version ~= VERSION or marker.schema ~= SCHEMA or marker.role ~= ROLE then", "offline marker version/role validation")
requireText(template, "marker.state ~= \"ready\" and marker.state ~= \"committing\" and marker.state ~= \"final-ready\"", "offline marker phase/state validation")
requireText(template, "local function clearMarker()", "offline marker cleanup helper")
requireText(template, "for _, suffix in ipairs({ \"\", \".tmp\", \".bak\" }) do", "offline marker cleanup paths")
requireText(template, "local function lowSpaceFailure(message)", "offline low-space failure path")
requireText(template, "LOW-SPACE UPDATE PAUSED", "offline marker failure safety message")

print("V4 online/offline low-space marker, sentinel, resume and rollback contracts passed")
