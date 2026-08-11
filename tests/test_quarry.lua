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

print("quarry V3 estimates, walks, grid helpers, world coordinates, and partitions passed (" .. tostring(#cases) .. " legacy cases)")
