local root = arg[1]
local realDofile = dofile

-- protocol.lua loads common through its CC:Tweaked absolute path.  Keep the
-- test host-independent by supplying a tiny fs and intercepting that load.
fs = { exists = function() return false end }
peripheral = { getNames = function() return {} end }
os.getComputerID = function() return 42 end
os.getComputerLabel = function() return "ProtocolTest" end
os.epoch = function() return 123456 end

local common = realDofile(root .. "/src/ccminer/lib/common.lua")
dofile = function(path)
  if path == "/ccminer/lib/common.lua" then return common end
  return realDofile(path)
end

local protocol = realDofile(root .. "/src/ccminer/lib/protocol.lua")
local message = protocol.message("command", "shared-key", { command = "pause" }, 7)
assert(message.magic == common.MAGIC and message.schema == 4 and message.version == "4.0.0")
assert(message.sender == 42 and message.target == 7 and type(message.id) == "string")
assert(protocol.validate(message, "shared-key", 7, 42))

-- A missing target is a valid broadcast; a matching target is accepted.
local broadcast = protocol.message("heartbeat", "shared-key", { status = "idle" })
assert(protocol.validate(broadcast, "shared-key", 7, 42))

local function rejected(mutator, expectedError)
  local candidate = common.copy(message)
  mutator(candidate)
  local ok, err = protocol.validate(candidate, "shared-key", 7, 42)
  assert(not ok, "adversarial message unexpectedly accepted")
  if expectedError then assert(err == expectedError, tostring(err)) end
end

rejected(function(candidate) candidate.magic = "OTHER" end, "bad_magic")
rejected(function(candidate) candidate.schema = 3 end, "bad_schema")
rejected(function(candidate) candidate.version = "3.0.0" end, "bad_version")
rejected(function(candidate) candidate.kind = 99 end, "bad_kind")
rejected(function(candidate) candidate.id = "" end, "bad_id")
rejected(function(candidate) candidate.payload = "pause" end, "bad_payload")
rejected(function(candidate) candidate.sender = 99 end, "sender_mismatch")
rejected(function(candidate) candidate.sender = "not-a-number" end, "bad_sender")
rejected(function(candidate) candidate.target = 8 end, "wrong_target")
rejected(function(candidate) candidate.key = "wrong-key" end, "bad_key")

-- Validate also rejects a missing required envelope field, not just wrong
-- values, and accepts numeric sender/target representations where documented.
rejected(function(candidate) candidate.id = nil end, "bad_id")
local numericEnvelope = common.copy(message)
numericEnvelope.sender = "42"
numericEnvelope.target = "7"
assert(protocol.validate(numericEnvelope, "shared-key", 7, 42))

-- Ctrl+T is an explicit operator request. protocol.receive may contain other
-- rednet failures, but must propagate Terminated so boot.lua can stop the
-- worker instead of immediately returning to its loop.
rednet = { receive = function() error("Terminated", 0) end }
local terminatedOk, terminatedError = pcall(protocol.receive, 0.1)
assert(not terminatedOk and tostring(terminatedError):find("Terminated", 1, true),
  "protocol.receive swallowed Ctrl+T termination")
rednet.receive = function() error("network_boom", 0) end
local sender, received, receiveError = protocol.receive(0.1)
assert(sender == nil and received == nil and receiveError == "network_boom",
  "ordinary rednet errors should remain recoverable")

print("protocol V4 positive and adversarial envelope tests passed")
