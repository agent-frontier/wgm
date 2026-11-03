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
eq "gates" "$R" gates '{"count":2,"total_s":180,"failed":1}'
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
  '{"units":2,"wall_min_per_unit":15,"agent_active_min_per_unit":2.75,"cost_per_unit":1.025,"tokens_per_unit":600,"shared_wall":false}'
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
eq "comparable" "$TMP/b.json" baseline.factors.learn.comparable true
eq "baseline provenance carried" "$TMP/b.json" baseline.factors.learn.baseline_provenance '"reconstructed"'
grep -q "not newly measured" "$TMP/b.md" && pass "reconstructed baseline flagged in Markdown" || fail "reconstructed flag missing"

# Baseline without provenance/complete: unspecified; complete only if wall_basis verified; differing basis -> not comparable.
cat > "$TMP/base2.json" << 'EOF2'
{"run":"b1","wall_basis":"window","per_class":{"learn":{"wall_min_per_unit":30,"agent_active_min_per_unit":5.5,"cost_per_unit":2.05,"shared_wall":false}}}
EOF2
python3 "$TEL" report --ledger "$L" --run r1 --sessions "$TMP/s" --orchestrator-session "$TMP/orch/o.jsonl" \
  --baseline "$TMP/base2.json" --json "$TMP/b2.json" > /dev/null
eq "unspecified provenance" "$TMP/b2.json" baseline.provenance '"unspecified"'
eq "not comparable when basis differs/incomplete" "$TMP/b2.json" baseline.factors.learn.comparable false
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
eq "negative span excluded from gate totals" "$TMP/neg.json" gates '{"count":0,"total_s":0,"failed":0}'

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
eq "span key pairs start/end" "$TMP/sp.json" gates '{"count":1,"total_s":60,"failed":0}'

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
printf '%s\n' '{"type":"message","timestamp":"2025-01-01T10:35:00Z","message":{"role":"user"}}' >> "$TMP/orch/o2.jsonl"
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
eq "mixed: not comparable despite complete + same basis" "$TMP/mx.json" baseline.factors.learn.comparable false
grep -q "NOT comparable (partial, shared-wall" "$TMP/mx.md" && pass "mixed: Markdown gives the not-comparable reason" || fail "mixed: Markdown lacks reason"
# A shared-wall BASELINE against a single-class current run is also not comparable.
printf '%s\n' '{"run":"sb","clocks":{"wall_basis":"verified","complete":true},"per_class":{"learn":{"wall_min_per_unit":40,"agent_active_min_per_unit":1,"cost_per_unit":1,"shared_wall":true}}}' > "$TMP/sb.json"
python3 "$TEL" report --ledger "$L" --run r1 --baseline "$TMP/sb.json" --json "$TMP/sb-out.json" > /dev/null
eq "shared-wall baseline: not comparable" "$TMP/sb-out.json" baseline.factors.learn.comparable false

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

# record subcommand appends a valid schema-v1 line.
python3 "$TEL" record --ledger "$TMP/rec/e.ndjson" unit run=q id=u1 class=c status=done
python3 -c 'import json,sys; e=json.loads(open(sys.argv[1]).read()); sys.exit(0 if e["v"]==1 and e["kind"]=="unit" and e["ts"] else 1)' "$TMP/rec/e.ndjson" \
  && pass "record appends a schema-v1 event" || fail "record output invalid"

if [ "$FAILED" -eq 0 ]; then echo "telemetry harness: GREEN"; else echo "telemetry harness: RED" >&2; exit 1; fi
