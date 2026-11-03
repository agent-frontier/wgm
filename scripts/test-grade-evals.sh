#!/usr/bin/env bash
#
# wgm/test-grade-evals.sh — deterministic backpressure for scripts/grade-evals.sh.
#
# Exercises the plumbing (arg parsing, error paths, prompt embedding, grading.json shape, the
# fence-stripping JSON fallback, and the --baseline accept/regression gate) with a fake agent in a
# throwaway git repo, so grade-evals.sh has a real pass/fail signal without spending real agent/API
# calls. It does not (and cannot) assert real grading quality — that is still human/LLM judgment;
# this only proves the invocation, gate arithmetic, and exit codes are correct.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADE_SRC="$ROOT/scripts/grade-evals.sh"

FAILED=0
ASSERTIONS=0
pass() { ASSERTIONS=$((ASSERTIONS + 1)); printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts" "$TMP/evals"
cp "$GRADE_SRC" "$TMP/scripts/grade-evals.sh"
chmod +x "$TMP/scripts/grade-evals.sh"
GRADE="$TMP/scripts/grade-evals.sh"

cd "$TMP"
git init -q
git config user.email "wgm-test@example.com"
git config user.name "wgm test"

printf '%s\n' "base skill content, no marker" > SKILL.md
cat > evals/evals.json << 'EOF'
{
  "skill_name": "fake",
  "evals": [
    {
      "id": "case-1",
      "prompt": "do the thing",
      "expected_output": "a helpful response demonstrating both behaviors",
      "assertions": ["has widget", "has gadget"]
    }
  ]
}
EOF
git add -A && git commit -qm "v1: no marker"
SHA_V1="$(git rev-parse HEAD)"

# Fake agent: task response depends on $FAKE_MARKER (only reacts to it when set, so unrelated
# tests get a deterministic partial-pass response regardless of SKILL.md content); grader response
# is a genuine substring check on the embedded transcript (not hardcoded to either revision); an
# optional $FAKE_BREAK_GRADER=1 returns unparseable prose to exercise the fallback/error path.
cat > fake_agent.sh << 'EOF'
#!/usr/bin/env bash
prompt="$1"
if [[ "$prompt" == *"You are grading a transcript"* ]]; then
  # Optional response sequence exercises the shipped grader, including revision/case asymmetry.
  if [[ -n "${FAKE_GRADES_DIR:-}" ]]; then
    n="$(cat "$FAKE_GRADES_DIR/count" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s\n' "$n" > "$FAKE_GRADES_DIR/count"
    cat "$FAKE_GRADES_DIR/$n"
    exit 0
  fi
  if [[ "${FAKE_BREAK_GRADER:-0}" == "1" ]]; then
    echo "sorry, I can't produce JSON right now — here is prose instead."
    exit 0
  fi
  if [[ "$prompt" == *"GADGET"* ]]; then
    printf '%s\n' '{"expectations":[{"text":"has widget","passed":true,"evidence":"WIDGET seen"},{"text":"has gadget","passed":true,"evidence":"GADGET seen"}]}'
  else
    printf '%s\n' '{"expectations":[{"text":"has widget","passed":true,"evidence":"WIDGET seen"},{"text":"has gadget","passed":false,"evidence":"GADGET missing"}]}'
  fi
else
  if [[ -n "${FAKE_MARKER:-}" && "$prompt" == *"$FAKE_MARKER"* ]]; then
    echo "Response: WIDGET GADGET both present."
  else
    echo "Response: WIDGET only."
  fi
fi
EOF
chmod +x fake_agent.sh
FAKE="$TMP/fake_agent.sh"

OUT=""; RC=0
run() {  # run grade-evals.sh, capturing combined output + exit code without tripping set -e
  set +e
  OUT="$("$GRADE" "$@" 2>&1)"; RC=$?
  set -e
}
run_dir_of() {  # extract the "Run directory: X" path from captured $OUT
  sed -n 's/^Run directory: //p' <<<"$OUT" | head -1
}

# 1) --help prints usage and exits 0
run --help
if [[ "$RC" -eq 0 ]] && grep -q "Usage:" <<<"$OUT"; then
  pass "--help prints usage and exits 0"
else
  fail "--help did not behave as expected (rc=$RC)"
fi

# 2) no agent configured -> exit 2 with a clear message
run
if [[ "$RC" -eq 2 ]] && grep -q "No agent configured" <<<"$OUT"; then
  pass "rejects with no agent configured"
else
  fail "did not reject missing agent config (rc=$RC)"
fi

# 3) unknown eval id -> exit 2
run nonexistent-id -- "$FAKE"
if [[ "$RC" -eq 2 ]] && grep -q "not found" <<<"$OUT"; then
  pass "rejects an unknown eval id"
else
  fail "did not reject an unknown eval id (rc=$RC)"
fi

# 4) a normal run grades against the fixture's assertions and reports a partial pass rate
unset FAKE_MARKER FAKE_BREAK_GRADER
run case-1 -- "$FAKE"
if [[ "$RC" -eq 0 ]] && grep -q "candidate: 1/2" <<<"$OUT"; then
  RD="$(run_dir_of)"
  if [[ -f "$RD/case-1/candidate/grading.json" ]] && \
     [[ "$(jq -r '.summary.total' "$RD/case-1/candidate/grading.json")" == "2" ]] && \
     [[ "$(jq -r '.summary.passed' "$RD/case-1/candidate/grading.json")" == "1" ]]; then
    pass "grades a case and writes a grading.json matching the expectations+summary shape"
  else
    fail "grading.json missing or has an unexpected shape"
  fi
else
  fail "normal run did not produce the expected 1/2 pass rate (rc=$RC)"
fi

# 5) an unparseable grader response degrades to a recorded error, not a crash
export FAKE_BREAK_GRADER=1
run case-1 -- "$FAKE"
unset FAKE_BREAK_GRADER
if [[ "$RC" -eq 0 ]]; then
  RD="$(run_dir_of)"
  if [[ "$(jq -r '.summary.total' "$RD/case-1/candidate/grading.json")" == "0" ]] && \
     [[ -n "$(jq -r '.error // empty' "$RD/case-1/candidate/grading.json")" ]]; then
    pass "an unparseable grader response degrades to a recorded error, not a crash"
  else
    fail "malformed grader output was not handled as expected"
  fi
else
  fail "malformed grader output caused a non-zero exit (rc=$RC)"
fi

# 6) --baseline: a genuinely better candidate gates ACCEPT (exit 0)
printf '%s\n' "base skill content, no marker" "MARKER_NEW" > SKILL.md
export FAKE_MARKER="MARKER_NEW"
run case-1 --baseline "$SHA_V1" -- "$FAKE"
unset FAKE_MARKER
if [[ "$RC" -eq 0 ]] && grep -q "GATE: ACCEPT" <<<"$OUT"; then
  pass "a genuinely better candidate gates ACCEPT against baseline"
else
  fail "expected GATE: ACCEPT for a better candidate (rc=$RC)"
fi

git add -A && git commit -qm "v2: with marker"
SHA_V2="$(git rev-parse HEAD)"

# 7) --baseline: a genuinely worse candidate gates REGRESSION (exit 1)
printf '%s\n' "base skill content, no marker" > SKILL.md
export FAKE_MARKER="MARKER_NEW"
run case-1 --baseline "$SHA_V2" -- "$FAKE"
unset FAKE_MARKER
if [[ "$RC" -eq 1 ]] && grep -q "GATE: REGRESSION" <<<"$OUT"; then
  pass "a genuinely worse candidate gates REGRESSION against baseline"
else
  fail "expected GATE: REGRESSION for a worse candidate (rc=$RC)"
fi

# The agent runs in a throwaway sandbox OUTSIDE the repo. Grading prompts describe BUILD tasks, and
# a tool-enabled agent carries them out for real: one run created a whole project and committed it
# into the repo under test. Capturing stdout does not make the call side-effect-free, so the agent's
# working directory is the actual control. This fake agent writes a marker into its CWD; the marker
# must never land in the repo grade-evals.sh cd'd to ($TMP here).
rm -f "$TMP/sandbox-canary.txt"
run case-1 --agent "printf 'probe' > sandbox-canary.txt; printf '%s' 'noop'"
if [[ ! -e "$TMP/sandbox-canary.txt" ]]; then
  pass "agent calls run in a sandbox; a file the agent writes never lands in the repo"
else
  fail "the agent wrote sandbox-canary.txt into the repo working directory — sandboxing regressed"
  rm -f "$TMP/sandbox-canary.txt"
fi

# 9) the throwaway sandbox directory name is blinded (no eval/grade/judge/test cues in pwd)
run case-1 --agent 'pwd; printf "%s" "{\"expectations\":[{\"text\":\"has widget\",\"passed\":true,\"evidence\":\"ok\"}]}"'
RD="$(run_dir_of)"
CAND_PWD="$(head -n 1 "$RD/case-1/candidate/response.txt" 2>/dev/null || true)"
if [[ -n "$CAND_PWD" ]] && ! grep -qiE '(eval|grade|judge|benchmark|rubric|candidate)' <<<"$(basename "$CAND_PWD")"; then
  pass "candidate sandbox directory basename is blinded against evaluation-cue keywords"
else
  fail "candidate sandbox directory leaked evaluation cues in basename: '$CAND_PWD'"
fi

# 10) GIT_CEILING_DIRECTORIES isolates the sandbox even when TMPDIR sits inside a git repository
mkdir -p "$TMP/in-repo-tmp"
TMPDIR="$TMP/in-repo-tmp" run case-1 --agent 'if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo "IN_GIT"; else echo "ISOLATED"; fi; printf "%s" "{\"expectations\":[{\"text\":\"has widget\",\"passed\":true,\"evidence\":\"ok\"}]}"'
RD="$(run_dir_of)"
GIT_CHECK="$(head -n 1 "$RD/case-1/candidate/response.txt" 2>/dev/null || true)"
if [[ "$GIT_CHECK" == "ISOLATED" ]]; then
  pass "GIT_CEILING_DIRECTORIES prevents a candidate sandbox inside TMPDIR from reading parent git history"
else
  fail "candidate sandbox inside a parent git tree leaked git context: '$GIT_CHECK'"
fi

# Malformed instruments are not failed model answers. Every mutation below must retain raw
# evidence, disclose incomplete informational coverage, and block a baseline gate, not shrink
# the checklist to a convincing 1/1. No provider is involved.
mkdir -p "$TMP/grades" "$TMP/payloads"
python3 - "$TMP/payloads" <<'PY'
import copy
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
valid = {"expectations": [
    {"text": "has widget", "passed": True, "evidence": "WIDGET seen"},
    {"text": "has gadget", "passed": False, "evidence": "GADGET missing"},
]}
payloads = {}
for name, value in [
    ("omitted", valid["expectations"][:1]),
    ("extra", valid["expectations"] + [valid["expectations"][0]]),
    ("duplicate", [valid["expectations"][0]] * 2),
    ("wrong-order", list(reversed(valid["expectations"]))),
    ("empty-array", []),
    ("array-type", {}),
]:
    payloads[name] = json.dumps({"expectations": value})
for name, key, value in [
    ("wrong-text", "text", "invented"),
    ("text-type", "text", 42),
    ("passed-string", "passed", "true"),
    ("passed-number", "passed", 1),
    ("passed-null", "passed", None),
    ("evidence-empty", "evidence", ""),
    ("evidence-whitespace", "evidence", " \t\r\n"),
    ("evidence-unicode-space", "evidence", "\u00a0\u2003"),
    ("evidence-type", "evidence", []),
]:
    changed = copy.deepcopy(valid)
    changed["expectations"][0][key] = value
    payloads[name] = json.dumps(changed)
for key in ("text", "passed", "evidence"):
    changed = copy.deepcopy(valid)
    del changed["expectations"][0][key]
    payloads["missing-" + key] = json.dumps(changed)
payloads.update({
    "empty": "",
    "prose": "not JSON",
    "missing-expectations": "{}",
    "null": "null",
    "top-array": json.dumps([valid]),
    "item-type": '{"expectations":[null,42]}',
    "multiple-documents": json.dumps(valid) + "\n" + json.dumps(valid),
    "fenced-multiple": "```json\n" + json.dumps(valid) + "\n{}\n```",
})
for name, raw in payloads.items():
    (root / name).write_text(raw + "\n")
(root / "valid").write_text(json.dumps(valid) + "\n")
forged = copy.deepcopy(valid)
forged["summary"] = {"passed": 900, "total": 900, "pass_rate": 1}
(root / "forged").write_text(json.dumps(forged) + "\n")
(root / "fenced").write_text("```json\n" + json.dumps(valid) + "\n```\n")
(root / "invalid-names").write_text("\n".join(payloads) + "\n")
PY

export FAKE_GRADES_DIR="$TMP/grades"
sequence() {
  local n=0 payload
  printf '0\n' > "$FAKE_GRADES_DIR/count"
  for payload in "$@"; do
    n=$((n + 1))
    cp "$TMP/payloads/$payload" "$FAKE_GRADES_DIR/$n"
  done
}
error_artifacts() {
  local dir="$1" payload="$2"
  [[ -f "$dir/grader_raw.txt" ]] &&
    cmp -s "$TMP/payloads/$payload" "$dir/grader_raw.txt" &&
    jq -e '.expectations == [] and (.error | type == "string" and length > 0)
      and .summary == {passed:0, failed:0, total:0, pass_rate:0}' "$dir/grading.json" >/dev/null
}
while IFS= read -r mutation; do
  sequence "$mutation"
  run case-1 -- "$FAKE"
  RD="$(run_dir_of)"
  if [[ "$RC" -eq 0 ]] && grep -qi 'candidate:.*ungraded.*error' <<<"$OUT" &&
     grep -qi 'incomplete' <<<"$OUT" &&
     error_artifacts "$RD/case-1/candidate" "$mutation"; then
    pass "$mutation: informational error preserves raw output and discloses incomplete coverage"
  else
    fail "$mutation: informational error/coverage/artifacts incorrect (rc=$RC)"
  fi
  sequence "$mutation" "$mutation"
  run case-1 --baseline "$SHA_V1" -- "$FAKE"
  RD="$(run_dir_of)"
  if [[ "$RC" -eq 2 ]] && grep -q 'GATE: ERROR' <<<"$OUT" &&
     ! grep -qE 'GATE: (ACCEPT|REGRESSION)' <<<"$OUT" &&
     error_artifacts "$RD/case-1/candidate" "$mutation" &&
     error_artifacts "$RD/case-1/baseline" "$mutation"; then
    pass "$mutation: invalid grades on both revisions block baseline comparison"
  else
    fail "$mutation: expected baseline ERROR, retained artifacts (rc=$RC): $OUT"
  fi
done < "$TMP/payloads/invalid-names"

for side in candidate baseline; do
  if [[ "$side" == candidate ]]; then sequence omitted valid; else sequence valid omitted; fi
  run case-1 --baseline "$SHA_V1" -- "$FAKE"
  RD="$(run_dir_of)"
  if [[ "$RC" -eq 2 ]] && grep -q 'GATE: ERROR' <<<"$OUT" &&
     grep -qi "$side:.*ungraded.*error" <<<"$OUT" &&
     ! grep -qE 'GATE: (ACCEPT|REGRESSION)' <<<"$OUT" &&
     error_artifacts "$RD/case-1/$side" omitted; then
    pass "$side-only invalid grade blocks comparison"
  else
    fail "$side-only invalid grade did not block comparison (rc=$RC)"
  fi
done

# Valid payloads after invalid ones must recover; summary forgery cannot change arithmetic.
for payload in valid forged fenced; do
  sequence "$payload" valid
  run case-1 --baseline "$SHA_V1" -- "$FAKE"
  RD="$(run_dir_of)"
  if [[ "$RC" -eq 0 ]] && grep -q 'GATE: ACCEPT' <<<"$OUT" &&
     jq -e '.summary == {passed:1, failed:1, total:2, pass_rate:0.5}
       and (.expectations | length == 2) and (has("error") | not)' \
       "$RD/case-1/candidate/grading.json" >/dev/null; then
    pass "$payload: valid equal comparison recovers with locally computed summary"
  else
    fail "$payload: valid comparison/summary incorrect (rc=$RC)"
  fi
done

# Keep aggregate counts from valid cases, but never let them hide a missing measurement.
jq '.evals += [.evals[0] | .id = "case-2"]' evals/evals.json > evals/two.json
mv evals/two.json evals/evals.json
for side in candidate baseline; do
  if [[ "$side" == candidate ]]; then sequence valid valid omitted valid
  else sequence valid valid valid omitted; fi
  run --baseline "$SHA_V1" -- "$FAKE"
  if [[ "$RC" -eq 2 ]] && grep -q 'GATE: ERROR' <<<"$OUT" &&
     grep -q "grading 'case-2'" <<<"$OUT" && grep -qi incomplete <<<"$OUT" &&
     ! grep -qE 'GATE: (ACCEPT|REGRESSION)' <<<"$OUT"; then
    pass "mixed cases: valid first case cannot hide invalid $side second case"
  else
    fail "mixed cases hid invalid $side grade (rc=$RC)"
  fi
done
sequence valid valid valid valid
run --baseline "$SHA_V1" -- "$FAKE"
if [[ "$RC" -eq 0 ]] && grep -q 'GATE: ACCEPT' <<<"$OUT" &&
   grep -q 'Overall candidate pass_rate: 2/4' <<<"$OUT"; then
  pass "multiple valid cases recover and aggregate without changing denominators"
else
  fail "multiple valid cases did not recover/aggregate (rc=$RC)"
fi
unset FAKE_GRADES_DIR

# ---- Attribution recording (docs audit A6; `[learn]` #147) ----------------------------------------
# Real runner, fake agents. Each agent call gets a private neutral TMPDIR inside its sandbox; the task
# call's spill/notice/refusal counts land in attribution.json as a DIAGNOSTIC that never touches scores.
TMPDIR_ORIG="${TMPDIR:-}"
OUTER="$TMP/outer"; mkdir -p "$OUTER"
REAL_RM="$(command -v rm)"
export FAKE
cat > attr_agent.sh << 'EOF'
#!/usr/bin/env bash
prompt="$1"
if [[ -n "${T20_OUT:-}" ]]; then readlink /proc/$$/fd/1 >> "$T20_OUT"; readlink /proc/$$/fd/2 >> "$T20_OUT"; fi
if [[ "$prompt" != *"You are grading a transcript"* ]]; then
  case "${ATTR_MODE:-}" in
    spill)     echo spilled > "$TMPDIR/spill.txt" ;;
    spillfail) echo spilled > "$TMPDIR/spill.txt"; exit 3 ;;
    plainfail) exit 3 ;;
    locked)    mkdir "$TMPDIR/locked"; echo x > "$TMPDIR/locked/f"; chmod 0555 "$TMPDIR/locked" ;;
    hang)      exec -a "$ATTR_MARK" sleep 30 ;;
    fdpaths)   : ;;
    unreadout) echo "NOTICE: saved to a temp file; use view or grep"; echo "REFUSED: tool nope"; chmod 000 /proc/$$/fd/1 ;;
    unreadable) chmod 000 /proc/self/fd/2 ;;
    late)      echo $$ > "$ATTR_PIDFILE"; ( trap '' TERM; exec -a "$ATTR_MARK" sleep 60 ) & ;;
    hang2)     n="$(cat "$ATTR_COUNT" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$ATTR_COUNT"
               if (( n == 2 )); then : > "$ATTR_CKPT"; exec -a "$ATTR_MARK" sleep 30; fi ;;
    notice)    echo "NOTICE: saved to a temp file; use view or grep"; echo "REFUSED: tool nope is not available" ;;
    stderr)    echo "NOTICE: saved to a temp file; use view or grep" >&2; echo "REFUSED: tool nope is not available" >&2 ;;
    unenum)    mkdir "$TMPDIR/sealed"; echo x > "$TMPDIR/sealed/f"; chmod 000 "$TMPDIR/sealed" ;;
    where)     echo "TMPDIR=$TMPDIR"; echo "PWD=$(pwd)" ;;
  esac
