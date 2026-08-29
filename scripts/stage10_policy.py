#!/usr/bin/env python3
"""Offline comparison of a learned route policy with a transparent incumbent.

All inputs are fixture or recorded evidence. This command never calls a provider, mutates policy,
creates a branch, opens a PR, merges, deploys, or publishes. Sparse or regressing evidence stays
inactive and is rendered as a human-readable report.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
from pathlib import Path
from typing import Any

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{7,64}$")
SECRET_RE = re.compile(
    r"(?i)(?:api[_ -]?key|secret|password|passwd|token|authorization|bearer)"
    r"\s*(?:[:=]|is)\s*[^\s,;]+"
    r"|\b(?:ghp_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"github_pat_[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"sk-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"xoxb-[A-Za-z0-9][A-Za-z0-9._-]{8,}|"
    r"AKIA[A-Z0-9]{12,})\b"
)
MAX_BYTES = 1_000_000
MAX_TASKS = 10_000


def die(message: str, code: int = 2) -> "NoReturn":
    import sys

    print(f"stage10 policy: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def root_path(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        die(f"root is not a directory: {root}")
    return root


def project_file(root: Path, raw: str) -> Path:
    path = Path(raw).expanduser().resolve()
    try:
        path.relative_to(root)
    except ValueError:
        die(f"manifest must remain under project root: {path}")
    if not path.is_file():
        die(f"manifest is not a file: {path}")
    return path


def output_path(root: Path, raw: str | None) -> Path:
    path = Path(raw).expanduser() if raw else root / ".wgm" / "stage10" / "routing" / "policy" / "comparison.json"
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
        json.dumps(value, sort_keys=True, ensure_ascii=False)
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
    reject_unsafe(value, "manifest")
    required = {"policy_name", "incumbent_name", "learner_name", "metric_direction", "history", "tasks"}
    missing = sorted(required - set(value))
    if missing:
        die("manifest missing: " + ", ".join(missing))
    if value["metric_direction"] not in {"max", "min"}:
        die("metric_direction must be max or min")
    for key in ("policy_name", "incumbent_name", "learner_name"):
        if not isinstance(value[key], str) or not ID_RE.fullmatch(value[key]):
            die(f"{key} must be a lowercase slug")
    if not isinstance(value["history"], list) or not value["history"]:
        die("history must be non-empty")
    if not isinstance(value["tasks"], list) or not value["tasks"] or len(value["tasks"]) > MAX_TASKS:
        die(f"tasks must contain 1..{MAX_TASKS} items")
    return value


def validate_history(history: list[Any]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate(history):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not ID_RE.fullmatch(item["id"]):
            die(f"history[{index}] needs a lowercase id")
        if item["id"] in seen:
            die(f"duplicate history id: {item['id']}")
        seen.add(item["id"])
        if item.get("standing") not in {"corroborated", "promoted"}:
            continue
        if not isinstance(item.get("source"), str) or not item["source"].strip():
            die(f"history[{index}] needs a source")
        evidence = item.get("evidence")
        if not isinstance(evidence, list) or not evidence or not all(isinstance(ref, str) and ref.strip() for ref in evidence):
            die(f"history[{index}] needs a non-empty evidence list")
        records.append(item)
    return records


def validate_result(task_id: str, label: str, value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        die(f"{task_id}.{label} must be an object")
    route = value.get("route")
    metric = value.get("value")
    if not isinstance(route, str) or not ID_RE.fullmatch(route):
        die(f"{task_id}.{label}.route must be a lowercase slug")
    if isinstance(metric, bool) or not isinstance(metric, (int, float)):
        die(f"{task_id}.{label}.value must be numeric")
    if not isinstance(value.get("hard_gate"), bool) or not isinstance(value.get("holdout"), bool):
        die(f"{task_id}.{label} needs boolean hard_gate and holdout")
    evidence = value.get("evidence")
    if not isinstance(evidence, list) or not evidence or not all(isinstance(ref, str) and ref.strip() for ref in evidence):
        die(f"{task_id}.{label} needs a non-empty evidence list")
    reject_unsafe(value, f"{task_id}.{label}")
    return value


def validate_tasks(tasks: list[Any]) -> list[dict[str, Any]]:
    validated: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, task in enumerate(tasks):
        if not isinstance(task, dict) or not isinstance(task.get("id"), str) or not ID_RE.fullmatch(task["id"]):
            die(f"tasks[{index}] needs a lowercase id")
        task_id = task["id"]
        if task_id in seen:
            die(f"duplicate task id: {task_id}")
        seen.add(task_id)
        incumbent = validate_result(task_id, "incumbent", task.get("incumbent"))
        learner = validate_result(task_id, "learner", task.get("learner"))
        validated.append({"id": task_id, "incumbent": incumbent, "learner": learner})
    return validated


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def render_card(report: dict[str, Any]) -> str:
    lines = [
        "<!-- GENERATED by `stage10_policy.py`; edit the source manifest, then rerun compare. -->",
        "# Stage 10 learned-policy comparison",
        "",
        f"- Policy: `{report['policy_name']}` vs incumbent `{report['incumbent_name']}`",
        f"- Metric: `{report['metric_direction']}` aggregate `{report['aggregate']['incumbent']}` → `{report['aggregate']['learner']}`",
        f"- Status: **{report['status']}**",
        f"- Recommendation: {report['recommendation']}",
        f"- Reason: {report['reason']}",
        f"- Corroborated history records: **{len(report['history_provenance'])}**",
        "",
        "## Per-task results",
    ]
    for row in report["tasks"]:
        lines.append(
            f"- `{row['id']}` — incumbent `{row['incumbent']['value']}`, learner `{row['learner']['value']}`, "
            f"hard regression: **{'yes' if row['hard_regression'] else 'no'}**"
        )
    lines.extend(
        [
            "",
            "## Authority boundary",
            "- Offline comparison only; no automatic activation, PR creation, merge, deploy, or publish.",
            "- Human review is required before a policy recommendation can become active.",
            "",
        ]
    )
    return "\n".join(lines)


def compare(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    manifest_path = project_file(root, args.manifest)
    manifest = load_manifest(manifest_path)
    history = validate_history(manifest["history"])
    tasks = validate_tasks(manifest["tasks"])
    if len(history) < 2:
        status = "deferred"
        reason = "insufficient corroborated route history (need at least 2 records)"
    else:
        status = "rejected"
        reason = "comparison did not clear the policy gates"

    rows: list[dict[str, Any]] = []
    regressions: list[str] = []
    for task in tasks:
        incumbent = task["incumbent"]
        learner = task["learner"]
        regression = (incumbent["hard_gate"] and not learner["hard_gate"]) or (
            incumbent["holdout"] and not learner["holdout"]
        )
        if regression:
            regressions.append(task["id"])
        rows.append(
            {
                **task,
                "hard_regression": regression,
            }
        )

    incumbent_total = sum(task["incumbent"]["value"] for task in tasks)
    learner_total = sum(task["learner"]["value"] for task in tasks)
    improves = learner_total > incumbent_total if manifest["metric_direction"] == "max" else learner_total < incumbent_total
    if len(history) >= 2:
        if regressions:
            status = "rejected"
            reason = "per-task hard regression: " + ", ".join(regressions)
        elif improves:
            status = "recommend"
            reason = "learner improves aggregate value with no hard regression"
        else:
            status = "rejected"
            reason = "learner does not improve aggregate value"

    eligible = status == "recommend"
    report = {
        "schema": "stage10.policy-comparison.v1",
        "recorded_at": stamp(),
        "manifest": str(manifest_path),
        "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "policy_name": manifest["policy_name"],
        "incumbent_name": manifest["incumbent_name"],
        "learner_name": manifest["learner_name"],
        "metric_direction": manifest["metric_direction"],
        "history_provenance": [
            {key: record[key] for key in ("id", "standing", "source", "evidence")}
            for record in history
        ],
        "holdout_partition": "identical task records supplied to both policies",
        "aggregate": {"incumbent": incumbent_total, "learner": learner_total, "improves": improves},
        "status": status,
        "recommendation": "human-reviewed PR may activate policy" if eligible else "do not activate policy",
        "reason": reason,
        "tasks": rows,
        "authority": "offline comparison only; no automatic activation, PR creation, merge, deploy, or publish",
    }
    reject_unsafe(report, "comparison report")
    output = output_path(root, args.output)
    atomic_write(output, json.dumps(report, indent=2, sort_keys=True) + "\n")
    card = output.with_suffix(".md")
    atomic_write(card, render_card(report) + "\n")
    print(f"stage10 policy: wrote {output} and {card}")
    if status != "recommend":
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
