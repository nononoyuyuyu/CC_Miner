#!/usr/bin/env python3
"""Build the role-scoped, split ComputerCraft offline installers.

The generated files are deliberately self contained.  The role loader verifies
every transferred part before loading the installer, then removes the loader
and its parts so a fresh installation can proceed on a one-megabyte device.

Requires Python 3.10+.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "4.0.0"
SCHEMA = 4
PART_LIMIT_BYTES = 12_000
ROLE_ORDER = ("worker", "controller", "gps")

# Keep this order in lockstep with manifest.lua.  The manifest is intentionally
# not parsed by Python: ComputerCraft cannot import it, and explicit lists make
# the generated digest reproducible on every build host.
COMMON_FILES = [
    ("src/ccminer/lib/common.lua", "lib/common.lua"),
    ("src/ccminer/lib/protocol.lua", "lib/protocol.lua"),
    ("src/ccminer/setup.lua", "setup.lua"),
    ("src/ccminer/boot.lua", "boot.lua"),
    ("src/ccminer/command.lua", "command.lua"),
]
WORKER_FILES = COMMON_FILES + [
    ("src/ccminer/lib/geo.lua", "lib/geo.lua"),
    ("src/ccminer/lib/quarry.lua", "lib/quarry.lua"),
    ("src/ccminer/worker.lua", "worker.lua"),
    ("src/ccminer/worker_parts/01.part", "worker_parts/01.part"),
    ("src/ccminer/worker_parts/02.part", "worker_parts/02.part"),
    ("src/ccminer/worker_parts/03.part", "worker_parts/03.part"),
    ("src/ccminer/worker_parts/04.part", "worker_parts/04.part"),
    ("src/ccminer/worker_parts/05.part", "worker_parts/05.part"),
]
CONTROLLER_FILES = COMMON_FILES + [
    ("src/ccminer/lib/quarry.lua", "lib/quarry.lua"),
    ("src/ccminer/controller.lua", "controller.lua"),
    ("src/ccminer/controller_parts/01.part", "controller_parts/01.part"),
    ("src/ccminer/controller_parts/02.part", "controller_parts/02.part"),
    ("src/ccminer/controller_parts/03.part", "controller_parts/03.part"),
]
GPS_FILES = COMMON_FILES + [
    ("src/ccminer/gps_host.lua", "gps_host.lua"),
]
ROLE_FILES: dict[str, list[tuple[str, str]]] = {
    "worker": WORKER_FILES,
    "controller": CONTROLLER_FILES,
    "gps": GPS_FILES,
}
ROLE_ENTRYPOINTS = {"worker": "worker.lua", "controller": "controller.lua", "gps": "gps_host.lua"}

# Compatibility for callers which used the old generator API.  This is also
# the unique manifest order, rather than an accidentally role-specific list.
RUNTIME_FILES = [
    *COMMON_FILES,
    ("src/ccminer/lib/geo.lua", "lib/geo.lua"),
    ("src/ccminer/lib/quarry.lua", "lib/quarry.lua"),
    ("src/ccminer/worker.lua", "worker.lua"),
    ("src/ccminer/worker_parts/01.part", "worker_parts/01.part"),
    ("src/ccminer/worker_parts/02.part", "worker_parts/02.part"),
    ("src/ccminer/worker_parts/03.part", "worker_parts/03.part"),
    ("src/ccminer/worker_parts/04.part", "worker_parts/04.part"),
    ("src/ccminer/worker_parts/05.part", "worker_parts/05.part"),
    ("src/ccminer/controller.lua", "controller.lua"),
    ("src/ccminer/controller_parts/01.part", "controller_parts/01.part"),
    ("src/ccminer/controller_parts/02.part", "controller_parts/02.part"),
    ("src/ccminer/controller_parts/03.part", "controller_parts/03.part"),
    ("src/ccminer/gps_host.lua", "gps_host.lua"),
]
ALL_RUNTIME_TARGETS = [target for _, target in RUNTIME_FILES]


def lua_long_string(text: str) -> str:
    """Return a Lua long string which cannot terminate on *text*."""

    for equals_count in range(32):
        equals = "=" * equals_count
        if f"]{equals}]" not in text:
            return f"[{equals}[{text}]{equals}]"
    raise ValueError("Could not find a safe Lua long-string delimiter")


def split_text(text: str, maximum_bytes: int = PART_LIMIT_BYTES) -> list[str]:
    """Split UTF-8 text on line boundaries without changing its contents."""

    parts: list[str] = []
    current: list[str] = []
    current_bytes = 0
    for line in text.splitlines(keepends=True):
        line_bytes = len(line.encode("utf-8"))
        if line_bytes > maximum_bytes:
            raise ValueError(f"A generated line exceeds the part limit: {line_bytes} bytes")
        if current and current_bytes + line_bytes > maximum_bytes:
            # Do not strand a run of blank lines at a part boundary.  This
            # keeps assembled Lua byte-for-byte identical to the installer.
            carry: list[str] = []
            while current and not current[-1].strip():
                blank = current.pop()
                current_bytes -= len(blank.encode("utf-8"))
                carry.insert(0, blank)
            if current:
                parts.append("".join(current))
            current = carry
            current_bytes = sum(len(item.encode("utf-8")) for item in carry)
            if current and current_bytes + line_bytes > maximum_bytes:
                parts.append("".join(current))
                current = []
                current_bytes = 0
        current.append(line)
        current_bytes += line_bytes
    if current:
        parts.append("".join(current))
    if "".join(parts) != text:
        raise AssertionError("Split output does not reproduce the source")
    if any(len(part.encode("utf-8")) > maximum_bytes for part in parts):
        raise AssertionError("Split output exceeds the part limit")
    return parts


def _read_role_files(role: str) -> list[dict[str, str]]:
    if role not in ROLE_FILES:
        raise ValueError(f"Unknown role: {role}")
    result: list[dict[str, str]] = []
    seen_targets: set[str] = set()
    for source, target in ROLE_FILES[role]:
        if target in seen_targets:
            raise AssertionError(f"Duplicate target in {role} manifest: {target}")
        seen_targets.add(target)
        content = (ROOT / source).read_text(encoding="utf-8")
        result.append(
            {
                "source": source,
                "target": target,
                "content": content,
                "digest": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            }
        )
    return result


def _role_digest(role: str, files: list[dict[str, str]]) -> str:
    digest = hashlib.sha256()
    for value in ("ccminer-offline-role", VERSION, str(SCHEMA), role, str(len(files))):
        digest.update(value.encode("utf-8"))
        digest.update(b"\0")
    for file in files:
        for value in (file["source"], file["target"], file["digest"]):
            digest.update(value.encode("utf-8"))
            digest.update(b"\0")
        digest.update(file["content"].encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def _part_names(count: int) -> list[str]:
    width = max(2, len(str(count)))
    return [f"{index:0{width}d}.part" for index in range(1, count + 1)]


def _embedded_entries(files: list[dict[str, str]]) -> str:
    return "\n".join(
        "  { source = %s, target = %s, digest = %s, content = %s },"
        % (
            lua_long_string(file["source"]),
            lua_long_string(file["target"]),
            lua_long_string(file["digest"]),
            lua_long_string(file["content"]),
        )
        for file in files
    )


def _part_target_groups(role: str) -> tuple[list[str], list[str]]:
    files = ROLE_FILES[role]
    worker = [target for _, target in files if target.startswith("worker_parts/")]
    controller = [target for _, target in files if target.startswith("controller_parts/")]
    return worker, controller


def _low_space_steps(role: str, files: list[dict[str, str]]) -> tuple[str, list[dict[str, str]], list[str]]:
    """Return entrypoint, non-entrypoint operations, and obsolete targets."""

    entrypoint = ROLE_ENTRYPOINTS[role]
    role_targets = {file["target"] for file in files}
    operations = [
        {"kind": "runtime", "index": index}
        for index, file in enumerate(files, 1)
        if file["target"] != entrypoint
    ]
    obsolete = [target for target in ALL_RUNTIME_TARGETS if target not in role_targets]
    operations.extend({"kind": "obsolete", "target": target} for target in obsolete)
    return entrypoint, operations, obsolete


def build_installer(role: str = "worker") -> str:
    """Render one role-fixed installer, embedding only that role's files."""

    files = _read_role_files(role)
    source_digest = _role_digest(role, files)
    embedded = _embedded_entries(files)
    worker_parts, controller_parts = _part_target_groups(role)
    worker_parts_lua = "{" + ", ".join(lua_long_string(item) for item in worker_parts) + "}"
    controller_parts_lua = "{" + ", ".join(lua_long_string(item) for item in controller_parts) + "}"
    entrypoint, low_space_operations, _ = _low_space_steps(role, files)
    low_space_steps_lua = "{\n" + "\n".join(
        (
            "  { kind = \"runtime\", index = %d }," % operation["index"]
            if operation["kind"] == "runtime"
            else "  { kind = \"obsolete\", target = %s }," % lua_long_string(operation["target"])
        )
        for operation in low_space_operations
    ) + "\n}"
    sentinel = lua_long_string(
        "-- CC Miner V4 update-incomplete sentinel for " + role + "\n"
        "error(\"CC Miner runtime update is incomplete. Re-transfer the offline "
        "bundle and run update-low-space.\", 0)\n"
    )

    # The template intentionally avoids Python formatting syntax: runtime Lua
    # contains many braces, while the small replacement map keeps the output
    # readable and deterministic.
    template = r'''-- CC Miner V4 role-scoped offline installer/updater
-- Generated by tools/build_offline_bundle.py. Do not edit directly.
-- Role: %ROLE%
-- Version: %VERSION%  Schema: %SCHEMA%
-- Source digest: %SOURCE_DIGEST%
-- Usage: ccminer-offline-%ROLE%.lua %ROLE% | update | update-low-space

local args = { ... }
local requested = string.lower(tostring(args[1] or ""))
local ROLE = "%ROLE%"
local VERSION = "%VERSION%"
local SCHEMA = %SCHEMA%
local SOURCE_DIGEST = "%SOURCE_DIGEST%"
local ROOT, TEMP, BACKUP = "/ccminer", "/ccminer.update", "/ccminer.backup"
local LOW_SPACE_MARKER = "/ccminer.update.low-space.marker"
local files = {
%EMBEDDED%
}
local FILE_COUNT = %FILE_COUNT%
local WORKER_PARTS = %WORKER_PARTS%
local CONTROLLER_PARTS = %CONTROLLER_PARTS%
local ENTRYPOINT = %ENTRYPOINT%
local UPDATE_SENTINEL = %UPDATE_SENTINEL%
local LOW_SPACE_STEPS = %LOW_SPACE_STEPS%

local function fail(message)
  error(tostring(message), 0)
end
local function ensureDir(path)
  if not path or path == "" or fs.exists(path) then return end
  local parent = fs.getDir(path)
  if parent and parent ~= "" and parent ~= path then ensureDir(parent) end
  fs.makeDir(path)
end
local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local text = handle.readAll(); handle.close(); return text
end
local function writeFile(path, text)
  ensureDir(fs.getDir(path))
  local handle = fs.open(path, "wb")
  if not handle then return false, "Cannot write " .. path end
  local ok, writeError = pcall(handle.write, text or "")
  handle.close()
  if not ok then return false, tostring(writeError) end
  return true
end
local function digest(text)
  if not textutils or type(textutils.sha256) ~= "function" then
    return nil, "textutils.sha256 is required for strict offline bundle verification."
  end
  local ok, value = pcall(textutils.sha256, text or "")
  if not ok or type(value) ~= "string" then return nil, tostring(value or "sha256 failed") end
  return string.lower(value)
end
local function compileText(label, text)
  local loader = loadstring or load
  local compiled, compileError = loader(text, "@" .. label)
  if not compiled then return false, tostring(compileError) end
  return true
end
local function validateEmbedded()
  if #files ~= FILE_COUNT then fail("Embedded runtime file count is invalid for role " .. ROLE) end
  local seen = {}
  local aggregate = {
    "ccminer-offline-role", "\0", VERSION, "\0", tostring(SCHEMA), "\0", ROLE, "\0", tostring(#files), "\0",
  }
  for index, file in ipairs(files) do
    if type(file.target) ~= "string" or type(file.content) ~= "string" or seen[file.target] then
      fail("Embedded runtime order/target is invalid at index " .. tostring(index))
    end
    seen[file.target] = true
    local actual, digestError = digest(file.content)
    if not actual then fail(digestError) end
    if actual ~= string.lower(file.digest or "") then
      fail("Embedded runtime digest mismatch: " .. tostring(file.target))
    end
    aggregate[#aggregate + 1] = file.source; aggregate[#aggregate + 1] = "\0"
    aggregate[#aggregate + 1] = file.target; aggregate[#aggregate + 1] = "\0"
    aggregate[#aggregate + 1] = file.digest; aggregate[#aggregate + 1] = "\0"
    aggregate[#aggregate + 1] = file.content; aggregate[#aggregate + 1] = "\0"
  end
  local aggregateDigest, aggregateError = digest(table.concat(aggregate))
  if not aggregateDigest then fail(aggregateError) end
  if aggregateDigest ~= string.lower(SOURCE_DIGEST) then
    fail("Embedded role source digest mismatch for " .. ROLE)
  end
  return true
end
local function validateParts(label, targets)
  if #targets == 0 then return true end
  local source = {}
  for index, target in ipairs(targets) do
    local found
    for _, file in ipairs(files) do if file.target == target then found = file.content; break end end
    if not found then fail("Embedded runtime part is missing: " .. target) end
    source[index] = found
  end
  local ok, compileError = compileText(label .. ".assembled.lua", table.concat(source))
  if not ok then fail("Assembled source failed syntax validation: " .. label .. ": " .. compileError) end
end
local function validateAll()
  validateEmbedded()
  for _, file in ipairs(files) do
    if not file.target:match("%.part$") then
      local ok, compileError = compileText(file.target, file.content)
      if not ok then fail("Embedded file failed syntax validation: " .. file.target .. ": " .. compileError) end
    end
  end
  validateParts("worker", WORKER_PARTS)
  validateParts("controller", CONTROLLER_PARTS)
end
-- Kept as a named boundary for source-contract checks and recovery logs.  The
-- role bundle validates from memory, so no /ccminer.update staging tree is
-- needed before a low-space commit.
local function validateLowSpaceStage()
  validateAll()
end
local function copyIfPresent(source, target)
  local text = readFile(source)
  if text then return writeFile(target, text) end
  return true
end
local function moveChecked(source, target)
  local ok, moveError = pcall(fs.move, source, target)
  if not ok or not fs.exists(target) then
    return false, tostring(moveError or ("Move destination is missing: " .. target))
  end
  return true
end
local function atomicWrite(path, text)
  local temp, backup = path .. ".tmp", path .. ".bak"
  ensureDir(fs.getDir(path))
  if fs.exists(temp) then fs.delete(temp) end
  local wrote, writeError = writeFile(temp, text)
  if not wrote then return false, writeError end
  local hadCurrent = fs.exists(path)
  if hadCurrent then
    if fs.exists(backup) then fs.delete(backup) end
    local moved, moveError = moveChecked(path, backup)
    if not moved then fs.delete(temp); return false, "Cannot rotate previous file: " .. moveError end
  end
  local moved, moveError = moveChecked(temp, path)
  if not moved then
    if fs.exists(path) then fs.delete(path) end
    local restored = true
    local restoreError
    if hadCurrent and fs.exists(backup) then
      restored, restoreError = moveChecked(backup, path)
    elseif hadCurrent then
      restored, restoreError = false, "backup is missing"
    end
    if fs.exists(temp) then fs.delete(temp) end
    return false, "Atomic replace failed: " .. tostring(moveError) .. "; rollback: " .. tostring(restoreError or restored)
  end
  if fs.exists(backup) then fs.delete(backup) end
  if fs.exists(temp) then fs.delete(temp) end
  return true
end
local function readConfigRole()
  local text = readFile(ROOT .. "/config.db")
  if not text then return nil, "No existing installation found." end
  if not textutils or type(textutils.unserialize) ~= "function" then return nil, "Cannot decode config.db." end
  local ok, value = pcall(textutils.unserialize, text)
  if not ok or type(value) ~= "table" then return nil, "Existing config.db is invalid." end
  return tostring(value.role or ""), nil
end
local function validateAction()
  local action = requested
  if action == "" then action = ROLE end
  if action ~= ROLE and action ~= "update" and action ~= "update-low-space" then
    fail("This offline bundle is fixed to role " .. ROLE .. "; refusing action " .. tostring(action))
  end
  if action == "worker" and not turtle then fail("Worker installation requires a turtle.") end
  if (action == "update" or action == "update-low-space") then
    local configRole, configError = readConfigRole()
    if not configRole then fail(configError) end
    if configRole ~= ROLE then
      fail("Refusing " .. action .. ": existing config role is " .. tostring(configRole)
        .. ", but this bundle is fixed to " .. ROLE .. ".")
    end
  end
  if action == "update" and fs.exists(LOW_SPACE_MARKER) then
    fail("A low-space update is incomplete. Re-transfer the original "
      .. "ccminer-offline-" .. ROLE .. ".lua and parts, then run update-low-space.")
  end
  return action
end
local function usage()
  print("CC Miner V4 offline " .. ROLE .. " installer " .. VERSION .. " (schema " .. SCHEMA .. ")")
  print("  ccminer-offline-" .. ROLE .. ".lua " .. ROLE)
  print("  ccminer-offline-" .. ROLE .. ".lua update")
  print("  ccminer-offline-" .. ROLE .. ".lua update-low-space")
end

local action = validateAction()
if action == "" then usage(); return end
if action ~= "update-low-space" then
  term.clear(); term.setCursorPos(1, 1)
  print("CC MINER V4 OFFLINE " .. string.upper(action) .. " / " .. ROLE); print("")
  if fs.exists(TEMP) then fs.delete(TEMP) end
  ensureDir(TEMP)
  for index, file in ipairs(files) do
    write(("[%d/%d] %s ... "):format(index, #files, file.target))
    local ok, writeError = writeFile(TEMP .. "/" .. file.target, file.content)
    if not ok then fs.delete(TEMP); fail(writeError) end
    print("OK")
  end
  validateAll()
end

local preserved = {
  { ROOT .. "/config.db", TEMP .. "/config.db" },
  { ROOT .. "/config.db.bak", TEMP .. "/config.db.bak" },
  { ROOT .. "/data/state.db", TEMP .. "/data/state.db" },
  { ROOT .. "/data/state.db.bak", TEMP .. "/data/state.db.bak" },
  { ROOT .. "/data/state.pending", TEMP .. "/data/state.pending" },
  { ROOT .. "/data/state.journal", TEMP .. "/data/state.journal" },
  { ROOT .. "/data/state.checkpoint.db", TEMP .. "/data/state.checkpoint.db" },
  { ROOT .. "/data/controller.db", TEMP .. "/data/controller.db" },
  { ROOT .. "/controller.db", TEMP .. "/controller.db" },
  { ROOT .. "/data/ccminer.log", TEMP .. "/data/ccminer.log" },
  { ROOT .. "/data/ccminer.log.1", TEMP .. "/data/ccminer.log.1" },
}
if action ~= "update-low-space" then
  for _, pair in ipairs(preserved) do
    local ok, copyError = copyIfPresent(pair[1], pair[2])
    if not ok then fs.delete(TEMP); fail("Cannot preserve existing data: " .. tostring(copyError)) end
  end
end

local function parseMarker(text)
  if not text then return nil end
  local version = text:match("version=([^\r\n]+)")
  local schema = tonumber(text:match("schema=(%d+)"))
  local role = text:match("role=([^\r\n]+)")
  local state = text:match("state=([^\r\n]+)")
  local nextIndex = tonumber(text:match("next=(%d+)"))
  if not version or not schema or not role or not state or not nextIndex then return nil end
  return { version = version, schema = schema, role = role, state = state, next = nextIndex }
end
local function markerRead()
  local markerText = readFile(LOW_SPACE_MARKER)
  local marker = parseMarker(markerText)
  if marker then return marker, nil end
  local backupPath, tempPath = LOW_SPACE_MARKER .. ".bak", LOW_SPACE_MARKER .. ".tmp"
  local tempText = readFile(tempPath)
  local temp = parseMarker(tempText)
  if tempText and not temp then
    return nil, "Recovery marker temporary file is corrupt; refusing to guess update progress."
  end
  local backupText = readFile(backupPath)
  local backup = parseMarker(backupText)
  if backup then
    local restored, restoreError = atomicWrite(LOW_SPACE_MARKER, backupText)
    if not restored then return nil, "Recovery marker backup is valid but could not be restored: " .. tostring(restoreError) end
    local recovered = parseMarker(readFile(LOW_SPACE_MARKER))
    if not recovered then return nil, "Recovery marker backup restore could not be verified." end
    return recovered, nil
  end
  if temp then
    local restored, restoreError = atomicWrite(LOW_SPACE_MARKER, tempText)
    if not restored then return nil, "Recovery marker temporary file is valid but could not be restored: " .. tostring(restoreError) end
    local recovered = parseMarker(readFile(LOW_SPACE_MARKER))
    if not recovered then return nil, "Recovery marker temporary restore could not be verified." end
    return recovered, nil
  end
  if markerText then return nil, "Recovery marker is corrupt and no valid atomic backup remains." end
  if backupText then return nil, "Recovery marker backup is corrupt and cannot be trusted." end
  return nil, nil
end
local function markerWrite(state, nextIndex)
  local text = table.concat({
    "version=" .. VERSION,
    "schema=" .. tostring(SCHEMA),
    "role=" .. ROLE,
    "state=" .. tostring(state),
    "next=" .. tostring(nextIndex or 1),
    "",
  }, "\n")
  return atomicWrite(LOW_SPACE_MARKER, text)
end
local function clearMarker()
  for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
    local path = LOW_SPACE_MARKER .. suffix
    if fs.exists(path) then pcall(fs.delete, path) end
    if fs.exists(path) then return false, "Cannot clear recovery marker artifact: " .. path end
  end
  return true
end
local function lowSpaceFailure(message)
  printError("LOW-SPACE UPDATE PAUSED")
  fail(tostring(message) .. "\nRecovery marker: " .. LOW_SPACE_MARKER
    .. "\nRe-transfer ccminer-offline-" .. ROLE .. ".lua and its parts, then rerun update-low-space.")
end
local function embeddedEntrypoint()
  for _, file in ipairs(files) do
    if file.target == ENTRYPOINT then return file.content end
  end
  lowSpaceFailure("Embedded role loader is missing: " .. ENTRYPOINT)
end
local function ensureUpdateSentinel()
  local path = ROOT .. "/" .. ENTRYPOINT
  if readFile(path) ~= UPDATE_SENTINEL then
    local wrote, writeError = atomicWrite(path, UPDATE_SENTINEL)
    if not wrote then lowSpaceFailure("Cannot install the update-incomplete sentinel: " .. tostring(writeError)) end
  end
  if readFile(path) ~= UPDATE_SENTINEL then
    lowSpaceFailure("Update-incomplete sentinel could not be verified; runtime was not started.")
  end
end
local function applyLowSpaceStep(step)
  if step.kind == "runtime" then
    local file = files[step.index]
    if not file then return false, "Low-space runtime step has an invalid file index." end
    local wrote, writeError = atomicWrite(ROOT .. "/" .. file.target, file.content)
    if not wrote then return false, "Cannot atomically install " .. file.target .. ": " .. tostring(writeError) end
    return true
  end
  if step.kind == "obsolete" then
    local basePath = ROOT .. "/" .. step.target
    for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
      local path = basePath .. suffix
      if fs.exists(path) then pcall(fs.delete, path) end
      if fs.exists(path) then return false, "Cannot remove obsolete runtime target: " .. path end
    end
    return true
  end
  return false, "Unknown low-space update step: " .. tostring(step.kind)
end
local function lowSpaceUpdate()
  -- Everything is already in memory from the verified role bundle.  There is
  -- deliberately no /ccminer.update staging tree in this path.  The runtime
  -- entrypoint is first replaced by a fail-closed sentinel, so a power loss
  -- cannot boot a mixed set of files.  The final entrypoint is committed only
  -- after every non-loader write and obsolete-role deletion has completed.
  validateLowSpaceStage()
  ensureUpdateSentinel()
  local marker, markerReadError = markerRead()
  if markerReadError then lowSpaceFailure(markerReadError) end
  if marker then
    if marker.version ~= VERSION or marker.schema ~= SCHEMA or marker.role ~= ROLE then
      lowSpaceFailure("Recovery marker does not match this role bundle.")
    end
    if marker.state ~= "ready" and marker.state ~= "committing" and marker.state ~= "final-ready" then
      lowSpaceFailure("Recovery marker has an unknown state: " .. tostring(marker.state))
    end
  else
    local marked, markerError = markerWrite("ready", 1)
    if not marked then lowSpaceFailure("Cannot create recovery marker: " .. tostring(markerError)) end
    marker, markerReadError = markerRead()
    if markerReadError or not marker then
      lowSpaceFailure(markerReadError or "Recovery marker was written but could not be read back.")
    end
  end
  local first
  if marker.state == "final-ready" then
    -- final-ready explicitly skips every non-loader step on resume.
    first = #LOW_SPACE_STEPS + 1
  else
    first = math.max(1, math.min(#LOW_SPACE_STEPS + 1, marker.next or 1))
  end
  local marked, markerError = markerWrite("ready", first)
  if not marked then lowSpaceFailure("Cannot mark validated runtime: " .. tostring(markerError)) end
  for index = first, #LOW_SPACE_STEPS do
    local step = LOW_SPACE_STEPS[index]
    marked, markerError = markerWrite("committing", index)
    if not marked then lowSpaceFailure("Cannot record commit progress for step " .. tostring(index) .. ": " .. tostring(markerError)) end
    local applied, applyError = applyLowSpaceStep(step)
    if not applied then lowSpaceFailure(applyError) end
    marked, markerError = markerWrite("committing", index + 1)
    if not marked then lowSpaceFailure("Applied low-space step " .. tostring(index) .. ", but cannot advance recovery marker: " .. tostring(markerError)) end
  end
  local finalContent = embeddedEntrypoint()
  marked, markerError = markerWrite("final-ready", #LOW_SPACE_STEPS + 1)
  if not marked then lowSpaceFailure("Cannot mark the validated final role loader: " .. tostring(markerError)) end
  local finalPath = ROOT .. "/" .. ENTRYPOINT
  local wrote, writeError = atomicWrite(finalPath, finalContent)
  if not wrote then lowSpaceFailure("Cannot atomically commit final role loader: " .. tostring(writeError)) end
  if readFile(finalPath) ~= finalContent then
    lowSpaceFailure("Final role loader could not be verified after atomic commit.")
  end
  local cleared, clearError = clearMarker()
  if not cleared then lowSpaceFailure(clearError) end
  print("Low-space update installed: " .. VERSION .. " (schema " .. SCHEMA .. ")")
  print("User data under /ccminer was left in place. Run: reboot")
end

if action == "update-low-space" then
  term.clear(); term.setCursorPos(1, 1)
  print("CC MINER V4 OFFLINE UPDATE-LOW-SPACE / " .. ROLE); print("")
  lowSpaceUpdate()
  return
end

if fs.exists(BACKUP) then fs.delete(BACKUP) end
local hadRoot = fs.exists(ROOT)
if hadRoot then
  local backedUp, backupError = moveChecked(ROOT, BACKUP)
  if not backedUp then fs.delete(TEMP); fail("Cannot back up existing installation: " .. backupError) end
end
local moved, moveError = moveChecked(TEMP, ROOT)
if not moved then
  if fs.exists(ROOT) then fs.delete(ROOT) end
  local restored, restoreError = true, nil
  if hadRoot then
    if fs.exists(BACKUP) then restored, restoreError = moveChecked(BACKUP, ROOT)
    else restored, restoreError = false, "Backup directory is missing." end
  end
  if not restored then
    fail("Install swap failed and rollback failed. Previous files remain at " .. BACKUP .. ": "
      .. tostring(moveError) .. "; rollback: " .. tostring(restoreError))
  end
  fail("Install swap failed; previous installation was restored: " .. tostring(moveError))
end
print("")
if action == "update" then
  print("Offline update installed: " .. VERSION .. " (schema " .. SCHEMA .. ")")
  print("Previous files: /ccminer.backup"); print("Run: reboot")
else
  local setupOk = shell.run(ROOT .. "/setup.lua", ROLE)
  if not setupOk then printError("Setup did not complete. Run: " .. ROOT .. "/setup.lua " .. ROLE)
  else print(""); print("Installation complete. Run: reboot") end
end
'''
    return (
        template.replace("%ROLE%", role)
        .replace("%VERSION%", VERSION)
        .replace("%SCHEMA%", str(SCHEMA))
        .replace("%SOURCE_DIGEST%", source_digest)
        .replace("%EMBEDDED%", embedded)
        .replace("%FILE_COUNT%", str(len(files)))
        .replace("%WORKER_PARTS%", worker_parts_lua)
        .replace("%CONTROLLER_PARTS%", controller_parts_lua)
        .replace("%ENTRYPOINT%", lua_long_string(entrypoint))
        .replace("%UPDATE_SENTINEL%", sentinel)
        .replace("%LOW_SPACE_STEPS%", low_space_steps_lua)
    )


