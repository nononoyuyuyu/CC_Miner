local quarry = dofile(arg[1] .. "/src/ccminer/lib/quarry.lua")

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
  local total = quarry.total(width, length, depth)
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

local catalog = assert(quarry.buildCatalog(40, 40, "local"))
assert(#catalog == 9, "40x40 local quarry should intersect 9 relative chunks")

local plan = assert(quarry.buildChunkPlan({
  width = 40,
  length = 40,
  depth = 3,
  chunkMode = "local",
  excludedChunks = { { mode = "local", cx = 1, cz = 1 } },
}))
assert(plan.excludedCount == 1)
assert(plan.catalogCount == 9)
assert(plan.columns == 40 * 40 - 16 * 16)
assert(plan.rootKey == "L:0:0")
assert(plan.chunks["L:1:1"] == nil)
assert(plan.walk[1].key == plan.rootKey)
assert(plan.walk[#plan.walk].key == plan.rootKey)

local firstVisits = {}
for index, step in ipairs(plan.walk) do
  assert(plan.chunks[step.key], "walk references excluded or missing chunk")
  if step.first then
    assert(not firstVisits[step.key], "chunk first-visited twice")
    firstVisits[step.key] = true
  end
  if index > 1 then
    local previous = plan.walk[index - 1].key
    if previous ~= step.key then
      local adjacent = false
      for _, neighbor in ipairs(plan.chunks[previous].neighbors) do if neighbor == step.key then adjacent = true end end
      assert(adjacent, "chunk walk crossed a non-adjacent boundary")
    end
  end
end
local visitedCount = 0
for _ in pairs(firstVisits) do visitedCount = visitedCount + 1 end
assert(visitedCount == 8)

for key, chunk in pairs(plan.chunks) do
  local count = quarry.chunkCellCount(chunk)
  local cells, previous = {}, nil
  for index = 0, count - 1 do
    local cell = assert(quarry.chunkCell(chunk, index, -2))
    local cellKey = cell.x .. ":" .. cell.z
    assert(not cells[cellKey], "duplicate chunk cell " .. key .. " " .. cellKey)
    cells[cellKey] = true
    if previous then
      local distance = math.abs(cell.x - previous.x) + math.abs(cell.z - previous.z)
      assert(distance == 1, "chunk-local serpentine path is not adjacent")
    end
    previous = cell
  end
  local path = assert(quarry.pathToRoot(plan, key))
  assert(path[#path] == plan.rootKey)
  local reverse = assert(quarry.pathFromRoot(plan, key))
  assert(reverse[1] == plan.rootKey and reverse[#reverse] == key)
end

local disconnected, disconnectedError = quarry.buildChunkPlan({
  width = 32,
  length = 48,
  depth = 1,
  chunkMode = "local",
  excludedChunks = {
    { mode = "local", cx = 0, cz = 1 },
    { mode = "local", cx = 1, cz = 1 },
  },
})
assert(disconnected == nil)
assert(tostring(disconnectedError):find("disconnected", 1, true))

local noEntrance, entranceError = quarry.buildChunkPlan({
  width = 32,
  length = 32,
  depth = 1,
  chunkMode = "local",
  excludedChunks = { { mode = "local", cx = 0, cz = 0 } },
})
assert(noEntrance == nil)
assert(tostring(entranceError):find("entrance", 1, true))

local calibration = { home = { x = -1, y = 64, z = -1 }, forward = { x = 0, z = -1 } }
local worldCatalog = assert(quarry.buildCatalog(20, 20, "world", calibration))
assert(#worldCatalog >= 4)
for _, chunk in ipairs(worldCatalog) do
  assert(chunk.mode == "world")
  assert(chunk.key:sub(1, 2) == "W:")
end
assert(quarry.buildCatalog(20, 20, "world", nil) == nil)

print("quarry path and chunk-plan tests passed (" .. tostring(#cases) .. " legacy cases)")
