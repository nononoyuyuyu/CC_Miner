#!/usr/bin/env python3
"""Run repository integrity checks without requiring a Minecraft client.

Requires Python 3.10+ (and a Lua 5.2-compatible interpreter for full checks).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = [
    ("src/ccminer/lib/common.lua", "lib/common.lua"),
    ("src/ccminer/lib/protocol.lua", "lib/protocol.lua"),
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
    ("src/ccminer/setup.lua", "setup.lua"),
    ("src/ccminer/boot.lua", "boot.lua"),
    ("src/ccminer/command.lua", "command.lua"),
]
RUNTIME_SOURCES = [source for source, _ in RUNTIME_FILES]
WORKER_PARTS = [ROOT / f"src/ccminer/worker_parts/{index:02d}.part" for index in range(1, 6)]
CONTROLLER_PARTS = [ROOT / f"src/ccminer/controller_parts/{index:02d}.part" for index in range(1, 4)]
OFFLINE_PART_LIMIT = 12_000


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


def concatenate(paths: list[Path]) -> str:
    missing = [str(path.relative_to(ROOT)) for path in paths if not path.is_file()]
    if missing:
        fail("missing source parts: " + ", ".join(missing))
    return "".join(path.read_text(encoding="utf-8") for path in paths)


def offline_parts() -> list[Path]:
    parts_dir = ROOT / "dist/ccminer-offline.parts"
    if not parts_dir.is_dir():
        return []
    return sorted(parts_dir.glob("*.part"), key=lambda path: int(path.stem) if path.stem.isdigit() else -1)


def check_lua_syntax(lua: str) -> None:
    files = sorted(ROOT.rglob("*.lua"))
    generated: list[Path] = []
    for label, source in [
        ("worker-assembled", concatenate(WORKER_PARTS)),
        ("controller-assembled", concatenate(CONTROLLER_PARTS)),
        ("offline-installer-assembled", concatenate(offline_parts())),
    ]:
        handle = tempfile.NamedTemporaryFile("w", suffix=f"-{label}.lua", encoding="utf-8", delete=False)
        with handle:
            handle.write(source)
        generated.append(Path(handle.name))

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
        checker_path = Path(handle.name)
    try:
        arguments = [str(path.relative_to(ROOT)) for path in files] + [str(path) for path in generated]
        run([lua, str(checker_path), *arguments])
    finally:
        checker_path.unlink(missing_ok=True)
        for path in generated:
            path.unlink(missing_ok=True)


def check_runtime_lists() -> None:
    manifest = (ROOT / "manifest.lua").read_text(encoding="utf-8")
    installer = (ROOT / "install.lua").read_text(encoding="utf-8")
    builder = (ROOT / "tools/build_offline_bundle.py").read_text(encoding="utf-8")
    common = (ROOT / "src/ccminer/lib/common.lua").read_text(encoding="utf-8")

    manifest_sources = re.findall(r'^\s+"(src/ccminer/[^"]+)",\s*$', manifest, re.MULTILINE)
    installer_files = re.findall(
        r'{\s*source\s*=\s*"([^"]+)",\s*target\s*=\s*"([^"]+)"\s*}', installer
    )
    builder_list = builder.split("RUNTIME_FILES = [", 1)[1].split("\n]", 1)[0]
    builder_files = re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', builder_list)
    if manifest_sources != RUNTIME_SOURCES:
        fail("manifest.lua runtime source list differs from the authoritative check list")
    if installer_files != RUNTIME_FILES:
        fail("install.lua runtime source/target list differs from the authoritative check list")
    if builder_files != RUNTIME_FILES:
        fail("offline builder runtime source/target list differs from the authoritative check list")

    version_patterns = {
        "manifest.lua": (manifest, r'\bversion\s*=\s*"([^"]+)"'),
        "install.lua": (installer, r'\bVERSION\s*=\s*"([^"]+)"'),
        "offline builder": (builder, r'^VERSION\s*=\s*"([^"]+)"'),
        "common.lua": (common, r'\bM\.VERSION\s*=\s*"([^"]+)"'),
    }
    versions: dict[str, str] = {}
    for label, (text, pattern) in version_patterns.items():
        match = re.search(pattern, text, re.MULTILINE)
        if not match:
            fail(f"cannot find version in {label}")
        versions[label] = match.group(1)
    if len(set(versions.values())) != 1:
        fail("version mismatch: " + ", ".join(f"{label}={version}" for label, version in versions.items()))

    for source in RUNTIME_SOURCES:
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
    allowed_hosts = {"github.com", "raw.githubusercontent.com"}
    allowed_path = "/nononoyuyuyu/CC_Miner"
    url_pattern = re.compile(r"https?://[^\s)\]>'\"]+")
    text_extensions = {".md", ".lua", ".part", ".py", ".yml", ".yaml", ".txt"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in text_extensions:
            continue
        text = path.read_text(encoding="utf-8")
        for url in url_pattern.findall(text):
            parsed = urlsplit(url)
            host = (parsed.hostname or "").lower()
            if "github.com" in host or "githubusercontent.com" in host:
                if host not in allowed_hosts or not (
                    parsed.path == allowed_path or parsed.path.startswith(allowed_path + "/")
                ):
                    fail(f"out-of-scope GitHub URL in {path.relative_to(ROOT)}: {url}")


def check_feature_markers() -> None:
    worker = concatenate(WORKER_PARTS)
    controller = concatenate(CONTROLLER_PARTS)
    setup = (ROOT / "src/ccminer/setup.lua").read_text(encoding="utf-8")
    required = {
        "worker GPS locate": (worker, "gps.locate"),
        "worker GPS pending recovery": (worker, "tryResolvePendingAction"),
        "worker lava sealing": (worker, "sealLava"),
        "worker seal refill state": (worker, "waiting_seal"),
        "worker chunk strategy": (worker, '"chunk_plan"'),
        "worker targeted commands": (worker, "tonumber(message.target) ~= tonumber(os.getComputerID())"),
        "controller monitor touch": (controller, 'event == "monitor_touch"'),
        "controller terminal click": (controller, 'event == "mouse_click"'),
        "controller keypad": (controller, '"CLR", "0", "<"'),
        "controller touch grid": (controller, '"NEW JOB - TOUCH GRID"'),
        "controller GPS calibration": (controller, '"calibrate_gps"'),
        "GPS setup role": (setup, 'requestedRole == "gps"'),
    }
    for label, (text, marker) in required.items():
        if marker not in text:
            fail(f"missing feature marker: {label}")


def almost_integer(value: float, tolerance: float = 1e-8) -> bool:
    return abs(value - round(value)) <= tolerance


def check_svg_grids() -> None:
    namespace = {"svg": "http://www.w3.org/2000/svg"}
    checked = 0
    for relative in ["docs/images/base-layout-top.svg", "docs/images/dock-side.svg"]:
        path = ROOT / relative
        root = ET.parse(path).getroot()
        groups = root.findall(".//svg:g[@id='block-grid']", namespace)
        if len(groups) != 1:
            fail(f"{relative} must contain exactly one g#block-grid")
        group = groups[0]
        cell = float(group.attrib["data-grid-cell"])
        origin_x = float(group.attrib.get("data-grid-origin-x", "0"))
        origin_y = float(group.attrib.get("data-grid-origin-y", "0"))
        blocks = [element for element in group.findall(".//svg:rect", namespace) if "grid-block" in element.attrib.get("class", "").split()]
        if not blocks:
            fail(f"{relative} has no grid-block rectangles")
        for block in blocks:
            x = float(block.attrib["x"])
            y = float(block.attrib["y"])
            width = float(block.attrib["width"])
            height = float(block.attrib["height"])
            if not almost_integer(width / cell) or not almost_integer(height / cell):
                fail(f"{relative} block size is not an integer grid multiple: {block.attrib}")
            x_aligned = almost_integer(x / cell) or almost_integer((x - origin_x) / cell)
            y_aligned = almost_integer(y / cell) or almost_integer((y - origin_y) / cell)
            if not x_aligned or not y_aligned:
                fail(f"{relative} block origin is off-grid: {block.attrib}")
            if "data-col" in block.attrib:
                col = int(block.attrib["data-col"])
                expected = {col * cell, origin_x + col * cell}
                if not any(abs(x - candidate) <= 1e-8 for candidate in expected):
                    fail(f"{relative} data-col disagrees with x: {block.attrib}")
            if "data-row" in block.attrib:
                row = int(block.attrib["data-row"])
                expected = {row * cell, origin_y + row * cell}
                if not any(abs(y - candidate) <= 1e-8 for candidate in expected):
                    fail(f"{relative} data-row disagrees with y: {block.attrib}")
            checked += 1
    print(f"SVG grid alignment passed ({checked} block rectangles).")


def check_bundle() -> None:
    loader = ROOT / "dist/ccminer-offline.lua"
    parts = offline_parts()
    if not loader.is_file() or not parts:
        fail("split offline bundle was not generated")
    names = [path.name for path in parts]
    name_width = max(2, len(str(len(parts))))
    expected = [f"{index:0{name_width}d}.part" for index in range(1, len(parts) + 1)]
    if names != expected:
        fail(f"offline parts are not contiguous: {names}")
    loader_text = loader.read_text(encoding="utf-8")
    for path in parts:
        size = path.stat().st_size
        if size <= 0 or size > OFFLINE_PART_LIMIT:
            fail(f"offline part has invalid size ({size}): {path.relative_to(ROOT)}")
        if path.name not in loader_text:
            fail(f"offline loader does not reference {path.name}")
    content = concatenate(parts)
    size = len(content.encode("utf-8"))
    if size <= 1_000 or size > 900_000:
        fail(f"assembled offline installer has unexpected size: {size}")
    for _, target in RUNTIME_FILES:
        if target not in content:
            fail(f"offline bundle is missing target {target}")
    print(f"Split offline bundle passed ({len(parts)} parts, {size} assembled bytes).")


def main() -> None:
    run([sys.executable, "tools/build_offline_bundle.py", "--check"])
    check_runtime_lists()
    check_markdown_links()
    check_github_scope()
    check_feature_markers()
    check_svg_grids()
    check_bundle()
    lua = find_lua()
    check_lua_syntax(lua)
    run([lua, "tests/test_startup.lua", str(ROOT)])
    run([lua, "tests/test_quarry.lua", str(ROOT)])
    run([lua, "tests/test_geo.lua", str(ROOT)])
    run([lua, "tests/test_common.lua", str(ROOT)])
    run([lua, "tests/test_protocol.lua", str(ROOT)])
    run([lua, "tests/test_controller_persistence.lua", str(ROOT)])
    run([lua, "tests/test_v3_contract.lua", str(ROOT)])
    print("All CC Miner V3 checks passed.")


if __name__ == "__main__":
    main()