fi
exec "$FAKE" "$prompt"
EOF
chmod +x attr_agent.sh
ATTR="$TMP/attr_agent.sh"
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/rm" << 'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == */workspace.* && "$a" != */.tmp* ]]; then
    : > "$RM_CHECKPOINT"
    bash -c 'exec -a "$0" sleep 30' "$ATTR_MARK"
    break
  fi
done
exec "$REAL_RM" "$@"
EOF
chmod +x "$TMP/fakebin/rm"
export REAL_RM
unset FAKE_MARKER FAKE_BREAK_GRADER FAKE_GRADES_DIR WGM_HARNESS_NOTICE_REGEX WGM_REFUSED_TOOL_REGEX ATTR_MODE
export TMPDIR="$OUTER"

attr() { jq -c "$1" "$RD/case-1/candidate/attribution.json" 2>/dev/null || echo missing; }
sandboxes_left() { find "$OUTER" -maxdepth 1 -name 'workspace.*' | wc -l | tr -d ' '; }
norm() { local t="${OUT//$RD/RUN}"; grep -v '^Run directory' <<<"$t"; }

# T1: a CLI that spills into $TMPDIR is contained in the sandbox, counted, and removed with it.
export ATTR_MODE=spill
run case-1 -- "$ATTR"; RD="$(run_dir_of)"
if [[ "$RC" -eq 0 && "$(attr .spill_files)" == "1" && -z "$(find "$OUTER" -name spill.txt)" && "$(sandboxes_left)" == "0" ]]; then
  pass "T1 spill: private TMPDIR contains the spill file, attribution.json counts it, sandbox removed"