def render_role_bundle(role: str) -> tuple[list[str], list[str], str]:
    installer = build_installer(role)
    parts = split_text(installer, PART_LIMIT_BYTES)
    names = _part_names(len(parts))
    assembled_digest = hashlib.sha256(installer.encode("utf-8")).hexdigest()
    part_metadata = "\n".join(
        '  { name = %s, bytes = %d, digest = %s },'
        % (
            lua_long_string(name),
            len(part.encode("utf-8")),
            lua_long_string(hashlib.sha256(part.encode("utf-8")).hexdigest()),
        )
        for name, part in zip(names, parts)
    )
    loader = r'''-- CC Miner V4 %ROLE% split offline installer loader
-- Generated by tools/build_offline_bundle.py. Keep this file and the adjacent
-- ccminer-offline-%ROLE%.parts directory together during transfer.
local ROLE, VERSION, SCHEMA = "%ROLE%", "%VERSION%", %SCHEMA%
local EXPECTED_ASSEMBLED_DIGEST = "%ASSEMBLED_DIGEST%"
local partManifest = {
%PART_METADATA%
}
local args = { ... }
local action = string.lower(tostring(args[1] or ""))
if action == "" then action = ROLE end
if action ~= ROLE and action ~= "update" and action ~= "update-low-space" then
  error("This offline loader is fixed to role " .. ROLE .. "; refusing action " .. tostring(action), 0)
end
local function digest(text)
  if not textutils or type(textutils.sha256) ~= "function" then
    error("textutils.sha256 is required for strict offline bundle verification.", 0)
  end
  local ok, value = pcall(textutils.sha256, text or "")
  if not ok or type(value) ~= "string" then error("Offline bundle digest failed: " .. tostring(value), 0) end
  return string.lower(value)
end
local running = shell and shell.getRunningProgram and shell.getRunningProgram() or ""
local runningPath = running ~= "" and running or ("ccminer-offline-" .. ROLE .. ".lua")
local base = fs.getDir(runningPath)
local loaderPath = fs.combine(base, "ccminer-offline-" .. ROLE .. ".lua")
local partDir = fs.combine(base, "ccminer-offline-" .. ROLE .. ".parts")
local source = {}
if not fs.isDir(partDir) then error("Missing offline installer parts directory: " .. partDir, 0) end
local found = {}
for _, name in ipairs(fs.list(partDir)) do found[name] = true end
local nameWidth = math.max(2, string.len(tostring(#partManifest)))
for index, item in ipairs(partManifest) do
  local expectedName = ("%0" .. tostring(nameWidth) .. "d.part"):format(index)
  if item.name ~= expectedName then
    error("Offline part order metadata is invalid at index " .. tostring(index), 0)
  end
  if not found[item.name] then error("Missing offline installer part: " .. fs.combine(partDir, item.name), 0) end
  found[item.name] = nil
  local path = fs.combine(partDir, item.name)
  local handle = fs.open(path, "rb")
  if not handle then error("Cannot read offline installer part: " .. path, 0) end
  local text = handle.readAll(); handle.close()
  if #text ~= item.bytes then error("Offline installer part size mismatch: " .. item.name, 0) end
  if digest(text) ~= string.lower(item.digest) then error("Offline installer part digest mismatch: " .. item.name, 0) end
  source[index] = text
end
for extra in pairs(found) do error("Unexpected offline installer part: " .. tostring(extra), 0) end
if #source ~= #partManifest then error("Offline installer part count mismatch", 0) end
local assembled = table.concat(source)
if digest(assembled) ~= string.lower(EXPECTED_ASSEMBLED_DIGEST) then
  error("Offline installer assembled digest mismatch", 0)
end
local loadSource = loadstring or load
local program, compileError = loadSource(assembled, "@ccminer-offline-%ROLE%.assembled.lua")
if not program then error("Cannot assemble offline installer: " .. tostring(compileError), 0) end

-- A verified installer is now resident in memory.  Free the transferred
-- bundle before it allocates /ccminer.update; a failed cleanup must never run
-- the installer because that would defeat the one-megabyte install contract.
print("Verified CC Miner V4 %ROLE% offline bundle (" .. tostring(#partManifest) .. " parts).")
print("Removing the transferred loader and parts to free space ...")
if fs.exists(partDir) then fs.delete(partDir) end
if fs.exists(partDir) then error("Offline bundle cleanup failed: parts directory remains. Runtime was not started. Re-transfer the original ccminer-offline-%ROLE%.lua and parts.", 0) end
if fs.exists(loaderPath) then fs.delete(loaderPath) end
if fs.exists(loaderPath) then error("Offline bundle cleanup failed: loader remains. Runtime was not started. Re-transfer the original ccminer-offline-%ROLE%.lua and parts.", 0) end
print("Offline bundle removed. Keep the original transfer so it can be retransferred for recovery.")
local unpackArgs = table.unpack or unpack
return program(unpackArgs(args))
'''
    loader = (
        loader.replace("%ROLE%", role)
        .replace("%VERSION%", VERSION)
        .replace("%SCHEMA%", str(SCHEMA))
        .replace("%ASSEMBLED_DIGEST%", assembled_digest)
        .replace("%PART_METADATA%", part_metadata)
    )
    return parts, names, loader


