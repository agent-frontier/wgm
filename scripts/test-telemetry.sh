#!/usr/bin/env bash
#
# wgm/test-telemetry.sh — deterministic backpressure for scripts/telemetry.py.
#
# Builds a ledger and pi-style session logs with hand-computed values in a temp dir and asserts every
# definition in references/telemetry.md ("Efficiency report"): clocks, completeness, span/phase matching,
# data-quality counters, turn accounting, peak concurrency, per-class figures, baseline factors and
# refusals, pre-registered vs late estimates, zero denominators. No network, no model calls.
#
# Exit 0 = GREEN; exit 1 = one or more assertions failed.

# shellcheck disable=SC2015  # pass() only prints; A && pass || fail is the harness idiom
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEL="$ROOT/scripts/telemetry.py"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# jget FILE PATH -> compact JSON of the value at a dotted path ("null" when absent)
jget() {
  python3 - "$1" "$2" << 'PY'
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if k.startswith("#"):  # "#N" indexes a list
        v = v[int(k[1:])] if isinstance(v, list) and int(k[1:]) < len(v) else None
    else:
        v = v.get(k) if isinstance(v, dict) else None
print(json.dumps(v, separators=(",", ":")))
PY
}
# eq NAME FILE PATH EXPECTED — one assertion on one report field
eq() {
  local got
  got="$(jget "$2" "$3")"
  if [ "$got" = "$4" ]; then pass "$1"; else fail "$1: $3 expected $4 got $got"; fi
}

L="$TMP/events.ndjson"
cat > "$L" << 'EOF2'
{"v":1,"ts":"2025-01-01T09:59:00Z","kind":"estimate","run":"r1","unit_class":"learn","units":4,"human_hours":2,"by":"op"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"r1","edge":"start","label":"x"}
garbage not json
{"v":2,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"r1"}
{"v":1,"ts":"not-a-time","kind":"run","run":"r1"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"bogus","run":"r1"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"expect","run":"r1","publication":"pubB"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"expect","run":"r1","publication":"pubA"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"phase","run":"r1","name":"plan","edge":"start"}
{"v":1,"ts":"2025-01-01T10:02:00Z","kind":"phase","run":"r1","name":"plan","edge":"end"}
{"v":1,"ts":"2025-01-01T10:03:00Z","kind":"phase","run":"r1","name":"plan","edge":"start"}
{"v":1,"ts":"2025-01-01T10:04:00Z","kind":"phase","run":"r1","name":"plan","edge":"end"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"phase","run":"r1","name":"orphan","edge":"end"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"span","run":"r1","edge":"start","span":"a1","cat":"agent","name":"w1","lane":"L1"}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"span","run":"r1","edge":"end","span":"a1","rc":0}
{"v":1,"ts":"2025-01-01T10:05:00+00:00","kind":"span","run":"r1","edge":"start","span":"a2","cat":"agent","name":"w2","lane":"L2"}
{"v":1,"ts":"2025-01-01T10:10:00.000Z","kind":"span","run":"r1","edge":"end","span":"a2","rc":0}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"span","run":"r1","edge":"start","span":"g1","cat":"gate","name":"unit"}
{"v":1,"ts":"2025-01-01T10:12:00Z","kind":"span","run":"r1","edge":"end","span":"g1","rc":0}
{"v":1,"ts":"2025-01-01T10:12:00Z","kind":"span","run":"r1","edge":"start","span":"g2","cat":"gate","name":"full"}
{"v":1,"ts":"2025-01-01T10:13:00Z","kind":"span","run":"r1","edge":"end","span":"g2","rc":1}
{"v":1,"ts":"2025-01-01T10:14:00Z","kind":"span","run":"r1","edge":"end","span":"zz","rc":0}
{"v":1,"ts":"2025-01-01T10:14:00Z","kind":"span","run":"r1","edge":"start","span":"open1","cat":"other","name":"never"}
{"v":1,"ts":"2025-01-01T10:15:00Z","kind":"span","run":"r1","edge":"start","span":"d1","cat":"other","name":"dup"}
{"v":1,"ts":"2025-01-01T10:16:00Z","kind":"span","run":"r1","edge":"start","span":"d1","cat":"other","name":"dup"}
{"v":1,"ts":"2025-01-01T10:17:00Z","kind":"span","run":"r1","edge":"end","span":"d1","rc":0}
{"v":1,"ts":"2025-01-01T10:19:00Z","kind":"span","run":"r1","edge":"end","span":"neg","rc":0}
{"v":1,"ts":"2025-01-01T10:20:00Z","kind":"span","run":"r1","edge":"start","span":"neg","cat":"other","name":"neg"}
{"v":1,"ts":"2025-01-01T10:01:00Z","kind":"candidate","run":"r1","sha":"aaa","decision":"accept"}
{"v":1,"ts":"2025-01-01T10:02:00Z","kind":"candidate","run":"r1","sha":"bbb","decision":"reject","gate":"unit"}
{"v":1,"ts":"2025-01-01T10:03:00Z","kind":"candidate","run":"r1","sha":"ccc","decision":"accept"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"unit","run":"r1","id":"u1","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:06:00Z","kind":"unit","run":"r1","id":"u2","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:07:00Z","kind":"unit","run":"r1","id":"u2","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:07:00Z","kind":"unit","run":"r1","id":"u3","class":"learn","status":"started"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"estimate","run":"r1","unit_class":"learn","units":2,"human_hours":9,"by":"late"}
{"v":1,"ts":"2025-01-01T10:12:00Z","kind":"milestone","run":"r1","name":"ready-to-test"}
{"v":1,"ts":"2025-01-01T10:13:00Z","kind":"milestone","run":"r1","name":"merged"}
{"v":1,"ts":"2025-01-01T10:15:00Z","kind":"milestone","run":"r1","name":"ready-to-test"}
{"v":1,"ts":"2025-01-01T10:20:00Z","kind":"milestone","run":"r1","name":"verified","publication":"pubA"}
{"v":1,"ts":"2025-01-01T10:30:00Z","kind":"milestone","run":"r1","name":"verified","publication":"pubB"}
{"v":1,"ts":"2025-01-01T10:40:00Z","kind":"run","run":"r1","edge":"end"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"unit","run":"other-run","id":"x","class":"zzz","status":"done"}
EOF2

# --- sessions (pi JSONL; lane = parent dir) ---
mkdir -p "$TMP/s/lane1" "$TMP/s/lane2" "$TMP/orch"
cat > "$TMP/s/lane1/a.jsonl" << 'EOF2'
{"type":"session","timestamp":"2025-01-01T09:00:00Z"}
{"type":"message","timestamp":"2025-01-01T09:00:00Z","message":{"role":"user"}}
{"type":"message","timestamp":"2025-01-01T09:01:00Z","message":{"role":"assistant","durationMs":999000,"usage":{"totalTokens":9999,"cost":{"total":9}}}}
{"type":"message","timestamp":"2025-01-01T10:00:00Z","message":{"role":"user"}}
{"type":"message","timestamp":"2025-01-01T10:01:00Z","message":{"role":"assistant","durationMs":30000,"usage":{"totalTokens":100,"cost":{"total":0.5}}}}
{"type":"message","timestamp":"2025-01-01T10:02:00Z","message":{"role":"toolResult","durationMs":5000}}
this is not json
{"type":"message","timestamp":"2025-01-01T10:05:00Z","message":{"role":"user"}}
{"type":"message","timestamp":"2025-01-01T10:06:00Z","message":{"role":"assistant","durationMs":20000,"usage":{"totalTokens":50,"cost":{"total":0.25}}}}
{"type":"message","timestamp":"2025-01-01T10:06:30Z","message":{"role":"assistant","usage":{"totalTokens":10,"cost":{"total":0.1}}}}
{"type":"message","timestamp":"2025-01-01T10:07:00Z","message":{"role":"user"}}
EOF2
cat > "$TMP/s/lane2/b.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T10:01:00Z","role":"user"}
{"timestamp":"2025-01-01T10:03:00Z","role":"assistant","durationMs":60000,"usage":{"totalTokens":40,"cost":{"total":0.2}}}
EOF2
cat > "$TMP/orch/o.jsonl" << 'EOF2'
{"type":"message","timestamp":"2025-01-01T10:00:00Z","message":{"role":"user"}}
{"type":"message","timestamp":"2025-01-01T10:30:00Z","message":{"role":"assistant","durationMs":100000,"usage":{"totalTokens":1000,"cost":{"total":1}}}}
EOF2

R="$TMP/r.json"
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" \
  --json "$R" --md "$TMP/r.md" || fail "report exits 0"
[ -s "$TMP/r.md" ] && pass "report writes Markdown file" || fail "markdown missing"

