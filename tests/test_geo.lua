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

local generated = assert(geo.calibrationFromFixes(
  { x = 5, y = 70, z = 5 },
  { x = 6, y = 70, z = 5 }
))
assert(generated.forward.x == 1 and generated.forward.z == 0)
assert(geo.calibrationFromFixes({ x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 0 }) == nil)

local pose = { x = 0, y = 0, z = 0, dir = 1 }
local after = geo.poseAfterMove(pose, "forward")
assert(after.x == 1 and after.z == 0 and after.dir == 1)

local pending = {
  kind = "move_forward",
  poseBefore = { x = 0, y = 0, z = 0, dir = 0 },
  poseAfter = { x = 0, y = 0, z = 1, dir = 0 },
}
local beforeWorld = assert(geo.localToWorld(calibration, pending.poseBefore))
local afterWorld = assert(geo.localToWorld(calibration, pending.poseAfter))
local resolvedBefore = assert(geo.resolvePending(pending, beforeWorld, calibration))
local resolvedAfter = assert(geo.resolvePending(pending, afterWorld, calibration))
assert(resolvedBefore.outcome == "before")
assert(resolvedAfter.outcome == "after")
assert(geo.resolvePending(pending, { x = 999, y = 64, z = 999 }, calibration) == nil)

assert(geo.chunkCoord(-1) == -1)
assert(geo.chunkCoord(-16) == -1)
assert(geo.chunkCoord(-17) == -2)
assert(geo.chunkCoord(15) == 0)
assert(geo.chunkCoord(16) == 1)

print("GPS coordinate and recovery tests passed")
