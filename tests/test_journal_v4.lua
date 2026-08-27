-- V4 journal compatibility and REHOME cleanup contracts.

local root = assert(arg[1], "repository root is required")

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "rb"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function marker(text, expected, label)
  assert(text:find(expected, 1, true), "missing " .. label .. " source contract: " .. expected)
end

local worker = read("src/ccminer/worker_parts/01.part")
local command = read("src/ccminer/command.lua")

marker(worker, "state.journal.seq, state.journal.sequence = journalSequence, journalSequence", "legacy counter synchronization")
marker(worker, "state.journal.sequence = state.journal.seq", "journal alias advancement")
marker(worker, 'pcall(textutils.serialize, entry, { compact = true })', "one-line journal serialization")
marker(worker, "state.journal.lastEntryAt = entry.at", "journal entry timestamp")

marker(command, 'table.concat(pendingLines, "\\n")', "legacy multiline journal decoder")
marker(command, "seqValue > 0 and sequenceValue > 0", "zero-alias migration tolerance")
marker(command, 'journal.path or "/ccminer/data/state.journal"', "REHOME journal cleanup")
marker(command, 'journal.checkpointPath or "/ccminer/data/state.checkpoint.db"', "REHOME checkpoint cleanup")
marker(command, 'journal.pendingPath or "/ccminer/data/state.pending"', "REHOME pending cleanup")
marker(command, 'Do not reboot until those files are removed.', "fail-closed cleanup warning")

-- The Doctor decoder must accept both the old pretty-printed table stream and
-- the new compact one-record-per-line stream.  Standard Lua's loader stands in
-- for CC's textutils.unserialize for this focused format test.
local function decode(value)
  local loader = loadstring or load
  local fn = loader("return " .. value, "@journal-entry")
  if not fn then return nil end
  local ok, result = pcall(fn)
  if ok and type(result) == "table" then return result end
  return nil
end

local function journalSequences(text)
  local sequences, malformed, pending = {}, 0, {}
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line ~= "" then
      if #pending == 0 and not line:match("^%s*{") then
        malformed = malformed + 1
      else
        pending[#pending + 1] = line
        local entry = decode(table.concat(pending, "\n"))
        if entry then
          local sequence = tonumber(entry.seq or entry.sequence)
          if not sequence or (#sequences > 0 and sequence <= sequences[#sequences]) then
            malformed = malformed + 1
          else
            sequences[#sequences + 1] = sequence
          end
          pending = {}
        end
      end
    end
  end
  if #pending > 0 then malformed = malformed + 1 end
  return sequences, malformed
end

local legacy = table.concat({
  "{",
  "  seq = 1,",
  '  event = "boot",',
  "  pose = { x = 0, y = 0, z = 0, dir = 0 },",
  "}",
  "{",
  "  seq = 2,",
  '  event = "idle",',
  "}",
}, "\n")
local legacySequences, legacyMalformed = journalSequences(legacy)
assert(legacyMalformed == 0 and #legacySequences == 2 and legacySequences[2] == 2, "legacy multiline journal must decode")

local compact = '{seq=3,event="start"}\n{seq=4,event="move"}'
local compactSequences, compactMalformed = journalSequences(compact)
assert(compactMalformed == 0 and #compactSequences == 2 and compactSequences[1] == 3 and compactSequences[2] == 4, "compact journal must decode")

local _, repeatedMalformed = journalSequences('{seq=4}\n{seq=4}')
assert(repeatedMalformed == 1, "non-monotonic journal sequence must still fail")

print("journal compact writing, legacy decoding, counters, and REHOME cleanup contracts passed")