# Clocks: wall to the LAST verified (1800 s), complete, last ready at/before last merged = 10:12.
eq "schema" "$R" schema '"wgm-telemetry-report/1"'
eq "window start" "$R" window.start '"2025-01-01T10:00:00Z"'
eq "window end = run end" "$R" window.end '"2025-01-01T10:40:00Z"'
eq "wall_s" "$R" clocks.wall_s 1800
eq "wall_basis verified" "$R" clocks.wall_basis '"verified"'
eq "complete" "$R" clocks.complete true
eq "expected sorted" "$R" clocks.expected_publications '["pubA","pubB"]'
eq "missing none" "$R" clocks.missing_publications '[]'
eq "wall_to_ready (ready at/before merged)" "$R" clocks.wall_to_ready_s 720
eq "wall_to_merged" "$R" clocks.wall_to_merged_s 780
eq "wall_to_verified" "$R" clocks.wall_to_verified_s 1800
eq "phase sums matched pairs" "$R" clocks.phases_s '{"plan":180}'
# Gates / candidates / units.
eq "gates" "$R" gates '{"count":2,"total_s":180,"failed":1,"unknown":0}'
eq "candidates" "$R" candidates '{"evaluated":3,"accepted":2,"rejected":1,"first_pass_yield":0.666667}'
eq "units distinct done ids; other run excluded" "$R" units '{"learn":2}'
# Data quality: 3 ledger + 1 session malformed; bogus kind; spans zz,open1,d1-dup,neg-end-without-start...
eq "malformed lines" "$R" data_quality.malformed_lines 4
eq "unknown kinds" "$R" data_quality.unknown_kinds 1
# unmatched spans: zz, open1, d1 replaced, neg end (no open start) + neg start left open = 5
eq "unmatched spans" "$R" data_quality.unmatched_spans 5
eq "unmatched phases" "$R" data_quality.unmatched_phases 1
eq "excluded turns" "$R" data_quality.excluded_turns 1
eq "missing fields counted once per message" "$R" data_quality.missing_fields 1
# Agents: turns 3 timed (120 + 90 + 120), 1 untimed, peak 2, orchestrator excluded.
eq "agents sessions" "$R" agents.sessions 2
eq "agents turns" "$R" agents.turns 3
eq "agents untimed" "$R" agents.turns_untimed 1
eq "agents active" "$R" agents.active_s 330
eq "agents model" "$R" agents.model_s 110
eq "agents tool" "$R" agents.tool_s 5
eq "agents tokens" "$R" agents.tokens 200
eq "agents cost" "$R" agents.cost 1.05
eq "peak concurrency excludes orchestrator" "$R" agents.peak_concurrency 2
eq "by_lane lane1" "$R" agents.by_lane.lane1 '{"turns":2,"active_s":210,"model_s":50,"tool_s":5,"tokens":160,"cost":0.85}'
eq "orchestrator separate" "$R" orchestrator '{"turns":1,"turns_untimed":0,"active_s":1800,"model_s":100,"tool_s":0,"tokens":1000,"cost":1}'
eq "per_class (cost/tokens include orchestrator)" "$R" per_class.learn \
  '{"units":2,"wall_min_per_unit":15,"agent_active_min_per_unit":2.75,"cost_per_unit":1.025,"tokens_per_unit":600,"shared_wall":false,"usage_basis":"whole-run"}'
eq "agent_work_compression" "$R" ratios.agent_work_compression 0.238889
eq "implementation_parallelism" "$R" ratios.implementation_parallelism 1.5
eq "retry_tax" "$R" ratios.retry_tax 0.333333
# Estimates: pre-registered (<= run start) is used; the later one is listed and ignored.
eq "preregistered estimate factor" "$R" estimates.preregistered \
  '[{"unit_class":"learn","units":4,"human_hours":2,"by":"op","ts":"2025-01-01T09:59:00Z","factor_x":2}]'
eq "late estimate ignored" "$R" estimates.ignored_late \
  '[{"unit_class":"learn","units":2,"human_hours":9,"by":"late","ts":"2025-01-01T10:05:00Z"}]'
eq "baseline absent -> null" "$R" baseline null
grep -q "causal speedup" "$TMP/r.md" && pass "markdown disclaims causal speedup" || fail "markdown lacks causal disclaimer"
grep -q "lower bound" "$TMP/r.md" && grep -q "heuristic" "$TMP/r.md" && grep -q "pre-registered estimate" "$TMP/r.md" \
  && pass "markdown labels figures" || fail "markdown labels missing"

# stdout Markdown when --md absent; no sessions -> unavailable, not invented.
python3 "$TEL" report --ledger "$L" --run r1 > "$TMP/out.md" && grep -q "unavailable" "$TMP/out.md" \
  && pass "stdout markdown; absent inputs labelled unavailable" || fail "stdout markdown/unavailable"
python3 "$TEL" report --ledger "$L" --run r1 --json "$TMP/nos.json" > /dev/null
eq "no sessions: compression null" "$TMP/nos.json" ratios.agent_work_compression null
eq "no sessions: orchestrator null" "$TMP/nos.json" orchestrator null
eq "no sessions: counts stay 0" "$TMP/nos.json" agents.turns 0
eq "no sessions: per-unit agent figure null" "$TMP/nos.json" per_class.learn.agent_active_min_per_unit null

# Several runs and none chosen is an error.
cp "$L" "$TMP/multi.ndjson"
printf '%s\n' '{"v":1,"ts":"2025-01-02T10:00:00Z","kind":"run","run":"r2","edge":"start"}' >> "$TMP/multi.ndjson"
if python3 "$TEL" report --ledger "$TMP/multi.ndjson" > /dev/null 2>&1; then fail "ambiguous run must error"; else pass "several runs without --run errors"; fi

# --- baseline ---
cat > "$TMP/base.json" << 'EOF2'
{"run":"b0","provenance":"reconstructed","clocks":{"wall_basis":"verified","complete":true},
 "per_class":{"learn":{"units":1,"wall_min_per_unit":30,"agent_active_min_per_unit":5.5,"cost_per_unit":0,"shared_wall":false}}}
EOF2
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" \
  --baseline "$TMP/base.json" --json "$TMP/b.json" > "$TMP/b.md"
eq "baseline wall factor" "$TMP/b.json" baseline.factors.learn.wall_per_unit_x 2
eq "baseline agent factor" "$TMP/b.json" baseline.factors.learn.agent_active_per_unit_x 2
eq "zero baseline cost -> null factor" "$TMP/b.json" baseline.factors.learn.cost_per_unit_x null
eq "zero denominator refusal names metric and class" "$TMP/b.json" baseline.refused '["cost_per_unit: zero baseline value for learn"]'
eq "wall comparable (complete, same basis, single class)" "$TMP/b.json" baseline.factors.learn.comparable.wall true
eq "baseline provenance carried" "$TMP/b.json" baseline.factors.learn.baseline_provenance '"reconstructed"'
grep -q "not newly measured" "$TMP/b.md" && pass "reconstructed baseline flagged in Markdown" || fail "reconstructed flag missing"

# Baseline without provenance/complete: unspecified; complete only if wall_basis verified; differing basis -> not comparable.
cat > "$TMP/base2.json" << 'EOF2'
{"run":"b1","wall_basis":"window","per_class":{"learn":{"wall_min_per_unit":30,"agent_active_min_per_unit":5.5,"cost_per_unit":2.05,"shared_wall":false}}}
EOF2
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" \
  --baseline "$TMP/base2.json" --json "$TMP/b2.json" > /dev/null
eq "unspecified provenance" "$TMP/b2.json" baseline.provenance '"unspecified"'
eq "wall not comparable when basis differs/incomplete" "$TMP/b2.json" baseline.factors.learn.comparable.wall false
eq "factor still printed when not comparable" "$TMP/b2.json" baseline.factors.learn.cost_per_unit_x 2

# Cross-class baseline refused.
cat > "$TMP/base3.json" << 'EOF2'
{"run":"b2","provenance":"measured","clocks":{"wall_basis":"verified","complete":true},"per_class":{"audit":{"wall_min_per_unit":3}}}
EOF2
python3 "$TEL" report --ledger "$L" --run r1 --baseline "$TMP/base3.json" --json "$TMP/b3.json" > /dev/null
eq "cross-class: no factors" "$TMP/b3.json" baseline.factors '{}'
python3 - "$TMP/b3.json" << 'PY' && pass "cross-class baseline refused with reason" || fail "cross-class refusal missing"
import json, sys
r = json.load(open(sys.argv[1]))["baseline"]["refused"]
sys.exit(0 if len(r) == 1 and "no shared unit class" in r[0] else 1)
PY

# --- incomplete run: pubB never verified ---
grep -v '"publication":"pubB","name"' "$L" | grep -v '"name":"verified","publication":"pubB"' > "$TMP/inc.ndjson"
python3 "$TEL" report --ledger "$TMP/inc.ndjson" --run r1 --baseline "$TMP/base.json" --json "$TMP/inc.json" > /dev/null
eq "incomplete basis" "$TMP/inc.json" clocks.wall_basis '"incomplete"'
eq "incomplete complete=false" "$TMP/inc.json" clocks.complete false
eq "incomplete missing ids" "$TMP/inc.json" clocks.missing_publications '["pubB"]'
eq "incomplete wall = window" "$TMP/inc.json" clocks.wall_s 2400
eq "incomplete: no factors" "$TMP/inc.json" baseline.factors '{}'
eq "incomplete: refused" "$TMP/inc.json" baseline.refused '["incomplete run"]'

