#!/usr/bin/env python3
"""Run repository integrity checks without requiring a Minecraft client.

Requires Python 3.10+ (and a Lua 5.2-compatible interpreter for full checks).
"""

from __future__ import annotations

import os
import re
import shutil
import hashlib
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
ROLE_ORDER = ("worker", "controller", "gps")

# This is the deliberately boring, ordered V4 manifest contract.  The three
# generated consumers (manifest.lua, install.lua and build_offline_bundle.py)
# are checked against it; none may silently add a file or reinterpret a role.
RUNTIME_ENTRIES = [
    ("src/ccminer/lib/common.lua", "lib/common.lua", ("worker", "controller", "gps")),
    ("src/ccminer/lib/protocol.lua", "lib/protocol.lua", ("worker", "controller", "gps")),
    ("src/ccminer/setup.lua", "setup.lua", ("worker", "controller", "gps")),
    ("src/ccminer/boot.lua", "boot.lua", ("worker", "controller", "gps")),
    ("src/ccminer/command.lua", "command.lua", ("worker", "controller", "gps")),
    ("src/ccminer/lib/geo.lua", "lib/geo.lua", ("worker",)),
    ("src/ccminer/lib/quarry.lua", "lib/quarry.lua", ("worker", "controller")),
    ("src/ccminer/worker.lua", "worker.lua", ("worker",)),
    ("src/ccminer/worker_parts/01.part", "worker_parts/01.part", ("worker",)),
    ("src/ccminer/worker_parts/02.part", "worker_parts/02.part", ("worker",)),
    ("src/ccminer/worker_parts/03.part", "worker_parts/03.part", ("worker",)),
    ("src/ccminer/worker_parts/04.part", "worker_parts/04.part", ("worker",)),
    ("src/ccminer/worker_parts/05.part", "worker_parts/05.part", ("worker",)),
    ("src/ccminer/controller.lua", "controller.lua", ("controller",)),
    ("src/ccminer/controller_parts/01.part", "controller_parts/01.part", ("controller",)),
    ("src/ccminer/controller_parts/02.part", "controller_parts/02.part", ("controller",)),
    ("src/ccminer/controller_parts/03.part", "controller_parts/03.part", ("controller",)),
    ("src/ccminer/gps_host.lua", "gps_host.lua", ("gps",)),
]
RUNTIME_FILES = [(source, target) for source, target, _ in RUNTIME_ENTRIES]
RUNTIME_SOURCES = [source for source, _, _ in RUNTIME_ENTRIES]
KNOWN_TARGETS = {target for _, target, _ in RUNTIME_ENTRIES}
ROLE_REQUIRED_TARGETS = {
    role: [target for _, target, roles in RUNTIME_ENTRIES if role in roles]
    for role in ROLE_ORDER
}
ROLE_ENTRYPOINTS = {"worker": "worker.lua", "controller": "controller.lua", "gps": "gps_host.lua"}
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


def offline_role_parts(role: str) -> list[Path]:
    parts_dir = ROOT / f"dist/ccminer-offline-{role}.parts"
    if not parts_dir.is_dir():
        return []
    return sorted(parts_dir.glob("*.part"), key=lambda path: int(path.stem) if path.stem.isdigit() else -1)


def offline_parts() -> list[Path]:
    """Compatibility helper for callers which still ask for the old bundle."""

    legacy = ROOT / "dist/ccminer-offline.parts"
    if not legacy.is_dir():
        return []
    return sorted(legacy.glob("*.part"), key=lambda path: int(path.stem) if path.stem.isdigit() else -1)


def check_lua_syntax(lua: str) -> None:
    files = sorted(ROOT.rglob("*.lua"))
    generated: list[Path] = []
    assemblies: list[tuple[str, str]] = [
        ("worker-assembled", concatenate(WORKER_PARTS)),
        ("controller-assembled", concatenate(CONTROLLER_PARTS)),
    ]
    for role in ROLE_ORDER:
        parts = offline_role_parts(role)
        assemblies.append((f"offline-{role}-installer-assembled", concatenate(parts)))
    for label, source in assemblies:
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


def _parse_lua_runtime_entries(text: str, label: str) -> list[tuple[str, str, tuple[str, ...]]]:
    """Parse explicit ``source/target/roles`` entries without executing Lua."""

    pattern = re.compile(
        r'\{\s*source\s*=\s*"([^"]+)"\s*,\s*target\s*=\s*"([^"]+)"'
        r'\s*,\s*roles\s*=\s*\{(.*?)\}\s*\}',
        re.DOTALL,
    )
    entries: list[tuple[str, str, tuple[str, ...]]] = []
    role_pattern = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(true|false)')
    for match in pattern.finditer(text):
        source, target, role_text = match.groups()
        roles: list[str] = []
        consumed: list[str] = []
        for role_match in role_pattern.finditer(role_text):
            role, enabled = role_match.groups()
            consumed.append(role_match.group(0))
            if role not in ROLE_ORDER:
                fail(f"unknown runtime role in {label}: {role}")
            if enabled != "true":
                fail(f"runtime role must be true in {label}: {role}")
            roles.append(role)
        residual = role_text
        for token in consumed:
            residual = residual.replace(token, "", 1)
        if residual.strip(" ,\t\r\n"):
            fail(f"cannot parse runtime roles in {label}: {role_text!r}")
        if not roles or len(set(roles)) != len(roles):
            fail(f"runtime roles are empty or duplicated in {label}: {source}")
        entries.append((source, target, tuple(roles)))
    source_markers = re.findall(r'\{\s*source\s*=\s*"', text)
    if len(source_markers) != len(entries):
        fail(f"runtime entry parse did not consume every source entry in {label}")
    return entries