else
  fail "T1 spill containment/count wrong (rc=$RC, spill_files=$(attr .spill_files))"
fi
unset ATTR_MODE

# T2/T3: notice and refusal counts have three states: unset -> null, set+match -> >=1, set+no match -> 0.
export ATTR_MODE=notice
for pair in "harness_notices:WGM_HARNESS_NOTICE_REGEX:saved to a temp file" "refused_tool_attempts:WGM_REFUSED_TOOL_REGEX:REFUSED:"; do
  IFS=: read -r field var rx <<<"$pair"
  t=T2; [[ "$field" == refused_tool_attempts ]] && t=T3
  run case-1 -- "$ATTR"; RD="$(run_dir_of)"; unset_v="$(attr ".$field")"
  env "$var=$rx" "$GRADE" case-1 -- "$ATTR" >"$TMP/o1" 2>&1 || true
  RD="$(sed -n 's/^Run directory: //p' "$TMP/o1" | head -1)"; match_v="$(attr ".$field")"
  env "$var=ZZZ-no-such-text" "$GRADE" case-1 -- "$ATTR" >"$TMP/o2" 2>&1 || true
  RD="$(sed -n 's/^Run directory: //p' "$TMP/o2" | head -1)"; none_v="$(attr ".$field")"
  if [[ "$unset_v" == "null" && "$match_v" =~ ^[1-9][0-9]*$ && "$none_v" == "0" ]]; then
    pass "$t $field: unset=null, matching=$match_v, non-matching=0"
  else
    fail "$t $field states wrong (unset=$unset_v match=$match_v none=$none_v)"
  fi
