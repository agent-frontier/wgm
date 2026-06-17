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
git add -A && git commit -qm seed
BASE="$(git rev-parse HEAD)"

# Fake agent: appends to the plan so loop.sh's --commit has something to commit on each branch.
AGENT_OK=(bash -c 'printf -- "- did work\n" >> IMPLEMENTATION_PLAN.md' _)

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
  rm -rf .wgm/worktrees
}

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

# 5) re-running with an existing branch is skipped (no duplicate / clobbered run)
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}"   # first run creates the branches
run --tasks tasks.txt --max-iterations 1 -- "${AGENT_OK[@]}"   # second run: both already exist
if [[ "$RC" -ne 0 ]] && grep -q "already exists" <<<"$OUT"; then
  pass "an existing swarm branch is skipped, not clobbered"
else
  fail "did not skip an existing swarm run (rc=$RC)"
fi
reset_swarm

# 6) a missing --tasks file is rejected before anything runs
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
