local geo = dofile(arg[1] .. "/src/ccminer/lib/geo.lua")

local calibration = {
  home = { x = 100, y = 64, z = -50 },
  forward = { x = 0, z = -1 },
}
assert(geo.validCalibration(calibration))
local world = assert(geo.localToWorld(calibration, { x = 3, y = -4, z = 7 }))
assert(world.x == 103 and world.y == 60 and world.z == -57)
local localPose = assert(geo.worldToLocal(calibration, world, 2))
assert(localPose.x == 3 and localPose.y == -4 and localPose.z == 7 and localPose.dir == 2)

local fix = assert(geo.integerFix(10.01, 63.99, -4.02))
assert(fix.x == 10 and fix.y == 64 and fix.z == -4)
assert(geo.integerFix(10.49, 64, 0) == nil)
assert(geo.integerFix("10", 64, 0) == nil)

local generated = assert(geo.calibrationFromFixes(
  { x = 5, y = 70, z = 5 },
  { x = 6, y = 70, z = 5 }
))
assert(generated.forward.x == 1 and generated.forward.z == 0)
assert(geo.calibrationFromFixes({ x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 0 }) == nil)
assert(not geo.validCalibration({ home = {}, forward = { x = 1, z = 0 } }))
assert(not geo.validCalibration({ home = { x = 0, y = 0, z = 0 }, forward = { x = 1, z = 1 } }))

-- Exercise all four horizontal headings and both movement commands.  The
-- direction numbering is the CC:Tweaked convention: south/east/north/west.
local expected = {
  [0] = { forward = { x = 0, z = 1 }, back = { x = 0, z = -1 } },
  [1] = { forward = { x = 1, z = 0 }, back = { x = -1, z = 0 } },
  [2] = { forward = { x = 0, z = -1 }, back = { x = 0, z = 1 } },
  [3] = { forward = { x = -1, z = 0 }, back = { x = 1, z = 0 } },
}
for direction = 0, 3 do
  local start = { x = 10, y = 20, z = 30, dir = direction }
  local afterForward = geo.poseAfterMove(start, "forward")
  assert(afterForward.x == 10 + expected[direction].forward.x)
  assert(afterForward.y == 20)
  assert(afterForward.z == 30 + expected[direction].forward.z)
  assert(afterForward.dir == direction)
  local afterBack = geo.poseAfterMove(start, "back")
  assert(afterBack.x == 10 + expected[direction].back.x)
  assert(afterBack.y == 20)
  assert(afterBack.z == 30 + expected[direction].back.z)
  assert(afterBack.dir == direction)
end
local elevated = geo.poseAfterMove({ x = 0, y = 0, z = 0, dir = 0 }, "up")
assert(elevated.y == 1 and elevated.x == 0 and elevated.z == 0)
local lowered = geo.poseAfterMove(elevated, "down")
assert(lowered.y == 0)

-- Pending movement can be recovered on either side of the physical action.
local movementPending = {
  kind = "move_forward",
  poseBefore = { x = 0, y = 0, z = 0, dir = 0 },
  poseAfter = { x = 0, y = 0, z = 1, dir = 0 },
}
local beforeWorld = assert(geo.localToWorld(calibration, movementPending.poseBefore))
local afterWorld = assert(geo.localToWorld(calibration, movementPending.poseAfter))
local resolvedBefore = assert(geo.resolvePending(movementPending, beforeWorld, calibration))
local resolvedAfter = assert(geo.resolvePending(movementPending, afterWorld, calibration))
assert(resolvedBefore.outcome == "before" and resolvedBefore.pose.z == 0)
assert(resolvedAfter.outcome == "after" and resolvedAfter.pose.z == 1)
assert(geo.resolvePending(movementPending, { x = 999, y = 64, z = 999 }, calibration) == nil)

-- Stationary actions must not silently accept a changed GPS position.
local stationary = {
  kind = "dig_forward",
  poseBefore = { x = 0, y = 0, z = 0, dir = 0 },
  poseAfter = { x = 0, y = 0, z = 0, dir = 0 },
}
assert(geo.resolvePending(stationary, beforeWorld, calibration).outcome == "before")
local stationaryError, stationaryMessage = geo.resolvePending(stationary, afterWorld, calibration)
assert(stationaryError == nil and tostring(stationaryMessage):find("stationary", 1, true))
local invalidPending, invalidPendingMessage = geo.resolvePending({}, beforeWorld, calibration)
assert(invalidPending == nil and invalidPendingMessage == "invalid_pending")

assert(geo.chunkCoord(-1) == -1)
assert(geo.chunkCoord(-16) == -1)
assert(geo.chunkCoord(-17) == -2)
assert(geo.chunkCoord(15) == 0)
assert(geo.chunkCoord(16) == 1)
local cx, cz = geo.worldChunk({ x = -17, z = -17 })
assert(cx == -2 and cz == -2)
assert(geo.chunkKey(-2, -2) == "-2:-2")

print("GPS V3 transforms, all headings, and pending-action recovery tests passed")
