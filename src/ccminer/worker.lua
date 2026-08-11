-- CC Miner V4 - generated worker source loader.
local parts = {
  "/ccminer/worker_parts/01.part",
  "/ccminer/worker_parts/02.part",
  "/ccminer/worker_parts/03.part",
  "/ccminer/worker_parts/04.part",
  "/ccminer/worker_parts/05.part",
}
local source = {}
for index, path in ipairs(parts) do
  local handle = fs.open(path, "r")
  if not handle then error("Missing runtime part: " .. path, 0) end
  source[index] = handle.readAll()
  handle.close()
end
local loader = loadstring or load
local program, compileError = loader(table.concat(source), "@/ccminer/worker.assembled.lua")
if not program then error("Cannot assemble worker: " .. tostring(compileError), 0) end
return program(...)
