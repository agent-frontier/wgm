#!/usr/bin/env python3
"""Deterministic, fail-closed harness qualification ladder.

The default command executes only explicit local fixture commands. A manifest is data, not a shell
script: commands are tokenized with ``shlex`` and run with ``shell=False``. Live evidence requires
a manifest opt-in, a hash/scope/expiry/budget-bound authorization file, and the operator's explicit
``--allow-live`` flag. Live phase commands reuse :mod:`stage10_runner`; raw command output and
credentials are never persisted.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import stage10_runner

PHASES = ("inventory", "contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark")
EXECUTABLE_PHASES = PHASES[1:]
SAFE_ENV_KEYS = ("AI_AGENT", "PI_CODING_AGENT", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL")
MAX_MANIFEST_BYTES = 1_000_000
MAX_AUTHORIZATION_BYTES = 64 * 1024
MAX_LIVE_BUDGET_SECONDS = 3_600.0
MAX_COMMAND_CHARS = 2_000
MAX_DETAIL_CHARS = 500
AUTHORIZATION_SCHEMA = "stage10.live-authorization.v1"
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


def load_manifest(path: Path) -> tuple[dict[str, Any], str]:
    try:
        if path.stat().st_size > MAX_MANIFEST_BYTES:
            die(f"manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit")
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except OSError as exc:
        die(f"cannot read manifest: {exc}")
    except (UnicodeError, json.JSONDecodeError) as exc:
        die(f"manifest is not valid UTF-8 JSON: {exc}")
    if not isinstance(value, dict) or not isinstance(value.get("routes"), list):
        die("manifest needs a routes array")
    try:
        stage10_runner.reject_manifest_material(value)
    except stage10_runner.RunnerError as exc:
        die(str(exc))
    if "allow_live" in value and not isinstance(value["allow_live"], bool):
        die("manifest allow_live must be boolean")
    return value, hashlib.sha256(raw).hexdigest()


def finite_budget(raw: Any, label: str) -> float:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        die(f"{label} must be a finite number")
    value = float(raw)
    if not math.isfinite(value) or value < stage10_runner.MIN_TIMEOUT_SECONDS or value > MAX_LIVE_BUDGET_SECONDS:
        die(
            f"{label} must be between {stage10_runner.MIN_TIMEOUT_SECONDS:g} "
            f"and {MAX_LIVE_BUDGET_SECONDS:g}"
        )
    return value


def parse_expiry(raw: Any) -> dt.datetime:
    if not isinstance(raw, str) or not raw.strip():
        die("authorization expires_at must be a UTC timestamp")
    try:
        value = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        die("authorization expires_at must be an ISO-8601 timestamp")
    if value.tzinfo is None or value.utcoffset() != dt.timedelta(0):
        die("authorization expires_at must include the UTC timezone")
    return value.astimezone(dt.timezone.utc)


def load_authorization(path: Path) -> tuple[dict[str, Any], str]:
    try:
        if path.stat().st_size > MAX_AUTHORIZATION_BYTES:
            die(f"authorization exceeds the {MAX_AUTHORIZATION_BYTES}-byte limit")
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except OSError as exc:
        die(f"cannot read authorization: {exc}")
    except (UnicodeError, json.JSONDecodeError) as exc:
        die(f"authorization is not valid UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        die("authorization must be a JSON object")
    try:
        stage10_runner.reject_manifest_material(value, "authorization")
    except stage10_runner.RunnerError as exc:
        die(str(exc))
    return value, hashlib.sha256(raw).hexdigest()


def expected_live_scope(
    routes: list[tuple[str, str, dict[str, Any], Any]],
) -> dict[str, dict[str, list[str]]]:
    return {
        "routes": {
            route_id: [phase for phase in EXECUTABLE_PHASES if phase in commands]
            for route_id, evidence, commands, _environment in routes
            if evidence == "live"
        }
    }


def validate_live_authorization(
    args: argparse.Namespace,
    manifest: dict[str, Any],
    manifest_hash: str,
    routes: list[tuple[str, str, dict[str, Any], Any]],
) -> dict[str, Any] | None:
    live_routes = [route for route in routes if route[1] == "live"]
    if not live_routes:
        if args.authorization_file:
            die("--authorization-file requires at least one live route")
        return None
    if manifest.get("allow_live") is not True:
        die("live routes require allow_live=true in the manifest")
    if not args.allow_live:
        die("live evidence requires --allow-live")
    if not args.authorization_file:
        die("live evidence requires --authorization-file")

    authorization_path = Path(args.authorization_file).expanduser().resolve()
    authorization, authorization_hash = load_authorization(authorization_path)
    required = {"schema", "allow_live", "manifest_sha256", "scope", "expires_at", "budget_seconds"}
    missing = sorted(required - set(authorization))
    if missing:
        die("authorization missing: " + ", ".join(missing))
    if authorization["schema"] != AUTHORIZATION_SCHEMA:
        die(f"authorization schema must be {AUTHORIZATION_SCHEMA}")
    if authorization["allow_live"] is not True:
        die("authorization must set allow_live=true")
    if authorization["manifest_sha256"] != manifest_hash:
        die("authorization manifest_sha256 does not match the live manifest")
    expected_scope = expected_live_scope(routes)
    if authorization["scope"] != expected_scope:
        die("authorization scope does not exactly match the live route phases")
    expires_at = parse_expiry(authorization["expires_at"])
    if expires_at <= dt.datetime.now(dt.timezone.utc):
        die("authorization has expired")
    manifest_budget = finite_budget(manifest.get("live_budget_seconds"), "manifest live_budget_seconds")
    authorization_budget = finite_budget(authorization["budget_seconds"], "authorization budget_seconds")
    if manifest_budget != authorization_budget:
        die("authorization budget_seconds does not match manifest live_budget_seconds")
    return {
        "path": authorization_path,
        "sha256": authorization_hash,
        "scope": expected_scope,
        "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
        "expires_at_datetime": expires_at,
        "budget_seconds": authorization_budget,
    }


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
    try:
        return stage10_runner.validate_argv(argv)
    except stage10_runner.RunnerError as exc:
        die(f"{route_id}/{phase}: {exc}")


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


def run_live_phase(
    command: Any,
    root: Path,
    route_id: str,
    phase: str,
    timeout_seconds: float,
    manifest_hash: str,
    authorization: dict[str, Any],
    qualification_run_id: str,
) -> tuple[str, str, int, str, str]:
    argv = command_argv(command, route_id, phase)
    run_directory = (
        root / ".wgm" / "stage10" / "harnesses" / "runs" / qualification_run_id
    )
    runner_manifest = run_directory / f"{route_id}-{phase}.manifest.json"
    runner_output = run_directory / f"{route_id}-{phase}.json"
    runner_authority = {
        "allow_live": True,
        "scope": f"qualification:{route_id}:{phase}",
        "authorization_sha256": authorization["sha256"],
        "manifest_sha256": manifest_hash,
        "expires_at": authorization["expires_at"],
        "budget_seconds": authorization["budget_seconds"],
    }
    stage10_runner.atomic_write(
        runner_manifest,
        {
            "argv": argv,
            "cwd": ".",
            "timeout_seconds": timeout_seconds,
            "evidence": "live",
            "diagnostic_limit": MAX_DETAIL_CHARS,
            "authority": runner_authority,
        },
    )
    runner_args = argparse.Namespace(
        root=str(root),
        manifest=str(runner_manifest),
        output=str(runner_output),
        allow_live=True,
    )
    try:
        stage10_runner.run_manifest(runner_args)
    except SystemExit as exc:
        die(f"{route_id}/{phase}: bounded runner rejected generated manifest (exit {exc.code})")
    try:
        result = json.loads(runner_output.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"{route_id}/{phase}: cannot read bounded runner result: {exc}")
    if result.get("evidence") != "live" or result.get("authority_sha256") != hashlib.sha256(
        json.dumps(runner_authority, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest():
        die(f"{route_id}/{phase}: bounded runner result lost live authority provenance")
    return (
        str(result["status"]),
        str(result["diagnostic"]),
        int(result["duration_ms"]),
        runner_manifest.relative_to(root).as_posix(),
        runner_output.relative_to(root).as_posix(),
    )


def validate_route(route: Any, index: int) -> tuple[str, str, dict[str, Any], Any]:
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
    route_environment = route.get("environment", "unspecified")
    if isinstance(route_environment, (dict, list)):
        rendered_environment = json.dumps(route_environment, sort_keys=True, ensure_ascii=False)
    else:
        rendered_environment = str(route_environment)
    if SECRET_RE.search(rendered_environment) or any(
        character in rendered_environment for character in "\r\n"
    ):
        die("route environment contains credential-like or multiline material")
    return route_id, evidence, commands, route_environment


def qualify(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    manifest_path = Path(args.manifest).expanduser().resolve()
    manifest, manifest_hash = load_manifest(manifest_path)
    if args.timeout_seconds < 1 or args.timeout_seconds > 600:
        die("--timeout-seconds must be an integer 1..600")
    if args.allow_live and not manifest.get("allow_live", False):
        die("--allow-live requires allow_live=true in the manifest")
    output = Path(args.output).expanduser() if args.output else root / ".wgm" / "stage10" / "harnesses" / "qualification.jsonl"
    if not output.is_absolute():
        output = root / output
    output = under(root, output.resolve(), "output")
    existing_ids: set[str] = set()
    records: list[dict[str, Any]] = []
    seen_routes: set[str] = set()
    routes: list[tuple[str, str, dict[str, Any], Any]] = []

    for index, raw_route in enumerate(manifest["routes"]):
        route_id, evidence, commands, route_environment = validate_route(raw_route, index)
        if route_id in seen_routes:
            die(f"duplicate route id: {route_id}")
        seen_routes.add(route_id)
        # Validate every command before any route runs so a malformed later live route cannot leave
        # partial side effects from an earlier one.
        for phase, command in commands.items():
            command_argv(command, route_id, phase)
        routes.append((route_id, evidence, commands, route_environment))

    authorization = validate_live_authorization(args, manifest, manifest_hash, routes)
    reserved_runs = (root / ".wgm" / "stage10" / "harnesses" / "runs").resolve()
    try:
        output.relative_to(reserved_runs)
    except ValueError:
        pass
    else:
        die(f"output must not overwrite reserved bounded-runner evidence under {reserved_runs}")
    protected_inputs = {manifest_path}
    if authorization:
        protected_inputs.add(authorization["path"])
    if output in protected_inputs:
        die("output must not overwrite the manifest or authorization input")

    qualification_run_id = hashlib.sha256(
        f"{manifest_hash}|{authorization['sha256'] if authorization else 'fixture'}|"
        f"{stamp()}|{os.getpid()}".encode("utf-8")
    ).hexdigest()[:16]
    total_live_spent_ms = 0

    for route_id, evidence, commands, route_environment in routes:
        environment_value, environment_fingerprint = environment_info(root, route_environment)
        environment = {"value": environment_value, "fingerprint": environment_fingerprint}
        route_records: list[dict[str, Any]] = []
        for phase in PHASES:
            command = commands.get(phase)
            started = time.monotonic()
            runner_manifest: str | None = None
            runner_result: str | None = None
            phase_timeout: float | int = args.timeout_seconds
            if phase == "inventory":
                status, detail = "passed", "route declared in manifest"
                duration_ms = 0
            elif command is None:
                status, detail = "unknown", "phase command not configured"
                duration_ms = 0
            elif evidence == "live":
                assert authorization is not None
                remaining_seconds = authorization["budget_seconds"] - (total_live_spent_ms / 1000)
                if dt.datetime.now(dt.timezone.utc) >= authorization["expires_at_datetime"]:
                    status = "refused"
                    detail = "authorization expired before phase"
                    duration_ms = 0
                    phase_timeout = 0
                elif remaining_seconds < stage10_runner.MIN_TIMEOUT_SECONDS:
                    status = "timeout"
                    detail = "authorization execution budget exhausted before phase"
                    duration_ms = 0
                    phase_timeout = 0
                else:
                    phase_timeout = min(float(args.timeout_seconds), remaining_seconds)
                    status, detail, duration_ms, runner_manifest, runner_result = run_live_phase(
                        command,
                        root,
                        route_id,
                        phase,
                        phase_timeout,
                        manifest_hash,
                        authorization,
                        qualification_run_id,
                    )
                    total_live_spent_ms += duration_ms
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
                "qualification_run_id": qualification_run_id,
                "revalidate": {
                    "manifest": str(manifest_path),
                    "manifest_sha256": manifest_hash,
                    "condition": "rerun the same manifest with the same environment and timeout",
                },
                "authorization_sha256": authorization["sha256"] if evidence == "live" and authorization else None,
                "authorization_scope": authorization["scope"] if evidence == "live" and authorization else None,
                "authorization_expires_at": authorization["expires_at"] if evidence == "live" and authorization else None,
                "budget": {
                    "authorized_seconds": authorization["budget_seconds"] if evidence == "live" and authorization else None,
                    "phase_timeout_seconds": phase_timeout,
                    "consumed_ms": total_live_spent_ms if evidence == "live" else duration_ms,
                    "remaining_ms": (
                        max(0, round(authorization["budget_seconds"] * 1000) - total_live_spent_ms)
                        if evidence == "live" and authorization
                        else None
                    ),
                },
                "runner": {
                    "manifest": runner_manifest,
                    "result": runner_result,
                    "contract": stage10_runner.SCHEMA if runner_result else None,
                },
                "authority": (
                    "dated live observation only; no automatic route, policy, PR, merge, deploy, or publish transition"
                    if evidence == "live"
                    else "fixture evidence only; never live or corroborated"
                ),
            }
            if evidence == "live" and authorization:
                record["revalidate"].update(
                    {
                        "authorization_file": str(authorization["path"]),
                        "authorization_sha256": authorization["sha256"],
                        "authorization_expires_at": authorization["expires_at"],
                    }
                )
            route_records.append(record)
            if status in {"failed", "timeout", "refused"}:
                break
        if any(record["status"] in {"failed", "timeout", "refused"} for record in route_records):
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
    if any(record["status"] in {"failed", "timeout", "refused"} for record in records):
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["qualify"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--manifest", required=True, help="JSON manifest containing explicit route commands")
    parser.add_argument("--output", help="qualification JSONL path; must be under .wgm")
    parser.add_argument("--timeout-seconds", type=int, default=30, help="per-phase command limit")
    parser.add_argument(
        "--authorization-file",
        help="hash/scope/expiry/budget-bound live authorization JSON; does not contain credentials",
    )
    parser.add_argument("--allow-live", action="store_true", help="confirm this operator-initiated live run")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    qualify(args)


if __name__ == "__main__":
    main()
