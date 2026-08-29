#!/usr/bin/env python3
"""Transparent, fail-closed Stage 10 route selection.

A route manifest is data, not a shell script. The router filters hard capabilities and evidence
standing before scoring, writes only under the target project's `.wgm/` directory, and emits both a
machine-readable decision and a short human-readable decision card. It does not call a model.
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
MAX_ROUTES = 100
STANDINGS = {"observed", "validated", "qualified", "corroborated", "promoted"}
QUALIFIED_LEVELS = {"qualified", "corroborated"}
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


def die(message: str, code: int = 2) -> "NoReturn":
    import sys

    print(f"stage10 router: ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def root_path(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        die(f"root is not a directory: {root}")
    return root


def under_wgm(root: Path, raw: str | None) -> Path:
    path = Path(raw).expanduser() if raw else root / ".wgm" / "stage10" / "routing" / "decision.json"
    if not path.is_absolute():
        path = root / path
    path = path.resolve()
    try:
        path.relative_to((root / ".wgm").resolve())
    except ValueError:
        die(f"output must remain under {root / '.wgm'}")
    return path


def under_root(root: Path, raw: str) -> Path:
    path = Path(raw).expanduser().resolve()
    try:
        path.relative_to(root)
    except ValueError:
        die(f"manifest must remain under project root: {path}")
    if not path.is_file():
        die(f"manifest is not a file: {path}")
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
    if not isinstance(value, dict) or not isinstance(value.get("task"), dict) or not isinstance(value.get("routes"), list):
        die("manifest needs task and routes")
    if len(value["routes"]) > MAX_ROUTES:
        die(f"manifest has more than {MAX_ROUTES} routes")
    reject_unsafe(value, "manifest")
    return value


def safe_git(root: Path, *args: str) -> str:
    import subprocess

    try:
        result = subprocess.run(
            ["git", *args], cwd=root, capture_output=True, text=True, check=True, timeout=10
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return "unknown"
    return result.stdout.strip() or "unknown"


def validate_task(task: dict[str, Any]) -> tuple[list[str], list[str], dict[str, Any], bool]:
    hard = task.get("hard_capabilities", [])
    preferences = task.get("preferences", [])
    budget = task.get("budget", {})
    local_only = task.get("local_only", False)
    if not isinstance(hard, list) or not all(isinstance(item, str) and item.strip() for item in hard):
        die("task hard_capabilities must be a list of non-empty strings")
    if not isinstance(preferences, list) or not all(isinstance(item, str) and item.strip() for item in preferences):
        die("task preferences must be a list of non-empty strings")
    if not isinstance(budget, dict):
        die("task budget must be an object")
    if not isinstance(local_only, bool):
        die("task local_only must be boolean")
    reject_unsafe(task, "task")
    return sorted(set(hard)), sorted(set(preferences)), budget, local_only


def validate_route(route: Any, index: int) -> tuple[str, set[str], dict[str, Any], str, float, float]:
    if not isinstance(route, dict):
        die(f"routes[{index}] must be an object")
    route_id = route.get("id")
    if not isinstance(route_id, str) or not ID_RE.fullmatch(route_id):
        die(f"routes[{index}] id must be a lowercase slug")
    capabilities = route.get("capabilities", [])
    evidence = route.get("evidence", {})
    environment = route.get("environment", "unknown")
    if not isinstance(capabilities, list) or not all(isinstance(item, str) and item.strip() for item in capabilities):
        die(f"{route_id}: capabilities must be a list of non-empty strings")
    if not isinstance(evidence, dict):
        die(f"{route_id}: evidence must be an object")
    if not isinstance(environment, str) or not environment.strip():
        die(f"{route_id}: environment must be a non-empty string")
    status = evidence.get("status", "unknown")
    level = evidence.get("level", "inventory")
    stale = evidence.get("stale", False)
    refs = evidence.get("refs", [])
    if status not in STANDINGS:
        die(f"{route_id}: evidence status must be one of {sorted(STANDINGS)}")
    if not isinstance(level, str) or not level.strip():
        die(f"{route_id}: evidence level must be a non-empty string")
    if not isinstance(stale, bool):
        die(f"{route_id}: evidence stale must be boolean")
    if not isinstance(refs, list) or not all(isinstance(item, str) and item.strip() for item in refs):
        die(f"{route_id}: evidence refs must be a list of non-empty strings")
    try:
        latency = float(route.get("latency_ms", 0))
        cost = float(route.get("cost_units", 0))
    except (TypeError, ValueError) as exc:
        die(f"{route_id}: latency_ms and cost_units must be numeric: {exc}")
    if latency < 0 or cost < 0:
        die(f"{route_id}: latency_ms and cost_units cannot be negative")
    reject_unsafe(route, f"route {route_id}")
    return route_id, set(capabilities), evidence, environment, latency, cost


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def decision_card(result: dict[str, Any]) -> str:
    selected = result.get("selected_route") or "none"
    lines = [
        "<!-- GENERATED by `stage10_router.py`; edit the manifest, then rerun route. -->",
        "# Stage 10 route decision",
        "",
        f"> Recorded at `{result['recorded_at']}` from `{result['manifest']}`.",
        "",
        "## Decision",
        f"- Selected route: **{selected}**",
        f"- Confidence: `{result['confidence']}`",
        f"- Budget: `{json.dumps(result['budget'], sort_keys=True)}`",
        f"- Rationale: {result['rationale']}",
        "",
        "## Alternatives and findings",
    ]
    for decision in result["decisions"]:
        status = "eligible" if decision["eligible"] else "excluded"
        score = decision["score"] if decision["score"] is not None else "—"
        lines.append(f"- `{decision['route']}` — **{status}**, score `{score}`: {'; '.join(decision['reasons'])}")
    lines.extend(
        [
            "",
            "## Authority boundary",
            "- This is a transparent offline decision; it does not call a model, deploy, open a PR, or merge.",
            "- Inventory presence is not authentication, tool capability, or successful Ralph execution.",
            "",
        ]
    )
    return "\n".join(lines)


def route(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    manifest_path = under_root(root, args.manifest)
    manifest = load_manifest(manifest_path)
    hard, preferences, budget, local_only = validate_task(manifest["task"])
    output = under_wgm(root, args.output)
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    decisions: list[dict[str, Any]] = []
    seen: set[str] = set()

    for index, route_data in enumerate(manifest["routes"]):
        route_id, capabilities, evidence, environment, latency, cost = validate_route(route_data, index)
        if route_id in seen:
            die(f"duplicate route id: {route_id}")
        seen.add(route_id)
        reasons: list[str] = []
        missing = sorted(set(hard) - capabilities)
        if missing:
            reasons.append("missing hard capabilities: " + ", ".join(missing))
        if local_only and environment != "local":
            reasons.append("local-only task requires local environment")
        if evidence.get("status") not in {"qualified", "corroborated", "promoted"} or evidence.get("level") not in QUALIFIED_LEVELS:
            reasons.append("evidence is not qualified")
        if evidence.get("stale"):
            reasons.append("evidence is stale and must be revalidated")
        if not evidence.get("refs"):
            reasons.append("evidence has no references")
        eligible = not reasons
        matched = sorted(set(preferences) & capabilities)
        score = len(matched) * 1000 - latency - cost if eligible else None
        if eligible:
            reasons.append(f"score = preferences({len(matched)}x1000) - latency({latency:g}) - cost({cost:g})")
        decisions.append(
            {
                "route": route_id,
                "eligible": eligible,
                "score": score,
                "environment": environment,
                "capabilities": sorted(capabilities),
                "evidence": evidence,
                "matched_preferences": matched,
                "reasons": reasons,
            }
        )

    eligible = sorted((item for item in decisions if item["eligible"]), key=lambda item: (-item["score"], item["route"]))
    selected = eligible[0]["route"] if eligible else None
    selected_record = next((item for item in eligible if item["route"] == selected), None)
    confidence = selected_record["evidence"]["status"] if selected_record else "none"
    result = {
        "schema": "stage10.routing.v1",
        "recorded_at": stamp(),
        "manifest": str(manifest_path),
        "manifest_sha256": manifest_hash,
        "task": manifest["task"],
        "selected_route": selected,
        "alternatives": [item["route"] for item in eligible[1:]],
        "budget": budget,
        "confidence": confidence,
        "uncertainty": [item["route"] + ": " + "; ".join(item["reasons"]) for item in decisions if not item["eligible"]],
        "rationale": (
            f"Selected {selected}: highest transparent score among capable, fresh, qualified routes."
            if selected
            else "No route selected: every route failed a hard eligibility gate."
        ),
        "decisions": decisions,
    }
    reject_unsafe(result, "decision result")
    atomic_write(output, json.dumps(result, indent=2, sort_keys=True) + "\n")
    card = output.with_suffix(".md")
    atomic_write(card, decision_card(result) + "\n")
    print(f"stage10 router: selected {selected or 'none'}; wrote {output} and {card}")
    if not selected:
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["route"])
    parser.add_argument("--root", default=".", help="project root")
    parser.add_argument("--manifest", required=True, help="route manifest under project root")
    parser.add_argument("--output", help="decision JSON path under project .wgm")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    route(args)


if __name__ == "__main__":
    main()