def render_bundle(role: str = "worker") -> tuple[list[str], list[str], str]:
    """Backward-compatible alias for rendering a role bundle."""

    return render_role_bundle(role)


def build_dispatcher() -> str:
    """Render the tiny legacy entry point which dispatches by role."""

    return r'''-- CC Miner V4 compatibility dispatcher
-- Generated by tools/build_offline_bundle.py. Keep the three role loaders and
-- their parts directories beside this file when transferring offline.
local args = { ... }
local action = string.lower(tostring(args[1] or ""))
local function readRole()
  if not fs.exists("/ccminer/config.db") or fs.isDir("/ccminer/config.db") then return nil end
  local handle = fs.open("/ccminer/config.db", "r")
  if not handle then return nil end
  local text = handle.readAll(); handle.close()
  if not textutils or type(textutils.unserialize) ~= "function" then return nil end
  local ok, config = pcall(textutils.unserialize, text)
  if not ok or type(config) ~= "table" then return nil end
  return config.role
end
local role = action
if action == "" then role = turtle and "worker" or "controller" end
if action == "update" or action == "update-low-space" then role = readRole() end
if role ~= "worker" and role ~= "controller" and role ~= "gps" then
  print("CC Miner V4 offline dispatcher")
  print("  ccminer-offline.lua worker | controller | gps")
  print("  ccminer-offline.lua update | update-low-space (uses /ccminer/config.db role)")
  if action == "update" or action == "update-low-space" then
    error("Cannot determine an existing config role for " .. action .. ".", 0)
  end
  return
end
local running = shell and shell.getRunningProgram and shell.getRunningProgram() or "ccminer-offline.lua"
local loader = fs.combine(fs.getDir(running), "ccminer-offline-" .. role .. ".lua")
if not fs.exists(loader) then
  error("Missing role loader: " .. loader .. ". Transfer that loader and its parts directory.", 0)
end
local program, compileError = loadfile(loader)
if not program then error("Cannot load role loader: " .. tostring(compileError), 0) end
local unpackArgs = table.unpack or unpack
return program(unpackArgs(args))
'''


