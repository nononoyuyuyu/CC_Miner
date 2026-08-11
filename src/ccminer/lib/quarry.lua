-- CC Miner V4 - deterministic quarry paths, chunk plans, and helpers.

local M = {}

-- The guards are deliberately conservative.  A quarry larger than these limits
-- is not useful in a single in-memory plan and would make an accidental UI/API
-- call allocate an unexpectedly large table.
local MAX_DIMENSION = 4096
local MAX_COLUMNS = 1024 * 1024
local MAX_BLOCKS = 16 * 1024 * 1024
local MAX_CHUNKS = 65536
local MAX_WORKERS = 128
local MAX_SELECTION_CELLS = 262144

M.MAX_DIMENSION = MAX_DIMENSION
M.MAX_COLUMNS = MAX_COLUMNS
M.MAX_BLOCKS = MAX_BLOCKS
M.MAX_CHUNKS = MAX_CHUNKS
M.MAX_WORKERS = MAX_WORKERS

local function numberValue(value)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return number
end

local function integerValue(value, minimum, maximum)
  local number = numberValue(value)
  if not number or number % 1 ~= 0 then return nil end
  if minimum and number < minimum then return nil end
  if maximum and number > maximum then return nil end
  return number
end

local function dimensions(width, length, depth)
  width = integerValue(width, 1, MAX_DIMENSION)
  length = integerValue(length, 1, MAX_DIMENSION)
  if not width or not length then return nil, "invalid_dimensions" end
  local columns = width * length
  if columns > MAX_COLUMNS then return nil, "quarry_too_large" end
  if depth ~= nil then
    depth = integerValue(depth, 1, MAX_DIMENSION)
    if not depth then return nil, "invalid_dimensions" end
    if columns * depth > MAX_BLOCKS then return nil, "quarry_too_large" end
  end
  return width, length, depth, columns
end

function M.total(width, length, depth)
  local validWidth, validLength, validDepth, columns = dimensions(width, length, depth)
  if not validWidth then return nil, validLength end
  if not validDepth then return nil, "invalid_dimensions" end
  return columns * validDepth
end

-- Fast continuous serpentine path used when no chunk is excluded.
function M.cell(width, length, depth, index)
  local validWidth, validLength, validDepth, totalColumns = dimensions(width, length, depth)
  if not validWidth then return nil, validLength end
  if not validDepth then return nil, "invalid_dimensions" end
  index = integerValue(index, 0)
  if not index or index >= totalColumns * validDepth then return nil, "index_out_of_range" end
  local perLayer = validWidth * validLength
  local layer = math.floor(index / perLayer)
  local offset = index % perLayer
  if layer % 2 == 1 then offset = perLayer - 1 - offset end
  local row = math.floor(offset / validLength)
  local column = offset % validLength
  local z = row % 2 == 0 and (column + 1) or (validLength - column)
  return { x = row, y = -layer, z = z }
end

function M.cellForJob(job, index)
  if type(job) ~= "table" then return nil, "invalid_job" end
  return M.cell(job.width, job.length, job.depth, index)
end

local function validCalibration(calibration)
  if type(calibration) ~= "table" or type(calibration.home) ~= "table" or type(calibration.forward) ~= "table" then
    return false
  end
  local fx, fz = numberValue(calibration.forward.x), numberValue(calibration.forward.z)
  local hx, hy, hz = numberValue(calibration.home.x), numberValue(calibration.home.y), numberValue(calibration.home.z)
  return fx ~= nil and fz ~= nil and hx ~= nil and hy ~= nil and hz ~= nil
    and math.abs(fx) + math.abs(fz) == 1
end

local function localToWorld(calibration, x, z)
  local forward = { x = numberValue(calibration.forward.x), z = numberValue(calibration.forward.z) }
  local homeX, homeZ = numberValue(calibration.home.x), numberValue(calibration.home.z)
  local rightX, rightZ = -forward.z, forward.x
  return homeX + rightX * x + forward.x * z,
    homeZ + rightZ * x + forward.z * z
end

-- Inverse of localToWorld for worker-local rebasing.  GPS calibrations are
-- cardinal (one-block forward/right vectors), so the result remains integral
-- for integral world positions while still accepting numeric coordinates for
-- diagnostics.
local function worldToLocalXZ(calibration, worldX, worldZ)
  if not validCalibration(calibration) then return nil, nil, "gps_not_calibrated" end
  worldX, worldZ = numberValue(worldX), numberValue(worldZ)
  if not worldX or not worldZ then return nil, nil, "invalid_world_position" end
  local forwardX, forwardZ = numberValue(calibration.forward.x), numberValue(calibration.forward.z)
  local homeX, homeZ = numberValue(calibration.home.x), numberValue(calibration.home.z)
  local dx, dz = worldX - homeX, worldZ - homeZ
  local rightX, rightZ = -forwardZ, forwardX
  return dx * rightX + dz * rightZ, dx * forwardX + dz * forwardZ
end

M.worldToLocalXZ = worldToLocalXZ
function M.inverseWorldToLocal(calibration, worldX, worldZ)
  if type(worldX) == "table" then worldZ, worldX = worldX.z, worldX.x end
  local localX, localZ, inverseError = worldToLocalXZ(calibration, worldX, worldZ)
  if not localX then return nil, inverseError end
  return { x = localX, z = localZ }
end
function M.referenceLocalToWorld(calibration, x, z)
  if not validCalibration(calibration) then return nil, "gps_not_calibrated" end
  x, z = numberValue(x), numberValue(z)
  if not x or not z then return nil, "invalid_position" end
  local worldX, worldZ = localToWorld(calibration, x, z)
  return { x = worldX, z = worldZ }
end
M.worldToLocal = M.inverseWorldToLocal

local function chunkKey(mode, cx, cz)
  return (mode == "world" and "W:" or "L:") .. tostring(cx) .. ":" .. tostring(cz)
end

M.chunkKey = chunkKey

function M.chunkForCell(mode, calibration, x, z)
  x, z = numberValue(x), numberValue(z)
  if not x or not z then return nil, nil, "invalid_position" end
  if mode == "world" then
    if not validCalibration(calibration) then return nil, nil, "gps_not_calibrated" end
    local wx, wz = localToWorld(calibration, x, z)
    return math.floor(wx / 16), math.floor(wz / 16)
  end
  return math.floor(x / 16), math.floor((z - 1) / 16)
end

local function chunkComparator(a, b)
  if a.cz ~= b.cz then return a.cz < b.cz end
  if a.cx ~= b.cx then return a.cx < b.cx end
  return tostring(a.key) < tostring(b.key)
end

