local quarry = dofile(arg[1] .. "/src/ccminer/lib/quarry.lua")

local function contains(text, needle)
  return tostring(text):find(needle, 1, true) ~= nil
end

local function adjacent(a, b)
  local function overlaps(a1, a2, b1, b2)
    return a1 <= b2 and b1 <= a2
  end
  if a.maxX + 1 == b.minX or b.maxX + 1 == a.minX then
    return overlaps(a.minZ, a.maxZ, b.minZ, b.maxZ)
  end
  if a.maxZ + 1 == b.minZ or b.maxZ + 1 == a.minZ then
    return overlaps(a.minX, a.maxX, b.minX, b.maxX)
  end
  return false
end

-- CC:Tweaked's textutils.serialize rejects a table that is referenced more
-- than once (including a recursive reference).  Keep the mock local to this
-- file so every V4 result that is persisted by a worker/controller is checked
-- without requiring a ComputerCraft runtime.
local function assertSerializable(value, label)
  local seen = {}
  local function visit(item)
    local kind = type(item)
    if kind == "function" or kind == "thread" or kind == "userdata" then
      error((label or "value") .. " contains unserializable " .. kind, 0)
    end
    if kind ~= "table" then return end
    if seen[item] then error((label or "value") .. " contains a shared table reference", 0) end
    seen[item] = true
    for key, nested in pairs(item) do
      visit(key)
      visit(nested)
    end
  end
  visit(value)
  return true
end

