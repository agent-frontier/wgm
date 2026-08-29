#!/usr/bin/env python3
"""Offline Stage 10 experiment comparison and isolated local execution.

The ``compare`` command remains the only authority for hard non-regression, holdout, feature
economy, and PR recommendations. The ``execute`` command creates one local branch/worktree, applies
already-local candidate material, and runs declared checks through :mod:`stage10_runner`. Neither
command calls a provider, pushes, opens a PR, merges, deploys, publishes, or activates policy.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any

import stage10_runner

MAX_BYTES = 1_000_000
MAX_PATCH_BYTES = 10_000_000
MAX_CANDIDATES = 100
MAX_EXECUTION_CHECKS = 100
MAX_EXECUTION_BUDGET_SECONDS = 3_600.0
STANDING_CATEGORIES = {"security", "correctness", "reliability", "compatibility"}
SECRET_RE = re.compile(
    r"(?i)(?:api[_ -]?key|secret|password|passwd|token|authorization|bearer)"
    r"\s*(?:[:=]|is)\s*[^\s,;]+"
    r"|\b(?:ghp_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"github_pat_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"sk-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"xoxb-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"AKIA[A-Z0-9]{12,})\b"
)
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{7,64}$")
LOCAL_SHELL_EXECUTABLES = {
    "bash", "cmd", "fish", "powershell", "pwsh", "sh", "zsh",
}
LOCAL_EXTERNAL_EXECUTABLES = {
    "aider", "agent", "claude", "codex", "copilot", "curl", "ftp", "gemini",
    "gh", "nc", "ncat", "opencode", "rsync", "scp", "sftp", "ssh", "telnet", "wget",
}
LOCAL_MUTATING_GIT_OPERATIONS = {
    "checkout", "clone", "commit", "config", "fetch", "merge", "pull", "push", "rebase",
    "remote", "reset", "switch", "tag", "update-ref", "worktree",
}


class ExecutionError(RuntimeError):
    """A controlled execution failure that must retain a negative report."""


def die(message: str, code: int = 2) -> "NoReturn":
    import sys

    print(f"stage10 experiments: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def root_path(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        die(f"root is not a directory: {root}")
    return root


def under_root(root: Path, raw: str) -> Path:
    path = Path(raw).expanduser().resolve()
    try:
        path.relative_to(root)
    except ValueError:
        die(f"manifest must remain under project root: {path}")
    if not path.is_file():
        die(f"manifest is not a file: {path}")
    return path


def under_wgm(root: Path, raw: str | None) -> Path:
    path = Path(raw).expanduser() if raw else root / ".wgm" / "stage10" / "experiments" / "report.json"
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    try:
        path.relative_to((root / ".wgm").resolve())
    except ValueError:
        die(f"output must remain under {root / '.wgm'}")
    return path


def reject_unsafe(value: Any, label: str) -> None:
    def walk(item: Any, path: str) -> None:
        if isinstance(item, str):
            if any(character in item for character in "\r\n"):
                die(f"{label}.{path} contains multiline material")
            if SECRET_RE.search(item):
                die(f"{label}.{path} contains credential-like material")
        elif isinstance(item, dict):
            for key, child in item.items():
                walk(child, f"{path}.{key}")
        elif isinstance(item, list):
            for index, child in enumerate(item):
                walk(child, f"{path}[{index}]")

    walk(value, "value")
    try:
        json.dumps(value, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError) as exc:
        die(f"{label} is not JSON-safe: {exc}")


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > MAX_BYTES:
            die(f"manifest exceeds the {MAX_BYTES}-byte limit")
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        die(f"cannot read manifest: {exc}")
    except json.JSONDecodeError as exc:
        die(f"manifest is not valid JSON: {exc.msg}")
    if not isinstance(value, dict):
        die("manifest must be an object")
    required = {
        "hypothesis", "baseline_sha", "route", "environment", "allowed_files", "evaluator",
        "target_metric", "metric_direction", "non_regression", "budget", "candidates",
    }
    missing = sorted(required - set(value))
    if missing:
        die("manifest missing: " + ", ".join(missing))
    reject_unsafe(value, "manifest")
    if not isinstance(value["baseline_sha"], str) or not SHA_RE.fullmatch(value["baseline_sha"]):
        die("baseline_sha must be a 7..64 character lowercase Git SHA")
    if value["metric_direction"] not in {"max", "min"}:
        die("metric_direction must be max or min")
    if not isinstance(value["allowed_files"], list) or not value["allowed_files"] or not all(
        isinstance(item, str) and item and not Path(item).is_absolute() and ".." not in Path(item).parts
        for item in value["allowed_files"]
    ):
        die("allowed_files must be non-empty relative paths")
    if not isinstance(value["non_regression"], list) or not value["non_regression"]:
        die("non_regression must be a non-empty list")
    if not isinstance(value["budget"], dict):
        die("budget must be an object")
    if not isinstance(value["candidates"], list) or not value["candidates"]:
        die("candidates must be non-empty")
    if len(value["candidates"]) > MAX_CANDIDATES:
        die(f"manifest has more than {MAX_CANDIDATES} candidates")
    return value


def validate_retirements(manifest: dict[str, Any]) -> tuple[bool, str, list[dict[str, Any]], dict[str, Any] | None]:
    retirements = manifest.get("retirements", [])
    exception = manifest.get("exception")
    if exception is not None:
        if not isinstance(exception, dict):
            die("exception must be an object")
        if exception.get("category") not in STANDING_CATEGORIES:
            die("exception category must be security, correctness, reliability, or compatibility")
        if not isinstance(exception.get("rationale"), str) or not exception["rationale"].strip():
            die("exception needs a rationale")
        evidence = exception.get("evidence")
        if not isinstance(evidence, list) or not evidence or not all(isinstance(item, str) and item.strip() for item in evidence):
            die("exception needs a non-empty evidence list")
        return True, f"narrow evidenced {exception['category']} exception", [], exception
    if not isinstance(retirements, list) or len(retirements) < 2:
        return False, "requires two evidence-backed retirements", [], None
    names: set[str] = set()
    for index, item in enumerate(retirements):
        if not isinstance(item, dict) or not isinstance(item.get("retired"), str) or not item["retired"].strip():
            die(f"retirements[{index}] needs a retired surface name")
        evidence = item.get("evidence")
        if not isinstance(evidence, list) or not evidence or not all(isinstance(ref, str) and ref.strip() for ref in evidence):
            die(f"retirements[{index}] needs a non-empty evidence list")
        if item["retired"] in names:
            die(f"duplicate retirement: {item['retired']}")
        names.add(item["retired"])
    return True, "two evidence-backed retirements", retirements, None


def validate_candidate(candidate: Any, index: int, allowed_files: set[str]) -> dict[str, Any]:
    if not isinstance(candidate, dict):
        die(f"candidates[{index}] must be an object")
    identifier = candidate.get("id")
    if not isinstance(identifier, str) or not ID_RE.fullmatch(identifier):
        die(f"candidates[{index}] id must be a lowercase slug")
    branch = candidate.get("branch")
    if not isinstance(branch, str) or not branch.strip():
        die(f"{identifier}: branch is required")
    metric = candidate.get("metric")
    if isinstance(metric, bool) or not isinstance(metric, (int, float)):
        die(f"{identifier}: metric must be numeric")
    holdout = candidate.get("holdout_pass")
    if not isinstance(holdout, bool):
        die(f"{identifier}: holdout_pass must be boolean")
    gates = candidate.get("gates")
    if not isinstance(gates, list) or not gates:
        die(f"{identifier}: gates must be a non-empty list")
    for gate in gates:
        if not isinstance(gate, dict) or not isinstance(gate.get("name"), str) or not isinstance(gate.get("passed"), bool):
            die(f"{identifier}: each gate needs name and boolean passed")
    changed = candidate.get("changed_files", [])
    if not isinstance(changed, list) or not all(isinstance(path, str) and path in allowed_files for path in changed):
        die(f"{identifier}: changed_files must be listed in allowed_files")
    evidence = candidate.get("evidence")
    if not isinstance(evidence, list) or not evidence or not all(isinstance(ref, str) and ref.strip() for ref in evidence):
        die(f"{identifier}: evidence must be a non-empty list")
    reject_unsafe(candidate, f"candidate {identifier}")
    hard_pass = holdout and all(gate["passed"] for gate in gates)
    return {
        "id": identifier,
        "branch": branch,
        "metric": metric,
        "holdout_pass": holdout,
        "gates": gates,
        "changed_files": changed,
        "evidence": evidence,
        "hard_gate_pass": hard_pass,
        "pr_eligible": False,
        "negative_result": not hard_pass,
        "reason": [] if hard_pass else ["hard non-regression gate failed"],
    }


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_execution_report(path: Path, report: dict[str, Any]) -> None:
    reject_unsafe(report, "execution report")
    atomic_write(path, json.dumps(report, indent=2, sort_keys=True) + "\n")


def git_command(
    root: Path,
    *argv: str,
    input_bytes: bytes | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    """Run Git control-plane operations directly.

    Candidate evaluator and non-regression processes do not use this helper; they must go through
    ``stage10_runner.run_manifest`` so timeout, environment, diagnostics, and cleanup have one
    implementation.
    """

    try:
        result = subprocess.run(
            ["git", "-C", str(root), *argv],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
            shell=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ExecutionError(f"git {' '.join(argv[:2])} could not complete: {exc}") from exc
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        detail = SECRET_RE.sub("<redacted>", detail).replace("\r", "\\r").replace("\n", "\\n")
        raise ExecutionError(f"git {' '.join(argv[:2])} failed: {detail or 'no diagnostic'}")
    return result


def git_text(root: Path, *argv: str) -> str:
    return git_command(root, *argv).stdout.decode("utf-8", errors="replace").strip()


def normalized_relative_path(raw: Any, label: str) -> str:
    if not isinstance(raw, str) or not raw or "\\" in raw:
        die(f"{label} must be a non-empty POSIX relative path")
    path = Path(raw)
    normalized = path.as_posix()
    if path.is_absolute() or normalized in {".", ""} or ".." in path.parts or normalized != raw:
        die(f"{label} must be a normalized relative path without '..'")
    return normalized


def finite_execution_seconds(raw: Any, label: str, maximum: float) -> float:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        die(f"{label} must be a finite number")
    value = float(raw)
    if not math.isfinite(value) or value < stage10_runner.MIN_TIMEOUT_SECONDS or value > maximum:
        die(
            f"{label} must be between {stage10_runner.MIN_TIMEOUT_SECONDS:g} "
            f"and {maximum:g}"
        )
    return value


def validate_local_execution_argv(argv: list[str], label: str) -> None:
    """Keep the local executor from becoming an implicit provider or publication client.

    This is an authority guard, not a network sandbox: callers still own the declared local
    executable. Rejecting common shell/network/hosting entry points and mutating Git operations
    makes the promised local-only boundary fail closed for the transitions Stage 10 itself must
    never initiate.
    """

    executable = Path(argv[0]).name.lower()
    if executable in LOCAL_SHELL_EXECUTABLES | LOCAL_EXTERNAL_EXECUTABLES:
        die(f"{label}: local execution forbids external-authority executable {executable!r}")
    if executable == "git":
        for item in argv[1:]:
            if item in LOCAL_MUTATING_GIT_OPERATIONS:
                die(f"{label}: local execution forbids mutating git operation {item!r}")


def execution_check(raw: Any, label: str, default_name: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        die(f"{label} must be an object with name, argv, and timeout_seconds")
    name = raw.get("name", default_name)
    if not isinstance(name, str) or not ID_RE.fullmatch(name):
        die(f"{label}.name must be a lowercase slug")
    try:
        argv = stage10_runner.validate_argv(raw.get("argv"))
    except stage10_runner.RunnerError as exc:
        die(f"{label}: {exc}")
    validate_local_execution_argv(argv, label)
    timeout_seconds = finite_execution_seconds(
        raw.get("timeout_seconds"), f"{label}.timeout_seconds", stage10_runner.MAX_TIMEOUT_SECONDS
    )
    return {"name": name, "argv": argv, "timeout_seconds": timeout_seconds}


def load_execution_manifest(
    root: Path, manifest_path: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        if manifest_path.stat().st_size > MAX_BYTES:
            die(f"manifest exceeds the {MAX_BYTES}-byte limit")
        raw = manifest_path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except OSError as exc:
        die(f"cannot read manifest: {exc}")
    except (UnicodeError, json.JSONDecodeError) as exc:
        die(f"manifest is not valid UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        die("execution manifest must be an object")
    required = {
        "id", "hypothesis", "baseline_sha", "candidate", "route", "environment",
        "allowed_files", "evaluator", "non_regression", "budget",
    }
    missing = sorted(required - set(value))
    if missing:
        die("execution manifest missing: " + ", ".join(missing))
    try:
        stage10_runner.reject_manifest_material(value)
    except stage10_runner.RunnerError as exc:
        die(str(exc))
    identifier = value["id"]
    if not isinstance(identifier, str) or not ID_RE.fullmatch(identifier):
        die("execution id must be a lowercase slug")
    if not isinstance(value["hypothesis"], str) or not value["hypothesis"].strip():
        die("hypothesis must be a non-empty string")
    baseline = value["baseline_sha"]
    if not isinstance(baseline, str) or not SHA_RE.fullmatch(baseline):
        die("baseline_sha must be a 7..64 character lowercase Git SHA")
    allowed_raw = value["allowed_files"]
    if not isinstance(allowed_raw, list) or not allowed_raw:
        die("allowed_files must be a non-empty list")
    allowed_files = [
        normalized_relative_path(item, f"allowed_files[{index}]")
        for index, item in enumerate(allowed_raw)
    ]
    if len(set(allowed_files)) != len(allowed_files):
        die("allowed_files contains a duplicate")
    candidate = value["candidate"]
    if not isinstance(candidate, dict):
        die("candidate must be an object containing exactly one of patch or ref")
    sources = [key for key in ("patch", "ref") if key in candidate]
    if len(sources) != 1:
        die("candidate must contain exactly one of patch or ref")
    if set(candidate) - {"patch", "ref"}:
        die("candidate supports only patch or ref")
    candidate_record: dict[str, Any]
    if sources[0] == "patch":
        patch_relative = normalized_relative_path(candidate["patch"], "candidate.patch")
        patch_path = (root / patch_relative).resolve()
        try:
            patch_path.relative_to(root)
        except ValueError:
            die("candidate.patch must remain under project root")
        if not patch_path.is_file():
            die(f"candidate.patch is not a file: {patch_path}")
        try:
            patch_bytes = patch_path.read_bytes()
        except OSError as exc:
            die(f"cannot read candidate.patch: {exc}")
        if len(patch_bytes) > MAX_PATCH_BYTES:
            die(f"candidate.patch exceeds the {MAX_PATCH_BYTES}-byte limit")
        candidate_record = {
            "type": "patch",
            "path": patch_relative,
            "sha256": hashlib.sha256(patch_bytes).hexdigest(),
            "_path": patch_path,
            "_bytes": patch_bytes,
        }
    else:
        ref = candidate["ref"]
        if not isinstance(ref, str) or not ref.strip() or ref.startswith("-"):
            die("candidate.ref must be a non-empty local Git ref")
        try:
            stage10_runner.reject_unsafe_string(ref, "candidate.ref")
        except stage10_runner.RunnerError as exc:
            die(str(exc))
        resolved = git_text(root, "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")
        candidate_record = {"type": "ref", "ref": ref, "sha": resolved}
    evaluator = execution_check(value["evaluator"], "evaluator", "evaluator")
    checks_raw = value["non_regression"]
    if not isinstance(checks_raw, list) or not checks_raw:
        die("non_regression must be a non-empty list of argv check objects")
    if len(checks_raw) > MAX_EXECUTION_CHECKS:
        die(f"non_regression has more than {MAX_EXECUTION_CHECKS} checks")
    non_regression = [
        execution_check(item, f"non_regression[{index}]", f"non-regression-{index + 1}")
        for index, item in enumerate(checks_raw)
    ]
    names = [evaluator["name"], *(check["name"] for check in non_regression)]
    if len(set(names)) != len(names):
        die("evaluator and non_regression check names must be unique")
    budget = value["budget"]
    if not isinstance(budget, dict):
        die("budget must be an object")
    budget_seconds = finite_execution_seconds(
        budget.get("seconds"), "budget.seconds", MAX_EXECUTION_BUDGET_SECONDS
    )
    frozen = {
        "id": identifier,
        "hypothesis": value["hypothesis"],
        "baseline_sha": baseline,
        "candidate": {key: item for key, item in candidate_record.items() if not key.startswith("_")},
        "route": value["route"],
        "environment": value["environment"],
        "allowed_files": allowed_files,
        "evaluator": evaluator,
        "non_regression": non_regression,
        "budget": {**budget, "seconds": budget_seconds},
    }
    reject_unsafe(frozen, "execution manifest")
    return frozen, candidate_record


def execution_output(root: Path, raw: str | None, execution_id: str, manifest_hash: str) -> Path:
    base = (root / ".wgm" / "stage10" / "experiments" / "executions").resolve()
    try:
        base.relative_to(root)
    except ValueError:
        die(f"execution output base must remain under project root: {base}")
    path = Path(raw).expanduser() if raw else base / f"{execution_id}-{manifest_hash[:12]}.json"
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    try:
        path.relative_to(base)
    except ValueError:
        die(f"execution output must remain under {base}")
    if path == base or path.suffix != ".json":
        die("execution output must name a JSON file")
    return path


def source_snapshot(root: Path) -> dict[str, Any]:
    top = Path(git_text(root, "rev-parse", "--show-toplevel")).resolve()
    head = git_text(root, "rev-parse", "HEAD")
    branch = git_text(root, "branch", "--show-current")
    dirty = git_text(
        root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        ".",
        ":(exclude).wgm",
        ":(exclude).wgm/**",
    )
    remotes = git_text(root, "remote", "-v")
    return {
        "root": str(top),
        "head": head,
        "branch": branch,
        "dirty_outside_wgm": dirty,
        "remote_names": sorted(filter(None, git_text(root, "remote").splitlines())),
        "remotes_sha256": hashlib.sha256(remotes.encode("utf-8")).hexdigest(),
        "_remotes": remotes,
    }


def public_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in snapshot.items() if not key.startswith("_")}


def source_is_unchanged(before: dict[str, Any], after: dict[str, Any]) -> bool:
    return all(
        before[key] == after[key]
        for key in ("root", "head", "branch", "dirty_outside_wgm", "_remotes")
    )


def branch_exists(root: Path, branch: str) -> bool:
    return (
        git_command(root, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}", check=False).returncode
        == 0
    )


def worktree_registered(root: Path, worktree: Path) -> bool:
    records = git_text(root, "worktree", "list", "--porcelain").splitlines()
    return f"worktree {worktree}" in records


def changed_files(worktree: Path, baseline: str, generated_runner_files: set[str]) -> list[str]:
    tracked_raw = git_command(
        worktree, "diff", "--name-only", "--no-renames", "-z", baseline, "--"
    ).stdout
    untracked_raw = git_command(
        worktree, "ls-files", "--others", "--exclude-standard", "-z"
    ).stdout
    # Evaluator output lives under the ignored .wgm tree. Include ignored untracked files as well;
    # otherwise a check can smuggle a neighboring file into generated evidence and the scope gate
    # will never see it. The exact runner manifest/result files remain the only exemptions.
    ignored_raw = git_command(
        worktree, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"
    ).stdout
    names = {
        item.decode("utf-8", errors="surrogateescape")
        for item in tracked_raw.split(b"\0") + untracked_raw.split(b"\0") + ignored_raw.split(b"\0")
        if item
    }
    return sorted(path for path in names if path not in generated_runner_files)


def apply_candidate(
    source_root: Path, worktree: Path, baseline: str, candidate: dict[str, Any]
) -> None:
    if candidate["type"] == "patch":
        git_command(
            worktree,
            "apply",
            "--index",
            "--whitespace=nowarn",
            "-",
            input_bytes=candidate["_bytes"],
        )
        return
    patch = git_command(
        source_root, "diff", "--binary", "--no-ext-diff", baseline, candidate["sha"], "--"
    ).stdout
    if len(patch) > MAX_PATCH_BYTES:
        raise ExecutionError(f"candidate ref diff exceeds the {MAX_PATCH_BYTES}-byte limit")
    git_command(worktree, "apply", "--index", "--whitespace=nowarn", "-", input_bytes=patch)


def run_execution_check(
    worktree: Path,
    check: dict[str, Any],
    effective_timeout: float,
    checks_directory: Path,
) -> dict[str, Any]:
    runner_manifest = checks_directory / f"{check['name']}.manifest.json"
    runner_result = checks_directory / f"{check['name']}.result.json"
    stage10_runner.atomic_write(
        runner_manifest,
        {
            "argv": check["argv"],
            "cwd": ".",
            "timeout_seconds": effective_timeout,
            "evidence": "fixture",
            "environment": "stage10-isolated-experiment",
            "diagnostic_limit": stage10_runner.DEFAULT_DIAGNOSTIC_LIMIT,
        },
    )
    args = argparse.Namespace(
        root=str(worktree),
        manifest=str(runner_manifest),
        output=str(runner_result),
        allow_live=False,
    )
    try:
        return_code = stage10_runner.run_manifest(args)
    except SystemExit as exc:
        raise ExecutionError(
            f"{check['name']}: bounded runner rejected generated manifest (exit {exc.code})"
        ) from exc
    try:
        result = json.loads(runner_result.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ExecutionError(f"{check['name']}: cannot read bounded runner result: {exc}") from exc
    if result.get("schema") != stage10_runner.SCHEMA:
        raise ExecutionError(f"{check['name']}: bounded runner result has the wrong schema")
    return {
        "name": check["name"],
        "declared_argv": check["argv"],
        "declared_timeout_seconds": check["timeout_seconds"],
        "effective_timeout_seconds": effective_timeout,
        "runner_manifest": runner_manifest.relative_to(worktree).as_posix(),
        "runner_result": runner_result.relative_to(worktree).as_posix(),
        "runner_manifest_record": json.loads(runner_manifest.read_text(encoding="utf-8")),
        "runner_result_record": result,
        "runner_contract": stage10_runner.SCHEMA,
        "status": result.get("status"),
        "return_code": return_code,
    }


def cleanup_execution(root: Path, worktree: Path, branch: str) -> dict[str, Any]:
    actions: list[str] = []
    errors: list[str] = []
    if worktree_registered(root, worktree) or os.path.lexists(worktree):
        result = git_command(root, "worktree", "remove", "--force", str(worktree), check=False)
        if result.returncode == 0:
            actions.append("removed failed worktree")
        else:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            errors.append(f"worktree removal failed: {detail or 'no diagnostic'}")
    git_command(root, "worktree", "prune", check=False)
    if branch_exists(root, branch):
        result = git_command(root, "branch", "-D", "--", branch, check=False)
        if result.returncode == 0:
            actions.append("removed failed branch")
        else:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            errors.append(f"branch removal failed: {detail or 'no diagnostic'}")
    remaining_worktree = worktree_registered(root, worktree) or os.path.lexists(worktree)
    remaining_branch = branch_exists(root, branch)
    return {
        "state": "removed" if not remaining_worktree and not remaining_branch and not errors else "incomplete",
        "actions": actions,
        "errors": [SECRET_RE.sub("<redacted>", item) for item in errors],
        "worktree_present": remaining_worktree,
        "branch_present": remaining_branch,
    }


def execute(args: argparse.Namespace) -> int:
    root = root_path(args.root)
    actual_root = Path(git_text(root, "rev-parse", "--show-toplevel")).resolve()
    if actual_root != root:
        die(f"--root must be the actual Git root: expected {actual_root}, got {root}")
    manifest_path = under_root(root, args.manifest)
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    frozen, candidate = load_execution_manifest(root, manifest_path)
    suffix = f"{frozen['id']}-{manifest_hash[:12]}"
    branch = f"stage10/experiment/{suffix}"
    worktree_base = (root / ".wgm" / "stage10" / "worktrees").resolve()
    try:
        worktree_base.relative_to(root)
    except ValueError:
        die(f"worktree base must remain under project root: {worktree_base}")
    worktree = (worktree_base / suffix).resolve()
    try:
        worktree.relative_to(worktree_base)
    except ValueError:
        die(f"worktree must remain under {worktree_base}")
    output = execution_output(root, args.output, frozen["id"], manifest_hash)
    if os.path.lexists(output):
        die(f"execution output already exists: {output}")
    if output == manifest_path or (candidate.get("_path") and output == candidate["_path"]):
        die("execution output must not overwrite an input")

    before = source_snapshot(root)
    identity = {
        "source_root": str(root),
        "source_branch": before["branch"],
        "source_head": before["head"],
        "branch": branch,
        "worktree": str(worktree),
    }
    report: dict[str, Any] = {
        "schema": "stage10.execution.v1",
        "recorded_at": stamp(),
        "manifest": str(manifest_path),
        "manifest_sha256": manifest_hash,
        "frozen_manifest": frozen,
        "baseline_sha": frozen["baseline_sha"],
        "route": frozen["route"],
        "environment": frozen["environment"],
        "allowed_files": frozen["allowed_files"],
        "identity": identity,
        "source_checkout": {"before": public_snapshot(before), "after": None, "unchanged": None},
        "checks": [],
        "changed_files": [],
        "diagnostics": [],
        "budget": {
            "seconds": frozen["budget"]["seconds"],
            "consumed_ms": 0,
            "remaining_ms": round(frozen["budget"]["seconds"] * 1000),
        },
        "status": "preflight",
        "result": "negative",
        "pr_eligible": False,
        "cleanup": {
            "state": "not-started",
            "actions": [],
            "errors": [],
            "worktree_present": False,
            "branch_present": False,
        },
        "authority": (
            "local experiment evidence only; compare remains the authority for hard "
            "non-regression, holdout, feature economy, and any PR recommendation"
        ),
    }

    preflight_errors: list[str] = []
    if not before["branch"]:
        preflight_errors.append("source checkout must be on a branch")
    if before["head"] != frozen["baseline_sha"]:
        preflight_errors.append(
            f"stale baseline: manifest {frozen['baseline_sha']} != source HEAD {before['head']}"
        )
    if before["dirty_outside_wgm"]:
        preflight_errors.append("source checkout is dirty outside .wgm")
    if branch_exists(root, branch):
        preflight_errors.append(f"branch collision: {branch}")
    if os.path.lexists(worktree) or worktree_registered(root, worktree):
        preflight_errors.append(f"worktree path collision: {worktree}")
    if preflight_errors:
        report["status"] = "refused"
        report["diagnostics"] = preflight_errors
        report["cleanup"]["state"] = "not-required"
        after = source_snapshot(root)
        report["source_checkout"]["after"] = public_snapshot(after)
        report["source_checkout"]["unchanged"] = source_is_unchanged(before, after)
        write_execution_report(output, report)
        print(f"stage10 experiments: execution refused; wrote {output}")
        return 1

    # This prepared report freezes every executable input and identity before Git mutation.
    report["status"] = "prepared"
    write_execution_report(output, report)
    started = time.monotonic()
    setup_started = False
    success = False
    failure_status = "failed"
    runner_prefix = f".wgm/stage10/experiments/executions/{suffix}/checks/"
    checks_directory = worktree / runner_prefix
    execution_checks = [frozen["evaluator"], *frozen["non_regression"]]
    generated_runner_files = {
        f"{runner_prefix}{check['name']}.{kind}.json"
        for check in execution_checks
        for kind in ("manifest", "result")
    }
    try:
        setup_started = True
        git_command(root, "worktree", "add", "--quiet", "-b", branch, str(worktree), frozen["baseline_sha"])
        actual_worktree_root = Path(git_text(worktree, "rev-parse", "--show-toplevel")).resolve()
        actual_branch = git_text(worktree, "branch", "--show-current")
        actual_head = git_text(worktree, "rev-parse", "HEAD")
        if actual_worktree_root != worktree or actual_branch != branch or actual_head != frozen["baseline_sha"]:
            raise ExecutionError(
                "worktree identity mismatch: "
                f"expected {worktree} on {branch} at {frozen['baseline_sha']}, "
                f"got {actual_worktree_root} on {actual_branch} at {actual_head}"
            )
        report["identity"].update(
            {
                "verified_root": str(actual_worktree_root),
                "verified_branch": actual_branch,
                "verified_head": actual_head,
            }
        )
        apply_candidate(root, worktree, frozen["baseline_sha"], candidate)
        files = changed_files(worktree, frozen["baseline_sha"], generated_runner_files)
        report["changed_files"] = files
        outside = sorted(set(files) - set(frozen["allowed_files"]))
        if not files:
            raise ExecutionError("candidate produced no changed files")
        if outside:
            failure_status = "out-of-scope"
            raise ExecutionError("candidate changed files outside allowed_files: " + ", ".join(outside))

        for check in execution_checks:
            elapsed = time.monotonic() - started
            remaining = frozen["budget"]["seconds"] - elapsed
            if remaining < stage10_runner.MIN_TIMEOUT_SECONDS:
                failure_status = "timeout"
                raise ExecutionError("total execution budget exhausted before " + check["name"])
            effective_timeout = min(check["timeout_seconds"], remaining)
            check_result = run_execution_check(worktree, check, effective_timeout, checks_directory)
            report["checks"].append(check_result)
            elapsed = time.monotonic() - started
            report["budget"]["consumed_ms"] = round(elapsed * 1000)
            report["budget"]["remaining_ms"] = max(
                0, round(frozen["budget"]["seconds"] * 1000) - report["budget"]["consumed_ms"]
            )
            files = changed_files(worktree, frozen["baseline_sha"], generated_runner_files)
            report["changed_files"] = files
            outside = sorted(set(files) - set(frozen["allowed_files"]))
            if outside:
                failure_status = "out-of-scope"
                raise ExecutionError("check changed files outside allowed_files: " + ", ".join(outside))
            if check_result["status"] != "passed":
                failure_status = "timeout" if check_result["status"] == "timeout" else "failed"
                raise ExecutionError(
                    f"{check['name']} {check_result['status']}: "
                    f"{check_result['runner_result_record'].get('diagnostic', 'no diagnostic')}"
                )

        after = source_snapshot(root)
        if not source_is_unchanged(before, after):
            raise ExecutionError("source checkout HEAD, branch, status, or configured remotes changed")
        report["source_checkout"]["after"] = public_snapshot(after)
        report["source_checkout"]["unchanged"] = True
        report["status"] = "passed"
        report["result"] = "execution-passed"
        report["cleanup"] = {
            "state": "retained-for-human-review",
            "actions": ["retained local worktree and branch"],
            "errors": [],
            "worktree_present": True,
            "branch_present": True,
        }
        success = True
    except (ExecutionError, KeyboardInterrupt) as exc:
        report["status"] = "interrupted" if isinstance(exc, KeyboardInterrupt) else failure_status
        report["diagnostics"].append(
            "execution interrupted" if isinstance(exc, KeyboardInterrupt) else str(exc)
        )
    finally:
        report["budget"]["consumed_ms"] = round((time.monotonic() - started) * 1000)
        report["budget"]["remaining_ms"] = max(
            0, round(frozen["budget"]["seconds"] * 1000) - report["budget"]["consumed_ms"]
        )
        if not success and setup_started:
            report["cleanup"] = cleanup_execution(root, worktree, branch)
        if report["source_checkout"]["after"] is None:
            try:
                after = source_snapshot(root)
                report["source_checkout"]["after"] = public_snapshot(after)
                report["source_checkout"]["unchanged"] = source_is_unchanged(before, after)
            except ExecutionError as exc:
                report["diagnostics"].append(f"source revalidation failed: {exc}")
                report["source_checkout"]["unchanged"] = False
        report["recorded_at"] = stamp()
        write_execution_report(output, report)

    if success:
        print(f"stage10 experiments: execution passed; retained {branch} at {worktree}; wrote {output}")
        return 0
    print(f"stage10 experiments: execution {report['status']}; wrote {output}")
    return 1


def render_card(result: dict[str, Any]) -> str:
    lines = [
        "<!-- GENERATED by `stage10_experiments.py`; edit the manifest, then rerun compare. -->",
        "# Stage 10 experiment comparison",
        "",
        f"- Hypothesis: {result['experiment']['hypothesis']}",
        f"- Baseline: `{result['baseline_sha']}` (frozen)",
        f"- Route: `{result['experiment']['route']}` · evaluator: `{result['experiment']['evaluator']}`",
        f"- Target metric: `{result['experiment']['target_metric']}` ({result['experiment']['metric_direction']})",
        f"- Winner: **{result['winner'] or 'none'}**",
        f"- PR recommendation: **{'yes' if result['pr_recommendation'] else 'no'}**",
        f"- Feature economy: {result['feature_economy']['reason']}",
        "",
        "## Results",
    ]
    for candidate in result["candidates"]:
        lines.append(
            f"- `{candidate['id']}` — metric `{candidate['metric']}`, "
            f"hard gate `{'pass' if candidate['hard_gate_pass'] else 'FAIL'}`, "
            f"negative result `{'yes' if candidate['negative_result'] else 'no'}`"
        )
        if candidate["reason"]:
            lines.append(f"  - Reason: {'; '.join(candidate['reason'])}")
    lines.extend(
        [
            "",
            "## Authority boundary",
            "- This report is a comparison, not a merge or deployment.",
            "- Human review is required before any PR recommendation becomes project policy.",
            "",
        ]
    )
    return "\n".join(lines)


def compare(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    manifest_path = under_root(root, args.manifest)
    manifest = load_manifest(manifest_path)
    economy_ok, economy_reason, retirements, exception = validate_retirements(manifest)
    allowed_files = set(manifest["allowed_files"])
    candidates = []
    seen: set[str] = set()
    for index, candidate in enumerate(manifest["candidates"]):
        value = validate_candidate(candidate, index, allowed_files)
        if value["id"] in seen:
            die(f"duplicate candidate id: {value['id']}")
        seen.add(value["id"])
        candidates.append(value)
    passing = [candidate for candidate in candidates if candidate["hard_gate_pass"]]
    if manifest["metric_direction"] == "max":
        best = max(passing, key=lambda candidate: (candidate["metric"], candidate["id"]), default=None)
    else:
        best = min(passing, key=lambda candidate: (candidate["metric"], candidate["id"]), default=None)
    all_hard_pass = len(passing) == len(candidates)
    if best and economy_ok and all_hard_pass:
        for candidate in candidates:
            candidate["pr_eligible"] = candidate["id"] == best["id"]
    for candidate in candidates:
        if not candidate["pr_eligible"] and candidate["hard_gate_pass"] and best and candidate["id"] != best["id"]:
            candidate["reason"].append("not the winning candidate under the declared metric direction")
        if not economy_ok and candidate["hard_gate_pass"]:
            candidate["reason"].append(economy_reason)
        if best and not all_hard_pass and candidate["hard_gate_pass"]:
            candidate["reason"].append("another candidate failed a hard gate; comparison batch is not PR-eligible")
    output = under_wgm(root, args.output)
    report = {
        "schema": "stage10.experiment.v1",
        "recorded_at": stamp(),
        "manifest": str(manifest_path),
        "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "baseline_sha": manifest["baseline_sha"],
        "frozen_baseline": True,
        "experiment": {
            key: manifest[key]
            for key in (
                "hypothesis", "route", "environment", "allowed_files", "evaluator",
                "target_metric", "metric_direction", "non_regression", "budget",
            )
        },
        "candidates": candidates,
        "feature_economy": {"eligible": economy_ok, "reason": economy_reason, "retirements": retirements, "exception": exception},
        "winner": best["id"] if best else None,
        "pr_recommendation": bool(best and economy_ok and all_hard_pass),
        "authority": "human review required; no automatic branch creation, no merge, no push, no deploy, no publish",
    }
    reject_unsafe(report, "comparison report")
    atomic_write(output, json.dumps(report, indent=2, sort_keys=True) + "\n")
    card = output.with_suffix(".md")
    atomic_write(card, render_card(report) + "\n")
    print(f"stage10 experiments: wrote {output} and {card}")
    if not all_hard_pass or not economy_ok:
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["compare", "execute"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.command == "compare":
        compare(args)
    else:
        raise SystemExit(execute(args))


if __name__ == "__main__":
    main()
