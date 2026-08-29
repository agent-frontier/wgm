#!/usr/bin/env bash
# Proves hard exclusion, stale/inventory evidence handling, stable ordering, and explanation.
set -euo pipefail
root=$(mktemp -d); output=.wgm/stage10/routing/test-decision.json
trap 'rm -rf "$root" "$output"' EXIT
printf '%s' '{"task":{"hard_capabilities":["fresh-session","tools"],"preferences":["fast"],"local_only":true,"budget":{"seconds":30}},"routes":[{"id":"incapable","environment":"local","capabilities":["tools"],"evidence":{"status":"qualified","level":"qualified"}},{"id":"stale","environment":"local","capabilities":["fresh-session","tools"],"evidence":{"status":"qualified","level":"qualified","stale":true}},{"id":"inventory","environment":"local","capabilities":["fresh-session","tools"],"evidence":{"status":"unknown","level":"inventory-only"}},{"id":"zulu","environment":"local","capabilities":["fresh-session","tools","fast"],"latency_ms":2,"cost_units":1,"evidence":{"status":"qualified","level":"qualified"}},{"id":"alpha","environment":"local","capabilities":["fresh-session","tools"],"latency_ms":2,"cost_units":1,"evidence":{"status":"qualified","level":"qualified"}}]}' >"$root/manifest.json"
python3 scripts/stage10_router.py route --manifest "$root/manifest.json" --output "$output"
python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); assert x["selected_route"]=="zulu" and x["alternatives"]==["alpha"] and len(x["uncertainty"])==3; by={d["route"]:d for d in x["decisions"]}; assert not by["incapable"]["eligible"] and "missing hard capabilities" in by["incapable"]["reasons"][0] and not by["stale"]["eligible"] and not by["inventory"]["eligible"] and "score =" in by["zulu"]["reasons"][0]' "$output"
printf '%s\n' 'stage10 router harness: GREEN'
