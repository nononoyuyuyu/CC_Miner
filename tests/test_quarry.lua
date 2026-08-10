local quarry = dofile(arg[1] .. "/src/ccminer/lib/quarry.lua")

local cases = {
  { 1, 1, 1 },
  { 1, 8, 3 },
  { 8, 1, 4 },
  { 2, 2, 2 },
  { 7, 13, 5 },
  { 8, 32, 16 },
}

for width = 1, 6 do
  for length = 1, 7 do
    for depth = 1, 4 do
      cases[#cases + 1] = { width, length, depth }
    end
  end
end

for _, case in ipairs(cases) do
  local width, length, depth = case[1], case[2], case[3]
  local total = quarry.total(width, length, depth)
  local seen = {}
  local previous = { x = 0, y = 0, z = 0 }
  for index = 0, total - 1 do
    local cell, err = quarry.cell(width, length, depth, index)
    assert(cell, err)
    assert(cell.x >= 0 and cell.x < width)
    assert(cell.z >= 1 and cell.z <= length)
    assert(cell.y <= 0 and cell.y > -depth)
    local key = cell.x .. ":" .. cell.y .. ":" .. cell.z
    assert(not seen[key], "duplicate cell " .. key)
    seen[key] = true
    local distance = math.abs(cell.x - previous.x) + math.abs(cell.y - previous.y) + math.abs(cell.z - previous.z)
    assert(distance == 1, ("non-adjacent path at %d for %dx%dx%d: distance=%d"):format(index, width, length, depth, distance))
    previous = cell
  end
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  assert(count == total)
  assert(quarry.cell(width, length, depth, -1) == nil)
  assert(quarry.cell(width, length, depth, total) == nil)
end

print("quarry path tests passed (" .. tostring(#cases) .. " cases)")
