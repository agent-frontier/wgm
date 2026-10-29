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
# is printed, so results are never lost); a one-line pass_rate per case; an overall summary; and,
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
run_agent() {  # expects global $PROMPT set; prints the agent's response on stdout
  local sandbox rc=0
  sandbox="$(mktemp -d -t workspace.XXXXXX)"
  (
    cd "$sandbox" || exit 1
    export GIT_CEILING_DIRECTORIES
    GIT_CEILING_DIRECTORIES="$(dirname "$sandbox")"
    if [[ ${#AGENT_ARGV[@]} -gt 0 ]]; then
      if [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | "${AGENT_ARGV[@]}"
      else "${AGENT_ARGV[@]}" "$PROMPT"; fi
    elif [[ "$PROMPT_STDIN" == "1" ]]; then printf '%s' "$PROMPT" | eval "$AGENT"
    else eval "$AGENT \"\$PROMPT\""; fi
  ) || rc=$?
  rm -rf "$sandbox"
  return "$rc"
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

# Grade one case against one skill revision. Prints "passed total pass_rate status" on stdout (the only
# line this function writes there); writes response.txt + grading.json under $3.
grade_one() {
  local id="$1" skill="$2" outdir="$3"
  local prompt expected assertions_json numbered response grader_raw json total passed failed pass_rate error=""

  prompt=$(jq -r --arg id "$id" '.evals[] | select(.id==$id) | .prompt' "$FIXTURE")
  expected=$(jq -r --arg id "$id" '.evals[] | select(.id==$id) | .expected_output' "$FIXTURE")
  assertions_json=$(jq -c --arg id "$id" '.evals[] | select(.id==$id) | .assertions' "$FIXTURE")
  numbered=$(printf '%s' "$assertions_json" | jq -r 'to_entries[] | "\(.key + 1). \(.value)"')

  PROMPT=$(printf 'Follow the protocol below exactly as written, then respond to the user'"'"'s request.\n\n===== SKILL PROTOCOL =====\n%s\n===== END PROTOCOL =====\n\nUser request:\n%s\n' "$skill" "$prompt")
  response="$(run_agent)"

  PROMPT=$(printf 'You are grading a transcript against a fixed checklist. Output ONLY JSON (no prose, no code fences) matching exactly this shape:\n{"expectations":[{"text":"<assertion text>","passed":true|false,"evidence":"<one-line quote or paraphrase>"}]}\n\nExpected outcome: %s\n\nAssertions to check (one expectations[] entry per line, same order):\n%s\n\nTranscript to grade:\n%s\n\nScore each assertion independently: passed=true only if the transcript clearly satisfies it, citing a quoted or closely paraphrased snippet as evidence; passed=false with evidence explaining what is missing otherwise.\n' "$expected" "$numbered" "$response")
  grader_raw="$(run_agent)"

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
    echo "0 0 0.0000 error"
    return 0
  fi

  total=$(printf '%s' "$json" | jq '[.expectations[]?] | length')
  passed=$(printf '%s' "$json" | jq '[.expectations[]? | select(.passed==true)] | length')
  failed=$((total - passed))
  pass_rate=$(awk -v p="$passed" -v t="$total" 'BEGIN{ if (t==0) print "0.0000"; else printf "%.4f", p/t }')

  jq --argjson passed "$passed" --argjson failed "$failed" --argjson total "$total" --argjson pass_rate "$pass_rate" \
     '{expectations: (.expectations // []), summary: {passed:$passed, failed:$failed, total:$total, pass_rate:$pass_rate}}' \
     <<<"$json" > "$outdir/grading.json"

  echo "$passed $total $pass_rate valid"
}

CANDIDATE_SKILL="$(cat SKILL.md)"
BASELINE_SKILL=""
[[ -n "$BASELINE_REF" ]] && BASELINE_SKILL="$(skill_at_ref "$BASELINE_REF")"

RUN_DIR="$(mktemp -d -t wgm-grade-evals.XXXXXX)"
echo "Run directory: $RUN_DIR"

OVERALL_TOTAL=0
OVERALL_PASSED=0
REGRESSED=0
GRADE_ERRORS=0
CANDIDATE_GRADED=0

for id in "${IDS[@]}"; do
  echo "== grading '$id' (candidate) =="
  read -r c_passed c_total c_rate c_status < <(grade_one "$id" "$CANDIDATE_SKILL" "$RUN_DIR/$id/candidate")
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
    read -r b_passed b_total b_rate b_status < <(grade_one "$id" "$BASELINE_SKILL" "$RUN_DIR/$id/baseline")
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
