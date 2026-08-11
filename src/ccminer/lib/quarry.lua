-- CC Miner V3 - deterministic quarry paths, chunk plans, and helpers.

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
  chunks[rootKey].optimizedAnchor = { x = chunks[rootKey].anchor.x, z = chunks[rootKey].anchor.z }
  walk[1] = { key = rootKey, first = true, anchor = { x = chunks[rootKey].anchor.x, z = chunks[rootKey].anchor.z } }
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
    for _, source in pairs(entries) do sources[#sources + 1] = source end
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

local function workerList(workerIds)
  if type(workerIds) ~= "table" then return nil, "invalid_worker_ids" end
  local workers, seen = {}, {}
  for _, id in ipairs(workerIds) do
    if #workers >= MAX_WORKERS then return nil, "too_many_workers" end
    if id == nil or tostring(id) == "" then return nil, "invalid_worker_id" end
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