# --- no milestones -> window basis; ready-only -> ready basis; no expect -> one verified completes ---
cat > "$TMP/w.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"w","edge":"start"}
{"v":1,"ts":"2025-01-01T10:10:00+02:00","kind":"unit","run":"w","id":"a","class":"c1","status":"done"}
{"v":1,"ts":"2025-01-01T10:20:00Z","kind":"unit","run":"w","id":"b","class":"c2","status":"done"}
EOF2
python3 "$TEL" report --ledger "$TMP/w.ndjson" --json "$TMP/w.json" > /dev/null
eq "no milestones: window basis" "$TMP/w.json" clocks.wall_basis '"window"'
eq "window ends at last event" "$TMP/w.json" clocks.wall_s 1200
eq "offset timestamp parsed in UTC (earlier event, last = 10:20Z)" "$TMP/w.json" window.end '"2025-01-01T10:20:00Z"'
eq "shared_wall true with two classes" "$TMP/w.json" per_class.c1.shared_wall true
eq "shared wall divides whole wall" "$TMP/w.json" per_class.c2.wall_min_per_unit 20
printf '%s\n' '{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"milestone","run":"w","name":"ready-to-test"}' >> "$TMP/w.ndjson"
python3 "$TEL" report --ledger "$TMP/w.ndjson" --json "$TMP/w2.json" > /dev/null
eq "ready-only basis" "$TMP/w2.json" clocks.wall_basis '"ready-to-test"'
eq "ready-only wall" "$TMP/w2.json" clocks.wall_s 300
eq "ready-only is not complete" "$TMP/w2.json" clocks.complete false
printf '%s\n' '{"v":1,"ts":"2025-01-01T10:06:00Z","kind":"milestone","run":"w","name":"verified"}' >> "$TMP/w.ndjson"
python3 "$TEL" report --ledger "$TMP/w.ndjson" --json "$TMP/w3.json" > /dev/null
eq "no expect: one verified completes" "$TMP/w3.json" clocks.wall_basis '"verified"'

# --- zero denominators: wall 0 -> null ratios, never inf/NaN ---
cat > "$TMP/z.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"estimate","run":"z","unit_class":"c","units":1,"human_hours":1,"by":"op"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"z","edge":"start"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"unit","run":"z","id":"a","class":"c","status":"done"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"milestone","run":"z","name":"verified"}
EOF2
echo '{"run":"zb","clocks":{"wall_basis":"verified","complete":true},"per_class":{"c":{"wall_min_per_unit":5,"agent_active_min_per_unit":1,"cost_per_unit":1}}}' > "$TMP/zb.json"
python3 "$TEL" report --ledger "$TMP/z.ndjson" --sessions "$TMP/s" --baseline "$TMP/zb.json" --json "$TMP/z.json" > /dev/null
eq "wall 0: compression null" "$TMP/z.json" ratios.agent_work_compression null
eq "wall 0: estimate factor null" "$TMP/z.json" estimates.preregistered.0 null
python3 - "$TMP/z.json" << 'PY' && pass "zero current wall: baseline factor null with named refusal" || fail "zero-denominator baseline handling"
import json, sys
r = json.load(open(sys.argv[1]))
f, ref = r["baseline"]["factors"]["c"], r["baseline"]["refused"]
ok = f["wall_per_unit_x"] is None and "wall_per_unit: zero current value for c" in ref
ok = ok and r["estimates"]["preregistered"][0]["factor_x"] is None
sys.exit(0 if ok else 1)
PY

# Edges pair in LEDGER order: an end appended after its start but timestamped earlier is ONE negative
# interval (excluded from totals), not two unmatched edges. Same for phases.
cat > "$TMP/neg.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"n","edge":"start"}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"span","run":"n","edge":"start","span":"g","cat":"gate","name":"g"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"span","run":"n","edge":"end","span":"g","rc":0}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"phase","run":"n","name":"p","edge":"start"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"phase","run":"n","name":"p","edge":"end"}
{"v":1,"ts":"2025-01-01T10:20:00Z","kind":"run","run":"n","edge":"end"}
EOF2
python3 "$TEL" report --ledger "$TMP/neg.ndjson" --json "$TMP/neg.json" > /dev/null
eq "ledger-order pairing: negative interval counted" "$TMP/neg.json" data_quality.negative_intervals 2
eq "ledger-order pairing: not unmatched span" "$TMP/neg.json" data_quality.unmatched_spans 0
eq "ledger-order pairing: not unmatched phase" "$TMP/neg.json" data_quality.unmatched_phases 0
eq "negative span excluded from gate totals" "$TMP/neg.json" gates '{"count":0,"total_s":0,"failed":0,"unknown":0}'

# Session inventory: each real file is read once; the orchestrator file is never an agent input.
# (protects against double counting when --sessions . also covers the orchestrator log)
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP" --orchestrator-session "$TMP/orch/o.jsonl" --json "$TMP/inv1.json" > /dev/null
eq "orchestrator under --sessions: agent active unchanged" "$TMP/inv1.json" agents.active_s 330
eq "orchestrator under --sessions: peak unchanged" "$TMP/inv1.json" agents.peak_concurrency 2
eq "orchestrator under --sessions: compression unchanged" "$TMP/inv1.json" ratios.agent_work_compression 0.238889
eq "orchestrator under --sessions: not a duplicate" "$TMP/inv1.json" data_quality.duplicate_session_files 0
eq "orchestrator under --sessions: still reported" "$TMP/inv1.json" orchestrator.turns 1
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --sessions "$TMP/s" --sessions "$TMP/s/lane1" \
  --orchestrator-session "$TMP/orch/o.jsonl" --json "$TMP/inv2.json" > /dev/null
eq "repeated/overlapping roots: read once" "$TMP/inv2.json" agents.active_s 330
eq "repeated/overlapping roots: sessions" "$TMP/inv2.json" agents.sessions 2
eq "repeated/overlapping roots: duplicates counted (2 + 1)" "$TMP/inv2.json" data_quality.duplicate_session_files 3
ln -s "$TMP/s/lane2" "$TMP/s/link2"
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s/link2" --sessions "$TMP/s/lane2" --json "$TMP/inv3.json" > /dev/null
eq "symlinked root resolves to the same real file" "$TMP/inv3.json" data_quality.duplicate_session_files 1
rm -f "$TMP/s/link2"

# Missing --sessions dir must never look measured.
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/nope" --json "$TMP/miss.json" --md "$TMP/miss.md" > /dev/null
eq "missing dir: missing_inputs" "$TMP/miss.json" data_quality.missing_inputs 1
eq "missing dir: available false" "$TMP/miss.json" agents.available false
eq "missing dir: active null" "$TMP/miss.json" agents.active_s null
eq "missing dir: tokens null" "$TMP/miss.json" agents.tokens null
eq "missing dir: peak null" "$TMP/miss.json" agents.peak_concurrency null
eq "missing dir: counts stay 0" "$TMP/miss.json" agents.turns 0
eq "missing dir: compression null" "$TMP/miss.json" ratios.agent_work_compression null
eq "missing dir: per-class agent figure null" "$TMP/miss.json" per_class.learn.agent_active_min_per_unit null
eq "missing dir: per-class cost null" "$TMP/miss.json" per_class.learn.cost_per_unit null
grep -A1 "## Agents" "$TMP/miss.md" | grep -q "unavailable" && pass "missing dir: Markdown says unavailable" || fail "markdown agent section not unavailable"
# Orchestrator alone: cost/tokens sum only the available source; agent measures stay null.
python3 "$TEL" report --ledger "$L" --run r1 --orchestrator-session "$TMP/orch/o.jsonl" --json "$TMP/oo.json" > /dev/null
eq "orchestrator only: cost/unit from orchestrator" "$TMP/oo.json" per_class.learn.cost_per_unit 0.5
eq "orchestrator only: compression null" "$TMP/oo.json" ratios.agent_work_compression null
eq "orchestrator only: agent figure null" "$TMP/oo.json" per_class.learn.agent_active_min_per_unit null
python3 "$TEL" report --ledger "$L" --run r1 --orchestrator-session "$TMP/nope.jsonl" --json "$TMP/om.json" > /dev/null
eq "missing orchestrator file: counted, orchestrator null" "$TMP/om.json" data_quality.missing_inputs 1
eq "missing orchestrator file: orchestrator null" "$TMP/om.json" orchestrator null

# The documented ledger key is `span` (written by record too).
SP="$TMP/sp.ndjson"
python3 "$TEL" record --ledger "$SP" run run=sp edge=start ts=2025-01-01T10:00:00Z
python3 "$TEL" record --ledger "$SP" span run=sp edge=start span=x cat=gate name=n ts=2025-01-01T10:00:00Z
python3 "$TEL" record --ledger "$SP" span run=sp edge=end span=x rc=0 ts=2025-01-01T10:01:00Z
python3 "$TEL" report --ledger "$SP" --json "$TMP/sp.json" > /dev/null
eq "span key pairs start/end" "$TMP/sp.json" gates '{"count":1,"total_s":60,"failed":0,"unknown":0}'