done
unset ATTR_MODE

# T4: an invalid classifier regex is recorded as classifier-error with a warning, and cannot change grading.
run case-1 -- "$ATTR"; RD="$(run_dir_of)"; BASE_RC="$RC"; BASE_OUT="$(norm)"; BASE_G="$(jq -S . "$RD/case-1/candidate/grading.json")"
for var in WGM_HARNESS_NOTICE_REGEX WGM_REFUSED_TOOL_REGEX; do
  field=harness_notices; [[ "$var" == WGM_REFUSED_TOOL_REGEX ]] && field=refused_tool_attempts
  rc=0
  env "$var=(" "$GRADE" case-1 -- "$ATTR" >"$TMP/o1" 2>&1 || rc=$?
  RD="$(sed -n 's/^Run directory: //p' "$TMP/o1" | head -1)"
  if [[ "$(attr ".$field")" == '"classifier-error"' ]] && grep -q "attribution: invalid $var" "$TMP/o1" &&
     [[ "$rc" == "$BASE_RC" && "$(jq -S . "$RD/case-1/candidate/grading.json")" == "$BASE_G" ]] &&
     [[ "$(sed "s|$RD|RUN|g" "$TMP/o1" | grep -v -e '^Run directory' -e '^attribution:')" == "$BASE_OUT" ]]; then
    pass "T4 $var invalid: classifier-error recorded with warning; grading.json, output, exit unchanged"
  else
    fail "T4 $var invalid regex changed behavior or was not reported (rc=$rc)"
  fi
done

