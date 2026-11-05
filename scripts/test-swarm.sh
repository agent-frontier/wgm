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

# --- HOME / XDG_CONFIG_HOME isolation for the WHOLE harness: the very first action, before ANY engine, git, jj or tool
# call. Every case below runs under a throwaway HOME and XDG_CONFIG_HOME (approvals, git/jj identity, engine config live
# there); only the engine's image store (XDG_DATA_HOME) stays REAL, and only where a case needs the container engine.
REAL_HOME="${HOME:-}"
REAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$REAL_HOME/.config}"
REAL_DATA_HOME="${WGM_TEST_REAL_DATA_HOME:-${XDG_DATA_HOME:-$REAL_HOME/.local/share}}"
export WGM_TEST_REAL_DATA_HOME="$REAL_DATA_HOME"
ISO_HOME="$(mktemp -d)"
export HOME="$ISO_HOME/home" XDG_CONFIG_HOME="$ISO_HOME/home/.config"
mkdir -p "$XDG_CONFIG_HOME"
# The operator's REAL config dirs must be left exactly as they were: a listing signature taken now is compared at the end.
# jj's per-repository state dir (`<config>/jj/repos/<id>`) is shared by EVERY jj user on the host — other tools (e.g. a Go
# test suite) legitimately create entries there while this harness runs — so it is excluded from the listing and checked
# separately: no NEW entry may reference a directory of THIS harness (its metadata records the repository path).
real_cfg_sig() {
  local p
  for p in "$REAL_XDG_CONFIG_HOME/wgm" "$REAL_XDG_CONFIG_HOME/jj" "$REAL_XDG_CONFIG_HOME/git" "$REAL_HOME/.gitconfig" "$REAL_HOME/.jjconfig.toml"; do
    if [[ -e "$p" || -L "$p" ]]; then find "$p" -path "$p/repos" -prune -o -printf '%p %y %s %T@\n' 2>/dev/null | LC_ALL=C sort; else printf '%s absent\n' "$p"; fi
  done
}
real_jj_repo_names() {  # names of the entries in the REAL jj repos dir (one per line, sorted)
  local d="$REAL_XDG_CONFIG_HOME/jj/repos"
  if [[ -d "$d" ]]; then find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort; fi
}
real_jj_repo_leaks() {  # real_jj_repo_leaks BEFORE_FILE PREFIX… — new real-jj-repos entries that record one of OUR directories
  local before="$1" n d out="" pre args=(); shift
  d="$REAL_XDG_CONFIG_HOME/jj/repos"
  for pre in "$@"; do [[ -z "$pre" ]] || args+=(-e "$pre"); done
  [[ -d "$d" && ${#args[@]} -gt 0 ]] || return 0
  while IFS= read -r n; do
    [[ -n "$n" && "$n" != . && "$n" != .. ]] || continue
    if grep -qaF "${args[@]}" "$d/$n/metadata.binpb" "$d/$n/config.toml" 2>/dev/null; then out+="$n "; fi
  done < <(comm -13 "$before" <(real_jj_repo_names))
  printf '%s' "$out"
}
REAL_CFG_BEFORE="$(real_cfg_sig)"
real_jj_repo_names > "$ISO_HOME/jj-repos.before"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="$ROOT/scripts/swarm.sh"

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
# Fixture state that must NOT be inside the repository under test (an in-project TMPDIR/HOME shows up as parent
# drift to the parent guard while lanes run): a sibling dir, cleaned with TMP.
OUTSIDE="$(mktemp -d)"
trap 'cd /; rm -rf "$TMP" "$OUTSIDE" "$ISO_HOME"' EXIT

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
   && grep -Fq 'Git fallback backend' <<<"$OUT" && grep -Fq 'scripts/test-jj-swarm.sh' <<<"$OUT" \
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

# 14) the default backend falls back from jj to git with ONE visible notice (this repo is not a jj repo)
reset_swarm
run -n 1 --max-iterations 1 --dry-run -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ "$(grep -c 'using the git backend' <<<"$OUT")" -eq 1 ]] && grep -q 'backend=git' <<<"$OUT"; then
  pass "default backend falls back to git with exactly one visible notice"
else
  fail "no single visible git-fallback notice (rc=$RC): $OUT"
fi
# an explicit --backend jj keeps today's hard failure instead of falling back
run --backend jj -n 1 --max-iterations 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 2 ]] && ! grep -q 'using the git backend' <<<"$OUT" && [[ ! -d .wgm/worktrees ]]; then
  pass "explicit --backend jj does not fall back"