function M.buildCatalog(width, length, mode, calibration)
  local validWidth, validLength, _, columns = dimensions(width, length)
  if not validWidth then return nil, validLength end
  mode = mode == "world" and "world" or "local"
  if mode == "world" and not validCalibration(calibration) then return nil, "gps_not_calibrated" end

  local byKey, catalogSize = {}, 0
  for x = 0, validWidth - 1 do
    for z = 1, validLength do
      local cx, cz, err = M.chunkForCell(mode, calibration, x, z)
      if not cx then return nil, err end
      local key = chunkKey(mode, cx, cz)
      local chunk = byKey[key]
      if not chunk then
        catalogSize = catalogSize + 1
        if catalogSize > MAX_CHUNKS then return nil, "too_many_chunks" end
        chunk = {
          key = key,
          mode = mode,
          cx = cx,
          cz = cz,
          minX = x,
          maxX = x,
          minZ = z,
          maxZ = z,
          cells = 0,
        }
        byKey[key] = chunk
      end
      if x < chunk.minX then chunk.minX = x end
      if x > chunk.maxX then chunk.maxX = x end
      if z < chunk.minZ then chunk.minZ = z end
      if z > chunk.maxZ then chunk.maxZ = z end
      chunk.cells = chunk.cells + 1
    end
  end

  local catalog = {}
  for _, chunk in pairs(byKey) do catalog[#catalog + 1] = chunk end
  table.sort(catalog, chunkComparator)
  return catalog
end

local function exclusionSet(exclusions, mode)
  local set = {}
  if exclusions == nil then return set end
  if type(exclusions) ~= "table" then return nil, "invalid_exclusions" end
  local seen = 0
  for _, item in ipairs(exclusions) do
    seen = seen + 1
    if seen > MAX_CHUNKS then return nil, "too_many_exclusions" end
    if type(item) == "string" then
      if item ~= "" then set[item] = true end
    elseif type(item) == "table" then
      local itemMode = item.mode == "world" and "world" or item.mode == "local" and "local" or mode
      local cx, cz = numberValue(item.cx), numberValue(item.cz)
      if cx and cz and cx % 1 == 0 and cz % 1 == 0 then
        set[chunkKey(itemMode, cx, cz)] = true
      elseif item.key and tostring(item.key) ~= "" then
        set[tostring(item.key)] = true
      end
    end
  end
  return set
end

local function overlaps(a1, a2, b1, b2)
  return a1 <= b2 and b1 <= a2
end

local function adjacent(a, b)
  if a.maxX + 1 == b.minX or b.maxX + 1 == a.minX then
    return overlaps(a.minZ, a.maxZ, b.minZ, b.maxZ)
  end
  if a.maxZ + 1 == b.minZ or b.maxZ + 1 == a.minZ then
    return overlaps(a.minX, a.maxX, b.minX, b.maxX)
  end
  return false
end

local function contains(chunk, x, z)
  return x >= chunk.minX and x <= chunk.maxX and z >= chunk.minZ and z <= chunk.maxZ
end

local function appendIndex(index, value, key)
  local list = index[value]
  if not list then list = {}; index[value] = list end
  list[#list + 1] = key
end

-- Build an edge-indexed graph.  The previous implementation compared every
-- chunk with every other chunk; boundary indexes make normal rectangular jobs
-- proportional to the number of chunks and their immediate candidates.
local function buildNeighborGraph(chunks, keys)
  local byMinX, byMaxX, byMinZ, byMaxZ = {}, {}, {}, {}
  for _, key in ipairs(keys) do
    local chunk = chunks[key]
    appendIndex(byMinX, chunk.minX, key)
    appendIndex(byMaxX, chunk.maxX, key)
    appendIndex(byMinZ, chunk.minZ, key)
    appendIndex(byMaxZ, chunk.maxZ, key)
    chunk.neighbors = {}
  end
  local order = {}
  for index, key in ipairs(keys) do order[key] = index end
  local function addPair(leftKey, rightKey)
    if leftKey == rightKey or order[leftKey] > order[rightKey] then return end
    local left, right = chunks[leftKey], chunks[rightKey]
    if not adjacent(left, right) then return end
    left.neighbors[#left.neighbors + 1] = rightKey
    right.neighbors[#right.neighbors + 1] = leftKey
  end
  for _, key in ipairs(keys) do
    local chunk = chunks[key]
    local candidates, seen = {}, {}
    local function collect(list)
      for _, candidate in ipairs(list or {}) do
        if not seen[candidate] then seen[candidate] = true; candidates[#candidates + 1] = candidate end
      end
    end
    collect(byMinX[chunk.maxX + 1])
    collect(byMaxX[chunk.minX - 1])
    collect(byMinZ[chunk.maxZ + 1])
    collect(byMaxZ[chunk.minZ - 1])
    table.sort(candidates, function(a, b) return order[a] < order[b] end)
    for _, candidate in ipairs(candidates) do addPair(key, candidate) end
  end
  for _, key in ipairs(keys) do
    table.sort(chunks[key].neighbors, function(left, right)
      return order[left] < order[right]
    end)
  end
end

local function copyChunk(source)
  local copy = {}
  for key, value in pairs(source) do copy[key] = value end
  copy.neighbors = {}
  copy.parent = nil
  copy.anchor = { x = copy.minX, z = copy.minZ }
  return copy
end

-- Return a deterministic boundary cell on `chunk` closest to `previous`.
-- `previous` may be a chunk, an anchor, or a point containing x/z.
function M.chunkAnchor(chunk, previous)
  if type(chunk) ~= "table" or not numberValue(chunk.minX) or not numberValue(chunk.maxX)
      or not numberValue(chunk.minZ) or not numberValue(chunk.maxZ) then
    return nil, "invalid_chunk"
  end
  local minX, maxX = chunk.minX, chunk.maxX
  local minZ, maxZ = chunk.minZ, chunk.maxZ
  local px, pz
  if type(previous) == "table" then
    px, pz = numberValue(previous.x), numberValue(previous.z)
    if (not px or not pz) and previous.anchor then
      px, pz = numberValue(previous.anchor.x), numberValue(previous.anchor.z)
    end
    if (not px or not pz) and previous.minX and previous.minZ then
      px, pz = numberValue(previous.minX), numberValue(previous.minZ)
    end
  end
  if not px or not pz then return { x = minX, z = minZ } end

  local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
  end
  local previousMinX, previousMaxX = numberValue(previous and previous.minX), numberValue(previous and previous.maxX)
  local previousMinZ, previousMaxZ = numberValue(previous and previous.minZ), numberValue(previous and previous.maxZ)
  if previousMinX and previousMaxX and previousMinZ and previousMaxZ then
    if previousMaxX + 1 == minX and overlaps(minZ, maxZ, previousMinZ, previousMaxZ) then
      return { x = minX, z = clamp(pz, math.max(minZ, previousMinZ), math.min(maxZ, previousMaxZ)) }
    elseif maxX + 1 == previousMinX and overlaps(minZ, maxZ, previousMinZ, previousMaxZ) then
      return { x = maxX, z = clamp(pz, math.max(minZ, previousMinZ), math.min(maxZ, previousMaxZ)) }
    elseif previousMaxZ + 1 == minZ and overlaps(minX, maxX, previousMinX, previousMaxX) then
      return { x = clamp(px, math.max(minX, previousMinX), math.min(maxX, previousMaxX)), z = minZ }
    elseif maxZ + 1 == previousMinZ and overlaps(minX, maxX, previousMinX, previousMaxX) then
      return { x = clamp(px, math.max(minX, previousMinX), math.min(maxX, previousMaxX)), z = maxZ }
    end
  end

  -- For a non-adjacent reference, choose the closest point on the rectangle
  -- perimeter, with a stable x-then-z tie break.
  local candidates = {
    { x = minX, z = clamp(pz, minZ, maxZ) },
    { x = maxX, z = clamp(pz, minZ, maxZ) },
    { x = clamp(px, minX, maxX), z = minZ },
    { x = clamp(px, minX, maxX), z = maxZ },
  }
  local best, bestDistance
  for _, candidate in ipairs(candidates) do
    local distance = math.abs(candidate.x - px) + math.abs(candidate.z - pz)
    if not best or distance < bestDistance or (distance == bestDistance and (candidate.x < best.x or (candidate.x == best.x and candidate.z < best.z))) then
      best, bestDistance = candidate, distance
    end
  end
  return best
end

M.selectChunkAnchor = M.chunkAnchor
M.chooseChunkAnchor = M.chunkAnchor
M.chunkEntry = M.chunkAnchor
M.chunkEntrance = M.chunkAnchor

local function shortestPathInternal(chunks, fromKey, toKey)
  if not chunks or not chunks[fromKey] then return nil, "unknown_chunk:" .. tostring(fromKey) end
  if not chunks[toKey] then return nil, "unknown_chunk:" .. tostring(toKey) end
  if fromKey == toKey then return { fromKey } end
  local queue, head, tail = { fromKey }, 1, 1
  local previous, seen = {}, { [fromKey] = true }
  while head <= tail do
    local key = queue[head]; head = head + 1
    for _, neighbor in ipairs(chunks[key].neighbors or {}) do
      if not seen[neighbor] then
        seen[neighbor] = true
        previous[neighbor] = key
        if neighbor == toKey then
          local path, current = { toKey }, toKey
          while current ~= fromKey do
            current = previous[current]
            path[#path + 1] = current
          end
          local reversed = {}
          for index = #path, 1, -1 do reversed[#reversed + 1] = path[index] end
          return reversed
        end
        tail = tail + 1; queue[tail] = neighbor
      end
    end
  end
  return nil, "chunks_disconnected"
end

function M.shortestChunkPath(plan, fromKey, toKey)
  if type(plan) ~= "table" or type(plan.chunks) ~= "table" then return nil, "invalid_chunk_plan" end
  local function normalizeKey(value)
    if type(value) == "table" then
      if value.key ~= nil then return tostring(value.key) end
      local cx, cz = integerValue(value.cx), integerValue(value.cz)
      if cx and cz then return chunkKey(plan.mode, cx, cz) end
      return nil
    end
    return value == nil and nil or tostring(value)
  end
  fromKey, toKey = normalizeKey(fromKey), normalizeKey(toKey)
  if fromKey == nil or toKey == nil then return nil, "invalid_chunk" end
  return shortestPathInternal(plan.chunks, tostring(fromKey), tostring(toKey))
end

M.shortestPath = M.shortestChunkPath

local function nearestUnvisitedPath(chunks, startKey, visited)
  local queue, head, tail = { startKey }, 1, 1
  local previous, seen = {}, { [startKey] = true }
  while head <= tail do
    local key = queue[head]; head = head + 1
    for _, neighbor in ipairs(chunks[key].neighbors or {}) do
      if not seen[neighbor] then
        seen[neighbor] = true
        previous[neighbor] = key
        if not visited[neighbor] then
          local path, current = { neighbor }, neighbor
          while current ~= startKey do
            current = previous[current]
            path[#path + 1] = current
          end
          local reversed = {}
          for index = #path, 1, -1 do reversed[#reversed + 1] = path[index] end
          return reversed
        end
        tail = tail + 1; queue[tail] = neighbor
      end
    end
  end
  return nil
end

local function optimizedWalk(chunks, keys, rootKey)
  local walk, order, visited = {}, {}, { [rootKey] = true }
  local current = rootKey
  -- Every plan is persisted in worker state.  CC:Tweaked's serializer rejects
  -- shared table references, so keep compatibility fields as independent
  -- point values instead of aliasing the chunk's anchor table.
  local rootAnchor = chunks[rootKey].anchor
    and { x = chunks[rootKey].anchor.x, z = chunks[rootKey].anchor.z }
    or (contains(chunks[rootKey], 0, 1) and { x = 0, z = 1 } or { x = chunks[rootKey].minX, z = chunks[rootKey].minZ })
  chunks[rootKey].optimizedAnchor = { x = rootAnchor.x, z = rootAnchor.z }
  walk[1] = { key = rootKey, first = true, anchor = { x = rootAnchor.x, z = rootAnchor.z } }
  order[1] = rootKey
  while #order < #keys do
    local nextKey
    for _, neighbor in ipairs(chunks[current].neighbors or {}) do
      if not visited[neighbor] then nextKey = neighbor; break end
    end
    local path
    if nextKey then
      path = { nextKey }
    else
      path = nearestUnvisitedPath(chunks, current, visited)
      if not path then break end
    end
    local previous = current
    for _, key in ipairs(path) do
      local first = not visited[key]
      if first then
        visited[key] = true
        order[#order + 1] = key
      end
      local anchor = M.chunkAnchor(chunks[key], chunks[previous]) or chunks[key].anchor
      if first then chunks[key].optimizedAnchor = { x = anchor.x, z = anchor.z } end
      walk[#walk + 1] = {
        key = key,
        first = first,
        anchor = { x = anchor.x, z = anchor.z },
      }
      previous, current = key, key
    end
  end
  return walk, order, visited
end

function M.buildChunkPlan(job, calibration)
  job = type(job) == "table" and job or {}
  local mode = job.chunkMode == "world" and "world" or "local"
  local validWidth, validLength, validDepth = dimensions(job.width, job.length, job.depth)
  if not validWidth then return nil, validLength end
  local catalog, catalogError = M.buildCatalog(validWidth, validLength, mode, calibration)
  if not catalog then return nil, catalogError end
  local excluded, exclusionError = exclusionSet(job.excludedChunks, mode)
  if not excluded then return nil, exclusionError end
  local chunks, rootKey, columns = {}, nil, 0
  local excludedCount = 0

  for _, source in ipairs(catalog) do
    if contains(source, 0, 1) then rootKey = source.key end
    if excluded[source.key] then
      excludedCount = excludedCount + 1
    else
      local copy = copyChunk(source)
      chunks[copy.key] = copy
      columns = columns + copy.cells
    end
  end

  if not rootKey then return nil, "entrance_chunk_missing" end
  if excluded[rootKey] then return nil, "The quarry entrance chunk cannot be excluded." end
  if not chunks[rootKey] then return nil, "No mineable chunks remain." end

  local keys = {}
  for key in pairs(chunks) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right) return chunkComparator(chunks[left], chunks[right]) end)
  buildNeighborGraph(chunks, keys)

  -- Keep the original DFS parent tree and walk for recovery/checkpoint
  -- compatibility.  The explicit stack avoids recursive overflow on large jobs.
  local visited, walk = {}, {}
  visited[rootKey] = true
  chunks[rootKey].parent = nil
  walk[1] = { key = rootKey, first = true }
  local stack = { { key = rootKey, next = 1 } }
  while #stack > 0 do
    local frame = stack[#stack]
    local chunk = chunks[frame.key]
    local neighbor
    while frame.next <= #chunk.neighbors do
      local candidate = chunk.neighbors[frame.next]
      frame.next = frame.next + 1
      if not visited[candidate] then neighbor = candidate; break end
    end
    if neighbor then
      visited[neighbor] = true
      chunks[neighbor].parent = frame.key
      walk[#walk + 1] = { key = neighbor, first = true }
      stack[#stack + 1] = { key = neighbor, next = 1 }
    else
      stack[#stack] = nil
      if #stack > 0 then walk[#walk + 1] = { key = stack[#stack].key, first = false } end
    end
  end

  local visitedCount = 0
  for _ in pairs(visited) do visitedCount = visitedCount + 1 end
  if visitedCount ~= #keys then
    local unreachable = {}
    for _, key in ipairs(keys) do if not visited[key] then unreachable[#unreachable + 1] = key end end
    return nil, "Excluded chunks split the quarry into disconnected regions: " .. table.concat(unreachable, ", ")
  end

  if contains(chunks[rootKey], 0, 1) then chunks[rootKey].anchor = { x = 0, z = 1 } end
  local optimized, optimizedOrder = optimizedWalk(chunks, keys, rootKey)
  return {
    mode = mode,
    width = validWidth,
    length = validLength,
    depth = validDepth,
    rootKey = rootKey,
    chunks = chunks,
    walk = walk,
    -- optimizedWalk is deliberately separate: worker recovery still uses the
    -- DFS parent/walk representation above.
    optimizedWalk = optimized,
    optimizedRoute = optimizedOrder,
    -- `route` is a legacy alias.  It must be a separate array because the
    -- runtime state is saved with textutils.serialize, which rejects shared
    -- table references even when the values are otherwise valid.
    route = (function()
      local copy = {}
      for index, key in ipairs(optimizedOrder) do copy[index] = key end
      return copy
    end)(),
    columns = columns,
    selectedChunks = #keys,
    excludedCount = excludedCount,
    catalogCount = #catalog,
  }
end

function M.chunkCellCount(chunk)
  if type(chunk) ~= "table" then return nil, "invalid_chunk" end
  local minX, maxX = integerValue(chunk.minX), integerValue(chunk.maxX)
  local minZ, maxZ = integerValue(chunk.minZ), integerValue(chunk.maxZ)
  if not minX or not maxX or not minZ or not maxZ or maxX < minX or maxZ < minZ then return nil, "invalid_chunk" end
  local count = (maxX - minX + 1) * (maxZ - minZ + 1)
  if count > MAX_COLUMNS then return nil, "chunk_too_large" end
  return count
end

function M.chunkCell(chunk, index, y)
  local count, countError = M.chunkCellCount(chunk)
  if not count then return nil, countError end
  index = integerValue(index, 0)
  if not index or index >= count then return nil, "index_out_of_range" end
  local width = chunk.maxX - chunk.minX + 1
  local length = chunk.maxZ - chunk.minZ + 1
  local row = math.floor(index / length)
  local column = index % length
  local z = row % 2 == 0 and (chunk.minZ + column) or (chunk.maxZ - column)
  return { x = chunk.minX + row, y = numberValue(y) or 0, z = z }
end

function M.findChunk(plan, x, z)
  if not plan or type(plan.chunks) ~= "table" then return nil end
  x, z = numberValue(x), numberValue(z)
  if not x or not z then return nil end
  for key, chunk in pairs(plan.chunks) do
    if contains(chunk, x, z) then return key, chunk end
  end
  return nil
end

function M.pathToRoot(plan, key)
  local path, seen = {}, {}
  if type(plan) ~= "table" or type(plan.chunks) ~= "table" then return nil, "invalid_chunk_plan" end
  if type(key) == "table" then key = key.key end
  key = key and tostring(key) or nil
  while key do
    if seen[key] then return nil, "parent_cycle" end
    seen[key] = true
    path[#path + 1] = key
    local chunk = plan.chunks[key]
    if not chunk then return nil, "unknown_chunk:" .. tostring(key) end
    key = chunk.parent
  end
  if path[#path] ~= plan.rootKey then return nil, "root_not_reached" end
  return path
end

function M.pathFromRoot(plan, key)
  local path, err = M.pathToRoot(plan, key)
  if not path then return nil, err end
  local reversed = {}
  for index = #path, 1, -1 do reversed[#reversed + 1] = path[index] end
  return reversed
end

-- Return a point on each side of one adjacent chunk edge.  The old recovery
-- walk intentionally starts at a chunk's minimum corner; service traffic must
-- not do that because it can add a full-corner detour on every transition.
-- Selecting the midpoint of the shared edge is deterministic and minimises the
-- worst-case distance for either side.  `edgeTransition` is kept independent
-- from a plan's mutable anchor/parent fields so it remains safe after a state
-- file is resumed on another worker.
local function edgeTransitionPoints(left, right, y)
  local pointY = numberValue(y) or 0
  if left.maxX + 1 == right.minX then
    local low, high = math.max(left.minZ, right.minZ), math.min(left.maxZ, right.maxZ)
    if low <= high then
      local z = math.floor((low + high) / 2)
      return { x = left.maxX, y = pointY, z = z }, { x = right.minX, y = pointY, z = z }
    end
  elseif right.maxX + 1 == left.minX then
    local low, high = math.max(left.minZ, right.minZ), math.min(left.maxZ, right.maxZ)
    if low <= high then
      local z = math.floor((low + high) / 2)
      return { x = left.minX, y = pointY, z = z }, { x = right.maxX, y = pointY, z = z }
    end
  elseif left.maxZ + 1 == right.minZ then
    local low, high = math.max(left.minX, right.minX), math.min(left.maxX, right.maxX)
    if low <= high then
      local x = math.floor((low + high) / 2)
      return { x = x, y = pointY, z = left.maxZ }, { x = x, y = pointY, z = right.minZ }
    end
  elseif right.maxZ + 1 == left.minZ then
    local low, high = math.max(left.minX, right.minX), math.min(left.maxX, right.maxX)
    if low <= high then
      local x = math.floor((low + high) / 2)
      return { x = x, y = pointY, z = left.minZ }, { x = x, y = pointY, z = right.maxZ }
    end
  end
  return nil, nil
end

local function normalizePlanKey(plan, value)
  if type(plan) ~= "table" or type(plan.chunks) ~= "table" then return nil, "invalid_chunk_plan" end
  local key
  if type(value) == "table" then
    key = value.chunkKey or value.chunk or value.key
    if key == nil and value.cx ~= nil and value.cz ~= nil then
      local cx, cz = integerValue(value.cx), integerValue(value.cz)
      if cx and cz then key = chunkKey(plan.mode, cx, cz) end
    end
  else
    key = value
  end
  if key == nil then return nil, "invalid_chunk" end
  key = tostring(key)
  if not plan.chunks[key] then return nil, "unknown_chunk:" .. key end
  return key
end

function M.edgeTransition(plan, fromKey, toKey, y)
  if type(plan) ~= "table" or type(plan.chunks) ~= "table" then return nil, "invalid_chunk_plan" end
  local from, fromError = normalizePlanKey(plan, fromKey)
  if not from then return nil, fromError end
  local to, toError = normalizePlanKey(plan, toKey)
  if not to then return nil, toError end
  local pointY = numberValue(y)
  if y ~= nil and not pointY then return nil, "invalid_y" end
  if from == to then return nil, "chunks_not_adjacent" end
  local left, right = plan.chunks[from], plan.chunks[to]
  local fromPoint, toPoint = edgeTransitionPoints(left, right, pointY or 0)
  if not fromPoint then return nil, "chunks_not_adjacent" end
  return {
    from = { x = fromPoint.x, y = fromPoint.y, z = fromPoint.z },
    to = { x = toPoint.x, y = toPoint.y, z = toPoint.z },
    -- Numeric entries keep older worker adapters (which consumed a waypoint
    -- array) compatible.  They are independent point tables, never aliases of
    -- the named fields.
    [1] = { x = fromPoint.x, y = fromPoint.y, z = fromPoint.z, kind = "from" },
    [2] = { x = toPoint.x, y = toPoint.y, z = toPoint.z, kind = "to" },
    fromKey = from,
    toKey = to,
    distance = math.abs(toPoint.x - fromPoint.x) + math.abs(toPoint.y - fromPoint.y) + math.abs(toPoint.z - fromPoint.z),
  }
end

M.chunkTransition = M.edgeTransition
M.neighborTransition = M.edgeTransition
M.transitionPoint = M.edgeTransition

local function routePointForChunk(chunk, y)
  local pointY = numberValue(y) or 0
  -- Integer midpoint keeps a route interior to the chunk for both odd and
  -- even dimensions.  It is deliberately not the historical min corner.
  return {
    x = math.floor((chunk.minX + chunk.maxX) / 2),
    y = pointY,
    z = math.floor((chunk.minZ + chunk.maxZ) / 2),
  }
end

local function normalizeRoutePose(plan, value, defaultKey, defaultY)
  local key, point
  if value == nil then
    key = defaultKey
  elseif type(value) == "string" or type(value) == "number" then
    key = tostring(value)
  elseif type(value) == "table" then
    key = value.chunkKey or value.chunk or value.key
    if key == nil and value.cx ~= nil and value.cz ~= nil then
      local cx, cz = integerValue(value.cx), integerValue(value.cz)
      if cx and cz then key = chunkKey(plan.mode, cx, cz) end
    end
    local nested = value.point or value.pose or value.position
    local source = type(nested) == "table" and nested or value
    local x, z = numberValue(source.x), numberValue(source.z)
    local y = numberValue(source.y)
    if x and z then point = { x = x, y = y or (numberValue(defaultY) or 0), z = z } end
    if key == nil and x and z then key = M.findChunk(plan, x, z) end
  end
  if key == nil then return nil, nil, "invalid_pose" end
  key = tostring(key)
  local chunk = plan.chunks[key]
  if not chunk then return nil, nil, "unknown_chunk:" .. key end
  if point == nil then point = routePointForChunk(chunk, defaultY) end
  if not contains(chunk, point.x, point.z) then
    return nil, nil, "pose_outside_chunk"
  end
  return key, point
end

local function parentFallbackPath(plan, fromKey, toKey)
  local fromRoot, fromError = M.pathFromRoot(plan, fromKey)
  if not fromRoot then return nil, fromError end
  local toRoot, toError = M.pathFromRoot(plan, toKey)
  if not toRoot then return nil, toError end
  local index = {}
  for i, key in ipairs(fromRoot) do index[key] = i end
  local commonFrom, commonTo
  for i = #toRoot, 1, -1 do
    if index[toRoot[i]] then commonFrom, commonTo = index[toRoot[i]], i; break end
  end
  if not commonFrom then return nil, "root_not_reached" end
  local path = {}
  -- pathFromRoot is ordered root -> node.  Walk the source node back to the
  -- common ancestor, then continue down the target branch.
  for i = #fromRoot, commonFrom, -1 do path[#path + 1] = fromRoot[i] end
  for i = commonTo + 1, #toRoot do path[#path + 1] = toRoot[i] end
  return path
end

local function appendRouteWaypoint(list, key, point, kind)
  list[#list + 1] = {
    chunkKey = tostring(key),
    key = tostring(key),
    x = point.x,
    y = point.y,
    z = point.z,
    kind = kind,
  }
end

function M.shortestServiceRoute(plan, fromPose, toPose, options)
  if type(plan) ~= "table" or type(plan.chunks) ~= "table" then return nil, "invalid_chunk_plan" end
  options = type(options) == "table" and options or {}
  local routeY = options.y
  if routeY == nil and type(fromPose) == "table" then routeY = fromPose.y end
  if routeY == nil and type(toPose) == "table" then routeY = toPose.y end
  routeY = numberValue(routeY) or 0
  if fromPose == nil and plan.rootKey and plan.chunks[plan.rootKey] and contains(plan.chunks[plan.rootKey], 0, 1) then
    fromPose = { chunkKey = plan.rootKey, x = 0, y = routeY, z = 1 }
  end
  local fromKey, fromPoint, fromError = normalizeRoutePose(plan, fromPose, plan.rootKey, routeY)
  if not fromKey then return nil, fromError end
  local toKey, toPoint, toError = normalizeRoutePose(plan, toPose, nil, routeY)
  if not toKey then return nil, toError end

  local chunkKeys, pathError = shortestPathInternal(plan.chunks, fromKey, toKey)
  local fallback = false
  if not chunkKeys and options.allowFallback ~= false then
    chunkKeys, pathError = parentFallbackPath(plan, fromKey, toKey)
    fallback = chunkKeys ~= nil
  end
  if not chunkKeys then return nil, pathError or "chunks_disconnected" end

  local waypoints, distance = {}, 0
  local previousPoint = { x = fromPoint.x, y = fromPoint.y, z = fromPoint.z }
  appendRouteWaypoint(waypoints, fromKey, previousPoint, "start")
  for index = 1, #chunkKeys - 1 do
    local leftKey, rightKey = chunkKeys[index], chunkKeys[index + 1]
    local transition, transitionError = M.edgeTransition(plan, leftKey, rightKey, routeY)
    if not transition then return nil, transitionError end
    distance = distance + math.abs(previousPoint.x - transition.from.x)
      + math.abs(previousPoint.y - transition.from.y)
      + math.abs(previousPoint.z - transition.from.z)
    appendRouteWaypoint(waypoints, leftKey, transition.from, "transition_from")
    distance = distance + math.abs(transition.to.x - transition.from.x)
      + math.abs(transition.to.y - transition.from.y)
      + math.abs(transition.to.z - transition.from.z)
    appendRouteWaypoint(waypoints, rightKey, transition.to, "transition_to")
    previousPoint = { x = transition.to.x, y = transition.to.y, z = transition.to.z }
  end
  distance = distance + math.abs(previousPoint.x - toPoint.x)
    + math.abs(previousPoint.y - toPoint.y)
    + math.abs(previousPoint.z - toPoint.z)
  appendRouteWaypoint(waypoints, toKey, toPoint, "target")
  local normalizedKeys = (function()
    local copy = {}; for i, key in ipairs(chunkKeys) do copy[i] = tostring(key) end; return copy
  end)()
  local function copyKeys()
    local copy = {}; for i, key in ipairs(normalizedKeys) do copy[i] = key end; return copy
  end
  return {
    chunkKeys = normalizedKeys,
    -- Compatibility names are independent arrays; never alias chunkKeys in a
    -- table persisted through CC's serializer.
    keys = copyKeys(),
    path = copyKeys(),
    transitKeys = copyKeys(),
    waypoints = waypoints,
    distance = distance,
    fallback = fallback,
  }
end

M.serviceRoute = M.shortestServiceRoute
M.shortestRoute = M.shortestServiceRoute
M.chunkServiceRoute = M.shortestServiceRoute
M.shortestServicePath = M.shortestServiceRoute

-- A checkpoint helper used by resume/return callers.  It intentionally has the
-- same result shape as shortestServiceRoute so callers can persist it without a
-- second schema.  The root is always selected from the plan, not from a
-- mutable worker pose.
function M.checkpointWaypoints(plan, target, options)
  if type(plan) ~= "table" then return nil, "invalid_chunk_plan" end
  options = type(options) == "table" and options or {}
  local rootPose = options.rootPose
  if type(rootPose) ~= "table" then
    rootPose = { chunkKey = plan.rootKey }
    local rootChunk = plan.chunks and plan.chunks[plan.rootKey]
    -- The quarry entrance is the stable root checkpoint.  If a custom plan
    -- does not contain the canonical (0,1) entrance, the route helper falls
    -- back to an interior midpoint instead of inventing a corner detour.
    if rootChunk and contains(rootChunk, 0, 1) then rootPose.x, rootPose.z = 0, 1 end
  end
  return M.shortestServiceRoute(plan, rootPose, target, options)
end

M.rootTargetWaypoints = M.checkpointWaypoints
M.safeWaypoints = M.checkpointWaypoints
M.buildCheckpointRoute = M.checkpointWaypoints
M.safeCheckpoint = M.checkpointWaypoints
M.rootToTargetCheckpoint = M.checkpointWaypoints

local function estimateOptions(job, options)
  options = type(options) == "table" and options or {}
  local interval = options.torchInterval or options.lightInterval
    or options.torchEvery or options.torchEveryCells
    or (type(job) == "table" and (job.torchInterval or job.lightInterval or job.torchEvery or job.torchEveryCells))
    or 16
  interval = integerValue(interval, 1, MAX_BLOCKS) or 16
  return interval
end

-- Estimate a job without returning a per-cell table.  The fields intentionally
-- carry both descriptive and compact aliases so callers can migrate gradually.
function M.estimateJob(job, calibration, options)
  if type(job) ~= "table" then return nil, "invalid_job" end
  if type(calibration) == "table" and not validCalibration(calibration) and calibration.home == nil and calibration.forward == nil and options == nil then
    options, calibration = calibration, nil
  end
  local validWidth, validLength, validDepth, columns = dimensions(job.width, job.length, job.depth)
  if not validWidth then return nil, validLength end
  if not validDepth then return nil, "invalid_dimensions" end
  local plan, planError = M.buildChunkPlan(job, calibration)
  if not plan then return nil, planError end
  local selectedColumns = plan.columns
  local totalCells = selectedColumns * validDepth
  if totalCells > MAX_BLOCKS then return nil, "quarry_too_large" end
  local interval = estimateOptions(job, options)
  local selectedChunks = plan.selectedChunks or 0
  local baseMovement = totalCells
  local transitionMovement = math.max(0, selectedChunks - 1)
  if selectedChunks > 1 then baseMovement = baseMovement + transitionMovement end

  local endpoint
  local noExclusions = (plan.excludedCount or 0) == 0
  if selectedChunks == 0 then
    endpoint = { x = 0, y = 0, z = 0 }
  elseif selectedChunks == plan.catalogCount and plan.mode == "local" and noExclusions then
    endpoint = M.cell(validWidth, validLength, validDepth, totalCells - 1)
  else
    local lastKey = plan.optimizedRoute[#plan.optimizedRoute]
    local lastChunk = plan.chunks[lastKey]
    endpoint = M.chunkCell(lastChunk, M.chunkCellCount(lastChunk) - 1, -(validDepth - 1))
  end
  endpoint = endpoint or { x = 0, y = 0, z = 0 }
  local returnMovement = math.abs(endpoint.x) + math.abs(endpoint.y) + math.abs(endpoint.z)
  local minimumFuel = baseMovement + returnMovement
  local estimatedTorches = math.ceil(totalCells / interval)
  return {
    width = validWidth,
    length = validLength,
    depth = validDepth,
    totalColumns = selectedColumns,
    columns = selectedColumns,
    surfaceCells = selectedColumns,
    columnCells = selectedColumns,
    minedCells = totalCells,
    totalCells = totalCells,
    cells = totalCells,
    cellCount = totalCells,
    totalBlocks = totalCells,
    blocks = totalCells,
    blockCount = totalCells,
    total = totalCells,
    baseMovement = baseMovement,
    baseMoves = baseMovement,
    baseDistance = baseMovement,
    estimatedMovement = baseMovement,
    transitionMovement = transitionMovement,
    returnMovement = returnMovement,
    minimumFuel = minimumFuel,
    minFuel = minimumFuel,
    torchInterval = interval,
    estimatedTorches = estimatedTorches,
    estimatedTorchCount = estimatedTorches,
    torchCount = estimatedTorches,
    torches = estimatedTorches,
    selectedChunks = selectedChunks,
    selectedChunkCount = selectedChunks,
    selectedCount = selectedChunks,
    excludedChunks = plan.excludedCount or 0,
    excludedChunkCount = plan.excludedCount or 0,
    excludedCount = plan.excludedCount or 0,
    catalogChunks = plan.catalogCount or 0,
    plan = plan,
  }
end

M.jobEstimate = M.estimateJob
M.estimate = M.estimateJob
M.estimateJobCost = M.estimateJob
M.estimateQuarry = M.estimateJob

local function catalogGraph(catalog)
  local chunks, keys = {}, {}
  local entries = catalog.chunks and type(catalog.chunks) == "table" and catalog.chunks or catalog
  local sources = {}
  if entries == catalog and #entries > 0 then
    for index = 1, #entries do sources[#sources + 1] = entries[index] end
  else
    -- Map catalogs commonly use the global chunk key as the map key and omit
    -- the duplicated `entry.key` field.  Normalize that form before
    -- validation; never mutate the caller's table (the descriptor may be
    -- shared with another worker/controller).
    for mapKey, source in pairs(entries) do
      if type(source) == "table" and (source.key == nil or tostring(source.key) == "") then
        local copy = {}
        for field, value in pairs(source) do copy[field] = value end
        copy.key = tostring(mapKey)
        sources[#sources + 1] = copy
      else
        sources[#sources + 1] = source
      end
    end
  end
  if #sources > MAX_CHUNKS then return nil, "too_many_chunks" end
  for _, source in ipairs(sources) do
    if type(source) ~= "table" then return nil, "invalid_chunk_catalog" end
    local key = source.key and tostring(source.key) or nil
    if not key or key == "" then return nil, "invalid_chunk_key" end
    if source.mode ~= "world" or key:sub(1, 2) ~= "W:" then return nil, "gps_required_world_catalog" end
    local cx, cz = integerValue(source.cx), integerValue(source.cz)
    local minX, maxX = integerValue(source.minX), integerValue(source.maxX)
    local minZ, maxZ = integerValue(source.minZ), integerValue(source.maxZ)
    local cells = integerValue(source.cells, 1, MAX_COLUMNS)
    if not cx or not cz or not minX or not maxX or not minZ or not maxZ or maxX < minX or maxZ < minZ or not cells or cells < 1 then
      return nil, "invalid_chunk_catalog"
    end
    local keyCx, keyCz = key:match("^W:(%-?%d+):(%-?%d+)$")
    if not keyCx or tonumber(keyCx) ~= cx or tonumber(keyCz) ~= cz then return nil, "invalid_chunk_key" end
    if chunks[key] then return nil, "duplicate_chunk_key" end
    chunks[key] = {
      key = key, mode = "world", cx = cx, cz = cz,
      minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, cells = cells,
    }
    keys[#keys + 1] = key
    if #keys > MAX_CHUNKS then return nil, "too_many_chunks" end
  end
  if #keys == 0 then return nil, "empty_chunk_catalog" end
  table.sort(keys, function(left, right) return chunkComparator(chunks[left], chunks[right]) end)
  buildNeighborGraph(chunks, keys)
  return chunks, keys
end

local function graphConnected(chunks, keys)
  local root = keys[1]
  local queue, head, tail = { root }, 1, 1
  local seen = { [root] = true }
  while head <= tail do
    local key = queue[head]; head = head + 1
    for _, neighbor in ipairs(chunks[key].neighbors or {}) do
      if not seen[neighbor] then seen[neighbor] = true; tail = tail + 1; queue[tail] = neighbor end
    end
  end
  for _, key in ipairs(keys) do if not seen[key] then return false end end
  return true
end

local function graphDistances(chunks, startKey)
  local queue, head, tail = { startKey }, 1, 1
  local distance = { [startKey] = 0 }
  while head <= tail do
    local key = queue[head]; head = head + 1
    for _, neighbor in ipairs(chunks[key].neighbors or {}) do
      if distance[neighbor] == nil then
        distance[neighbor] = distance[key] + 1
        tail = tail + 1; queue[tail] = neighbor
      end
    end
  end
  return distance
end

local function graphBreadthTree(chunks, startKey)
  local queue, head, tail = { startKey }, 1, 1
  local previous, seen = {}, { [startKey] = true }
  while head <= tail do
    local key = queue[head]; head = head + 1
    for _, neighbor in ipairs(chunks[key].neighbors or {}) do
      if not seen[neighbor] then
        seen[neighbor] = true
        previous[neighbor] = key
        tail = tail + 1; queue[tail] = neighbor
      end
    end
  end
  return previous
end

local function pathFromBreadthTree(previous, startKey, targetKey)
  if startKey == targetKey then return { startKey } end
  if not previous[targetKey] then return nil, "chunks_disconnected" end
  local reversed, current = { targetKey }, targetKey
  while current ~= startKey do
    current = previous[current]
    if not current then return nil, "chunks_disconnected" end
    reversed[#reversed + 1] = current
  end
  local path = {}
  for index = #reversed, 1, -1 do path[#path + 1] = reversed[index] end
  return path
end

local function workerList(workerIds)
  if type(workerIds) ~= "table" then return nil, "invalid_worker_ids" end
  local workers, seen = {}, {}
  for _, id in ipairs(workerIds) do
    if #workers >= MAX_WORKERS then return nil, "too_many_workers" end
    if id == nil or (type(id) ~= "string" and type(id) ~= "number") or tostring(id) == "" then
      return nil, "invalid_worker_id"
    end
    local key = tostring(id)
    if seen[key] then return nil, "duplicate_worker_id" end
    seen[key] = true
    workers[#workers + 1] = { id = id, key = key }
  end
  if #workers == 0 then return nil, "no_workers" end
  table.sort(workers, function(a, b) return a.key < b.key end)
  return workers
end

local function partitionChunks(catalog, workerIds)
  if type(catalog) ~= "table" then return nil, "invalid_chunk_catalog" end
  local workers, workerError = workerList(workerIds)
  if not workers then return nil, workerError end
  local chunks, keys = catalogGraph(catalog)
  if not chunks then return nil, keys end
  if #workers > #keys then return nil, "more_workers_than_chunks" end
  if not graphConnected(chunks, keys) then return nil, "chunk_catalog_disconnected" end

  local owner, loads, owned = {}, {}, {}
  for index, worker in ipairs(workers) do loads[index], owned[index] = 0, {} end
  local seeds = { keys[1] }
  local seedSet = { [keys[1]] = true }
  -- Farthest-point seeds spread workers over the world graph while keeping
  -- every later region reachable through an adjacent frontier.
  for index = 2, #workers do
    local distances = {}
    for _, seed in ipairs(seeds) do
      local fromSeed = graphDistances(chunks, seed)
      for key, distance in pairs(fromSeed) do
        if distances[key] == nil or distance < distances[key] then distances[key] = distance end
      end
    end
    local selected
    for _, key in ipairs(keys) do
      if not seedSet[key] and (not selected or distances[key] > distances[selected] or (distances[key] == distances[selected] and chunkComparator(chunks[key], chunks[selected]))) then
        selected = key
      end
    end
    if not selected then return nil, "worker_seed_failed" end
    seeds[#seeds + 1] = selected
    seedSet[selected] = true
  end
  for index, seed in ipairs(seeds) do
    owner[seed] = index
    owned[index][#owned[index] + 1] = seed
    loads[index] = loads[index] + chunks[seed].cells
  end

  local assigned = #seeds
  local target = 0
  for _, key in ipairs(keys) do target = target + chunks[key].cells end
  target = target / #workers
  while assigned < #keys do
    local bestKey, bestOwner, bestDeficit, bestProjected
    for _, key in ipairs(keys) do
      if not owner[key] then
        local candidates, candidateSeen = {}, {}
        for _, neighbor in ipairs(chunks[key].neighbors or {}) do
          local index = owner[neighbor]
          if index and not candidateSeen[index] then candidateSeen[index] = true; candidates[#candidates + 1] = index end
        end
        for _, index in ipairs(candidates) do
          local deficit = target - loads[index]
          local projected = math.abs((loads[index] + chunks[key].cells) - target)
          if not bestKey or deficit > bestDeficit or (deficit == bestDeficit and projected < bestProjected) or (deficit == bestDeficit and projected == bestProjected and (chunkComparator(chunks[key], chunks[bestKey]) or (key == bestKey and index < bestOwner))) then
            bestKey, bestOwner, bestDeficit, bestProjected = key, index, deficit, projected
          end
        end
      end
    end
    if not bestKey then return nil, "chunk_catalog_disconnected" end
    owner[bestKey] = bestOwner
    owned[bestOwner][#owned[bestOwner] + 1] = bestKey
    loads[bestOwner] = loads[bestOwner] + chunks[bestKey].cells
    assigned = assigned + 1
  end

  local result = {}
  for index, worker in ipairs(workers) do
    table.sort(owned[index], function(left, right) return chunkComparator(chunks[left], chunks[right]) end)
    result[worker.id] = { chunkKeys = owned[index], cells = loads[index] }
  end
  return result
end

M.partitionChunks = partitionChunks
M.assignWorkers = partitionChunks
M.splitWorkers = partitionChunks
M.splitWorkerChunks = partitionChunks
M.partitionWorkers = partitionChunks
M.assignChunkWorkers = partitionChunks
M.splitWorkerAssignments = partitionChunks

-- -------------------------------------------------------------------------
-- Group dispatch helpers
-- -------------------------------------------------------------------------
-- Group dispatch accepts either an already-built GPS catalog or a compact
-- descriptor ({ width, length, worldSeed/calibration }).  Keeping catalog
-- construction here lets a controller send only a worker bay and a GPS world
-- seed while preserving the world-coordinate safety checks in buildCatalog.
local function worldSeedCalibration(seed, options)
  options = type(options) == "table" and options or {}
  if type(seed) ~= "table" then return nil, "gps_not_calibrated" end
  local nested = seed.home and seed or (seed.calibration and seed.calibration) or seed
  if validCalibration(nested) then
    return {
      home = { x = nested.home.x, y = nested.home.y, z = nested.home.z },
      forward = { x = nested.forward.x, z = nested.forward.z },
    }
  end
  local point = seed.position or seed.world or seed.bay or seed.worldSeed or seed
  local x, z = numberValue(point.x), numberValue(point.z)
  if (not x or not z) and point.cx ~= nil and point.cz ~= nil then
    local cx, cz = integerValue(point.cx), integerValue(point.cz)
    if cx and cz then x, z = cx * 16 + 8, cz * 16 + 8 end
  end
  local y = numberValue(point.y)
  if not x or not z then return nil, "gps_not_calibrated" end
  y = y or numberValue(options.homeY) or 0
  local forward = seed.forward or options.forward or { x = 0, z = 1 }
  local fx, fz = numberValue(forward.x), numberValue(forward.z)
  if not fx or not fz or math.abs(fx) + math.abs(fz) ~= 1 then return nil, "gps_not_calibrated" end
  return { home = { x = x, y = y, z = z }, forward = { x = fx, z = fz } }
end

function M.buildWorldCatalog(width, length, worldSeed, options)
  options = type(options) == "table" and options or {}
  if type(width) == "table" then
    local descriptor = width
    if descriptor.width == nil and descriptor.length == nil and integerValue(length, 1, MAX_DIMENSION)
        and integerValue(worldSeed, 1, MAX_DIMENSION) then
      -- Flexible seed-first form: buildWorldCatalog(worldSeed, width, length).
      local seed = descriptor
      width, length, worldSeed = length, worldSeed, seed
      descriptor = nil
    end
    if descriptor == nil then
      local calibration = options.calibration or worldSeedCalibration(worldSeed, options)
      if not calibration then return nil, "gps_not_calibrated" end
      local catalog, catalogError = M.buildCatalog(width, length, "world", calibration)
      if not catalog then return nil, catalogError end
      catalog.referenceCalibration = {
        home = { x = calibration.home.x, y = calibration.home.y, z = calibration.home.z },
        forward = { x = calibration.forward.x, z = calibration.forward.z },
      }
      catalog.calibrationSeed = {
        home = { x = calibration.home.x, y = calibration.home.y, z = calibration.home.z },
        forward = { x = calibration.forward.x, z = calibration.forward.z },
      }
      local bounds
      for _, chunk in ipairs(catalog) do
        if contains(chunk, 0, 1) then catalog.rootKey = chunk.key; break end
      end
      for _, chunk in ipairs(catalog) do
        bounds = bounds or { minX = chunk.minX, maxX = chunk.maxX, minZ = chunk.minZ, maxZ = chunk.maxZ }
        bounds.minX, bounds.maxX = math.min(bounds.minX, chunk.minX), math.max(bounds.maxX, chunk.maxX)
        bounds.minZ, bounds.maxZ = math.min(bounds.minZ, chunk.minZ), math.max(bounds.maxZ, chunk.maxZ)
      end
      catalog.bounds = bounds
      return catalog
    end
    options = type(length) == "table" and length or options
    width, length = descriptor.width, descriptor.length
    worldSeed = descriptor.worldSeed or descriptor.seed or descriptor.calibration or options.worldSeed or worldSeed
    if descriptor.options and type(descriptor.options) == "table" then
      local merged = {}
      for key, value in pairs(descriptor.options) do merged[key] = value end
      for key, value in pairs(options) do merged[key] = value end
      options = merged
      if worldSeed == nil then worldSeed = options.worldSeed end
    end
  end
  local calibration = options.calibration
  if not calibration then calibration = worldSeedCalibration(worldSeed, options) end
  if not calibration then return nil, "gps_not_calibrated" end
  local catalog, catalogError = M.buildCatalog(width, length, "world", calibration)
  if not catalog then return nil, catalogError end
  -- Arrays may carry metadata fields in Lua.  Keep the reference GPS seed and
  -- bounds available to assigned-plan builders without sharing calibration
  -- tables with the caller or with persisted worker state.
  catalog.referenceCalibration = {
    home = { x = calibration.home.x, y = calibration.home.y, z = calibration.home.z },
    forward = { x = calibration.forward.x, z = calibration.forward.z },
  }
  catalog.calibrationSeed = {
    home = { x = calibration.home.x, y = calibration.home.y, z = calibration.home.z },
    forward = { x = calibration.forward.x, z = calibration.forward.z },
  }
  local referenceRoot
  for _, chunk in ipairs(catalog) do
    if contains(chunk, 0, 1) then referenceRoot = chunk.key; break end
  end
  catalog.rootKey = referenceRoot
  local bounds
  for _, chunk in ipairs(catalog) do
    bounds = bounds or { minX = chunk.minX, maxX = chunk.maxX, minZ = chunk.minZ, maxZ = chunk.maxZ }
    bounds.minX, bounds.maxX = math.min(bounds.minX, chunk.minX), math.max(bounds.maxX, chunk.maxX)
    bounds.minZ, bounds.maxZ = math.min(bounds.minZ, chunk.minZ), math.max(bounds.maxZ, chunk.maxZ)
  end
  catalog.bounds = bounds
  return catalog
end

M.catalogFromWorldSeed = M.buildWorldCatalog
M.worldCatalog = M.buildWorldCatalog
M.buildGpsCatalog = M.buildWorldCatalog
M.buildCatalogFromWorldSeed = M.buildWorldCatalog
M.worldCatalogFromSeed = M.buildWorldCatalog

local function groupCatalogInput(catalog, options)
  options = type(options) == "table" and options or {}
  if catalog == nil and options.width ~= nil and options.length ~= nil then
    local generated, generatedError = M.buildWorldCatalog(options.width, options.length, options.worldSeed, options)
    if not generated then return nil, nil, generatedError end
    local chunks, keys = catalogGraph(generated)
    if not chunks then return nil, nil, keys end
    return chunks, keys
  end
  if type(catalog) ~= "table" then return nil, nil, "invalid_chunk_catalog" end
  local descriptor = catalog
  local hasChunks = type(descriptor.chunks) == "table" or #descriptor > 0
  if not hasChunks and descriptor.width ~= nil and descriptor.length ~= nil then
    local generated, generatedError = M.buildWorldCatalog(descriptor, options)
    if not generated then return nil, nil, generatedError end
    local chunks, keys = catalogGraph(generated)
    if not chunks then return nil, nil, keys end
    return chunks, keys
  end
  -- A caller may pass { worldSeed = ..., width = ..., length = ... } with no
  -- explicit calibration.  Treat this as the same descriptor form above.
  if not hasChunks and options.width ~= nil and options.length ~= nil then
    local generated, generatedError = M.buildWorldCatalog(options.width, options.length,
      descriptor.worldSeed or descriptor.seed or options.worldSeed, options)
    if not generated then return nil, nil, generatedError end
    local chunks, keys = catalogGraph(generated)
    if not chunks then return nil, nil, keys end
    return chunks, keys
  end
  local chunks, keys = catalogGraph(catalog)
  if not chunks then return nil, nil, keys end
  return chunks, keys
end

local function groupWorkerList(values)
  if type(values) ~= "table" then return nil, "invalid_worker_ids" end
  local raw = {}
  if #values > 0 then
    for i = 1, #values do raw[#raw + 1] = { value = values[i], order = i } end
  else
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for index, key in ipairs(keys) do raw[#raw + 1] = { value = values[key], idKey = key, order = index } end
  end
  if #raw == 0 then return nil, "no_workers" end
  if #raw > MAX_WORKERS then return nil, "too_many_workers" end
  local workers, seen = {}, {}
  local function nestedPoint(value, depth)
    if type(value) ~= "table" then return nil end
    depth = (depth or 0) + 1
    if depth > 4 then return nil end
    local x, z = numberValue(value.x), numberValue(value.z)
    if (not x or not z) and value.cx ~= nil and value.cz ~= nil then
      local cx, cz = integerValue(value.cx), integerValue(value.cz)
      if cx and cz then x, z = cx * 16 + 8, cz * 16 + 8 end
    end
    if x and z then return { x = x, z = z } end
    local candidates = { value.bay, value.bayWorld, value.world, value.worldSeed,
      value.position, value.homeWorld, value.gps, value.seed }
    for index = 1, 8 do
      local nested = candidates[index]
      if nested ~= value then
        local point = nestedPoint(nested, depth)
        if point then return point end
      end
    end
    return nil
  end
  for _, item in ipairs(raw) do
    local value = item.value
    local id, key, homeY, bay, seedKey, homeYProvided, bayInvalid
    if type(value) == "table" then
      id = value.id
      if id == nil then id = value.workerId end
      if id == nil then id = value.name end
      if id == nil then id = item.idKey end
      homeY = value.homeY
      homeYProvided = homeY ~= nil
      if homeY == nil and type(value.home) == "table" then homeY = value.home.y end
      if homeY ~= nil then homeYProvided = true end
      if homeY == nil and type(value.calibration) == "table" and type(value.calibration.home) == "table" then
        homeY = value.calibration.home.y
        homeYProvided = true
      end
      bay = nestedPoint(value)
      local bayInput = value.bay or value.bayWorld or value.world or value.worldSeed or value.position or value.homeWorld or value.gps
      if bayInput == nil and type(value.seed) == "table" then bayInput = value.seed end
      bayInvalid = bayInput ~= nil and bay == nil
      seedKey = value.seedKey or value.chunkKey or value.chunk
    else
      id = value
    end
    if id == nil or tostring(id) == "" then return nil, "invalid_worker_id" end
    key = tostring(id)
    if seen[key] then return nil, "duplicate_worker_id" end
    seen[key] = true
    homeY = homeY == nil and nil or integerValue(homeY)
    if homeY == nil and homeYProvided then return nil, "invalid_home_y" end
    workers[#workers + 1] = {
      id = id,
      key = key,
      homeY = homeY,
      bay = bay,
      bayInvalid = bayInvalid,
      seedKey = seedKey and tostring(seedKey) or nil,
      order = item.order,
    }
  end
  table.sort(workers, function(a, b) return a.key < b.key end)
  return workers
end

local function uniqueSortedKeys(keys, chunks)
  local result, seen = {}, {}
  for _, key in ipairs(keys or {}) do
    key = tostring(key)
    if chunks[key] and not seen[key] then seen[key] = true; result[#result + 1] = key end
  end
  table.sort(result, function(a, b) return chunkComparator(chunks[a], chunks[b]) end)
  return result
end

local function catalogGridShape(chunks, keys)
  local xs, zs, seenX, seenZ, byCoord = {}, {}, {}, {}, {}
  for _, key in ipairs(keys) do
    local chunk = chunks[key]
    local coordKey = tostring(chunk.cx) .. ":" .. tostring(chunk.cz)
    if byCoord[coordKey] then return nil end
    byCoord[coordKey] = key
    if not seenX[chunk.cx] then seenX[chunk.cx] = true; xs[#xs + 1] = chunk.cx end
    if not seenZ[chunk.cz] then seenZ[chunk.cz] = true; zs[#zs + 1] = chunk.cz end
  end
  table.sort(xs); table.sort(zs)
  if #xs * #zs ~= #keys then return nil end
  for _, cx in ipairs(xs) do
    for _, cz in ipairs(zs) do
      if not byCoord[tostring(cx) .. ":" .. tostring(cz)] then return nil end
    end
  end
  return xs, zs, byCoord
end

local function workerBayChunk(worker, chunks, keys)
  -- In world group mode the bay entrance is the authoritative seed.  An
  -- optional seedKey is only a legacy hint and must not move a worker away
  -- from its own bay chunk.
  if worker.bayChunkKey and chunks[worker.bayChunkKey] then return worker.bayChunkKey end
  if worker.seedKey and chunks[worker.seedKey] then return worker.seedKey end
  if worker.bay then
    local cx, cz = math.floor(worker.bay.x / 16), math.floor(worker.bay.z / 16)
    local exact
    for _, key in ipairs(keys) do
      local chunk = chunks[key]
      if chunk.cx == cx and chunk.cz == cz then exact = key; break end
    end
    if exact then return exact end
    local best, bestDistance
    for _, key in ipairs(keys) do
      local chunk = chunks[key]
      local centerX, centerZ = chunk.cx * 16 + 8, chunk.cz * 16 + 8
      local distance = math.abs(worker.bay.x - centerX) + math.abs(worker.bay.z - centerZ)
      if not best or distance < bestDistance or (distance == bestDistance and chunkComparator(chunk, chunks[best])) then
        best, bestDistance = key, distance
      end
    end
    return best
  end
  return nil
end

local function stripeOwner(chunks, keys, workers, options)
  local xs, zs, byCoord = catalogGridShape(chunks, keys)
  if not xs or not zs then return nil, "stripe_partition_unavailable" end
  local explicitAxis = options.stripeAxis == "x" or options.stripeAxis == "z"
  local axis = explicitAxis and options.stripeAxis or (#xs >= #zs and "x" or "z")

  -- A bay-aware stripe can only satisfy the ownership contract when each bay
  -- occupies a distinct stripe level.  If the automatically selected axis
  -- collides, try the other axis before falling back to graph growth.
  local function levelData(candidateAxis)
    local candidateLevels = candidateAxis == "x" and xs or zs
    if #workers > #candidateLevels then return nil end
    local positions, used = {}, {}
    local anyBay = false
    for index, worker in ipairs(workers) do
      if worker.bayChunkKey then
        anyBay = true
        local chunk = chunks[worker.bayChunkKey]
        if not chunk then return nil end
        local level = candidateAxis == "x" and chunk.cx or chunk.cz
        local position
        for levelIndex, value in ipairs(candidateLevels) do
          if value == level then position = levelIndex; break end
        end
        if not position or used[position] then return nil end
        used[position] = true
        positions[index] = position
      end
    end
    if anyBay then
      for index = 1, #workers do if not positions[index] then return nil end end
    end
    return candidateLevels, positions, anyBay
  end

  local levels, bayPositions, bayAware = levelData(axis)
  if not levels and not explicitAxis then
    axis = axis == "x" and "z" or "x"
    levels, bayPositions, bayAware = levelData(axis)
  end
  if not levels then return nil, "stripe_partition_unavailable" end

  local weights, levelPositions = {}, {}
  for index, level in ipairs(levels) do
    levelPositions[level] = index
    local weight = 0
    for _, key in ipairs(keys) do
      local chunk = chunks[key]
      if (axis == "x" and chunk.cx == level) or (axis == "z" and chunk.cz == level) then weight = weight + chunk.cells end
    end
    weights[index] = weight
  end
  local workerOrder = {}
  for index = 1, #workers do workerOrder[index] = index end
  if bayAware then
    table.sort(workerOrder, function(left, right)
      if bayPositions[left] ~= bayPositions[right] then return bayPositions[left] < bayPositions[right] end
      return workers[left].key < workers[right].key
    end)
  end

  local owner, owned, loads = {}, {}, {}
  for index = 1, #workers do owned[index], loads[index] = {}, 0 end
  local cuts = {}
  if bayAware then
    -- Choose each cut at the nearest weighted midpoint while constraining it
    -- between adjacent bay levels.  This keeps every stripe contiguous and
    -- guarantees the worker whose bay is on a level owns that level.
    local prefix, total = { [0] = 0 }, 0
    for index, weight in ipairs(weights) do total = total + weight; prefix[index] = total end
    local previousCut = 0
    for rank = 1, #workers - 1 do
      local workerIndex = workerOrder[rank]
      local nextWorkerIndex = workerOrder[rank + 1]
      local minimum = math.max(previousCut + 1, bayPositions[workerIndex])
      local maximum = math.min(bayPositions[nextWorkerIndex] - 1, #levels - (#workers - rank))
      if minimum > maximum then return nil, "stripe_bay_alignment_unavailable" end
      local target = total * rank / #workers
      local bestCut, bestError
      for candidate = minimum, maximum do
        local error = math.abs(prefix[candidate] - target)
        if not bestCut or error < bestError or (error == bestError and candidate < bestCut) then
          bestCut, bestError = candidate, error
        end
      end
      cuts[rank], previousCut = bestCut, bestCut
    end
    cuts[#workers] = #levels
  else
    local levelIndex, remainingWeight = 1, 0
    for _, weight in ipairs(weights) do remainingWeight = remainingWeight + weight end
    for rank = 1, #workers do
      local remainingWorkers = #workers - rank
      local target = remainingWeight / (remainingWorkers + 1)
      local selected = 0
      while levelIndex <= #levels do
        local canStop = selected > 0 and (#levels - levelIndex + 1) >= remainingWorkers
        local weight = weights[levelIndex]
        if canStop and selected + weight > target and selected > 0 then break end
        selected = selected + weight
        levelIndex = levelIndex + 1
        if levelIndex > #levels or (#levels - levelIndex + 1) == remainingWorkers then break end
      end
      if rank == #workers then selected = remainingWeight end
      cuts[rank] = levelIndex - 1
      remainingWeight = remainingWeight - selected
    end
  end

  local startLevel = 1
  for rank = 1, #workers do
    local workerIndex = workerOrder[rank]
    local endLevel = cuts[rank]
    for _, key in ipairs(keys) do
      local chunk = chunks[key]
      local level = axis == "x" and chunk.cx or chunk.cz
      local levelPos = levelPositions[level]
      if levelPos and levelPos >= startLevel and levelPos <= endLevel then
        owner[key] = workerIndex
        owned[workerIndex][#owned[workerIndex] + 1] = key
        loads[workerIndex] = loads[workerIndex] + chunk.cells
      end
    end
    startLevel = endLevel + 1
  end
  return owner, owned, loads, "stripe", axis
end

local function graphOwner(chunks, keys, workers, strategyLabel, distanceWeight)
  if #workers > #keys then return nil, "more_workers_than_chunks" end
  local owner, owned, loads = {}, {}, {}
  for index = 1, #workers do owned[index], loads[index] = {}, 0 end
  local seeds, seedSet = {}, {}
  local seedDistanceCache = {}
  -- First honour explicit/bay seeds.  Bay chunks are validated as unique by
  -- partitionGroup; a duplicate can still only arise from a legacy caller,
  -- in which case choose the next deterministic frontier rather than aliasing
  -- ownership.
  for index, worker in ipairs(workers) do
    local selected = workerBayChunk(worker, chunks, keys)
    if selected and seedSet[selected] then selected = nil end
    if not selected then
      local best, bestDistance
      for _, key in ipairs(keys) do
        if not seedSet[key] then
          local distance = 0
          if worker.bay then
            local chunk = chunks[key]
            distance = math.abs(worker.bay.x - (chunk.cx * 16 + 8)) + math.abs(worker.bay.z - (chunk.cz * 16 + 8))
          else
            distance = MAX_CHUNKS
            local maps = seedDistanceCache
            for _, seed in ipairs(seeds) do
              if not maps[seed] then maps[seed] = graphDistances(chunks, seed) end
              local d = maps[seed][key] or MAX_CHUNKS
              -- Farthest-point seeding maximises the nearest distance to an
              -- existing seed (maximin), rather than clustering all workers
              -- around the first seed.
              if d < distance then distance = d end
            end
            if #seeds == 0 then distance = 0 end
          end
          local farther = not worker.bay
          if not best
              or (farther and distance > bestDistance)
              or ((not farther) and distance < bestDistance)
              or (distance == bestDistance and chunkComparator(chunks[key], chunks[best])) then
            best, bestDistance = key, distance
          end
        end
      end
      selected = best
    end
    if not selected then return nil, "worker_seed_failed" end
    seeds[index], seedSet[selected] = selected, true
    owner[selected] = index
    owned[index][#owned[index] + 1] = selected
    loads[index] = loads[index] + chunks[selected].cells
  end
  local total, target = 0, 0
  for _, key in ipairs(keys) do total = total + chunks[key].cells end
  target = total / #workers
  local assigned = #workers
  while assigned < #keys do
    local bestKey, bestOwner, bestScore, bestProjected
    for _, key in ipairs(keys) do
      if not owner[key] then
        local candidateOwners = {}
        for _, neighbor in ipairs(chunks[key].neighbors or {}) do
          local index = owner[neighbor]
          if index then candidateOwners[index] = true end
        end
        for index in pairs(candidateOwners) do
          local projected = math.abs((loads[index] + chunks[key].cells) - target)
          local score = projected
          if distanceWeight and workers[index].bay then
            local chunk = chunks[key]
            score = score + distanceWeight * (math.abs(workers[index].bay.x - (chunk.cx * 16 + 8))
              + math.abs(workers[index].bay.z - (chunk.cz * 16 + 8)))
          end
          if not bestKey or score < bestScore or (score == bestScore and (chunkComparator(chunks[key], chunks[bestKey]) or (key == bestKey and index < bestOwner))) then
            bestKey, bestOwner, bestScore, bestProjected = key, index, score, projected
          end
        end
      end
    end
    if not bestKey then return nil, "chunk_catalog_disconnected" end
    owner[bestKey] = bestOwner
    owned[bestOwner][#owned[bestOwner] + 1] = bestKey
    loads[bestOwner] = loads[bestOwner] + chunks[bestKey].cells
    assigned = assigned + 1
  end
  return owner, owned, loads, strategyLabel or "graph", seeds
end

local function cloneStringArray(values)
  local copy = {}
  for index, value in ipairs(values or {}) do copy[index] = tostring(value) end
  return copy
end

local function groupAssignmentCopy(source)
  local copy = {}
  for key, value in pairs(source or {}) do
    if key == "chunkKeys" or key == "transitKeys" or key == "leaseKeys" or key == "transitLeaseKeys" then
      copy[key] = cloneStringArray(value)
    elseif key == "layersInfo" and type(value) == "table" then
      local info = {}; for infoKey, infoValue in pairs(value) do info[infoKey] = infoValue end; copy[key] = info
    else
      copy[key] = value
    end
  end
  return copy
end

local function groupLeaseKey(groupJobId, workerId, chunkKeyValue)
  return tostring(groupJobId) .. ":" .. tostring(workerId) .. ":" .. tostring(chunkKeyValue)
end

function M.partitionGroup(catalog, workersInput, options)
  options = type(options) == "table" and options or {}
  local chunks, keys, catalogError = groupCatalogInput(catalog, options)
  if not chunks then return nil, catalogError end
  if #keys > MAX_CHUNKS then return nil, "too_many_chunks" end
  local catalogCells = 0
  for _, key in ipairs(keys) do
    catalogCells = catalogCells + chunks[key].cells
    if catalogCells > MAX_BLOCKS then return nil, "group_too_large" end
  end
  local workers, workerError = groupWorkerList(workersInput)
  if not workers then return nil, workerError end
  if #workers > #keys then return nil, "more_workers_than_chunks" end
  for _, worker in ipairs(workers) do
    if worker.seedKey and not chunks[worker.seedKey] then return nil, "unknown_seed_chunk:" .. worker.seedKey end
    if worker.bayInvalid then return nil, "invalid_worker_bay" end
  end
  local bayMap = options.workerBays or options.bays
  if type(bayMap) == "table" then
    for _, worker in ipairs(workers) do
      if not worker.bay then
        local bay = bayMap[worker.id] or bayMap[worker.key]
        if type(bay) == "table" then
          local point = bay.position or bay.world or bay.bay or bay.homeWorld or bay
          if type(point) == "table" and (not numberValue(point.x) or not numberValue(point.z)) then
            point = point.world or point.position or point.bay or point
          end
          local x, z = numberValue(point.x), numberValue(point.z)
          if (not x or not z) and point.cx ~= nil and point.cz ~= nil then
            local cx, cz = integerValue(point.cx), integerValue(point.cz)
            if cx and cz then x, z = cx * 16 + 8, cz * 16 + 8 end
          end
          if x and z then worker.bay = { x = x, z = z } end
        end
        if bay ~= nil and not worker.bay then return nil, "invalid_worker_bay" end
      end
    end
  end
  -- When bay metadata is supplied, every worker must have one distinct bay
  -- chunk inside the authoritative world catalog.  Never silently snap an
  -- out-of-catalog bay to its nearest chunk: that would let a worker start
  -- from another worker's region and defeats the transit lease boundary.
  local bayAware, bayChunks = false, {}
  for _, worker in ipairs(workers) do
    if worker.bay then
      bayAware = true
      local cx, cz = math.floor(worker.bay.x / 16), math.floor(worker.bay.z / 16)
      local bayKey
      for _, key in ipairs(keys) do
        local chunk = chunks[key]
        if chunk.cx == cx and chunk.cz == cz then bayKey = key; break end
      end
      if not bayKey then return nil, "worker_bay_outside_catalog:" .. worker.key end
      if bayChunks[bayKey] then return nil, "duplicate_worker_bay_chunk:" .. bayKey end
      bayChunks[bayKey] = worker.key
      worker.bayChunkKey = bayKey
    end
  end
  if bayAware then
    for _, worker in ipairs(workers) do
      if not worker.bayChunkKey then return nil, "worker_bay_required:" .. worker.key end
    end
  end
  if not graphConnected(chunks, keys) then return nil, "chunk_catalog_disconnected" end

  local bottomY = options.bottomY
  if bottomY == nil then bottomY = options.commonBottomY end
  if bottomY == nil then bottomY = options.targetY end
  if bottomY == nil then bottomY = options.bottom end
  if bottomY ~= nil then
    bottomY = integerValue(bottomY)
    if not bottomY then return nil, "invalid_bottom_y" end
  end
  local homeYMap = options.workerHomeY or options.homeYs
  if type(homeYMap) == "table" then
    for _, worker in ipairs(workers) do
      if worker.homeY == nil then
        local candidate = homeYMap[worker.id] or homeYMap[worker.key]
        if candidate ~= nil then
          worker.homeY = integerValue(candidate)
          if worker.homeY == nil then return nil, "invalid_home_y" end
        end
      end
    end
  end
  local defaultLayers = options.layers
  if defaultLayers ~= nil then
    defaultLayers = integerValue(defaultLayers, 1, MAX_DIMENSION)
    if not defaultLayers then return nil, "invalid_layers" end
  end
  local groupJobId = options.groupJobId or options.jobId or "group"
  if (type(groupJobId) ~= "string" and type(groupJobId) ~= "number") or tostring(groupJobId) == "" then
    return nil, "invalid_group_job_id"
  end
  local strategy = options.strategy
  -- Older controller settings called graph growth "round_robin".  Keep that
  -- spelling accepted while retaining connected ownership guarantees.
  if strategy == "round_robin" then strategy = "graph" end
  if strategy ~= nil and strategy ~= "stripe" and strategy ~= "graph" and strategy ~= "growth" then
    return nil, "invalid_partition_strategy"
  end
  if options.stripeAxis ~= nil and options.stripeAxis ~= "x" and options.stripeAxis ~= "z" then
    return nil, "invalid_stripe_axis"
  end
  local distanceWeight = options.distanceWeight
  if distanceWeight == nil then distanceWeight = 0.25 end
  distanceWeight = numberValue(distanceWeight)
  if not distanceWeight or distanceWeight < 0 or distanceWeight > MAX_DIMENSION then return nil, "invalid_distance_weight" end

  local owner, owned, loads, strategyUsed, seeds, stripeAxisUsed
  if strategy ~= "graph" and strategy ~= "growth" and options.stripeFirst ~= false then
    owner, owned, loads, strategyUsed, stripeAxisUsed = stripeOwner(chunks, keys, workers, options)
  end
  if strategy == "stripe" and not owner then return nil, owned or "stripe_partition_unavailable" end
  if not owner then
    owner, owned, loads, strategyUsed, seeds = graphOwner(chunks, keys, workers,
      strategy == "growth" and "growth" or "graph", distanceWeight)
  end
  if not owner then return nil, owned or "partition_failed" end

  -- Rectangular stripes are expected to be connected, but a hand-authored
  -- catalog may have irregular bounding boxes.  Fail closed (or use graph
  -- growth for the automatic strategy) instead of handing a worker a split
  -- region.
  local function ownedConnected(list)
    if #list < 2 then return true end
    local allowed, seen, queue = {}, {}, { list[1] }
    for _, key in ipairs(list) do allowed[key] = true end
    seen[list[1]] = true
    local head = 1
    while queue[head] do
      local key = queue[head]; head = head + 1
      for _, neighbor in ipairs(chunks[key].neighbors or {}) do
        if allowed[neighbor] and not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
      end
    end
    for _, key in ipairs(list) do if not seen[key] then return false end end
    return true
  end
  local allConnected = true
  for index = 1, #workers do if not ownedConnected(owned[index]) then allConnected = false; break end end
  if not allConnected then
    if strategy == "stripe" then return nil, "partition_disconnected" end
    owner, owned, loads, strategyUsed, seeds = graphOwner(chunks, keys, workers, "graph", distanceWeight)
    stripeAxisUsed = nil
    if not owner then return nil, owned or "partition_disconnected" end
  end

  -- Stripe assignment has no growth seeds, but each worker still needs a
  -- deterministic checkpoint near its bay.  Prefer the bay's chunk when it is
  -- inside the stripe; otherwise choose the closest owned chunk.
  if strategyUsed == "stripe" then
    seeds = {}
    for index, worker in ipairs(workers) do
      local candidate = workerBayChunk(worker, chunks, keys)
      if not candidate or owner[candidate] ~= index then
        local best, bestDistance
        for _, key in ipairs(owned[index] or {}) do
          local chunk = chunks[key]
          local distance = worker.bay
            and (math.abs(worker.bay.x - (chunk.cx * 16 + 8)) + math.abs(worker.bay.z - (chunk.cz * 16 + 8)))
            or 0
          if not best or distance < bestDistance or (distance == bestDistance and chunkComparator(chunk, chunks[best])) then
            best, bestDistance = key, distance
          end
        end
        candidate = best
      end
      seeds[index] = candidate
    end
  end

  -- Prefer the canonical entrance chunk in the shared reference-local
  -- catalog.  Falling back to lexicographic order is only for hand-authored
  -- catalogs that do not expose the (0,1) entrance cell.
  local rootKey = options.rootKey and tostring(options.rootKey) or nil
  if not rootKey then
    for _, key in ipairs(keys) do
      if contains(chunks[key], 0, 1) then rootKey = key; break end
    end
  end
  rootKey = rootKey or keys[1]
  if not chunks[rootKey] then return nil, "unknown_root_chunk" end
  local assignments, totalCost, assignedSet = {}, 0, {}
  for index, worker in ipairs(workers) do
    local chunkKeys = uniqueSortedKeys(owned[index], chunks)
    if #chunkKeys == 0 then return nil, "empty_worker_assignment" end
    local seedKey = worker.bayChunkKey
      or (worker.seedKey and chunks[worker.seedKey] and worker.seedKey)
      or (seeds and seeds[index]) or chunkKeys[1]
    if not owner[seedKey] or owner[seedKey] ~= index then seedKey = chunkKeys[1] end
    local transitSet, originKey = {}, workerBayChunk(worker, chunks, keys) or rootKey
    if not chunks[originKey] then originKey = rootKey end
    -- A bay-aligned stripe is itself connected and starts at the worker's own
    -- bay seed, so it needs no transit lease at all.  For graph growth keep
    -- the explicit shortest paths, but include only keys outside this
    -- worker's mine assignment.
    if not (strategyUsed == "stripe" and bayAware) then
      local originTree = graphBreadthTree(chunks, originKey)
      for _, targetKey in ipairs(chunkKeys) do
        local path = pathFromBreadthTree(originTree, originKey, targetKey)
        if path then
          for _, transitKey in ipairs(path) do
            if owner[transitKey] ~= index then transitSet[transitKey] = true end
          end
        end
      end
    end
    for _, targetKey in ipairs(chunkKeys) do assignedSet[targetKey] = true end
    local transitKeys = {}
    for transitKey in pairs(transitSet) do transitKeys[#transitKeys + 1] = transitKey end
    table.sort(transitKeys, function(a, b) return chunkComparator(chunks[a], chunks[b]) end)
    local layers = defaultLayers
    if layers == nil and worker.homeY ~= nil and bottomY ~= nil then layers = worker.homeY - bottomY + 1 end
    if layers == nil then layers = 1 end
    if layers < 1 or layers > MAX_DIMENSION then return nil, "invalid_worker_layers" end
    local volume = loads[index] * layers
    if volume > MAX_BLOCKS then return nil, "group_too_large" end
    local distance = #transitKeys + math.max(0, #chunkKeys - 1)
    if worker.bay then
      local seedChunk = chunks[seedKey]
      distance = distance + math.abs(worker.bay.x - (seedChunk.cx * 16 + 8))
        + math.abs(worker.bay.z - (seedChunk.cz * 16 + 8))
    end
    local estimatedCost = volume + distance
    -- Lease overlap checks operate on global chunk keys.  Do not prefix these
    -- arrays with a worker name: that would make two assignments appear
    -- disjoint to the controller.  The assignment-scoped identity lives in
    -- leaseId separately, while each array gets its own copy for CC's
    -- serializer.
    local leaseKeys = cloneStringArray(chunkKeys)
    local transitLeaseKeys = cloneStringArray(transitKeys)
    local assignment = {
      workerId = worker.id,
      groupJobId = groupJobId,
      leaseId = tostring(groupJobId) .. ":" .. tostring(worker.id),
      chunkKeys = chunkKeys,
      transitKeys = transitKeys,
      transitLeaseKeys = transitLeaseKeys,
      leaseKeys = leaseKeys,
      seedKey = seedKey,
      estimatedCost = estimatedCost,
      estimatedVolume = volume,
      volume = volume,
      estimatedDistance = distance,
      distance = distance,
      distanceWeight = distanceWeight,
      homeY = worker.homeY,
      bottomY = bottomY,
      layers = layers,
      layersInfo = { homeY = worker.homeY, bottomY = bottomY, count = layers },
      strategy = strategyUsed,
      stripeAxis = stripeAxisUsed,
    }
    assignments[#assignments + 1] = assignment
    totalCost = totalCost + estimatedCost
  end

  local unassigned = {}
  for _, key in ipairs(keys) do if not assignedSet[key] then unassigned[#unassigned + 1] = key end end
  local result = {
    assignments = {},
    unassigned = cloneStringArray(unassigned),
    totalCost = totalCost,
    groupJobId = groupJobId,
    strategy = strategyUsed,
    stripeAxis = stripeAxisUsed,
    distanceWeight = distanceWeight,
    bottomY = bottomY,
    catalogCount = #keys,
  }
  for index, assignment in ipairs(assignments) do result.assignments[index] = groupAssignmentCopy(assignment) end
  -- Mapping is useful to controller callers, but must be a deep independent
  -- copy: CC's serializer treats even equal table references as recursive.
  result.byWorker = {}
  for _, assignment in ipairs(assignments) do result.byWorker[assignment.workerId] = groupAssignmentCopy(assignment) end
  return result
end

M.groupPartition = M.partitionGroup
M.splitGroupWorkers = M.partitionGroup
M.assignGroupWorkers = M.partitionGroup
M.partitionWorkersGroup = M.partitionGroup

-- Build a worker-local plan from a shared world catalog.  The catalog may be
-- an array/map, or an existing plan.  `assignedKeys` are the only mineable
-- chunks; `transitKeys` are optional, explicit lease keys that may be crossed
-- while travelling from a dock/entrance to the assigned seed.
local function cloneValue(value, depth)
  if type(value) ~= "table" then return value end
  depth = (depth or 0) + 1
  if depth > 16 then return nil end
  local copy = {}
  for key, item in pairs(value) do
    local copiedKey = type(key) == "table" and nil or key
    if copiedKey ~= nil then copy[copiedKey] = cloneValue(item, depth) end
  end
  return copy
end

local function assignedCatalogEntries(catalog)
  if type(catalog) ~= "table" then return nil, nil, "invalid_chunk_catalog" end
  local source = catalog
  if type(catalog.catalog) == "table" then source = catalog.catalog end
  if type(catalog.chunks) == "table" then source = catalog.chunks end
  local entries, byKey = {}, {}
  if #source > 0 then
    for index = 1, #source do
      local entry = source[index]
      if type(entry) ~= "table" then return nil, nil, "invalid_chunk_catalog" end
      local key = entry.key and tostring(entry.key) or nil
      if not key or byKey[key] then return nil, nil, "duplicate_chunk_key" end
      byKey[key] = entry; entries[#entries + 1] = entry
    end
  else
    for key, entry in pairs(source) do
      if type(entry) ~= "table" then return nil, nil, "invalid_chunk_catalog" end
      local normalized = entry.key and tostring(entry.key) or tostring(key)
      if normalized == "" or byKey[normalized] then return nil, nil, "duplicate_chunk_key" end
      if entry.key == nil or tostring(entry.key) == "" then
        -- Keep map-key catalogs immutable while giving catalogGraph the
        -- explicit key required by its world-key validation.
        local copy = {}
        for field, value in pairs(entry) do copy[field] = value end
        copy.key = normalized
        entry = copy
      end
      byKey[normalized] = entry; entries[#entries + 1] = entry
    end
  end
  return entries, byKey
end

local function assignedKeyList(value, field)
  if type(value) == "table" and field and type(value[field]) == "table" then value = value[field] end
  if type(value) ~= "table" then return nil, "invalid_assigned_keys" end
  local list, seen = {}, {}
  if #value > 0 then
    for index = 1, #value do
      local key = value[index]
      if type(key) == "table" then key = key.key or key.chunkKey end
      if key == nil or tostring(key) == "" then return nil, "invalid_assigned_key" end
      key = tostring(key)
      if seen[key] then return nil, "duplicate_assigned_key:" .. key end
      seen[key] = true; list[#list + 1] = key
    end
  else
    for key, enabled in pairs(value) do
      if enabled then
        key = tostring(key)
        if key == "" or seen[key] then return nil, "duplicate_assigned_key:" .. key end
        seen[key] = true; list[#list + 1] = key
      end
    end
  end
  table.sort(list)
  if #list == 0 then return nil, "no_assigned_chunks" end
  return list
end

local function assignedConnected(chunks, keys)
  if #keys == 0 then return false end
  local allowed, seen, queue = {}, {}, { keys[1] }
  for _, key in ipairs(keys) do allowed[key] = true end
  seen[keys[1]] = true
  local head = 1
  while queue[head] do
    local key = queue[head]; head = head + 1
    for _, neighbor in ipairs(chunks[key].neighbors or {}) do
      if allowed[neighbor] and not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
    end
  end
  for _, key in ipairs(keys) do if not seen[key] then return false end end
  return true
end

local function assignedWalk(chunks, keys, rootKey, assignedSet)
  local visited, walk = {}, {}
  visited[rootKey] = true
  chunks[rootKey].parent = nil
  walk[1] = {
    key = rootKey,
    first = true,
    anchor = { x = chunks[rootKey].anchor.x, z = chunks[rootKey].anchor.z },
  }
  local stack = { { key = rootKey, next = 1 } }
  while #stack > 0 do
    local frame = stack[#stack]
    local chunk = chunks[frame.key]
    local nextKey
    while frame.next <= #chunk.neighbors do
      local candidate = chunk.neighbors[frame.next]
      frame.next = frame.next + 1
      if assignedSet[candidate] and not visited[candidate] then nextKey = candidate; break end
    end
    if nextKey then
      visited[nextKey] = true
      chunks[nextKey].parent = frame.key
      local boundary = M.chunkAnchor(chunks[nextKey], chunks[frame.key]) or chunks[nextKey].anchor
      chunks[nextKey].anchor = { x = boundary.x, z = boundary.z }
      walk[#walk + 1] = {
        key = nextKey,
        first = true,
        anchor = { x = boundary.x, z = boundary.z },
      }
      stack[#stack + 1] = { key = nextKey, next = 1 }
    else
      stack[#stack] = nil
      if #stack > 0 then
        local parentKey = stack[#stack].key
        walk[#walk + 1] = {
          key = parentKey,
          first = false,
          anchor = { x = chunks[parentKey].anchor.x, z = chunks[parentKey].anchor.z },
        }
      end
    end
  end
  return walk, visited
end

function M.buildAssignedChunkPlan(catalog, assignedKeys, options)
  options = type(options) == "table" and options or {}
  local sourceEntries, sourceByKey, sourceError = assignedCatalogEntries(catalog)
  if not sourceEntries then return nil, sourceError end
  local graphInput = {}
  for _, source in ipairs(sourceEntries) do graphInput[#graphInput + 1] = source end
  local sourceChunks, sourceKeys = catalogGraph(graphInput)
  if not sourceChunks then return nil, sourceKeys end
  for _, key in ipairs(sourceKeys) do
    if sourceChunks[key].mode ~= "world" then return nil, "gps_required_world_catalog" end
  end
  if not graphConnected(sourceChunks, sourceKeys) then return nil, "chunk_catalog_disconnected" end

  local assignment = type(assignedKeys) == "table" and assignedKeys or nil
  if assignedKeys == nil and type(catalog) == "table" then
    assignedKeys = catalog.assignedKeys or catalog.mineChunkKeys or catalog.chunkKeys
    if not assignedKeys and type(catalog.catalog) == "table" then
      assignedKeys = catalog.catalog.assignedKeys or catalog.catalog.mineChunkKeys or catalog.catalog.chunkKeys
    end
    assignment = type(assignedKeys) == "table" and catalog or nil
  end
  local mineKeys, mineError = assignedKeyList(assignment and (assignment.chunkKeys or assignment.assignedKeys or assignment.chunks) or assignedKeys)
  if not mineKeys then return nil, mineError end
  local transitInput = options.transitKeys or (assignment and (assignment.transitKeys or assignment.transit))
  local transitKeys = {}
  if transitInput ~= nil then
    local transitError
    local transitEmpty = type(transitInput) == "table" and next(transitInput) == nil
    if transitEmpty then transitKeys = {} else
      transitKeys, transitError = assignedKeyList(transitInput)
      if not transitKeys then return nil, transitError end
    end
  end
  local mineSet, transitSet = {}, {}
  for _, key in ipairs(mineKeys) do
    if not sourceChunks[key] then return nil, "unknown_assigned_chunk:" .. key end
    mineSet[key] = true
  end
  for _, key in ipairs(transitKeys) do
    if not sourceChunks[key] then return nil, "unknown_transit_chunk:" .. key end
    if mineSet[key] then return nil, "transit_overlaps_assigned:" .. key end
    transitSet[key] = true
  end

  -- Shared catalogs are expressed in the reference worker's local frame.
  -- Rebase every catalog rectangle through world coordinates before building
  -- the worker-local graph; this handles both offsets and cardinal rotations.
  local referenceCalibration = options.referenceCalibration
  if not referenceCalibration and type(catalog) == "table" then
    referenceCalibration = catalog.referenceCalibration or catalog.calibrationSeed or catalog.calibration
    if not referenceCalibration and type(catalog.catalog) == "table" then
      referenceCalibration = catalog.catalog.referenceCalibration or catalog.catalog.calibrationSeed or catalog.catalog.calibration
    end
  end
  local workerCalibration = options.workerCalibration or options.calibration
  if workerCalibration and not referenceCalibration then return nil, "reference_calibration_required" end
  if referenceCalibration and not validCalibration(referenceCalibration) then return nil, "invalid_reference_calibration" end
  if workerCalibration and not validCalibration(workerCalibration) then return nil, "invalid_worker_calibration" end
  local referenceRootKey = options.referenceRootKey or (type(catalog) == "table" and catalog.rootKey)
  if not referenceRootKey and type(catalog) == "table" and type(catalog.catalog) == "table" then
    referenceRootKey = catalog.catalog.rootKey
  end
  if referenceRootKey ~= nil then referenceRootKey = tostring(referenceRootKey) end
  if not referenceRootKey then
    for _, key in ipairs(sourceKeys) do
      if contains(sourceChunks[key], 0, 1) then referenceRootKey = key; break end
    end
  end
  local function rebaseBounds(chunk)
    if not workerCalibration then return true end
    local minX, maxX, minZ, maxZ = chunk.minX, chunk.maxX, chunk.minZ, chunk.maxZ
    local corners = {
      { x = minX, z = minZ }, { x = minX, z = maxZ },
      { x = maxX, z = minZ }, { x = maxX, z = maxZ },
    }
    local rebasedMinX, rebasedMaxX, rebasedMinZ, rebasedMaxZ
    for _, corner in ipairs(corners) do
      local worldX, worldZ = localToWorld(referenceCalibration, corner.x, corner.z)
      local localX, localZ, rebaseError = worldToLocalXZ(workerCalibration, worldX, worldZ)
      if not localX or not localZ then return nil, rebaseError or "invalid_rebase" end
      if localX % 1 ~= 0 or localZ % 1 ~= 0 then return nil, "non_integral_rebase" end
      rebasedMinX = rebasedMinX and math.min(rebasedMinX, localX) or localX
      rebasedMaxX = rebasedMaxX and math.max(rebasedMaxX, localX) or localX
      rebasedMinZ = rebasedMinZ and math.min(rebasedMinZ, localZ) or localZ
      rebasedMaxZ = rebasedMaxZ and math.max(rebasedMaxZ, localZ) or localZ
    end
    chunk.referenceMinX, chunk.referenceMaxX = minX, maxX
    chunk.referenceMinZ, chunk.referenceMaxZ = minZ, maxZ
    chunk.minX, chunk.maxX = rebasedMinX, rebasedMaxX
    chunk.minZ, chunk.maxZ = rebasedMinZ, rebasedMaxZ
    return true
  end
  for _, key in ipairs(sourceKeys) do
    local ok, rebaseError = rebaseBounds(sourceChunks[key])
    if not ok then return nil, rebaseError end
  end
  if not assignedConnected(sourceChunks, mineKeys) then return nil, "assigned_chunks_disconnected" end

  local seedKey = options.seedKey or (assignment and assignment.seedKey) or mineKeys[1]
  if seedKey ~= nil then seedKey = tostring(seedKey) end
  if not seedKey or not mineSet[seedKey] then return nil, "assigned_seed_not_mineable" end
  local rootKey = options.rootKey or referenceRootKey or sourceKeys[1]
  rootKey = rootKey and tostring(rootKey) or nil
  local dockKey = options.dockKey or options.entranceKey or rootKey
  dockKey = dockKey and tostring(dockKey) or nil
  if workerCalibration then
    local dockWorldX, dockWorldZ = localToWorld(workerCalibration, 0, 1)
    local expectedDockKey = chunkKey("world", math.floor(dockWorldX / 16), math.floor(dockWorldZ / 16))
    if not sourceChunks[expectedDockKey] then return nil, "worker_entrance_chunk_missing" end
    if options.dockKey and tostring(options.dockKey) ~= expectedDockKey then return nil, "worker_dock_chunk_mismatch" end
    dockKey = expectedDockKey
    -- A group may share one controller dock while workers enter from
    -- distinct bay chunks.  The worker-local entrance therefore need only be
    -- present in the catalog and explicitly mineable/transit-allowed below;
    -- it is not required to equal the reference worker's root chunk.
  end
  if not dockKey or not sourceChunks[dockKey] then return nil, "unknown_dock_chunk" end
  if not mineSet[dockKey] and not transitSet[dockKey] then
    return nil, "dock_requires_explicit_transit:" .. dockKey
  end

  local allSet, allKeys = {}, {}
  for _, key in ipairs(mineKeys) do allSet[key] = true; allKeys[#allKeys + 1] = key end
  for _, key in ipairs(transitKeys) do
    if not allSet[key] then allSet[key] = true; allKeys[#allKeys + 1] = key end
  end
  table.sort(allKeys, function(left, right) return chunkComparator(sourceChunks[left], sourceChunks[right]) end)
  local chunks = {}
  for _, key in ipairs(allKeys) do
    local source = sourceByKey[key] or sourceChunks[key]
    local copy = cloneValue(source)
    if type(copy) ~= "table" then return nil, "invalid_chunk_catalog" end
    copy.key, copy.mode = key, "world"
    copy.cx, copy.cz = sourceChunks[key].cx, sourceChunks[key].cz
    copy.minX, copy.maxX = sourceChunks[key].minX, sourceChunks[key].maxX
    copy.minZ, copy.maxZ = sourceChunks[key].minZ, sourceChunks[key].maxZ
    copy.referenceMinX, copy.referenceMaxX = sourceChunks[key].referenceMinX, sourceChunks[key].referenceMaxX
    copy.referenceMinZ, copy.referenceMaxZ = sourceChunks[key].referenceMinZ, sourceChunks[key].referenceMaxZ
    copy.cells = sourceChunks[key].cells
    copy.mine = mineSet[key] == true
    copy.transit = transitSet[key] == true and not copy.mine
    copy.parent, copy.anchor, copy.optimizedAnchor = nil, nil, nil
    chunks[key] = copy
  end
  buildNeighborGraph(chunks, allKeys)

  -- Every non-assigned edge on dock -> seed must be explicitly leased as
  -- transit.  This also permits an entrance outside the worker's mine region
  -- without silently granting access to arbitrary shared chunks.
  local servicePath, serviceError = shortestPathInternal(chunks, dockKey, seedKey)
  if not servicePath then return nil, serviceError or "service_route_disconnected" end
  for _, key in ipairs(servicePath) do
    if not mineSet[key] and not transitSet[key] then return nil, "service_route_requires_transit:" .. key end
  end

  -- Runtime movement still consumes `chunk.anchor`, including on older
  -- workers that do not understand serviceRoute waypoints.  Populate every
  -- mine/transit chunk with independent valid cells before constructing the
  -- assigned DFS walk.
  for _, key in ipairs(allKeys) do
    local chunk = chunks[key]
    local anchor = M.chunkAnchor(chunk) or { x = chunk.minX, z = chunk.minZ }
    chunk.anchor = { x = anchor.x, z = anchor.z }
  end
  if chunks[seedKey] then
    local entranceAnchor = contains(chunks[seedKey], 0, 1)
      and { x = 0, z = 1 }
      or M.chunkAnchor(chunks[seedKey], { x = 0, z = 1 })
    if entranceAnchor then chunks[seedKey].anchor = { x = entranceAnchor.x, z = entranceAnchor.z } end
  end
  if chunks[dockKey] then
    local dockAnchor = contains(chunks[dockKey], 0, 1)
      and { x = 0, z = 1 }
      or M.chunkAnchor(chunks[dockKey], { x = 0, z = 1 })
    if dockAnchor then chunks[dockKey].anchor = { x = dockAnchor.x, z = dockAnchor.z } end
  end
  for index = 2, #servicePath do
    local previousKey, currentKey = servicePath[index - 1], servicePath[index]
    local boundary = M.chunkAnchor(chunks[currentKey], chunks[previousKey])
    if boundary and currentKey ~= seedKey then chunks[currentKey].anchor = { x = boundary.x, z = boundary.z } end
  end

  local walk, visited = assignedWalk(chunks, mineKeys, seedKey, mineSet)
  for _, key in ipairs(mineKeys) do
    if not visited[key] then return nil, "assigned_chunks_disconnected" end
  end
  local mineCopies = {}
  for _, key in ipairs(mineKeys) do mineCopies[key] = cloneValue(chunks[key]); mineCopies[key].neighbors = {} end
  buildNeighborGraph(mineCopies, mineKeys)
  local optimized, optimizedOrder = optimizedWalk(mineCopies, mineKeys, seedKey)
  for _, key in ipairs(mineKeys) do
    if mineCopies[key].optimizedAnchor then
      chunks[key].optimizedAnchor = { x = mineCopies[key].optimizedAnchor.x, z = mineCopies[key].optimizedAnchor.z }
    end
  end
  local routeCopy = {}
  for index, key in ipairs(optimizedOrder) do routeCopy[index] = key end
  local assignedColumns = 0
  local assignedBounds
  for _, key in ipairs(mineKeys) do assignedColumns = assignedColumns + chunks[key].cells end
  for _, key in ipairs(mineKeys) do
    local chunk = chunks[key]
    assignedBounds = assignedBounds or { minX = chunk.minX, maxX = chunk.maxX, minZ = chunk.minZ, maxZ = chunk.maxZ }
    assignedBounds.minX, assignedBounds.maxX = math.min(assignedBounds.minX, chunk.minX), math.max(assignedBounds.maxX, chunk.maxX)
    assignedBounds.minZ, assignedBounds.maxZ = math.min(assignedBounds.minZ, chunk.minZ), math.max(assignedBounds.maxZ, chunk.maxZ)
  end
  local servicePlan = {
    mode = "world", chunks = chunks, rootKey = dockKey,
  }
  local dockPose = { chunkKey = dockKey }
  if chunks[dockKey] then
    local dockAnchor = chunks[dockKey].anchor
    if contains(chunks[dockKey], 0, 1) then
      dockPose.x, dockPose.z = 0, 1
    elseif dockAnchor then
      dockPose.x, dockPose.z = dockAnchor.x, dockAnchor.z
    end
  end
  local serviceRoute = M.shortestServiceRoute(servicePlan,
    dockPose, { chunkKey = seedKey }, { y = options.y or options.bottomY or 0 })
  if not serviceRoute then return nil, "service_route_disconnected" end
  return {
    mode = "world",
    rootKey = seedKey,
    dockKey = dockKey,
    entranceKey = dockKey,
    seedKey = seedKey,
    chunks = chunks,
    assignedKeys = cloneStringArray(mineKeys),
    mineChunkKeys = cloneStringArray(mineKeys),
    transitKeys = cloneStringArray(transitKeys),
    serviceRoute = {
      chunkKeys = cloneStringArray(serviceRoute.chunkKeys),
      keys = cloneStringArray(serviceRoute.keys or serviceRoute.chunkKeys),
      path = cloneStringArray(serviceRoute.path or serviceRoute.chunkKeys),
      transitKeys = cloneStringArray(serviceRoute.transitKeys or serviceRoute.chunkKeys),
      waypoints = cloneValue(serviceRoute.waypoints),
      distance = serviceRoute.distance,
      fallback = serviceRoute.fallback,
    },
    transitRouteKeys = cloneStringArray(servicePath),
    walk = walk,
    optimizedWalk = optimized,
    optimizedRoute = optimizedOrder,
    route = routeCopy,
    columns = assignedColumns,
    selectedChunks = #mineKeys,
    catalogCount = #sourceKeys,
    bounds = assignedBounds,
    referenceCalibration = cloneValue(referenceCalibration),
    workerCalibration = cloneValue(workerCalibration),
    workerId = assignment and assignment.workerId or options.workerId,
    groupJobId = assignment and assignment.groupJobId or options.groupJobId,
    homeY = assignment and assignment.homeY or options.homeY,
    bottomY = assignment and assignment.bottomY or options.bottomY,
    depth = assignment and assignment.layers or options.layers,
  }
end

M.assignedChunkPlan = M.buildAssignedChunkPlan
M.buildWorkerChunkPlan = M.buildAssignedChunkPlan
M.planAssignedChunks = M.buildAssignedChunkPlan
M.planAssignment = M.buildAssignedChunkPlan
M.buildAssignmentPlan = M.buildAssignedChunkPlan

local function boundsFrom(value, length, options)
  options = type(options) == "table" and options or {}
  local minX, maxX, minZ, maxZ
  if type(value) == "table" then
    if value.minX ~= nil and value.maxX ~= nil and value.minZ ~= nil and value.maxZ ~= nil then
      minX, maxX = integerValue(value.minX), integerValue(value.maxX)
      minZ, maxZ = integerValue(value.minZ), integerValue(value.maxZ)
    elseif value.width ~= nil and value.length ~= nil then
      local width, validLength = integerValue(value.width, 1, MAX_DIMENSION), integerValue(value.length, 1, MAX_DIMENSION)
      if not width or not validLength or width * validLength > MAX_COLUMNS then return nil, "invalid_bounds" end
      local originX = integerValue(value.originX ~= nil and value.originX or options.originX or 0)
      local originZ = integerValue(value.originZ ~= nil and value.originZ or options.originZ or 1)
      if not originX or not originZ then return nil, "invalid_bounds" end
      minX, maxX = originX, originX + width - 1
      minZ, maxZ = originZ, originZ + validLength - 1
    elseif value.plan then
      return boundsFrom(value.plan, nil, options)
    elseif value.chunks then
      for _, chunk in pairs(value.chunks) do
        if not minX or chunk.minX < minX then minX = chunk.minX end
        if not maxX or chunk.maxX > maxX then maxX = chunk.maxX end
        if not minZ or chunk.minZ < minZ then minZ = chunk.minZ end
        if not maxZ or chunk.maxZ > maxZ then maxZ = chunk.maxZ end
      end
    end
  else
    local width = integerValue(value, 1, MAX_DIMENSION)
    local validLength = integerValue(length, 1, MAX_DIMENSION)
    if width and validLength and width * validLength <= MAX_COLUMNS then
      local originX = integerValue(options.originX ~= nil and options.originX or 0)
      local originZ = integerValue(options.originZ ~= nil and options.originZ or 1)
      if originX and originZ then
        minX, maxX = originX, originX + width - 1
        minZ, maxZ = originZ, originZ + validLength - 1
      end
    end
  end
  if not minX or not maxX or not minZ or not maxZ or maxX < minX or maxZ < minZ then return nil, "invalid_bounds" end
  if (maxX - minX + 1) * (maxZ - minZ + 1) > MAX_COLUMNS then return nil, "bounds_too_large" end
  return {
    minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ,
    width = maxX - minX + 1, length = maxZ - minZ + 1,
    cells = (maxX - minX + 1) * (maxZ - minZ + 1),
  }
end

function M.gridBounds(value, length, options)
  return boundsFrom(value, length, options)
end

M.getGridBounds = M.gridBounds
M.bounds = M.gridBounds

function M.gridPage(bounds, page, pageWidth, pageHeight)
  local normalized, boundsError = boundsFrom(bounds)
  if not normalized then return nil, boundsError end
  if type(pageWidth) == "table" then pageHeight, pageWidth = pageWidth.pageHeight, pageWidth.pageWidth end
  pageWidth = integerValue(pageWidth, 1, MAX_DIMENSION) or 16
  pageHeight = integerValue(pageHeight, 1, MAX_DIMENSION) or pageWidth
  local pagesX = math.ceil(normalized.width / pageWidth)
  local pagesZ = math.ceil(normalized.length / pageHeight)
  local pageCount = pagesX * pagesZ
  page = integerValue(page, 1, pageCount) or 1
  local pageIndex = page - 1
  local pageX, pageZ = pageIndex % pagesX, math.floor(pageIndex / pagesX)
  local minX = normalized.minX + pageX * pageWidth
  local minZ = normalized.minZ + pageZ * pageHeight
  local maxX = math.min(normalized.maxX, minX + pageWidth - 1)
  local maxZ = math.min(normalized.maxZ, minZ + pageHeight - 1)
  return {
    page = page, pageIndex = pageIndex, pageCount = pageCount,
    pagesX = pagesX, pagesZ = pagesZ, pageX = pageX, pageZ = pageZ,
    pageWidth = pageWidth, pageHeight = pageHeight,
    minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ,
    width = maxX - minX + 1, length = maxZ - minZ + 1,
    cells = (maxX - minX + 1) * (maxZ - minZ + 1),
  }
end

M.getGridPage = M.gridPage
M.page = M.gridPage
M.gridPageInfo = M.gridPage
M.pageInfo = M.gridPage

function M.gridCell(bounds, index)
  local normalized, boundsError = boundsFrom(bounds)
  if not normalized then return nil, boundsError end
  index = integerValue(index, 0)
  if not index or index >= normalized.cells then return nil, "index_out_of_range" end
  local row = math.floor(index / normalized.length)
  local column = index % normalized.length
  local z = row % 2 == 0 and (normalized.minZ + column) or (normalized.maxZ - column)
  return { x = normalized.minX + row, z = z, index = index, row = row, column = column }
end

M.getGridCell = M.gridCell

function M.gridCellInfo(bounds, x, z)
  local normalized, boundsError = boundsFrom(bounds)
  if not normalized then return nil, boundsError end
  x, z = integerValue(x), integerValue(z)
  if not x or not z then return nil, "invalid_position" end
  local inside = contains(normalized, x, z)
  local info = { x = x, z = z, inside = inside }
  if inside then
    local row, column = x - normalized.minX, z - normalized.minZ
    info.row, info.column = row, column
    info.index = row * normalized.length + (row % 2 == 0 and column or normalized.length - 1 - column)
  end
  return info
end

M.getCellInfo = M.gridCellInfo
M.cellInfo = M.gridCellInfo

function M.selectRectangle(bounds, x1, z1, x2, z2, options)
  local normalized, boundsError = boundsFrom(bounds)
  if not normalized then return nil, boundsError end
  if type(x1) == "table" then
    options = z1
    local selection = x1
    x1, z1, x2, z2 = selection.x1 or selection.minX, selection.z1 or selection.minZ, selection.x2 or selection.maxX, selection.z2 or selection.maxZ
  end
  x1, z1, x2, z2 = integerValue(x1), integerValue(z1), integerValue(x2), integerValue(z2)
  if not x1 or not z1 or not x2 or not z2 then return nil, "invalid_rectangle" end
  if x1 > x2 then x1, x2 = x2, x1 end
  if z1 > z2 then z1, z2 = z2, z1 end
  local minX, maxX = math.max(x1, normalized.minX), math.min(x2, normalized.maxX)
  local minZ, maxZ = math.max(z1, normalized.minZ), math.min(z2, normalized.maxZ)
  if minX > maxX or minZ > maxZ then return nil, "rectangle_out_of_bounds" end
  local count = (maxX - minX + 1) * (maxZ - minZ + 1)
  local result = {
    minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ,
    width = maxX - minX + 1, length = maxZ - minZ + 1,
    count = count, cellsCount = count,
    clipped = minX ~= x1 or maxX ~= x2 or minZ ~= z1 or maxZ ~= z2,
  }
  local includeCells = true
  if type(options) == "table" and options.includeCells == false then includeCells = false end
  if type(options) == "boolean" then includeCells = options end
  if includeCells and count <= MAX_SELECTION_CELLS then
    result.cells = {}
    for x = minX, maxX do
      for z = minZ, maxZ do result.cells[#result.cells + 1] = { x = x, z = z } end
    end
    result.selectedCells = result.cells
  elseif includeCells then
    result.cellsTruncated = true
  end
  return result
end

M.rectangleSelection = M.selectRectangle
M.selectRect = M.selectRectangle
M.rectangle = M.selectRectangle
M.selectRectangleCells = M.selectRectangle

return M
