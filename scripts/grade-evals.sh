#!/usr/bin/env bash
#
# wgm/grade-evals.sh — OPTIONAL, opt-in live grading for evals/evals.json.
#
# Mechanizes references/evals.md's "Automated grading protocol" for real: for each case, embeds a
# revision of SKILL.md directly into the case's prompt (so the check never depends on wherever an
# installed skill copy happens to live, or whether it's gone stale — see references/evals.md for
# why), runs it through your configured agent, then spawns a second call to the same agent as a
# grader (the `anthropics/skills` `agents/grader.md` pattern evals.md already names) and writes a
# `grading.json` in the lean core of that ecosystem's schema: `expectations[]` + `summary` only —
# the fuller skill-creator schema's execution_metrics/timing/claims fields are deliberately left out
# as unneeded complexity for wgm's own use. Design borrowed from
# https://github.com/microsoft/SkillOpt's validation gate (accept a candidate only if it doesn't
# regress a held-out/baseline score) — see docs/plans/2026-07-08_SKILLOPT_ADOPTION.md.
#
# SAFETY: every agent call runs in a throwaway sandbox directory outside this repo. Grading prompts
# describe BUILD tasks, and a tool-enabled agent will carry them out for real — one run created a
# whole project and committed it into the repo under test. Capturing stdout does not prevent that.
#
# Scope, honestly: this grades SKILL.md's own text only, single-shot — not the references/*.md files
# it points to (a real agent would read those itself via tools; this harness doesn't simulate that),
# and it does not retry a failed agent call the way scripts/loop.sh does. Re-run the script if an
# agent call fails. Costs real agent/API calls (one task call + one grader call per case, doubled
# with --baseline) — this is why it is NEVER wired into `make validate` or CI. Run it by hand before
# landing a SKILL.md/references change that might affect behavior quality.
#
# Usage:
#   ./scripts/grade-evals.sh [eval-id] [--baseline REF] [--agent "CMD" | -- agent argv...]
#
#   eval-id         grade only this case id (default: every case in evals/evals.json)
#   --baseline REF  also grade the same case(s) against SKILL.md as it existed at git ref REF, and
#                   print ACCEPT (exit 0), REGRESSION (exit 1), or ERROR (invalid grade, exit 2)
#
# Agent configuration is identical to scripts/loop.sh:
#   $WGM_AGENT (or --agent "CMD") — shell-evaluated, prompt appended as the final argument
#   a `--` passthrough — everything after `--` is the agent argv, invoked WITHOUT eval (safest)
#   $WGM_PROMPT_STDIN=1 — set this if your agent reads the prompt from stdin instead of an argument
#
# Output: a grading.json + raw response per (case, revision) under a fresh run directory (its path
# is printed, so results are never lost); an attribution.json beside each TASK call's grading.json
# ({spill_files|"unavailable", harness_notices, refused_tool_attempts, observed_channels, descendants_terminated[, retained_path]} —
# counts cover only stdout+stderr of the task call (stderr is kept in agent.stderr, never graded); a diagnostic only: notices and
# refusals are counted only when WGM_HARNESS_NOTICE_REGEX / WGM_REFUSED_TOOL_REGEX are set, else null, and
# nothing here affects scores, verdicts, or exit codes); a sandboxes.tsv ownership ledger
# (created/removed/retained per sandbox); SIGINT/SIGTERM stop the whole agent process group and exit 130/143; every call runs in its own group (bash
# job control, no setsid needed) and any member left after the leader exits is terminated (TERM, KILL after ~2 s); a one-line pass_rate per case; an overall summary; and,
# with --baseline, a final gate verdict.
#
# Exit codes: 2 = misconfigured (no agent / bad flags / jq missing) or invalid baseline comparison
# (any candidate/baseline grade is ungraded/error); 1 = --baseline given and at
# least one case regressed; 0 = otherwise (grading without --baseline is informational, not gating —
# see references/evals.md for why an absolute score alone isn't treated as pass/fail here).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