else
  fail "explicit --backend jj fell back or created lanes (rc=$RC): $OUT"
fi

# 15) preflight refusal creates NO lane resources: sandbox forced on (WGM_DEVCONTAINER unset, throwaway HOME and
# XDG_CONFIG_HOME), every engine broken, headless -> exit 2 before any workspace, branch, log or metrics dir.
STUBS="$OUTSIDE/stub-engines"; mkdir -p "$STUBS" "$OUTSIDE/home/.config" "$OUTSIDE/swarm-tmp"
for e in podman docker; do printf '#!/bin/sh\nexit 1\n' > "$STUBS/$e"; chmod +x "$STUBS/$e"; done
reset_swarm
set +e
OUT="$(env -u WGM_DEVCONTAINER HOME="$OUTSIDE/home" XDG_CONFIG_HOME="$OUTSIDE/home/.config" TMPDIR="$OUTSIDE/swarm-tmp" PATH="$STUBS:$PATH" \
  "$SWARM" --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}" </dev/null 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 2 ]] && grep -q 'no lane was created' <<<"$OUT" \
   && [[ ! -e .wgm/worktrees && ! -e .wgm/swarm-logs && ! -e .wgm/metrics ]] \
   && [[ -z "$(git for-each-ref refs/heads/wgm/)" ]] && [[ -z "$(ls -A "$OUTSIDE/swarm-tmp")" ]] \
   && [[ "$(git worktree list | wc -l)" -eq 1 ]]; then   # (the throwaway preflight workspace is gone too)
  pass "a sandbox preflight refusal exits 2 and leaves no lane, branch, dir or decision file"
else
  fail "preflight refusal left resources or wrong status (rc=$RC): $OUT"
fi

# 16) decision hand-off: ONE preflight, one run-scoped 0600 decision file, lanes reuse it silently (they print
# the decision's label and never preflight/prompt), telemetry carries the sandbox line, and the file is gone.
reset_swarm
set +e
OUT="$(TMPDIR="$OUTSIDE/swarm-tmp" "$SWARM" --no-devcontainer --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 0 ]] && grep -q 'sandbox: OFF (operator-flag)' <<<"$OUT" \
   && grep -q 'sandbox: OFF — unsandboxed (operator-flag)' .wgm/swarm-logs/wgm-swarm-1.log \
   && grep -q 'sandbox: OFF — unsandboxed (operator-flag)' .wgm/swarm-logs/wgm-swarm-2.log \
   && [[ -z "$(ls -A "$OUTSIDE/swarm-tmp")" ]]; then
  pass "swarm hands one decision to every lane, reports it in telemetry, and deletes the decision file"
else
  fail "decision hand-off/telemetry/cleanup wrong (rc=$RC): $OUT
