#!/usr/bin/env bash
#
# wgm/test-swarm.sh — deterministic backpressure for scripts/swarm.sh.
#
# Fans out parallel git-worktree streams with a fake agent in a throwaway repo, so the swarm's
# orchestration (worktrees, branches, parallel commits, cleanup, guards) has a real pass/fail signal.
# No real agent, model, or network is needed.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="$ROOT/scripts/swarm.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
git config user.email "wgm-test@example.com"
git config user.name "wgm test"
printf '# plan\n\n- seed\n' > IMPLEMENTATION_PLAN.md
printf '*.cache\n' > .gitignore
git add -A && git commit -qm seed
BASE="$(git rev-parse HEAD)"

# Fake agents: create the probe during preflight, then append to the plan and declare the files the
# loop is allowed to commit.
# shellcheck disable=SC2016
AGENT_OK=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- did work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_NOOP=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; : > "$WGM_OWNERSHIP_MANIFEST"' _)

printf 'add feature A\nadd feature B\n' > tasks.txt

OUT=""; RC=0
run() {  # run swarm.sh, capturing combined output + exit code without tripping set -e
  set +e
  OUT="$("$SWARM" "$@" 2>&1)"; RC=$?
  set -e
}

reset_swarm() {  # tear down every worktree under .wgm/worktrees + every wgm/* branch
  while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    git worktree remove --force "$w" 2>/dev/null || true
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep '/\.wgm/worktrees/' || true)
  git worktree prune 2>/dev/null || true
  while IFS= read -r b; do
    git branch -D "$b" >/dev/null 2>&1 || true
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -E '^wgm/' || true)
  rm -rf .wgm/worktrees .wgm/metrics .wgm/swarm-logs
  rm -f .wgm/memories.md
}

# The installed help must point operators and contributors to the jj prerequisite guidance without
# implying that the Git-only backend requires jj or a newer Git.
run --help
if [[ "$RC" -eq 0 ]] && grep -Fq 'worktree add --orphan' <<<"$OUT" \
   && grep -Fq 'backports work' <<<"$OUT" && grep -Fq 'exits 129' <<<"$OUT" \
   && grep -Fq 'default Git backend' <<<"$OUT" && grep -Fq 'scripts/test-jj-swarm.sh' <<<"$OUT" \
   && grep -Fq 'CONTRIBUTING.md#check-git-for-jj' <<<"$OUT" \
   && grep -Fq 'docs/reference/cli-swarm.md#try-the-jj-backend' <<<"$OUT"; then
  pass "swarm help points to jj prerequisites and Git-only boundaries"
else
  fail "swarm help lost jj prerequisite guidance (rc=$RC): $OUT"
fi

# 1) --dry-run lists the streams and creates nothing
run --tasks tasks.txt --dry-run -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "streams=2" <<<"$OUT" && grep -q "wgm/swarm/1" <<<"$OUT" && [[ ! -d .wgm/worktrees ]]; then
  pass "dry-run lists streams without creating worktrees"
else
  fail "dry-run misbehaved (rc=$RC)"
fi

# 2) two tasks -> two branches, each with a commit, produced in parallel
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] \
   && git show-ref --verify --quiet refs/heads/wgm/swarm/1 \
   && git show-ref --verify --quiet refs/heads/wgm/swarm/2 \
   && [[ "$(git rev-list --count "$BASE..wgm/swarm/1")" -ge 1 ]] \
   && [[ "$(git rev-list --count "$BASE..wgm/swarm/2")" -ge 1 ]]; then
  pass "two streams produce two committed branches in parallel"
else
  fail "parallel streams did not produce two committed branches (rc=$RC)"
fi
reset_swarm

# A successful host commit updates the expected lane tip so the next legitimate turn can proceed.
run -n 1 --max-iterations 2 --prefix wgm/two-turns -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ "$(git rev-list --count "$BASE..wgm/two-turns/1")" -eq 2 ]]; then
  pass "successive host-owned commits advance the guarded lane tip"
else
  fail "the lane tip guard rejected a later legitimate turn (rc=$RC): $OUT"
fi
reset_swarm

# 2a) parent project gates are copied into each lane and executed there
printf 'gates:\n  - test -f IMPLEMENTATION_PLAN.md\n' > wgm.yml
run --tasks tasks.txt --max-iterations 1 --prefix wgm/gates -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Project gate 1/1" .wgm/swarm-logs/wgm-gates-1.log; then
  pass "project gates propagate into and execute inside swarm lanes"
