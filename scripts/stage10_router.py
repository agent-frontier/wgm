#!/usr/bin/env python3
"""Transparent, fail-closed Stage 10 route selection."""
from __future__ import annotations
import argparse, datetime as dt, hashlib, json, re, sys
from pathlib import Path

MAX_BYTES = 1_000_000
SECRET = re.compile(r"(?i)(api[_ -]?key|secret|password|token|authorization|bearer)\s*[:=]\s*[^\s,;]+|\b(?:sk-|ghp_|xoxb-)[A-Za-z0-9._-]{8,}")

def die(msg: str) -> None:
    print(f"stage10 router: ERROR: {msg}", file=sys.stderr); raise SystemExit(2)

def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def load(path: Path) -> dict:
    if path.stat().st_size > MAX_BYTES: die("manifest exceeds size limit")
    try: value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc: die(f"cannot read manifest: {exc}")
    if not isinstance(value, dict) or not isinstance(value.get("task"), dict) or not isinstance(value.get("routes"), list):
        die("manifest needs task and routes")
    return value

def clean(value: object, label: str) -> object:
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    if "\n" in text or "\r" in text or SECRET.search(text): die(f"{label} contains unsafe material")
    return value

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__); ap.add_argument("command", choices=["route"])
    ap.add_argument("--manifest", required=True); ap.add_argument("--output"); args = ap.parse_args()
    manifest = load(Path(args.manifest).resolve()); task = manifest["task"]
    hard = task.get("hard_capabilities", []); prefs = task.get("preferences", []); budget = task.get("budget", {})
    if not all(isinstance(x, str) for x in hard + prefs) or not isinstance(budget, dict): die("capabilities and budget have invalid types")
    local_only = bool(task.get("local_only", False)); decisions=[]
    for index, route in enumerate(manifest["routes"]):
        if not isinstance(route, dict) or not isinstance(route.get("id"), str): die(f"routes[{index}] needs an id")
        rid=route["id"]; capabilities=set(route.get("capabilities", [])); evidence=route.get("evidence", {})
        if not isinstance(evidence, dict): die(f"{rid}: evidence must be an object")
        status=evidence.get("status", "unknown"); level=evidence.get("level", "inventory"); stale=bool(evidence.get("stale", False))
        reasons=[]; eligible=True
        missing=sorted(set(hard)-capabilities)
        if missing: eligible=False; reasons.append("missing hard capabilities: " + ", ".join(missing))
        if local_only and route.get("environment") != "local": eligible=False; reasons.append("local-only task requires local environment")
        if status not in {"qualified", "corroborated"} or level in {"inventory", "inventory-only"}: eligible=False; reasons.append("evidence is not qualified")
        if stale: eligible=False; reasons.append("evidence is stale and must be revalidated")
        matched=sorted(set(prefs)&capabilities); score=(len(matched)*10) - int(route.get("latency_ms", 0)) - int(route.get("cost_units", 0))
        if not eligible: score=None
        else: reasons.append(f"score = preferences({len(matched)}x10) - latency({route.get('latency_ms',0)}) - cost({route.get('cost_units',0)})")
        decisions.append({"route":rid,"eligible":eligible,"score":score,"capabilities":sorted(capabilities),"evidence":evidence,"reasons":reasons,"matched_preferences":matched})
    eligible=sorted((x for x in decisions if x["eligible"]), key=lambda x:(-x["score"], x["route"]))
    selected=eligible[0]["route"] if eligible else None
    if selected: rationale=f"Selected {selected}: highest transparent score among capable, fresh, qualified routes."
    else: rationale="No route selected: every route failed a hard eligibility gate."
    result={"schema":"stage10.routing.v1","recorded_at":stamp(),"task":clean(task,"task"),"selected_route":selected,"alternatives":[x["route"] for x in eligible[1:]],"budget":clean(budget,"budget"),"confidence":"high" if selected else "none","uncertainty":[x["route"]+": "+"; ".join(x["reasons"]) for x in decisions if not x["eligible"]],"rationale":rationale,"decisions":decisions}
    out=Path(args.output).expanduser() if args.output else Path(".wgm/stage10/routing/decision.json")
    if not out.is_absolute(): out=Path.cwd()/out
    root=(Path.cwd()/".wgm").resolve()
    try: out.resolve().relative_to(root)
    except ValueError: die("output must remain under .wgm")
    out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print(f"stage10 router: selected {selected or 'none'}; wrote {out}")
    if not selected: raise SystemExit(1)
if __name__ == "__main__": main()
