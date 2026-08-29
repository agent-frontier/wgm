#!/usr/bin/env python3
"""Deterministic, fail-closed harness qualification ladder.

The default command executes only explicit local fixture commands. A manifest is data, not a shell
script: commands are tokenized with ``shlex`` and run with ``shell=False``. Live evidence requires
both a manifest opt-in and the operator's explicit ``--allow-live`` flag. Raw command output is
never persisted; only a short redacted diagnostic is retained.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

PHASES = ("inventory", "contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark")
SAFE_ENV_KEYS = ("AI_AGENT", "PI_CODING_AGENT", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL")
MAX_MANIFEST_BYTES = 1_000_000
MAX_COMMAND_CHARS = 2_000
MAX_DETAIL_CHARS = 500
SECRET_RE = re.compile(
    r"(?i)(?:api[_ -]?key|secret|password|passwd|token|authorization|bearer)"
    r"\s*(?:[:=]|is)\s*[^\s,;]+"
    r"|\b(?:ghp_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"github_pat_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"sk-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"xoxb-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"AKIA[A-Z0-9]{12,})\b"
)


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def die(message: str, code: int = 2) -> "NoReturn":
    print(f"stage10 qualification: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def root_path(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        die(f"root is not a directory: {root}")
    return root


def under(root: Path, candidate: Path, label: str) -> Path:
    try:
        candidate.relative_to((root / ".wgm").resolve())
    except ValueError:
        die(f"{label} must remain under {root / '.wgm'}")
    return candidate


def safe_git(root: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", *args], cwd=root, capture_output=True, text=True, check=True, timeout=10
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return "unknown"
    return result.stdout.strip() or "unknown"


def safe_host_signals() -> dict[str, str]:
    values: dict[str, str] = {}
    for key in SAFE_ENV_KEYS:
        value = os.environ.get(key, "")
        if not value:
            continue
        if any(character in value for character in "\r\n") or SECRET_RE.search(value):
            values[key] = "<redacted>"
        else:
            values[key] = value
    return values


def environment_info(root: Path, route_environment: Any) -> tuple[Any, str]:
    if isinstance(route_environment, (dict, list)):
        rendered = json.dumps(route_environment, sort_keys=True, ensure_ascii=False)
    else:
        rendered = str(route_environment)
    if SECRET_RE.search(rendered) or any(character in rendered for character in "\r\n"):
        die("route environment contains credential-like or multiline material")
    facts = {
        "branch": safe_git(root, "branch", "--show-current"),
        "head": safe_git(root, "rev-parse", "HEAD"),
        "python": platform.python_version(),
        "platform": platform.platform(aliased=True),
        "route_environment": route_environment,
        "safe_host_signals": safe_host_signals(),
    }
    return route_environment, hashlib.sha256(
        json.dumps(facts, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).hexdigest()


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > MAX_MANIFEST_BYTES:
            die(f"manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit")
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        die(f"cannot read manifest: {exc}")
    except json.JSONDecodeError as exc:
        die(f"manifest is not valid JSON: {exc.msg}")
    if not isinstance(value, dict) or not isinstance(value.get("routes"), list):
        die("manifest needs a routes array")
    if "allow_live" in value and not isinstance(value["allow_live"], bool):
        die("manifest allow_live must be boolean")
    return value


def command_argv(command: Any, route_id: str, phase: str) -> list[str]:
    if not isinstance(command, str) or not command.strip() or len(command) > MAX_COMMAND_CHARS:
        die(f"{route_id}/{phase}: command must be a non-empty string under {MAX_COMMAND_CHARS} characters")
    if SECRET_RE.search(command) or any(character in command for character in "\r\n"):
        die(f"{route_id}/{phase}: command contains credential-like or multiline material")
    try:
        argv = shlex.split(command)
    except ValueError as exc:
        die(f"{route_id}/{phase}: command cannot be tokenized safely: {exc}")
    if not argv:
        die(f"{route_id}/{phase}: command tokenizes to no executable")
    return argv


def safe_detail(stdout: str, stderr: str) -> str:
    detail = (stdout.strip() or stderr.strip()).replace("\r", "\\r").replace("\n", "\\n")
    if SECRET_RE.search(detail):
        detail = SECRET_RE.sub("<redacted>", detail)
    return detail[-MAX_DETAIL_CHARS:] or "no output"


def run_phase(command: Any, root: Path, route_id: str, phase: str, timeout_seconds: int) -> tuple[str, str, int]:
    argv = command_argv(command, route_id, phase)
    started = time.monotonic()
    try:
        result = subprocess.run(
            argv,
            cwd=root,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
            shell=False,
        )
    except subprocess.TimeoutExpired:
        return "timeout", f"command exceeded {timeout_seconds}s", round((time.monotonic() - started) * 1000)
    except OSError as exc:
        return "failed", f"process error: {exc}", round((time.monotonic() - started) * 1000)
    status = "passed" if result.returncode == 0 else "failed"
    return status, f"exit={result.returncode}; {safe_detail(result.stdout, result.stderr)}", round(
        (time.monotonic() - started) * 1000
    )


def validate_route(root: Path, route: Any, index: int) -> tuple[str, str, dict[str, Any], dict[str, Any]]:
    if not isinstance(route, dict):
        die(f"routes[{index}] must be an object")
    route_id = route.get("id")
    if not isinstance(route_id, str) or not route_id.strip():
        die(f"routes[{index}] needs a non-empty id")
    if route_id != route_id.strip() or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789._-" for character in route_id):
        die(f"{route_id!r}: id must be a lowercase slug")
    evidence = route.get("evidence", "fixture")
    if evidence not in {"fixture", "live"}:
        die(f"{route_id}: evidence must be fixture or live")
    commands = route.get("commands", {})
    if not isinstance(commands, dict):
        die(f"{route_id}: commands must be an object")
    unknown_phases = sorted(set(commands) - set(PHASES))
    if unknown_phases:
        die(f"{route_id}: unknown phases: {', '.join(unknown_phases)}")
    environment, fingerprint = environment_info(root, route.get("environment", "unspecified"))
    return route_id, evidence, commands, {"value": environment, "fingerprint": fingerprint}


def qualify(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    manifest_path = Path(args.manifest).expanduser().resolve()
    manifest = load_manifest(manifest_path)
    if args.timeout_seconds < 1 or args.timeout_seconds > 600:
        die("--timeout-seconds must be an integer 1..600")
    if args.allow_live and not manifest.get("allow_live", False):
        die("--allow-live requires allow_live=true in the manifest")
    if not args.allow_live and manifest.get("allow_live", False):
        # The manifest may describe a live-capable experiment, but the operator must still opt in
        # on this invocation. This prevents a copied manifest from becoming authority by itself.
        pass
    output = Path(args.output).expanduser() if args.output else root / ".wgm" / "stage10" / "harnesses" / "qualification.jsonl"
    if not output.is_absolute():
        output = root / output
    output = under(root, output.resolve(), "output")
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    existing_ids: set[str] = set()
    records: list[dict[str, Any]] = []
    seen_routes: set[str] = set()

    for index, raw_route in enumerate(manifest["routes"]):
        route_id, evidence, commands, environment = validate_route(root, raw_route, index)
        if route_id in seen_routes:
            die(f"duplicate route id: {route_id}")
        seen_routes.add(route_id)
        if evidence == "live" and not args.allow_live:
            die(f"{route_id}: live evidence requires --allow-live and allow_live=true")
        route_records: list[dict[str, Any]] = []
        for phase in PHASES:
            command = commands.get(phase)
            started = time.monotonic()
            if phase == "inventory":
                status, detail = "passed", "route declared in manifest"
                duration_ms = 0
            elif command is None:
                status, detail = "unknown", "phase command not configured"
                duration_ms = 0
            else:
                status, detail, duration_ms = run_phase(command, root, route_id, phase, args.timeout_seconds)
            record = {
                "schema": "stage10.qualification.v1",
                "id": hashlib.sha256(f"{route_id}:{phase}:{evidence}".encode("utf-8")).hexdigest()[:16],
                "route": route_id,
                "phase": phase,
                "evidence": evidence,
                "environment": environment["value"],
                "environment_fingerprint": environment["fingerprint"],
                "command": command or "(declared route; no command)",
                "duration_ms": duration_ms or round((time.monotonic() - started) * 1000),
                "status": status,
                "detail": detail,
                "recorded_at": stamp(),
                "revalidate": {
                    "manifest": str(manifest_path),
                    "manifest_sha256": manifest_hash,
                    "condition": "rerun the same manifest with the same environment and timeout",
                },
            }
            route_records.append(record)
            if status in {"failed", "timeout"}:
                break
        if any(record["status"] in {"failed", "timeout"} for record in route_records):
            route_status = "blocked"
        elif any(record["status"] == "unknown" for record in route_records):
            route_status = "inventory-only"
        elif evidence == "fixture":
            route_status = "fixture-qualified"
        else:
            route_status = "qualified"
        for record in route_records:
            record["route_status"] = route_status
        records.extend(route_records)

    for record in records:
        if record["id"] in existing_ids:
            die(f"duplicate qualification record id: {record['id']}")
        existing_ids.add(record["id"])
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"stage10 qualification: wrote {len(records)} records to {output}")
    if any(record["status"] in {"failed", "timeout"} for record in records):
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["qualify"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--manifest", required=True, help="JSON manifest containing explicit route commands")
    parser.add_argument("--output", help="qualification JSONL path; must be under .wgm")
    parser.add_argument("--timeout-seconds", type=int, default=30, help="per-phase command limit")
    parser.add_argument("--allow-live", action="store_true", help="explicitly authorize live-evidence commands")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    qualify(args)


if __name__ == "__main__":
    main()
