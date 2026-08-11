-- CC Miner V2 - generated controller source loader.
local parts = {
  "/ccminer/controller_parts/01.part",
  "/ccminer/controller_parts/02.part",
  "/ccminer/controller_parts/03.part",
}
local source = {}
for index, path in ipairs(parts) do
  local handle = fs.open(path, "r")
  if not handle then error("Missing runtime part: " .. path, 0) end
  source[index] = handle.readAll()
  handle.close()
end
local loader = loadstring or load
local program, compileError = loader(table.concat(source), "@/ccminer/controller.assembled.lua")
if not program then error("Cannot assemble controller: " .. tostring(compileError), 0) end
return program(...)