else
  fail "project gates did not propagate into the swarm lane (rc=$RC): $OUT"
fi
rm -f wgm.yml
reset_swarm

# 2b) each lane's prompt re-pins its absolute worktree and expected branch, so a later turn cannot
#     drift back to the parent checkout and mutate it ([learn] issue #73).
# shellcheck disable=SC2016  # $1 is the fake agent's own positional (the prompt), not ours.
# shellcheck disable=SC2016
AGENT_CAPTURE=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; printf "%s" "$1" > "$PWD/.prompt.txt"; printf "IMPLEMENTATION_PLAN.md\n.prompt.txt\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_CAPTURE[@]}"
pinned=0
for w in .wgm/worktrees/wgm-swarm-1 .wgm/worktrees/wgm-swarm-2; do
  [[ -f "$w/.prompt.txt" ]] || continue
  abs="$(cd "$w" && pwd)"
  if grep -qF "$abs" "$w/.prompt.txt" && grep -qF "git -C $abs" "$w/.prompt.txt"; then
    pinned=$((pinned + 1))
  fi
done
if [[ "$RC" -eq 0 && "$pinned" -eq 2 ]]; then
  pass "every lane prompt re-pins its absolute worktree path and git -C usage"
else
  fail "lane prompts did not re-pin the worktree (rc=$RC, pinned=$pinned)"
fi
reset_swarm

# 3) -n COUNT fans out COUNT identical streams
run -n 3 --max-iterations 1 --prefix wgm/race -- "${AGENT_OK[@]}"
nbr="$(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -c '^wgm/race/' || true)"
if [[ "$RC" -eq 0 ]] && [[ "$nbr" -eq 3 ]]; then
  pass "-n COUNT fans out COUNT identical streams"
else
  fail "-n COUNT did not create 3 branches (got $nbr, rc=$RC)"
fi
reset_swarm

# 4) --cleanup removes the worktree dirs but keeps the branches
run --tasks tasks.txt --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && git show-ref --verify --quiet refs/heads/wgm/swarm/1 && [[ ! -d .wgm/worktrees/wgm-swarm-1 ]]; then
  pass "--cleanup removes worktree dirs but keeps branches"
else
  fail "--cleanup did not keep branches while removing worktrees (rc=$RC)"
fi
reset_swarm

# 5) per-stream memories are consolidated back into the main worktree
# shellcheck disable=SC2016
AGENT_MEMORIES=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- did work\n" >> IMPLEMENTATION_PLAN.md; mkdir -p .wgm; printf "lesson from %s\n" "$(git branch --show-current)" >> .wgm/memories.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_MEMORIES[@]}"
if [[ "$RC" -eq 0 ]] \
   && [[ -f .wgm/memories.md ]] \
   && grep -q '<!-- from wgm/swarm/1 -->' .wgm/memories.md \
   && grep -q '<!-- from wgm/swarm/2 -->' .wgm/memories.md \
   && grep -q 'lesson from wgm/swarm/1' .wgm/memories.md \
   && grep -q 'lesson from wgm/swarm/2' .wgm/memories.md; then
  pass "stream memories are consolidated into the main worktree"
else
  fail "stream memories were not consolidated into the main worktree (rc=$RC)"
fi
# harvest-hive.sh is a sibling of swarm.sh in this checkout, so the standing dispatch above
# actually ran against the just-consolidated memories -- assert it did, safely, with no consent
# file and non-interactive stdin (declines for itself only, never blocks, never touches gh).
if grep -q "no human is present to answer, so treating only this run as declined" <<<"$OUT"; then
  pass "the standing post-swarm harvest-hive dispatch ran safely with no consent file yet"
else
  fail "swarm.sh did not dispatch harvest-hive.sh after consolidating memories: $OUT"
fi
if [[ "$RC" -eq 0 ]] && ! grep -R -q "Ship/Handoff harvest" .wgm/swarm-logs; then
  pass "swarm lanes defer harvest side effects to the parent"
else
  fail "a swarm lane invoked the parent-only harvest hook"
fi
reset_swarm

