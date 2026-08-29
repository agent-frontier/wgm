#!/usr/bin/env python3
"""Offline, provider-agnostic Stage 10 experiment comparison.

Manifests and evaluator results are data only. This command never creates branches, calls a
provider, opens a PR, merges, deploys, or publishes. It validates a frozen-baseline comparison and
writes a machine report plus a concise human recommendation under the target project's `.wgm`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
from pathlib import Path
from typing import Any

MAX_BYTES = 1_000_000
MAX_CANDIDATES = 100
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
    parser.add_argument("command", choices=["compare"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    compare(args)


if __name__ == "__main__":
    main()