local function assertConnected(chunks, keys, label)
  assert(type(chunks) == "table" and type(keys) == "table" and #keys > 0, label or "empty graph")
  local allowed, seen, queue = {}, {}, { keys[1] }
  for _, key in ipairs(keys) do
    assert(chunks[key], (label or "graph") .. " references an unknown chunk " .. tostring(key))
    allowed[key] = true
  end
  seen[keys[1]] = true
  local head = 1
  while queue[head] do
    local current = chunks[queue[head]]
    head = head + 1
    for _, candidate in ipairs(keys) do
      if not seen[candidate] and allowed[candidate] and adjacent(current, chunks[candidate]) then
        seen[candidate] = true
        queue[#queue + 1] = candidate
      end
    end
  end
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  assert(count == #keys, (label or "graph") .. " is disconnected")
end

local function containsKey(keys, needle)
  for _, key in ipairs(keys or {}) do if key == needle then return true end end
  return false
end

local function catalogMap(catalog)
  local map = {}
  for _, chunk in ipairs(catalog or {}) do map[chunk.key] = chunk end
  return map
end

-- Legacy serpentine cells remain deterministic and bounded for every layer.
local cases = {
  { 1, 1, 1 }, { 1, 8, 3 }, { 8, 1, 4 }, { 2, 2, 2 }, { 7, 13, 5 }, { 8, 32, 16 },
}
for width = 1, 6 do
  for length = 1, 7 do
    for depth = 1, 4 do cases[#cases + 1] = { width, length, depth } end
  end
end
for _, case in ipairs(cases) do
  local width, length, depth = case[1], case[2], case[3]
  local total = assert(quarry.total(width, length, depth))
  local seen, previous = {}, { x = 0, y = 0, z = 0 }
  for index = 0, total - 1 do
    local cell, err = quarry.cell(width, length, depth, index)
    assert(cell, err)
    assert(cell.x >= 0 and cell.x < width)
    assert(cell.z >= 1 and cell.z <= length)
    assert(cell.y <= 0 and cell.y > -depth)
    local key = cell.x .. ":" .. cell.y .. ":" .. cell.z
    assert(not seen[key], "duplicate legacy cell " .. key)
    seen[key] = true
    local distance = math.abs(cell.x - previous.x) + math.abs(cell.y - previous.y) + math.abs(cell.z - previous.z)
    assert(distance == 1, ("non-adjacent legacy path at %d for %dx%dx%d: distance=%d"):format(index, width, length, depth, distance))
    previous = cell
  end
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  assert(count == total)
  assert(quarry.cell(width, length, depth, -1) == nil)
  assert(quarry.cell(width, length, depth, total) == nil)
end
assert(quarry.total(0, 1, 1) == nil)
assert(quarry.total(1, 1, 0) == nil)
assert(quarry.total("wide", 1, 1) == nil)
assert(quarry.cellForJob({ width = 2, length = 2, depth = 1 }, 0).z == 1)
assert(quarry.cellForJob(nil, 0) == nil)

-- EstimateJob exposes stable aliases and accounts for depth, transitions,
-- return distance, and configurable torch cadence.
local estimate = assert(quarry.estimateJob({ width = 4, length = 5, depth = 3, chunkMode = "local" }, nil, { torchInterval = 10 }))
assert(estimate.width == 4 and estimate.length == 5 and estimate.depth == 3)
assert(estimate.columns == 20 and estimate.totalColumns == 20 and estimate.totalCells == 60)
assert(estimate.blocks == 60 and estimate.total == 60 and estimate.selectedChunks == 1)
assert(estimate.torchInterval == 10 and estimate.estimatedTorches == 6 and estimate.torches == 6)
assert(estimate.baseMovement == 60 and estimate.transitionMovement == 0)
assert(estimate.returnMovement == 6 and estimate.minimumFuel == 66)
assert(estimate.plan.rootKey == "L:0:0")
local excludedEstimate = assert(quarry.estimateJob({
  width = 32, length = 32, depth = 2, chunkMode = "local",
  excludedChunks = { { mode = "local", cx = 1, cz = 1 } },
}, nil, { torchInterval = 32 }))
assert(excludedEstimate.columns == 768 and excludedEstimate.totalCells == 1536)
assert(excludedEstimate.selectedChunks == 3 and excludedEstimate.excludedChunks == 1)
assert(excludedEstimate.transitionMovement == 2 and excludedEstimate.estimatedTorches == 48)
assert(quarry.estimateJob(nil) == nil)

-- A nine-chunk plan exercises both the DFS compatibility walk and the
-- optimized route/anchor walk.
local fullPlan = assert(quarry.buildChunkPlan({ width = 40, length = 40, depth = 3, chunkMode = "local" }))
assert(fullPlan.rootKey == "L:0:0" and fullPlan.catalogCount == 9)
assert(fullPlan.selectedChunks == 9 and fullPlan.columns == 1600)
assert(#fullPlan.optimizedRoute == fullPlan.selectedChunks)
assert(fullPlan.optimizedRoute[1] == fullPlan.rootKey)
local optimizedSeen = {}
for index, key in ipairs(fullPlan.optimizedRoute) do
  assert(fullPlan.chunks[key], "optimized route references an unknown chunk")
  assert(not optimizedSeen[key], "optimized route visits a chunk twice")
  optimizedSeen[key] = true
end
for _, key in ipairs(fullPlan.optimizedRoute) do
  local chunk = fullPlan.chunks[key]
  local anchor = chunk.optimizedAnchor
  assert(anchor and anchor.x >= chunk.minX and anchor.x <= chunk.maxX)
  assert(anchor.z >= chunk.minZ and anchor.z <= chunk.maxZ)
end
local optimizedFirst, optimizedWalkCount = {}, 0
for index, step in ipairs(fullPlan.optimizedWalk) do
  assert(fullPlan.chunks[step.key])
  optimizedWalkCount = optimizedWalkCount + (step.first and 1 or 0)
  if step.first then
    assert(not optimizedFirst[step.key], "optimized walk marks first visit twice")
    optimizedFirst[step.key] = true
  end
  if index > 1 then
    assert(adjacent(fullPlan.chunks[fullPlan.optimizedWalk[index - 1].key], fullPlan.chunks[step.key]))
  end
end
assert(optimizedWalkCount == fullPlan.selectedChunks)

local firstVisits = {}
for index, step in ipairs(fullPlan.walk) do
  assert(fullPlan.chunks[step.key])
  if step.first then
    assert(not firstVisits[step.key], "DFS walk first-visits a chunk twice")
    firstVisits[step.key] = true
  end
  if index > 1 then
    assert(adjacent(fullPlan.chunks[fullPlan.walk[index - 1].key], fullPlan.chunks[step.key]))
  end
end
local firstVisitCount = 0
for _ in pairs(firstVisits) do firstVisitCount = firstVisitCount + 1 end
assert(firstVisitCount == fullPlan.selectedChunks)

for key, chunk in pairs(fullPlan.chunks) do
  local count = assert(quarry.chunkCellCount(chunk))
  local cells, previous = {}, nil
  for index = 0, count - 1 do
    local cell = assert(quarry.chunkCell(chunk, index, -2))
    local cellKey = cell.x .. ":" .. cell.z
    assert(not cells[cellKey], "duplicate chunk cell " .. key .. " " .. cellKey)
    cells[cellKey] = true
    assert(cell.y == -2)
    if previous then
      local distance = math.abs(cell.x - previous.x) + math.abs(cell.z - previous.z)
      assert(distance == 1, "chunk-local serpentine path is not adjacent")
    end
    previous = cell
  end
  assert(quarry.chunkCell(chunk, count) == nil)
  local path = assert(quarry.pathToRoot(fullPlan, key))
  assert(path[#path] == fullPlan.rootKey)
  local reverse = assert(quarry.pathFromRoot(fullPlan, key))
  assert(reverse[1] == fullPlan.rootKey and reverse[#reverse] == key)
  local shortest = assert(quarry.shortestChunkPath(fullPlan, fullPlan.rootKey, key))
  assert(shortest[1] == fullPlan.rootKey and shortest[#shortest] == key)
end
assert(quarry.findChunk(fullPlan, 0, 1) == fullPlan.rootKey)
assert(quarry.findChunk(fullPlan, 999, 999) == nil)

local disconnected, disconnectedError = quarry.buildChunkPlan({
  width = 32, length = 48, depth = 1, chunkMode = "local",
  excludedChunks = {
    { mode = "local", cx = 0, cz = 1 },
    { mode = "local", cx = 1, cz = 1 },
  },
})
assert(disconnected == nil and contains(disconnectedError, "disconnected"))
local noEntrance, entranceError = quarry.buildChunkPlan({
  width = 32, length = 32, depth = 1, chunkMode = "local",
  excludedChunks = { { mode = "local", cx = 0, cz = 0 } },
})
assert(noEntrance == nil and contains(entranceError, "entrance"))

-- Grid bounds/page/cell/rectangle helpers use an arbitrary (including
-- negative) origin and preserve a serpentine index in both directions.
local bounds = assert(quarry.gridBounds({ width = 5, length = 7, originX = -2, originZ = -3 }))
assert(bounds.minX == -2 and bounds.maxX == 2 and bounds.minZ == -3 and bounds.maxZ == 3)
assert(bounds.width == 5 and bounds.length == 7 and bounds.cells == 35)
local page1 = assert(quarry.gridPage(bounds, 1, 3, 4))
assert(page1.pageCount == 4 and page1.pagesX == 2 and page1.pagesZ == 2)
assert(page1.minX == -2 and page1.maxX == 0 and page1.minZ == -3 and page1.maxZ == 0)
local page4 = assert(quarry.gridPage(bounds, 4, 3, 4))
assert(page4.pageX == 1 and page4.pageZ == 1 and page4.minX == 1 and page4.maxX == 2)
assert(page4.minZ == 1 and page4.maxZ == 3 and page4.cells == 6)
local pageTable = assert(quarry.gridPage(bounds, 2, { pageWidth = 3, pageHeight = 4 }))
assert(pageTable.pageWidth == 3 and pageTable.pageHeight == 4 and pageTable.pageX == 1 and pageTable.pageZ == 0)
assert(quarry.gridPage(bounds, 99, 3, 4).page == 1)
assert(quarry.gridBounds({ width = 0, length = 1 }) == nil)
assert(quarry.gridBounds({ minX = 2, maxX = 1, minZ = 0, maxZ = 1 }) == nil)

for index = 0, bounds.cells - 1 do
  local cell = assert(quarry.gridCell(bounds, index))
  assert(cell.index == index and cell.x >= bounds.minX and cell.x <= bounds.maxX)
  assert(cell.z >= bounds.minZ and cell.z <= bounds.maxZ)
  local info = assert(quarry.gridCellInfo(bounds, cell.x, cell.z))
  assert(info.inside and info.index == index)
end
assert(quarry.gridCell(bounds, -1) == nil)
local outInfo = assert(quarry.gridCellInfo(bounds, 999, 999))
assert(outInfo.inside == false and outInfo.index == nil)
local rectangle = assert(quarry.selectRectangle(bounds, 0, -4, 5, 0))
assert(rectangle.minX == 0 and rectangle.maxX == 2 and rectangle.minZ == -3 and rectangle.maxZ == 0)
assert(rectangle.count == 12 and rectangle.cellsCount == 12 and rectangle.clipped == true)
assert(#rectangle.cells == rectangle.count and rectangle.selectedCells == rectangle.cells)
local noCells = assert(quarry.selectRectangle(bounds, -2, -3, 2, 3, { includeCells = false }))
assert(noCells.count == 35 and noCells.cells == nil and noCells.clipped == false)
local reversed = assert(quarry.selectRectangle(bounds, { x1 = 2, z1 = 1, x2 = 0, z2 = -1 }))
assert(reversed.minX == 0 and reversed.maxX == 2 and reversed.minZ == -1 and reversed.maxZ == 1)
assert(quarry.selectRectangle(bounds, 99, 99, 100, 100) == nil)

-- World-aligned catalogs retain negative Minecraft chunk coordinates and
-- require a valid calibration.
local calibration = { home = { x = -17, y = 64, z = -17 }, forward = { x = 0, z = -1 } }
local negativeCx, negativeCz, negativeError = quarry.chunkForCell("world", calibration, 0, 1)
assert(not negativeError and negativeCx == -2 and negativeCz == -2)
local worldCatalog = assert(quarry.buildCatalog(64, 64, "world", calibration))
assert(#worldCatalog > 4)
for _, chunk in ipairs(worldCatalog) do
  assert(chunk.mode == "world" and chunk.key:sub(1, 2) == "W:")
end
assert(quarry.buildCatalog(20, 20, "world", nil) == nil)
assert(quarry.buildCatalog(20, 20, "world", { home = {}, forward = { x = 1, z = 0 } }) == nil)
local worldPlan = assert(quarry.buildChunkPlan({ width = 32, length = 32, depth = 2, chunkMode = "world" }, calibration))
assert(worldPlan.mode == "world" and worldPlan.rootKey:sub(1, 2) == "W:")
local worldEstimate = assert(quarry.estimateJob({ width = 2, length = 2, depth = 2, chunkMode = "world" }, calibration))
assert(worldEstimate.plan.mode == "world" and worldEstimate.totalCells == 8)

-- partitionChunks is intentionally world-catalog-only.  Every chunk must be
-- assigned once, and each worker's region remains connected with no overlap.
local assignments = assert(quarry.partitionChunks(worldCatalog, { 101, 202, 303 }))
local catalogByKey, assignedByKey = {}, {}
for _, chunk in ipairs(worldCatalog) do catalogByKey[chunk.key] = chunk end
for _, workerId in ipairs({ 101, 202, 303 }) do
  local assignment = assignments[workerId]
  assert(assignment and #assignment.chunkKeys > 0)
  local owned = {}
  for _, key in ipairs(assignment.chunkKeys) do
    assert(catalogByKey[key] and not assignedByKey[key], "chunk overlap or unknown key")
    assignedByKey[key], owned[key] = workerId, true
  end
  local queue, seen = { assignment.chunkKeys[1] }, { [assignment.chunkKeys[1]] = true }
  local head = 1
  while queue[head] do
    local current = catalogByKey[queue[head]]
    head = head + 1
    for _, candidate in ipairs(assignment.chunkKeys) do
      if not seen[candidate] and adjacent(current, catalogByKey[candidate]) then
        seen[candidate] = true
        queue[#queue + 1] = candidate
      end
    end
  end
  local connectedCount = 0
  for _ in pairs(seen) do connectedCount = connectedCount + 1 end
  assert(connectedCount == #assignment.chunkKeys, "worker assignment is disconnected")
end
local assignmentCount = 0
for _ in pairs(assignedByKey) do assignmentCount = assignmentCount + 1 end
assert(assignmentCount == #worldCatalog)

local localCatalog = assert(quarry.buildCatalog(16, 16, "local"))
local localPartition, localPartitionError = quarry.partitionChunks(localCatalog, { 1 })
assert(localPartition == nil and contains(localPartitionError, "gps_required_world_catalog"))
local invalidWorkers, invalidWorkersError = quarry.partitionChunks(worldCatalog, nil)
assert(invalidWorkers == nil and invalidWorkersError == "invalid_worker_ids")
invalidWorkers, invalidWorkersError = quarry.partitionChunks(worldCatalog, {})
assert(invalidWorkers == nil and invalidWorkersError == "no_workers")
invalidWorkers, invalidWorkersError = quarry.partitionChunks(worldCatalog, { 1, 1 })
assert(invalidWorkers == nil and invalidWorkersError == "duplicate_worker_id")
local oneWorldCatalog = assert(quarry.buildCatalog(16, 16, "world", {
  home = { x = 0, y = 64, z = 0 }, forward = { x = 0, z = -1 },
}))
assert(#oneWorldCatalog == 1)
local tooManyWorkers, tooManyWorkersError = quarry.partitionChunks(oneWorldCatalog, { 1, 2 })
assert(tooManyWorkers == nil and tooManyWorkersError == "more_workers_than_chunks")
local disconnectedCatalog = {
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 0, maxX = 0, minZ = 1, maxZ = 1, cells = 1 },
  { key = "W:2:0", mode = "world", cx = 2, cz = 0, minX = 2, maxX = 2, minZ = 1, maxZ = 1, cells = 1 },
}
local disconnectedPartition, disconnectedPartitionError = quarry.partitionChunks(disconnectedCatalog, { 1 })
assert(disconnectedPartition == nil and disconnectedPartitionError == "chunk_catalog_disconnected")
local malformedCatalog, malformedCatalogError = quarry.partitionChunks({
  { key = "L:0:0", mode = "local", cx = 0, cz = 0, minX = 0, maxX = 0, minZ = 1, maxZ = 1, cells = 1 },
}, { 1 })
assert(malformedCatalog == nil and malformedCatalogError == "gps_required_world_catalog")
local duplicateCatalog, duplicateCatalogError = quarry.partitionChunks({
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 0, maxX = 0, minZ = 1, maxZ = 1, cells = 1 },
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 1, maxX = 1, minZ = 1, maxZ = 1, cells = 1 },
}, { 1 })
assert(duplicateCatalog == nil and duplicateCatalogError == "duplicate_chunk_key")

-- V4 service boundaries use explicit edge transitions and a BFS route.  The
-- old DFS parent tree remains an opt-in fallback for resumed/legacy plans.
assert(quarry.shortestPath == quarry.shortestChunkPath)
assert(quarry.chunkTransition == quarry.edgeTransition)
assert(quarry.neighborTransition == quarry.edgeTransition)
assert(quarry.transitionPoint == quarry.edgeTransition)
assert(quarry.selectChunkAnchor == quarry.chunkAnchor)
assert(quarry.chooseChunkAnchor == quarry.chunkAnchor)
assert(quarry.chunkEntry == quarry.chunkAnchor)
assert(quarry.chunkEntrance == quarry.chunkAnchor)

local horizontalTransition = assert(quarry.edgeTransition(fullPlan, "L:0:0", "L:1:0", -7))
assert(horizontalTransition.fromKey == "L:0:0" and horizontalTransition.toKey == "L:1:0")
assert(horizontalTransition.from.y == -7 and horizontalTransition.to.y == -7)
assert(horizontalTransition.from.x == 15 and horizontalTransition.to.x == 16)
assert(horizontalTransition.from.z == horizontalTransition.to.z)
assert(horizontalTransition.distance == 1)
assert(horizontalTransition[1] ~= horizontalTransition.from and horizontalTransition[2] ~= horizontalTransition.to)
assertSerializable(horizontalTransition, "edge transition")
local coordinateTransition = assert(quarry.edgeTransition(fullPlan, { cx = 0, cz = 0 }, { key = "L:1:0" }, 0))
assert(coordinateTransition.fromKey == "L:0:0" and coordinateTransition.toKey == "L:1:0")
local verticalTransition = assert(quarry.edgeTransition(fullPlan, "L:0:0", "L:0:1", 4))
assert(verticalTransition.from.x == verticalTransition.to.x)
assert(verticalTransition.from.z == 16 and verticalTransition.to.z == 17)
assert(verticalTransition.distance == 1 and verticalTransition.from.y == 4)
local nonAdjacentTransition, nonAdjacentTransitionError = quarry.edgeTransition(fullPlan, "L:0:0", "L:1:1", 0)
assert(nonAdjacentTransition == nil and nonAdjacentTransitionError == "chunks_not_adjacent")
local badTransitionY, badTransitionYError = quarry.edgeTransition(fullPlan, "L:0:0", "L:1:0", "floor")
assert(badTransitionY == nil and badTransitionYError == "invalid_y")

local serviceTargetKey = "L:2:2"
local serviceRoute = assert(quarry.shortestServiceRoute(fullPlan,
  { chunkKey = fullPlan.rootKey, x = 0, y = 9, z = 1 },
  { chunkKey = serviceTargetKey, x = fullPlan.chunks[serviceTargetKey].minX, y = 9, z = fullPlan.chunks[serviceTargetKey].minZ },
  { y = -3 }))
assert(serviceRoute.chunkKeys[1] == fullPlan.rootKey)
assert(serviceRoute.chunkKeys[#serviceRoute.chunkKeys] == serviceTargetKey)
assert(#serviceRoute.chunkKeys == 5, "service route did not use a shortest 3x3 BFS path")
assert(serviceRoute.waypoints[1].kind == "start")
assert(serviceRoute.waypoints[#serviceRoute.waypoints].kind == "target")
assert(serviceRoute.waypoints[1].y == 9 and serviceRoute.waypoints[2].y == -3 and serviceRoute.distance > 0)
assert(serviceRoute.keys ~= serviceRoute.chunkKeys)
assert(serviceRoute.path ~= serviceRoute.chunkKeys)
assert(serviceRoute.transitKeys ~= serviceRoute.chunkKeys)
assertSerializable(serviceRoute, "shortest service route")

-- Disable only the graph edges on a private copy.  Parent pointers still
-- describe the DFS compatibility tree, so the route must report fallback.
local fallbackPlan = { mode = fullPlan.mode, rootKey = fullPlan.rootKey, chunks = {} }
for key, source in pairs(fullPlan.chunks) do
  local copy = {}
  for field, value in pairs(source) do
    if field == "neighbors" then copy.neighbors = {} else copy[field] = value end
  end
  fallbackPlan.chunks[key] = copy
end
local fallbackRoute = assert(quarry.shortestServiceRoute(fallbackPlan,
  { chunkKey = fullPlan.rootKey, x = 0, z = 1 },
  { chunkKey = serviceTargetKey, x = fallbackPlan.chunks[serviceTargetKey].minX, z = fallbackPlan.chunks[serviceTargetKey].minZ },
  { y = -2, allowFallback = true }))
assert(fallbackRoute.fallback == true)
assert(fallbackRoute.chunkKeys[1] == fullPlan.rootKey and fallbackRoute.chunkKeys[#fallbackRoute.chunkKeys] == serviceTargetKey)
local noFallbackRoute, noFallbackError = quarry.shortestServiceRoute(fallbackPlan,
  { chunkKey = fullPlan.rootKey, x = 0, z = 1 },
  { chunkKey = serviceTargetKey, x = fallbackPlan.chunks[serviceTargetKey].minX, z = fallbackPlan.chunks[serviceTargetKey].minZ },
  { allowFallback = false })
assert(noFallbackRoute == nil and noFallbackError == "chunks_disconnected")
local outsideStart, outsideStartError = quarry.shortestServiceRoute(fullPlan,
  { chunkKey = fullPlan.rootKey, x = 16, z = 1 },
  { chunkKey = serviceTargetKey, x = fullPlan.chunks[serviceTargetKey].minX, z = fullPlan.chunks[serviceTargetKey].minZ })
assert(outsideStart == nil and outsideStartError == "pose_outside_chunk")
local outsideTarget, outsideTargetError = quarry.shortestServiceRoute(fullPlan,
  { chunkKey = fullPlan.rootKey, x = 0, z = 1 },
  { chunkKey = serviceTargetKey, x = fullPlan.chunks[serviceTargetKey].maxX + 1, z = fullPlan.chunks[serviceTargetKey].minZ })
assert(outsideTarget == nil and outsideTargetError == "pose_outside_chunk")
local checkpoint = assert(quarry.checkpointWaypoints(fullPlan,
  { chunkKey = serviceTargetKey, x = fullPlan.chunks[serviceTargetKey].minX, y = -5, z = fullPlan.chunks[serviceTargetKey].minZ },
  { y = -5 }))
assert(checkpoint.chunkKeys[1] == fullPlan.rootKey and checkpoint.chunkKeys[#checkpoint.chunkKeys] == serviceTargetKey)
assert(checkpoint.waypoints[1].x == 0 and checkpoint.waypoints[1].z == 1)
assertSerializable(checkpoint, "checkpoint waypoints")
assert(quarry.rootTargetWaypoints == quarry.checkpointWaypoints)
assert(quarry.safeWaypoints == quarry.checkpointWaypoints)
assert(quarry.buildCheckpointRoute == quarry.checkpointWaypoints)
assert(quarry.safeCheckpoint == quarry.checkpointWaypoints)
assert(quarry.rootToTargetCheckpoint == quarry.checkpointWaypoints)

-- V4 aliases are intentionally function aliases, while persisted array and
-- point fields remain independent values.
assert(quarry.serviceRoute == quarry.shortestServiceRoute)
assert(quarry.shortestRoute == quarry.shortestServiceRoute)
assert(quarry.chunkServiceRoute == quarry.shortestServiceRoute)
assert(quarry.shortestServicePath == quarry.shortestServiceRoute)
assert(quarry.jobEstimate == quarry.estimateJob)
assert(quarry.estimate == quarry.estimateJob)
assert(quarry.estimateJobCost == quarry.estimateJob)
assert(quarry.estimateQuarry == quarry.estimateJob)
assert(quarry.getGridBounds == quarry.gridBounds and quarry.bounds == quarry.gridBounds)
assert(quarry.getGridPage == quarry.gridPage and quarry.page == quarry.gridPage)
assert(quarry.gridPageInfo == quarry.gridPage and quarry.pageInfo == quarry.gridPage)
assert(quarry.getGridCell == quarry.gridCell)
assert(quarry.getCellInfo == quarry.gridCellInfo and quarry.cellInfo == quarry.gridCellInfo)
assert(quarry.rectangleSelection == quarry.selectRectangle)
assert(quarry.selectRect == quarry.selectRectangle and quarry.rectangle == quarry.selectRectangle)
assert(quarry.selectRectangleCells == quarry.selectRectangle)
assert(quarry.assignWorkers == quarry.partitionChunks)
assert(quarry.splitWorkers == quarry.partitionChunks)
assert(quarry.splitWorkerChunks == quarry.partitionChunks)
assert(quarry.partitionWorkers == quarry.partitionChunks)
assert(quarry.assignChunkWorkers == quarry.partitionChunks)
assert(quarry.splitWorkerAssignments == quarry.partitionChunks)

-- World-seed catalogs preserve negative Minecraft chunk coordinates, clone the
-- calibration metadata, and accept both descriptor and seed-first forms.
assert(quarry.catalogFromWorldSeed == quarry.buildWorldCatalog)
assert(quarry.worldCatalog == quarry.buildWorldCatalog)
assert(quarry.buildGpsCatalog == quarry.buildWorldCatalog)
assert(quarry.buildCatalogFromWorldSeed == quarry.buildWorldCatalog)
assert(quarry.worldCatalogFromSeed == quarry.buildWorldCatalog)
local negativeSeedCatalog = assert(quarry.buildWorldCatalog(32, 32, calibration))
assert(negativeSeedCatalog.rootKey == "W:-2:-2")
assert(negativeSeedCatalog.referenceCalibration ~= calibration)
assert(negativeSeedCatalog.calibrationSeed ~= calibration)
assert(negativeSeedCatalog.referenceCalibration.home ~= calibration.home)
assert(negativeSeedCatalog.referenceCalibration.forward ~= calibration.forward)
for _, chunk in ipairs(negativeSeedCatalog) do
  assert(chunk.mode == "world" and chunk.key:match("^W:%-?%d+:%-?%d+$"))
end
local descriptorCatalog = assert(quarry.buildWorldCatalog({ width = 32, length = 32, worldSeed = calibration }))
local seedFirstCatalog = assert(quarry.buildWorldCatalog(calibration, 32, 32))
local optionCalibrationCatalog = assert(quarry.buildWorldCatalog(16, 16, nil, { calibration = calibration }))
assert(descriptorCatalog.rootKey == negativeSeedCatalog.rootKey)
assert(seedFirstCatalog.rootKey == negativeSeedCatalog.rootKey)
assert(optionCalibrationCatalog.rootKey == "W:-2:-2")
assert(#descriptorCatalog == #negativeSeedCatalog and #seedFirstCatalog == #negativeSeedCatalog)
local positionedSeedCatalog = assert(quarry.buildWorldCatalog(16, 16,
  { position = { x = -17, y = 70, z = -17 }, forward = { x = 0, z = -1 } }))
assert(positionedSeedCatalog.rootKey == "W:-2:-2")
assert(quarry.buildWorldCatalog(16, 16, nil) == nil)
assert(quarry.buildWorldCatalog(16, 16, { home = { x = 0, y = 64, z = 0 }, forward = { x = 1, z = 1 } }) == nil)
assert(quarry.buildWorldCatalog({ width = 16, length = 16, worldSeed = { position = { x = 0, z = 0 }, forward = { x = 0, z = 0 } } }) == nil)

-- All four cardinal orientations must round-trip through the world/local
-- transform, including the table-pose overload used by worker rebasing.
local rotationCalibrations = {
  { x = 0, z = -1 }, { x = 1, z = 0 }, { x = 0, z = 1 }, { x = -1, z = 0 },
}
for index, forward in ipairs(rotationCalibrations) do
  local rotatedCalibration = { home = { x = 37, y = 80, z = -29 }, forward = forward }
  local localX, localZ = index * 3 - 7, index * 5 - 9
  local worldPoint = assert(quarry.referenceLocalToWorld(rotatedCalibration, localX, localZ))
  local inverse = assert(quarry.inverseWorldToLocal(rotatedCalibration, worldPoint.x, worldPoint.z))
  assert(inverse.x == localX and inverse.z == localZ, "inverse rotation mismatch")
  local inversePose = assert(quarry.inverseWorldToLocal(rotatedCalibration, { x = worldPoint.x, z = worldPoint.z }))
  assert(inversePose.x == localX and inversePose.z == localZ)
  local directX, directZ = quarry.worldToLocalXZ(rotatedCalibration, worldPoint.x, worldPoint.z)
  assert(directX == localX and directZ == localZ)
end
assert(quarry.worldToLocal == quarry.inverseWorldToLocal)
assert(quarry.inverseWorldToLocal(nil, 0, 0) == nil)
assert(quarry.referenceLocalToWorld(nil, 0, 1) == nil)
assert(quarry.inverseWorldToLocal(calibration, "x", 0) == nil)

-- Group partitioning requires one unique, in-catalog bay chunk per worker when
-- bay metadata is present.  A 64x64 catalog is aligned to four world chunks
-- on each axis so bay-aligned stripes can own the complete catalog.
local groupCalibration = { home = { x = -1, y = 64, z = 0 }, forward = { x = 1, z = 0 } }
local groupCatalog = assert(quarry.buildWorldCatalog(64, 64, groupCalibration))
local groupChunks = catalogMap(groupCatalog)
local groupWorkers = {
  { id = "bay-1", bay = { x = 8, z = 8 }, homeY = 64 },
  { id = "bay-2", bay = { x = 24, z = 24 }, homeY = 64 },
  { id = "bay-3", bay = { x = 40, z = 40 }, homeY = 64 },
}
local stripeGroup = assert(quarry.partitionGroup(groupCatalog, groupWorkers, {
  groupJobId = "group-v4-stripe", strategy = "stripe", stripeAxis = "x", bottomY = 62,
}))
assert(stripeGroup.strategy == "stripe" and stripeGroup.stripeAxis == "x")
assert(#stripeGroup.assignments == #groupWorkers and #stripeGroup.unassigned == 0)
assert(stripeGroup.byWorker ~= stripeGroup.assignments)
local stripeSeen, stripeBayChunks = {}, {}
for index, worker in ipairs(groupWorkers) do
  local assignment = stripeGroup.assignments[index]
  assert(assignment.workerId == worker.id)
  local bayKey = "W:" .. math.floor(worker.bay.x / 16) .. ":" .. math.floor(worker.bay.z / 16)
  assert(assignment.seedKey == bayKey and containsKey(assignment.chunkKeys, bayKey), "bay seed is not owned")
  assert(#assignment.transitKeys == 0 and #assignment.transitLeaseKeys == 0)
  assert(assignment.leaseId == "group-v4-stripe:" .. worker.id)
  assert(assignment.leaseKeys ~= assignment.chunkKeys)
  assert(assignment.transitLeaseKeys ~= assignment.transitKeys)
  for leaseIndex, leaseKey in ipairs(assignment.leaseKeys) do
    assert(leaseKey == assignment.chunkKeys[leaseIndex] and not leaseKey:find(worker.id .. ":", 1, true),
      "lease keys must remain global chunk keys")
  end
  for _, key in ipairs(assignment.chunkKeys) do
    assert(groupChunks[key] and not stripeSeen[key], "stripe assignment overlap or unknown key")
    stripeSeen[key] = assignment.workerId
  end
  assertConnected(groupChunks, assignment.chunkKeys, "bay stripe " .. worker.id)
  stripeBayChunks[bayKey] = true
end
local stripeCount = 0
for _ in pairs(stripeSeen) do stripeCount = stripeCount + 1 end
assert(stripeCount == #groupCatalog)
for _, key in ipairs(stripeGroup.unassigned) do assert(not stripeSeen[key]) end
assertSerializable(stripeGroup, "bay-aligned group partition")
assert(stripeGroup.byWorker["bay-1"] ~= stripeGroup.assignments[1])
assert(stripeGroup.byWorker["bay-1"].chunkKeys ~= stripeGroup.assignments[1].chunkKeys)
assert(quarry.groupPartition == quarry.partitionGroup)
assert(quarry.splitGroupWorkers == quarry.partitionGroup)
assert(quarry.assignGroupWorkers == quarry.partitionGroup)
assert(quarry.partitionWorkersGroup == quarry.partitionGroup)

local duplicateBayGroup, duplicateBayError = quarry.partitionGroup(groupCatalog, {
  { id = "dup-a", bay = { x = 8, z = 8 } },
  { id = "dup-b", bay = { x = 8, z = 8 } },
}, { strategy = "stripe" })
assert(duplicateBayGroup == nil and contains(duplicateBayError, "duplicate_worker_bay_chunk"))
local missingBayGroup, missingBayError = quarry.partitionGroup(groupCatalog, {
  { id = "has-bay", bay = { x = 8, z = 8 } },
  { id = "missing-bay" },
}, { strategy = "stripe" })
assert(missingBayGroup == nil and contains(missingBayError, "worker_bay_required"))
local outsideBayGroup, outsideBayError = quarry.partitionGroup(groupCatalog, {
  { id = "outside", bay = { x = 999, z = 999 } },
}, { strategy = "stripe" })
assert(outsideBayGroup == nil and contains(outsideBayError, "worker_bay_outside_catalog"))
local duplicateGroupCatalog, duplicateGroupCatalogError = quarry.partitionGroup({
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 0, maxX = 15, minZ = 0, maxZ = 15, cells = 256 },
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 0, maxX = 15, minZ = 16, maxZ = 31, cells = 256 },
}, { "duplicate-catalog-worker" })
assert(duplicateGroupCatalog == nil and duplicateGroupCatalogError == "duplicate_chunk_key")
local missingGroupField, missingGroupFieldError = quarry.partitionGroup({
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 0, maxX = 15, minZ = 0, maxZ = 15 },
}, { "missing-cells-worker" })
assert(missingGroupField == nil and missingGroupFieldError == "invalid_chunk_catalog")

-- round_robin is a compatibility spelling for graph growth.  Every owner
-- remains connected and the global catalog is covered exactly once.
local graphGroup = assert(quarry.partitionGroup(groupCatalog, { "rr-a", "rr-b", "rr-c" }, {
  groupJobId = "group-v4-graph", strategy = "round_robin",
}))
assert(graphGroup.strategy == "graph" and #graphGroup.unassigned == 0)
local graphSeen = {}
for _, assignment in ipairs(graphGroup.assignments) do
  assert(#assignment.chunkKeys > 0)
  assertConnected(groupChunks, assignment.chunkKeys, "round_robin " .. tostring(assignment.workerId))
  for _, key in ipairs(assignment.chunkKeys) do
    assert(groupChunks[key] and not graphSeen[key], "round_robin overlap or unknown key")
    graphSeen[key] = true
  end
end
local graphCount = 0
for _ in pairs(graphSeen) do graphCount = graphCount + 1 end
assert(graphCount == #groupCatalog)
assertSerializable(graphGroup, "round_robin group partition")

-- Assignment objects returned by partitionGroup are accepted directly, with
-- their mine/transit/seed fields used without sharing the source arrays.
local assignmentObjectPlan = assert(quarry.buildAssignedChunkPlan(groupCatalog, stripeGroup.assignments[1], {
  referenceRootKey = groupCatalog.rootKey,
}))
assert(assignmentObjectPlan.workerId == stripeGroup.assignments[1].workerId)
assert(assignmentObjectPlan.seedKey == stripeGroup.assignments[1].seedKey)
assert(#assignmentObjectPlan.assignedKeys == #stripeGroup.assignments[1].chunkKeys)
assertSerializable(assignmentObjectPlan, "assignment-object worker plan")

-- Assigned worker plans rebase a shared reference catalog into the worker's
-- offset/rotation, while allowing each worker to mine its own bay chunk.
local referenceCalibration = { home = { x = -1, y = 64, z = 0 }, forward = { x = 1, z = 0 } }
local referenceCatalog = assert(quarry.buildWorldCatalog(32, 32, referenceCalibration))
local referenceChunks = catalogMap(referenceCatalog)
local referenceRootKey = assert(referenceCatalog.rootKey)
local ownBayKey = "W:1:1"
assert(referenceChunks[referenceRootKey] and referenceChunks[ownBayKey])
local referenceRootBounds = {
  minX = referenceChunks[referenceRootKey].minX,
  maxX = referenceChunks[referenceRootKey].maxX,
  minZ = referenceChunks[referenceRootKey].minZ,
  maxZ = referenceChunks[referenceRootKey].maxZ,
}
local offsetWorkerCalibration = { home = { x = 3, y = 64, z = 3 }, forward = { x = 1, z = 0 } }
local offsetPlan = assert(quarry.buildAssignedChunkPlan(referenceCatalog, { referenceRootKey }, {
  referenceCalibration = referenceCalibration,
  referenceRootKey = referenceRootKey,
  workerCalibration = offsetWorkerCalibration,
  seedKey = referenceRootKey,
  dockKey = referenceRootKey,
  y = -12,
}))
assert(offsetPlan.mode == "world" and offsetPlan.rootKey == referenceRootKey)
assert(offsetPlan.dockKey == referenceRootKey and offsetPlan.entranceKey == referenceRootKey)
assert(offsetPlan.seedKey == referenceRootKey and offsetPlan.selectedChunks == 1)
assert(#offsetPlan.assignedKeys == 1 and offsetPlan.assignedKeys[1] == referenceRootKey)
local offsetChunk = assert(offsetPlan.chunks[referenceRootKey])
assert(offsetChunk.mine == true and offsetChunk.transit ~= true)
assert(offsetChunk.referenceMinX == referenceRootBounds.minX)
assert(offsetChunk.anchor and offsetChunk.anchor.x >= offsetChunk.minX and offsetChunk.anchor.x <= offsetChunk.maxX)
assert(offsetChunk.anchor.z >= offsetChunk.minZ and offsetChunk.anchor.z <= offsetChunk.maxZ)
local offsetWorldCorner = assert(quarry.referenceLocalToWorld(referenceCalibration, referenceRootBounds.minX, referenceRootBounds.minZ))
local offsetLocalCorner = assert(quarry.inverseWorldToLocal(offsetWorkerCalibration, offsetWorldCorner.x, offsetWorldCorner.z))
assert(offsetLocalCorner.x >= offsetChunk.minX and offsetLocalCorner.x <= offsetChunk.maxX)
assert(offsetLocalCorner.z >= offsetChunk.minZ and offsetLocalCorner.z <= offsetChunk.maxZ)
assert(#offsetPlan.walk > 0 and offsetPlan.walk[1].key == referenceRootKey)
assert(#offsetPlan.optimizedRoute == 1 and offsetPlan.optimizedRoute[1] == referenceRootKey)
assert(offsetPlan.columns == offsetChunk.cells)
assert(offsetPlan.serviceRoute.chunkKeys[1] == referenceRootKey and offsetPlan.serviceRoute.chunkKeys[#offsetPlan.serviceRoute.chunkKeys] == referenceRootKey)
assert(offsetPlan.referenceCalibration ~= referenceCalibration and offsetPlan.workerCalibration ~= offsetWorkerCalibration)
assert(referenceChunks[referenceRootKey].minX == referenceRootBounds.minX)
assert(referenceChunks[referenceRootKey].maxX == referenceRootBounds.maxX)
assert(referenceChunks[referenceRootKey].minZ == referenceRootBounds.minZ)
assert(referenceChunks[referenceRootKey].maxZ == referenceRootBounds.maxZ)

local rotatedWorkerCalibration = { home = { x = 24, y = 64, z = 24 }, forward = { x = 0, z = 1 } }
local rotatedPlan = assert(quarry.buildAssignedChunkPlan(referenceCatalog, { ownBayKey }, {
  referenceCalibration = referenceCalibration,
  referenceRootKey = referenceRootKey,
  workerCalibration = rotatedWorkerCalibration,
  seedKey = ownBayKey,
  dockKey = ownBayKey,
  y = -20,
}))
assert(rotatedPlan.rootKey == ownBayKey and rotatedPlan.dockKey == ownBayKey)
assert(rotatedPlan.seedKey == ownBayKey and rotatedPlan.assignedKeys[1] == ownBayKey)
local rotatedChunk = assert(rotatedPlan.chunks[ownBayKey])
assert(rotatedChunk.mine == true and rotatedChunk.transit ~= true)
assert(rotatedChunk.referenceMinX == referenceChunks[ownBayKey].minX)
assert(rotatedChunk.referenceMaxX == referenceChunks[ownBayKey].maxX)
assert(rotatedChunk.referenceMinZ == referenceChunks[ownBayKey].minZ)
assert(rotatedChunk.referenceMaxZ == referenceChunks[ownBayKey].maxZ)
assert(rotatedChunk.minX ~= rotatedChunk.referenceMinX or rotatedChunk.minZ ~= rotatedChunk.referenceMinZ)
assert(rotatedChunk.anchor and rotatedChunk.anchor.x >= rotatedChunk.minX and rotatedChunk.anchor.x <= rotatedChunk.maxX)
assert(rotatedChunk.anchor.z >= rotatedChunk.minZ and rotatedChunk.anchor.z <= rotatedChunk.maxZ)
local rotatedWorldCorner = assert(quarry.referenceLocalToWorld(referenceCalibration,
  rotatedChunk.referenceMinX, rotatedChunk.referenceMinZ))
local rotatedLocalCorner = assert(quarry.inverseWorldToLocal(rotatedWorkerCalibration,
  rotatedWorldCorner.x, rotatedWorldCorner.z))
assert(rotatedLocalCorner.x >= rotatedChunk.minX and rotatedLocalCorner.x <= rotatedChunk.maxX)
assert(rotatedLocalCorner.z >= rotatedChunk.minZ and rotatedLocalCorner.z <= rotatedChunk.maxZ)
assert(#rotatedPlan.walk > 0 and rotatedPlan.walk[1].key == ownBayKey)
assert(rotatedPlan.columns == rotatedChunk.cells and rotatedPlan.selectedChunks == 1)

-- A worker may mine only its assigned chunk and cross only explicitly leased
-- transit chunks from the dock.  The bridge below is the deterministic BFS
-- neighbor between the canonical root and the diagonal target.
local bridgeKey = "W:1:0"
local explicitTransitPlan = assert(quarry.buildAssignedChunkPlan(referenceCatalog, { ownBayKey }, {
  referenceRootKey = referenceRootKey,
  rootKey = referenceRootKey,
  dockKey = referenceRootKey,
  seedKey = ownBayKey,
  transitKeys = { referenceRootKey, bridgeKey },
  y = -4,
}))
assert(explicitTransitPlan.rootKey == ownBayKey and explicitTransitPlan.dockKey == referenceRootKey)
assert(#explicitTransitPlan.assignedKeys == 1 and explicitTransitPlan.assignedKeys[1] == ownBayKey)
assert(containsKey(explicitTransitPlan.transitKeys, referenceRootKey))
assert(containsKey(explicitTransitPlan.transitKeys, bridgeKey))
assert(explicitTransitPlan.chunks[ownBayKey].mine == true and explicitTransitPlan.chunks[ownBayKey].transit ~= true)
assert(explicitTransitPlan.chunks[referenceRootKey].mine ~= true and explicitTransitPlan.chunks[referenceRootKey].transit == true)
assert(explicitTransitPlan.chunks[bridgeKey].mine ~= true and explicitTransitPlan.chunks[bridgeKey].transit == true)
assert(explicitTransitPlan.transitRouteKeys[1] == referenceRootKey)
assert(explicitTransitPlan.transitRouteKeys[#explicitTransitPlan.transitRouteKeys] == ownBayKey)
assert(explicitTransitPlan.serviceRoute.chunkKeys[1] == referenceRootKey)
assert(explicitTransitPlan.serviceRoute.chunkKeys[#explicitTransitPlan.serviceRoute.chunkKeys] == ownBayKey)
assert(explicitTransitPlan.serviceRoute.waypoints[1].chunkKey == referenceRootKey)
assert(explicitTransitPlan.serviceRoute.waypoints[#explicitTransitPlan.serviceRoute.waypoints].chunkKey == ownBayKey)
assert(explicitTransitPlan.columns == explicitTransitPlan.chunks[ownBayKey].cells)
for key, chunk in pairs(explicitTransitPlan.chunks) do
  assert(chunk.anchor and chunk.anchor.x >= chunk.minX and chunk.anchor.x <= chunk.maxX,
    "assigned/transit anchor x is outside " .. key)
  assert(chunk.anchor.z >= chunk.minZ and chunk.anchor.z <= chunk.maxZ,
    "assigned/transit anchor z is outside " .. key)
end

local overlapTransitPlan, overlapTransitError = quarry.buildAssignedChunkPlan(referenceCatalog, { ownBayKey }, {
  rootKey = referenceRootKey, dockKey = referenceRootKey, seedKey = ownBayKey,
  transitKeys = { ownBayKey },
})
assert(overlapTransitPlan == nil and contains(overlapTransitError, "transit_overlaps_assigned"))
local missingBridgePlan, missingBridgeError = quarry.buildAssignedChunkPlan(referenceCatalog, { ownBayKey }, {
  rootKey = referenceRootKey, dockKey = referenceRootKey, seedKey = ownBayKey,
  transitKeys = { referenceRootKey },
})
assert(missingBridgePlan == nil and contains(missingBridgeError, "chunks_disconnected"))
local noDockLeasePlan, noDockLeaseError = quarry.buildAssignedChunkPlan(referenceCatalog, { ownBayKey }, {
  rootKey = referenceRootKey, dockKey = referenceRootKey, seedKey = ownBayKey,
})
assert(noDockLeasePlan == nil and contains(noDockLeaseError, "dock_requires_explicit_transit"))
local unknownAssignedPlan, unknownAssignedError = quarry.buildAssignedChunkPlan(referenceCatalog, { "W:99:99" }, {
  rootKey = referenceRootKey, dockKey = referenceRootKey, seedKey = "W:99:99", transitKeys = { referenceRootKey },
})
assert(unknownAssignedPlan == nil and contains(unknownAssignedError, "unknown_assigned_chunk"))
local unknownTransitPlan, unknownTransitError = quarry.buildAssignedChunkPlan(referenceCatalog, { ownBayKey }, {
  rootKey = referenceRootKey, dockKey = referenceRootKey, seedKey = ownBayKey,
  transitKeys = { referenceRootKey, "W:99:99" },
})
assert(unknownTransitPlan == nil and contains(unknownTransitError, "unknown_transit_chunk"))
local noAssignedPlan, noAssignedError = quarry.buildAssignedChunkPlan(referenceCatalog, {}, {})
assert(noAssignedPlan == nil and noAssignedError == "no_assigned_chunks")
local disconnectedAssignedPlan, disconnectedAssignedError = quarry.buildAssignedChunkPlan(referenceCatalog,
  { referenceRootKey, ownBayKey }, { rootKey = referenceRootKey, dockKey = referenceRootKey, seedKey = referenceRootKey })
assert(disconnectedAssignedPlan == nil and disconnectedAssignedError == "assigned_chunks_disconnected")
local disconnectedSourcePlan, disconnectedSourceError = quarry.buildAssignedChunkPlan({
  { key = "W:0:0", mode = "world", cx = 0, cz = 0, minX = 0, maxX = 15, minZ = 0, maxZ = 15, cells = 256 },
  { key = "W:2:0", mode = "world", cx = 2, cz = 0, minX = 32, maxX = 47, minZ = 0, maxZ = 15, cells = 256 },
}, { "W:0:0" }, { rootKey = "W:0:0", dockKey = "W:0:0", seedKey = "W:0:0" })
assert(disconnectedSourcePlan == nil and disconnectedSourceError == "chunk_catalog_disconnected")

-- Returned assigned plans and all compatibility aliases must be safe to save
-- directly through the CC serializer; no arrays or nested point tables may be
-- shared by two fields.
assertSerializable(offsetPlan, "offset assigned plan")
assertSerializable(rotatedPlan, "rotated assigned plan")
assertSerializable(explicitTransitPlan, "transit assigned plan")
assert(explicitTransitPlan.assignedKeys ~= explicitTransitPlan.mineChunkKeys)
assert(explicitTransitPlan.serviceRoute.chunkKeys ~= explicitTransitPlan.serviceRoute.keys)
assert(explicitTransitPlan.serviceRoute.keys ~= explicitTransitPlan.serviceRoute.path)
assert(explicitTransitPlan.serviceRoute.transitKeys ~= explicitTransitPlan.serviceRoute.chunkKeys)
assert(quarry.assignedChunkPlan == quarry.buildAssignedChunkPlan)
assert(quarry.buildWorkerChunkPlan == quarry.buildAssignedChunkPlan)
assert(quarry.planAssignedChunks == quarry.buildAssignedChunkPlan)
assert(quarry.planAssignment == quarry.buildAssignedChunkPlan)
assert(quarry.buildAssignmentPlan == quarry.buildAssignedChunkPlan)

print("quarry V4 estimates, walks, grid helpers, world coordinates, routes, group partitions, and assigned plans passed (" .. tostring(#cases) .. " legacy cases)")
