#!/usr/bin/env bash
#
# wgm/test-loop.sh — deterministic backpressure for scripts/loop.sh.
#
# Exercises the operational-limit knobs (--max-runtime-seconds, --idle-timeout,
# --checkpoint-interval, --notify), the resilience knobs (--max-retries with backoff,
# --max-consecutive-failures circuit breaker), and the metrics ledger (--metrics, --cost-cmd) with a
# fake agent in a throwaway git repo, so the loop's safety behavior has a real pass/fail signal. No
# real agent, model, or network is needed.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/scripts/loop.sh"

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

# Fake agents (argv after `--`; loop.sh appends the prompt as a trailing arg the script ignores).
AGENT_PROGRESS=(bash -c 'printf -- "- step\n" >> IMPLEMENTATION_PLAN.md' _)  # changes the plan
AGENT_IDLE=(bash -c 'sleep 2' _)                                            # no change, burns time
AGENT_SLOW=(bash -c 'sleep 2; printf -- "- slow\n" >> IMPLEMENTATION_PLAN.md' _)

OUT=""; RC=0
run() {  # run loop.sh, capturing combined output + exit code without tripping set -e
  set +e
  OUT="$("$LOOP" "$@" 2>&1)"; RC=$?
  set -e
}

# 1) a non-integer knob value is rejected before anything runs
run build --checkpoint-interval xyz -- true
if [[ "$RC" -eq 2 ]] && grep -q "non-negative integer" <<<"$OUT"; then
  pass "rejects a non-integer --checkpoint-interval"
else
  fail "did not reject a bad --checkpoint-interval (rc=$RC)"
fi

# 2) --dry-run surfaces the new limit knobs
run build --dry-run --max-runtime-seconds 30 --idle-timeout 15 --checkpoint-interval 5 --notify 'echo hi' -- true
if [[ "$RC" -eq 0 ]] && grep -q "max_runtime=30s idle_timeout=15s checkpoint_interval=5 notify=set" <<<"$OUT"; then
  pass "dry-run surfaces the limit knobs"
else
  fail "dry-run did not surface the limit knobs (rc=$RC)"
fi

# 3) --checkpoint-interval 1 auto-commits after every build iteration
before="$(git rev-list --count HEAD)"
run build 3 --checkpoint-interval 1 -- "${AGENT_PROGRESS[@]}"
after="$(git rev-list --count HEAD)"
if [[ "$RC" -eq 0 ]] && [[ $((after - before)) -eq 3 ]]; then
  pass "checkpoint-interval commits each iteration (+$((after - before)))"
else
  fail "expected 3 checkpoint commits, got $((after - before)) (rc=$RC)"
fi

# 4) --max-runtime-seconds caps the wall clock
run build 10 --max-runtime-seconds 1 -- "${AGENT_SLOW[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Reached max runtime" <<<"$OUT"; then
  pass "max-runtime-seconds halts the loop"
else
  fail "max-runtime-seconds did not halt the loop (rc=$RC)"
fi

# 5) --idle-timeout halts when the plan stops progressing
run build 10 --idle-timeout 1 -- "${AGENT_IDLE[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Idle timeout" <<<"$OUT"; then
  pass "idle-timeout halts a stuck loop"
else
  fail "idle-timeout did not halt a stuck loop (rc=$RC)"
fi

# 6) --notify fires the start + complete lifecycle events
# shellcheck disable=SC2016  # $WGM_EVENT must stay literal here; loop.sh expands it at notify time
run build 1 --notify 'printf "%s\n" "$WGM_EVENT" >> events.log' -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 ]] && [[ -f events.log ]] && grep -qx start events.log && grep -qx complete events.log; then
  pass "notify emits start + complete"
else
  fail "notify did not emit both start and complete"
fi

# 7) portability: run by absolute path from a foreign cwd resolves the plan in THIS dir
run build --dry-run -- true
if [[ "$RC" -eq 0 ]] && grep -q "plan=IMPLEMENTATION_PLAN.md" <<<"$OUT" && ! grep -q "none yet" <<<"$OUT"; then
  pass "runs by absolute path against the current directory (portable across projects)"
else
  fail "did not resolve the cwd plan when run by absolute path (rc=$RC)"
fi

