#!/usr/bin/env python3
"""Run repository integrity checks without requiring a Minecraft client."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_SOURCES = [
    "src/ccminer/lib/common.lua",
    "src/ccminer/lib/protocol.lua",
    "src/ccminer/lib/quarry.lua",
    "src/ccminer/worker.lua",
    "src/ccminer/controller.lua",
    "src/ccminer/setup.lua",
    "src/ccminer/boot.lua",
    "src/ccminer/command.lua",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def find_lua() -> str:
    configured = os.environ.get("CCMINER_LUA")
    candidates = [configured] if configured else []
    candidates += ["texlua", "lua5.2", "lua"]
    for candidate in candidates:
        if candidate and shutil.which(candidate):
            return candidate
    fail("No Lua interpreter found (tried texlua, lua5.2, lua).")
    raise AssertionError


def run(command: list[str]) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=ROOT, check=True)


def check_lua_syntax(lua: str) -> None:
    files = sorted(ROOT.rglob("*.lua"))
    checker = """
local failed = false
for i = 1, #arg do
  local fn, err = loadfile(arg[i])
  if not fn then
    io.stderr:write(arg[i] .. ": " .. tostring(err) .. "\\n")
    failed = true
  end
end
if failed then os.exit(1) end
"""
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(checker)
        checker_path = handle.name
    try:
        run([lua, checker_path, *[str(path.relative_to(ROOT)) for path in files]])
    finally:
        Path(checker_path).unlink(missing_ok=True)


def check_runtime_lists() -> None:
    manifest = (ROOT / "manifest.lua").read_text(encoding="utf-8")
    installer = (ROOT / "install.lua").read_text(encoding="utf-8")
    builder = (ROOT / "tools/build_offline_bundle.py").read_text(encoding="utf-8")
    for source in RUNTIME_SOURCES:
        if source not in manifest:
            fail(f"manifest.lua is missing {source}")
        if source not in installer:
            fail(f"install.lua is missing {source}")
        if source not in builder:
            fail(f"offline builder is missing {source}")
        if not (ROOT / source).is_file():
            fail(f"runtime source does not exist: {source}")


def check_markdown_links() -> None:
    link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
    for document in sorted([ROOT / "README.md", *ROOT.glob("docs/*.md")]):
        text = document.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(text):
            target = raw_target.split("#", 1)[0].strip()
            if not target or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", target):
                continue
            resolved = (document.parent / target).resolve()
            if not resolved.exists():
                fail(f"broken relative link in {document.relative_to(ROOT)}: {raw_target}")


def check_github_scope() -> None:
    allowed = (
        "github.com/nononoyuyuyu/CC_Miner",
        "raw.githubusercontent.com/nononoyuyuyu/CC_Miner",
    )
    url_pattern = re.compile(r"https?://[^\s)\]>'\"]+")
    text_extensions = {".md", ".lua", ".py", ".yml", ".yaml", ".txt"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in text_extensions:
            continue
        text = path.read_text(encoding="utf-8")
        for url in url_pattern.findall(text):
            if "github.com" in url or "githubusercontent.com" in url:
                if not any(allowed_part in url for allowed_part in allowed):
                    fail(f"out-of-scope GitHub URL in {path.relative_to(ROOT)}: {url}")


def check_bundle() -> None:
    bundle = ROOT / "dist/ccminer-offline.lua"
    if not bundle.is_file():
        fail("offline bundle was not generated")
    size = bundle.stat().st_size
    if size <= 1000:
        fail("offline bundle is unexpectedly small")
    if size > 900_000:
        fail(f"offline bundle is too large for comfortable ComputerCraft transfer: {size}")
    content = bundle.read_text(encoding="utf-8")
    for source in RUNTIME_SOURCES:
        target = source.removeprefix("src/ccminer/")
        if target not in content:
            fail(f"offline bundle is missing target {target}")


def main() -> None:
    run([sys.executable, "tools/build_offline_bundle.py"])
    lua = find_lua()
    check_lua_syntax(lua)
    run([lua, "tests/test_quarry.lua", str(ROOT)])
    run([lua, "tests/test_common.lua", str(ROOT)])
    check_runtime_lists()
    check_markdown_links()
    check_github_scope()
    check_bundle()
    print("All CC Miner V2 checks passed.")


if __name__ == "__main__":
    main()
