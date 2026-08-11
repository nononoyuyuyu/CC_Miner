local root = arg[1]
local realDofile = dofile

fs = { exists = function() return false end }
peripheral = { getNames = function() return {} end }
os.getComputerID = function() return 42 end
os.epoch = function() return 123456 end

local common = realDofile(root .. "/src/ccminer/lib/common.lua")
dofile = function(path)
  if path == "/ccminer/lib/common.lua" then return common end
  return realDofile(path)
end

local protocol = realDofile(root .. "/src/ccminer/lib/protocol.lua")
local message = protocol.message("command", "shared-key", { command = "pause" }, 7)
assert(protocol.validate(message, "shared-key", 7, 42))

local wrongTarget = common.copy(message)
wrongTarget.target = 8
assert(not protocol.validate(wrongTarget, "shared-key", 7, 42))

local badPayload = common.copy(message)
badPayload.payload = "pause"
assert(not protocol.validate(badPayload, "shared-key", 7, 42))

local badSender = common.copy(message)
badSender.sender = 99
assert(not protocol.validate(badSender, "shared-key", 7, 42))

local badVersion = common.copy(message)
badVersion.version = "0.0.0"
assert(not protocol.validate(badVersion, "shared-key", 7, 42))

print("protocol validation tests passed")
