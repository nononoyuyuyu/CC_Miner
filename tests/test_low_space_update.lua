-- Low-space installer source contract.  The update path must not move or
-- delete the complete installation tree, and it must leave a resumable marker.

local root = assert(arg[1], "repository root is required")

local function read(relative)
  local handle = assert(io.open(root .. "/" .. relative, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function requireText(text, needle, label)
  assert(text:find(needle, 1, true), "missing " .. label .. ": " .. needle)
end

local installer = read("install.lua")
requireText(installer, "update-low-space", "online low-space action")
requireText(installer, "LOW_SPACE_MARKER", "online recovery marker")
requireText(installer, "validateLowSpaceStage", "online pre-commit syntax validation")
requireText(installer, "state=", "marker state contract")
requireText(installer, "User data under /ccminer", "online user-data safety message")
requireText(installer, "Free space", "capacity failure guidance")

local lowStart = assert(installer:find('if action == "update-low-space" then', 1, true), "online low-space branch")
local lowEnd = assert(installer:find("if fs.exists(BACKUP)", lowStart, true), "online normal swap boundary")
local lowSpace = installer:sub(lowStart, lowEnd - 1)
assert(not lowSpace:find("moveChecked", 1, true), "low-space branch must not move a complete tree")
assert(not lowSpace:find("fs.delete(ROOT)", 1, true), "low-space branch must not delete the complete tree")
requireText(lowSpace, "committing", "per-file commit marker")

local builder = read("tools/build_offline_bundle.py")
requireText(builder, "update-low-space", "offline low-space action")
requireText(builder, "LOW_SPACE_MARKER", "offline recovery marker")
requireText(builder, "validateLowSpaceStage", "offline pre-commit syntax validation")

local installDocs = read("docs/03-install.md")
requireText(installDocs, "install.lua update-low-space", "online low-space documentation")
requireText(installDocs, "ccminer-offline.lua update-low-space", "offline low-space documentation")

print("low-space installer source contracts passed")