# No `run start`: nothing start-dependent is measured (wall, window filter, pre-registration, baseline factors).
grep -v '"kind":"run","run":"r1","edge":"start"' "$L" > "$TMP/nostart.ndjson"
python3 "$TEL" report --ledger "$TMP/nostart.ndjson" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" \
  --baseline "$TMP/base.json" --json "$TMP/ns.json" --md "$TMP/ns.md" > /dev/null
eq "no start: wall_s null" "$TMP/ns.json" clocks.wall_s null
eq "no start: basis unavailable" "$TMP/ns.json" clocks.wall_basis '"unavailable"'
eq "no start: complete false" "$TMP/ns.json" clocks.complete false
eq "no start: wall_to_ready null" "$TMP/ns.json" clocks.wall_to_ready_s null
eq "no start: wall_to_merged null" "$TMP/ns.json" clocks.wall_to_merged_s null
eq "no start: wall_to_verified null" "$TMP/ns.json" clocks.wall_to_verified_s null
eq "no start: wall_min_per_unit null" "$TMP/ns.json" per_class.learn.wall_min_per_unit null
eq "no start: compression null" "$TMP/ns.json" ratios.agent_work_compression null
eq "no start: baseline factors refused" "$TMP/ns.json" baseline '{"run":"b0","provenance":"reconstructed","factors":{},"refused":["no run start"]}'
eq "no start: no window filter (excluded 0)" "$TMP/ns.json" data_quality.excluded_turns 0
eq "no start: out-of-window turn still parsed" "$TMP/ns.json" agents.turns 4
eq "no start: preregistered empty" "$TMP/ns.json" estimates.preregistered '[]'
eq "no start: late empty" "$TMP/ns.json" estimates.ignored_late '[]'
python3 - "$TMP/ns.json" << 'PY' && pass "no start: both estimates unverifiable, no factor_x" || fail "no start: estimates not unverifiable"
import json, sys
u = json.load(open(sys.argv[1]))["estimates"]["unverifiable"]
sys.exit(0 if len(u) == 2 and all("factor_x" not in x for x in u) else 1)
PY
grep -q "wall unavailable" "$TMP/ns.md" && pass "no start: Markdown says wall unavailable" || fail "no start: Markdown lacks unavailable"
# Control: the same ledger with the start restored keeps the measured results.
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" \
  --baseline "$TMP/base.json" --json "$TMP/ctl.json" > /dev/null
eq "control: wall_s measured" "$TMP/ctl.json" clocks.wall_s 1800
eq "control: basis verified" "$TMP/ctl.json" clocks.wall_basis '"verified"'
eq "control: baseline factor" "$TMP/ctl.json" baseline.factors.learn.wall_per_unit_x 2
eq "control: one preregistered, one late, none unverifiable" "$TMP/ctl.json" estimates.unverifiable '[]'
eq "control: excluded turn" "$TMP/ctl.json" data_quality.excluded_turns 1

# Per-figure labels: each line that prints an active-time figure says "lower bound"; each line that prints a
# cost/token figure says "session usage" (a document-wide label does not count). linehas MD PATTERN LABEL...
# finds the line(s) matching PATTERN and requires every one to contain every LABEL.
linehas() {
  local md="$1" pat="$2" shown n=0 label line
  shift 2
  while IFS= read -r line; do
    n=$((n + 1))
    for label in "$@"; do
      case "$line" in *"$label"*) ;; *) fail "label '$label' missing on line: $line"; return 0 ;; esac
    done
  done < <(grep -E -- "$pat" "$md" || true)
  shown="$pat"
  [ "$n" -gt 0 ] && pass "labels on the line printing: $shown" || fail "no line prints: $shown"
}
linehas "$TMP/r.md" '^- Sessions [0-9]+, timed turns' "lower bound"
linehas "$TMP/r.md" '^- Tokens ' "session usage"
linehas "$TMP/r.md" '^  - lane .lane1.' "lower bound" "session usage"
linehas "$TMP/r.md" '^- Orchestrator: [0-9]+ turns' "lower bound" "session usage"
linehas "$TMP/r.md" '^- .learn.: 2 units' "lower bound" "session usage"
linehas "$TMP/r.md" 'Agent-work compression' "lower bound"
# Orchestrator-only: agents unavailable, yet per-class usage and orchestrator active time stay labelled.
python3 "$TEL" report --ledger "$L" --run r1 --orchestrator-session "$TMP/orch/o.jsonl" --md "$TMP/oo.md" > /dev/null
linehas "$TMP/oo.md" '^- Orchestrator: [0-9]+ turns' "lower bound" "session usage"
linehas "$TMP/oo.md" '^- .learn.: 2 units' "session usage" "lower bound"
grep -q 'cost 0.5/unit; tokens 500/unit (measured from session usage' "$TMP/oo.md" \
  && pass "orchestrator-only per-unit usage printed with its label" || fail "orchestrator-only per-unit usage line unlabelled"
# Baseline factor line labels the figures it names.
linehas "$TMP/b.md" '^- .learn.: wall' "lower bound" "session usage"

# Orchestrator untimed turns: a trailing in-window unanswered user message is counted in
# orchestrator.turns_untimed only (never agents.turns_untimed, never in any total), and shown on the Markdown line.
cp "$TMP/orch/o.jsonl" "$TMP/orch/o2.jsonl"
printf '%s\n' '{"type":"message","timestamp":"2025-01-01T10:30:00Z","message":{"role":"user"}}' >> "$TMP/orch/o2.jsonl"
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" --json "$TMP/ou0.json" --md "$TMP/ou0.md" > /dev/null
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o2.jsonl" --json "$TMP/ou1.json" --md "$TMP/ou1.md" > /dev/null
eq "orchestrator untimed 0 without trailing user" "$TMP/ou0.json" orchestrator.turns_untimed 0
eq "orchestrator untimed 1 with trailing user" "$TMP/ou1.json" orchestrator.turns_untimed 1
eq "orchestrator untimed not in agents.turns_untimed" "$TMP/ou1.json" agents.turns_untimed 1
python3 - "$TMP/ou0.json" "$TMP/ou1.json" << 'PY' && pass "orchestrator and agent totals unchanged by untimed turn" || fail "untimed orchestrator turn altered totals"
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:3])
oa, ob = dict(a["orchestrator"]), dict(b["orchestrator"])
oa.pop("turns_untimed"); ob.pop("turns_untimed")
sys.exit(0 if oa == ob and a["agents"] == b["agents"] and a["ratios"] == b["ratios"] and a["per_class"] == b["per_class"] else 1)
PY
linehas "$TMP/ou1.md" '^- Orchestrator: [0-9]+ turns' "untimed 1"
linehas "$TMP/ou0.md" '^- Orchestrator: [0-9]+ turns' "untimed 0"

# First-pass yield is a heuristic: labelled so on its own line; counts stay measured.
linehas "$TMP/r.md" '^- First-pass yield' "heuristic"
linehas "$TMP/r.md" '^- Candidates:' "measured"
linehas "$TMP/r.md" '^- Retry tax' "heuristic"
linehas "$TMP/r.md" '^- Implementation parallelism' "heuristic"

# Half-open concurrency: a turn ending exactly when another starts does not overlap (peak 1);
# a 1 ms overlap does (peak 2).
cat > "$TMP/pk.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T09:00:00Z","kind":"run","run":"pk","edge":"start"}
{"v":1,"ts":"2025-01-01T11:00:00Z","kind":"run","run":"pk","edge":"end"}
EOF2
for variant in tie overlap; do
  mkdir -p "$TMP/pk-$variant/a" "$TMP/pk-$variant/b"
  printf '%s\n' '{"timestamp":"2025-01-01T10:00:00.000Z","role":"user"}' \
    '{"timestamp":"2025-01-01T10:01:00.000Z","role":"assistant","durationMs":1,"usage":{"totalTokens":1,"cost":{"total":0}}}' > "$TMP/pk-$variant/a/a.jsonl"
done
printf '%s\n' '{"timestamp":"2025-01-01T10:01:00.000Z","role":"user"}' \
  '{"timestamp":"2025-01-01T10:02:00.000Z","role":"assistant","durationMs":1,"usage":{"totalTokens":1,"cost":{"total":0}}}' > "$TMP/pk-tie/b/b.jsonl"
printf '%s\n' '{"timestamp":"2025-01-01T10:00:59.999Z","role":"user"}' \
  '{"timestamp":"2025-01-01T10:02:00.000Z","role":"assistant","durationMs":1,"usage":{"totalTokens":1,"cost":{"total":0}}}' > "$TMP/pk-overlap/b/b.jsonl"
