#!/usr/bin/env python3
"""Deterministic, fail-closed harness qualification ladder.

The default command executes disposable fixture commands only.  A manifest is explicit about the
route, evidence kind, and phase commands; no provider, network, or credential is inferred.
"""
from __future__ import annotations
import argparse, datetime as dt, hashlib, json, os, subprocess, sys, time
from pathlib import Path

PHASES = ("inventory", "contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark")

def stamp(): return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
def die(msg): print(f"stage10 qualification: ERROR: {msg}", file=sys.stderr); raise SystemExit(2)
def root_path(raw):
    root=Path(raw).expanduser().resolve()
    if not root.is_dir(): die(f"root is not a directory: {root}")
    return root

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("qualify", nargs="?")
    p.add_argument("--root", default=".")
    p.add_argument("--manifest", required=True, help="JSON fixture manifest; commands are explicit")
    p.add_argument("--output", help="qualification JSONL path (must be under .wgm)")
    args=p.parse_args(); root=root_path(args.root)
    manifest=Path(args.manifest).expanduser().resolve()
    try: data=json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc: die(f"cannot read manifest: {exc}")
    if not isinstance(data,dict) or not isinstance(data.get("routes"),list): die("manifest needs a routes array")
    out=Path(args.output).expanduser() if args.output else root/".wgm/stage10/harnesses/qualification.jsonl"
    if not out.is_absolute(): out=root/out
    out=out.resolve()
    try: out.relative_to((root/".wgm").resolve())
    except ValueError: die("output must remain under .wgm")
    records=[]
    for route in data["routes"]:
        if not isinstance(route,dict) or not isinstance(route.get("id"),str): die("each route needs an id")
        evidence=route.get("evidence", "fixture")
        if evidence not in ("fixture", "live"): die(f"{route['id']}: evidence must be fixture or live")
        if evidence == "live" and not data.get("allow_live",False): die(f"{route['id']}: live evidence requires allow_live=true")
        commands=route.get("commands",{})
        if not isinstance(commands,dict): die(f"{route['id']}: commands must be an object")
        for phase in PHASES:
            command=commands.get(phase)
            started=time.monotonic(); status="passed"; detail="command not configured"
            if phase == "inventory": status="passed"; detail="route declared in manifest"
            elif command:
                if not isinstance(command,str) or len(command)>2000: die(f"{route['id']}/{phase}: invalid command")
                result=subprocess.run(command, shell=True, cwd=root, capture_output=True, text=True, timeout=30)
                status="passed" if result.returncode==0 else "failed"
                detail=(result.stdout.strip() or result.stderr.strip())[-500:]
            else: status="unknown"
            record={"schema":"stage10.qualification.v1","id":hashlib.sha256(f"{route['id']}:{phase}:{evidence}".encode()).hexdigest()[:16],"route":route["id"],"phase":phase,"evidence":evidence,"environment":route.get("environment","fixture" if evidence=="fixture" else "unspecified"),"command":command or "(declared route; no command)","duration_ms":round((time.monotonic()-started)*1000),"status":status,"detail":detail,"recorded_at":stamp(),"revalidate":{"source":str(manifest),"condition":"rerun the same manifest command"}}
            records.append(record)
            if status == "failed": break
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text("".join(json.dumps(r,sort_keys=True)+"\n" for r in records),encoding="utf-8")
    print(f"stage10 qualification: wrote {len(records)} records to {out}")
    if any(r["status"]=="failed" for r in records): raise SystemExit(1)

if __name__ == "__main__": main()
