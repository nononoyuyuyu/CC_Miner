-- Worker remote-console source contracts.
--
-- This is deliberately a read-only source test: booting a worker would open a
-- modem and touch its state files.  Runtime integration is exercised by the
-- parent validation suite with a CC:Tweaked harness.

local root = assert(arg and arg[1], "repository root is required")

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local workerControl = read("src/ccminer/worker_parts/02.part")
local worker = read("src/ccminer/worker_parts/01.part") .. "\n"
  .. workerControl .. "\n"
  .. read("src/ccminer/worker_parts/03.part") .. "\n"
  .. read("src/ccminer/worker_parts/04.part") .. "\n"
  .. read("src/ccminer/worker_parts/05.part")

local function marker(expected, label)
  assert(worker:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

for _, field in ipairs({
  "config.remoteConsole = config.remoteConsole or {}",
  "config.remoteConsole.enabled = config.remoteConsole.enabled == true",
  "config.remoteConsole.allowShell = config.remoteConsole.allowShell == true",
  "config.remoteConsole.sessionSeconds",
  "config.remoteConsole.maxOutputBytes",
  "config.remoteConsole.auditLimit",
}) do marker(field, "remote config " .. field) end

for _, action in ipairs({
  'if action == "open" then',
  'elseif action == "exec" or action == "close" then',
}) do marker(action, "remote action " .. action) end

for _, field in ipairs({
  "config.controllerId or 0",
  "Remote console requires a pinned controllerId.",
  "Remote console requires an idle, complete, aborted, or paused worker.",
  "Remote console requires the worker to be at home.",
  "state.pendingAction",
  "sessionId = remoteToken(\"session\", sender)",
  "nonce = remoteToken(\"nonce\", sender)",
  "sender = tonumber(sender)",
  "expiresAt = now +",
  "Remote console sequence replay/out of order",
  "remoteSession.lastSeq = seq",
  "Remote console session resumed.",
  "resumed = true",
}) do marker(field, "remote authorization/session " .. field) end

for _, field in ipairs({
  "config.remoteConsole.allowShell",
  "remoteConfiguredCommand(command)",
  "ccm status",
  "ccm report",
  "ccm doctor",
  "reboot = true",
  "update = true",
  "delete = true",
  "term.redirect",
  "config.remoteConsole.maxOutputBytes",
  "if remoteIsTerminated(exitCode) then error(exitCode, 0) end",
  "commandText = payload.commandText",
}) do marker(field, "remote shell safety/output " .. field) end

marker("result = type(result) == \"table\" and common.copy(result) or nil", "ACK result table")
marker("session = type(session) == \"table\" and common.copy(session) or nil", "ACK session table")
marker("remoteAudit[#remoteAudit + 1]", "bounded audit ring")
marker("while #remoteAudit > limit do table.remove(remoteAudit, 1) end", "audit limit")
marker('remoteAuditRecord("remote_console auto_close", true)', "automatic close before movement")

-- The remote path must not create a shell input file or write command text to
-- the worker filesystem.
local remoteStart = assert(workerControl:find("-- Remote console", 1, true))
local remoteEnd = assert(workerControl:find("local function applyControlCommand", remoteStart, true))
local remote = workerControl:sub(remoteStart, remoteEnd - 1)
assert(not remote:find("fs.open", 1, true), "remote console must not open input files")
assert(not remote:find("writeAllAtomic", 1, true), "remote console must not persist shell input")

print("worker remote-console source contracts passed")
