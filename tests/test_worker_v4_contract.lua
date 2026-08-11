-- CC Miner V4 worker contracts.
--
-- The worker is an interactive CC:Tweaked program and keeps its helpers in
-- private locals, so this test deliberately combines source contracts with a
-- very small, host-side quarry planner exercise.  It must not boot a turtle,
-- open a modem, or mutate a state file.

local root = assert(arg and arg[1], "repository root is required")

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

local worker = parts("src/ccminer/worker_parts", 5)
local quarrySource = read("src/ccminer/lib/quarry.lua")

local function marker(text, expected, label)
  assert(text:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

local function ordered(text, first, second, label)
  local firstAt = text:find(first, 1, true)
  local secondAt = text:find(second, 1, true)
  assert(firstAt and secondAt and firstAt < secondAt,
    "invalid order in " .. label .. ": " .. first .. " -> " .. second)
end

local function section(text, startNeedle, endNeedle, label)
  local startAt = assert(text:find(startNeedle, 1, true), "missing " .. label .. " start")
  local endAt = assert(text:find(endNeedle, startAt + #startNeedle, true), "missing " .. label .. " end")
  return text:sub(startAt, endAt - 1)
end

-- A group/assignment payload is not allowed to silently become a full local
-- footprint.  In particular, metadata with an empty assignmentChunks list is
-- a refusal, not a legacy single-worker fallback.
marker(worker, "local assignmentChunks = payload.assignmentChunks", "assignment chunk extraction")
marker(worker, "or (assignment and (assignment.chunkKeys or assignment.chunks or assignment.assignmentChunks))", "nested assignment chunk extraction")
marker(worker, "local assignmentPlanRequested = type(assignmentChunks) == \"table\" and assignmentListCount(assignmentChunks) > 0", "non-empty assignment gate")
marker(worker, "if (job.groupJobId or job.assignmentId or assignment ~= nil) and not assignmentPlanRequested then", "group metadata fail-closed gate")
marker(worker, "Group assignment keys are required; refusing full-footprint fallback.", "full-footprint fallback refusal")
marker(worker, "if assignmentPlanRequested and type(assignmentCatalog) ~= \"table\" then", "authoritative catalog requirement")
marker(worker, "Group assignment requires the authoritative chunk catalog.", "catalog refusal")
marker(worker, "if assignmentPlanRequested and requestedChunkMode ~= \"world\" then", "world assignment mode gate")
marker(worker, "Explicit group assignments require chunkMode=world.", "local assignment refusal")

local function assignmentMetadataAccepted(value)
  local chunks = value and value.assignmentChunks
  local count = 0
  if type(chunks) == "table" then
    if #chunks > 0 then
      count = #chunks
    else
      for _, enabled in pairs(chunks) do if enabled then count = count + 1 end end
    end
  end
  return not (value and (value.groupJobId or value.assignmentId or value.assignment)) or count > 0
end

assert(not assignmentMetadataAccepted({ groupJobId = "group-empty", assignmentChunks = {} }),
  "empty group assignment metadata must fail closed")
assert(not assignmentMetadataAccepted({ assignmentId = "assignment-empty", assignmentChunks = { W = false } }),
  "false-only assignment map must fail closed")
assert(assignmentMetadataAccepted({ groupJobId = "group-one", assignmentChunks = { "W:0:0" } }),
  "non-empty assignment metadata should be accepted by the gate")

-- The worker calls the assigned planner with one canonical (catalog, keys,
-- options) signature.  Keep this assertion close to the implementation so a
-- compatibility retry cannot reinterpret a catalog as a normal job.
marker(quarrySource, "function M.buildAssignedChunkPlan(catalog, assignedKeys, options)", "assigned planner canonical signature")
marker(worker, "pcall(quarry.buildAssignedChunkPlan,\n        assignmentCatalog, assignmentChunks, assignmentOptions)", "worker assigned planner canonical call")
marker(worker, "assignmentOptions = {", "assigned planner options")
for _, field in ipairs({
  "transitKeys = job.assignmentTransitChunks or {}",
  "seedKey = payload.seedKey or assignment.seedKey or job.seedKey",
  "rootKey = assignmentCatalog.rootKey",
  "dockKey = payload.dockKey or assignment.dockKey or assignmentCatalog.dockKey",
  "workerId = payload.workerId or assignment.workerId",
  "groupJobId = job.groupJobId",
  "referenceCalibration = assignmentCatalog.calibrationSeed",
  "workerCalibration = gpsCalibration()",
}) do
  marker(worker, field, "assigned planner option " .. field:match("^([^ =]+)"))
end
marker(worker, "if not ok or type(assignedPlan) ~= \"table\" or type(assignedPlan.chunks) ~= \"table\" then", "assigned planner result validation")
marker(worker, "Group assignment selects no mineable chunks.", "empty assigned plan refusal")

-- Exercise the planner with a tiny world catalog.  This is a pure Lua mock of
-- the controller hand-off: no CC globals or turtle APIs are involved.
local quarry = dofile(root .. "/src/ccminer/lib/quarry.lua")
local calibration = {
  home = { x = 0, y = 64, z = 0 },
  forward = { x = 0, z = 1 },
}
local catalog, catalogError = quarry.buildCatalog(32, 32, "world", calibration)
assert(catalog, catalogError)
local rootKey = quarry.chunkKey("world", 0, 0)
local plannerOptions = {
  rootKey = rootKey,
  dockKey = rootKey,
  seedKey = rootKey,
  referenceCalibration = calibration,
  workerCalibration = calibration,
  workerId = 7,
  groupJobId = "group-contract",
  bottomY = 0,
  y = 0,
}
local assignedPlan, assignedPlanError = quarry.buildAssignedChunkPlan(catalog, { rootKey }, plannerOptions)
assert(assignedPlan, assignedPlanError)
assert(assignedPlan.rootKey == rootKey and assignedPlan.dockKey == rootKey and assignedPlan.seedKey == rootKey,
  "assigned planner must preserve dock/root/seed metadata")
assert(assignedPlan.serviceRoute and #assignedPlan.serviceRoute.chunkKeys >= 1,
  "assigned planner must emit a service route")
assert(assignedPlan.assignedKeys and assignedPlan.assignedKeys[1] == rootKey,
  "assigned planner must emit the canonical assigned key list")
local rejectedPlan, rejectedError = quarry.buildAssignedChunkPlan(catalog, { "W:99:99" }, plannerOptions)
assert(not rejectedPlan and tostring(rejectedError):find("unknown_assigned_chunk", 1, true),
  "unknown assigned chunks must be rejected instead of expanding the plan")

-- Initial chunk-plan movement is a constrained home -> dock -> serviceRoute ->
-- seed bridge.  A checkpoint outside the plan, or a current pose outside the
-- plan, is a hard refusal; direct generic movement is only the no-plan branch.
local chunkWork = section(worker, "local function navigateChunkPlanWork", "local function estimatedReturnDistance", "chunk-plan work route")
marker(chunkWork, "local targetKey = quarry.findChunk(plan, checkpoint.x, checkpoint.z)", "checkpoint chunk lookup")
marker(chunkWork, "if not targetKey then return false, \"Checkpoint is outside every allowed chunk.\" end", "checkpoint outside-plan refusal")
marker(chunkWork, "local fromKey = quarry.findChunk(plan, state.pose.x, state.pose.z)", "current chunk lookup")
marker(chunkWork, "if not plan then return navigateTo(checkpoint, \"work\", context) end", "no-plan-only generic fallback")
marker(chunkWork, "local dock, dockError = serviceDockAnchor(plan, state.pose.y)", "dock bridge anchor")
marker(chunkWork, "local bridged, bridgeError = navigateTo(dock, \"home\", context)", "home-to-dock bridge")
marker(chunkWork, "return navigateServiceRoute(plan, dock, checkpoint, context, \"work\")", "dock-to-checkpoint service route")
marker(chunkWork, "return navigateServiceRoute(plan, state.pose, checkpoint, context, \"work\")", "in-plan service route")
ordered(chunkWork, "local targetKey = quarry.findChunk(plan, checkpoint.x, checkpoint.z)", "local fromKey = quarry.findChunk(plan, state.pose.x, state.pose.z)", "checkpoint route validation")
ordered(chunkWork, "local bridged, bridgeError = navigateTo(dock, \"home\", context)", "return navigateServiceRoute(plan, dock, checkpoint, context, \"work\")", "home bridge before route")
local planGuardAt = assert(chunkWork:find("if not plan then return navigateTo(checkpoint, \"work\", context) end", 1, true))
local targetLookupAt = assert(chunkWork:find("local targetKey = quarry.findChunk(plan, checkpoint.x, checkpoint.z)", 1, true))
assert(planGuardAt < targetLookupAt, "generic checkpoint movement must be guarded by the no-plan branch")
local plannedTail = chunkWork:sub(targetLookupAt)
assert(not plannedTail:find("return navigateTo(checkpoint, \"work\", context)", 1, true),
  "chunk plans must not use a direct generic checkpoint fallback")
marker(worker, "if not currentKey then return false, \"Current position is outside every allowed chunk.\" end", "return outside-plan refusal")
marker(worker, "state.routeMetrics.lastRoute = { kind = routeKind or \"fallback\", chunkKeys = common.copy(keys) }", "bounded route audit")
marker(worker, "No safe chunk service route.", "service route hard refusal")
marker(quarrySource, "serviceRoute = {", "assigned service route persistence")
marker(quarrySource, "serviceRoute = M.shortestServiceRoute(servicePlan,", "planner service route construction")

-- Returns and resumes use the durable checkpoint/route cursor, never a
-- computed far end of the assignment.
local service = section(worker, "local function continueService()", "local function requiredDirectionTo", "service continuation")
marker(service, "if state.service.resumeAfter and (state.resumeToken or state.checkpoint) then", "checkpoint resume guard")
marker(service, "local token = state.resumeToken or state.checkpoint", "checkpoint token selection")
marker(service, "local checkpoint = poseCopy(token)", "checkpoint pose copy")
marker(service, "navigateChunkPlanWork(checkpoint, \"service\")", "chunk checkpoint resume")
marker(service, "navigateTo(checkpoint, \"work\", \"service\")", "serpentine checkpoint resume")
marker(service, "turnTo(checkpoint.dir)", "checkpoint direction restore")
marker(service, "if token[key] ~= nil then state.job.route[key] = token[key] end", "checkpoint route cursor restore")
marker(worker, "if not isHome() and not state.checkpoint then installCheckpointToken(checkpointToken()) end", "checkpoint capture before service")
marker(worker, "if state.job and state.job.strategy == \"chunk_plan\" then\n      ok, err = navigateChunkPlanHome(\"service\")", "chunk-plan return route")

-- Assignment resume tokens carry identity, integer world pose, direction, and
-- the complete chunk-route cursor.  The token is intentionally validated
-- against the active assignment before it can move a turtle.
local snapshot = section(worker, "assignmentResumeSnapshot = function", "local function validateAssignmentResumeToken", "assignment resume snapshot")
for _, field in ipairs({
  "schema = common.SCHEMA",
  "jobId = tostring(job.id)",
  "workerId = tonumber(os.getComputerID and os.getComputerID() or nil) or config.workerId",
  "groupJobId = tostring(job.groupJobId)",
  "assignmentId = tostring(job.assignmentId)",
  "route = {",
  "layer = tonumber(route.layer) or 0",
  "walkIndex = tonumber(route.walkIndex) or 1",
  "localCursor = tonumber(route.localCursor) or 0",
  "phase = route.phase or \"travel\"",
  "currentKey = route.currentKey",
  "worldPose = worldPose",
}) do marker(snapshot, field, "resume snapshot " .. field:match("^([^ =]+)")) end

local validateToken = section(worker, "local function validateAssignmentResumeToken", "local function validateJob", "assignment resume validation")
for _, field in ipairs({
  "value.jobId",
  "value.groupJobId",
  "value.assignmentId",
  "value.workerId",
  "worldPose must be integral",
  "worldPose.dir is required",
  "worldPose.dir is invalid",
  "route is required",
  "layer is invalid",
  "walkIndex is invalid",
  "localCursor is invalid",
  "currentKey is outside the assignment",
  "cursor is invalid",
  "phase is invalid",
  "worldPose is outside current assignment chunk",
  "worldPose layer does not match route",
}) do marker(validateToken, field, "resume token validation " .. field) end
marker(validateToken, "group/assignment identity mismatch", "group and assignment identity check")
marker(validateToken, "assignmentResumeToken requires GPS calibration.", "resume GPS requirement")
marker(validateToken, "math.floor(tonumber(world.x))", "integer world coordinate normalization")

-- Status and reports expose stable progress/assignment shapes, including the
-- route token while active and the terminal report after service completion.
local status = section(worker, "local function statusPayload()", "local function sendStatus", "status payload")
for _, field in ipairs({
  "assignmentResumeToken = assignmentResume",
  "progress = progress",
  "job = jobSnapshot()",
  "report = state.report and common.copy(state.report) or nil",
  "returnRoute = returnSnapshot()",
  "capabilities = {",
}) do marker(status, field, "status shape " .. field:match("^([^ =]+)")) end
local finish = section(worker, "local function finishService()", "local function continueService", "service completion")
local completeBranch = section(finish, "if finalStatus == \"complete\" then", "elseif finalStatus == \"aborted\" then", "complete report")
for _, field in ipairs({
  "state.checkpoint = nil",
  "state.resumeToken = nil",
  "state.assignmentResumeToken = nil",
  "state.status, state.phase = \"complete\", \"home\"",
  "state.report = {",
  "jobId = state.job and state.job.id or nil",
  "groupJobId = state.job and state.job.groupJobId or nil",
  "reason = state.completionReason",
  "progress = state.job and { cursor = state.job.cursor or 0, total = state.job.total or 0 } or nil",
  "stats = common.copy(state.stats)",
  "materials = {",
  "discard = common.copy(state.discardStats or state.discard or {})",
  "throughput = throughputSnapshot()",
  "assignmentResumeToken = nil",
}) do marker(completeBranch, field, "complete report " .. field:match("^([^ =]+)")) end
local abortBranch = section(finish, "elseif finalStatus == \"aborted\" then", "elseif finalStatus == \"paused\" then", "abort report")
marker(abortBranch, "state.status, state.phase = \"aborted\", \"home\"", "abort terminal state")
marker(abortBranch, "assignmentResumeToken = state.assignmentResumeToken and common.copy(state.assignmentResumeToken)", "abort token retention")
marker(abortBranch, "or assignmentResumeSnapshot(state.resumeToken or state.checkpoint)", "abort token snapshot")
marker(abortBranch, "aborted = true", "abort report flag")

-- Discard is opt-in and conservative.  Unknown/valuable/protected items stay
-- on the output path; custom mode only admits exact item IDs, and stone mode
-- never splits a stack below the seal reserve.
marker(worker, "discardMode = tostring(discardMode or \"KEEP_ALL\"):upper()", "discard default mode")
marker(worker, "if discardMode ~= \"KEEP_ALL\" and discardMode ~= \"DISCARD_EXCESS_STONE\" and discardMode ~= \"CUSTOM_ALLOWLIST\" then", "discard mode enum")
marker(worker, "discardMode = \"KEEP_ALL\"", "invalid discard mode fail-closed")
local discardCandidate = section(worker, "local function discardCandidate", "local function discardStatsTable", "discard candidate policy")
marker(discardCandidate, "if mode == \"KEEP_ALL\" then return false end", "KEEP_ALL candidate refusal")
marker(discardCandidate, "if mode == \"CUSTOM_ALLOWLIST\" then", "custom allowlist mode")
marker(discardCandidate, "return explicitAllowlisted(name, policy)", "exact custom allowlist check")
marker(discardCandidate, "if isSealItemName(name) or isTorchItemName(name) or isFuelItem(slot)", "custom hard protected material check")
marker(discardCandidate, "or isOreOrRawMaterial(name) then return false end", "custom ore/raw protection")
marker(discardCandidate, "if discardProtectedItem(slot, name) then return false end", "stone hard protected check")
marker(worker, "local function isUnknownModItem(name)", "unknown mod item classifier")
marker(worker, "if isOreOrRawMaterial(name) or isUnknownModItem(name) then return true end", "unknown/valuable hard protection")
marker(discardCandidate, "Unknown mod items are discardable only", "custom unknown exact-name semantics")
marker(discardCandidate, "when their exact name is explicitly allowlisted.", "custom unknown exact-name semantics")
marker(discardCandidate, "if mode == \"DISCARD_EXCESS_STONE\" then", "excess stone mode")
marker(discardCandidate, "stoneAllowlist", "stone exact allowlist")
marker(discardCandidate, "local keep = math.max(1, tonumber(config.discard and config.discard.retainSealTarget) or 64)", "seal reserve target")
marker(discardCandidate, "return totalSeal > keep", "seal reserve gate")
marker(worker, "if candidate and isSealItemName(name) and totalSeal - count < (tonumber(policy.retainSealTarget) or 64) then", "home whole-stack seal guard")
marker(worker, "if candidate and discardDrop then", "home discard candidate path")
marker(worker, "local dropped = discardDrop() -- no count argument: one complete stack", "home whole-stack drop")
marker(worker, "if dropped and after == 0 then", "home stack emptied check")
marker(worker, "if count > 0 and discardCandidate(slot, name, totalSeal, policy, mode)", "field candidate path")
marker(worker, "and not (isSealItemName(name) and totalSeal - count < (tonumber(policy.retainSealTarget) or 64)) then", "field whole-stack seal guard")

-- Field discard must detect an inventory before dropping; only a confirmed
-- non-inventory side may receive a complete stack, and the action is journaled
-- before the world mutation.
local fieldDiscard = section(worker, "local function discardAtField()", "local function targetFuelForService", "field discard")
marker(fieldDiscard, "if mode == \"KEEP_ALL\" then return true end", "field KEEP_ALL no-op")
marker(worker, "local function inventoryPresent(side, inspectFunction)", "inventory presence helper")
marker(fieldDiscard, "if inventoryPresent(checkSide, inspectFunction) then", "field inventory skip")
marker(fieldDiscard, "Field discard skipped because the configured direction contains an inventory.", "field inventory skip reason")
marker(fieldDiscard, "saveState(\"field_discard_inventory\")", "field skip checkpoint")
marker(fieldDiscard, "beginPhysicalAction(\"discard_field\"", "field discard pending action")
marker(fieldDiscard, "local dropped = dropFunction() -- world discard is always stack-at-a-time", "field whole-stack world drop")
marker(fieldDiscard, "local after = turtle.getItemCount(slot)", "field post-drop inventory check")
marker(fieldDiscard, "commitPhysicalAction()", "field discard commit")
marker(fieldDiscard, "noteDiscardSkip(name, isUnknownModItem(name))", "field failed-drop retention")

local unload = section(worker, "local function unloadAtHome()", "local function discardAtField", "home unload")
marker(unload, "if not inventoryPresent(outCheck, outInspect) then", "home output inventory check")
marker(unload, 'Output inventory missing on configured side " .. outputSide .. ".', "home output missing refusal")
marker(unload, "if discardEnabled and discardSide ~= outputSide then", "home discard side selection")
marker(unload, "if discardReady and not inventoryPresent(checkSide, discardInspect) then", "home discard inventory check")
marker(unload, "Discard inventory missing on configured side", "home discard missing refusal")
marker(unload, "if discardEnabled and not discardReady then", "home discard blocking gate")
marker(unload, "return false, discardStats.lastError", "home discard block result")

-- A power loss during any inventory transfer is ambiguous.  Recovery keeps
-- the pending action and stops for explicit/manual revalidation, including
-- field/home discard and all refill/refuel phases.
local recovery = section(worker, "local function resolveNonMovementPending", "local function tryResolvePendingAction", "pending inventory recovery")
marker(recovery, "common.startsWith(kind, \"discard_\")", "pending discard recovery")
marker(recovery, "common.startsWith(kind, \"refill_\")", "pending refill recovery")
marker(recovery, "common.startsWith(kind, \"refuel_\")", "pending refuel recovery")
marker(recovery, "return false, \"Pending inventory transfer requires manual revalidation before continuing.\"", "manual inventory recovery stop")
marker(worker, "state.pendingAction = common.copy(pending.pendingAction)", "pending action state contract")
marker(worker, "state.pendingAction ~= nil", "pending action recovery boundary")

-- Lightweight pending snapshots and full atomic checkpoints have independent
-- cadence/force rules.  GPS is checked periodically and at layer/service
-- boundaries so a stale cursor cannot silently continue after drift.
for _, field in ipairs({
  "lightweightCheckpointEveryMoves",
  "checkpointEveryMoves",
  "local function lightweightWriteDue(reason)",
  "if moves - lastMove >= every then return true end",
  "local function saveJournalCheckpoint()",
  "if writes == 0 or writes % every ~= 0 then return true end",
  "local function stateSaveNeedsFull(reason, explicit)",
  "if (tonumber(state.stats and state.stats.moves) or 0) - lastMove >= moveEvery then return true end",
  "local writeLightweight = full or lightweightWriteDue(reason)",
  "if full then saveJournalCheckpoint() end",
}) do marker(worker, field, "checkpoint cadence " .. field) end
marker(worker, "local interval = math.max(1, tonumber(", "GPS verification interval")
marker(worker, "if not force and ((state.stats.moves or 0) % interval ~= 0) then return true end", "periodic GPS boundary")
marker(worker, "local gpsOK, gpsError = verifyGPS(false)", "move GPS boundary")
marker(worker, "local layerGPS, layerGPSError = verifyGPS(true)", "layer GPS boundary")
marker(worker, "local preReturnGPS, preReturnError = verifyGPS(true)", "return GPS boundary")
marker(worker, "local arrivedGPS, arrivedGPSError = verifyGPS(true)", "resume GPS boundary")

-- ACKs echo only sanitized command/group/assignment identities, while status
-- advertises the worker capabilities required by world-group dispatch.
local ack = section(worker, "local function sendAck", "local function markBlocked", "ACK payload")
for _, field in ipairs({
  "command = payload.command and tostring(payload.command) or nil",
  "groupJobId = payload.groupJobId and tostring(payload.groupJobId) or nil",
  "assignmentId = payload.assignmentId and tostring(payload.assignmentId) or nil",
  "groupId = payload.groupId and tostring(payload.groupId) or nil",
  "status = statusPayload()",
}) do marker(ack, field, "ACK field " .. field:match("^([^ =]+)")) end
for _, field in ipairs({ "worldPartition = true", "groupAssignment = true" }) do
  marker(status, field, "capability " .. field:match("^([^ =]+)"))
end

print("worker V4 source contracts and assigned-plan mock passed")