python3 "$TEL" report --ledger "$TMP/pk.ndjson" --sessions "$TMP/pk-tie" --json "$TMP/pk1.json" > /dev/null
python3 "$TEL" report --ledger "$TMP/pk.ndjson" --sessions "$TMP/pk-overlap" --json "$TMP/pk2.json" > /dev/null
eq "half-open tie: end == start is not concurrent" "$TMP/pk1.json" agents.peak_concurrency 1
eq "half-open control: 1 ms overlap is concurrent" "$TMP/pk2.json" agents.peak_concurrency 2

# Complete mixed-class current run vs complete single-class baseline with the same wall basis: the factor is
# printed but NOT comparable (shared wall). The single-class control above stays comparable.
cat > "$TMP/mix.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"mx","edge":"start"}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"unit","run":"mx","id":"a","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:11:00Z","kind":"unit","run":"mx","id":"b","class":"audit","status":"done"}
{"v":1,"ts":"2025-01-01T10:20:00Z","kind":"milestone","run":"mx","name":"verified"}
EOF2
cat > "$TMP/mixb.json" << 'EOF2'
{"run":"mb","provenance":"measured","clocks":{"wall_basis":"verified","complete":true},
 "per_class":{"learn":{"wall_min_per_unit":40,"agent_active_min_per_unit":1,"cost_per_unit":1,"shared_wall":false}}}
EOF2
python3 "$TEL" report --ledger "$TMP/mix.ndjson" --baseline "$TMP/mixb.json" --json "$TMP/mx.json" --md "$TMP/mx.md" > /dev/null
eq "mixed: current complete, verified basis" "$TMP/mx.json" clocks.wall_basis '"verified"'
eq "mixed: shared_wall flagged" "$TMP/mx.json" per_class.learn.shared_wall true
eq "mixed: factor still printed" "$TMP/mx.json" baseline.factors.learn.wall_per_unit_x 2
eq "mixed: wall not comparable despite complete + same basis" "$TMP/mx.json" baseline.factors.learn.comparable.wall false
eq "mixed: reason names the failed condition and side" "$TMP/mx.json" baseline.factors.learn.not_comparable.wall '["shared wall (current)"]'
grep -q "wall NOT comparable (shared wall (current))" "$TMP/mx.md" && pass "mixed: Markdown gives the not-comparable reason" || fail "mixed: Markdown lacks reason"
# A shared-wall BASELINE against a single-class current run is also not comparable.
printf '%s\n' '{"run":"sb","clocks":{"wall_basis":"verified","complete":true},"per_class":{"learn":{"wall_min_per_unit":40,"agent_active_min_per_unit":1,"cost_per_unit":1,"shared_wall":true}}}' > "$TMP/sb.json"
python3 "$TEL" report --ledger "$L" --run r1 --baseline "$TMP/sb.json" --json "$TMP/sb-out.json" > /dev/null
eq "shared-wall baseline: wall not comparable" "$TMP/sb-out.json" baseline.factors.learn.comparable.wall false
eq "shared-wall baseline: reason names the baseline side" "$TMP/sb-out.json" baseline.factors.learn.not_comparable.wall '["shared wall (baseline)"]'

# Baseline failures: unreadable, malformed JSON and a non-object all fail closed (exit nonzero, message on stderr,
# no report written), never "no baseline".
echo '{not json' > "$TMP/bad.json"
echo '[1,2]' > "$TMP/arr.json"
for bcase in "$TMP/absent.json" "$TMP/bad.json" "$TMP/arr.json"; do
  rm -f "$TMP/bf.json"
  if python3 "$TEL" report --ledger "$L" --run r1 --baseline "$bcase" --json "$TMP/bf.json" > /dev/null 2> "$TMP/bf.err"; then
    fail "baseline $(basename "$bcase") must fail"
  elif grep -q "cannot read baseline" "$TMP/bf.err" && [ ! -e "$TMP/bf.json" ]; then
    pass "baseline $(basename "$bcase"): error exit, message, no report"
  else
    fail "baseline $(basename "$bcase"): wrong failure mode"
  fi
done

# ===== w5a contract amendments: A1 ownership, A2 validation, A3 one window + clipping, A4 evidence validity,
# A5 per-metric comparability, A11 whole-run usage label, A12 pre-registration evidence =====
wl() { printf '%s\n' "$@"; }   # write each argument as one ledger line

# A1: events with no usable `run` belong to no run. Two runs plus untagged/empty/non-string run events: each run's
# report sees only its own events; the unowned ones are excluded from every report and counted once (whole ledger).
cat > "$TMP/own.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T09:00:00Z","kind":"estimate","run":"A","unit_class":"learn","units":1,"human_hours":1,"by":"op"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"A","edge":"start"}
{"v":1,"ts":"2025-01-01T10:01:00Z","kind":"unit","run":"A","id":"a1","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:01:00Z","kind":"candidate","run":"A","sha":"s1","decision":"accept"}
{"v":1,"ts":"2025-01-01T10:09:00Z","kind":"milestone","run":"A","name":"verified"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"B","edge":"start"}
{"v":1,"ts":"2025-01-01T10:02:00Z","kind":"unit","run":"B","id":"b1","class":"audit","status":"done"}
{"v":1,"ts":"2025-01-01T10:02:00Z","kind":"unit","run":"B","id":"b2","class":"audit","status":"done"}
{"v":1,"ts":"2025-01-01T10:20:00Z","kind":"expect","run":"B","publication":"pubB"}
{"v":1,"ts":"2025-01-01T10:03:00Z","kind":"unit","id":"g1","class":"ghost","status":"done"}
{"v":1,"ts":"2025-01-01T10:03:00Z","kind":"candidate","sha":"g","decision":"reject"}
{"v":1,"ts":"2025-01-01T10:03:00Z","kind":"milestone","name":"verified","publication":"pubB"}
{"v":1,"ts":"2025-01-01T08:00:00Z","kind":"estimate","run":"","unit_class":"learn","units":9,"human_hours":9,"by":"x"}
{"v":1,"ts":"2025-01-01T10:03:00Z","kind":"unit","run":7,"id":"n1","class":"ghost","status":"done"}
EOF2
python3 "$TEL" report --ledger "$TMP/own.ndjson" --run A --json "$TMP/oa.json" > /dev/null
python3 "$TEL" report --ledger "$TMP/own.ndjson" --run B --json "$TMP/ob.json" > /dev/null
eq "A1: unowned events counted once (run A)" "$TMP/oa.json" data_quality.unowned_events 5
eq "A1: unowned events counted once (run B, same whole-ledger count)" "$TMP/ob.json" data_quality.unowned_events 5
eq "A1: run A units isolated" "$TMP/oa.json" units '{"learn":1}'
eq "A1: run B units isolated" "$TMP/ob.json" units '{"audit":2}'
eq "A1: run A candidates exclude untagged" "$TMP/oa.json" candidates.evaluated 1
eq "A1: run B has no candidates of A or untagged" "$TMP/ob.json" candidates.evaluated 0
eq "A1: run A completes on its own verified" "$TMP/oa.json" clocks.complete true
eq "A1: untagged verified does not complete run B" "$TMP/ob.json" clocks.complete false
eq "A1: run B missing its publication" "$TMP/ob.json" clocks.missing_publications '["pubB"]'
eq "A1: run A estimates: only its own (empty-run one excluded)" "$TMP/oa.json" estimates.preregistered.#0.units 1
eq "A1: run B has no estimates" "$TMP/ob.json" estimates '{"preregistered":[],"ignored_late":[],"unverifiable":[]}'
eq "A1 control: fully tagged ledger has none unowned" "$R" data_quality.unowned_events 0

# A2: each invalid shape is excluded and counted once; the control line (valid form) is counted 0.
a2base='{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"t","edge":"start"}'
a2() { # a2 NAME EXPECTED_INVALID LINE...
  local name="$1" want="$2"
  shift 2
  { printf '%s\n' "$a2base"; printf '%s\n' "$@"; } > "$TMP/a2.ndjson"
  python3 "$TEL" report --ledger "$TMP/a2.ndjson" --run t --json "$TMP/a2.json" > /dev/null
  eq "A2 $name" "$TMP/a2.json" data_quality.invalid_events "$want"
}
T='"v":1,"ts":"2025-01-01T10:01:00Z","run":"t"'
a2 "control: valid shapes of every kind" 0 \
  "{$T,\"kind\":\"run\",\"edge\":\"end\"}" "{$T,\"kind\":\"phase\",\"name\":\"p\",\"edge\":\"start\"}" \
  "{$T,\"kind\":\"span\",\"edge\":\"start\",\"span\":\"s\",\"cat\":\"gate\"}" "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"s\",\"rc\":0}" \
  "{$T,\"kind\":\"candidate\",\"sha\":\"x\",\"decision\":\"accept\"}" "{$T,\"kind\":\"unit\",\"id\":\"u\",\"class\":\"c\",\"status\":\"done\"}" \
  "{$T,\"kind\":\"milestone\",\"name\":\"merged\",\"sha\":\"x\",\"publication\":\"p\"}" "{$T,\"kind\":\"expect\",\"publication\":\"p\"}" \
  "{$T,\"kind\":\"estimate\",\"unit_class\":\"c\",\"units\":1,\"human_hours\":0.5,\"by\":\"op\"}"
