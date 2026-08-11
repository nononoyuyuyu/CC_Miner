-- CC Miner V2 split offline installer loader
-- Keep the adjacent ccminer-offline.parts directory when transferring this file.
local partNames = {
  "01.part",
  "02.part",
  "03.part",
  "04.part",
  "05.part",
  "06.part",
  "07.part",
  "08.part",
  "09.part",
  "10.part",
  "11.part",
  "12.part",
  "13.part",
}
local running = shell and shell.getRunningProgram and shell.getRunningProgram() or "ccminer-offline.lua"
local base = fs.getDir(running)
local partDir = fs.combine(base, "ccminer-offline.parts")
local source = {}
for index, name in ipairs(partNames) do
  local path = fs.combine(partDir, name)
  local handle = fs.open(path, "r")
  if not handle then error("Missing offline installer part: " .. path, 0) end
  source[index] = handle.readAll()
  handle.close()
end
local loadSource = loadstring or load
local program, compileError = loadSource(table.concat(source), "@ccminer-offline.assembled.lua")
if not program then error("Cannot assemble offline installer: " .. tostring(compileError), 0) end
return program(...)