# 2c) a lane that exits 0 but produces no commit is a hard swarm failure
run -n 1 --max-iterations 1 --prefix wgm/noop -- "${AGENT_NOOP[@]}"
if [[ "$RC" -ne 0 ]] && grep -q "no verifiable commit artifact" <<<"$OUT"; then
  pass "an exit-0 lane with zero commits is reported as a failure"
else
  fail "zero-commit lane was treated as successful (rc=$RC): $OUT"
fi
reset_swarm

# 5b) the swarm reports two explicit clocks + lane telemetry, and per-lane ledgers land in the parent
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] \
   && grep -q "== swarm telemetry" <<<"$OUT" \
   && grep -q "wall time (parent):" <<<"$OUT" \
   && grep -q "lane time (allocated):" <<<"$OUT" \
   && grep -q "agent time (active):" <<<"$OUT" \
   && grep -q "parked time:" <<<"$OUT" \
   && grep -q "lanes completed/started:   2/2" <<<"$OUT" \
   && grep -q "turns timed/missing:" <<<"$OUT" \
   && grep -q "peak concurrency:" <<<"$OUT" \
   && grep -q "critical path" <<<"$OUT" \
   && grep -q "not billing data" <<<"$OUT" \
   && [[ -f .wgm/metrics/wgm-swarm-1.tsv && -f .wgm/metrics/wgm-swarm-2.tsv ]] \
   && grep -q "add feature A" .wgm/metrics/wgm-swarm-1.tsv; then
  pass "swarm reports wall/lane/active clocks and writes per-lane ledgers attributed to the parent task"
else
  fail "swarm telemetry summary or per-lane ledgers missing (rc=$RC): $OUT"
fi

# 5c) allocated lane time is never reported as "agent-hours" — the distinction the report turns on:
#     a parked lane still burns lifetime, so lifetime is a capacity bound, not measured agent work.
if [[ "$RC" -eq 0 ]] \
   && grep -q "capacity upper bound" <<<"$OUT" \
   && grep -q "measured LOWER BOUND" <<<"$OUT" \
   && ! grep -qi "agent time (summed)" <<<"$OUT"; then
  pass "allocated lane time and measured active agent time are labelled distinctly"
else
  fail "lane allocation vs active agent time were not distinguished: $OUT"
fi
reset_swarm

# 6) re-running with an existing branch is skipped (no duplicate / clobbered run)
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}"   # first run creates the branches
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}"   # second run: both already exist
if [[ "$RC" -ne 0 ]] && grep -q "already exists" <<<"$OUT"; then
  pass "an existing swarm branch is skipped, not clobbered"
else
  fail "did not skip an existing swarm run (rc=$RC)"
fi
reset_swarm

# 7) a partially unavailable swarm is not reported green when a later lane succeeds
git branch wgm/mixed/1
run -n 2 --max-iterations 1 --prefix wgm/mixed -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && grep -q "already exists" <<<"$OUT" && grep -q "one or more streams failed" <<<"$OUT"; then
  pass "a mixed setup failure remains a swarm failure"
else
  fail "a mixed setup failure was reported green (rc=$RC): $OUT"
fi
reset_swarm

# 8) If an agent detaches HEAD during a turn, the host must refuse its automatic commit and keep
#    the lane, even when cleanup was requested. A prompt alone cannot enforce the branch pin.
# shellcheck disable=SC2016
AGENT_DRIFT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; git switch -q --detach; printf -- "- retained after branch drift\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run -n 1 --max-iterations 1 --prefix wgm/drift --cleanup -- "${AGENT_DRIFT[@]}"
if [[ "$RC" -ne 0 ]] \
   && [[ -f .wgm/worktrees/wgm-drift-1/IMPLEMENTATION_PLAN.md ]] \
   && grep -q "retained after branch drift" .wgm/worktrees/wgm-drift-1/IMPLEMENTATION_PLAN.md \
   && grep -q "lane guard" .wgm/swarm-logs/wgm-drift-1.log \
   && [[ "$(git rev-parse wgm/drift/1)" == "$BASE" ]]; then
  pass "branch drift is refused before commit and the failed lane is retained"
else
  fail "branch drift was committed or its failed lane was removed (rc=$RC): $OUT"
fi
reset_swarm

