-- CC Miner V3/V2-compatible rednet protocol helpers

local common = dofile("/ccminer/lib/common.lua")
local M = {}

local function makeId(prefix)
  local millis = common.nowMillis()
  local randomPart = math.random(100000, 999999)
  return ("%s-%d-%d-%d"):format(prefix or "msg", os.getComputerID(), millis, randomPart)
end

function M.message(kind, key, payload, target)
  return {
    magic = common.MAGIC,
    schema = common.SCHEMA,
    version = common.VERSION,
    kind = kind,
    key = key,
    sender = os.getComputerID(),
    target = target,
    id = makeId(kind),
    sentAt = common.nowSeconds(),
    payload = payload or {},
  }
end

function M.validate(message, expectedKey, expectedTarget, actualSender)
  if type(message) ~= "table" then return false, "not_table" end
  if message.magic ~= common.MAGIC then return false, "bad_magic" end
  if tonumber(message.schema) ~= common.SCHEMA then return false, "bad_schema" end
  if message.version ~= common.VERSION then return false, "bad_version" end
  if type(message.kind) ~= "string" then return false, "bad_kind" end
  if type(message.id) ~= "string" or message.id == "" then return false, "bad_id" end
  if type(message.payload) ~= "table" then return false, "bad_payload" end
  local claimedSender = tonumber(message.sender)
  if not claimedSender then return false, "bad_sender" end
  if actualSender and claimedSender ~= tonumber(actualSender) then return false, "sender_mismatch" end
  if expectedKey and expectedKey ~= "" and message.key ~= expectedKey then return false, "bad_key" end
  if expectedTarget and message.target and tonumber(message.target) ~= tonumber(expectedTarget) then
    return false, "wrong_target"
  end
  return true
end

function M.open()
  local opened = common.openWirelessModems()
  return #opened > 0, opened
end

function M.send(target, message)
  if not rednet then return false, "rednet_unavailable" end
  local ok, result = pcall(rednet.send, tonumber(target), message, common.PROTOCOL)
  if not ok then return false, tostring(result) end
  return result == true, result == true and nil or "send_failed"
end

function M.broadcast(message)
  if not rednet then return false, "rednet_unavailable" end
  local ok, result = pcall(rednet.broadcast, message, common.PROTOCOL)
  if not ok then return false, tostring(result) end
  return result ~= false, result == false and "broadcast_failed" or nil
end

function M.receive(timeout)
  if not rednet then return nil, nil, "rednet_unavailable" end
  local ok, sender, message, protocolName = pcall(rednet.receive, common.PROTOCOL, timeout)
  if not ok then return nil, nil, tostring(sender) end
  if not sender then return nil, nil, nil end
  return sender, message, protocolName
end

function M.reply(target, key, request, kind, payload)
  local message = M.message(kind, key, payload, target)
  if request and request.id then message.replyTo = request.id end
  return M.send(target, message)
end

return M