FIXTURE="evals/evals.json"
ONLY_ID=""
BASELINE_REF=""
AGENT="${WGM_AGENT:-}"
AGENT_ARGV=()
PROMPT_STDIN="${WGM_PROMPT_STDIN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --baseline) [[ $# -ge 2 ]] || { echo "--baseline requires a git ref" >&2; exit 2; }; BASELINE_REF="$2"; shift 2 ;;
    --agent)    [[ $# -ge 2 ]] || { echo "--agent requires a command" >&2; exit 2; }; AGENT="$2"; shift 2 ;;
    --)         shift; AGENT_ARGV=("$@"); break ;;
    --*)        echo "Unknown flag: $1" >&2; exit 2 ;;
    *)          [[ -z "$ONLY_ID" ]] || { echo "Only one eval-id may be given" >&2; exit 2; }; ONLY_ID="$1"; shift ;;
  esac
done

if [[ ${#AGENT_ARGV[@]} -eq 0 && -z "$AGENT" ]]; then
  echo "No agent configured. Set \$WGM_AGENT, pass --agent \"CMD\", or append -- argv. See --help." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found on PATH (see CONTRIBUTING.md's Dev prerequisites)" >&2
  exit 2
fi
[[ -f "$FIXTURE" ]] || { echo "ERROR: $FIXTURE not found" >&2; exit 2; }
jq empty "$FIXTURE" 2>/dev/null || { echo "ERROR: $FIXTURE is not valid JSON (run scripts/check-evals.sh)" >&2; exit 2; }
[[ -f "SKILL.md" ]] || { echo "ERROR: SKILL.md not found at repo root" >&2; exit 2; }

mapfile -t ALL_IDS < <(jq -r '.evals[].id' "$FIXTURE")
if [[ -n "$ONLY_ID" ]]; then
  printf '%s\n' "${ALL_IDS[@]}" | grep -qx -- "$ONLY_ID" || { echo "ERROR: eval id '$ONLY_ID' not found in $FIXTURE" >&2; exit 2; }
  IDS=("$ONLY_ID")
else
  IDS=("${ALL_IDS[@]}")
fi

# Same invocation convention as scripts/loop.sh: eval'd $AGENT with $PROMPT appended, a `--` argv
# passthrough (no eval), or stdin. We capture the response, but capturing stdout does NOT make the
# call side-effect-free: a tool-enabled agent still writes files and runs git in its working
# directory. This script cd's to the repo root, so an eval task phrased as a build ("create a
# greenfield CLI") was taken literally and committed into the repo under test. So every agent call
# runs in a throwaway sandbox OUTSIDE the repo — the prompt already embeds the SKILL.md text being
# graded, and the agent needs nothing else from disk.
# Anti-gaming blinding (adapted from backnotprop/pstack's eval.md): the sandbox directory name uses
# a neutral project-shaped prefix (`workspace.XXXXXX`), never words like `eval`, `grade`, `test`,
# `judge`, or `benchmark` that leak to a tool-using candidate that it is being evaluated.
# Deliberately no retry/backoff (unlike loop.sh) — see the header's Scope note.
# Attribution (diagnostic only — see references/evals.md "Attribution recording"): each call also gets a
# private, neutrally named temp dir INSIDE its sandbox (`.tmp`) exported as TMPDIR for the agent only, so
# CLI spill files land where they can be counted and removed. Nothing here feeds scores or verdicts.
ERR_FILE=""; DESC_TERMINATED=0; REAP_N=0
CHILD=""; CUR_SANDBOX=""; CUR_CAP=""; CAP_DIR=""; CUR_STATE=""; RESP_FILE=""
AGENT_RC=0; SPILL_COUNT=0; RETAINED_PATH=""; OUT_UNREADABLE=0; ERR_UNREADABLE=0

# shellcheck disable=SC2317,SC2329  # invoked indirectly (run via run_child in a background subshell)
agent_body() {  # runs in a background subshell: $1 = sandbox; prompt in global $PROMPT
  local sandbox="$1"
  # Redirect here, in the child only: a redirection on the run_child call would also capture the main
  # shell's own stderr (including the signal handler's `retained:` report) for the call's duration.
  # Blinding: stdout/stderr go to NEUTRAL files in a sibling capture dir (never under the labeled run
  # directory), so `readlink /proc/self/fd/1` shows no evaluation or arm label. The runner moves them to the
  # labeled outdir only AFTER the call. Regular files, so nothing ever waits on a pipe reader.
  exec > "$CAP_DIR/o1" 2> "$CAP_DIR/o2"
  cd "$sandbox" || exit 1
  export TMPDIR="$sandbox/.tmp"
  export GIT_CEILING_DIRECTORIES
  GIT_CEILING_DIRECTORIES="$(dirname "$sandbox")"
  if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
    if [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | "${AGENT_ARGV[@]}"
    else "${AGENT_ARGV[@]}" "$PROMPT"; fi
  elif [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | eval "$AGENT"
  else eval "$AGENT \"\$PROMPT\""; fi
}

# Process-group ownership: bash job control (`set -m`) makes every backgrounded call its own group leader
# (pgid == pid), which needs no `setsid` binary. CHILD keeps that group id from start until the group is empty,
# so the signal handler can stop the WHOLE group, including descendants that outlive the leader.
live_in_group() {  # $1 = pgid; prints the number of non-zombie members, or "unavailable" (status 1) if ps fails
  local out
  if ! out="$(ps -eo pgid=,stat= 2>/dev/null)"; then echo unavailable; return 1; fi
  awk -v g="$1" '$1==g && $2!~/^Z/{n++} END{print n+0}' <<<"$out"
}

reap_group() {  # $1 = pgid; after the leader exited: TERM remaining members, KILL after ~2 s; sets REAP_N
  local pg="$1" n i
  REAP_N=0
  if ! n="$(live_in_group "$pg")"; then
    # Membership cannot be observed: still stop the group (bounded), but never report that as a measured 0.
    REAP_N=unavailable
    kill -TERM -- "-$pg" 2>/dev/null || true
    sleep 2
    kill -KILL -- "-$pg" 2>/dev/null || true
    return 0
  fi
  [[ "$n" -gt 0 ]] || return 0
  REAP_N="$n"
  kill -TERM -- "-$pg" 2>/dev/null || true
  for ((i = 0; i < 20; i++)); do
    [[ "$(live_in_group "$pg")" != 0 ]] || break
    sleep 0.1
  done
  kill -KILL -- "-$pg" 2>/dev/null || true
  return 0
}

run_child() {  # run "$@" in its own process group; returns the leader's status; no member outlives the call
  local rc=0
  set -m
  "$@" </dev/null &
  CHILD=$!
  set +m
  wait "$CHILD" || rc=$?
  reap_group "$CHILD"
  CHILD=""
  return "$rc"
}

# shellcheck disable=SC2317,SC2329  # invoked indirectly (called only from the on_signal trap handler)
kill_group() {  # TERM the group, KILL after ~5 s if any non-zombie member is left
  local pg="$1" i
  kill -TERM -- "-$pg" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    ps -eo pgid=,stat= 2>/dev/null | awk -v g="$pg" '$1==g && $2!~/^Z/{f=1} END{exit !f}' || break
    sleep 0.1
  done
  kill -KILL -- "-$pg" 2>/dev/null || true
  wait "$pg" 2>/dev/null || true
}

# Bounded, tracked removal for the signal path: its own process group, ~3 s to finish, then KILL.
# Never a second unbounded cleanup; failure or timeout means the caller reports the sandbox as retained.
# shellcheck disable=SC2317,SC2329  # invoked indirectly (called only from the on_signal trap handler)
bounded_rm() {  # $@ = paths; returns 0 only if rm finished successfully in time
  local pid i rc=0
  set -m
  rm -rf "$@" >/dev/null 2>&1 &
  pid=$!
  set +m
  CHILD="$pid"
  for ((i = 0; i < 30; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    CHILD=""
    return 1
  fi
  wait "$pid" 2>/dev/null || rc=$?
  CHILD=""
  return "$rc"
}

# After a removal attempt, record each path by what is actually on disk: "removed" only if it is gone,
# otherwise "retained" plus a visible `retained: <path>` line. Never aborts the caller.
ledger_paths() {
  local pth
  for pth in "$@"; do
    [[ -n "$pth" ]] || continue
    if [[ -e "$pth" ]]; then
      printf 'retained\t%s\n' "$pth" >> "$LEDGER" || echo "attribution: ledger write failed" >&2
      echo "retained: $pth" >&2 || true
    else
      printf 'removed\t%s\n' "$pth" >> "$LEDGER" || echo "attribution: ledger write failed" >&2
    fi
  done
}

# shellcheck disable=SC2317,SC2329  # invoked indirectly (INT/TERM trap handler)
on_signal() {  # $1 = exit code (INT 130 / TERM 143); stop the agent tree, remove or report the sandbox
  local status="$1"   # chosen FIRST: nothing below may change it
  trap '' INT TERM
  set +e              # best-effort teardown; no helper failure may preempt the deliberate exit
  if [[ -n "$CHILD" ]]; then kill_group "$CHILD" || true; fi
  if [[ -n "$CUR_SANDBOX" ]]; then
    # One bounded, tracked removal of both neutral dirs (and none when the state is already "cleanup": that
    # removal was just killed, so report whatever remains).
    if [[ "$CUR_STATE" == agent ]]; then bounded_rm "$CUR_SANDBOX" "$CUR_CAP" || true; fi
    ledger_paths "$CUR_SANDBOX" "$CUR_CAP"
  fi
  # Nothing here is foreground or unbounded; captured output lives in the neutral dir and goes with it.
  exit "$status"
}

# Deliberately no retry/backoff (unlike loop.sh) — see the header's Scope note.
run_agent() {  # expects global $PROMPT; response text goes to $RESP_FILE; sets AGENT_RC/SPILL_COUNT/RETAINED_PATH
  local sandbox cap
  AGENT_RC=0; SPILL_COUNT=0; RETAINED_PATH=""; OUT_UNREADABLE=0; ERR_UNREADABLE=0
  sandbox="$(mktemp -d -t workspace.XXXXXX)"
  cap="$(mktemp -d -t workspace.XXXXXX)"
  CUR_SANDBOX="$sandbox"; CUR_CAP="$cap"; CAP_DIR="$cap"; CUR_STATE=agent
  if ! { printf 'created\t%s\n' "$sandbox" >> "$LEDGER" && printf 'created\t%s\n' "$cap" >> "$LEDGER"; }; then
    echo "ERROR: cannot write the sandbox ownership ledger $LEDGER" >&2
    rm -rf "$sandbox" "$cap" 2>/dev/null || true
    exit 2
  fi
  mkdir -p "$sandbox/.tmp"
  RESP_FILE="$RUN_DIR/.response.$$"
  run_child agent_body "$sandbox" || AGENT_RC=$?
  DESC_TERMINATED="$REAP_N"
  # Only now do captured streams move to the labeled run directory.
  # An unreadable capture is UNOBSERVED: flagged here, never turned into an empty-but-observed channel.
  if ! cat "$cap/o1" > "$RESP_FILE" 2>/dev/null; then
    OUT_UNREADABLE=1; : > "$RESP_FILE"; echo "attribution: channel unreadable (stdout)" >&2
  fi
  if [[ -n "$ERR_FILE" ]] && ! cat "$cap/o2" > "$ERR_FILE" 2>/dev/null; then
    ERR_UNREADABLE=1; rm -f "$ERR_FILE"
  fi
  if [[ -s "$cap/o2" ]]; then cat "$cap/o2" >&2 2>/dev/null || true; fi   # replay to the terminal
  if spill_list="$(find "$sandbox/.tmp" -type f 2>/dev/null)"; then
    if [[ -z "$spill_list" ]]; then SPILL_COUNT=0; else SPILL_COUNT="$(printf '%s\n' "$spill_list" | wc -l | tr -d ' ')"; fi
  else
    SPILL_COUNT=unavailable   # never report an unobservable directory as a measured zero
    echo "attribution: spill enumeration failed" >&2
  fi
  CUR_STATE=cleanup
  run_child rm -rf "$sandbox" "$cap" || true
  ledger_paths "$sandbox" "$cap"
  if [[ -e "$sandbox" ]]; then RETAINED_PATH="$sandbox"; fi
  CUR_SANDBOX=""; CUR_CAP=""; CAP_DIR=""; CUR_STATE=""
  return 0
}

classify() {  # $1 = env var name, $2 = regex ("" = unset), $3 = text of all readable channels; prints a JSON token
  local n rc=0 var="$1" rx="$2"
  if [[ -z "$rx" ]]; then echo null; return 0; fi
  n="$(printf '%s\n' "$3" | grep -cE -e "$rx" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) echo "$n" ;;
    1) echo 0 ;;
    *) echo "attribution: invalid $var" >&2; echo '"classifier-error"' ;;
  esac
}

# Observation is checked BEFORE classification: a channel that cannot be read is not "no match" — it is
# unobserved, so it is left out of observed_channels and a set classifier reports "unavailable" (never 0).
write_attribution() {  # $1 = outdir; diagnostic record beside grading.json, never read back by the gate
  local outdir="$1" notices refusals text="" chan_text unreadable=0 channels='[]'
  local name file bad
  for name in stdout stderr; do
    if [[ "$name" == stdout ]]; then file="$RESP_FILE"; bad="$OUT_UNREADABLE"; else file="$ERR_FILE"; bad="$ERR_UNREADABLE"; fi
    # Each channel is checked independently: a capture flagged unreadable, or one that cannot be read now, is unobserved.
    if [[ "$bad" == 0 ]] && chan_text="$(cat "$file" 2>/dev/null)"; then
      text+="$chan_text"$'\n'
      channels="$(jq -c --arg c "$name" '. + [$c]' <<<"$channels")"
    else
      unreadable=1
      echo "attribution: channel unreadable ($name)" >&2
    fi
  done
  if (( unreadable )); then
    notices=null; refusals=null
    [[ -z "${WGM_HARNESS_NOTICE_REGEX:-}" ]] || notices='"unavailable"'
    [[ -z "${WGM_REFUSED_TOOL_REGEX:-}" ]] || refusals='"unavailable"'
  else
    notices="$(classify WGM_HARNESS_NOTICE_REGEX "${WGM_HARNESS_NOTICE_REGEX:-}" "$text")"
    refusals="$(classify WGM_REFUSED_TOOL_REGEX "${WGM_REFUSED_TOOL_REGEX:-}" "$text")"
  fi
  mkdir -p "$outdir"
  jq -n --arg d "$DESC_TERMINATED" --arg s "$SPILL_COUNT" --argjson n "$notices" --argjson r "$refusals" --argjson ch "$channels" --arg rp "$RETAINED_PATH" \
    '{spill_files:(if ($s|test("^[0-9]+$")) then ($s|tonumber) else $s end), harness_notices:$n, refused_tool_attempts:$r, observed_channels:$ch, descendants_terminated:(if ($d|test("^[0-9]+$")) then ($d|tonumber) else $d end)} + (if $rp != "" then {retained_path:$rp} else {} end)' \
    > "$outdir/attribution.json" || { rm -f "$outdir/attribution.json"; echo "attribution: record not written" >&2; }
}

skill_at_ref() {  # $1 = git ref; prints SKILL.md content as it existed at that ref
  git show "${1}:SKILL.md" 2>/dev/null || { echo "ERROR: could not read SKILL.md at ref '$1'" >&2; exit 2; }
}

# Accept one object only, including after the existing fence-stripping fallback. jq normally
# accepts a stream of documents; slurping prevents a second document from becoming a second grade.
extract_json() {  # $1 = raw grader text
  local raw="$1" stripped
  if printf '%s' "$raw" | jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then printf '%s' "$raw"; return 0; fi
  stripped="$(printf '%s' "$raw" | sed -e '/^```/d')"
  if printf '%s' "$stripped" | jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then printf '%s' "$stripped"; return 0; fi
  return 1
}

grade_error() {  # $1 = outdir, $2 = message: the existing ungraded/error shape (never a pass)
  mkdir -p "$1"
  jq -n --arg error "$2" '{expectations: [], summary: {passed:0, failed:0, total:0, pass_rate:0}, error:$error}' > "$1/grading.json"
  GRADE_LINE="0 0 0.0000 error"
}

# Grade one case against one skill revision. Sets GRADE_LINE to "passed total pass_rate status"; writes response.txt + grading.json under $3.
grade_one() {
  local id="$1" skill="$2" outdir="$3"
  local prompt expected assertions_json numbered response grader_raw json total passed failed pass_rate error=""

  prompt=$(jq -r --arg id "$id" '.evals[] | select(.id==$id) | .prompt' "$FIXTURE")
  expected=$(jq -r --arg id "$id" '.evals[] | select(.id==$id) | .expected_output' "$FIXTURE")
  assertions_json=$(jq -c --arg id "$id" '.evals[] | select(.id==$id) | .assertions' "$FIXTURE")
  numbered=$(printf '%s' "$assertions_json" | jq -r 'to_entries[] | "\(.key + 1). \(.value)"')

  PROMPT=$(printf 'Follow the protocol below exactly as written, then respond to the user'"'"'s request.\n\n===== SKILL PROTOCOL =====\n%s\n===== END PROTOCOL =====\n\nUser request:\n%s\n' "$skill" "$prompt")
  mkdir -p "$outdir"
  ERR_FILE="$outdir/agent.stderr"
  run_agent
  write_attribution "$outdir"
  ERR_FILE=""
  response="$(cat "$RESP_FILE")"
  rm -f "$RESP_FILE"; RESP_FILE=""
  [[ "$AGENT_RC" -eq 0 ]] || exit 1   # same disposition as before: an agent failure aborts the run
  if [[ "$OUT_UNREADABLE" -eq 1 ]]; then   # strict: an unobserved response is never graded as empty
    grade_error "$outdir" "task output capture unreadable; case not graded"; return 0
  fi

  PROMPT=$(printf 'You are grading a transcript against a fixed checklist. Output ONLY JSON (no prose, no code fences) matching exactly this shape:\n{"expectations":[{"text":"<assertion text>","passed":true|false,"evidence":"<one-line quote or paraphrase>"}]}\n\nExpected outcome: %s\n\nAssertions to check (one expectations[] entry per line, same order):\n%s\n\nTranscript to grade:\n%s\n\nScore each assertion independently: passed=true only if the transcript clearly satisfies it, citing a quoted or closely paraphrased snippet as evidence; passed=false with evidence explaining what is missing otherwise.\n' "$expected" "$numbered" "$response")
  run_agent
  grader_raw="$(cat "$RESP_FILE")"
  rm -f "$RESP_FILE"; RESP_FILE=""
  [[ "$AGENT_RC" -eq 0 ]] || exit 1
  if [[ "$OUT_UNREADABLE" -eq 1 ]]; then
    grade_error "$outdir" "grader output capture unreadable; case not graded"; return 0
  fi

  mkdir -p "$outdir"
  printf '%s\n' "$response" > "$outdir/response.txt"

  if ! json="$(extract_json "$grader_raw")"; then
    error="grader output did not parse as exactly one JSON object"
  elif ! jq -e --argjson assertions "$assertions_json" '
    (.expectations | type == "array") and
    ($assertions | length > 0) and
    (.expectations | length == ($assertions | length)) and
    (.expectations | to_entries | all(.[];
      .key as $i | .value |
      type == "object" and
      (.text == $assertions[$i]) and
      (.passed | type == "boolean") and
      (.evidence | type == "string" and test("\\S"))
    ))
  ' <<<"$json" >/dev/null 2>&1; then
    error="grader expectations did not match the complete ordered assertion checklist with boolean passed and nonblank evidence"
  fi

  if [[ -n "$error" ]]; then
    printf '%s\n' "$grader_raw" > "$outdir/grader_raw.txt"
    jq -n --arg error "$error" '{expectations: [], summary: {passed:0, failed:0, total:0, pass_rate:0}, error:$error}' > "$outdir/grading.json"
    GRADE_LINE="0 0 0.0000 error"
    return 0
  fi

  total=$(printf '%s' "$json" | jq '[.expectations[]?] | length')
  passed=$(printf '%s' "$json" | jq '[.expectations[]? | select(.passed==true)] | length')
  failed=$((total - passed))
  pass_rate=$(awk -v p="$passed" -v t="$total" 'BEGIN{ if (t==0) print "0.0000"; else printf "%.4f", p/t }')

  jq --argjson passed "$passed" --argjson failed "$failed" --argjson total "$total" --argjson pass_rate "$pass_rate" \
     '{expectations: (.expectations // []), summary: {passed:$passed, failed:$failed, total:$total, pass_rate:$pass_rate}}' \
     <<<"$json" > "$outdir/grading.json"

  GRADE_LINE="$passed $total $pass_rate valid"
}

CANDIDATE_SKILL="$(cat SKILL.md)"
BASELINE_SKILL=""
[[ -n "$BASELINE_REF" ]] && BASELINE_SKILL="$(skill_at_ref "$BASELINE_REF")"

RUN_DIR="$(mktemp -d -t wgm-grade-evals.XXXXXX)"
echo "Run directory: $RUN_DIR"
LEDGER="$RUN_DIR/sandboxes.tsv"; : > "$LEDGER"
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

OVERALL_TOTAL=0
OVERALL_PASSED=0
REGRESSED=0
GRADE_ERRORS=0
CANDIDATE_GRADED=0

for id in "${IDS[@]}"; do
  echo "== grading '$id' (candidate) =="
  grade_one "$id" "$CANDIDATE_SKILL" "$RUN_DIR/$id/candidate"
  read -r c_passed c_total c_rate c_status <<<"$GRADE_LINE"
  if [[ "$c_status" == valid ]]; then
    echo "   candidate: ${c_passed}/${c_total} (pass_rate=${c_rate})"
    CANDIDATE_GRADED=$((CANDIDATE_GRADED + 1))
  else
    echo "   candidate: ungraded/error (see $RUN_DIR/$id/candidate/grading.json)"
    GRADE_ERRORS=$((GRADE_ERRORS + 1))
  fi
  OVERALL_TOTAL=$((OVERALL_TOTAL + c_total))
  OVERALL_PASSED=$((OVERALL_PASSED + c_passed))

  if [[ -n "$BASELINE_REF" ]]; then
    echo "== grading '$id' (baseline @ ${BASELINE_REF}) =="
    grade_one "$id" "$BASELINE_SKILL" "$RUN_DIR/$id/baseline"
    read -r b_passed b_total b_rate b_status <<<"$GRADE_LINE"
    if [[ "$b_status" == valid ]]; then
      echo "   baseline:  ${b_passed}/${b_total} (pass_rate=${b_rate})"
    else
      echo "   baseline: ungraded/error (see $RUN_DIR/$id/baseline/grading.json)"
      GRADE_ERRORS=$((GRADE_ERRORS + 1))
    fi
    if [[ "$c_status" == valid && "$b_status" == valid ]] &&
       awk -v c="$c_rate" -v b="$b_rate" 'BEGIN{exit !(c < b)}'; then
      echo "   REGRESSION on '$id': candidate ${c_rate} < baseline ${b_rate}"
      REGRESSED=1
    fi
  fi
done

OVERALL_RATE=$(awk -v p="$OVERALL_PASSED" -v t="$OVERALL_TOTAL" 'BEGIN{ if (t==0) print "0.0000"; else printf "%.4f", p/t }')
echo ""
if [[ "$GRADE_ERRORS" -gt 0 ]]; then
  echo "Incomplete grading coverage: ${CANDIDATE_GRADED}/${#IDS[@]} candidate cases graded; ${GRADE_ERRORS} candidate/baseline grade error(s)"
  echo "Overall candidate pass_rate (graded cases only; incomplete coverage): ${OVERALL_PASSED}/${OVERALL_TOTAL} (${OVERALL_RATE})"
else
  echo "Overall candidate pass_rate: ${OVERALL_PASSED}/${OVERALL_TOTAL} (${OVERALL_RATE})"
fi
echo "Results written under: $RUN_DIR"

if [[ -n "$BASELINE_REF" ]]; then
  if [[ "$GRADE_ERRORS" -gt 0 ]]; then
    echo "GATE: ERROR (comparison blocked by ungraded/error candidate or baseline output)"
    exit 2
  fi
  if [[ "$REGRESSED" -eq 1 ]]; then
    echo "GATE: REGRESSION (candidate scored lower than baseline '${BASELINE_REF}' on at least one case)"
    exit 1
  fi
  echo "GATE: ACCEPT (candidate did not regress vs. baseline '${BASELINE_REF}')"
fi
exit 0