$(tail -n 8 .wgm/swarm-logs/*.log 2>&1)"
fi
# a lane's failure status survives the cleanup trap (swarm's own exit status is what the caller sees)
reset_swarm
set +e
OUT="$(TMPDIR="$OUTSIDE/swarm-tmp" "$SWARM" --no-devcontainer --tasks tasks.txt --max-iterations 1 -- "${AGENT_NOOP[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && [[ -z "$(ls -A "$OUTSIDE/swarm-tmp")" ]]; then
  pass "a failing lane keeps its non-zero status through decision-file cleanup"
else
  fail "failing-lane status lost or decision file left behind (rc=$RC): $OUT"
fi
reset_swarm
git reset -q --hard "$BASE"

# 17) GIT SPLIT (C2): every host git call swarm.sh makes is neutralized; porcelain (status/diff/switch/...) runs
# ONLY on the operator's parent checkout, never on a lane workspace (lanes get plumbing only). A PATH git wrapper
# logs cwd + argv for calls made by swarm itself (lane loops carry WGM_SWARM_LANE and are not swarm's calls).
GITLOG="$OUTSIDE/git-calls.log"; GITBIN="$OUTSIDE/gitlog-bin"; mkdir -p "$GITBIN"; : > "$GITLOG"
REAL_GIT_BIN="$(command -v git)"
cat > "$GITBIN/git" <<SH
#!/usr/bin/env bash
if [[ -z "\${WGM_SWARM_LANE:-}" ]]; then printf '%s\t%s\n' "\$PWD" "\$*" >> "$GITLOG"; fi
exec "$REAL_GIT_BIN" "\$@"
SH
chmod +x "$GITBIN/git"
reset_swarm
PARENT_PHYS="$(pwd -P)"
set +e
OUT="$(PATH="$GITBIN:$PATH" "$SWARM" --no-devcontainer --tasks tasks.txt --max-iterations 1 --cleanup -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
set -e
bad=""; total=0
while IFS=$'\t' read -r gcwd gargs; do
  total=$((total + 1))
  [[ "$gargs" == *"core.fsmonitor=false"* && "$gargs" == *"core.hooksPath=/dev/null"* && "$gargs" == *"protocol.allow=never"* ]] \
    || { [[ "$gargs" == "worktree add -h"* ]] || bad+=$'\n'"not neutralized: $gargs"; continue; }
  # strip leading "-c key=value" pairs, then an optional "-C dir"
  rest="$gargs"; target="$gcwd"
  while [[ "$rest" == "-c "* ]]; do rest="${rest#-c * }"; done
  if [[ "$rest" == "-C "* ]]; then rest="${rest#-C }"; target="${rest%% *}"; rest="${rest#* }"; fi
  sub="${rest%% *}"
  case "$sub" in
    status|diff|switch|branch|checkout|add|commit|merge|stash|reset|log|pull|fetch|push|clean|restore)
      [[ "$sub" == branch && "$rest" == "branch -D"* ]] && continue
      [[ "$(cd "$target" 2>/dev/null && pwd -P)" == "$PARENT_PHYS" ]] || bad+=$'\n'"porcelain on a non-parent path ($target): $gargs" ;;
    ls-files) [[ "$rest" == *" -m"* ]] && { [[ "$(cd "$target" 2>/dev/null && pwd -P)" == "$PARENT_PHYS" ]] || bad+=$'\n'"ls-files -m on a lane ($target)"; } ;;
  esac
done < "$GITLOG"
if [[ "$RC" -eq 0 && "$total" -gt 10 && -z "$bad" ]]; then
  pass "host git: every swarm call is neutralized; porcelain runs only on the parent checkout ($total calls)"
else
  fail "host git split violated (rc=$RC, calls=$total):$bad"
fi
reset_swarm
git reset -q --hard "$BASE"

# 18) gate parsing (rugged F2): each gate stays ONE separate entry; only a quote pair wrapping the WHOLE entry is
# stripped, so `sh -c 'echo ready'`, $VARs, && and spaces reach `bash -c` intact (never joined, never half-stripped).
cat > "$OUTSIDE/quote-gates.yml" <<'YML'
gates:
  - sh -c 'echo ready'
  - test -n "$HOME" && echo "a b"
  - "echo wrapped"
  - 'echo $HOME >/dev/null'
YML
reset_swarm
run -n 1 --gates "$OUTSIDE/quote-gates.yml" --dry-run -- "${AGENT_OK[@]}"
# shellcheck disable=SC2016  # the expected gate text deliberately contains a literal $VAR
if [[ "$RC" -eq 0 ]] && grep -Fxq "  gate: sh -c 'echo ready'" <<<"$OUT" \
   && grep -Fxq '  gate: test -n "$HOME" && echo "a b"' <<<"$OUT" \
   && grep -Fxq '  gate: echo wrapped' <<<"$OUT" && grep -Fxq '  gate: echo $HOME >/dev/null' <<<"$OUT"; then
  pass "swarm gates keep inner quotes, \$VAR, && and spaces; only a whole-entry wrapping pair is stripped"
else
  fail "swarm gate parsing mangled an entry (rc=$RC): $OUT"
fi

# 19) cleanup accountability (rugged F3): when the engine's \`ps\` fails, the sweep must NOT read that as "nothing
# left": it returns non-zero and names every lane loop's container handle. (The function is extracted from
# swarm.sh and run against a stub engine; swarm turns its failure into a non-zero exit via \`|| FAIL=1\`.)
cat > "$STUBS/failps" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$STUBS/failps"
SWEEP_SRC="$(sed -n '/^sweep_containers() {/,/^}/p' "$ROOT/scripts/swarm.sh")"
sweep_unverified() (
  # the REAL sb_bounded (lane u) bounds every engine call; sb_reap is stubbed below
  # shellcheck source=scripts/sandbox.sh disable=SC1091
  source "$ROOT/scripts/sandbox.sh"
  # shellcheck disable=SC2034  # these four are read by the extracted sweep_containers
  SWARM_SB_MODE=on
  # shellcheck disable=SC2034
  SB_KEY8=abcd1234
  # shellcheck disable=SC2034
  SB_ENGINE="${SWEEP_ENGINE:-$STUBS/failps}"
  # shellcheck disable=SC2034
  LANE_LOOP_PIDS=(4242 4343)
  # shellcheck disable=SC2317,SC2329  # invoked indirectly (by the eval'd sweep_containers)
  sb_reap() { [[ -z "${REAPLOG:-}" ]] || printf '%s\n' "$1" >> "$REAPLOG"; return 0; }
  eval "$SWEEP_SRC"
  sweep_containers
)
set +e
OUT="$(sweep_unverified 2>&1)"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -Fq 'cleanup unverified: retained container wgm-abcd1234-4242-' <<<"$OUT" \
   && grep -Fq 'cleanup unverified: retained container wgm-abcd1234-4343-' <<<"$OUT"; then
  pass "a failing engine ps is reported as unverified cleanup (non-zero), naming each lane container handle"
else
  fail "engine ps failure was read as 'nothing left' (rc=$RC): $OUT"
fi
# 19a) the sweep reaps ONLY this swarm's own lane-loop containers (membership in LANE_LOOP_PIDS): a container retained
# by an unrelated, finished loop of the same repository (same key, a dead pid) must survive.
cat > "$STUBS/listps" <<'SH'
#!/bin/sh
printf 'wgm-abcd1234-4242-1\nwgm-abcd1234-99999-1\nwgm-otherkey-4242-1\n'
SH
chmod +x "$STUBS/listps"
REAPLOG="$OUTSIDE/reaplog"; : > "$REAPLOG"
set +e
OUT="$(REAPLOG="$REAPLOG" SWEEP_ENGINE="$STUBS/listps" sweep_unverified 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 0 ]] && [[ "$(cat "$REAPLOG")" == "wgm-abcd1234-4242-1" ]]; then
  pass "the sweep reaps only containers of this swarm's lane loops; another run's retained container survives"
else
  fail "sweep touched a container that is not this swarm's (rc=$RC reaped=[$(tr '\n' ' ' < "$REAPLOG")]): $OUT"
fi
# 19b) a HUNG engine client (its `ps` never returns) must not hang the sweep: it finishes within the bound, prints the
# same retained lines and returns non-zero (every engine call goes through lane u's sb_bounded).
cat > "$STUBS/hangps" <<'SH'
#!/bin/sh
sleep 120
SH
chmod +x "$STUBS/hangps"
set +e
t0=$SECONDS
OUT="$(SWEEP_ENGINE="$STUBS/hangps" SB_CALL_BOUND=2 sweep_unverified 2>&1)"; RC=$?
hang_secs=$((SECONDS - t0))
set -e
if [[ "$RC" -ne 0 && "$hang_secs" -lt 60 ]] && grep -Fq 'cleanup unverified: retained container wgm-abcd1234-4242-' <<<"$OUT" \
   && grep -Fq 'cleanup unverified: retained container wgm-abcd1234-4343-' <<<"$OUT"; then
  pass "a hanging engine ps is bounded: sweep done in ${hang_secs}s with the retained lines and a non-zero status"
else
  fail "hung engine ps hung or hid the retained containers (rc=$RC secs=$hang_secs): $OUT"
fi
# shellcheck disable=SC2016  # the patterns are literal source text
if grep -Fq 'sweep_containers || sweep_rc=$?' "$ROOT/scripts/swarm.sh" && grep -Fq '[[ "$sweep_rc" -eq 0 ]] || FAIL=1' "$ROOT/scripts/swarm.sh" \
   && grep -Fq 'if [[ "$sweep_rc" -ne 0 ]] || containment_lost_any; then swarm_containment_stop; fi' "$ROOT/scripts/swarm.sh"; then
  pass "swarm folds an unverified sweep into its exit status"
else
  fail "swarm ignores the sweep result"
fi

# 19c) telemetry counts ONLY rows written during THIS run: ledger paths are reused per prefix/lane number and loop.sh
# APPENDS, so a stale row from a previous run (here: 9999 s of "active" time) must not be summed into this run's agent time.
reset_swarm
mkdir -p .wgm/metrics
printf 'start_timestamp\tend_timestamp\titer\tmode\tagent\tduration_s\tplan_changed\tresult\tcost\tparent\tsandbox\n2020-01-01T00:00:00Z\t2020-01-01T02:46:39Z\t1\tbuild\told\t9999\ty\tok\t0\tprevious-run\tcontainer:podman\n' > .wgm/metrics/wgm-swarm-1.tsv
run -n 1 --max-iterations 1 --no-devcontainer -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -Eq 'agent time \(active\):\s+0h00m0[0-9]s' <<<"$OUT" && ! grep -Fq '2h46m39s' <<<"$OUT" \
   && grep -Fq 'turns timed/missing:       1/0' <<<"$OUT"; then
  pass "telemetry reads only this run's ledger rows (a previous run's 9999 s row is not counted)"
else
  fail "stale ledger rows leaked into this run's telemetry (rc=$RC): $(grep -E 'agent time|turns timed' <<<"$OUT")"
fi
reset_swarm
git reset -q --hard "$BASE"

# 20) swarm's help/usage and argument-error paths run BEFORE the host tools are bound: they must be builtins-only. With an
# empty PATH nothing external can run, so any external call would print "command not found".
BASH_BIN="$(command -v bash)"
for args in "--help" "--bogus" "-n abc" "--backend zzz -n 1" "--tasks"; do
  set +e
  # shellcheck disable=SC2086  # the words are intentionally split into separate arguments
  OUT="$(env -i PATH=/nonexistent "$BASH_BIN" "$SWARM" $args 2>&1)"; RC=$?
  set -e
  if ! grep -Fq 'command not found' <<<"$OUT" && ! grep -Fq 'No such file' <<<"$OUT"; then
    pass "swarm '$args' runs builtins-only (no external command reached with an empty PATH, rc=$RC)"
  else
    fail "swarm '$args' reached an external command before the host tools were bound: $OUT"
  fi
done

# positive control: the signature really notices a change under a (stand-in) real config dir
if (
  REAL_XDG_CONFIG_HOME="$ISO_HOME/fake-real-config"; REAL_HOME="$ISO_HOME/fake-real-home"; mkdir -p "$REAL_XDG_CONFIG_HOME/wgm" "$REAL_XDG_CONFIG_HOME/jj/repos"
  sig_a="$(real_cfg_sig)"; : > "$REAL_XDG_CONFIG_HOME/wgm/touched"; sig_b="$(real_cfg_sig)"
  [[ "$sig_a" != "$sig_b" ]] || exit 1
  # the jj repos check: a new entry recording one of OUR dirs is a leak; another tool's new entry is not
  real_jj_repo_names > "$ISO_HOME/fake-before"
  mkdir -p "$REAL_XDG_CONFIG_HOME/jj/repos/aaaa" "$REAL_XDG_CONFIG_HOME/jj/repos/bbbb"
  printf 'U%s/proj/.jj/repo' "$ISO_HOME" > "$REAL_XDG_CONFIG_HOME/jj/repos/aaaa/metadata.binpb"
  printf 'U/somewhere/else/.jj/repo' > "$REAL_XDG_CONFIG_HOME/jj/repos/bbbb/metadata.binpb"
  [[ "$(real_jj_repo_leaks "$ISO_HOME/fake-before" "$ISO_HOME")" == "aaaa " ]]
); then pass "the real-config signature detects a change, and the jj repos check flags only entries recording this harness's dirs (positive control)"
else fail "the real-config signature / jj repos leak check did not behave under a stand-in config dir"; fi
# the operator's real config dirs were not touched by any case of this harness
real_jj_leaks="$(real_jj_repo_leaks "$ISO_HOME/jj-repos.before" "$ISO_HOME" "${TMP:-}" "${OUTSIDE:-}")"
if [[ "$(real_cfg_sig)" == "$REAL_CFG_BEFORE" && -z "$real_jj_leaks" ]]; then
  pass "the operator's real HOME/XDG config (wgm, jj, git, .gitconfig) is exactly as before the run; no new real jj repo entry records a directory of this harness"
else
  fail "the harness touched the operator's real config (changed listing: $(diff <(printf '%s\n' "$REAL_CFG_BEFORE") <(real_cfg_sig) | head -10); new real jj repos entries recording this harness's dirs: [$real_jj_leaks])"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "swarm harness: GREEN"
  exit 0
else
  echo "swarm harness: RED" >&2
  exit 1
fi