# 8) wgm.yml gates are auto-detected, parsed, and injected into the build prompt
printf 'gates:\n  - echo gate-a\n  - echo gate-b\n' > wgm.yml
run build --dry-run -- true
if [[ "$RC" -eq 0 ]] && grep -q "gates=wgm.yml (2)" <<<"$OUT" && grep -q "Project gates" <<<"$OUT"; then
  pass "wgm.yml gates are auto-detected and injected"
else
  fail "wgm.yml gates not detected/injected (rc=$RC)"
fi

# 9) a missing --gates file is rejected before running
run build --gates does-not-exist.yml --dry-run -- true
if [[ "$RC" -eq 2 ]] && grep -q "gates file not found" <<<"$OUT"; then
  pass "missing --gates file is rejected"
else
  fail "missing --gates file not rejected (rc=$RC)"
fi
rm -f wgm.yml

# 10) --dry-run surfaces the resilience knobs
run build --dry-run --max-retries 4 --retry-base-delay 1 --max-consecutive-failures 5 -- true
if [[ "$RC" -eq 0 ]] && grep -q "retries=4 retry_base=1s retry_max=60s circuit_breaker=5" <<<"$OUT"; then
  pass "dry-run surfaces the retry + circuit-breaker knobs"
else
  fail "dry-run did not surface the resilience knobs (rc=$RC)"
fi

# 11) a non-integer --max-retries is rejected before running
run build --max-retries xyz --dry-run -- true
if [[ "$RC" -eq 2 ]] && grep -q "non-negative integer" <<<"$OUT"; then
  pass "rejects a non-integer --max-retries"
else
  fail "did not reject a bad --max-retries (rc=$RC)"
fi

# 12) a transient agent failure is retried and recovers (the loop does not abort)
rm -f .retry_n
# shellcheck disable=SC2016  # the agent script body must stay literal; loop.sh's child shell expands it
AGENT_FLAKY=(bash -c 'n=$(cat .retry_n 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > .retry_n; [ "$n" -ge 2 ] || exit 1; printf -- "- recovered\n" >> IMPLEMENTATION_PLAN.md' _)
run build 1 --max-retries 2 --retry-base-delay 0 -- "${AGENT_FLAKY[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "retry 1/2" <<<"$OUT" && grep -q -- "- recovered" IMPLEMENTATION_PLAN.md; then
  pass "retries a transient agent failure and recovers"
else
  fail "did not recover from a transient failure (rc=$RC)"
fi
rm -f .retry_n

# 13) persistent failure trips the circuit breaker (and does not loop forever)
AGENT_FAIL=(bash -c 'exit 1' _)
run build 10 --max-retries 0 --retry-base-delay 0 --max-consecutive-failures 2 -- "${AGENT_FAIL[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Circuit breaker: 2 consecutive" <<<"$OUT"; then
  pass "circuit breaker stops after N consecutive failures"
else
  fail "circuit breaker did not trip on persistent failure (rc=$RC)"
fi

# 14) --metrics logs a header + one row per iteration
rm -f metrics.tsv
run build 2 --metrics metrics.tsv -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 && -f metrics.tsv ]] && head -1 metrics.tsv | grep -q "timestamp" && head -1 metrics.tsv | grep -q "cost" && [[ "$(($(wc -l < metrics.tsv) - 1))" -eq 2 ]] && grep -q $'\tok\t' metrics.tsv; then
  pass "metrics ledger logs a header + a row per iteration"
else
  fail "metrics ledger did not log expected rows (rc=$RC)"
fi
rm -f metrics.tsv

# 15) --cost-cmd populates the cost column
run build 1 --metrics metrics.tsv --cost-cmd 'echo 0.42' -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 ]] && tail -1 metrics.tsv | grep -q "0.42"; then
  pass "cost-cmd populates the cost column"
else
  fail "cost-cmd did not populate the cost column (rc=$RC)"
fi
rm -f metrics.tsv

# 16) --dry-run surfaces the metrics knobs
run build --dry-run --metrics m.tsv --cost-cmd 'echo x' -- true
if [[ "$RC" -eq 0 ]] && grep -q "metrics=m.tsv cost_cmd=set" <<<"$OUT"; then
  pass "dry-run surfaces the metrics knobs"
else
  fail "dry-run did not surface the metrics knobs (rc=$RC)"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "loop harness: GREEN"
  exit 0
else
  echo "loop harness: RED" >&2
  exit 1
fi
