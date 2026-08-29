#!/usr/bin/env python3
"""Prepare a bounded local PR handoff from Stage 10 execution and comparison reports."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, NoReturn

sys.dont_write_bytecode = True
import stage10_experiments

MAX_INPUT_BYTES = 1_000_000
MAX_BUNDLE_BYTES = 200_000
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BRANCH_RE = re.compile(r"^(?!-)[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$")
APPROVAL_SCHEMA = "stage10.pr-approval.v1"
BUNDLE_SCHEMA = "stage10.pr-bundle.v1"
REMAINING_HUMAN_ACTION = (
    "Review the local candidate diff, commit it if accepted, then explicitly push and create "
    "the PR using the project's hosting workflow; this tool performed none of those actions."
)


def die(message: str, code: int = 2) -> NoReturn:
    import sys

    print(f"stage10 pr: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def root_path(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        die(f"root is not a directory: {root}")
    actual = Path(git_text(root, "rev-parse", "--show-toplevel")).resolve()
    if actual != root:
        die(f"--root must be the actual Git root: expected {actual}, got {root}")
    return root


def confined_file(root: Path, raw: str, label: str) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    try:
        path.relative_to(root)
    except ValueError:
        die(f"{label} must remain under project root: {path}")
    if not path.is_file():
        die(f"{label} is not a file: {path}")
    return path


def bundle_output(root: Path, raw: str | None, identifier: str, binding: str) -> tuple[Path, Path]:
    logical_base = root / ".wgm" / "stage10" / "pr"
    base = logical_base.resolve()
    if base != logical_base:
        die("output boundary must not traverse symlinks")
    try:
        base.relative_to(root)
    except ValueError:
        die(f"output base must remain under project root: {base}")
    output = Path(raw).expanduser() if raw else base / f"{identifier}-{binding[:12]}.json"
    if not output.is_absolute():
        output = root / output
    output = output.resolve()
    try:
        output.relative_to(base)
    except ValueError:
        die(f"output must remain under {base}")
    if output == base or output.suffix != ".json":
        die("output must name a JSON file")
    return output, output.with_suffix(".md")


def load_json(path: Path, label: str) -> tuple[dict[str, Any], str]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        die(f"cannot read {label}: {exc}")
    if len(raw) > MAX_INPUT_BYTES:
        die(f"{label} exceeds the {MAX_INPUT_BYTES}-byte limit")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        die(f"{label} is not valid UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        die(f"{label} must be an object")
    try:
        stage10_experiments.reject_unsafe(value, label)
    except SystemExit:
        die(f"{label} contains unsafe material")
    return value, hashlib.sha256(raw).hexdigest()


def required_object(value: dict[str, Any], key: str, label: str) -> dict[str, Any]:
    child = value.get(key)
    if not isinstance(child, dict):
        die(f"{label}.{key} must be an object")
    return child


def required_string(value: dict[str, Any], key: str, label: str) -> str:
    child = value.get(key)
    if not isinstance(child, str) or not child.strip():
        die(f"{label}.{key} must be a non-empty string")
    return child


def string_list(value: Any, label: str, *, non_empty: bool = True) -> list[str]:
    if not isinstance(value, list) or (non_empty and not value):
        die(f"{label} must be {'a non-empty' if non_empty else 'a'} list")
    if not all(
        isinstance(item, str)
        and item
        and not Path(item).is_absolute()
        and ".." not in Path(item).parts
        for item in value
    ):
        die(f"{label} must contain confined relative paths")
    if len(set(value)) != len(value):
        die(f"{label} contains duplicates")
    return value


def report_manifest(root: Path, report: dict[str, Any], label: str) -> tuple[Path, str]:
    manifest = confined_file(root, required_string(report, "manifest", label), f"{label} manifest")
    if manifest.stat().st_size > MAX_INPUT_BYTES:
        die(f"{label} source manifest exceeds the {MAX_INPUT_BYTES}-byte limit")
    expected = required_string(report, "manifest_sha256", label)
    if not SHA256_RE.fullmatch(expected):
        die(f"{label}.manifest_sha256 must be a SHA-256 digest")
    actual = hashlib.sha256(manifest.read_bytes()).hexdigest()
    if actual != expected:
        die(f"{label} is stale: source manifest hash changed", 1)
    return manifest, actual


def git(root: Path, *argv: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *argv],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        die(f"git {' '.join(argv)} failed: {exc}")
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        die(f"git {' '.join(argv)} failed: {detail or 'no diagnostic'}")
    return result


def git_text(root: Path, *argv: str) -> str:
    return git(root, *argv).stdout.decode("utf-8", errors="strict").strip()


def valid_branch(raw: Any, label: str) -> str:
    if not isinstance(raw, str) or not BRANCH_RE.fullmatch(raw) or ".." in raw or raw.endswith(("/", ".")):
        die(f"{label} is not a safe local branch name")
    return raw


def local_branch_sha(root: Path, branch: str, label: str) -> str:
    result = git(root, "show-ref", "--verify", "--hash", f"refs/heads/{branch}", check=False)
    if result.returncode != 0:
        die(f"{label} local branch is missing: {branch}", 1)
    return result.stdout.decode("ascii").strip()


def validate_execution(
    root: Path, report: dict[str, Any]
) -> tuple[dict[str, Any], list[str], str, str, str, Path, list[dict[str, Any]]]:
    if report.get("schema") != "stage10.execution.v1":
        die("execution report has the wrong schema", 1)
    manifest_path, _manifest_hash = report_manifest(root, report, "execution report")
    if report.get("status") != "passed" or report.get("result") != "execution-passed":
        die("execution report is not passed", 1)
    if report.get("pr_eligible") is not False:
        die("execution report bypassed the comparison authority boundary", 1)
    source = required_object(report, "source_checkout", "execution report")
    if source.get("unchanged") is not True:
        die("execution report did not preserve the source checkout", 1)
    cleanup = required_object(report, "cleanup", "execution report")
    if (
        cleanup.get("state") != "retained-for-human-review"
        or cleanup.get("worktree_present") is not True
        or cleanup.get("branch_present") is not True
    ):
        die("execution report has no retained local review identity", 1)
    frozen = required_object(report, "frozen_manifest", "execution report")
    expected_frozen, _candidate = stage10_experiments.load_execution_manifest(root, manifest_path)
    if frozen != expected_frozen:
        die("execution report does not match its source manifest", 1)
    identifier = required_string(frozen, "id", "execution report.frozen_manifest")
    baseline = required_string(report, "baseline_sha", "execution report")
    if not re.fullmatch(r"[0-9a-f]{7,64}", baseline):
        die("execution report baseline_sha is invalid")
    if frozen.get("baseline_sha") != baseline:
        die("execution report baseline does not match its frozen manifest", 1)
    allowed = string_list(report.get("allowed_files"), "execution report.allowed_files")
    if frozen.get("allowed_files") != allowed:
        die("execution report allowed scope does not match its frozen manifest", 1)
    changed = string_list(report.get("changed_files"), "execution report.changed_files")
    if not set(changed).issubset(allowed):
        die("execution report changed files escape allowed_files", 1)
    identity = required_object(report, "identity", "execution report")
    head = valid_branch(identity.get("branch"), "execution report head branch")
    base = valid_branch(identity.get("source_branch"), "execution report base branch")
    if identity.get("source_root") != str(root):
        die("execution report belongs to a different source checkout", 1)
    worktree = Path(required_string(identity, "worktree", "execution report.identity")).resolve()
    expected_base = (root / ".wgm" / "stage10" / "worktrees").resolve()
    try:
        worktree.relative_to(expected_base)
    except ValueError:
        die("execution report worktree escaped the Stage 10 boundary", 1)
    if identity.get("verified_root") != str(worktree) or identity.get("verified_branch") != head:
        die("execution report has an unverified worktree identity", 1)
    if identity.get("verified_head") != baseline:
        die("execution report verified a different baseline", 1)
    if not worktree.is_dir():
        die("execution report worktree is stale or missing", 1)
    if git_text(worktree, "rev-parse", "--show-toplevel") != str(worktree):
        die("retained worktree root changed", 1)
    if git_text(worktree, "branch", "--show-current") != head:
        die("retained worktree branch changed", 1)
    if git_text(worktree, "rev-parse", "HEAD") != baseline:
        die("retained worktree baseline changed", 1)
    if local_branch_sha(root, head, "head") != baseline:
        die("retained head branch moved after execution", 1)
    if local_branch_sha(root, base, "base") != baseline:
        die("base branch moved after execution", 1)
    if git_text(root, "branch", "--show-current") != base or git_text(root, "rev-parse", "HEAD") != baseline:
        die("source checkout no longer matches the approved base", 1)
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
    if dirty:
        die("source checkout is dirty outside .wgm", 1)
    current_remotes_hash = hashlib.sha256(git_text(root, "remote", "-v").encode()).hexdigest()
    source_after = required_object(source, "after", "execution report.source_checkout")
    if source_after.get("remotes_sha256") != current_remotes_hash:
        die("source remotes changed after execution", 1)
    checks = report.get("checks")
    expected_checks = [frozen["evaluator"], *frozen["non_regression"]]
    if not isinstance(checks, list) or len(checks) != len(expected_checks):
        die("execution report check set does not match its frozen manifest", 1)
    suffix = f"{identifier}-{report['manifest_sha256'][:12]}"
    generated: set[str] = set()
    validated_checks: list[dict[str, Any]] = []
    for index, (check, expected_check) in enumerate(zip(checks, expected_checks, strict=True)):
        if not isinstance(check, dict):
            die(f"execution report check {index} must be an object")
        expected_prefix = f".wgm/stage10/experiments/executions/{suffix}/checks/{expected_check['name']}"
        expected_manifest_path = f"{expected_prefix}.manifest.json"
        expected_result_path = f"{expected_prefix}.result.json"
        if (
            check.get("name") != expected_check["name"]
            or check.get("declared_argv") != expected_check["argv"]
            or check.get("declared_timeout_seconds") != expected_check["timeout_seconds"]
            or check.get("runner_manifest") != expected_manifest_path
            or check.get("runner_result") != expected_result_path
            or check.get("status") != "passed"
            or check.get("return_code") != 0
            or check.get("runner_contract") != "stage10.runner.v1"
            or required_object(check, "runner_result_record", f"execution report check {index}").get("status")
            != "passed"
        ):
            die(f"execution report check {index} does not match exact passing evidence", 1)
        effective_timeout = check.get("effective_timeout_seconds")
        if (
            isinstance(effective_timeout, bool)
            or not isinstance(effective_timeout, (int, float))
            or effective_timeout <= 0
            or effective_timeout > expected_check["timeout_seconds"]
        ):
            die(f"execution report check {index} has an invalid effective timeout", 1)
        manifest_path = (worktree / expected_manifest_path).resolve()
        result_path = (worktree / expected_result_path).resolve()
        try:
            manifest_path.relative_to(worktree)
            result_path.relative_to(worktree)
        except ValueError:
            die(f"execution report check {index} evidence escaped the worktree", 1)
        runner_manifest, runner_manifest_hash = load_json(
            manifest_path, f"execution report check {index} runner manifest"
        )
        runner_result, runner_result_hash = load_json(
            result_path, f"execution report check {index} runner result"
        )
        if check.get("runner_manifest_record") != runner_manifest:
            die(f"execution report check {index} manifest record was tampered", 1)
        if check.get("runner_result_record") != runner_result:
            die(f"execution report check {index} result record was tampered", 1)
        if (
            runner_manifest.get("argv") != expected_check["argv"]
            or runner_manifest.get("cwd") != "."
            or runner_manifest.get("timeout_seconds") != effective_timeout
            or runner_manifest.get("evidence") != "fixture"
            or runner_manifest.get("environment") != "stage10-isolated-experiment"
        ):
            die(f"execution report check {index} runner manifest does not match execution", 1)
        if (
            runner_result.get("schema") != "stage10.runner.v1"
            or runner_result.get("manifest_sha256") != runner_manifest_hash
            or runner_result.get("argv") != expected_check["argv"]
            or runner_result.get("shell") is not False
            or runner_result.get("status") != "passed"
            or runner_result.get("exit_code") != 0
        ):
            die(f"execution report check {index} runner result is not exact passing evidence", 1)
        generated.update((expected_manifest_path, expected_result_path))
        validated_checks.append(
            {
                "name": expected_check["name"],
                "argv": expected_check["argv"],
                "status": "passed",
                "runner_manifest": expected_manifest_path,
                "runner_manifest_sha256": runner_manifest_hash,
                "runner_result": expected_result_path,
                "runner_result_sha256": runner_result_hash,
            }
        )
    actual_changed = stage10_experiments.changed_files(worktree, baseline, generated)
    if actual_changed != changed:
        die("execution report is stale: retained candidate file set changed", 1)
    snapshot = required_string(report, "candidate_snapshot_sha256", "execution report")
    if not SHA256_RE.fullmatch(snapshot):
        die("execution report candidate snapshot digest is invalid")
    if stage10_experiments.candidate_snapshot_sha256(worktree, actual_changed) != snapshot:
        die("execution report is stale: retained candidate content changed", 1)
    return frozen, changed, snapshot, head, base, worktree, validated_checks


def validate_economy(economy: dict[str, Any]) -> None:
    if economy.get("eligible") is not True:
        die("comparison report is under-retired or lacks an evidenced exception", 1)
    retirements = economy.get("retirements")
    exception = economy.get("exception")
    if exception is None:
        if not isinstance(retirements, list) or len(retirements) < 2:
            die("comparison report is under-retired", 1)
        names: set[str] = set()
        for index, item in enumerate(retirements):
            if not isinstance(item, dict) or not isinstance(item.get("retired"), str):
                die(f"comparison retirement {index} is malformed", 1)
            evidence = item.get("evidence")
            if not isinstance(evidence, list) or not evidence or not all(
                isinstance(ref, str) and ref for ref in evidence
            ):
                die(f"comparison retirement {index} lacks evidence", 1)
            names.add(item["retired"])
        if len(names) != len(retirements):
            die("comparison report has duplicate retirements", 1)
    else:
        if retirements not in ([], None) or not isinstance(exception, dict):
            die("comparison economy exception conflicts with retirements", 1)
        if exception.get("category") not in stage10_experiments.STANDING_CATEGORIES:
            die("comparison economy exception category is invalid", 1)
        evidence = exception.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            die("comparison economy exception lacks evidence", 1)


def validate_comparison(
    root: Path,
    report: dict[str, Any],
    frozen: dict[str, Any],
    execution_changed: list[str],
    head: str,
) -> dict[str, Any]:
    if report.get("schema") != "stage10.experiment.v1":
        die("comparison report has the wrong schema", 1)
    manifest_path, _manifest_hash = report_manifest(root, report, "comparison report")
    if report.get("frozen_baseline") is not True or report.get("baseline_sha") != frozen["baseline_sha"]:
        die("comparison baseline does not match execution", 1)
    experiment = required_object(report, "experiment", "comparison report")
    allowed = string_list(experiment.get("allowed_files"), "comparison report allowed_files")
    if allowed != frozen["allowed_files"]:
        die("comparison allowed scope does not match execution", 1)
    if experiment.get("route") != frozen.get("route") or experiment.get("environment") != frozen.get("environment"):
        die("comparison route or environment does not match execution", 1)
    if report.get("pr_recommendation") is not True:
        die("comparison report does not recommend a PR", 1)
    validate_economy(required_object(report, "feature_economy", "comparison report"))
    candidates = report.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        die("comparison report has no candidates")
    winner_id = report.get("winner")
    matches = []
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            die(f"comparison candidate {index} must be an object")
        gates = candidate.get("gates")
        if not isinstance(gates, list) or not gates or not all(
            isinstance(gate, dict)
            and isinstance(gate.get("name"), str)
            and gate.get("passed") is True
            for gate in gates
        ):
            die(f"comparison candidate {index} lacks passing hard gates", 1)
        if (
            candidate.get("holdout_pass") is not True
            or candidate.get("hard_gate_pass") is not True
            or candidate.get("negative_result") is not False
        ):
            die(f"comparison candidate {index} did not pass holdout and hard gates", 1)
        candidate_changed = string_list(
            candidate.get("changed_files"), f"comparison candidate {index} changed_files"
        )
        if not set(candidate_changed).issubset(allowed):
            die(f"comparison candidate {index} escaped allowed scope", 1)
        if candidate.get("id") == winner_id:
            matches.append(candidate)
    if len(matches) != 1:
        die("comparison report must identify exactly one winner", 1)
    winner = matches[0]
    if winner.get("id") != frozen["id"] or winner.get("branch") != head:
        die("comparison winner does not match the executed candidate", 1)
    if winner.get("pr_eligible") is not True:
        die("comparison winner is not PR-eligible", 1)
    if winner.get("changed_files") != execution_changed:
        die("comparison winner file set does not match execution", 1)
    source_manifest = stage10_experiments.load_manifest(manifest_path)
    expected = stage10_experiments.build_comparison_report(
        manifest_path, source_manifest, report.get("recorded_at")
    )
    if report != expected:
        die("comparison report does not match its source manifest", 1)
    return winner


def parse_expiry(raw: Any) -> dt.datetime:
    if not isinstance(raw, str) or not raw.endswith("Z"):
        die("approval expires_at must be a UTC timestamp")
    try:
        value = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        die("approval expires_at must be an ISO-8601 timestamp")
    if value.utcoffset() != dt.timedelta(0):
        die("approval expires_at must use UTC")
    return value


def validate_approval(
    approval: dict[str, Any],
    approval_hash: str,
    execution_hash: str,
    comparison_hash: str,
    snapshot: str,
    head: str,
    base: str,
    baseline: str,
    allowed: list[str],
) -> dict[str, Any]:
    if approval.get("schema") != APPROVAL_SCHEMA or approval.get("approved") is not True:
        die("approval must explicitly approve the Stage 10 PR bundle")
    approver = required_string(approval, "approver", "approval")
    expiry = parse_expiry(approval.get("expires_at"))
    if expiry <= dt.datetime.now(dt.timezone.utc):
        die("approval has expired", 1)
    expected = {
        "execution_report_sha256": execution_hash,
        "comparison_report_sha256": comparison_hash,
        "candidate_snapshot_sha256": snapshot,
        "head_branch": head,
        "base_branch": base,
        "baseline_sha": baseline,
        "allowed_files": allowed,
    }
    for key, value in expected.items():
        if approval.get(key) != value:
            die(f"approval {key} does not match current evidence", 1)
    return {
        "approver": approver,
        "expires_at": expiry.isoformat().replace("+00:00", "Z"),
        "sha256": approval_hash,
    }


def report_reference(root: Path, path: Path, digest: str, manifest_hash: str) -> dict[str, str]:
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": digest,
        "source_manifest_sha256": manifest_hash,
    }


def render_markdown(bundle: dict[str, Any]) -> str:
    candidate = bundle["candidate"]
    lines = [
        "<!-- GENERATED by `stage10_pr.py`; obtain fresh approval after any evidence change. -->",
        f"# {bundle['title']}",
        "",
        bundle["summary"],
        "",
        "## Candidate",
        f"- Base: `{candidate['base_branch']}` at `{candidate['baseline_sha']}`",
        f"- Local head: `{candidate['head_branch']}`",
        f"- Snapshot: `{candidate['candidate_snapshot_sha256']}`",
        "- Changed files:",
        *(f"  - `{path}`" for path in candidate["changed_files"]),
        "",
        "## Route and environment",
        f"- Route: `{json.dumps(bundle['route'], sort_keys=True)}`",
        f"- Environment: `{json.dumps(bundle['environment'], sort_keys=True)}`",
        "",
        "## Exact validation",
        *(
            f"- `{check['name']}`: `{json.dumps(check['argv'])}` — **passed**"
            for check in bundle["validation"]["execution_checks"]
        ),
        *(
            f"- Hard gate `{gate['name']}` — **passed**"
            for gate in bundle["validation"]["hard_gates"]
        ),
        f"- Holdout — **{'passed' if bundle['validation']['holdout_pass'] else 'FAILED'}**",
        "",
        "## Feature economy",
        f"- {bundle['feature_economy']['reason']}",
    ]
    for retirement in bundle["feature_economy"]["retirements"]:
        lines.append(
            f"- Retired `{retirement['retired']}` — evidence: "
            + ", ".join(f"`{item}`" for item in retirement["evidence"])
        )
    if bundle["feature_economy"]["exception"]:
        exception = bundle["feature_economy"]["exception"]
        lines.append(f"- Evidenced `{exception['category']}` exception: {exception['rationale']}")
    lines.extend(["", "## Negative findings"])
    if bundle["negative_findings"]:
        lines.extend(f"- {item}" for item in bundle["negative_findings"])
    else:
        lines.append("- None recorded in the validated execution/comparison reports.")
    lines.extend(
        [
            "",
            "## Source evidence",
            f"- Execution report: `{bundle['source_reports']['execution']['path']}` "
            f"(`{bundle['source_reports']['execution']['sha256']}`)",
            f"- Comparison report: `{bundle['source_reports']['comparison']['path']}` "
            f"(`{bundle['source_reports']['comparison']['sha256']}`)",
            f"- Human approval: `{bundle['approval']['sha256']}`; expires "
            f"`{bundle['approval']['expires_at']}`",
            "",
            "## Remaining human action",
            f"- {bundle['remaining_human_action']}",
            "",
        ]
    )
    return "\n".join(lines)


def stage_file(path: Path, content: str) -> Path:
    descriptor, raw_temporary = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary = Path(raw_temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        return temporary
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def write_bundle_pair(
    output: Path,
    json_content: str,
    markdown_path: Path,
    markdown_content: str,
    pre_publish: Callable[[], None],
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.resolve() != output.parent:
        die("output directory changed or traverses a symlink")
    json_temporary = stage_file(output, json_content)
    markdown_temporary = stage_file(markdown_path, markdown_content)
    published: list[Path] = []
    try:
        pre_publish()
        os.replace(json_temporary, output)
        published.append(output)
        os.replace(markdown_temporary, markdown_path)
        published.append(markdown_path)
    except BaseException:
        for path in published:
            path.unlink(missing_ok=True)
        raise
    finally:
        json_temporary.unlink(missing_ok=True)
        markdown_temporary.unlink(missing_ok=True)


def prepare(args: argparse.Namespace) -> int:
    root = root_path(args.root)
    execution_path = confined_file(root, args.execution_report, "execution report")
    comparison_path = confined_file(root, args.comparison_report, "comparison report")
    execution, execution_hash = load_json(execution_path, "execution report")
    comparison, comparison_hash = load_json(comparison_path, "comparison report")
    frozen, changed, snapshot, head, base, _worktree, checks = validate_execution(root, execution)
    winner = validate_comparison(root, comparison, frozen, changed, head)

    if not args.human_approve or not args.approval_file:
        die(
            "awaiting-human-review: a matching --approval-file and explicit --human-approve "
            "are both required",
            1,
        )
    approval_path = confined_file(root, args.approval_file, "approval")
    approval, approval_hash = load_json(approval_path, "approval")
    approval_record = validate_approval(
        approval,
        approval_hash,
        execution_hash,
        comparison_hash,
        snapshot,
        head,
        base,
        frozen["baseline_sha"],
        frozen["allowed_files"],
    )
    binding = hashlib.sha256(f"{execution_hash}|{comparison_hash}|{approval_hash}".encode()).hexdigest()
    output, markdown_path = bundle_output(root, args.output, frozen["id"], binding)
    if os.path.lexists(output) or os.path.lexists(markdown_path):
        die("PR bundle output already exists; evidence requires a fresh destination")
    execution_manifest = required_string(execution, "manifest_sha256", "execution report")
    comparison_manifest = required_string(comparison, "manifest_sha256", "comparison report")
    negative_findings = list(execution.get("diagnostics", []))
    for candidate in comparison["candidates"]:
        if candidate["id"] != winner["id"]:
            negative_findings.extend(candidate.get("reason", []))
    bundle = {
        "schema": BUNDLE_SCHEMA,
        "status": "ready",
        "generated_at": stamp(),
        "title": f"Stage 10: {frozen['hypothesis']}"[:120],
        "summary": frozen["hypothesis"],
        "candidate": {
            "id": frozen["id"],
            "base_branch": base,
            "head_branch": head,
            "baseline_sha": frozen["baseline_sha"],
            "changed_files": changed,
            "candidate_snapshot_sha256": snapshot,
        },
        "route": frozen["route"],
        "environment": frozen["environment"],
        "validation": {
            "execution_checks": checks,
            "hard_gates": winner["gates"],
            "holdout_pass": winner["holdout_pass"],
            "comparison_evidence": winner["evidence"],
            "non_regression": comparison["experiment"]["non_regression"],
        },
        "feature_economy": comparison["feature_economy"],
        "negative_findings": negative_findings,
        "source_reports": {
            "execution": report_reference(root, execution_path, execution_hash, execution_manifest),
            "comparison": report_reference(root, comparison_path, comparison_hash, comparison_manifest),
        },
        "approval": approval_record,
        "authority": (
            "local handoff only; no hosting client, network operation, push, PR creation, merge, "
            "deployment, publication, protected-history rewrite, or policy activation was performed"
        ),
        "remaining_human_action": REMAINING_HUMAN_ACTION,
    }
    try:
        stage10_experiments.reject_unsafe(bundle, "PR bundle")
    except SystemExit:
        die("generated PR bundle contains unsafe material")
    json_content = json.dumps(bundle, indent=2, sort_keys=True) + "\n"
    markdown_content = render_markdown(bundle)
    if len(json_content.encode()) > MAX_BUNDLE_BYTES or len(markdown_content.encode()) > MAX_BUNDLE_BYTES:
        die(f"generated PR bundle exceeds the {MAX_BUNDLE_BYTES}-byte per-file limit", 1)
    def revalidate_before_publish() -> None:
        current_execution, current_execution_hash = load_json(execution_path, "execution report")
        current_comparison, current_comparison_hash = load_json(comparison_path, "comparison report")
        current_approval, current_approval_hash = load_json(approval_path, "approval")
        if (
            current_execution_hash != execution_hash
            or current_comparison_hash != comparison_hash
            or current_approval_hash != approval_hash
        ):
            die("evidence or approval changed while preparing the bundle", 1)
        (
            current_frozen,
            current_changed,
            current_snapshot,
            current_head,
            current_base,
            _current_worktree,
            current_checks,
        ) = validate_execution(root, current_execution)
        current_winner = validate_comparison(
            root, current_comparison, current_frozen, current_changed, current_head
        )
        validate_approval(
            current_approval,
            current_approval_hash,
            current_execution_hash,
            current_comparison_hash,
            current_snapshot,
            current_head,
            current_base,
            current_frozen["baseline_sha"],
            current_frozen["allowed_files"],
        )
        if (
            current_frozen != frozen
            or current_changed != changed
            or current_snapshot != snapshot
            or current_head != head
            or current_base != base
            or current_checks != checks
            or current_winner != winner
        ):
            die("validated evidence changed while preparing the bundle", 1)

    write_bundle_pair(output, json_content, markdown_path, markdown_content, revalidate_before_publish)
    print(f"stage10 pr: ready local bundle written to {output} and {markdown_path}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--execution-report", required=True)
    parser.add_argument("--comparison-report", required=True)
    parser.add_argument("--approval-file")
    parser.add_argument("--human-approve", action="store_true")
    parser.add_argument("--output")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    raise SystemExit(prepare(args))


if __name__ == "__main__":
    main()