def _parse_python_pairs(text: str, name: str) -> list[tuple[str, str]]:
    match = re.search(rf'(?ms)^{re.escape(name)}\s*=.*?^\]', text)
    if not match:
        fail(f"cannot find {name} list in offline builder")
    return re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', match.group(0))


def _parse_builder_role_files(builder: str) -> dict[str, str]:
    match = re.search(r'(?ms)^ROLE_FILES\s*:\s*dict\[.*?\]\s*=\s*\{(.*?)^\}', builder)
    if not match:
        fail("cannot find ROLE_FILES in offline builder")
    return dict(re.findall(r'"([^"]+)"\s*:\s*([A-Z_]+)', match.group(1)))


def _parse_builder_role_order(builder: str) -> tuple[str, ...]:
    match = re.search(r'^ROLE_ORDER\s*=\s*\(([^)]*)\)', builder, re.MULTILINE)
    if not match:
        fail("cannot find ROLE_ORDER in offline builder")
    return tuple(re.findall(r'"([^"]+)"', match.group(1)))


def _parse_builder_entrypoints(builder: str) -> dict[str, str]:
    match = re.search(r'(?ms)^ROLE_ENTRYPOINTS\s*=\s*\{(.*?)\}', builder)
    if not match:
        fail("cannot find ROLE_ENTRYPOINTS in offline builder")
    return dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', match.group(1)))


