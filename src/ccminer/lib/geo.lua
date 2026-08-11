-- CC Miner V3 - GPS and coordinate transforms.

local M = {}

local function rounded(value)
  if type(value) ~= "number" then return nil end
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
end

function M.integerFix(x, y, z, tolerance)
  tolerance = tonumber(tolerance) or 0.35
  local rx, ry, rz = rounded(x), rounded(y), rounded(z)
  if not rx or not ry or not rz then return nil, "invalid_fix" end
  if math.abs(x - rx) > tolerance or math.abs(y - ry) > tolerance or math.abs(z - rz) > tolerance then
    return nil, "non_block_fix"
  end
  return { x = rx, y = ry, z = rz }
end

function M.validCalibration(calibration)
  if type(calibration) ~= "table" or type(calibration.home) ~= "table" or type(calibration.forward) ~= "table" then
    return false
  end
  local fx, fz = tonumber(calibration.forward.x), tonumber(calibration.forward.z)
  if not fx or not fz or math.abs(fx) + math.abs(fz) ~= 1 then return false end
  return tonumber(calibration.home.x) ~= nil
    and tonumber(calibration.home.y) ~= nil
    and tonumber(calibration.home.z) ~= nil
end

function M.rightVector(calibration)
  if not M.validCalibration(calibration) then return nil end
  local forward = calibration.forward
  return { x = -forward.z, z = forward.x }
end

function M.localToWorld(calibration, pose)
  if not M.validCalibration(calibration) then return nil, "gps_not_calibrated" end
  pose = pose or {}
  local home, forward = calibration.home, calibration.forward
  local right = M.rightVector(calibration)
  local x, y, z = tonumber(pose.x) or 0, tonumber(pose.y) or 0, tonumber(pose.z) or 0
  return {
    x = home.x + right.x * x + forward.x * z,
    y = home.y + y,
    z = home.z + right.z * x + forward.z * z,
  }
end

function M.worldToLocal(calibration, world, dir)
  if not M.validCalibration(calibration) then return nil, "gps_not_calibrated" end
  world = world or {}
  local wx, wy, wz = tonumber(world.x), tonumber(world.y), tonumber(world.z)
  if not wx or not wy or not wz then return nil, "invalid_world_position" end
  local home, forward = calibration.home, calibration.forward
  local right = M.rightVector(calibration)
  local dx, dz = wx - home.x, wz - home.z
  return {
    x = dx * right.x + dz * right.z,
    y = wy - home.y,
    z = dx * forward.x + dz * forward.z,
    dir = tonumber(dir) or 0,
  }
end

function M.samePosition(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return tonumber(a.x) == tonumber(b.x)
    and tonumber(a.y) == tonumber(b.y)
    and tonumber(a.z) == tonumber(b.z)
end

function M.poseAfterMove(pose, direction)
  pose = {
    x = tonumber(pose and pose.x) or 0,
    y = tonumber(pose and pose.y) or 0,
    z = tonumber(pose and pose.z) or 0,
    dir = (tonumber(pose and pose.dir) or 0) % 4,
  }
  if direction == "up" then pose.y = pose.y + 1
  elseif direction == "down" then pose.y = pose.y - 1
  elseif direction == "forward" then
    if pose.dir == 0 then pose.z = pose.z + 1
    elseif pose.dir == 1 then pose.x = pose.x + 1
    elseif pose.dir == 2 then pose.z = pose.z - 1
    else pose.x = pose.x - 1 end
  elseif direction == "back" then
    if pose.dir == 0 then pose.z = pose.z - 1
    elseif pose.dir == 1 then pose.x = pose.x - 1
    elseif pose.dir == 2 then pose.z = pose.z + 1
    else pose.x = pose.x + 1 end
  end
  return pose
end

function M.chunkCoord(value)
  return math.floor((tonumber(value) or 0) / 16)
end

function M.chunkKey(cx, cz)
  return tostring(math.floor(tonumber(cx) or 0)) .. ":" .. tostring(math.floor(tonumber(cz) or 0))
end

function M.worldChunk(world)
  return M.chunkCoord(world.x), M.chunkCoord(world.z)
end

function M.calibrationFromFixes(home, forwardFix)
  if type(home) ~= "table" or type(forwardFix) ~= "table" then return nil, "missing_fix" end
  local dx, dy, dz = forwardFix.x - home.x, forwardFix.y - home.y, forwardFix.z - home.z
  if dy ~= 0 or math.abs(dx) + math.abs(dz) ~= 1 then
    return nil, "Forward calibration move was not exactly one horizontal block."
  end
  return {
    home = { x = home.x, y = home.y, z = home.z },
    forward = { x = dx, z = dz },
    calibratedAt = os and os.epoch and os.epoch("utc") or 0,
  }
end

function M.resolvePending(pending, fix, calibration)
  if type(pending) ~= "table" or type(pending.poseBefore) ~= "table" then return nil, "invalid_pending" end
  local actual, err = M.worldToLocal(calibration, fix, pending.poseBefore.dir)
  if not actual then return nil, err end
  local before = pending.poseBefore
  local kind = tostring(pending.kind or "")
  if M.samePosition(actual, before) then
    return { outcome = "before", pose = {
      x = before.x, y = before.y, z = before.z, dir = before.dir,
    } }
  end
  local expected = pending.poseAfter
  if type(expected) == "table" and M.samePosition(actual, expected) then
    return { outcome = "after", pose = {
      x = expected.x, y = expected.y, z = expected.z, dir = expected.dir,
    } }
  end
  if kind:match("^dig_") or kind:match("^seal_") then
    return nil, "position_changed_during_stationary_action"
  end
  return nil, "gps_position_matches_neither_side_of_pending_action"
end

return M