def _expected_outputs() -> tuple[dict[str, tuple[list[str], list[str], str]], str]:
    bundles = {role: render_role_bundle(role) for role in ROLE_ORDER}
    return bundles, build_dispatcher()


def _check_one_bundle(role: str, parts: list[str], names: list[str], loader: str) -> None:
    dist = ROOT / "dist"
    parts_dir = dist / f"ccminer-offline-{role}.parts"
    output = dist / f"ccminer-offline-{role}.lua"
    if not parts_dir.is_dir():
        raise SystemExit(f"Offline {role} bundle is stale: missing parts directory. Run: python tools/build_offline_bundle.py")
    actual_names = sorted(path.name for path in parts_dir.iterdir())
    if actual_names != names:
        raise SystemExit(f"Offline {role} bundle is stale: part list differs. Run: python tools/build_offline_bundle.py")
    for name, expected in zip(names, parts):
        path = parts_dir / name
        expected_bytes = expected.encode("utf-8")
        if path.read_bytes() != expected_bytes:
            raise SystemExit(f"Offline {role} bundle is stale: {name} differs. Run: python tools/build_offline_bundle.py")
        if path.stat().st_size <= 0 or path.stat().st_size > PART_LIMIT_BYTES:
            raise SystemExit(f"Offline {role} bundle part exceeds {PART_LIMIT_BYTES} bytes: {path}")
    if not output.is_file() or output.read_bytes() != loader.encode("utf-8"):
        raise SystemExit(f"Offline {role} bundle is stale: loader differs. Run: python tools/build_offline_bundle.py")
    total = sum(len(part.encode("utf-8")) for part in parts)
    print(f"Offline {role} bundle is current ({len(parts)} parts, {total} assembled bytes).")