def _parse_installer_role_map(installer: str) -> tuple[str, ...]:
    match = re.search(r'(?ms)^local\s+ROLES\s*=\s*\{(.*?)\}', installer)
    if not match:
        fail("cannot find ROLES map in install.lua")
    return tuple(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*true', match.group(1)))


def _parse_installer_part_targets(installer: str, role: str) -> list[str]:
    if role == "gps":
        return []
    match = re.search(
        rf'(?:if|elseif)\s+role\s*==\s*"{re.escape(role)}"\s*then\s*return\s*\{{(.*?)\}}\s*(?:elseif|end)',
        installer,
        re.DOTALL,
    )
    if not match:
        fail(f"cannot find install.lua part targets for {role}")
    return re.findall(r'"([^"]+)"', match.group(1))


def _parse_installer_version_schema(installer: str) -> tuple[str, int]:
    """Read the installer's version/schema declaration.

    ``install.lua`` keeps the two values in one Lua tuple assignment.  Parse
    that declaration as a unit so the schema cannot be accidentally taken from
    an unrelated ``SCHEMA`` token later in the installer.  The separate-local
    form remains accepted for compatibility with older installers.
    """

    tuple_match = re.search(
        r'(?m)^\s*local\s+VERSION\s*,\s*SCHEMA\s*=\s*"([^"\\]+)"\s*,\s*(\d+)\b',
        installer,
    )
    if tuple_match:
        return tuple_match.group(1), int(tuple_match.group(2))

    version_match = re.search(r'(?m)^\s*local\s+VERSION\s*=\s*"([^"\\]+)"', installer)
    schema_match = re.search(r'(?m)^\s*local\s+SCHEMA\s*=\s*(\d+)\b', installer)
    if not version_match:
        fail("cannot find version in install.lua")
    if not schema_match:
        fail("cannot find schema in install.lua")
    return version_match.group(1), int(schema_match.group(1))


def check_runtime_lists() -> None:
    manifest = (ROOT / "manifest.lua").read_text(encoding="utf-8")
    installer = (ROOT / "install.lua").read_text(encoding="utf-8")
    builder = (ROOT / "tools/build_offline_bundle.py").read_text(encoding="utf-8")
    common = (ROOT / "src/ccminer/lib/common.lua").read_text(encoding="utf-8")

    expected_entries = RUNTIME_ENTRIES
    manifest_entries = _parse_lua_runtime_entries(manifest, "manifest.lua")
    installer_entries = _parse_lua_runtime_entries(installer, "install.lua")
    expected_pairs = [(source, target) for source, target, _ in expected_entries]
    if manifest_entries != expected_entries:
        fail("manifest.lua runtime source/target/roles list differs (extra, missing, order, or role mismatch)")
    if installer_entries != expected_entries:
        fail("install.lua FILES source/target/roles list differs (extra, missing, order, or role mismatch)")

    common_files = _parse_python_pairs(builder, "COMMON_FILES")
    worker_extra = _parse_python_pairs(builder, "WORKER_FILES")
    controller_extra = _parse_python_pairs(builder, "CONTROLLER_FILES")
    gps_extra = _parse_python_pairs(builder, "GPS_FILES")
    builder_runtime_extra = _parse_python_pairs(builder, "RUNTIME_FILES")
    builder_runtime = common_files + builder_runtime_extra
    if builder_runtime != expected_pairs:
        fail("offline builder RUNTIME_FILES differs from the authoritative source/target order")
    expected_role_pairs = {
        role: [(source, target) for source, target, roles in expected_entries if role in roles]
        for role in ROLE_ORDER
    }
    builder_roles = {
        "worker": common_files + worker_extra,
        "controller": common_files + controller_extra,
        "gps": common_files + gps_extra,
    }
    if builder_roles != expected_role_pairs:
        fail("offline builder ROLE_FILES dependencies/order differ from manifest role projections")
    if _parse_builder_role_files(builder) != {
        "worker": "WORKER_FILES",
        "controller": "CONTROLLER_FILES",
        "gps": "GPS_FILES",
    }:
        fail("offline builder ROLE_FILES mapping has an extra, missing, or wrong role")
    if _parse_builder_role_order(builder) != ROLE_ORDER:
        fail("offline builder ROLE_ORDER differs from the V4 role order")
    if _parse_builder_entrypoints(builder) != ROLE_ENTRYPOINTS:
        fail("offline builder ROLE_ENTRYPOINTS differs from known runtime targets")
    if _parse_installer_role_map(installer) != ROLE_ORDER:
        fail("install.lua ROLES map differs from the V4 role order")

    for role, pairs in expected_role_pairs.items():
        targets = [target for _, target in pairs]
        if any(target not in KNOWN_TARGETS for target in targets):
            fail(f"{role} role contains an unknown runtime target")
        required = ROLE_REQUIRED_TARGETS[role]
        if targets != required:
            fail(f"{role} role is missing a required dependency or has an extra target")
        part_targets = _parse_installer_part_targets(installer, role)
        expected_parts = [target for target in required if target.startswith(f"{role}_parts/")]
        if part_targets != expected_parts:
            fail(f"install.lua {role} part targets differ from required role parts")
        loader_pattern = rf'if role\s*==\s*"{re.escape(role)}"\s*then\s*return\s*"([^"]+)"\s*end'
        loader_match = re.search(loader_pattern, installer)
        if not loader_match or loader_match.group(1) != ROLE_ENTRYPOINTS[role]:
            fail(f"install.lua loader target for {role} is unknown or misplaced")
    for source in RUNTIME_SOURCES:
        if not (ROOT / source).is_file():
            fail(f"runtime source does not exist: {source}")

    installer_version, installer_schema = _parse_installer_version_schema(installer)
    version_patterns = {
        "manifest.lua": (manifest, r'\bversion\s*=\s*"([^"\\]+)"'),
        "offline builder": (builder, r'^VERSION\s*=\s*"([^"\\]+)"'),
        "common.lua": (common, r'\bM\.VERSION\s*=\s*"([^"\\]+)"'),
    }
    versions: dict[str, str] = {}
    for label, (text, pattern) in version_patterns.items():
        match = re.search(pattern, text, re.MULTILINE)
        if not match:
            fail(f"cannot find version in {label}")
        versions[label] = match.group(1)
    versions["install.lua"] = installer_version
    if set(versions.values()) != {"4.0.0"}:
        fail("V4 version mismatch: " + ", ".join(f"{label}={version}" for label, version in versions.items()))
    schema_patterns = {
        "manifest.lua": (manifest, r'\bschema\s*=\s*(\d+)'),
        "offline builder": (builder, r'^SCHEMA\s*=\s*(\d+)'),
        "common.lua": (common, r'\bM\.SCHEMA\s*=\s*(\d+)'),
    }
    schemas: dict[str, int] = {}
    for label, (text, pattern) in schema_patterns.items():
        match = re.search(pattern, text, re.MULTILINE)
        if not match:
            fail(f"cannot find schema in {label}")
        schemas[label] = int(match.group(1))
    schemas["install.lua"] = installer_schema
    if set(schemas.values()) != {4}:
        fail("V4 schema mismatch: " + ", ".join(f"{label}={schema}" for label, schema in schemas.items()))


def check_github_scope() -> None:
    allowed_hosts = {"github.com", "raw.githubusercontent.com"}
    allowed_path = "/nononoyuyuyu/CC_Miner"
    url_pattern = re.compile(r"(?:https?://|//)[^\s)\]>'\"]+")
    text_extensions = {
        ".md",
        ".lua",
        ".part",
        ".py",
        ".yml",
        ".yaml",
        ".txt",
        ".html",
        ".css",
        ".js",
    }
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
    quarry = (ROOT / "src/ccminer/lib/quarry.lua").read_text(encoding="utf-8")
    setup = (ROOT / "src/ccminer/setup.lua").read_text(encoding="utf-8")
    manifest = (ROOT / "manifest.lua").read_text(encoding="utf-8")
    installer = (ROOT / "install.lua").read_text(encoding="utf-8")
    builder = (ROOT / "tools/build_offline_bundle.py").read_text(encoding="utf-8")
    required = {
        # V4 group assignment is fail-closed and never falls back to a full
        # footprint when metadata or the authoritative catalog is missing.
        "worker group assignment extraction": (worker, "local assignmentChunks = payload.assignmentChunks"),
        "worker group assignment refusal": (worker, "Group assignment keys are required; refusing full-footprint fallback."),
        "worker group catalog guard": (worker, "Group assignment requires the authoritative chunk catalog."),
        # Discard policy is explicit and reports skipped/unknown items.
        "worker discard policy": (worker, "local function discardPolicy()"),
        "worker discard protection": (worker, "local function discardProtectedItem(slot, name)"),
        "worker discard metrics": (worker, "state.stats.discardPasses = (state.stats.discardPasses or 0) + 1"),
        # Route execution is bounded by the assigned chunk graph and durable
        # route metrics/checkpoints.
        "worker service route": (worker, "local function navigateServiceRoute(plan, fromPose, toPose, context, mode)"),
        "worker route hard refusal": (worker, "No safe chunk service route."),
        "worker route audit": (worker, "state.routeMetrics.lastRoute = { kind = routeKind or \"fallback\", chunkKeys = common.copy(keys) }"),
        "controller service route": (quarry, "function M.shortestServiceRoute(plan, fromPose, toPose, options)"),
        # Every world-group worker needs a distinct, in-catalog bay chunk.
        "controller unique bay": (controller, "bay chunk unique:"),
        "quarry unique bay": (quarry, "duplicate_worker_bay_chunk:"),
        "quarry bay catalog guard": (quarry, "worker_bay_outside_catalog:"),
        # Existing V4 operator surfaces remain covered while the new markers
        # above guard the safety-critical implementation paths.
        "controller monitor touch": (controller, 'event == "monitor_touch"'),
        "controller terminal click": (controller, 'event == "mouse_click"'),
        "controller touch grid": (controller, '"NEW JOB - TOUCH GRID"'),
        "controller GPS calibration": (controller, '"calibrate_gps"'),
        "GPS setup role": (setup, 'requestedRole == "gps"'),
        # Distribution is role-scoped in all three generated consumers.
        "manifest role distribution": (manifest, "roles = { worker = true, controller = true, gps = true }"),
        "installer role distribution": (installer, "local ROLES = { worker = true, controller = true, gps = true }"),
        "builder role distribution": (builder, 'ROLE_ORDER = ("worker", "controller", "gps")'),
        "builder role files": (builder, "ROLE_FILES: dict[str, list[tuple[str, str]]]"),
    }
    for label, (text, marker) in required.items():
        if marker not in text:
            fail(f"missing feature marker: {label}")


class ManualHTMLParser(HTMLParser):
    """Collect the small HTML contract shared by every manual page.

    ``HTMLParser`` intentionally does not try to build a browser DOM.  The
    manual is generated as strict, fully closed HTML, so a lightweight tag
    stack is enough to catch malformed nesting while keeping this check
    dependency-free.
    """

    VOID_ELEMENTS = {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.errors: list[str] = []
        self.doctypes: list[str] = []
        self.stack: list[dict[str, object]] = []
        self.root_seen = False
        self.root_closed = False
        self.tag_counts: dict[str, int] = {}
        self.ids: set[str] = set()
        self.duplicate_ids: set[str] = set()
        self.html_attrs: dict[str, str] | None = None
        self.title_parts: list[str] = []
        self.title_count = 0
        self._title_depth = 0
        self.viewport_metas: list[dict[str, str]] = []
        self.stylesheets: list[str] = []
        self.scripts: list[str] = []
        self.anchor_hrefs: list[str] = []
        self.regions: dict[str, list[dict[str, object]]] = {
            "site_nav": [],
            "toc": [],
            "breadcrumbs": [],
            "pager": [],
        }
        self._open_regions: list[dict[str, object]] = []
        self.diagrams: list[dict[str, object]] = []

    @staticmethod
    def _attrs_dict(attrs: list[tuple[str, str | None]]) -> dict[str, str]:
        result: dict[str, str] = {}
        for name, value in attrs:
            key = name.lower()
            if key in result:
                raise ValueError(f"duplicate attribute {key}")
            result[key] = value or ""
        return result

    @staticmethod
    def _classes(attrs: dict[str, str]) -> set[str]:
        return set(attrs.get("class", "").split())

    def _record_error(self, message: str) -> None:
        line, column = self.getpos()
        self.errors.append(f"line {line}, column {column}: {message}")

    def handle_decl(self, decl: str) -> None:
        if self.root_seen or self.stack:
            self._record_error("DOCTYPE must precede the html element")
        self.doctypes.append(decl.strip().lower())

    def unknown_decl(self, data: str) -> None:
        self._record_error(f"unknown declaration {data!r}")

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        try:
            attributes = self._attrs_dict(attrs)
        except ValueError as error:
            self._record_error(str(error))
            attributes = {name.lower(): value or "" for name, value in attrs}

        if tag == "html":
            if self.root_seen:
                self._record_error("document contains more than one html element")
            self.root_seen = True
        elif not self.root_seen:
            self._record_error(f"element <{tag}> appears before html")
        elif self.root_closed:
            self._record_error(f"element <{tag}> appears after html")
        if tag in {"head", "body"} and (
            not self.stack or self.stack[-1]["tag"] != "html"
        ):
            self._record_error(f"<{tag}> must be a direct child of <html>")

        self.tag_counts[tag] = self.tag_counts.get(tag, 0) + 1
        if tag == "html" and self.html_attrs is None:
            self.html_attrs = attributes

        identifier = attributes.get("id")
        if identifier:
            if identifier in self.ids:
                self.duplicate_ids.add(identifier)
            self.ids.add(identifier)

        if tag == "meta" and attributes.get("name", "").lower() == "viewport":
            self.viewport_metas.append(attributes)
        if tag == "link" and "stylesheet" in attributes.get("rel", "").lower().split():
            href = attributes.get("href", "")
            if not href:
                self._record_error("stylesheet link has no href")
            else:
                self.stylesheets.append(href)
        if tag == "script" and "src" in attributes:
            src = attributes["src"]
            if not src:
                self._record_error("script tag has an empty src")
            else:
                self.scripts.append(src)
        if tag == "a":
            href = attributes.get("href")
            if href is None:
                self._record_error("anchor has no href")
            else:
                self.anchor_hrefs.append(href)
                for region in self._open_regions:
                    links = region["links"]
                    assert isinstance(links, list)
                    links.append({
                        "href": href,
                        "data_page": "data-page" in attributes,
                    })

        record: dict[str, object] = {"tag": tag, "regions": []}
        classes = self._classes(attributes)
        region_classes = {
            "site_nav": "site-nav",
            "toc": "toc",
            "breadcrumbs": "breadcrumbs",
            "pager": "pager",
        }
        for kind, class_name in region_classes.items():
            if class_name not in classes:
                continue
            region: dict[str, object] = {
                "kind": kind,
                "attrs": attributes,
                "links": [],
                "has_ul": False,
                "has_h2": False,
            }
            self.regions[kind].append(region)
            self._open_regions.append(region)
            region_records = record["regions"]
            assert isinstance(region_records, list)
            region_records.append(region)

        if tag == "ul":
            for region in self._open_regions:
                if region["kind"] == "toc":
                    region["has_ul"] = True
        if tag == "h2":
            for region in self._open_regions:
                if region["kind"] == "toc":
                    region["has_h2"] = True

        if tag == "title":
            self.title_count += 1
            self._title_depth += 1
        if "diagram" in classes:
            diagram = {
                "role": attributes.get("role", ""),
                "aria_label": attributes.get("aria-label", ""),
                "alt_parts": [],
            }
            self.diagrams.append(diagram)
            record["diagram"] = diagram
        if "diagram-alt" in classes:
            record["diagram_alt"] = True

        if tag not in self.VOID_ELEMENTS:
            self.stack.append(record)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag.lower() not in self.VOID_ELEMENTS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in self.VOID_ELEMENTS:
            self._record_error(f"void element has an end tag </{tag}>")
            return
        if not self.stack:
            self._record_error(f"unexpected closing tag </{tag}>")
            return

        if self.stack[-1]["tag"] != tag:
            self._record_error(
                f"closing tag </{tag}> does not match <{self.stack[-1]['tag']}>"
            )
            matching_index = next(
                (index for index in range(len(self.stack) - 1, -1, -1)
                 if self.stack[index]["tag"] == tag),
                None,
            )
            if matching_index is None:
                return
            self.stack = self.stack[:matching_index]
            return

        record = self.stack.pop()
        if tag == "title" and self._title_depth:
            self._title_depth -= 1
        if tag == "html":
            self.root_closed = True
        region_records = record.get("regions", [])
        assert isinstance(region_records, list)
        for region in region_records:
            if region in self._open_regions:
                self._open_regions.remove(region)

    def handle_data(self, data: str) -> None:
        if data.strip() and not self.stack:
            self._record_error("text appears outside the html element")
        if self._title_depth:
            self.title_parts.append(data)
        for record in reversed(self.stack):
            if record.get("diagram_alt"):
                diagram = next(
                    (
                        ancestor.get("diagram")
                        for ancestor in reversed(self.stack)
                        if ancestor.get("diagram") is not None
                    ),
                    None,
                )
                if isinstance(diagram, dict):
                    parts = diagram["alt_parts"]
                    assert isinstance(parts, list)
                    parts.append(data)
                break


def _manual_page_key(path: Path) -> str:
    try:
        return path.relative_to(ROOT / "docs").as_posix()
    except ValueError:
        return path.relative_to(ROOT).as_posix()


def _external_reference(reference: str) -> bool:
    try:
        parsed = urlsplit(reference)
    except ValueError:
        return False
    return bool(parsed.scheme or parsed.netloc)


def _resolve_manual_reference(page: Path, reference: str) -> tuple[Path, str, bool]:
    """Resolve a relative manual URL and return (path, fragment, has_fragment)."""

    try:
        parsed = urlsplit(reference)
    except ValueError as error:
        fail(f"invalid URL in {_manual_page_key(page)}: {reference!r} ({error})")
    if parsed.scheme or parsed.netloc:
        raise ValueError("external reference")
    if parsed.path.startswith("/"):
        fail(f"root-relative URL is not allowed in {_manual_page_key(page)}: {reference}")
    relative_path = unquote(parsed.path)
    resolved = (page.parent / relative_path).resolve() if relative_path else page.resolve()
    try:
        resolved.relative_to(ROOT)
    except ValueError:
        fail(f"relative URL escapes repository in {_manual_page_key(page)}: {reference}")
    return resolved, unquote(parsed.fragment), bool(parsed.fragment)


def _region_page_targets(
    page: Path,
    region: dict[str, object],
    page_keys: set[str],
    *,
    require_data_page: bool = True,
) -> list[str]:
    links = region["links"]
    assert isinstance(links, list)
    targets: list[str] = []
    for link in links:
        assert isinstance(link, dict)
        if require_data_page and not link.get("data_page"):
            fail(f"common navigation link lacks data-page in {_manual_page_key(page)}")
        reference = str(link.get("href", ""))
        if not reference or _external_reference(reference):
            fail(f"common navigation link is not relative in {_manual_page_key(page)}: {reference}")
        resolved, fragment, has_fragment = _resolve_manual_reference(page, reference)
        if has_fragment or fragment:
            fail(f"common navigation link has a fragment in {_manual_page_key(page)}: {reference}")
        if not resolved.is_file():
            fail(f"common navigation target does not exist in {_manual_page_key(page)}: {reference}")
        try:
            target = _manual_page_key(resolved)
        except ValueError:
            fail(f"common navigation points outside docs/ in {_manual_page_key(page)}: {reference}")
        if target not in page_keys:
            fail(f"common navigation points outside manual HTML in {_manual_page_key(page)}: {reference}")
        targets.append(target)
    if len(set(targets)) != len(targets):
        fail(f"common navigation contains duplicate targets in {_manual_page_key(page)}")
    return targets


def check_readme_manual_link() -> None:
    readme = ROOT / "README.md"
    text = readme.read_text(encoding="utf-8")
    link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
    expected = (ROOT / "docs/index.html").resolve()
    for raw_target in link_pattern.findall(text):
        target = raw_target.strip()
        if target.startswith("<") and ">" in target:
            target = target[1:target.index(">")]
        else:
            parts = target.split(None, 1)
            target = parts[0] if parts else ""
        if not target or _external_reference(target):
            continue
        try:
            resolved, _, _ = _resolve_manual_reference(readme, target)
        except ValueError:
            continue
        if resolved == expected:
            print("README manual link passed (docs/index.html).")
            return
    fail("README.md must link to docs/index.html")


def check_legacy_manual_assets_absent() -> None:
    docs = ROOT / "docs"
    markdown = sorted(path for path in docs.glob("*.md") if path.is_file())
    svg_dir = docs / "images"
    svgs = sorted(
        path for path in svg_dir.glob("*")
        if path.is_file() and path.suffix.lower() == ".svg"
    ) if svg_dir.is_dir() else []
    if markdown:
        fail("legacy Markdown manual pages remain: " + ", ".join(_manual_page_key(path) for path in markdown))
    if svgs:
        fail("legacy SVG manual diagrams remain: " + ", ".join(str(path.relative_to(ROOT)) for path in svgs))
    print("Legacy Markdown/SVG manual assets absent.")


def check_html_manual() -> None:
    docs = ROOT / "docs"
    paths = sorted(path for path in docs.rglob("*.html") if path.is_file())
    index = docs / "index.html"
    if not index.is_file():
        fail("manual entry page is missing: docs/index.html")
    if index not in paths:
        paths.append(index)
        paths.sort()

    parsed_pages: dict[Path, ManualHTMLParser] = {}
    page_keys = {_manual_page_key(path) for path in paths}
    for path in paths:
        parser = ManualHTMLParser()
        try:
            parser.feed(path.read_text(encoding="utf-8"))
            parser.close()
        except Exception as error:
            fail(f"cannot parse {_manual_page_key(path)}: {error}")
        parsed_pages[path] = parser

        if parser.errors:
            fail(f"invalid HTML in {_manual_page_key(path)}: " + "; ".join(parser.errors))
        if parser.stack:
            unclosed = ", ".join(str(record["tag"]) for record in parser.stack)
            fail(f"unclosed HTML tags in {_manual_page_key(path)}: {unclosed}")
        if not parser.root_seen or not parser.root_closed:
            fail(f"{_manual_page_key(path)} must contain one closed html root element")
        if parser.doctypes != ["doctype html"]:
            fail(f"{_manual_page_key(path)} must contain exactly <!doctype html>")
        if parser.tag_counts.get("html", 0) != 1:
            fail(f"{_manual_page_key(path)} must contain exactly one <html>")
        if parser.tag_counts.get("head", 0) != 1 or parser.tag_counts.get("body", 0) != 1:
            fail(f"{_manual_page_key(path)} must contain one <head> and one <body>")
        if parser.html_attrs is None or parser.html_attrs.get("lang", "").lower() != "ja":
            fail(f"{_manual_page_key(path)} must declare html lang=\"ja\"")
        if parser.title_count != 1 or not "".join(parser.title_parts).strip():
            fail(f"{_manual_page_key(path)} must contain one non-empty <title>")
        if len(parser.viewport_metas) != 1:
            fail(f"{_manual_page_key(path)} must contain one viewport meta")
        viewport = parser.viewport_metas[0]
        viewport_content = re.sub(r"\s+", "", viewport.get("content", "")).lower()
        if "width=device-width" not in viewport_content:
            fail(f"{_manual_page_key(path)} viewport meta must set width=device-width")
        if parser.tag_counts.get("main", 0) != 1 or parser.tag_counts.get("h1", 0) != 1:
            fail(f"{_manual_page_key(path)} must contain one <main> and one <h1>")
        if parser.duplicate_ids:
            fail(f"duplicate HTML id(s) in {_manual_page_key(path)}: {', '.join(sorted(parser.duplicate_ids))}")

        for reference in parser.stylesheets + parser.scripts:
            if _external_reference(reference):
                continue
            resolved, fragment, has_fragment = _resolve_manual_reference(path, reference)
            if has_fragment or fragment:
                fail(f"CSS/JS reference has a fragment in {_manual_page_key(path)}: {reference}")
            if not resolved.is_file():
                fail(f"missing CSS/JS reference in {_manual_page_key(path)}: {reference}")

        for diagram in parser.diagrams:
            role = str(diagram.get("role", "")).strip().lower()
            aria_label = str(diagram.get("aria_label", "")).strip()
            alt_parts = diagram.get("alt_parts", [])
            alt_text = "".join(alt_parts).strip() if isinstance(alt_parts, list) else ""
            if role != "img" or not aria_label or not alt_text:
                fail(
                    f"CSS diagram in {_manual_page_key(path)} needs role=img, aria-label, and .diagram-alt text"
                )

        for kind, regions in parser.regions.items():
            if len(regions) != 1:
                fail(f"{_manual_page_key(path)} must contain exactly one common {kind} region")

        toc_region = parser.regions["toc"][0]
        toc_attrs = toc_region["attrs"]
        assert isinstance(toc_attrs, dict)
        if toc_attrs.get("aria-label") != "マニュアル目次" or not toc_region["has_ul"] or not toc_region["has_h2"]:
            fail(f"{_manual_page_key(path)} has an invalid common TOC")
        site_nav_region = parser.regions["site_nav"][0]
        site_nav_attrs = site_nav_region["attrs"]
        assert isinstance(site_nav_attrs, dict)
        if site_nav_attrs.get("aria-label") != "ページ移動":
            fail(f"{_manual_page_key(path)} has an invalid site navigation label")
        breadcrumb_region = parser.regions["breadcrumbs"][0]
        breadcrumb_attrs = breadcrumb_region["attrs"]
        assert isinstance(breadcrumb_attrs, dict)
        if breadcrumb_attrs.get("aria-label") != "パンくず":
            fail(f"{_manual_page_key(path)} has an invalid breadcrumb label")
        pager_region = parser.regions["pager"][0]
        pager_attrs = pager_region["attrs"]
        assert isinstance(pager_attrs, dict)
        if pager_attrs.get("aria-label") != "ページ送り":
            fail(f"{_manual_page_key(path)} has an invalid pager label")

    index_parser = parsed_pages[index]
    canonical_toc = _region_page_targets(index, index_parser.regions["toc"][0], page_keys)
    if set(canonical_toc) != page_keys or len(canonical_toc) != len(page_keys):
        fail("index.html TOC must list every manual HTML page exactly once")
    if canonical_toc[0] != "index.html":
        fail("index.html TOC must start with index.html")

    toc_graph: dict[str, list[str]] = {}
    for path, parser in parsed_pages.items():
        key = _manual_page_key(path)
        toc_targets = _region_page_targets(path, parser.regions["toc"][0], page_keys)
        site_targets = _region_page_targets(path, parser.regions["site_nav"][0], page_keys)
        if toc_targets != canonical_toc or site_targets != canonical_toc:
            fail(f"common TOC/site navigation differs from index.html in {key}")
        toc_graph[key] = toc_targets

        breadcrumb_links = parser.regions["breadcrumbs"][0]["links"]
        assert isinstance(breadcrumb_links, list)
        if len(breadcrumb_links) != 1:
            fail(f"{key} breadcrumb must contain one manual link")
        breadcrumb_target = _region_page_targets(
            path, parser.regions["breadcrumbs"][0], page_keys, require_data_page=False
        )
        if breadcrumb_target != ["index.html"]:
            fail(f"{key} breadcrumb must link back to index.html")

        pager_targets = _region_page_targets(
            path, parser.regions["pager"][0], page_keys, require_data_page=False
        )
        position = canonical_toc.index(key)
        expected_pager: list[str] = []
        if position > 0:
            expected_pager.append(canonical_toc[position - 1])
        if position + 1 < len(canonical_toc):
            expected_pager.append(canonical_toc[position + 1])
        elif position > 0:
            expected_pager.append("index.html")
        if pager_targets != expected_pager:
            fail(f"prev/next pager mismatch in {key}: expected {expected_pager}, got {pager_targets}")

    for path, parser in parsed_pages.items():
        for reference in parser.anchor_hrefs:
            if not reference.strip():
                fail(f"anchor has an empty href in {_manual_page_key(path)}")
            if _external_reference(reference):
                continue
            resolved, fragment, has_fragment = _resolve_manual_reference(path, reference)
            if not resolved.is_file():
                fail(f"broken relative link in {_manual_page_key(path)}: {reference}")
            if has_fragment or fragment:
                target_parser = parsed_pages.get(resolved)
                if target_parser is None:
                    continue
                if fragment not in target_parser.ids:
                    fail(f"broken fragment in {_manual_page_key(path)}: {reference}")

    reachable = {"index.html"}
    pending = ["index.html"]
    while pending:
        current = pending.pop()
        for target in toc_graph[current]:
            if target not in reachable:
                reachable.add(target)
                pending.append(target)
    if reachable != page_keys:
        missing = sorted(page_keys - reachable)
        fail("manual pages unreachable from index.html TOC: " + ", ".join(missing))
    diagram_count = sum(len(parser.diagrams) for parser in parsed_pages.values())
    print(f"HTML manual checks passed ({len(paths)} pages, {diagram_count} CSS diagrams).")


def _decode_lua_literal(token: str) -> str:
    token = token.strip()
    if token.startswith('"') and token.endswith('"'):
        # The generated metadata contains no escapes, but handle the common
        # escaped quote/backslash forms so the parser remains unambiguous.
        return bytes(token[1:-1], "utf-8").decode("unicode_escape")
    match = re.fullmatch(r'\[(=*)\[(.*?)\]\1\]', token, re.DOTALL)
    if match:
        return match.group(2)
    fail(f"cannot parse generated Lua string literal: {token[:80]!r}")
    raise AssertionError


def _parse_role_runtime_entries(content: str, role: str) -> list[tuple[str, str]]:
    files_block = re.search(r'(?ms)^local\s+files\s*=\s*\{(.*?)^local\s+FILE_COUNT\s*=', content)
    if not files_block:
        fail(f"offline {role} installer has no embedded files table")
    literal = r'(?:\[\[.*?\]\]|"(?:\\.|[^"\\])*")'
    entry_pattern = re.compile(
        rf'\{{\s*source\s*=\s*(?P<source>{literal})\s*,\s*target\s*=\s*(?P<target>{literal})',
        re.DOTALL,
    )
    entries = [
        (_decode_lua_literal(match.group("source")), _decode_lua_literal(match.group("target")))
        for match in entry_pattern.finditer(files_block.group(1))
    ]
    count_match = re.search(r'^local\s+FILE_COUNT\s*=\s*(\d+)', content, re.MULTILINE)
    if not count_match:
        fail(f"offline {role} installer has no FILE_COUNT")
    if len(entries) != int(count_match.group(1)):
        fail(f"offline {role} installer embedded file count differs from FILE_COUNT")
    return entries


def _check_role_bundle(role: str) -> tuple[str, int]:
    parts_dir = ROOT / f"dist/ccminer-offline-{role}.parts"
    loader_path = ROOT / f"dist/ccminer-offline-{role}.lua"
    if not parts_dir.is_dir() or not loader_path.is_file():
        fail(f"offline {role} role bundle is missing")
    actual_names = sorted(
        (path.name for path in parts_dir.iterdir()),
        key=lambda name: (0, int(Path(name).stem)) if Path(name).stem.isdigit() else (1, name),
    )
    if not actual_names:
        fail(f"offline {role} role bundle has no parts")
    name_width = max(2, len(str(len(actual_names))))
    expected_names = [f"{index:0{name_width}d}.part" for index in range(1, len(actual_names) + 1)]
    if actual_names != expected_names:
        fail(f"offline {role} parts are not exactly ordered/contiguous: {actual_names}")
    parts = [parts_dir / name for name in expected_names]
    loader = loader_path.read_text(encoding="utf-8")
    part_block_match = re.search(r'(?ms)^local\s+partManifest\s*=\s*\{(.*?)^\}', loader)
    if not part_block_match:
        fail(f"offline {role} loader has no partManifest")
    literal = r'(?:\[\[.*?\]\]|"(?:\\.|[^"\\])*")'
    metadata_pattern = re.compile(
        rf'\{{\s*name\s*=\s*(?P<name>{literal})\s*,\s*bytes\s*=\s*(?P<bytes>\d+)\s*,\s*'
        rf'digest\s*=\s*(?P<digest>{literal})\s*\}}',
        re.DOTALL,
    )
    metadata = list(metadata_pattern.finditer(part_block_match.group(1)))
    if len(metadata) != len(parts):
        fail(f"offline {role} loader partManifest count differs from parts directory")
    expected_assembled = hashlib.sha256()
    for path, match, expected_name in zip(parts, metadata, expected_names):
        name = _decode_lua_literal(match.group("name"))
        if name != expected_name:
            fail(f"offline {role} loader part order metadata is invalid: {name}")
        if not path.is_file():
            fail(f"offline {role} part is not a regular file: {path.relative_to(ROOT)}")
        data = path.read_bytes()
        if len(data) <= 0 or len(data) > OFFLINE_PART_LIMIT:
            fail(f"offline {role} part exceeds {OFFLINE_PART_LIMIT} bytes: {path.relative_to(ROOT)}")
        expected_bytes = int(match.group("bytes"))
        expected_digest = _decode_lua_literal(match.group("digest")).lower()
        actual_digest = hashlib.sha256(data).hexdigest()
        if len(data) != expected_bytes or actual_digest != expected_digest:
            fail(f"offline {role} part metadata digest/size mismatch: {expected_name}")
        expected_assembled.update(data)
    if "for extra in pairs(found) do error(\"Unexpected offline installer part:" not in loader:
        fail(f"offline {role} loader does not reject extra parts")
    if "found[item.name] = nil" not in loader:
        fail(f"offline {role} loader does not consume exact part names")
    assembled = b"".join(path.read_bytes() for path in parts)
    assembled_digest_match = re.search(r'^local\s+EXPECTED_ASSEMBLED_DIGEST\s*=\s*"([0-9a-fA-F]{64})"', loader, re.MULTILINE)
    if not assembled_digest_match or assembled_digest_match.group(1).lower() != hashlib.sha256(assembled).hexdigest():
        fail(f"offline {role} assembled digest metadata mismatch")
    if expected_assembled.hexdigest() != hashlib.sha256(assembled).hexdigest():
        fail(f"offline {role} assembled part order changed")
    assembled_text = assembled.decode("utf-8")
    expected_entries = ROLE_REQUIRED_TARGETS[role]
    expected_pairs = [(source, target) for source, target, roles in RUNTIME_ENTRIES if role in roles]
    actual_entries = _parse_role_runtime_entries(assembled_text, role)
    if actual_entries != expected_pairs:
        fail(f"offline {role} embedded runtime entries differ (extra, missing, order, or known-target mismatch)")
    if f'local ROLE = "{role}"' not in assembled_text:
        fail(f"offline {role} installer role marker is missing")
    size = len(assembled)
    if size <= 1_000 or size > 900_000:
        fail(f"offline {role} assembled installer has unexpected size: {size}")
    # Keep this check explicit so a malformed embedded table cannot hide an
    # unknown target behind a valid-looking part digest.
    for _, target in actual_entries:
        if target not in KNOWN_TARGETS or target not in expected_entries:
            fail(f"offline {role} embedded unknown target: {target}")
    return assembled_text, size


def _check_dispatcher() -> None:
    path = ROOT / "dist/ccminer-offline.lua"
    if not path.is_file():
        fail("offline compatibility dispatcher is missing")
    text = path.read_text(encoding="utf-8")
    if "ccminer-offline.parts" in text:
        fail("offline compatibility dispatcher still references legacy parts")
    expected_pattern = 'fs.combine(fs.getDir(running), "ccminer-offline-" .. role .. ".lua")'
    if expected_pattern not in text:
        fail("offline compatibility dispatcher does not reference role loaders exactly")
    for role in ROLE_ORDER:
        if f'role ~= "{role}"' not in text and f'role == "{role}"' not in text:
            fail(f"offline compatibility dispatcher omits role {role}")
    if "Missing role loader:" not in text or "loadfile(loader)" not in text:
        fail("offline compatibility dispatcher has no strict role-loader handoff")
    print("Offline compatibility dispatcher references the exact role loaders.")


def check_bundle() -> None:
    summaries = []
    for role in ROLE_ORDER:
        _, size = _check_role_bundle(role)
        summaries.append(f"{role}={size} bytes")
    _check_dispatcher()
    legacy_parts = ROOT / "dist/ccminer-offline.parts"
    # The dispatcher filename is intentionally retained; only its legacy
    # split-parts directory is forbidden.
    if legacy_parts.exists():
        fail("legacy dist/ccminer-offline.parts remains")
    print("Split role bundles passed (" + ", ".join(summaries) + ").")


def main() -> None:
    run([sys.executable, "tools/build_offline_bundle.py", "--check"])
    check_runtime_lists()
    check_html_manual()
    check_legacy_manual_assets_absent()
    check_readme_manual_link()
    check_github_scope()
    check_feature_markers()
    check_bundle()
    lua = find_lua()
    check_lua_syntax(lua)
    lua_tests = [
        "tests/test_setup_v4.lua",
        "tests/test_remote_console.lua",
        "tests/test_worker_remote_console.lua",
        "tests/test_worker_v4_contract.lua",
        "tests/test_journal_v4.lua",
        "tests/test_controller_v4_contract.lua",
        "tests/test_distribution_v4.lua",
        "tests/test_startup.lua",
        "tests/test_low_space_update.lua",
        "tests/test_quarry.lua",
        "tests/test_geo.lua",
        "tests/test_common.lua",
        "tests/test_protocol.lua",
        "tests/test_controller_persistence.lua",
        "tests/test_v3_contract.lua",
    ]
    for test in lua_tests:
        run([lua, test, str(ROOT)])
    print("All CC Miner V4 checks passed.")


if __name__ == "__main__":
    main()
