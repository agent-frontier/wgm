#!/usr/bin/env python3
"""Offline comparison of a learned route policy with the transparent incumbent.

All inputs are fixture data: this command never calls a provider, mutates policy, or activates,
merges, or publishes a recommendation.
"""
from __future__ import annotations
import argparse, datetime as dt, hashlib, json, re
from pathlib import Path
from typing import Any

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
MAX_BYTES = 1_000_000

def die(message: str) -> "NoReturn":
    import sys
    print(f"stage10 policy: ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)

def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')

def root_path(raw: str) -> Path:
    root = Path(raw).expanduser().resolve()
    if not root.is_dir(): die(f"root is not a directory: {root}")
    return root

def manifest_path(root: Path, raw: str) -> Path:
    p = Path(raw).expanduser().resolve()
    try: p.relative_to(root)
    except ValueError: die(f"manifest must remain under project root: {p}")
    if not p.is_file(): die(f"manifest is not a file: {p}")
    if p.stat().st_size > MAX_BYTES: die(f"manifest exceeds {MAX_BYTES}-byte limit")
    return p

def safe(value: Any, label: str) -> None:
    def walk(v: Any, path: str) -> None:
        if isinstance(v, str) and ("\n" in v or "\r" in v): die(f"{label}.{path} contains multiline material")
        if isinstance(v, dict):
            for k, child in v.items(): walk(child, f"{path}.{k}")
        elif isinstance(v, list):
            for i, child in enumerate(v): walk(child, f"{path}[{i}]")
    walk(value, "value")
    try: json.dumps(value, sort_keys=True)
    except (TypeError, ValueError) as exc: die(f"{label} is not JSON-safe: {exc}")

def load(path: Path) -> dict[str, Any]:
    try: value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc: die(f"cannot read manifest: {exc}")
    if not isinstance(value, dict): die("manifest must be an object")
    safe(value, "manifest")
    history = value.get("history", [])
    tasks = value.get("tasks", [])
    if not isinstance(history, list) or not isinstance(tasks, list): die("history and tasks must be lists")
    if not history or not tasks: die("history and tasks must be non-empty")
    return value

def output(root: Path, raw: str | None) -> Path:
    p = Path(raw) if raw else root / ".wgm/stage10/routing/policy/comparison.json"
    if not p.is_absolute(): p = root / p
    p = p.resolve()
    try: p.relative_to((root / '.wgm').resolve())
    except ValueError: die(f"output must remain under {root / '.wgm'}")
    return p

def compare(args: argparse.Namespace) -> None:
    root = root_path(args.root); path = manifest_path(root, args.manifest); data = load(path)
    history = data["history"]
    corroborated = [x for x in history if isinstance(x, dict) and x.get("standing") == "corroborated"]
    if len(corroborated) < 2:
        status, reason = "deferred", "insufficient corroborated route history (need at least 2 records)"
    else:
        status, reason = "rejected", "comparison not yet evaluated"
    rows = []
    ids = set()
    for i, task in enumerate(data["tasks"]):
        if not isinstance(task, dict) or not isinstance(task.get("id"), str) or not ID_RE.fullmatch(task["id"]): die(f"tasks[{i}] needs a valid id")
        if task["id"] in ids: die(f"duplicate task id: {task['id']}")
        ids.add(task["id"])
        inc, learn = task.get("incumbent"), task.get("learner")
        if not isinstance(inc, dict) or not isinstance(learn, dict): die(f"{task['id']} needs incumbent and learner results")
        for label, result in (("incumbent", inc), ("learner", learn)):
            if not isinstance(result.get("route"), str) or not isinstance(result.get("value"), (int, float)) or isinstance(result.get("value"), bool): die(f"{task['id']}.{label} needs route and numeric value")
            if not isinstance(result.get("hard_gate"), bool) or not isinstance(result.get("holdout"), bool): die(f"{task['id']}.{label} needs hard_gate and holdout booleans")
        regression = (inc["hard_gate"] and not learn["hard_gate"]) or (inc["holdout"] and not learn["holdout"])
        rows.append({"task": task["id"], "incumbent": inc, "learner": learn, "hard_regression": regression})
    if len(corroborated) >= 2:
        inc_total = sum(r["incumbent"]["value"] for r in rows); learn_total = sum(r["learner"]["value"] for r in rows)
        regressions = [r["task"] for r in rows if r["hard_regression"]]
        if regressions: reason = "per-task hard regression: " + ", ".join(regressions)
        elif learn_total > inc_total: status, reason = "recommend", "learner improves aggregate value with no hard regression"
        else: reason = "learner does not improve aggregate value"
    eligible = status == "recommend"
    report = {"schema":"stage10.policy-comparison.v1", "recorded_at":stamp(), "manifest":str(path), "manifest_sha256":hashlib.sha256(path.read_bytes()).hexdigest(), "history_provenance":[{"id":x.get("id"),"standing":x.get("standing"),"source":x.get("source")} for x in corroborated], "holdout_partition":"identical task records supplied to both policies", "status":status, "recommendation": "human-reviewed PR may activate policy" if eligible else "do not activate policy", "reason":reason, "tasks":rows, "authority":"offline comparison only; no automatic activation, PR creation, merge, deploy, or publish"}
    safe(report, "report"); out = output(root, args.output); out.parent.mkdir(parents=True, exist_ok=True); out.write_text(json.dumps(report, indent=2, sort_keys=True)+"\n", encoding="utf-8")
    card = out.with_suffix('.md'); lines=["# Stage 10 learned-policy comparison", "", f"- Status: **{status}**", f"- Recommendation: {report['recommendation']}", f"- Reason: {reason}", f"- Provenance records: {len(corroborated)}", "", "## Per-task results"]
    lines += [f"- `{r['task']}` — incumbent `{r['incumbent']['value']}`, learner `{r['learner']['value']}`, hard regression: **{'yes' if r['hard_regression'] else 'no'}**" for r in rows]
    lines += ["", "## Authority boundary", "- Offline evidence only; human review and merge are required before activation."]
    card.write_text("\n".join(lines)+"\n", encoding="utf-8"); print(f"stage10 policy: wrote {out} and {card}")
    if status != "recommend": raise SystemExit(1)

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("command", choices=["compare"]); p.add_argument("--root", required=True); p.add_argument("--manifest", required=True); p.add_argument("--output"); compare(p.parse_args())
if __name__ == "__main__": main()
