-- CC Miner V3 split offline installer loader
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
  "14.part",
  "15.part",
  "16.part",
  "17.part",
  "18.part",
  "19.part",
  "20.part",
  "21.part",
  "22.part",
  "23.part",
  "24.part",
  "25.part",
  "26.part",
  "27.part",
  "28.part",
  "29.part",
  "30.part",
  "31.part",
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