a2 "run edge outside start|end" 1 "{$T,\"kind\":\"run\",\"edge\":\"middle\"}"
a2 "run without edge" 1 "{$T,\"kind\":\"run\"}"
a2 "phase without name" 1 "{$T,\"kind\":\"phase\",\"edge\":\"start\"}"
a2 "phase bad edge" 1 "{$T,\"kind\":\"phase\",\"name\":\"p\",\"edge\":\"begin\"}"
a2 "span without id" 1 "{$T,\"kind\":\"span\",\"edge\":\"start\",\"cat\":\"gate\"}"
a2 "span start without cat" 1 "{$T,\"kind\":\"span\",\"edge\":\"start\",\"span\":\"s\"}"
a2 "span end without rc" 1 "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"s\"}"
a2 "span end rc string" 1 "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"s\",\"rc\":\"0\"}"
a2 "span end rc boolean" 1 "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"s\",\"rc\":true}"
a2 "span end rc fractional" 1 "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"s\",\"rc\":0.5}"
a2 "span invalid edge" 1 "{$T,\"kind\":\"span\",\"edge\":\"x\",\"span\":\"s\",\"cat\":\"gate\"}"
a2 "candidate without sha" 1 "{$T,\"kind\":\"candidate\",\"decision\":\"accept\"}"
a2 "candidate bad decision" 1 "{$T,\"kind\":\"candidate\",\"sha\":\"x\",\"decision\":\"maybe\"}"
a2 "unit without id" 1 "{$T,\"kind\":\"unit\",\"class\":\"c\",\"status\":\"done\"}"
a2 "unit without class" 1 "{$T,\"kind\":\"unit\",\"id\":\"u\",\"status\":\"done\"}"
a2 "unit without status" 1 "{$T,\"kind\":\"unit\",\"id\":\"u\",\"class\":\"c\"}"
a2 "unit empty id" 1 "{$T,\"kind\":\"unit\",\"id\":\"\",\"class\":\"c\",\"status\":\"done\"}"
a2 "milestone unknown name" 1 "{$T,\"kind\":\"milestone\",\"name\":\"shipped\"}"
a2 "milestone non-string publication" 1 "{$T,\"kind\":\"milestone\",\"name\":\"verified\",\"publication\":5}"
a2 "milestone non-string sha" 1 "{$T,\"kind\":\"milestone\",\"name\":\"merged\",\"sha\":1}"
a2 "milestone empty sha" 1 "{$T,\"kind\":\"milestone\",\"name\":\"merged\",\"sha\":\"\"}"
a2 "milestone empty publication" 1 "{$T,\"kind\":\"milestone\",\"name\":\"verified\",\"publication\":\"\"}"
a2 "control: milestone non-empty sha and publication" 0 "{$T,\"kind\":\"milestone\",\"name\":\"verified\",\"sha\":\"x\",\"publication\":\"p\"}"
a2 "expect without publication" 1 "{$T,\"kind\":\"expect\"}"
a2 "estimate units zero" 1 "{$T,\"kind\":\"estimate\",\"unit_class\":\"c\",\"units\":0,\"human_hours\":1,\"by\":\"op\"}"
a2 "estimate units boolean" 1 "{$T,\"kind\":\"estimate\",\"unit_class\":\"c\",\"units\":true,\"human_hours\":1,\"by\":\"op\"}"
a2 "estimate human_hours NaN" 1 "{$T,\"kind\":\"estimate\",\"unit_class\":\"c\",\"units\":1,\"human_hours\":NaN,\"by\":\"op\"}"
a2 "estimate without by" 1 "{$T,\"kind\":\"estimate\",\"unit_class\":\"c\",\"units\":1,\"human_hours\":1}"
a2 "unknown kind is unknown, not invalid" 0 "{$T,\"kind\":\"zzz\"}"
eq "A2: unknown kind still counted as unknown_kinds" "$TMP/a2.json" data_quality.unknown_kinds 1
# An invalid event is excluded from aggregation: an id-less unit does not count; a bad-decision candidate neither.
a2 "excluded from aggregation" 2 "{$T,\"kind\":\"unit\",\"class\":\"c\",\"status\":\"done\"}" \
  "{$T,\"kind\":\"candidate\",\"sha\":\"x\",\"decision\":\"maybe\"}"
eq "A2: invalid unit not counted" "$TMP/a2.json" units '{}'
eq "A2: invalid candidate not counted" "$TMP/a2.json" candidates.evaluated 0
# F3: a selected run with no valid events exits 2 with one stderr line naming the run and the invalid count.
printf '%s\n' "{$T,\"kind\":\"unit\",\"class\":\"c\",\"status\":\"done\"}" "{$T,\"kind\":\"milestone\",\"name\":\"nope\"}" > "$TMP/allbad.ndjson"
rm -f "$TMP/allbad.json"
rc=0
python3 "$TEL" report --ledger "$TMP/allbad.ndjson" --run t --json "$TMP/allbad.json" > "$TMP/allbad.out" 2> "$TMP/allbad.err" || rc=$?
[ "$rc" -eq 2 ] && pass "F3: all-invalid run exits 2" || fail "F3: exit $rc, expected 2"
[ "$(wc -l < "$TMP/allbad.err")" -eq 1 ] && grep -q "'t'" "$TMP/allbad.err" && grep -q "2 invalid" "$TMP/allbad.err" \
  && pass "F3: one stderr line naming run and invalid count" || fail "F3: stderr wrong: $(cat "$TMP/allbad.err")"
! grep -q Traceback "$TMP/allbad.err" && [ ! -e "$TMP/allbad.json" ] && [ ! -s "$TMP/allbad.out" ] \
  && pass "F3: no traceback, no report" || fail "F3: traceback or report produced"
# F3 (none case): an absent run against an empty ledger and against a ledger holding only another run.
: > "$TMP/empty.ndjson"
printf '%s\n' "$a2base" > "$TMP/other.ndjson"
for nl in empty other; do
  rm -f "$TMP/none.json" "$TMP/none.md"
  rc=0
  python3 "$TEL" report --ledger "$TMP/$nl.ndjson" --run absent --json "$TMP/none.json" --md "$TMP/none.md" > "$TMP/none.out" 2> "$TMP/none.err" || rc=$?
  [ "$rc" -eq 2 ] && pass "F3: absent run on $nl ledger exits 2" || fail "F3: $nl ledger exit $rc, expected 2"
  [ "$(wc -l < "$TMP/none.err")" -eq 1 ] && grep -q "'absent'" "$TMP/none.err" && grep -q "0 invalid" "$TMP/none.err" \
    && pass "F3: $nl ledger: one stderr line naming run and 0 invalid" || fail "F3: $nl ledger stderr wrong: $(cat "$TMP/none.err")"
  ! grep -q Traceback "$TMP/none.err" && [ ! -e "$TMP/none.json" ] && [ ! -e "$TMP/none.md" ] && [ ! -s "$TMP/none.out" ] \
    && pass "F3: $nl ledger: no traceback, no report" || fail "F3: $nl ledger produced output"
done
# Control: the other run in that ledger still reports, exit 0.
python3 "$TEL" report --ledger "$TMP/other.ndjson" --run t --json "$TMP/none.json" > /dev/null \
  && [ -s "$TMP/none.json" ] && pass "F3 control: existing run still reports (exit 0)" || fail "F3 control: existing run failed"
# All-invalid case also writes no Markdown file.
rm -f "$TMP/allbad.md"
python3 "$TEL" report --ledger "$TMP/allbad.ndjson" --run t --md "$TMP/allbad.md" > /dev/null 2>&1 || true
[ ! -e "$TMP/allbad.md" ] && pass "F3: all-invalid run writes no Markdown file" || fail "F3: Markdown written for all-invalid run"
# Control: one valid event among invalid ones reports normally.
a2 "control: one valid event beside invalid ones reports" 2 "{$T,\"kind\":\"unit\",\"class\":\"c\",\"status\":\"done\"}" "{$T,\"kind\":\"milestone\",\"name\":\"nope\"}"

# gates.unknown: a gate with no valid end is unknown (also unmatched) — never passed or failed.
a2 "gate end without rc: invalid" 1 "{$T,\"kind\":\"span\",\"edge\":\"start\",\"span\":\"g\",\"cat\":\"gate\"}" \
  "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"g\"}"
eq "A2: gate without valid end is unknown" "$TMP/a2.json" gates '{"count":0,"total_s":0,"failed":0,"unknown":1}'
eq "A2: unknown gate also unmatched" "$TMP/a2.json" data_quality.unmatched_spans 1
a2 "gate with valid end rc=0" 0 "{$T,\"kind\":\"span\",\"edge\":\"start\",\"span\":\"g\",\"cat\":\"gate\"}" \
  "{$T,\"kind\":\"span\",\"edge\":\"end\",\"span\":\"g\",\"rc\":0}"