# 9) The host owns commits. An agent that advances the same branch during a turn must be caught
#    even though its branch name and worktree path still match; retain its commit for inspection.
# shellcheck disable=SC2016
AGENT_MOVED_TIP=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- agent commit\n" >> IMPLEMENTATION_PLAN.md; git add IMPLEMENTATION_PLAN.md; git commit -qm "agent moved tip"; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run -n 1 --max-iterations 1 --prefix wgm/moved --cleanup -- "${AGENT_MOVED_TIP[@]}"
if [[ "$RC" -ne 0 ]] && [[ -d .wgm/worktrees/wgm-moved-1 ]] \
   && grep -q "lane guard" .wgm/swarm-logs/wgm-moved-1.log \
   && [[ "$(git log -1 --format=%s wgm/moved/1)" == "agent moved tip" ]] \
   && [[ "$(git rev-list --count "$BASE..wgm/moved/1")" -eq 1 ]]; then
  pass "agent-moved branch tip is refused and retained without another commit"
else
  fail "agent-moved branch tip was not refused or preserved (rc=$RC): $OUT"
fi
reset_swarm

# 10) An undeclared edit makes the loop fail; cleanup must not destroy the diagnostic work.
# shellcheck disable=SC2016
AGENT_UNDECLARED=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- tracked change\n" >> IMPLEMENTATION_PLAN.md; printf "recover this\n" > undeclared.txt; mkdir -p .wgm; printf "untrusted failed lesson\n" > .wgm/memories.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run -n 1 --max-iterations 1 --prefix wgm/dirty --cleanup -- "${AGENT_UNDECLARED[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f .wgm/worktrees/wgm-dirty-1/undeclared.txt ]] \
   && [[ -f .wgm/worktrees/wgm-dirty-1/.wgm/memories.md ]] \
   && [[ ! -f .wgm/memories.md ]] && grep -q "retained" <<<"$OUT"; then
  pass "failed dirty lane and its untrusted memory survive without parent harvest"
else
  fail "failed dirty lane was not retained (rc=$RC): $OUT"
fi
reset_swarm

# 11) Git normally hides ignored files. A successful lane with an ignored non-wgm artifact must
#     still be retained; --cleanup is not permission to erase unknown user/build data.
# shellcheck disable=SC2016
AGENT_IGNORED=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- committed work\n" >> IMPLEMENTATION_PLAN.md; printf "valuable ignored artifact\n" > result.cache; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run -n 1 --max-iterations 1 --prefix wgm/ignored --cleanup -- "${AGENT_IGNORED[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f .wgm/worktrees/wgm-ignored-1/result.cache ]] \
   && grep -q "retained" <<<"$OUT"; then
  pass "ignored non-wgm artifacts prevent destructive cleanup"
else
  fail "ignored non-wgm artifact was not retained (rc=$RC): $OUT"
fi
reset_swarm

# 12) A tracked .wgm file is project data, not disposable scratch, even though untracked .wgm
#     runtime files are excluded from cleanup checks.
SAVED_BASE="$BASE"
mkdir -p .wgm
printf 'tracked baseline\n' > .wgm/tracked-state.txt
git add -f .wgm/tracked-state.txt && git commit -qm 'seed tracked wgm state'
BASE="$(git rev-parse HEAD)"
# shellcheck disable=SC2016
AGENT_TRACKED_WGM=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- committed work\n" >> IMPLEMENTATION_PLAN.md; printf "tracked project edit\n" >> .wgm/tracked-state.txt; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
run -n 1 --max-iterations 1 --prefix wgm/tracked --cleanup -- "${AGENT_TRACKED_WGM[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f .wgm/worktrees/wgm-tracked-1/.wgm/tracked-state.txt ]] \
   && grep -q 'tracked project edit' .wgm/worktrees/wgm-tracked-1/.wgm/tracked-state.txt; then
  pass "tracked .wgm project edits prevent cleanup"
else
  fail "tracked .wgm project edit was discarded (rc=$RC): $OUT"
fi
reset_swarm
BASE="$SAVED_BASE"
git reset -q --hard "$BASE"

# 13) a missing --tasks file is rejected before anything runs
run --tasks does-not-exist.txt -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 2 ]] && grep -q "tasks file not found" <<<"$OUT"; then
  pass "missing --tasks file is rejected"
else
  fail "missing --tasks file not rejected (rc=$RC)"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "swarm harness: GREEN"
  exit 0
else
  echo "swarm harness: RED" >&2
  exit 1
fi
