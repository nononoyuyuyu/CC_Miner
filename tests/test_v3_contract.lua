-- Worker/controller are interactive CC:Tweaked programs, so their private
-- locals cannot be exercised without booting a turtle/monitor/rednet stack.
-- Keep only small V4 source-contract assertions for safety-critical branches.

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

local worker = parts("src/ccminer/worker_parts", 5)
local controller = parts("src/ccminer/controller_parts", 3)
local quarry = read("src/ccminer/lib/quarry.lua")

local function marker(text, expected, label)
  assert(text:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

-- Profile math is intentionally explicit and mirrored by the controller's
-- profileParameters helper.
marker(worker, 'if profile == "safe" then return math.min(8, base + 2) end', "safe reserve slots")
marker(worker, 'if profile == "turbo" then return math.max(1, base - 1) end', "turbo reserve slots")
marker(worker, 'if profile == "safe" then return math.min(requested, 8) end', "safe lighting interval")
marker(worker, 'if profile == "turbo" then return math.min(12, math.max(requested, 12)) end', "turbo lighting interval")
marker(controller, 'local function profileParameters(profile, lighting)', "controller profile parameters")
marker(controller, 'if name ~= "safe" and name ~= "balanced" and name ~= "turbo" then return nil', "profile validation")

-- V4 group assignments are explicit and fail closed: metadata without a
-- non-empty authoritative assignment never falls back to a full footprint.
marker(worker, "local assignmentChunks = payload.assignmentChunks", "group assignment extraction")
marker(worker, 'local assignmentPlanRequested = type(assignmentChunks) == "table" and assignmentListCount(assignmentChunks) > 0', "group assignment count guard")
marker(worker, 'if (job.groupJobId or job.assignmentId or assignment ~= nil) and not assignmentPlanRequested then', "group assignment refusal guard")
marker(worker, "Group assignment keys are required; refusing full-footprint fallback.", "group assignment rejection")
marker(controller, 'if conflict then return nil, "Active lease overlap with " .. tostring(conflict.jobId or conflict.assignmentId)', "controller overlap rejection")

-- V4 discard, bounded routes, and unique world-group bays remain explicit
-- source contracts even though the executable code is split into parts.
marker(worker, "local function discardPolicy()", "discard policy")
marker(worker, "local function navigateServiceRoute(plan, fromPose, toPose, context, mode)", "bounded service route")
marker(worker, "No safe chunk service route.", "route refusal")
marker(controller, "bay chunk unique:", "unique bay guard")
marker(quarry, "duplicate_worker_bay_chunk:", "duplicate bay rejection")

-- World depth is derived from calibrated home Y and targetY, while chunk-grid
-- selection is whole-chunk only (partial masks are a fatal preflight item).
marker(controller, 'local targetY = calibration and calibration.home and tonumber(calibration.home.y) and (tonumber(calibration.home.y) - depth + 1) or nil', "targetY formula")
marker(worker, 'local derivedDepth = homeY - targetY + 1', "worker targetY validation")
marker(controller, 'partial cell mask cannot be sent; select whole chunks', "chunk-grid semantics")
marker(controller, 'local chunkMode = calibration and "world" or "local"', "chunk mode selection")

-- Queue dispatch waits for an ACK and keeps an awaiting/retry record until it
-- receives one; alerts use the configured redstone side and cooldown ledger.
marker(controller, 'elseif message.kind == "ack" then', "queue ACK handler")
marker(controller, 'acknowledgeQueuedStart(id, payload)', "queue ACK acknowledgement")
marker(controller, 'local settings = config.alerts or {}', "alert configuration")
marker(controller, 'local side = tostring(settings.redstoneSide or "back")', "alert redstone side")

-- Torch placement records a pending physical action, carves a safe niche when
-- needed, and reports an unavailable surface rather than placing blindly.
marker(worker, 'dig_torch_niche_forward', "torch niche action")
marker(worker, 'torch_niche_forward', "torch niche placement")
marker(worker, 'torch_surface_unavailable', "torch surface failure")
marker(worker, 'state.pendingAction = {', "pending physical action")

-- Reserved seal/torch/fuel slot sets must remain disjoint during unloading and
-- refill passes.
marker(worker, 'seal = slotSet(materials.sealSlots or config.sealSlots)', "reserved seal slots")
marker(worker, 'torch = slotSet(materials.torchSlots or config.torchSlots)', "reserved torch slots")
marker(worker, 'if role == "seal" then return sets.torch[number] or sets.fuel[number] end', "seal slot exclusion")
marker(worker, 'if role == "torch" then return sets.seal[number] or sets.fuel[number] end', "torch slot exclusion")

print("worker/controller V4 source contracts passed")
