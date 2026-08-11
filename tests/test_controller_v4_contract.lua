-- CC Miner V4 controller contracts.
--
-- The controller is an interactive ComputerCraft program, so this test keeps
-- the executable boundary out of the host test process.  It checks the source
-- contract for the safety-critical group scheduler and uses a small
-- textutils.serialize reference checker for durable DB examples.

local root = arg[1]

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function parts(directory, count)
  local out = {}
  for index = 1, count do
    out[#out + 1] = read(directory .. "/" .. ("%02d"):format(index) .. ".part")
  end
  return table.concat(out, "\n")
end

local controller = parts("src/ccminer/controller_parts", 3)
local worker = parts("src/ccminer/worker_parts", 5)
local quarry = read("src/ccminer/lib/quarry.lua")

local function marker(text, expected, label)
  assert(text:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

-- Durable V4 state has separate registries for groups, docks, bays, jobs and
-- leases.  `activeLeases` remains a detached compatibility snapshot only.
for _, item in ipairs({
  { "groups = {},", "DB groups registry" },
  { "docks = {},", "DB docks registry" },
  { "bays = {},", "DB bays registry" },
  { "groupJobs = {},", "DB group jobs registry" },
  { "groupLeases = {},", "DB group leases registry" },
  { "local function persistentGroupValue(source)", "group persistence copier" },
  { "local persistedGroups, persistedDocks, persistedBays, persistedJobs, persistedGroupLeases = {}, {}, {}, {}, {}", "detached group DB roots" },
  { "persistedDb.groups, persistedDb.docks, persistedDb.bays = persistedGroups, persistedDocks, persistedBays", "detached group/dock/bay save" },
  { "persistedDb.groupJobs, persistedDb.groupLeases = persistedJobs, persistedGroupLeases", "detached group job/lease save" },
  { "db.activeLeases = common.copy(db.leases or {})", "detached active lease snapshot" },
  { "persistedDb.activeLeases = common.copy(db.leases or {})", "detached persisted lease snapshot" },
}) do
  marker(controller, item[1], item[2])
end

-- Resource registration normalizes integer world coordinates, facing and depth;
-- group registration validates worker limits, mode/partition and per-worker
-- bay/dock maps before writing durable records.
for _, item in ipairs({
  { "local function normalizeFacingValue(value)", "facing normalization" },
  { "world_coordinates_must_be_integers", "integer world coordinate validation" },
  { "local function registerDock(dockId, value)", "dock registration" },
  { "local function registerBay(bayId, value)", "bay registration" },
  { "local function registerGroup(groupId, workerIds, options)", "group registration" },
  { "if value.maxDepth ~= nil then", "maxDepth registration" },
  { "local maxWorkers = tonumber(config.group and config.group.maxWorkers)", "group maxWorkers" },
  { "group_max_workers_exceeded:", "group maxWorkers rejection" },
  { "if mode ~= \"world\" and mode ~= \"local\" then", "group mode enum" },
  { "if partition ~= \"stripe\" and partition ~= \"round_robin\" then", "group partition enum" },
  { "options.workerBays or previous.workerBays", "worker bay map" },
  { "options.workerDocks or previous.workerDocks", "worker dock map" },
  { "db.docks[dockId] = persistentGroupValue(value)", "durable dock write" },
  { "db.bays[bayId] = persistentGroupValue(value)", "durable bay write" },
  { "db.groups[groupId] = persistentGroupValue(group)", "durable group write" },
}) do
  marker(controller, item[1], item[2])
end

-- Group-job drafts expose BOTTOM Y (world mode), depth (local mode), profile,
-- water, lighting and partition controls.  PRECHECK persists the exact checks
-- used by START, so a restart cannot silently change the plan.
for _, item in ipairs({
  { 'fieldLabels = { width = "WIDTH", length = "LENGTH", depth = "DEPTH", targetY = "BOTTOM Y" }', "BOTTOM Y touch field" },
  { "local function groupDraftWorldMode()", "group draft mode" },
  { "local function groupFieldOrder()", "group draft fields" },
  { "groupDraft.preflight = computeGroupPreflight(gid, groupDraft)", "group PRECHECK" },
  { "if checked and not checked.fatal then startGroup(gid, groupDraft) end", "group START after PRECHECK" },
  { "{ \"LIGHT \" .. tostring(groupDraft.lighting", "group lighting control" },
  { "{ \"WATER \" .. tostring(groupDraft.waterMode", "group water control" },
  { "{ \"PROFILE \" .. tostring(groupDraft.profile", "group profile control" },
  { "{ \"PART \" .. tostring(groupDraft.partition", "group partition control" },
  { "local function computeGroupPreflight(groupId, value)", "group preflight" },
  { "preflight = { checks = common.copy(result.checks), bottomY = result.bottomY, partition = result.partition }", "durable group preflight" },
  { "profile = value.profile, waterMode = value.waterMode, lighting = common.copy(value.lighting or {}), partition = result.partition", "group job touch fields" },
  { "local function startGroup(groupId, value)", "group start" },
}) do
  marker(controller, item[1], item[2])
end

-- World preflight is deliberately explicit.  Every worker must advertise group
-- capability, calibrated GPS home/forward pose, common floor/orientation and a
-- unique bay chunk inside the catalog; the assigned partition must own that
-- bay seed and any transit chunks must be a subset of its mine assignment.
for _, item in ipairs({
  { "world group capability must be explicitly supported", "explicit group capability" },
  { "calibration with home/forward coordinates required", "GPS home/forward requirement" },
  { "check(\"home:#\" .. tostring(id), \"bad\", \"worker is not at home\", true)", "world home preflight" },
  { "GPS orientation:", "common GPS orientation" },
  { "GPS floor:", "common GPS floor" },
  { "worker bay entrance is outside common world footprint", "bay catalog membership" },
  { "cannot rebase worker forward entrance to common catalog", "forward catalog membership" },
  { "catalogWorldSet[tostring(chunk.key)] = true", "world catalog membership set" },
  { "worker home and forward entrance must share one bay chunk", "home/forward bay chunk" },
  { "bay chunk unique:", "unique bay chunk" },
  { "registered bay HOME Y differs", "registered bay floor" },
  { "registered bay orientation differs", "registered bay orientation" },
  { "assignment does not own worker bay chunk", "assignment bay ownership" },
  { "assignment seed is not worker bay chunk", "assignment bay seed" },
  { "transit chunk leaves worker assignment", "transit subset" },
  { "local_group_partition_disabled", "local multi-worker rejection" },
  { "local jobs cannot be auto-split", "local split safety" },
  { "local_group_partition", "local partition preflight" },
  { "local_group_partition", "local partition check" },
}) do
  marker(controller, item[1], item[2])
end

-- Mine and transit are independent lease kinds, but both are checked against
-- existing group/legacy leases before START and persisted as separate entries.
for _, item in ipairs({
  { "local function groupLeaseConflict(mode, workerId, keys, kind, groupJobId)", "cross-kind lease conflict helper" },
  { "local mineConflict = groupLeaseConflict(chunkMode, nil, selectedKeys, \"mine\", groupId)", "mine lease overlap" },
  { "local transitConflict = groupLeaseConflict(chunkMode, nil, transitKeys, \"transit\", groupId)", "transit lease overlap" },
  { "for _, kind in ipairs({ \"transit\", \"mine\" }) do", "separate mine/transit lease entries" },
  { "kind = kind, mode = job.chunkMode", "lease kind/mode payload" },
}) do
  marker(controller, item[1], item[2])
end

-- Group START dispatches one assignment at a time and waits for the worker's
-- explicit ACK/status.  Timeout/rejection enters PARTIAL_START, safely returns
-- accepted workers and releases only leases for assignments never started.
for _, item in ipairs({
  { "for _ in pairs(job.awaitingAck) do return true end", "sequential ACK gate" },
  { "job.awaitingAck[key] = { sentAt = now, attempts =", "START ACK ledger" },
  { "acceptGroupStart = function(groupJob, workerId, assignmentId)", "START ACK acceptor" },
  { "elseif message.kind == \"ack\" then", "ACK message handler" },
  { "if now - tonumber(waiting.sentAt or now) >= 10 then", "START ACK timeout" },
  { "rejectGroupStart(job, waitingKey, \"start ACK timeout\")", "timeout rejection" },
  { "job.status = \"PARTIAL_START\"", "partial start status" },
  { "for startedKey in pairs(groupJob.started or {}) do groupSafeStop(groupJob, startedKey, \"start_rejected\") end", "safe stop after rejection" },
  { "releaseGroupLeases(job, true)", "pending lease release" },
  { "groupSafeStop(job, startedKey, \"partial_start\")", "safe stop after send failure" },
  { "job.alerts[#job.alerts + 1] = \"PARTIAL_START\"", "partial start alert" },
}) do
  marker(controller, item[1], item[2])
end

-- ABORT/CLEAR are terminal-at-home operations.  CLEAR cannot be sent while a
-- worker is active or away from its registered home; finalization releases
-- leases and records a terminal group history row.
for _, item in ipairs({
  { "local function groupWorkersTerminalAtHome(groupJob, requireAll)", "terminal/home gate" },
  { "if data.atHome ~= true then return false end", "home requirement" },
  { "if command == \"clear\" and groupJob and not groupWorkersTerminalAtHome(groupJob, true) then", "clear terminal gate" },
  { "groupJob.status = command == \"clear\" and \"clear_requested\" or \"aborting\"", "abort/clear state" },
  { "if (groupJob.status == \"aborting\" or groupJob.status == \"clear_requested\" or groupJob.status == \"PARTIAL_START\") and groupWorkersTerminalAtHome(groupJob) then", "terminal finalization" },
  { "groupJob.status = clear and \"cleared\" or \"aborted\"", "terminal status" },
  { "releaseGroupLeases(groupJob)", "terminal lease release" },
  { "groupCommand = \"RETURN\"", "group return command" },
}) do
  marker(controller, item[1], item[2])
end

-- Reassignment is a durable two-phase handoff.  The source must be terminal,
-- at home, and carry a valid cursor/resume token; the target must be idle (or
-- terminal), calibrated and at its bay.  Leases are rewritten only after a
-- strict assignment/group ACK is observed.
for _, item in ipairs({
  { "local function validateSourceResumeToken(job, source, sourceData, stoppedWorkerId)", "reassignment source validator" },
  { "source_assignment_not_terminal_at_home", "source terminal/home requirement" },
  { "assignment_resume_token_required", "cursor token requirement" },
  { "assignment_resume_token_group_mismatch", "resume token group identity" },
  { "assignment_resume_token_assignment_mismatch", "resume token assignment identity" },
  { "if not ((targetStatus == \"idle\" or targetStatus == \"complete\" or targetStatus == \"aborted\") and targetData.atHome == true) then", "reassignment target state" },
  { "targetData.gps and targetData.gps.calibration", "reassignment GPS requirement" },
  { "job.pendingReassignment = pending", "durable reassignment pending" },
  { "outboundToken.assignmentId = target.assignmentId", "resume token assignment rewrite" },
  { "outboundToken.jobId = target.jobId", "resume token job rewrite" },
  { "finalizePendingReassignment = function(groupJob, workerId, data)", "strict reassignment ACK finalizer" },
  { "acceptedStates = {", "strict reassignment accepted states" },
  { "if assignmentId == nil or tostring(assignmentId) ~= tostring(pending.assignmentId) then return false end", "reassignment ACK assignment match" },
  { "if reportedGroupJobId == nil or tostring(reportedGroupJobId) ~= tostring(groupJob.groupJobId) then return false end", "reassignment ACK group match" },
  { "lease.assignmentId = pending.assignmentId", "post-ACK lease transfer" },
  { "groupJob.pendingReassignment = nil", "reassignment pending clear" },
}) do
  marker(controller, item[1], item[2])
end

local reassignBegin = assert(controller:find("local function reassignGroupAssignment", 1, true), "reassignment function boundary missing")
local schedulerBegin = assert(controller:find("local function groupSchedulerTick", reassignBegin + 1, true), "reassignment function terminator missing")
local reassignBody = controller:sub(reassignBegin, schedulerBegin - 1)
assert(not reassignBody:find("lease.assignmentId = pending.assignmentId", 1, true), "reassignment transfers leases before strict ACK")
assert(not reassignBody:find("lease.workerId = pending.targetWorkerId", 1, true), "reassignment transfers workers before strict ACK")

-- START and reassignment payloads carry an authoritative assignment catalog;
-- workers reject missing catalogs, non-world explicit assignments, and keys
-- outside catalog bounds/calibration.
for _, item in ipairs({
  { "assignmentCatalog = common.copy(job.catalog)", "controller assignment catalog payload" },
  { "assignmentCatalog = payload.assignmentCatalog or payload.catalog or payload.groupCatalog", "worker catalog input" },
  { "assignmentCatalog = state.job.assignmentCatalog and {", "worker status catalog payload" },
  { "chunkCount = state.job.assignmentCatalog.chunks and #state.job.assignmentCatalog.chunks or nil", "catalog bounds/status payload" },
  { "Explicit group assignments require chunkMode=world.", "world assignment mode guard" },
  { "Group assignment requires the authoritative chunk catalog.", "authoritative catalog guard" },
  { "assignmentCatalog.calibrationSeed", "assignment catalog calibration" },
  { "referenceCalibration = assignmentCatalog.calibrationSeed", "worker calibration payload" },
  { "assignmentCatalog.rootKey", "assignment catalog root bounds" },
  { "local transitEmpty = type(transitInput) == \"table\" and next(transitInput) == nil", "empty transit assignment" },
  { "unknown_assigned_chunk:", "mine catalog bounds" },
  { "worker_entrance_chunk_missing", "worker entrance catalog bounds" },
  { "reference_calibration_required", "reference calibration requirement" },
  { "assigned_seed_not_mineable", "assigned seed validation" },
  { "unknown_transit_chunk:", "transit catalog bounds" },
  { "transit_overlaps_assigned:", "mine/transit cross-kind overlap" },
  { "Group assignment selects no mineable chunks.", "empty assignment guard" },
}) do
  marker(controller .. worker .. quarry, item[1], item[2])
end

-- Group aggregates/reporting expose progress, ACKs, fuel and warnings; worker
-- reports/discard metrics are folded into durable history, and RETURN is a
-- first-class group command.
for _, item in ipairs({
  { "local function updateGroupAggregate(groupJob)", "group aggregate" },
  { "aggregate.percent", "aggregate progress" },
  { "aggregate.minFuel", "aggregate minimum fuel" },
  { "aggregate.warnings", "aggregate warnings" },
  { "groupJob.metrics = groupJob.metrics or {}", "group report metrics" },
  { "if report and (report.discard or report.discardStats) then", "discard report" },
  { "groupJob.report = common.copy(groupJob.metrics)", "durable group report" },
  { "metrics = common.copy(groupJob.metrics or groupJob.report or {})", "group history report" },
  { "groupCommand = \"RETURN\"", "return report path" },
}) do
  marker(controller, item[1], item[2])
end

-- CLI exposes group/dock/bay list, show/register, lifecycle and reassignment
-- commands in addition to the touch/keyboard views.
for _, item in ipairs({
  { "if command == \"group\" or command == \"groups\" then", "group CLI" },
  { "if sub == \"show\" then", "group show CLI" },
  { "if sub == \"register\" or sub == \"save\" then", "group register CLI" },
  { "if sub == \"reassign\" then", "group reassign CLI" },
  { "if command == \"dock\" or command == \"bay\" then", "dock/bay CLI" },
  { "local registry = command == \"dock\" and db.docks or db.bays", "dock/bay registry CLI" },
  { "register <id> <x> <y> <z>", "dock/bay register usage" },
}) do
  marker(controller, item[1], item[2])
end

-- Approximate CC:Tweaked textutils.serialize's repeated-reference check.
-- It catches aliases as well as cycles (both are rejected by the real
-- ComputerCraft serializer).
local function ccSerialize(value)
  local seen = {}
  local function visit(item)
    local kind = type(item)
    if kind == "function" or kind == "thread" or kind == "userdata" then
      error("Cannot serialize " .. kind, 0)
    end
    if kind ~= "table" then return end
    if seen[item] then error("Cannot serialize table with recursive entries", 0) end
    seen[item] = true
    for key, nested in pairs(item) do
      visit(key)
      visit(nested)
    end
  end
  visit(value)
  return "{}"
end

local common = dofile(root .. "/src/ccminer/lib/common.lua")
local leases = {
  { groupJobId = "group-1", assignmentId = "group-1:1", workerId = 1, mode = "world", kind = "mine", chunks = { "world:0:0" } },
  { groupJobId = "group-1", assignmentId = "group-1:1", workerId = 1, mode = "world", kind = "transit", chunks = {} },
}
local db = {
  groups = { miners = { id = "miners", workerIds = { 1 }, workerBays = { ["1"] = "bay-1" }, workerDocks = { ["1"] = "dock-1" }, mode = "world", partition = "stripe" } },
  docks = { ["dock-1"] = { id = "dock-1", world = { x = 0, y = 64, z = 0 }, facing = 0, maxDepth = 32 } },
  bays = { ["bay-1"] = { id = "bay-1", world = { x = 0, y = 64, z = 0 }, facing = 0, maxDepth = 32 } },
  groupJobs = { ["group-1"] = { groupJobId = "group-1", groupId = "miners", bottomY = 32, profile = "balanced", waterMode = "seal", lighting = { mode = "safe", interval = 10 }, partition = "stripe", catalog = { mode = "world", rootKey = "world:0:0", chunks = { { key = "world:0:0", cx = 0, cz = 0 } } }, assignments = { ["1"] = { assignmentId = "group-1:1", chunkKeys = { "world:0:0" }, transitKeys = {} } } } },
  leases = common.copy(leases),
  groupLeases = common.copy(leases),
  activeLeases = common.copy(leases),
}
assert(pcall(ccSerialize, db), "V4 group DB tree should be serializable")

-- Demonstrate the failure the detached persistence contract prevents: sharing
-- one group/lease table between DB roots must be rejected.
local shared = { id = "shared", workerIds = { 1 } }
local bad, badError = pcall(ccSerialize, { groups = { shared = shared }, groupJobs = { job = shared } })
assert(not bad and tostring(badError):find("recursive", 1, true), "serializer mock did not reject V4 group alias")

print("controller V4 source contracts and group persistence mock passed")