def check_all_outputs() -> None:
    bundles, dispatcher = _expected_outputs()
    for role, (parts, names, loader) in bundles.items():
        _check_one_bundle(role, parts, names, loader)
    output = ROOT / "dist/ccminer-offline.lua"
    if not output.is_file() or output.read_bytes() != dispatcher.encode("utf-8"):
        raise SystemExit("Offline compatibility dispatcher is stale. Run: python tools/build_offline_bundle.py")
    legacy_parts = ROOT / "dist/ccminer-offline.parts"
    if legacy_parts.exists():
        raise SystemExit("Legacy dist/ccminer-offline.parts remains; run python tools/build_offline_bundle.py")
    print("Offline role bundles and compatibility dispatcher are current.")


def check_outputs(parts: list[str], names: list[str], loader: str, role: str = "worker") -> None:
    """Backward-compatible strict check for one role (normally worker)."""

    _check_one_bundle(role, parts, names, loader)


def _replace_target(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    os.replace(source, target)


def write_all_outputs() -> None:
    """Atomically replace all role bundles and the compatibility dispatcher."""

    bundles, dispatcher = _expected_outputs()
    dist = ROOT / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    targets: list[tuple[Path, Path]] = []
    with tempfile.TemporaryDirectory(prefix=".ccminer-offline.", dir=dist) as temporary:
        stage = Path(temporary)
        for role, (parts, names, loader) in bundles.items():
            stage_parts = stage / f"ccminer-offline-{role}.parts"
            stage_parts.mkdir()
            for name, part in zip(names, parts):
                (stage_parts / name).write_text(part, encoding="utf-8", newline="\n")
            stage_loader = stage / f"ccminer-offline-{role}.lua"
            stage_loader.write_text(loader, encoding="utf-8", newline="\n")
            targets.extend(
                [
                    (stage_loader, dist / stage_loader.name),
                    (stage_parts, dist / stage_parts.name),
                ]
            )
        stage_dispatcher = stage / "ccminer-offline.lua"
        stage_dispatcher.write_text(dispatcher, encoding="utf-8", newline="\n")
        targets.append((stage_dispatcher, dist / stage_dispatcher.name))

        # The old split bundle is intentionally retired in the same atomic
        # transaction.  It is included in the backup set so a failed replace
        # restores the complete previous distribution.
        legacy = dist / "ccminer-offline.parts"
        target_paths = [target for _, target in targets] + [legacy]
        backup_root = Path(tempfile.mkdtemp(prefix=".ccminer-offline-backup.", dir=dist))
        moved_backups: list[tuple[Path, Path]] = []
        installed: list[Path] = []
        committed = False
        try:
            for target in target_paths:
                if target.exists():
                    backup = backup_root / target.name
                    os.replace(target, backup)
                    moved_backups.append((backup, target))
            for source, target in targets:
                _replace_target(source, target)
                installed.append(target)
            committed = True
        except Exception:
            for target in reversed(installed):
                if target.exists():
                    if target.is_dir():
                        shutil.rmtree(target)
                    else:
                        target.unlink()
            for backup, target in reversed(moved_backups):
                if backup.exists():
                    os.replace(backup, target)
            raise
        finally:
            if committed and backup_root.exists():
                shutil.rmtree(backup_root)

    totals = ", ".join(
        f"{role}={len(parts)} parts/{sum(len(part.encode('utf-8')) for part in parts)} bytes"
        for role, (parts, _, _) in bundles.items()
    )
    print(f"Wrote role-scoped offline bundles ({totals}; each part <= {PART_LIMIT_BYTES}) and dispatcher.")


def write_outputs(parts: list[str], names: list[str], loader: str) -> None:
    """Backward-compatible writer; normal CLI always writes all roles."""

    # Preserve the old function for external tooling while still using the
    # same atomic directory replacement semantics for the requested role.
    role = "worker"
    dist = ROOT / "dist"
    parts_dir = dist / f"ccminer-offline-{role}.parts"
    output = dist / f"ccminer-offline-{role}.lua"
    dist.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".ccminer-offline-{role}.", dir=dist) as temporary:
        stage = Path(temporary)
        stage_parts = stage / parts_dir.name
        stage_parts.mkdir()
        for name, part in zip(names, parts):
            (stage_parts / name).write_text(part, encoding="utf-8", newline="\n")
        stage_loader = stage / output.name
        stage_loader.write_text(loader, encoding="utf-8", newline="\n")
        backup_root = Path(tempfile.mkdtemp(prefix=".ccminer-offline-backup.", dir=dist))
        moved: list[tuple[Path, Path]] = []
        installed: list[Path] = []
        committed = False
        try:
            for target in (output, parts_dir):
                if target.exists():
                    backup = backup_root / target.name
                    os.replace(target, backup)
                    moved.append((backup, target))
            for source, target in ((stage_loader, output), (stage_parts, parts_dir)):
                os.replace(source, target)
                installed.append(target)
            committed = True
        except Exception:
            for target in reversed(installed):
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.exists():
                    target.unlink()
            for backup, target in reversed(moved):
                if backup.exists():
                    os.replace(backup, target)
            raise
        finally:
            if committed and backup_root.exists():
                shutil.rmtree(backup_root)
    total = sum(len(part.encode("utf-8")) for part in parts)
    print(f"Wrote dist/{output.name} and {len(parts)} parts ({total} assembled bytes; each <= {PART_LIMIT_BYTES})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if tracked dist role bundles are stale")
    args = parser.parse_args()
    if args.check:
        check_all_outputs()
    else:
        write_all_outputs()


if __name__ == "__main__":
    main()