eq "A2 control: closed gate is passed, not unknown" "$TMP/a2.json" gates '{"count":1,"total_s":0,"failed":0,"unknown":0}'
a2 "non-gate open span is not an unknown gate" 0 "{$T,\"kind\":\"span\",\"edge\":\"start\",\"span\":\"o\",\"cat\":\"agent\"}"
eq "A2 control: open non-gate span" "$TMP/a2.json" gates.unknown 0

# A3: one accounting window [run start, run start + wall]. Run 10:00, verified 10:10, run end 10:30.
cat > "$TMP/win.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"w","edge":"start"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"unit","run":"w","id":"u1","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"milestone","run":"w","name":"verified"}
{"v":1,"ts":"2025-01-01T10:30:00Z","kind":"run","run":"w","edge":"end"}
EOF2
mkdir -p "$TMP/ws/lane1" "$TMP/ws/lane2" "$TMP/wo"
# lane1: C crosses run start (09:58-10:01), A inside (10:02-10:04), untimed F inside (10:05), D crosses the
# accounting end (10:09-10:12), untimed E after the end (10:20, excluded).
cat > "$TMP/ws/lane1/a.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T09:58:00Z","role":"user"}
{"timestamp":"2025-01-01T10:01:00Z","role":"assistant","durationMs":1000,"usage":{"totalTokens":20,"cost":{"total":2}}}
{"timestamp":"2025-01-01T10:02:00Z","role":"user"}
{"timestamp":"2025-01-01T10:04:00Z","role":"assistant","durationMs":1000,"usage":{"totalTokens":10,"cost":{"total":1}}}
{"timestamp":"2025-01-01T10:05:00Z","role":"user"}
{"timestamp":"2025-01-01T10:09:00Z","role":"user"}
{"timestamp":"2025-01-01T10:12:00Z","role":"assistant","durationMs":2000,"usage":{"totalTokens":40,"cost":{"total":4}}}
{"timestamp":"2025-01-01T10:20:00Z","role":"user"}
EOF2
# lane2: K ends exactly at run start (clipped to zero length; unclipped it would overlap C -> peak 2), B entirely
# after the endpoint, H entirely before the start (both excluded).
cat > "$TMP/ws/lane2/b.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T09:50:00Z","role":"user"}
{"timestamp":"2025-01-01T09:51:00Z","role":"assistant","durationMs":1000,"usage":{"totalTokens":900,"cost":{"total":90}}}
{"timestamp":"2025-01-01T09:57:00Z","role":"user"}
{"timestamp":"2025-01-01T10:00:00Z","role":"assistant","durationMs":1000,"usage":{"totalTokens":5,"cost":{"total":0.5}}}
{"timestamp":"2025-01-01T10:13:00Z","role":"user"}
{"timestamp":"2025-01-01T10:14:00Z","role":"assistant","durationMs":1000,"usage":{"totalTokens":700,"cost":{"total":70}}}
EOF2
cat > "$TMP/wo/o.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T09:59:00Z","role":"user"}
{"timestamp":"2025-01-01T10:01:00Z","role":"assistant","durationMs":3000,"usage":{"totalTokens":300,"cost":{"total":3}}}
EOF2
python3 "$TEL" report --ledger "$TMP/win.ndjson" --run w --sessions "$TMP/ws" --orchestrator-session "$TMP/wo/o.jsonl" \
  --json "$TMP/w.json" --md "$TMP/w.md" > /dev/null
eq "A3: wall = 600" "$TMP/w.json" clocks.wall_s 600
eq "A3: accounting_end = run start + wall" "$TMP/w.json" window.accounting_end '"2025-01-01T10:10:00Z"'
eq "A3: window.end unchanged (run end)" "$TMP/w.json" window.end '"2025-01-01T10:30:00Z"'
eq "A3: turns after endpoint / before start excluded (B, H, E)" "$TMP/w.json" data_quality.excluded_turns 3
eq "A3: crossing turns clipped once each (C, D, K, orchestrator)" "$TMP/w.json" data_quality.clipped_turns 4
eq "A3: timed turns (A, C, D, K) and untimed inside (F)" "$TMP/w.json" agents.turns 4
eq "A3: untimed inside counted, untimed after end excluded" "$TMP/w.json" agents.turns_untimed 1
eq "A3: active = overlap only (60 + 120 + 60 + 0)" "$TMP/w.json" agents.active_s 240
eq "A3: usage of clipped turns counted in full; excluded turns not" "$TMP/w.json" agents.tokens 75
eq "A3: cost in full" "$TMP/w.json" agents.cost 7.5
eq "A3: peak concurrency uses the clipped overlap" "$TMP/w.json" agents.peak_concurrency 1
eq "A3: by-lane active clipped" "$TMP/w.json" agents.by_lane.lane1.active_s 240
eq "A3: orchestrator clipped too (active 60, usage full)" "$TMP/w.json" orchestrator '{"turns":1,"turns_untimed":0,"active_s":60,"model_s":3,"tool_s":0,"tokens":300,"cost":3}'
# Controls: with the verified endpoint moved to 10:30 nothing is excluded for lateness and only the start-crossers clip.
sed 's/"2025-01-01T10:10:00Z","kind":"milestone"/"2025-01-01T10:30:00Z","kind":"milestone"/' "$TMP/win.ndjson" > "$TMP/win2.ndjson"
python3 "$TEL" report --ledger "$TMP/win2.ndjson" --run w --sessions "$TMP/ws" --json "$TMP/w2.json" > /dev/null
eq "A3 control: wider window keeps B in" "$TMP/w2.json" data_quality.excluded_turns 1
eq "A3 control: only C and K clip now" "$TMP/w2.json" data_quality.clipped_turns 2
eq "A3 control: peak 1 (K clipped to zero length)" "$TMP/w2.json" agents.peak_concurrency 1
eq "A3: no start -> accounting_end null" "$TMP/ns.json" window.accounting_end null

# A4: reversed turn and invalid measurements. user 10:05 whose last message is at 10:04 = negative interval.
mkdir -p "$TMP/bs/l"
cat > "$TMP/bs/l/n.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T10:05:00Z","role":"user"}
{"timestamp":"2025-01-01T10:04:00Z","role":"assistant","durationMs":1000,"usage":{"totalTokens":99,"cost":{"total":9}}}
{"timestamp":"2025-01-01T10:01:00Z","role":"user"}
{"timestamp":"2025-01-01T10:02:00Z","role":"assistant","durationMs":-1000,"usage":{"totalTokens":NaN,"cost":{"total":Infinity}}}
{"timestamp":"2025-01-01T10:02:30Z","role":"toolResult","durationMs":-5}
{"timestamp":"2025-01-01T10:03:00Z","role":"assistant","durationMs":"7","usage":{"totalTokens":-Infinity,"cost":{"total":-1}}}
EOF2
python3 "$TEL" report --ledger "$TMP/win.ndjson" --run w --sessions "$TMP/bs" --json "$TMP/bad.json" > /dev/null
eq "A4: reversed turn excluded and counted" "$TMP/bad.json" data_quality.negative_intervals 1
eq "A4: reversed turn adds nothing (one timed turn left)" "$TMP/bad.json" agents.turns 1
eq "A4: negative/NaN/Infinity/wrong-type values are missing, +1 per message" "$TMP/bad.json" data_quality.missing_fields 3
eq "A4: invalid values add nothing (tokens)" "$TMP/bad.json" agents.tokens 0
eq "A4: invalid values add nothing (cost)" "$TMP/bad.json" agents.cost 0
eq "A4: invalid durations add nothing (model)" "$TMP/bad.json" agents.model_s 0
eq "A4: invalid durations add nothing (tool)" "$TMP/bad.json" agents.tool_s 0
mkdir -p "$TMP/gs/l"
cat > "$TMP/gs/l/g.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T10:01:00Z","role":"user"}
{"timestamp":"2025-01-01T10:02:00Z","role":"assistant","durationMs":0,"usage":{"totalTokens":0,"cost":{"total":0}}}
{"timestamp":"2025-01-01T10:02:30Z","role":"toolResult","durationMs":5000}
EOF2
python3 "$TEL" report --ledger "$TMP/win.ndjson" --run w --sessions "$TMP/gs" --json "$TMP/good.json" > /dev/null
eq "A4 control: zero values are valid (nothing missing)" "$TMP/good.json" data_quality.missing_fields 0
eq "A4 control: no negative intervals" "$TMP/good.json" data_quality.negative_intervals 0
eq "A4 control: valid tool duration counted" "$TMP/good.json" agents.tool_s 5