# T5: classifier settings (valid or invalid) cannot change gate verdicts or grading.json bytes.
t5_case() {  # $1 label; expects SKILL.md/baseline/env prepared by caller via $2 = baseline sha
  local label="$1" sha="$2" rc0 rc1 rc2 out0 out1 out2 g0 g1 g2 rd0 rd1 rd2
  run case-1 --baseline "$sha" -- "$FAKE"; rc0=$RC; rd0="$(run_dir_of)"; out0="$(t="${OUT//$rd0/RUN}"; grep -v '^Run directory' <<<"$t")"
  g0="$(cat "$rd0"/case-1/*/grading.json)"
  rc1=0; rc2=0
  env WGM_HARNESS_NOTICE_REGEX='WIDGET' WGM_REFUSED_TOOL_REGEX='only' "$GRADE" case-1 --baseline "$sha" -- "$FAKE" >"$TMP/o1" 2>&1 || rc1=$?
  rd1="$(sed -n 's/^Run directory: //p' "$TMP/o1")"; out1="$(sed "s|$rd1|RUN|g" "$TMP/o1" | grep -v '^Run directory')"; g1="$(cat "$rd1"/case-1/*/grading.json)"
  env WGM_HARNESS_NOTICE_REGEX='(' WGM_REFUSED_TOOL_REGEX='[' "$GRADE" case-1 --baseline "$sha" -- "$FAKE" >"$TMP/o2" 2>&1 || rc2=$?
  rd2="$(sed -n 's/^Run directory: //p' "$TMP/o2")"; out2="$(sed "s|$rd2|RUN|g" "$TMP/o2" | grep -v -e '^Run directory' -e '^attribution:')"; g2="$(cat "$rd2"/case-1/*/grading.json)"
  if [[ "$rc0" == "$T5_EXPECT" && "$rc1" == "$rc0" && "$rc2" == "$rc0" && "$out0" == "$out1" && "$out0" == "$out2" &&
        "$g0" == "$g1" && "$g0" == "$g2" ]] && grep -q "$T5_VERDICT" <<<"$out0" && [[ -f "$rd1/case-1/candidate/attribution.json" ]]; then
    pass "T5 $label: exit $rc0 and verdict identical with valid/invalid classifier regexes; grading.json byte-identical"
  else
    fail "T5 $label: classifier regexes changed behavior (rc $rc0/$rc1/$rc2, want $T5_EXPECT)"
  fi
}
printf '%s\n' "base skill content, no marker" "MARKER_NEW" > SKILL.md
export FAKE_MARKER="MARKER_NEW"; T5_EXPECT=0; T5_VERDICT="GATE: ACCEPT"; t5_case ACCEPT "$SHA_V1"
printf '%s\n' "base skill content, no marker" > SKILL.md
T5_EXPECT=1; T5_VERDICT="GATE: REGRESSION"; t5_case REGRESSION "$SHA_V2"
unset FAKE_MARKER
export FAKE_BREAK_GRADER=1; T5_EXPECT=2; T5_VERDICT="GATE: ERROR"; t5_case ERROR "$SHA_V1"
unset FAKE_BREAK_GRADER

# T6: a failing task agent still gets its attribution written and sandbox removed; disposition matches a spill-free failure.
export ATTR_MODE=plainfail
run case-1 -- "$ATTR"; RD="$(run_dir_of)"; P_RC="$RC"; P_OUT="$(norm)"
export ATTR_MODE=spillfail
run case-1 -- "$ATTR"; RD="$(run_dir_of)"
if [[ "$(attr .spill_files)" == "1" && "$(sandboxes_left)" == "0" && "$RC" == "$P_RC" && "$RC" -ne 0 &&
      "$(norm)" == "$P_OUT" && ! -e "$RD/case-1/candidate/grading.json" ]]; then
  pass "T6 agent failure: attribution.json written (spill_files 1), sandbox removed, exit/disposition unchanged"
else
  fail "T6 agent failure handling wrong (rc=$RC vs $P_RC, spill_files=$(attr .spill_files))"
fi
unset ATTR_MODE

# T7: a sandbox that cannot be fully removed is reported and recorded, and the run still completes with scoring unchanged.
export ATTR_MODE=locked
run case-1 -- "$ATTR"; RD="$(run_dir_of)"
RET="$(sed -n 's/^retained: //p' <<<"$OUT" | head -1)"
if [[ "$(id -u)" == 0 ]]; then
  pass "T7 cleanup failure: skipped visibly because root can remove a 0555 directory"
elif [[ "$RC" -eq 0 && -n "$RET" && "$(attr .retained_path)" == "\"$RET\"" ]] && grep -q 'candidate: 1/2' <<<"$OUT" &&
     jq -e '(.summary.pass_rate | tonumber) == 0.5' "$RD/case-1/candidate/grading.json" >/dev/null; then
  pass "T7 cleanup failure: run completes, retained path reported and recorded, scoring unchanged"
else
  fail "T7 cleanup failure handling wrong (rc=$RC, retained='$RET')"
fi
[[ -n "$RET" && -d "$RET" ]] && { chmod -R u+rwx "$RET"; "$REAL_RM" -rf "$RET"; }
unset ATTR_MODE

# Helper: start grade-evals.sh in the background (own process group, so SIGINT is deliverable), send $TERM_SIG
# (default TERM), and report its exact exit status; TERM_RC=999 means it was still alive after 10 s.
TERM_ARGS=(); TERM_PREFIX=(); TERM_SIGIGN_BAD=0
term_run() {  # $1 = checkpoint file to wait for ("" = sleep 1 s); extra env comes from the caller
  local pid i dead=0
  set -m
  "${TERM_PREFIX[@]}" "$GRADE" case-1 "${TERM_ARGS[@]}" -- "$ATTR" >"$TMP/o1" 2>&1 &
  pid=$!
  set +m
  if [[ -n "$1" ]]; then for ((i = 0; i < 100; i++)); do [[ -e "$1" ]] && break; sleep 0.1; done; else sleep 1; fi
  TERM_SIGIGN_BAD=0
  if [[ "${TERM_SIG:-TERM}" == INT && -r "/proc/$pid/status" ]]; then
    # Self-validating precondition: a runner that inherited SIGINT as ignored can never see it.
    local mask; mask="$(awk '/^SigIgn:/{print $2}' "/proc/$pid/status")"
    if (( 0x${mask:-0} & 2 )); then TERM_SIGIGN_BAD=1; fi
  fi
  if [[ -n "${TERM_LEADER_PIDFILE:-}" ]]; then   # wait until the task leader has exited, runner still active
    local lp st
    for ((i = 0; i < 100; i++)); do [[ -s "$TERM_LEADER_PIDFILE" ]] && break; sleep 0.05; done
    lp="$(cat "$TERM_LEADER_PIDFILE" 2>/dev/null || echo 0)"
    for ((i = 0; i < 200; i++)); do st="$(ps -o stat= -p "$lp" 2>/dev/null | tr -d " " || true)"; [[ -z "$st" || "$st" == Z* ]] && break; sleep 0.02; done
  fi
  TERM_ACTIVE=0; kill -0 "$pid" 2>/dev/null && TERM_ACTIVE=1
  kill -"${TERM_SIG:-TERM}" "$pid" 2>/dev/null || true
  for ((i = 0; i < 100; i++)); do kill -0 "$pid" 2>/dev/null || { dead=1; break; }; sleep 0.1; done
  if (( dead )); then TERM_RC=0; wait "$pid" 2>/dev/null || TERM_RC=$?; else kill -KILL "$pid" 2>/dev/null; pkill -KILL -f "$ATTR_MARK" 2>/dev/null; TERM_RC=999; fi
  OUT="$(cat "$TMP/o1")"; RD="$(run_dir_of)"
}
sweep_sandboxes() { find "$OUTER" -maxdepth 1 -name 'workspace.*' -exec "$REAL_RM" -rf {} +; }

# T8: SIGTERM during an agent call exits EXACTLY 143 (never the baseline REGRESSION code 1), kills the agent's whole
# tree, cleans up, and leaves no success-shaped grading.json. Repeated to catch timing dependence.
export ATTR_MODE=hang ATTR_MARK="wgm-hang-$$-$RANDOM"
T8_OK=1; T8_CODES=""
for n in 1 2 3; do
  term_run ""
  T8_CODES="$T8_CODES $TERM_RC"
  if [[ "$TERM_RC" -ne 143 ]] || pgrep -f "$ATTR_MARK" >/dev/null || [[ -e "$RD/case-1/candidate/grading.json" ]] ||
     ! { [[ "$(sandboxes_left)" == "0" ]] || grep -q '^retained: ' <<<"$OUT"; }; then T8_OK=0; fi
  pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
  sweep_sandboxes
done
if (( T8_OK )); then
  pass "T8 interruption x3: exits exactly 143 (codes:$T8_CODES), no agent survives, sandbox removed or reported, no grading.json"
else
  fail "T8 interruption handling wrong (codes:$T8_CODES; want 143 each)"
fi
unset ATTR_MODE

# T14: SIGINT during an agent call exits EXACTLY 130 with the same cleanup guarantees. A background job of a
# non-interactive shell starts with SIGINT ignored (which bash cannot undo), so the runner is launched with SIGINT
# reset to default, and the test fails loudly if the runner's SigIgn mask still has the SIGINT bit.
if env --help 2>&1 | grep -q -e '--default-signal'; then
  TERM_PREFIX=(env --default-signal=INT)
elif command -v python3 >/dev/null 2>&1; then
  TERM_PREFIX=(python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])')
else
  TERM_PREFIX=()
  echo "SKIP: T14 SIGINT (neither env --default-signal nor python3 available to reset an ignored SIGINT)"
