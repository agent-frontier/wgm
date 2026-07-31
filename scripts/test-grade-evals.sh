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
pass() { printf 'ok:   %s\n' "$*"; }
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

if (( FAILED == 0 )); then
  echo "grade-evals: GREEN"
  exit 0
else
  echo "grade-evals: RED" >&2
  exit 1
fi