# A5: metric-specific comparability. A clean current report vs baselines with asymmetric coverage.
mkdir -p "$TMP/cs/l"
cat > "$TMP/cs/l/c.jsonl" << 'EOF2'
{"timestamp":"2025-01-01T10:01:00Z","role":"user"}
{"timestamp":"2025-01-01T10:03:00Z","role":"assistant","durationMs":60000,"usage":{"totalTokens":10,"cost":{"total":1}}}
EOF2
python3 "$TEL" report --ledger "$TMP/win.ndjson" --run w --sessions "$TMP/cs" --json "$TMP/clean.json" > /dev/null
a5() { # a5 NAME REPORT_JSON JQ-ish python mutation of the baseline; expected comparable + not_comparable
  local name="$1" cur="$2" mut="$3" wantc="$4" wantn="$5"
  python3 - "$TMP/clean.json" "$TMP/a5b.json" "$mut" << 'PY'
import json, sys
b = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(b, open(sys.argv[2], "w"))
PY
  python3 "$TEL" report --ledger "$TMP/win.ndjson" --run w --sessions "$cur" --baseline "$TMP/a5b.json" --json "$TMP/a5.json" > /dev/null
  eq "A5 $name: comparable" "$TMP/a5.json" baseline.factors.learn.comparable "$wantc"
  eq "A5 $name: reasons" "$TMP/a5.json" baseline.factors.learn.not_comparable "$wantn"
}
a5 "control: clean both sides" "$TMP/cs" 'pass' '{"wall":true,"agent_active":true,"cost":true}' '{}'
eq "A5: factor values still computed" "$TMP/a5.json" baseline.factors.learn.wall_per_unit_x 1
a5 "baseline untimed turns" "$TMP/cs" 'b["agents"]["turns_untimed"]=1' '{"wall":true,"agent_active":false,"cost":true}' '{"agent_active":["untimed turns (baseline)"]}'
a5 "baseline agents unavailable" "$TMP/cs" 'b["agents"]["available"]=False' '{"wall":true,"agent_active":false,"cost":true}' '{"agent_active":["agents unavailable (baseline)"]}'
a5 "baseline missing usage fields" "$TMP/cs" 'b["data_quality"]["missing_fields"]=2' '{"wall":true,"agent_active":true,"cost":false}' '{"cost":["missing usage fields (baseline)"]}'
a5 "baseline clipped turns" "$TMP/cs" 'b["data_quality"]["clipped_turns"]=1' '{"wall":true,"agent_active":true,"cost":false}' '{"cost":["clipped turns (baseline)"]}'
a5 "orchestrator inclusion differs" "$TMP/cs" 'b["orchestrator"]={"turns":1}' '{"wall":true,"agent_active":true,"cost":false}' '{"cost":["orchestrator inclusion differs"]}'
a5 "baseline lacks agents block" "$TMP/cs" 'del b["agents"]' '{"wall":true,"agent_active":false,"cost":true}' '{"agent_active":["baseline coverage unknown"]}'
a5 "baseline lacks data_quality" "$TMP/cs" 'del b["data_quality"]' '{"wall":true,"agent_active":true,"cost":false}' '{"cost":["baseline coverage unknown"]}'
a5 "baseline lacks clipped_turns key" "$TMP/cs" 'del b["data_quality"]["clipped_turns"]' '{"wall":true,"agent_active":true,"cost":false}' '{"cost":["baseline coverage unknown"]}'
# F1: nothing is inferred. Each explicit wall key missing (or non-boolean) -> wall, and therefore agent_active and
# cost, are "baseline coverage unknown"; descriptive factor values are still computed.
unk3='{"wall":false,"agent_active":false,"cost":false}'
unkr='{"wall":["baseline coverage unknown"],"agent_active":["baseline coverage unknown"],"cost":["baseline coverage unknown"]}'
a5 "baseline lacks clocks.complete (not inferred from wall_basis=verified)" "$TMP/cs" 'del b["clocks"]["complete"]' "$unk3" "$unkr"
eq "F1: factor still computed without clocks.complete" "$TMP/a5.json" baseline.factors.learn.wall_per_unit_x 1
a5 "baseline clocks.complete not a boolean" "$TMP/cs" 'b["clocks"]["complete"]="true"' "$unk3" "$unkr"
a5 "baseline lacks class row shared_wall (not read as false)" "$TMP/cs" 'del b["per_class"]["learn"]["shared_wall"]' "$unk3" "$unkr"
eq "F1: factor still computed without shared_wall" "$TMP/a5.json" baseline.factors.learn.cost_per_unit_x 1
a5 "baseline shared_wall not a boolean" "$TMP/cs" 'b["per_class"]["learn"]["shared_wall"]=0' "$unk3" "$unkr"
a5 "baseline lacks clocks.wall_basis (top-level copy is not consulted)" "$TMP/cs" 'b["wall_basis"]=b["clocks"].pop("wall_basis")' "$unk3" "$unkr"
a5 "wall basis differs" "$TMP/cs" 'b["clocks"]["wall_basis"]="window"' '{"wall":false,"agent_active":false,"cost":false}' '{"wall":["wall basis differs"],"agent_active":["wall basis differs"],"cost":["wall basis differs"]}'
a5 "current agents unavailable" "$TMP/absent-dir" 'pass' '{"wall":true,"agent_active":false,"cost":true}' '{"agent_active":["agents unavailable (current)"]}'
a5 "current untimed + clipped turns (and orchestrator-less baseline)" "$TMP/ws" 'pass' '{"wall":true,"agent_active":false,"cost":false}' '{"agent_active":["untimed turns (current)"],"cost":["clipped turns (current)"]}'
python3 "$TEL" report --ledger "$TMP/win.ndjson" --run w --sessions "$TMP/ws" --baseline "$TMP/a5b.json" --md "$TMP/a5.md" > /dev/null
grep -q "agent_active NOT comparable (untimed turns (current))" "$TMP/a5.md" && grep -q "cost NOT comparable (clipped turns (current))" "$TMP/a5.md" \
  && pass "A5: Markdown names each metric's failed condition and side" || fail "A5: Markdown reasons missing"

# A11: per-class usage is whole-run, labelled on the line and in the record.
eq "A11: usage_basis recorded" "$R" per_class.learn.usage_basis '"whole-run"'
linehas "$TMP/r.md" '^- .learn.: 2 units' "whole-run" "not attributed" "not additive"
linehas "$TMP/mx.md" '^- .(learn|audit).: 1 units' "whole-run"
linehas "$TMP/b.md" '^- .learn.: wall' "whole-run"
eq "A11: every mixed-class row carries the basis" "$TMP/mx.json" per_class.audit.usage_basis '"whole-run"'

# A12: pre-registration needs ts <= run start AND an earlier ledger line than the run's first run start.
cat > "$TMP/pre.ndjson" << 'EOF2'
{"v":1,"ts":"2025-01-01T09:00:00Z","kind":"estimate","run":"p","unit_class":"learn","units":1,"human_hours":2,"by":"early"}
{"v":1,"ts":"2025-01-01T10:00:00Z","kind":"run","run":"p","edge":"start"}
{"v":1,"ts":"2025-01-01T09:00:00Z","kind":"estimate","run":"p","unit_class":"learn","units":1,"human_hours":3,"by":"backdated"}
{"v":1,"ts":"2025-01-01T10:05:00Z","kind":"unit","run":"p","id":"u","class":"learn","status":"done"}
{"v":1,"ts":"2025-01-01T10:10:00Z","kind":"milestone","run":"p","name":"verified"}
EOF2
python3 "$TEL" report --ledger "$TMP/pre.ndjson" --run p --json "$TMP/pre.json" --md "$TMP/pre.md" > /dev/null
eq "A12: control: early line + early ts is pre-registered" "$TMP/pre.json" estimates.preregistered.#0.by '"early"'
eq "A12: exactly one pre-registered" "$TMP/pre.json" estimates.preregistered.#1 null
eq "A12: backdated late append is unverifiable" "$TMP/pre.json" estimates.unverifiable.#0.by '"backdated"'
python3 - "$TMP/pre.json" "$TMP/ns.json" << 'PY' && pass "A12: every unverifiable record has a reason (ledger order / no run start)" || fail "A12: unverifiable reasons wrong"
import json, sys
a = json.load(open(sys.argv[1]))["estimates"]["unverifiable"]
b = json.load(open(sys.argv[2]))["estimates"]["unverifiable"]
ok = len(a) == 1 and "backdated" in a[0]["reason"] and "ledger" in a[0]["reason"] and "factor_x" not in a[0]
ok = ok and b and all(x["reason"] == "no run start" for x in b)
sys.exit(0 if ok else 1)
PY
linehas "$TMP/pre.md" 'pre-registered estimate' "timestamp and ledger order only" "not proof of prior registration"
linehas "$TMP/pre.md" 'UNVERIFIABLE' "timestamp and ledger order only" "backdated"

# record subcommand appends a valid schema-v1 line.
python3 "$TEL" record --ledger "$TMP/rec/e.ndjson" unit run=q id=u1 class=c status=done
python3 -c 'import json,sys; e=json.loads(open(sys.argv[1]).read()); sys.exit(0 if e["v"]==1 and e["kind"]=="unit" and e["ts"] else 1)' "$TMP/rec/e.ndjson" \
  && pass "record appends a schema-v1 event" || fail "record output invalid"

if [ "$FAILED" -eq 0 ]; then echo "telemetry harness: GREEN"; else echo "telemetry harness: RED" >&2; exit 1; fi
