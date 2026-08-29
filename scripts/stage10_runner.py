#!/usr/bin/env python3
"""Run one bounded Stage 10 process from a provider-agnostic JSON manifest.

The manifest is data, never an implicit shell script.  The runner accepts an explicit argv vector,
confined cwd/output paths, a finite timeout, and an evidence class.  It starts the child in its own
process group, drains output without allowing it to grow without bound, redacts diagnostics before
persistence, and writes one revalidatable result under the target project's ``.wgm`` directory.
Live evidence additionally needs an explicit authority envelope and ``--allow-live``; this generic
boundary does not create or discover that authority for a caller.
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
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

SCHEMA = "stage10.runner.v1"
MAX_MANIFEST_BYTES = 1_000_000
MAX_ARGV_ITEMS = 128
MAX_ARG_CHARS = 16_000
MAX_TOTAL_ARG_CHARS = 64_000
MIN_TIMEOUT_SECONDS = 0.01
MAX_TIMEOUT_SECONDS = 600.0
DEFAULT_DIAGNOSTIC_LIMIT = 4_000
MAX_DIAGNOSTIC_LIMIT = 64_000
MAX_ENV_FILE_BYTES = 64 * 1024
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SECRET_RE = re.compile(
    r"(?i)(?:api[_ -]?key|secret|password|passwd|token|authorization|bearer)"
    r"\s*(?:[:=]|is)\s*[^\s,;]+"
    r"|\b(?:ghp_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"github_pat_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"sk-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"xoxb-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"AKIA[A-Z0-9]{12,})\b"
)
SENSITIVE_PATH_RE = re.compile(
    r"(?i)(?:^|/)(?:\.env(?:\..*)?|credentials?(?:\..*)?|"
    r"secrets?(?:\..*)?|auth(?:entication)?\.json|.*\.(?:pem|key|p12|pfx))$"
)
INHERITED_ENV_KEYS = (
    "PATH",
    "HOME",
    "TMPDIR",
    "TMP",
    "TEMP",
    "LANG",
    "LC_ALL",
    "SYSTEMROOT",
    "PATHEXT",
)


class RunnerError(ValueError):
    """A manifest or boundary error that must happen before process creation."""


def die(message: str, code: int = 2) -> "NoReturn":
    print(f"stage10 runner: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def reject_unsafe_string(value: str, label: str) -> None:
    if "\x00" in value:
        raise RunnerError(f"{label} contains a NUL byte")
    if any(character in value for character in "\r\n"):
        raise RunnerError(f"{label} contains multiline material")
    if SECRET_RE.search(value):
        raise RunnerError(f"{label} contains credential-like material")


def reject_manifest_material(value: Any, label: str = "manifest") -> None:
    """Reject values that could become unsafe persisted manifest metadata.

    Shell metacharacters are intentionally not rejected: they are ordinary argv data when no shell
    is inserted.  Newlines, NULs, and credential-shaped assignments are different because they can
    corrupt a line-oriented record or persist a secret.
    """

    if isinstance(value, str):
        reject_unsafe_string(value, label)
    elif isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise RunnerError(f"{label} has a non-string key")
            reject_manifest_material(child, f"{label}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_manifest_material(child, f"{label}[{index}]")
    elif value is not None and not isinstance(value, (bool, int, float)):
        raise RunnerError(f"{label} is not JSON-safe")


def resolve_root(raw: str) -> Path:
    try:
        root = Path(raw).expanduser().resolve()
    except (OSError, RuntimeError, ValueError) as exc:
        die(f"root cannot be resolved: {exc}")
    if not root.is_dir():
        die(f"root is not a directory: {root}")
    return root


def resolve_path(root: Path, raw: Any, label: str, *, must_exist: bool = False) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        raise RunnerError(f"{label} must be a non-empty path")
    try:
        candidate = Path(raw).expanduser()
        if not candidate.is_absolute():
            candidate = root / candidate
        resolved = candidate.resolve()
    except (OSError, RuntimeError, ValueError) as exc:
        raise RunnerError(f"{label} cannot be resolved: {exc}") from exc
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise RunnerError(f"{label} must remain under project root {root}: {resolved}") from exc
    if must_exist and not resolved.exists():
        raise RunnerError(f"{label} does not exist: {resolved}")
    return resolved


def resolve_output(root: Path, raw: Any) -> Path:
    output = resolve_path(root, raw, "output")
    state = (root / ".wgm").resolve()
    try:
        output.relative_to(state)
    except ValueError as exc:
        raise RunnerError(f"output must remain under {state}: {output}") from exc
    if output == root or output == state or output.is_dir():
        raise RunnerError(f"output must name a file: {output}")
    return output


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > MAX_MANIFEST_BYTES:
            raise RunnerError(f"manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit")
        value = json.loads(path.read_text(encoding="utf-8"))
    except RunnerError:
        raise
    except OSError as exc:
        raise RunnerError(f"cannot read manifest: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RunnerError(f"manifest is not valid JSON: {exc.msg}") from exc
    if not isinstance(value, dict):
        raise RunnerError("manifest must be a JSON object")
    try:
        reject_manifest_material(value)
    except RunnerError:
        raise
    required = {"argv", "cwd", "timeout_seconds", "evidence"}
    missing = sorted(required - set(value))
    if missing:
        raise RunnerError("manifest missing: " + ", ".join(missing))
    return value


def validate_argv(raw: Any) -> list[str]:
    if not isinstance(raw, list) or not raw:
        raise RunnerError("argv must be a non-empty array")
    if len(raw) > MAX_ARGV_ITEMS:
        raise RunnerError(f"argv has more than {MAX_ARGV_ITEMS} items")
    argv: list[str] = []
    total = 0
    for index, item in enumerate(raw):
        if not isinstance(item, str):
            raise RunnerError(f"argv[{index}] must be a string")
        if len(item) > MAX_ARG_CHARS:
            raise RunnerError(f"argv[{index}] exceeds the {MAX_ARG_CHARS}-character limit")
        # The argv is persisted as structured data, so shell punctuation is safe and remains data.
        # This check only rejects record-breaking or credential material.
        reject_unsafe_string(item, f"argv[{index}]")
        total += len(item)
        argv.append(item)
    if not argv[0]:
        raise RunnerError("argv[0] must name an executable")
    if total > MAX_TOTAL_ARG_CHARS:
        raise RunnerError(f"argv exceeds the {MAX_TOTAL_ARG_CHARS}-character total limit")
    return argv


def timeout_value(raw: Any) -> float | int:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        raise RunnerError("timeout_seconds must be a finite number")
    try:
        value = float(raw)
    except (OverflowError, ValueError) as exc:
        raise RunnerError("timeout_seconds must be a finite number") from exc
    if not math.isfinite(value):
        raise RunnerError("timeout_seconds must be a finite number")
    if value < MIN_TIMEOUT_SECONDS or value > MAX_TIMEOUT_SECONDS:
        raise RunnerError(
            f"timeout_seconds must be between {MIN_TIMEOUT_SECONDS:g} and {MAX_TIMEOUT_SECONDS:g}"
        )
    return raw if isinstance(raw, int) else value


def diagnostic_limit(manifest: dict[str, Any]) -> int:
    aliases = [key for key in ("diagnostic_limit", "max_diagnostic_chars", "max_output_chars") if key in manifest]
    if len(aliases) > 1:
        raise RunnerError("use only one diagnostic limit field")
    raw = manifest.get(aliases[0], DEFAULT_DIAGNOSTIC_LIMIT) if aliases else DEFAULT_DIAGNOSTIC_LIMIT
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1 or raw > MAX_DIAGNOSTIC_LIMIT:
        raise RunnerError(f"diagnostic limit must be an integer 1..{MAX_DIAGNOSTIC_LIMIT}")
    return raw


def relative_to(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix() or "."


def sensitive_path(path: Path, root: Path) -> bool:
    return bool(SENSITIVE_PATH_RE.search(relative_to(root, path)))


def environment_mapping(manifest: dict[str, Any]) -> tuple[dict[str, str], str | None]:
    """Return explicit environment values and an optional human label, never ambient secrets."""

    if "env" in manifest and "environment" in manifest and isinstance(manifest["environment"], dict):
        raise RunnerError("use only one of env or environment for explicit variables")
    raw = manifest.get("env")
    label: str | None = None
    if raw is None and isinstance(manifest.get("environment"), dict):
        raw = manifest["environment"]
    elif raw is None and isinstance(manifest.get("environment"), str):
        label = manifest["environment"]
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise RunnerError("env must be an object of explicit environment values")
    result: dict[str, str] = {}
    for key, value in raw.items():
        if not isinstance(key, str) or not ENV_KEY_RE.fullmatch(key):
            raise RunnerError(f"environment key is invalid: {key!r}")
        if not isinstance(value, str):
            raise RunnerError(f"environment value for {key} must be a string")
        reject_unsafe_string(value, f"environment value for {key}")
        result[key] = value
    if label is not None:
        reject_unsafe_string(label, "environment label")
    return result, label


def load_environment_file(root: Path, raw: Any) -> tuple[dict[str, str], Path | None]:
    if raw is None:
        return {}, None
    path = resolve_path(root, raw, "environment_file", must_exist=True)
    if sensitive_path(path, root):
        raise RunnerError(f"environment_file names a credential-bearing path: {path}")
    if not path.is_file():
        raise RunnerError(f"environment_file is not a regular file: {path}")
    try:
        if path.stat().st_size > MAX_ENV_FILE_BYTES:
            raise RunnerError(f"environment_file exceeds the {MAX_ENV_FILE_BYTES}-byte limit")
        content = path.read_text(encoding="utf-8")
    except RunnerError:
        raise
    except (OSError, UnicodeError) as exc:
        raise RunnerError(f"cannot read environment_file: {exc}") from exc
    values: dict[str, str] = {}
    for line_number, line in enumerate(content.splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        if "=" not in text:
            raise RunnerError(f"environment_file:{line_number} must use KEY=VALUE")
        key, value = text.split("=", 1)
        if not ENV_KEY_RE.fullmatch(key):
            raise RunnerError(f"environment_file:{line_number} has an invalid key")
        reject_unsafe_string(value, f"environment_file:{line_number}")
        values[key] = value
    return values, path


def child_environment(explicit: dict[str, str], file_values: dict[str, str]) -> tuple[dict[str, str], dict[str, Any]]:
    """Construct a small environment and a non-secret fingerprint descriptor."""

    environment = {key: os.environ[key] for key in INHERITED_ENV_KEYS if os.environ.get(key)}
    environment.setdefault("PATH", os.defpath)
    environment.update(file_values)
    environment.update(explicit)
    value_hashes = {key: sha256_text(value) for key, value in sorted(environment.items())}
    descriptor = {
        "keys": sorted(environment),
        "value_sha256": value_hashes,
        "python": platform.python_version(),
        "platform": platform.platform(aliased=True),
    }
    return environment, descriptor


def validate_authority(manifest: dict[str, Any], allow_live: bool) -> tuple[bool, str, str | None]:
    if manifest["evidence"] != "live":
        if allow_live:
            raise RunnerError("--allow-live requires evidence=live")
        return True, "fixture evidence", None
    authority = manifest.get("authority")
    if not isinstance(authority, dict) or not authority:
        return False, "live evidence requires an authority envelope", None
    if authority.get("allow_live") is not True:
        return False, "authority envelope must set allow_live=true", sha256_text(canonical_json(authority))
    if not isinstance(authority.get("scope"), str) or not authority["scope"].strip():
        return False, "authority envelope needs a non-empty scope", sha256_text(canonical_json(authority))
    if not allow_live:
        return False, "live evidence requires the explicit --allow-live action", sha256_text(canonical_json(authority))
    return True, "explicit live authority supplied", sha256_text(canonical_json(authority))


class BoundedOutput:
    """Drain both pipes while retaining at most one diagnostic-limit of decoded text."""

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self._remaining = limit
        self._parts: dict[str, list[str]] = {"stdout": [], "stderr": []}
        self._truncated = False
        self._lock = threading.Lock()

    def feed(self, stream_name: str, data: bytes) -> None:
        text = data.decode("utf-8", errors="replace")
        with self._lock:
            if self._remaining <= 0:
                self._truncated = True
                return
            retained = text[: self._remaining]
            if retained:
                self._parts[stream_name].append(retained)
                self._remaining -= len(retained)
            if len(retained) < len(text):
                self._truncated = True

    def text(self) -> tuple[str, bool]:
        with self._lock:
            stdout = "".join(self._parts["stdout"])
            stderr = "".join(self._parts["stderr"])
            truncated = self._truncated
        pieces = []
        if stdout:
            pieces.append(f"stdout: {stdout}")
        if stderr:
            pieces.append(f"stderr: {stderr}")
        value = "; ".join(pieces) or "no output"
        value = value.replace("\r", "\\r").replace("\n", "\\n")
        value = SECRET_RE.sub("<redacted>", value)
        if len(value) > self.limit:
            value = value[: self.limit]
            truncated = True
        return value or "no output", truncated


@dataclass
class ProcessResult:
    status: str
    returncode: int | None
    duration_ms: int
    diagnostic: str
    diagnostic_truncated: bool
    cleanup: dict[str, Any]


def drain_pipe(stream: BinaryIO, stream_name: str, output: BoundedOutput) -> None:
    try:
        while True:
            chunk = stream.read(8192)
            if not chunk:
                break
            output.feed(stream_name, chunk)
    except (OSError, ValueError):
        # The process was torn down while the reader drained.  The bounded data already captured is
        # still useful; a pipe-close race must not turn a completed timeout into an unbounded wait.
        pass
    finally:
        try:
            stream.close()
        except OSError:
            pass


def terminate_process_group(process: subprocess.Popen[bytes]) -> dict[str, Any]:
    actions: list[str] = []
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGTERM)
            actions.append("SIGTERM process group")
        except ProcessLookupError:
            actions.append("process group already exited")
        except OSError:
            actions.append("process group termination unavailable")
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            pass
        # A parent may exit on SIGTERM while a descendant ignores it.  Escalate the process group
        # independently of the parent's state so a timeout never leaves that descendant running.
        try:
            os.killpg(process.pid, signal.SIGKILL)
            actions.append("SIGKILL process group")
        except ProcessLookupError:
            actions.append("process group exited before SIGKILL")
        except OSError:
            actions.append("process group SIGKILL unavailable")
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
            actions.append("reaped parent with kill")
    else:
        # Windows has no killpg. CREATE_NEW_PROCESS_GROUP is still requested at spawn time; taskkill
        # with /T is the native tree-equivalent when available, and terminate is the safe fallback.
        try:
            taskkill = subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(process.pid)],
                capture_output=True,
                timeout=2,
                check=False,
                shell=False,
            )
            actions.append("taskkill process tree" if taskkill.returncode == 0 else "taskkill unavailable")
        except (OSError, subprocess.TimeoutExpired):
            process.terminate()
            actions.append("terminated parent fallback")
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
            actions.append("reaped parent with kill")
    return {"process_group_termination": True, "actions": actions, "reaped": process.poll() is not None}


def execute_argv(argv: list[str], cwd: Path, timeout_seconds: float | int, limit: int, environment: dict[str, str]) -> ProcessResult:
    output = BoundedOutput(limit)
    started = time.monotonic()
    process: subprocess.Popen[bytes] | None = None
    readers: list[threading.Thread] = []
    try:
        kwargs: dict[str, Any] = {
            "cwd": cwd,
            "env": environment,
            "stdin": subprocess.DEVNULL,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "shell": False,
            "close_fds": True,
        }
        if os.name == "posix":
            kwargs["start_new_session"] = True
        else:
            kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        process = subprocess.Popen(argv, **kwargs)
        assert process.stdout is not None and process.stderr is not None
        readers = [
            threading.Thread(target=drain_pipe, args=(process.stdout, "stdout", output), daemon=True),
            threading.Thread(target=drain_pipe, args=(process.stderr, "stderr", output), daemon=True),
        ]
        for reader in readers:
            reader.start()
        try:
            process.wait(timeout=float(timeout_seconds))
            status = "passed" if process.returncode == 0 else "failed"
            cleanup = {
                "process_group_termination": False,
                "actions": ["process exited normally"],
                "reaped": True,
            }
        except subprocess.TimeoutExpired:
            cleanup = terminate_process_group(process)
            status = "timeout"
    except OSError as exc:
        duration_ms = round((time.monotonic() - started) * 1000)
        detail = SECRET_RE.sub("<redacted>", str(exc)).replace("\r", "\\r").replace("\n", "\\n")
        return ProcessResult("failed", None, duration_ms, f"process error: {detail}", False, {"process_group_termination": False, "actions": [], "reaped": True})
    finally:
        for reader in readers:
            reader.join(timeout=2)

    assert process is not None
    diagnostic, truncated = output.text()
    if status == "timeout" and diagnostic == "no output":
        diagnostic = f"command exceeded {timeout_seconds:g}s"
    duration_ms = round((time.monotonic() - started) * 1000)
    return ProcessResult(status, process.returncode, duration_ms, diagnostic, truncated, cleanup)


def atomic_write(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def record_base(
    root: Path,
    manifest_path: Path,
    manifest_hash: str,
    output: Path,
    argv: list[str],
    cwd: Path,
    timeout_seconds: float | int,
    limit: int,
    evidence: str,
    environment: dict[str, Any],
    environment_fingerprint: str,
    authority_hash: str | None,
) -> dict[str, Any]:
    run_id = sha256_text(f"{manifest_hash}|{relative_to(root, output)}|{canonical_json(argv)}")[:16]
    return {
        "schema": SCHEMA,
        "id": run_id,
        "recorded_at": stamp(),
        "manifest": str(manifest_path),
        "manifest_sha256": manifest_hash,
        "output": str(output),
        "argv": argv,
        "shell": False,
        "cwd": str(cwd),
        "cwd_relative": relative_to(root, cwd),
        "timeout_seconds": timeout_seconds,
        "diagnostic_limit": limit,
        "evidence": evidence,
        "evidence_class": evidence,
        "environment": environment,
        "environment_fingerprint": environment_fingerprint,
        "authority_sha256": authority_hash,
        "evidence_promoted": False,
        "revalidate": {
            "manifest": str(manifest_path),
            "manifest_sha256": manifest_hash,
            "condition": "rerun the same manifest with the same environment, cwd, and timeout",
        },
    }


def prepare_environment(root: Path, manifest: dict[str, Any]) -> tuple[dict[str, str], dict[str, Any], str]:
    explicit, label = environment_mapping(manifest)
    file_values, environment_file = load_environment_file(root, manifest.get("environment_file"))
    if set(explicit) & set(file_values):
        # An explicit object must not silently override a file value: duplicate declarations are
        # difficult to audit and make revalidation ambiguous.
        duplicate = sorted(set(explicit) & set(file_values))[0]
        raise RunnerError(f"environment key is declared in both env and environment_file: {duplicate}")
    environment, descriptor = child_environment(explicit, file_values)
    descriptor["label"] = label or "isolated"
    descriptor["file"] = relative_to(root, environment_file) if environment_file else None
    fingerprint = sha256_text(canonical_json(descriptor))
    return environment, {
        "label": descriptor["label"],
        "keys": descriptor["keys"],
        "file": descriptor["file"],
    }, fingerprint


def run_manifest(args: argparse.Namespace) -> int:
    root = resolve_root(args.root)
    try:
        manifest_path = Path(args.manifest).expanduser().resolve()
    except (OSError, RuntimeError, ValueError) as exc:
        die(f"manifest cannot be resolved: {exc}")
    try:
        manifest = load_manifest(manifest_path)
        argv = validate_argv(manifest["argv"])
        cwd = resolve_path(root, manifest["cwd"], "cwd", must_exist=True)
        if not cwd.is_dir():
            raise RunnerError(f"cwd is not a directory: {cwd}")
        timeout_seconds = timeout_value(manifest["timeout_seconds"])
        limit = diagnostic_limit(manifest)
        evidence = manifest["evidence"]
        if evidence not in {"fixture", "live"}:
            raise RunnerError("evidence must be fixture or live")
        environment, environment_descriptor, environment_fingerprint = prepare_environment(root, manifest)
        output_raw = args.output if args.output is not None else manifest.get("output", ".wgm/stage10/runs/result.json")
        output = resolve_output(root, output_raw)
        authority_ok, authority_reason, authority_hash = validate_authority(manifest, args.allow_live)
    except RunnerError as exc:
        die(str(exc))

    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    record = record_base(
        root,
        manifest_path,
        manifest_hash,
        output,
        argv,
        cwd,
        timeout_seconds,
        limit,
        evidence,
        environment_descriptor,
        environment_fingerprint,
        authority_hash,
    )

    if not authority_ok:
        record.update(
            {
                "status": "refused",
                "exit_classification": "refused",
                "exit_code": None,
                "duration_ms": 0,
                "diagnostic": authority_reason,
                "diagnostic_truncated": False,
                "cleanup": {"process_group_termination": False, "actions": ["process not spawned"], "reaped": True},
                "evidence_promoted": False,
                "authority": "refused",
            }
        )
        atomic_write(output, record)
        print(f"stage10 runner: refused live execution; wrote {output}")
        return 1

    result = execute_argv(argv, cwd, timeout_seconds, limit, environment)
    record.update(
        {
            "status": result.status,
            "exit_classification": result.status,
            "exit_code": result.returncode,
            "duration_ms": result.duration_ms,
            "diagnostic": result.diagnostic,
            "diagnostic_truncated": result.diagnostic_truncated,
            "cleanup": result.cleanup,
            "authority": authority_reason if evidence == "live" else "not required for fixture evidence",
        }
    )
    atomic_write(output, record)
    print(f"stage10 runner: {result.status}; wrote {output}")
    return 0 if result.status == "passed" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    run = subcommands.add_parser("run", help="execute one bounded argv manifest")
    run.add_argument("--root", required=True, help="project boundary")
    run.add_argument("--manifest", required=True, help="JSON run manifest")
    run.add_argument("--output", help="result JSON path under .wgm")
    run.add_argument("--allow-live", action="store_true", help="explicitly opt into a valid live authority envelope")
    run.set_defaults(handler=run_manifest)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    raise SystemExit(args.handler(args))


if __name__ == "__main__":
    main()
