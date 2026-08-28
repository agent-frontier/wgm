#!/usr/bin/env python3
"""Stage 10's local, evidence-first memory substrate.

The command deliberately has no model, network, database, or credential-file dependency.  It
captures deterministic repository/host observations as JSONL sources and renders a small Markdown
brief as a generated view.  A later router may consume these records, but this module never promotes
model prose or executable presence into routing authority.

Commands:
    inspect  Capture repository, validation, harness, and non-secret host observations; render brief.
    brief    Render the brief from existing observations and memory records.
    record   Append one provenance-bearing memory record.
    lint     Validate records, redaction, brief bounds, and source freshness.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

OBSERVATION_SCHEMA = "stage10.observation.v1"
MEMORY_SCHEMA = "stage10.record.v1"
STANDINGS = {"observed", "validated", "corroborated", "promoted", "stale", "rejected"}
MEMORY_KINDS = {"observation", "lesson", "invariant", "decision", "route", "experiment", "failure"}
MAX_BRIEF_LINES = 120
MAX_BRIEF_BYTES = 16_000
MAX_SUMMARY_CHARS = 240
MAX_SOURCE_BYTES = 10 * 1024 * 1024

# Only these environment values are intentionally observable.  Credentials and arbitrary env are
# never read, copied, or printed by this tool.
SAFE_ENV_KEYS = (
    "AI_AGENT",
    "PI_CODING_AGENT",
    "PI_PROVIDER",
    "PI_MODEL",
    "PI_REASONING_LEVEL",
)

HARNESS_BINARIES = {
    "pi": "pi",
    "copilot-cli": "copilot",
    "claude-code": "claude",
    "codex-cli": "codex",
    "gemini-cli": "gemini",
    "cursor": "agent",
    "opencode": "opencode",
    "aider": "aider",
    "windsurf": "windsurf",
}

# This is a refusal pattern, not a claim that every word below is secret.  Requiring an assignment
# or bearer-shaped value keeps ordinary prose such as "API key rotation" usable.
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
    r"(?i)(?:^|/)(?:\.env(?:\..*)?|auth(?:entication)?\.json|credentials?(?:\..*)?|"
    r"secrets?(?:\..*)?|.*\.(?:pem|key|p12|pfx))$"
)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def fail(message: str, code: int = 2) -> "NoReturn":
    print(f"stage10: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def reject_secret(value: str, label: str) -> None:
    if SECRET_RE.search(value):
        fail(
            f"{label} looks credential-bearing; replace the token-shaped value with "
            "<redacted> or rewrite it as non-assignment prose before recording"
        )


def is_sensitive_path(relative: str) -> bool:
    return bool(SENSITIVE_PATH_RE.search(relative.replace(os.sep, "/")))


def resolve_root(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        fail(f"root is not a directory: {root}")
    return root


def state_dir(root: Path, raw: str | None) -> Path:
    path = Path(raw).expanduser() if raw else root / ".wgm" / "stage10"
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    allowed = (root / ".wgm").resolve()
    try:
        path.relative_to(allowed)
    except ValueError:
        fail(f"state directory must remain under {allowed}")
    return path


def paths(root: Path, raw: str | None) -> tuple[Path, Path, Path]:
    state = state_dir(root, raw)
    return state, state / "observations.jsonl", state / "memory.jsonl"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    text = "".join(canonical_json(record) + "\n" for record in records)
    atomic_write(path, text)


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(record) + "\n")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        if path.stat().st_size > MAX_SOURCE_BYTES:
            raise ValueError(f"{path} exceeds the {MAX_SOURCE_BYTES}-byte source limit")
    except OSError as exc:
        raise ValueError(f"cannot inspect {path}: {exc}") from exc
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{line_number} is not valid JSON: {exc.msg}") from exc
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{line_number} must contain a JSON object")
        records.append(value)
    return records


def run_git(root: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args], cwd=root, capture_output=True, text=True, check=True, timeout=10
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip()


def repository_identity(root: Path) -> dict[str, Any]:
    top = run_git(root, "rev-parse", "--show-toplevel")
    branch = run_git(root, "branch", "--show-current")
    head = run_git(root, "rev-parse", "HEAD")
    return {
        "root": str(root),
        "git": top is not None,
        "git_root": top,
        "branch": branch or "(detached or unknown)",
        "head": head or "unknown",
    }


def tracked_paths(root: Path) -> list[str]:
    output = run_git(root, "ls-files", "-z")
    if output is not None:
        # Python's text subprocess preserves NUL separators.  Ignore malformed names rather than
        # allowing a surprising byte sequence into the Markdown view.
        return sorted(path for path in output.split("\0") if path)

    found: list[str] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_file() and not relative.startswith(".git/") and not relative.startswith(".wgm/"):
            found.append(relative)
    return sorted(found)


def file_fingerprint(root: Path, relative: str) -> dict[str, Any] | None:
    if is_sensitive_path(relative):
        return {"path": relative, "sensitive": True, "sha256": None, "size": None}
    path = root / relative
    try:
        data = path.read_bytes()
    except OSError:
        return None
    return {"path": relative, "sensitive": False, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


def make_targets(root: Path) -> list[str]:
    makefile = root / "Makefile"
    if not makefile.is_file():
        return []
    targets: list[str] = []
    for match in re.finditer(r"(?m)^([A-Za-z0-9_.-]+):(?!=)", makefile.read_text(encoding="utf-8", errors="replace")):
        name = match.group(1)
        if name != ".PHONY" and name not in targets:
            targets.append(name)
    return targets


def project_surface(root: Path, files: list[str]) -> dict[str, Any]:
    known = [
        path
        for path in files
        if path in {"SKILL.md", "README.md", "AGENTS.md", "CLAUDE.md", "Makefile", "pyproject.toml", "package.json", "Cargo.toml", "go.mod"}
        or path.startswith(".github/workflows/")
    ]
    scripts = [path for path in files if path.startswith("scripts/")]
    docs = [path for path in files if path.startswith("docs/") or path.startswith("references/")]
    return {
        "entry_points": known,
        "scripts": scripts,
        "docs": docs,
        "make_targets": make_targets(root),
        "validation_targets": [target for target in make_targets(root) if target in {"check", "test", "validate", "lint", "docs"}],
    }


def load_harness_registry(script_path: Path, root: Path) -> list[dict[str, Any]]:
    candidates = [script_path.parent.parent / "compatibility" / "harnesses.json", root / "compatibility" / "harnesses.json"]
    registry = next((candidate for candidate in candidates if candidate.is_file()), None)
    if registry is None:
        return []
    try:
        payload = json.loads(registry.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return payload.get("harnesses", []) if isinstance(payload, dict) else []


def normalize_harness(raw: str) -> str | None:
    value = raw.strip().lower()
    aliases = {
        "github-copilot": "copilot-cli",
        "copilot": "copilot-cli",
        "claude": "claude-code",
        "codex": "codex-cli",
        "cursor-cli": "cursor",
        "pi-coding-agent": "pi",
    }
    if value in HARNESS_BINARIES:
        return value
    return aliases.get(value)


def process_harness() -> str | None:
    """Return a known harness found in the parent process chain, without reading command arguments."""
    pid = os.getppid()
    for _ in range(8):
        try:
            result = subprocess.run(
                ["ps", "-o", "pid=,ppid=,comm=", "-p", str(pid)],
                capture_output=True,
                text=True,
                check=True,
                timeout=2,
            )
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return None
        fields = result.stdout.strip().split()
        if len(fields) < 3:
            return None
        parent_pid, command = fields[1], fields[2]
        if (candidate := normalize_harness(Path(command).name)):
            return candidate
        if not parent_pid.isdigit() or parent_pid == str(pid):
            return None
        pid = int(parent_pid)
    return None


def host_signals() -> dict[str, Any]:
    values: dict[str, str] = {}
    redacted_keys: list[str] = []
    for key in SAFE_ENV_KEYS:
        value = os.environ.get(key, "")
        if not value:
            continue
        if any(character in value for character in "\r\n") or SECRET_RE.search(value):
            values[key] = "<redacted>"
            redacted_keys.append(key)
        else:
            values[key] = value
    candidates: list[str] = []
    if values.get("AI_AGENT") and (candidate := normalize_harness(values["AI_AGENT"])):
        candidates.append(candidate)
    if values.get("PI_CODING_AGENT", "").lower() in {"1", "true", "yes"}:
        candidates.append("pi")
    candidates = sorted(set(candidates))
    process_candidate = process_harness() if not candidates else None
    if process_candidate:
        candidates.append(process_candidate)
    candidates = sorted(set(candidates))
    current = candidates[0] if len(candidates) == 1 else "ambiguous" if candidates else "unknown"
    if values.get("AI_AGENT") or values.get("PI_CODING_AGENT"):
        source = "AI_AGENT/PI_CODING_AGENT"
    elif process_candidate:
        source = "parent process name"
    else:
        source = "no safe host signal"
    return {
        "current_harness": current,
        "detection_source": source,
        "process_signal": process_candidate or "unknown",
        "signals": values,
        "redacted_keys": redacted_keys,
        "provider": values.get("PI_PROVIDER", "unknown"),
        "model": values.get("PI_MODEL", "unknown"),
        "reasoning_level": values.get("PI_REASONING_LEVEL", "unknown"),
    }


def harness_inventory(root: Path, script_path: Path) -> dict[str, Any]:
    registry = {entry.get("id"): entry for entry in load_harness_registry(script_path, root)}
    known_ids = set(HARNESS_BINARIES)
    registry_ids = {identifier for identifier in registry if identifier}
    host = host_signals()
    rows: list[dict[str, Any]] = []
    for harness_id, binary in HARNESS_BINARIES.items():
        entry = registry.get(harness_id, {})
        found = shutil.which(binary)
        rows.append(
            {
                "id": harness_id,
                "name": entry.get("name", harness_id),
                "binary": binary,
                "present": bool(found),
                "path": found,
                "registry_status": entry.get("status", "unknown"),
                "static_invocation": entry.get("invocation", {}).get("command", "unknown"),
                "subagents": entry.get("subagents", {}).get("capability", "unknown"),
                "current": harness_id == host["current_harness"],
            }
        )
    return {
        "current": host,
        "routes": rows,
        "registry_consistency": {
            "registry_ids": sorted(registry_ids),
            "unmapped_registry_ids": sorted(registry_ids - known_ids),
            "binaries_without_registry_entry": sorted(known_ids - registry_ids) if registry else [],
        },
    }


def observation(
    identifier: str,
    kind: str,
    summary: str,
    data: dict[str, Any],
    source: str,
    evidence: list[str],
) -> dict[str, Any]:
    return {
        "schema": OBSERVATION_SCHEMA,
        "id": f"obs-{identifier}",
        "kind": kind,
        "standing": "observed",
        "summary": summary,
        "scope": "repository",
        "source": source,
        "evidence": evidence,
        "observed_at": now(),
        "fingerprint": digest(data),
        "data": data,
    }


def capture_observations(root: Path, script_path: Path) -> list[dict[str, Any]]:
    files = tracked_paths(root)
    fingerprints = [fingerprint for path in files if (fingerprint := file_fingerprint(root, path)) is not None]
    identity = repository_identity(root)
    surface = project_surface(root, files)
    harnesses = harness_inventory(root, script_path)
    omitted = sum(1 for row in fingerprints if row.get("sensitive"))
    inventory = {
        **identity,
        "tracked_file_count": len(files),
        "fingerprinted_file_count": len(fingerprints) - omitted,
        "sensitive_file_count_omitted": omitted,
        "files": fingerprints,
    }
    return [
        observation(
            "repository",
            "repository",
            f"Repository snapshot for {identity['branch']} at {identity['head']}",
            inventory,
            "command: git rev-parse + git ls-files",
            ["git:repository identity", "git:tracked file inventory and content hashes"],
        ),
        observation(
            "surface",
            "surface",
            "Repository entry points, scripts, documentation, and validation targets",
            surface,
            "files: Makefile and tracked path inventory",
            ["source inventory: tracked paths", "Makefile target parser when Makefile exists"],
        ),
        observation(
            "harnesses",
            "harnesses",
            "Known harness presence and non-secret current-host signals",
            harnesses,
            "compatibility/harnesses.json plus command presence and safe environment allowlist",
            ["command: shutil.which for known binaries", "environment: SAFE_ENV_KEYS only"],
        ),
    ]


def latest_by_kind(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    for record in records:
        kind = str(record.get("kind", ""))
        if kind:
            latest[kind] = record
    return latest


def stale_reasons(root: Path, observations: list[dict[str, Any]]) -> list[str]:
    repository = next((record for record in observations if record.get("kind") == "repository"), None)
    if not repository:
        return ["repository observation is missing"]
    reasons: list[str] = []
    recorded_files = repository.get("data", {}).get("files", [])
    recorded_paths = {row.get("path") for row in recorded_files if row.get("path")}
    if recorded_paths != set(tracked_paths(root)):
        reasons.append("tracked file inventory changed")
    for row in recorded_files:
        relative = row.get("path")
        if not relative or row.get("sensitive"):
            continue
        current = file_fingerprint(root, relative)
        if current is None:
            reasons.append(f"source missing: {relative}")
        elif current.get("sha256") != row.get("sha256"):
            reasons.append(f"source changed: {relative}")
    return reasons


def render_brief(root: Path, state: Path, observations: list[dict[str, Any]], memories: list[dict[str, Any]]) -> str:
    grouped = latest_by_kind(observations)
    repository = grouped.get("repository", {}).get("data", {})
    surface = grouped.get("surface", {}).get("data", {})
    harness_data = grouped.get("harnesses", {}).get("data", {})
    identity = repository
    stale = stale_reasons(root, observations)
    generated = f"python3 scripts/stage10_memory.py brief --root {root}"
    lines = [
        "<!-- GENERATED by `stage10_memory.py`; edit source records, then rerun the command. -->",
        "# Stage 10 system brief",
        "",
        f"> Generated at `{now()}` from `{state / 'observations.jsonl'}` and `{state / 'memory.jsonl'}`.",
        f"> Refresh with: `{generated}`",
        "",
        "## Snapshot",
        f"- Repository: `{identity.get('root', str(root))}`",
        f"- Git: `{'yes' if identity.get('git') else 'unknown'}` · branch `{identity.get('branch', 'unknown')}` · head `{identity.get('head', 'unknown')}`",
        f"- Observation freshness: `{'stale' if stale else 'current'}`",
        "",
        "## System surface",
        f"- Tracked files: **{repository.get('tracked_file_count', 0)}**; safe fingerprints: **{repository.get('fingerprinted_file_count', 0)}**; sensitive paths omitted: **{repository.get('sensitive_file_count_omitted', 0)}**.",
        f"- Entry points: {', '.join(f'`{item}`' for item in surface.get('entry_points', [])[:12]) or 'none observed'}",
        f"- Scripts: **{len(surface.get('scripts', []))}** · documentation files: **{len(surface.get('docs', []))}**",
        f"- Validation targets: {', '.join(f'`{item}`' for item in surface.get('validation_targets', [])) or 'none observed'}",
        "",
        "## Harnesses",
        "",
        "| Harness | Present | Current | Registry standing | Qualification |\n|---|---|---|---|---|",
    ]
    current = harness_data.get("current", {})
    for route in harness_data.get("routes", []):
        present = "yes" if route.get("present") else "no"
        active = "yes" if route.get("current") else "no"
        qualification = "inventory only"
        lines.append(f"| `{route.get('name', route.get('id'))}` | {present} | {active} | `{route.get('registry_status', 'unknown')}` | {qualification} |")
    lines.extend(
        [
            "",
            f"- Current-harness signal: **{current.get('current_harness', 'unknown')}** ({current.get('detection_source', 'unknown')}).",
            f"- Provider/model: `{current.get('provider', 'unknown')}` / `{current.get('model', 'unknown')}`; reasoning: `{current.get('reasoning_level', 'unknown')}`.",
            "- Evidence limit: executable presence is not authentication, live compatibility, or a successful Ralph journey.",
            "",
            "## Memory",
        ]
    )
    if memories:
        for memory in memories[-12:]:
            lines.extend(
                [
                    f"### `{memory.get('standing', 'unknown')}` — {memory.get('summary', '(missing summary)')}",
                    f"- Scope: `{memory.get('scope', 'unknown')}` · kind: `{memory.get('kind', 'unknown')}`",
                    f"- Source: `{memory.get('source', 'unknown')}`",
                    f"- Evidence: {', '.join(f'`{item}`' for item in memory.get('evidence', [])) or 'none'}",
                    f"- Revalidate when: {memory.get('revalidate_when', 'source or environment changes')}",
                ]
            )
    else:
        lines.append("- No memory records have been recorded yet.")
    lines.extend(["", "## Uncertainty and findings"])
    if stale:
        lines.extend(f"- **STALE:** {reason}. Rerun inspect before using this brief for routing." for reason in stale[:20])
    if current.get("current_harness") in {"unknown", "ambiguous"}:
        lines.append("- Current harness is unknown or ambiguous; do not infer it from binary presence.")
    lines.extend(
        [
            "- Live qualification, authentication, semantic retrieval, and learned routing are not performed by `inspect`.",
            "- Raw observations and records remain under `.wgm/stage10/`; this page is a generated view.",
            "",
        ]
    )
    return "\n".join(lines) + "\n"


def write_brief(root: Path, state: Path, observations: list[dict[str, Any]], memories: list[dict[str, Any]]) -> Path:
    target = state / "brief.md"
    content = render_brief(root, state, observations, memories)
    atomic_write(target, content)
    return target


def render_system_map(root: Path, state: Path, observations: list[dict[str, Any]]) -> str:
    """Render the fuller deterministic map; the brief stays the small hot view."""
    grouped = latest_by_kind(observations)
    repository = grouped.get("repository", {}).get("data", {})
    surface = grouped.get("surface", {}).get("data", {})
    harness_data = grouped.get("harnesses", {}).get("data", {})
    lines = [
        "<!-- GENERATED by `stage10_memory.py`; edit source observations, then rerun inspect. -->",
        "# Stage 10 system map",
        "",
        f"> Generated at `{now()}` from `{state / 'observations.jsonl'}`.",
        "> This is a deterministic map of observed surfaces, not a claim that every semantic dependency is known.",
        "",
        "## Repository",
        f"- Root: `{repository.get('root', str(root))}`",
        f"- Git: `{'yes' if repository.get('git') else 'unknown'}` · branch `{repository.get('branch', 'unknown')}` · head `{repository.get('head', 'unknown')}`",
        f"- Tracked files: **{repository.get('tracked_file_count', 0)}** · safe fingerprints: **{repository.get('fingerprinted_file_count', 0)}** · sensitive paths omitted: **{repository.get('sensitive_file_count_omitted', 0)}**",
        "",
        "## Entry points and gates",
    ]
    for item in surface.get("entry_points", []):
        lines.append(f"- `{item}`")
    if not surface.get("entry_points"):
        lines.append("- None observed.")
    lines.extend(["", "### Validation targets"])
    for item in surface.get("validation_targets", []):
        lines.append(f"- `{item}`")
    if not surface.get("validation_targets"):
        lines.append("- None observed.")
    lines.extend(["", "## Harness inventory", "", "| Harness | Binary | Present | Current | Registry | Subagents |", "|---|---|---|---|---|---|"])
    for route in harness_data.get("routes", []):
        lines.append(
            f"| `{route.get('name', route.get('id'))}` | `{route.get('binary', 'unknown')}` | "
            f"{'yes' if route.get('present') else 'no'} | {'yes' if route.get('current') else 'no'} | "
            f"`{route.get('registry_status', 'unknown')}` | `{route.get('subagents', 'unknown')}` |"
        )
    lines.extend(
        [
            "",
            "## Evidence boundaries",
            "- Executable presence is inventory evidence only.",
            "- Current-host/provider/model values come only from the safe environment allowlist or a parent process name.",
            "- Authentication, live protocol support, tool success, and Ralph success require later qualification levels.",
            "- Sensitive paths are counted but not read into observations or views.",
            "",
        ]
    )
    return "\n".join(lines)


def write_system_map(root: Path, state: Path, observations: list[dict[str, Any]]) -> Path:
    target = state / "system-map.md"
    atomic_write(target, render_system_map(root, state, observations))
    return target


def current_environment(root: Path) -> dict[str, Any]:
    identity = repository_identity(root)
    host = host_signals()
    return {
        "branch": identity.get("branch", "unknown"),
        "head": identity.get("head", "unknown"),
        "harness": host.get("current_harness", "unknown"),
        "provider": host.get("provider", "unknown"),
        "model": host.get("model", "unknown"),
    }


def make_memory_record(
    root: Path,
    kind: str,
    standing: str,
    scope: str,
    summary: str,
    source: str,
    evidence: list[str],
    revalidate_when: str = "",
) -> dict[str, Any]:
    summary = summary.strip()
    source = source.strip()
    scope = scope.strip()
    evidence = [item.strip() for item in evidence if item.strip()]
    if not summary or len(summary) > MAX_SUMMARY_CHARS or any(character in summary for character in "\r\n"):
        fail(f"summary must be 1..{MAX_SUMMARY_CHARS} characters and stay on one line")
    if not scope or any(character in scope for character in "\r\n"):
        fail("scope must not be empty or multiline")
    if not source or any(character in source for character in "\r\n") or not evidence:
        fail("source and at least one single-line evidence reference are required")
    if any(character in revalidate_when for character in "\r\n"):
        fail("revalidate_when must stay on one line")
    for label, value in (
        ("summary", summary),
        ("source", source),
        ("revalidate_when", revalidate_when),
        *[("evidence", item) for item in evidence],
    ):
        reject_secret(value, label)
    if standing in {"corroborated", "promoted"} and len(evidence) < 2:
        fail(f"{standing} memory requires at least two independent evidence references")
    if standing == "promoted" and not any(item.lower().startswith("human-approved:") for item in evidence):
        fail("promoted memory requires a human-approved: evidence reference")
    stable = "|".join((kind, scope, summary, source))
    identifier = "mem-" + hashlib.sha256(stable.encode("utf-8")).hexdigest()[:16]
    return {
        "schema": MEMORY_SCHEMA,
        "id": identifier,
        "kind": kind,
        "standing": standing,
        "summary": summary,
        "scope": scope,
        "source": source,
        "evidence": evidence,
        "environment": current_environment(root),
        "observed_at": now(),
        "revalidate_when": revalidate_when.strip() or "source, validation, or environment fingerprint changes",
    }


def record_memory(args: argparse.Namespace) -> None:
    root = resolve_root(args.root)
    state, _, memory_file = paths(root, args.state_dir)
    record = make_memory_record(
        root,
        args.kind,
        args.standing,
        args.scope,
        args.summary,
        args.source,
        args.evidence,
        args.revalidate_when,
    )
    state.mkdir(parents=True, exist_ok=True)
    append_jsonl(memory_file, record)
    print(f"stage10 record: appended {record['id']} to {memory_file}")


def input_file(root: Path, raw: str) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    try:
        path.relative_to(root)
    except ValueError:
        fail(f"legacy input must remain under project root: {path}")
    return path


def legacy_records(root: Path, memories_file: Path, scores_file: Path) -> list[dict[str, Any]]:
    """Convert legacy ledgers without deleting or treating them as authoritative."""
    records: list[dict[str, Any]] = []
    if memories_file.is_file():
        relative = memories_file.relative_to(root).as_posix()
        for line_number, line in enumerate(memories_file.read_text(encoding="utf-8").splitlines(), 1):
            text = line.strip()
            if not text.startswith("- "):
                continue
            summary = text[2:].strip()
            if not summary or summary.startswith("<"):
                continue
            records.append(
                make_memory_record(
                    root,
                    "lesson",
                    "observed",
                    "project",
                    summary,
                    f"legacy:{relative}:{line_number}",
                    [f"legacy-file:{relative}"],
                )
            )
    if scores_file.is_file():
        relative = scores_file.relative_to(root).as_posix()
        for line_number, line in enumerate(scores_file.read_text(encoding="utf-8").splitlines(), 1):
            text = line.strip()
            if not text.startswith("|") or set(text.replace("|", "").replace("-", "").replace(":", "").strip()) == set():
                continue
            cells = [cell.strip() for cell in text.strip("|").split("|")]
            if len(cells) < 3 or cells[0].lower() in {"iteration", "---"}:
                continue
            summary = "Legacy score: " + " · ".join(cells)
            records.append(
                make_memory_record(
                    root,
                    "observation",
                    "observed",
                    "project",
                    summary,
                    f"legacy:{relative}:{line_number}",
                    [f"legacy-file:{relative}"],
                )
            )
    return records


def migrate_legacy(args: argparse.Namespace) -> None:
    root = resolve_root(args.root)
    state, _, memory_file = paths(root, args.state_dir)
    memories_file = input_file(root, args.memories_file)
    scores_file = input_file(root, args.scores_file)
    try:
        existing = read_jsonl(memory_file)
    except ValueError as exc:
        fail(str(exc), 1)
    existing_ids = {record.get("id") for record in existing}
    imported = legacy_records(root, memories_file, scores_file)
    pending = [record for record in imported if record.get("id") not in existing_ids]
    state.mkdir(parents=True, exist_ok=True)
    for record in pending:
        append_jsonl(memory_file, record)
    observations = read_jsonl(paths(root, args.state_dir)[1])
    if observations:
        write_brief(root, state, observations, existing + pending)
        write_system_map(root, state, observations)
    print(
        f"stage10 migrate: imported {len(pending)} legacy records, "
        f"skipped {len(imported) - len(pending)} already present; "
        f"legacy sources remain unchanged"
    )


def validate_record(
    record: dict[str, Any],
    expected_schema: str,
    label: str,
    allowed_kinds: set[str],
) -> list[str]:
    required = {"schema", "id", "kind", "standing", "summary", "scope", "source", "evidence", "observed_at"}
    missing = sorted(required - set(record))
    errors = [f"{label} missing: {', '.join(missing)}"] if missing else []
    if record.get("schema") != expected_schema:
        errors.append(f"{label} has schema {record.get('schema')!r}, expected {expected_schema!r}")
    if record.get("standing") not in STANDINGS:
        errors.append(f"{label} has invalid standing {record.get('standing')!r}")
    if not isinstance(record.get("id"), str) or not record.get("id", "").strip():
        errors.append(f"{label} id is empty")
    if record.get("kind") not in allowed_kinds:
        errors.append(f"{label} has invalid kind {record.get('kind')!r}")
    if not isinstance(record.get("scope"), str) or not record.get("scope", "").strip():
        errors.append(f"{label} scope is empty")
    if not isinstance(record.get("summary"), str) or not record.get("summary", "").strip():
        errors.append(f"{label} summary is empty")
    if not isinstance(record.get("source"), str) or not record.get("source", "").strip():
        errors.append(f"{label} source is empty")
    evidence = record.get("evidence")
    if not isinstance(evidence, list) or not evidence or any(
        not isinstance(item, str) or not item.strip() or any(character in item for character in "\r\n")
        for item in evidence
    ):
        errors.append(f"{label} needs a non-empty single-line evidence list")
    if record.get("standing") in {"corroborated", "promoted"} and len(record.get("evidence", [])) < 2:
        errors.append(f"{label} promoted/corroborated standing needs two evidence references")
    if record.get("standing") == "promoted" and not any(
        isinstance(item, str) and item.lower().startswith("human-approved:") for item in record.get("evidence", [])
    ):
        errors.append(f"{label} promoted standing needs human-approved evidence")
    if SECRET_RE.search(canonical_json(record)):
        errors.append(f"{label} contains credential-like material")
    if any(character in canonical_json(record) for character in "\r\n"):
        errors.append(f"{label} contains a multiline field")
    return errors


def lint(args: argparse.Namespace) -> None:
    root = resolve_root(args.root)
    state, observations_file, memory_file = paths(root, args.state_dir)
    errors: list[str] = []
    try:
        observations = read_jsonl(observations_file)
        memories = read_jsonl(memory_file)
    except ValueError as exc:
        fail(str(exc), 1)
    seen: set[str] = set()
    for index, record in enumerate(observations, 1):
        identifier = str(record.get("id", ""))
        if identifier in seen:
            errors.append(f"duplicate observation id: {identifier}")
        seen.add(identifier)
        errors.extend(
            validate_record(
                record,
                OBSERVATION_SCHEMA,
                f"observation[{index}]",
                {"repository", "surface", "harnesses"},
            )
        )
    seen.clear()
    for index, record in enumerate(memories, 1):
        identifier = str(record.get("id", ""))
        if identifier in seen:
            errors.append(f"duplicate memory id: {identifier}")
        seen.add(identifier)
        errors.extend(validate_record(record, MEMORY_SCHEMA, f"memory[{index}]", MEMORY_KINDS))
    if not observations:
        errors.append("no observations found; run inspect first")
    errors.extend(stale_reasons(root, observations))
    harness_observation = next((record for record in observations if record.get("kind") == "harnesses"), None)
    consistency = (harness_observation or {}).get("data", {}).get("registry_consistency", {})
    for identifier in consistency.get("unmapped_registry_ids", []):
        errors.append(f"harness registry entry has no executable mapping: {identifier}")
    target = state / "brief.md"
    system_map = state / "system-map.md"
    if not target.is_file():
        errors.append(f"generated brief is missing: {target}")
    else:
        content = target.read_text(encoding="utf-8")
        line_count = len(content.splitlines())
        byte_count = len(content.encode("utf-8"))
        if line_count > MAX_BRIEF_LINES:
            errors.append(f"brief has {line_count} lines; maximum is {MAX_BRIEF_LINES}")
        if byte_count > MAX_BRIEF_BYTES:
            errors.append(f"brief has {byte_count} bytes; maximum is {MAX_BRIEF_BYTES}")
        if SECRET_RE.search(content):
            errors.append("brief contains credential-like material")
        for marker in ("# Stage 10 system brief", "GENERATED", "## Harnesses", "## Memory"):
            if marker not in content:
                errors.append(f"brief is missing required section/marker: {marker}")
    if not system_map.is_file():
        errors.append(f"generated system map is missing: {system_map}")
    else:
        map_content = system_map.read_text(encoding="utf-8")
        map_lines = len(map_content.splitlines())
        map_bytes = len(map_content.encode("utf-8"))
        if map_lines > MAX_BRIEF_LINES:
            errors.append(f"system map has {map_lines} lines; maximum is {MAX_BRIEF_LINES}")
        if map_bytes > MAX_BRIEF_BYTES:
            errors.append(f"system map has {map_bytes} bytes; maximum is {MAX_BRIEF_BYTES}")
        if SECRET_RE.search(map_content):
            errors.append("system map contains credential-like material")
        for marker in ("# Stage 10 system map", "GENERATED", "## Harness inventory", "## Evidence boundaries"):
            if marker not in map_content:
                errors.append(f"system map is missing required section/marker: {marker}")
    if errors:
        for error in errors:
            print(f"stage10: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"stage10 lint: GREEN ({len(observations)} observations, {len(memories)} memory records)")


def inspect(args: argparse.Namespace) -> None:
    root = resolve_root(args.root)
    state, observations_file, memory_file = paths(root, args.state_dir)
    script_path = Path(__file__).resolve()
    observations = capture_observations(root, script_path)
    write_jsonl(observations_file, observations)
    memories = read_jsonl(memory_file)
    target = write_brief(root, state, observations, memories)
    system_map = write_system_map(root, state, observations)
    print(f"stage10 inspect: wrote {len(observations)} observations to {observations_file}")
    print(f"stage10 inspect: wrote human brief to {target}")
    print(f"stage10 inspect: wrote system map to {system_map}")
    print("stage10 inspect: no model call, network call, or credential-file read")


def brief(args: argparse.Namespace) -> None:
    root = resolve_root(args.root)
    state, observations_file, memory_file = paths(root, args.state_dir)
    try:
        observations = read_jsonl(observations_file)
        memories = read_jsonl(memory_file)
    except ValueError as exc:
        fail(str(exc), 1)
    if not observations:
        fail(f"no observations found at {observations_file}; run inspect first", 1)
    target = write_brief(root, state, observations, memories)
    system_map = write_system_map(root, state, observations)
    print(f"stage10 brief: wrote {target}")
    print(f"stage10 brief: wrote system map to {system_map}")


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(description="Stage 10 evidence-first local memory")
    subcommands = command.add_subparsers(dest="command", required=True)

    def common(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--root", default=".", help="project root (default: current directory)")
        sub.add_argument("--state-dir", help="override .wgm/stage10 output directory")

    inspect_command = subcommands.add_parser("inspect", help="capture observations and generate the brief")
    common(inspect_command)
    inspect_command.set_defaults(handler=inspect)

    brief_command = subcommands.add_parser("brief", help="regenerate the human-readable brief")
    common(brief_command)
    brief_command.set_defaults(handler=brief)

    lint_command = subcommands.add_parser("lint", help="validate records, freshness, and brief bounds")
    common(lint_command)
    lint_command.set_defaults(handler=lint)

    record_command = subcommands.add_parser("record", help="append one memory record")
    common(record_command)
    record_command.add_argument("--kind", choices=sorted(MEMORY_KINDS), default="lesson")
    record_command.add_argument("--standing", choices=sorted(STANDINGS), default="observed")
    record_command.add_argument("--scope", required=True, help="task, subsystem, project, or host scope")
    record_command.add_argument("--summary", required=True)
    record_command.add_argument("--source", required=True, help="source path/claim reference")
    record_command.add_argument("--evidence", action="append", required=True, help="repeat for independent evidence")
    record_command.add_argument("--revalidate-when", default="")
    record_command.set_defaults(handler=record_memory)

    migrate_command = subcommands.add_parser("migrate", help="import legacy memories and scores into Stage 10")
    common(migrate_command)
    migrate_command.add_argument("--memories-file", default=".wgm/memories.md")
    migrate_command.add_argument("--scores-file", default=".wgm/scores.md")
    migrate_command.set_defaults(handler=migrate_legacy)
    return command


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
