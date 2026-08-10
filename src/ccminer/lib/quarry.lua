-- CC Miner V2 - deterministic 3D quarry path
-- The path is a continuous serpentine route through every block in a box.

local M = {}

function M.total(width, length, depth)
  return width * length * depth
end

function M.cell(width, length, depth, index)
  if index < 0 or index >= M.total(width, length, depth) then
    return nil, "index_out_of_range"
  end
  local perLayer = width * length
  local layer = math.floor(index / perLayer)
  local offset = index % perLayer
  if layer % 2 == 1 then offset = perLayer - 1 - offset end
  local row = math.floor(offset / length)
  local column = offset % length
  local z
  if row % 2 == 0 then z = column + 1 else z = length - column end
  return { x = row, y = -layer, z = z }
end

function M.cellForJob(job, index)
  return M.cell(job.width, job.length, job.depth, index)
end

return M