fi
if [[ ${#TERM_PREFIX[@]} -gt 0 ]]; then
  export ATTR_MODE=hang
  TERM_SIG=INT term_run ""
  if (( TERM_SIGIGN_BAD )); then
    fail "T14 precondition: runner still has SIGINT ignored (SigIgn bit 0x2) — cannot test SIGINT handling"
  elif [[ "$TERM_RC" -eq 130 ]] && ! pgrep -f "$ATTR_MARK" >/dev/null && ! [[ -e "$RD/case-1/candidate/grading.json" ]] &&
     { [[ "$(sandboxes_left)" == "0" ]] || grep -q '^retained: ' <<<"$OUT"; }; then
    pass "T14 SIGINT: exits exactly 130, no agent survives, sandbox removed or reported, no grading.json"
  else
    fail "T14 SIGINT handling wrong (rc=$TERM_RC; want 130)"
  fi
  pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
  sweep_sandboxes
  TERM_PREFIX=()
fi

# T15: an interrupted --baseline run (signal during the candidate call, then during the baseline call) exits
# EXACTLY 143 — never 1 (REGRESSION) or 2 (ERROR) — with no verdict, no survivor, and no success-shaped grading.json
# for the interrupted revision. Repeated three times per phase.
T15_OK=1; T15_CODES=""
TERM_ARGS=(--baseline "$SHA_V1")
for phase in candidate baseline; do
  for n in 1 2 3; do
    if [[ "$phase" == candidate ]]; then
      export ATTR_MODE=hang; term_run ""
    else
      export ATTR_MODE=hang2 ATTR_COUNT="$TMP/t15-count" ATTR_CKPT="$TMP/t15-ckpt"; rm -f "$ATTR_COUNT" "$ATTR_CKPT"
      term_run "$ATTR_CKPT"
    fi
    T15_CODES="$T15_CODES $phase:$TERM_RC"
    if [[ "$TERM_RC" -ne 143 ]] || pgrep -f "$ATTR_MARK" >/dev/null || grep -qE 'GATE:|REGRESSION on' <<<"$OUT" ||
       [[ -e "$RD/case-1/$phase/grading.json" ]] ||
       ! { [[ "$(sandboxes_left)" == "0" ]] || grep -q '^retained: ' <<<"$OUT"; }; then T15_OK=0; fi
    pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
    sweep_sandboxes
  done
done
TERM_ARGS=()
if (( T15_OK )); then
  pass "T15 interrupted --baseline x3 per phase: exits exactly 143 (${T15_CODES# }), no verdict, no survivor, no success-shaped grading"
else
  fail "T15 interrupted --baseline handling wrong (${T15_CODES# }; want 143 each)"
fi
unset ATTR_MODE ATTR_COUNT ATTR_CKPT

# T16: a task leader that exits 0 while a TERM-ignoring background child (inheriting stdout/stderr) lives on must not
# leave the runner unable to cancel: SIGTERM then exits EXACTLY 143 within 10 s, the whole process group is gone, and
# nothing success-shaped or verdict-shaped is left for that revision. Repeated three times.
T16_OK=1; T16_CODES=""
export ATTR_MODE=late ATTR_MARK="wgm-late-$$-$RANDOM" ATTR_PIDFILE="$TMP/t16-pid"
for n in 1 2 3; do
  rm -f "$ATTR_PIDFILE"
  TERM_LEADER_PIDFILE="$ATTR_PIDFILE" term_run "$ATTR_PIDFILE"
  T16_CODES="$T16_CODES $TERM_RC/active=$TERM_ACTIVE"
  if [[ "$TERM_RC" -ne 143 || "$TERM_ACTIVE" -ne 1 ]] || pgrep -f "$ATTR_MARK" >/dev/null || [[ -e "$RD/case-1/candidate/grading.json" ]] ||
     grep -q 'GATE:' <<<"$OUT" || ! { [[ "$(sandboxes_left)" == "0" ]] || grep -q '^retained: ' <<<"$OUT"; }; then T16_OK=0; fi
  pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
  sweep_sandboxes
done
if (( T16_OK )); then
  pass "T16 late descendant x3: SIGTERM after the leader exited gives exactly 143 (${T16_CODES# }), no survivor, no grading.json"
else
  fail "T16 late descendant cancellation wrong (${T16_CODES# }; want 143/active=1 each, no survivor)"
fi
unset ATTR_MODE

# T17: the same late descendant with NO signal: the run still completes in bounded time, the descendant is terminated
# and counted, and grading.json is identical to a run without it (the diagnostic never touches scoring).
run case-1 -- "$ATTR"; RD="$(run_dir_of)"; Q17_G="$(jq -S . "$RD/case-1/candidate/grading.json")"
export ATTR_MODE=late
T17_START=$SECONDS; T17_RC=0
timeout --kill-after=2 15 "$GRADE" case-1 -- "$ATTR" >"$TMP/o1" 2>&1 || T17_RC=$?
T17_DUR=$((SECONDS - T17_START)); OUT="$(cat "$TMP/o1")"; RD="$(run_dir_of)"
if [[ "$T17_RC" -eq 0 && "$T17_DUR" -lt 15 ]] && ! pgrep -f "$ATTR_MARK" >/dev/null &&
   [[ "$(jq -S . "$RD/case-1/candidate/grading.json" 2>/dev/null)" == "$Q17_G" ]] &&
   [[ "$(attr '.descendants_terminated')" =~ ^[1-9] ]]; then
  pass "T17 late descendant, no signal: completes in ${T17_DUR}s, descendant terminated and counted, grading.json unchanged"
else
  fail "T17 late descendant run wrong (rc=$T17_RC, ${T17_DUR}s, descendants=$(attr '.descendants_terminated'))"
fi
pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
sweep_sandboxes
unset ATTR_MODE ATTR_PIDFILE

# T18: a channel that cannot be read is UNOBSERVED, not "no match": with a notice regex set the classifier reports
# "unavailable" (never 0), the channel is left out of observed_channels, a warning is printed, and grading.json
# and the exit status are unchanged. (A cat read failure must not be folded into grep's "no match" status.)
export WGM_HARNESS_NOTICE_REGEX='saved to a temp file' WGM_REFUSED_TOOL_REGEX='REFUSED:'
run case-1 -- "$ATTR"; RD="$(run_dir_of)"; Q18_G="$(jq -S . "$RD/case-1/candidate/grading.json")"; Q18_RC="$RC"
export ATTR_MODE=unreadable
run case-1 -- "$ATTR"; RD="$(run_dir_of)"
if [[ "$(id -u)" == 0 ]]; then
  pass "T18 unreadable channel: skipped visibly because root can read a 000 file"
elif [[ "$(attr .harness_notices)" == '"unavailable"' && "$(attr .refused_tool_attempts)" == '"unavailable"' &&
        "$(attr .observed_channels)" == '["stdout"]' ]] && grep -q 'attribution: channel unreadable' <<<"$OUT" &&
     [[ "$RC" == "$Q18_RC" && "$(jq -S . "$RD/case-1/candidate/grading.json")" == "$Q18_G" ]]; then
  pass "T18 unreadable channel: classifiers \"unavailable\", channel not listed as observed, warning printed, scoring unchanged"
else
  fail "T18 unreadable channel mishandled (rc=$RC, attr: $(attr .))"
fi
chmod -R u+rwx "$RD" 2>/dev/null || true
unset ATTR_MODE WGM_HARNESS_NOTICE_REGEX WGM_REFUSED_TOOL_REGEX

# T19: the signal handler performs no unbounded removal. A fake rm stalls (marked sleep) only on the RESPONSE file
# path; SIGTERM mid-agent must still exit EXACTLY 143 within 10 s with no survivor and no grading.json.
mkdir -p "$TMP/fakebin2"
cat > "$TMP/fakebin2/rm" << 'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == */.response.* ]]; then bash -c 'exec -a "$0" sleep 30' "$ATTR_MARK"; break; fi
done
exec "$REAL_RM" "$@"
EOF
chmod +x "$TMP/fakebin2/rm"
export ATTR_MODE=hang ATTR_MARK="wgm-t19-$$-$RANDOM"
PATH="$TMP/fakebin2:$PATH" term_run ""
if [[ "$TERM_RC" -eq 143 ]] && ! pgrep -f "$ATTR_MARK" >/dev/null && ! [[ -e "$RD/case-1/candidate/grading.json" ]] &&
   { [[ "$(sandboxes_left)" == "0" ]] || grep -q '^retained: ' <<<"$OUT"; }; then
  pass "T19 stalled response-file removal: handler stays bounded, exits exactly 143, no survivor, no grading.json"
else
  fail "T19 handler not bounded for response-file removal (rc=$TERM_RC; want 143)"
fi
pkill -KILL -f "^$ATTR_MARK" 2>/dev/null || true
sweep_sandboxes
unset ATTR_MODE ATTR_MARK

# T20: blinding of the captured streams. A tool-using agent can `readlink /proc/self/fd/1` and `/2` to see where its
# output is going; those paths must carry no evaluation or arm label (before live capture they were an anonymous
# pipe). The fake agent records both links, during candidate AND baseline calls (task and grader), to a file outside
# the run that only the TEST names.
if [[ ! -d /proc/self/fd ]]; then
  echo "SKIP: T20 stream-path blinding (no /proc)"
else
  T20_OUT="$TMP/t20-paths"; : > "$T20_OUT"; export T20_OUT ATTR_MODE=fdpaths
  run case-1 --baseline "$SHA_V1" -- "$ATTR"
  unset ATTR_MODE
  T20_BAD=""; T20_N=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    T20_N=$((T20_N + 1)); rel="${line#"$OUTER"/}"; [[ "$line" == pipe:* ]] && continue   # anonymous pipe: no label
    if [[ "$rel" == "$line" ]] || grep -qiE '(eval|grade|judge|test|benchmark|candidate|baseline|wgm)' <<<"$rel"; then T20_BAD="$T20_BAD [$line]"; fi
  done < "$T20_OUT"
  if [[ "$RC" -eq 0 && "$T20_N" -ge 8 && -z "$T20_BAD" ]]; then
    pass "T20 blinding: $T20_N stream paths (fd 1/2, candidate+baseline, task+grader) carry no evaluation or arm label"
  else
    fail "T20 stream paths leak labels or are missing (rc=$RC, n=$T20_N):$T20_BAD"
  fi
  unset T20_OUT
fi

# T21: symmetric observation. A task call whose STDOUT capture cannot be read is unobserved: stdout is left out of
# observed_channels, every configured classifier is "unavailable" (not a partial count from stderr), a warning is
# printed, and the case follows the existing strict ungraded/error path (never a pass, never a silently empty
# response), with the cleanup ledger intact. Exit code semantics (informational 0 / baseline ERROR 2) are unchanged.
export WGM_HARNESS_NOTICE_REGEX='saved to a temp file' WGM_REFUSED_TOOL_REGEX='REFUSED:'
export ATTR_MODE=unreadout
run case-1 -- "$ATTR"; RD="$(run_dir_of)"; T21_RC="$RC"; T21_OUT="$OUT"
run case-1 --baseline "$SHA_V1" -- "$ATTR"; T21_BRC="$RC"; T21_BOUT="$OUT"
if [[ "$(id -u)" == 0 ]]; then
  pass "T21 unreadable stdout: skipped visibly because root can read a 000 file"
elif [[ "$(attr .harness_notices)" == '"unavailable"' && "$(attr .refused_tool_attempts)" == '"unavailable"' &&
        "$(attr .observed_channels)" == '["stderr"]' ]] && grep -q 'attribution: channel unreadable (stdout)' <<<"$T21_OUT" &&
     [[ "$T21_RC" -eq 0 ]] && grep -q 'candidate: ungraded/error' <<<"$T21_OUT" && ! grep -q 'candidate: [0-9]' <<<"$T21_OUT" &&
     jq -e '.error != null and .summary.total == 0 and .summary.pass_rate == 0' "$RD/case-1/candidate/grading.json" >/dev/null &&
     [[ "$T21_BRC" -eq 2 ]] && grep -q 'GATE: ERROR' <<<"$T21_BOUT" && ! grep -qE 'GATE: (ACCEPT|REGRESSION)' <<<"$T21_BOUT" &&
     [[ "$(sandboxes_left)" == "0" ]] && ! grep -qP '^created\t' <(awk -F'\t' '{s[$2]=$1} END{for(k in s) if(s[k]=="created") print "created\t" k}' "$RD/sandboxes.tsv"); then
  pass "T21 unreadable stdout: channel unobserved, classifiers \"unavailable\", warning printed, strict ungraded/error (baseline ERROR 2), ledger intact"
else
  fail "T21 unreadable stdout mishandled (rc=$T21_RC/$T21_BRC, attr: $(attr .))"
fi
chmod -R u+rwx "$OUTER" 2>/dev/null || true
sweep_sandboxes
unset ATTR_MODE WGM_HARNESS_NOTICE_REGEX WGM_REFUSED_TOOL_REGEX

# T9: the private temp dir sits inside the sandbox and its name carries no evaluation cue.
export ATTR_MODE=where
run case-1 -- "$ATTR"; RD="$(run_dir_of)"
T_TMP="$(sed -n 's/^TMPDIR=//p' "$RD/case-1/candidate/response.txt" | head -1)"
T_PWD="$(sed -n 's/^PWD=//p' "$RD/case-1/candidate/response.txt" | head -1)"
if [[ -n "$T_TMP" && "$T_TMP" != "$OUTER" && "$(dirname "$T_TMP")" == "$T_PWD" ]] &&
   ! grep -qiE '(eval|grade|judge|test|benchmark)' <<<"$(basename "$T_TMP")"; then
  pass "T9 blinding: private temp dir '$(basename "$T_TMP")' is inside the sandbox with no evaluation cue"
else
  fail "T9 private temp dir missing, outside the sandbox, or cue-bearing: '$T_TMP' (sandbox '$T_PWD')"
fi
unset ATTR_MODE

# T10: SIGTERM while the sandbox is being removed must stop promptly and leave a discoverable ledger/retained report.
export ATTR_MODE=spill ATTR_MARK="wgm-rm-$$-$RANDOM" RM_CHECKPOINT="$TMP/rm-checkpoint"
rm -f "$RM_CHECKPOINT"
PATH="$TMP/fakebin:$PATH" term_run "$RM_CHECKPOINT"
RET="$(sed -n 's/^retained: //p' <<<"$OUT" | head -1)"
LEDGER_F="$RD/sandboxes.tsv"
if [[ "$TERM_RC" -eq 143 ]] && ! pgrep -f "$ATTR_MARK" >/dev/null && ! [[ -e "$RD/case-1/candidate/grading.json" ]] &&
   [[ -n "$RET" ]] && { [[ ! -e "$RET" ]] || { grep -qP "^(created|retained)\t$RET\$" "$LEDGER_F" && ! grep -qP "^removed\t$RET\$" "$LEDGER_F"; }; }; then
  pass "T10 cancellation during cleanup: exits exactly 143 ($TERM_RC), no survivor, retained reported, ledger shows no removal"
else
  fail "T10 cancellation during cleanup wrong (rc=$TERM_RC, retained='$RET', ledger: $(tr '\n\t' ' ' < "$LEDGER_F" 2>/dev/null))"
fi
pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
sweep_sandboxes
if [[ -z "$(find "$OUTER" -maxdepth 1 -name 'workspace.*')" ]]; then
  pass "T10 recovery: retained sandbox removed by the test and confirmed gone"
else
  fail "T10 recovery: a sandbox is still present"
fi
unset ATTR_MODE ATTR_MARK RM_CHECKPOINT
# T11: SIGTERM while the agent runs, with a sandbox removal that stalls, must stay bounded: the handler's own
# removal is tracked and killed, nothing marked survives, and the sandbox is reported retained (not "removed").
export ATTR_MODE=hang ATTR_MARK="wgm-t11-$$-$RANDOM" RM_CHECKPOINT="$TMP/t11-checkpoint"
T11_OK=1; T11_CODES=""
for n in 1 2 3; do
  rm -f "$RM_CHECKPOINT"
  PATH="$TMP/fakebin:$PATH" term_run ""
  T11_CODES="$T11_CODES $TERM_RC"
  RET="$(sed -n 's/^retained: //p' <<<"$OUT" | head -1)"
  LEDGER_F="$RD/sandboxes.tsv"
  if [[ "$TERM_RC" -ne 143 ]] || pgrep -f "$ATTR_MARK" >/dev/null || [[ -e "$RD/case-1/candidate/grading.json" ]] ||
     ! { [[ -n "$RET" && -d "$RET" ]] && grep -qP "^(created|retained)\t$RET\$" "$LEDGER_F" && ! grep -qP "^removed\t$RET\$" "$LEDGER_F"; }; then
    T11_OK=0; T11_LAST="rc=$TERM_RC retained='$RET' ledger: $(tr '\n\t' ' ' < "$LEDGER_F" 2>/dev/null)"
  fi
  pkill -KILL -f "$ATTR_MARK" 2>/dev/null || true
  sweep_sandboxes
done
if (( T11_OK )); then
  pass "T11 stalled removal during signal x3: exits exactly 143 (codes:$T11_CODES) promptly, no survivor, sandbox retained and ledgered"
else
  fail "T11 stalled removal during signal wrong (codes:$T11_CODES; want 143 each; ${T11_LAST:-})"
fi
if [[ -z "$(find "$OUTER" -maxdepth 1 -name 'workspace.*')" ]]; then
  pass "T11 recovery: retained sandbox removed by the test and confirmed gone"
else
  fail "T11 recovery: a sandbox is still present"
fi
unset ATTR_MODE ATTR_MARK RM_CHECKPOINT
# T12: notices/refusals a harness prints only on stderr are observed (stderr is kept in agent.stderr, shown, and
# never mixed into the graded response), so grading.json is unchanged versus a run with no stderr output.
export WGM_HARNESS_NOTICE_REGEX='saved to a temp file' WGM_REFUSED_TOOL_REGEX='REFUSED:'
run case-1 -- "$ATTR"; RD="$(run_dir_of)"; QUIET_G="$(jq -S . "$RD/case-1/candidate/grading.json")"
export ATTR_MODE=stderr
run case-1 -- "$ATTR"; RD="$(run_dir_of)"
if [[ "$(attr .harness_notices)" =~ ^[1-9] && "$(attr .refused_tool_attempts)" =~ ^[1-9] &&
      "$(attr .observed_channels)" == '["stdout","stderr"]' && -f "$RD/case-1/candidate/agent.stderr" ]] &&
   grep -q 'saved to a temp file' "$RD/case-1/candidate/agent.stderr" &&
   ! grep -q 'saved to a temp file' "$RD/case-1/candidate/response.txt" && grep -q 'saved to a temp file' <<<"$OUT" &&
   [[ "$(jq -S . "$RD/case-1/candidate/grading.json")" == "$QUIET_G" ]]; then
  pass "T12 stderr channel: notices/refusals counted from stderr, agent.stderr kept and shown, grading.json byte-identical"
else
  fail "T12 stderr observation wrong (attr: $(attr .))"
fi
unset ATTR_MODE WGM_HARNESS_NOTICE_REGEX WGM_REFUSED_TOOL_REGEX

# T13: an unenumerable private temp dir is "unavailable" with a warning — never a measured 0 — and cannot change
# the baseline verdict, exit code, or grading.json.
unseal() { find "$OUTER" -maxdepth 1 -name 'workspace.*' -exec chmod -R u+rwx {} + 2>/dev/null; find "$OUTER" -maxdepth 1 -name 'workspace.*' -exec "$REAL_RM" -rf {} +; }
run case-1 --baseline "$SHA_V1" -- "$ATTR"; RD="$(run_dir_of)"; B13_RC="$RC"; B13_OUT="$(norm)"; B13_G="$(jq -S . "$RD/case-1/candidate/grading.json")"
export ATTR_MODE=unenum
run case-1 --baseline "$SHA_V1" -- "$ATTR"; RD="$(run_dir_of)"
if [[ "$(id -u)" == 0 ]]; then
  pass "T13 unenumerable temp dir: skipped visibly because root can enumerate a 000 directory"
elif [[ "$(attr .spill_files)" == '"unavailable"' ]] && grep -q 'attribution: spill enumeration failed' <<<"$OUT" &&
     [[ "$RC" == "$B13_RC" && "$(jq -S . "$RD/case-1/candidate/grading.json")" == "$B13_G" ]] &&
     [[ "$(grep -E 'GATE:' <<<"$OUT")" == "$(grep -E 'GATE:' <<<"$B13_OUT")" ]]; then
  pass "T13 unenumerable temp dir: spill_files \"unavailable\" with warning; verdict, exit, grading.json unchanged"
else
  fail "T13 unenumerable temp dir mishandled (rc=$RC vs $B13_RC, spill_files=$(attr .spill_files))"
fi
unseal
unset ATTR_MODE
if [[ -n "$TMPDIR_ORIG" ]]; then export TMPDIR="$TMPDIR_ORIG"; else unset TMPDIR; fi

if (( FAILED == 0 )); then
  echo "grade-evals: GREEN ($ASSERTIONS assertions)"
  exit 0
else
  echo "grade-evals: RED" >&2
  exit 1
fi
