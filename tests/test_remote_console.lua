-- Source contracts for the V4 remote-console safety boundary.
-- This test intentionally reads source text only; it does not open a turtle,
-- rednet modem, shell, or interactive setup prompt.

local root = assert(arg[1], "repository root is required")

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function marker(text, expected, label)
  assert(text:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

local function markerAny(text, expected, label)
  for _, candidate in ipairs(expected) do
    if text:find(candidate, 1, true) then return end
  end
  error("missing " .. label .. " source contract: " .. table.concat(expected, " OR "))
end

local common = read("src/ccminer/lib/common.lua")
local setup = read("src/ccminer/setup.lua")
local workerInit = read("src/ccminer/worker_parts/01.part")
local workerControl = read("src/ccminer/worker_parts/02.part")
local controller = read("src/ccminer/controller_parts/01.part")
local controllerCli = read("src/ccminer/controller_parts/03.part")
local command = read("src/ccminer/command.lua")
local settings = read("docs/settings.html")
local safety = read("docs/safety.html")
local quickstart = read("docs/quickstart.html")
local readme = read("README.md")
local changelog = read("CHANGELOG.md")

-- Canonical defaults are additive to worker V4 configuration and use a fresh
-- ordered array.  Keeping every literal here catches accidental drift between
-- setup, normalizer, and runtime policy.
for _, expected in ipairs({
  "function M.defaultRemoteConsoleConfig()",
  "remoteConsole = M.defaultRemoteConsoleConfig()",
  "enabled = true",
  "allowShell = false",
  "sessionSeconds = 120",
  "maxOutputBytes = 8192",
  "auditLimit = 50",
  '"ccm status"',
  '"ccm report"',
  '"ccm doctor"',
  '"id"',
  '"label get"',
  '"ls"',
  '"dir"',
  '"df"',
  '"free"',
  '"version"',
}) do
  marker(common, expected, "remote-console default")
end
marker(common, "function M.normalizeRemoteConsoleConfig(value)", "remote-console normalizer")
marker(common, "loaded.remoteConsoleAllowlist", "remote-console migration alias")
marker(common, "if not remoteWasSpecified then remoteSource.enabled = false end", "legacy update remains opt-in")
marker(common, "toSave.remoteConsole = M.normalizeRemoteConsoleConfig(config.remoteConsole)", "remote-console serializer detachment")
marker(common, "config.controllerId = normalizeInteger(config.controllerId, 0, 65535, defaults.controllerId)", "controller pin normalization")

-- Fresh setup enables only the bounded safe console for same-key controllers.
-- Arbitrary shell access remains a separate opt-in and requires a pin.
for _, expected in ipairs({
  'local remoteConsole = ensureTable(config, "remoteConsole", workerDefaults.remoteConsole)',
  "【強い警告】遠隔コンソールは",
  "安全な遠隔コンソールを有効にしますか（新規設定はON）",
  "remoteConsole.allowShell = common.promptYesNo",
  "allowShell（シェル実行）を許可しますか",
  "controllerId=0 は、同じ合言葉を持つ管理用コンピューターを許可します。",
  "allowShellではcontrollerId=0を使えません。",
  "Allowed controller ID (0=same network key)",
  "Controller computer ID (1-65535)",
  "config.remoteConsole = common.normalizeRemoteConsoleConfig(remoteConsole)",
}) do
  marker(setup, expected, "setup remote-console safety prompt")
end

-- Worker policy: pinned sender, idle/home guard, nonce/session/sequence,
-- exact allowlist, bounded output, audit ring, and explicit exit/close.
for _, expected in ipairs({
  "config.remoteConsole.enabled = config.remoteConsole.enabled == true",
  "config.remoteConsole.maxOutputBytes",
  "config.remoteConsole.auditLimit",
  "local remoteAudit = {}",
  "local function remoteConsoleReady()",
  "Remote console requires the worker to be at home.",
  "local function remoteConsumeSession(sender, payload)",
  "Remote console nonce is invalid.",
  "Remote console sequence replay/out of order",
  "local function remoteSafeCommand(command)",
  "local function remoteConfiguredCommand(command)",
  "config.remoteConsole.allowShell",
  "local function runRemoteShell(command)",
  "remoteConsoleAction(sender, payload)",
  'command == "remote_console"',
}) do
  markerAny(workerInit .. "\n" .. workerControl, { expected }, "worker remote-console contract")
end
marker(workerControl, "sessionId", "worker remote session identity")
marker(workerControl, "nextSeq", "worker remote sequence response")
marker(workerControl, "remoteAuditRecord", "worker remote audit record")

-- Controller sends the three actions through the remote command path and
-- provides a CLI entry point with a one-shot form.
for _, expected in ipairs({
  'command = "remote_console", action = tostring(action)',
  "noticeState.remoteApi.consoleCommand = function(workerId, oneShot)",
  "Type exit or quit to close.",
  "Remote console close warning",
  'remoteAckField(payload, result, "nextSeq")',
}) do
  marker(controller, expected, "controller remote-console contract")
end
marker(controllerCli, 'if command == "remote" then', "controller remote CLI branch")
marker(command, "ccm remote <workerId>", "ccm remote help")

-- Beginner documentation must describe the safe sequence and the fact that
-- rednet is not encryption, without hiding the command itself.
for _, expected in ipairs({
  "安全な確認機能だけが既定でONです",
  "同じ合言葉",
  "ccm remote 12",
  "採掘を止め",
  "ドックへ戻った",
  "controllerId",
  "exit",
  "更新",
  "rednet",
  "暗号化され",
  "allowShell",
  "maxOutputBytes=8192",
  "auditLimit=50",
}) do
  marker(settings, expected, "remote-console beginner documentation")
end
for _, expected in ipairs({
  "ccm remote 12",
  "controllerId=0",
  "採掘を停止",
  "ドック",
  "exit",
  "rednet",
  "暗号化され",
}) do
  marker(safety, expected, "remote-console safety documentation")
end
marker(quickstart, "この最短手順では遠隔コンソールを使いません", "remote-console quickstart scope warning")
marker(readme, "ccm remote 12", "remote-console README procedure")
marker(changelog, "同じnetworkKeyのコントローラーへ読み取りallowlistだけを既定許可", "remote-console changelog entry")

print("remote-console V4 config, setup, runtime boundary, and beginner documentation contracts passed")
