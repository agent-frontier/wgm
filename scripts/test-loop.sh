#!/usr/bin/env bash
#
# wgm/test-loop.sh — deterministic backpressure for scripts/loop.sh.
#
# Exercises the operational-limit knobs (--max-runtime-seconds, --idle-timeout,
# --checkpoint-interval, --notify), the resilience knobs (--max-retries with backoff,
# --max-consecutive-failures circuit breaker), the metrics ledger (--metrics, --cost-cmd), and the
# cost ceiling (--max-cost) with a fake agent in a throwaway git repo, so the loop's safety behavior
# has a real pass/fail signal. No real agent, model, or network is needed.
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
# The probe-aware agents model a real full-shell invocation: they create only the requested probe
# during preflight, then write the plan and ownership manifest during a build iteration.
# shellcheck disable=SC2016
AGENT_PROGRESS=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; if [[ -n "${WGM_OWNERSHIP_MANIFEST:-}" ]]; then printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"; fi' _)  # changes the plan
# shellcheck disable=SC2016
AGENT_IDLE=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; sleep 2' _) # no change, burns time
# shellcheck disable=SC2016
AGENT_SLOW=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; sleep 2; printf -- "- slow\n" >> IMPLEMENTATION_PLAN.md; if [[ -n "${WGM_OWNERSHIP_MANIFEST:-}" ]]; then printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"; fi' _)
# shellcheck disable=SC2016
# shellcheck disable=SC2016
AGENT_FORK_HANG=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; (sleep 10) & child=$!; echo "$child" > child.pid; wait "$child"' _)
AGENT_NO_WRITE=(bash -c 'exit 0' _)
# shellcheck disable=SC2016
AGENT_PLAN_NOOP=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; exit 0' _)
# shellcheck disable=SC2016
AGENT_CUSTOM_PLAN=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; mkdir -p "$(dirname "$WGM_PLAN_FILE")"; printf "# custom plan\n\n- generated\n" > "$WGM_PLAN_FILE"' _)
# shellcheck disable=SC2016
AGENT_EXTRACT_CREATE=(bash -c 'mkdir -p .wgm; printf "# Genes\n\n- reusable pattern\n" > .wgm/genes.md' _)
# shellcheck disable=SC2016
AGENT_EXTRACT_WGM_AGENT=(bash -c 'mkdir -p .wgm; printf "## Codebase patterns\n- reusable pattern\n" > .wgm/AGENTS.md' _)
# shellcheck disable=SC2016
AGENT_EXTRACT_EMPTY=(bash -c 'mkdir -p .wgm; : > .wgm/genes.md' _)
# shellcheck disable=SC2016
AGENT_EXTRACT_UNRELATED=(bash -c 'printf "unrelated change\n" >> AGENTS.md' _)
# shellcheck disable=SC2016
AGENT_NO_MANIFEST=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md' _)
# shellcheck disable=SC2016
AGENT_FOREIGN=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- step\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"; printf "unrelated\n" > foreign.txt' _)
# shellcheck disable=SC2016
AGENT_COMMIT_FLAKY=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; mkdir -p .wgm; n=$(cat .wgm/.commit_retry_n 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > .wgm/.commit_retry_n; [ "$n" -ge 2 ] || exit 1; printf -- "- commit recovered\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_RENAME=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; mv rename-source.txt rename-dest.txt; git add -A -- rename-source.txt rename-dest.txt; printf -- "- rename\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\nrename-source.txt\nrename-dest.txt\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_STOP=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; mkdir -p .wgm; touch .wgm/STOP' _)

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
run build --dry-run --max-runtime-seconds 30 --idle-timeout 15 --max-no-progress-iterations 3 --checkpoint-interval 5 --notify 'echo hi' -- true
if [[ "$RC" -eq 0 ]] && grep -q "max_runtime=30s idle_timeout=15s no_progress_limit=3 checkpoint_interval=5 notify=set" <<<"$OUT"; then
  pass "dry-run surfaces the limit knobs"
else
  fail "dry-run did not surface the limit knobs (rc=$RC)"
fi

# 2a) explicit auto uses the same availability resolver as the default
run build --dry-run --container auto -- true
if [[ "$RC" -eq 0 ]] && grep -qE "container=(podman|docker|unavailable)" <<<"$OUT"; then
  pass "explicit container auto resolves without treating auto as an executable"
else
  fail "explicit container auto did not resolve (rc=$RC): $OUT"
fi
run build --dry-run --devcontainer --devcontainer-mount "$TMP/auth:/home/wgm/.copilot" -- true
if [[ "$RC" -eq 0 ]] && grep -q "mounts=1" <<<"$OUT"; then
  pass "devcontainer auth mounts are forwarded by the loop"
else
  fail "devcontainer auth mount was not surfaced (rc=$RC): $OUT"
fi

# 2b) a successful but non-writing agent is rejected before the first paid iteration
run build 1 --max-retries 0 -- "${AGENT_NO_WRITE[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Capability probe failed" <<<"$OUT"; then
  pass "capability probe rejects an exit-0 agent that cannot write"
else
  fail "capability probe did not reject the silent agent (rc=$RC)"
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

# 3b) --commit refuses a human edit that predates the loop
printf 'human edit\n' > human.txt
run build 1 --commit -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "requires a clean worktree" <<<"$OUT"; then
  pass "--commit refuses a dirty baseline instead of sweeping it into a loop commit"
else
  fail "--commit did not refuse the dirty baseline (rc=$RC)"
fi
rm -f human.txt

# 3c) a changed iteration without a manifest is not committed
run build 1 --commit --max-retries 0 -- "${AGENT_NO_MANIFEST[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "ownership manifest is missing" <<<"$OUT"; then
  pass "--commit requires an ownership manifest even when staging would be empty"
else
  fail "--commit accepted a missing ownership manifest (rc=$RC)"
fi
git show HEAD:IMPLEMENTATION_PLAN.md > IMPLEMENTATION_PLAN.md

# 3d) an iteration that changes an undeclared path is not committed
run build 1 --commit --max-retries 0 -- "${AGENT_FOREIGN[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "absent from its ownership manifest" <<<"$OUT"; then
  pass "--commit refuses an undeclared concurrent edit"
else
  fail "--commit did not reject the undeclared path (rc=$RC)"
fi
git show HEAD:IMPLEMENTATION_PLAN.md > IMPLEMENTATION_PLAN.md
rm -f foreign.txt .wgm/.loop-touched-* .wgm/.loop-owned-* .wgm/.loop-actual-*

# 3e) a failed commit-mode iteration does not poison the next manifest
run build 2 --commit --max-retries 0 -- "${AGENT_COMMIT_FLAKY[@]}"
if [[ "$RC" -eq 0 && "$(git log --oneline --all | grep -c 'chore: wgm build iteration' || true)" -ge 1 ]]; then
  pass "commit-mode recovery discards the failed iteration manifest"
else
  fail "commit-mode recovery retained a stale manifest (rc=$RC): $OUT"
fi
rm -f .wgm/.commit_retry_n
git show HEAD:IMPLEMENTATION_PLAN.md > IMPLEMENTATION_PLAN.md

# 3f) a declared rename stages both repository paths without false ownership drift
printf 'rename content\n' > rename-source.txt
git add rename-source.txt && git commit -qm rename-seed
run build 1 --commit --max-retries 0 -- "${AGENT_RENAME[@]}"
if [[ "$RC" -eq 0 && ! -e rename-source.txt && -e rename-dest.txt ]] \
  && git show --format= --name-status HEAD | grep -q '^R'; then
  pass "--commit accepts a declared rename"
else
  fail "--commit mishandled a declared rename (rc=$RC)"
fi

# 4) --max-runtime-seconds caps the wall clock
run build 10 --max-runtime-seconds 1 -- "${AGENT_SLOW[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Reached max runtime" <<<"$OUT"; then
  pass "max-runtime-seconds halts the loop"
else
  fail "max-runtime-seconds did not halt the loop (rc=$RC)"
fi

# 5) --idle-timeout halts when the plan stops progressing
run build 10 --idle-timeout 1 --max-no-progress-iterations 0 -- "${AGENT_IDLE[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Idle timeout" <<<"$OUT"; then
  pass "idle-timeout halts a stuck loop"
else
  fail "idle-timeout did not halt a stuck loop (rc=$RC)"
fi

# 5b) the no-progress guard is independently exercised
run build 10 --idle-timeout 60 --max-no-progress-iterations 1 -- "${AGENT_IDLE[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "No progress: plan unchanged" <<<"$OUT"; then
  pass "no-progress guard halts a stuck loop"
else
  fail "no-progress guard did not halt a stuck loop (rc=$RC)"
fi

# 5c) an active agent is bounded when the host exposes GNU timeout/gtimeout
if { command -v timeout >/dev/null 2>&1 && timeout --help 2>&1 | grep -q -- '--kill-after'; } \
  || { command -v gtimeout >/dev/null 2>&1 && gtimeout --help 2>&1 | grep -q -- '--kill-after'; }; then
  rm -f timeout.tsv child.pid
  run build 1 --agent-timeout-seconds 1 --metrics timeout.tsv --max-retries 0 --max-consecutive-failures 1 -- "${AGENT_FORK_HANG[@]}"
  child_alive=0
  if [[ -f child.pid ]] && kill -0 "$(cat child.pid)" 2>/dev/null; then child_alive=1; fi
  if [[ "$RC" -eq 1 ]] && grep -q "Agent timed out" <<<"$OUT" \
    && grep -q $'\tfail\t' timeout.tsv && [[ "$child_alive" -eq 0 ]]; then
    pass "agent-timeout-seconds terminates the process group and records failure"
  else
    fail "agent-timeout-seconds did not terminate/process-record a hung agent (rc=$RC): $OUT"
  fi
  rm -f timeout.tsv child.pid
else
  run build --dry-run --agent-timeout-seconds 1 -- true
  if [[ "$RC" -eq 0 ]] && grep -q "cooperative" <<<"$OUT"; then
    pass "agent-timeout-seconds reports the cooperative fallback"
  else
    fail "agent-timeout-seconds did not report unsupported-host fallback (rc=$RC)"
  fi
fi

# 5d) a mutating single-phase mode must produce its promised artifact
run extract 1 --metrics off -- "${AGENT_NO_WRITE[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Phase artifact missing" <<<"$OUT"; then
  pass "extract rejects an exit-0 agent with no genes artifact"
else
  fail "extract accepted a missing artifact (rc=$RC)"
fi

# 5e) a fresh project honors .wgm/STOP after the capability probe creates .wgm
STOP_TMP="$(mktemp -d "$TMP/stop.XXXXXX")"
git -C "$STOP_TMP" init -q
git -C "$STOP_TMP" config user.email "wgm-test@example.com"
git -C "$STOP_TMP" config user.name "wgm test"
printf '# plan\n' > "$STOP_TMP/IMPLEMENTATION_PLAN.md"
git -C "$STOP_TMP" add IMPLEMENTATION_PLAN.md && git -C "$STOP_TMP" commit -qm seed
set +e
STOP_OUT="$(cd "$STOP_TMP" && "$LOOP" build 5 --metrics off -- "${AGENT_STOP[@]}" 2>&1)"
STOP_RC=$?
set -e
if [[ "$STOP_RC" -eq 0 ]] && grep -q "Stop sentinel found" <<<"$STOP_OUT"; then
  pass "fresh projects honor the .wgm/STOP sentinel"
else
  fail "fresh project ignored .wgm/STOP (rc=$STOP_RC): $STOP_OUT"
fi

# 5f) plan/extract reject stale pre-existing artifacts when the phase makes no change
run plan 1 --metrics off -- "${AGENT_PLAN_NOOP[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Phase artifact unchanged" <<<"$OUT"; then
  pass "plan rejects a stale unchanged artifact"
else
  fail "plan accepted an unchanged artifact (rc=$RC)"
fi
printf '## Codebase patterns\n' > AGENTS.md
run extract 1 --metrics off -- "${AGENT_NO_WRITE[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Phase artifact unchanged" <<<"$OUT"; then
  pass "extract rejects a stale unchanged artifact"
else
  fail "extract accepted an unchanged artifact (rc=$RC)"
fi
rm -f AGENTS.md

# 5g) frugal/main escalation gets a chance before the no-progress circuit breaker
FRUGAL_CMD="bash -c 'if [[ -n \"\${WGM_CAPABILITY_PROBE_FILE:-}\" ]]; then printf \"%s\" \"\$WGM_CAPABILITY_PROBE_CONTENT\" > \"\$WGM_CAPABILITY_PROBE_FILE\"; exit 0; fi; exit 0' _"
MAIN_CMD="bash -c 'printf -- \"- main\\n\" >> IMPLEMENTATION_PLAN.md' _"
run build 3 --max-no-progress-iterations 3 --escalate-after 2 --retry-base-delay 0 --frugal-agent "$FRUGAL_CMD" --agent "$MAIN_CMD"
if [[ "$RC" -eq 0 ]] && grep -q "escalating to main agent" <<<"$OUT" && grep -q -- "- main" IMPLEMENTATION_PLAN.md; then
  pass "frugal/main escalation runs before the no-progress circuit breaker"
else
  fail "frugal/main escalation did not recover a no-progress run (rc=$RC): $OUT"
fi

# 5h) plan and extract accept meaningful artifacts they actually create or update
run plan 1 --metrics off -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 ]] && grep -q -- "- step" IMPLEMENTATION_PLAN.md; then
  pass "plan accepts a meaningful updated artifact"
else
  fail "plan rejected a meaningful artifact update (rc=$RC)"
fi
rm -f custom/plan.md
run plan 1 --plan custom/plan.md --metrics off -- "${AGENT_CUSTOM_PLAN[@]}"
if [[ "$RC" -eq 0 ]] && [[ -s custom/plan.md ]]; then
  pass "plan supports an explicitly selected new plan path"
else
  fail "plan rejected an explicitly selected new plan path (rc=$RC): $OUT"
fi
run extract 1 --metrics off -- "${AGENT_EXTRACT_CREATE[@]}"
if [[ "$RC" -eq 0 ]] && [[ -s .wgm/genes.md ]]; then
  pass "extract accepts a meaningful genes artifact"
else
  fail "extract rejected a meaningful genes artifact (rc=$RC)"
fi
run extract 1 --metrics off -- "${AGENT_EXTRACT_WGM_AGENT[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Codebase patterns" .wgm/AGENTS.md; then
  pass "extract accepts the existing-project .wgm/AGENTS.md destination"
else
  fail "extract rejected the .wgm/AGENTS.md destination (rc=$RC)"
fi
run extract 1 --metrics off -- "${AGENT_EXTRACT_EMPTY[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Phase artifact invalid" <<<"$OUT"; then
  pass "extract rejects an empty genes artifact"
else
  fail "extract accepted an empty genes artifact (rc=$RC)"
fi
rm -f .wgm/genes.md
rm -f .wgm/AGENTS.md
printf '## Codebase patterns\nexisting pattern\n## Other section\nexisting note\n' > AGENTS.md
run extract 1 --metrics off -- "${AGENT_EXTRACT_UNRELATED[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Phase artifact unchanged" <<<"$OUT"; then
  pass "extract rejects an unrelated AGENTS.md change"
else
  fail "extract accepted an unrelated AGENTS.md change (rc=$RC)"
fi
rm -f AGENTS.md

# 6) --notify fires the start + complete lifecycle events
mkdir -p .wgm
printf '%s\n' '- durable test lesson' > .wgm/memories.md
# shellcheck disable=SC2016  # $WGM_EVENT must stay literal here; loop.sh expands it at notify time
run build 1 --notify 'printf "%s\n" "$WGM_EVENT" >> events.log' -- "${AGENT_STOP[@]}"
if [[ "$RC" -eq 0 ]] && [[ -f events.log ]] && grep -qx start events.log && grep -qx complete events.log; then
  pass "notify emits start + complete"
else
  fail "notify did not emit both start and complete"
fi
if grep -q "Ship/Handoff harvest" <<<"$OUT"; then
  pass "normal build completion invokes the consent-gated harvest hook"
else
  fail "normal build completion did not invoke the harvest hook"
fi
rm -f .wgm/STOP
run build 1 --metrics off -- "${AGENT_STOP[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "memories unchanged; skipping duplicate harvest" <<<"$OUT"; then
  pass "unchanged memories do not trigger duplicate harvest side effects"
else
  fail "unchanged memories triggered an unbounded duplicate harvest (rc=$RC): $OUT"
fi
mkdir -p .github
printf 'consent: false\nauto_report: false\n' > .github/wgm-hive.yml
rm -f .wgm/STOP
run build 1 --metrics off -- "${AGENT_STOP[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "invoking consent-gated harvest-hive hook" <<<"$OUT"; then
  pass "a consent-state change reopens unchanged-memory harvest"
else
  fail "a consent-state change did not reopen harvest (rc=$RC): $OUT"
fi
rm -rf .github .wgm/STOP .wgm/memories.md .wgm/.last-harvest-hash

# 7) portability: run by absolute path from a foreign cwd resolves the plan in THIS dir
run build --dry-run -- true
if [[ "$RC" -eq 0 ]] && grep -q "plan=IMPLEMENTATION_PLAN.md" <<<"$OUT" && ! grep -q "none yet" <<<"$OUT"; then
  pass "runs by absolute path against the current directory (portable across projects)"
else
  fail "did not resolve the cwd plan when run by absolute path (rc=$RC)"
fi

# 7b) existing-project artifact placement prefers the .wgm plan when both are present
mkdir -p .wgm
printf '# wgm plan\n' > .wgm/IMPLEMENTATION_PLAN.md
run build --dry-run -- true
if [[ "$RC" -eq 0 ]] && grep -q "plan=.wgm/IMPLEMENTATION_PLAN.md" <<<"$OUT"; then
  pass "dual-plan projects select the .wgm implementation plan"
else
  fail "dual-plan selection did not prefer .wgm (rc=$RC): $OUT"
fi
rm -f .wgm/IMPLEMENTATION_PLAN.md

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

# 9b) configured project gates execute in the host runner, not only in the prompt
printf 'gates:\n  - false\n' > wgm.yml
run build 1 --max-retries 0 -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Project gate failed" <<<"$OUT"; then
  pass "a failing project gate fails the host iteration"
else
  fail "a failing project gate did not fail the host iteration (rc=$RC): $OUT"
fi
printf 'gates:\n  - true\n' > wgm.yml
run build 1 --max-retries 0 -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "Project gate 1/1" <<<"$OUT"; then
  pass "a passing project gate clears the host iteration"
else
  fail "a passing project gate did not clear the host iteration (rc=$RC): $OUT"
fi
printf 'not_gates: true\n' > wgm.yml
run build --dry-run -- true
if [[ "$RC" -eq 2 ]] && grep -q "must declare a gates" <<<"$OUT"; then
  pass "a malformed project gate file is rejected"
else
  fail "a malformed project gate file was accepted (rc=$RC): $OUT"
fi
printf 'gates:\n' > wgm.yml
run build --dry-run -- true
if [[ "$RC" -eq 2 ]] && grep -q "no executable gate" <<<"$OUT"; then
  pass "an empty project gate list is rejected"
else
  fail "an empty project gate list was accepted (rc=$RC): $OUT"
fi
printf 'gates: [true]\n' > wgm.yml
run build --dry-run -- true
if [[ "$RC" -eq 0 ]] && grep -q "gates=wgm.yml (1)" <<<"$OUT"; then
  pass "an inline project gate list is parsed"
else
  fail "an inline project gate list was not parsed (rc=$RC): $OUT"
fi
printf 'gates:\n  - "true"\n' > wgm.yml
run build --dry-run -- true
if [[ "$RC" -eq 0 ]] && grep -q "gates=wgm.yml (1)" <<<"$OUT"; then
  pass "a quoted block project gate is parsed"
else
  fail "a quoted block project gate was not parsed (rc=$RC): $OUT"
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
AGENT_FLAKY=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; n=$(cat .retry_n 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > .retry_n; [ "$n" -ge 2 ] || exit 1; printf -- "- recovered\n" >> IMPLEMENTATION_PLAN.md' _)
run build 1 --max-retries 2 --retry-base-delay 0 -- "${AGENT_FLAKY[@]}"
if [[ "$RC" -eq 0 ]] && grep -q "retry 1/2" <<<"$OUT" && grep -q -- "- recovered" IMPLEMENTATION_PLAN.md; then
  pass "retries a transient agent failure and recovers"
else
  fail "did not recover from a transient failure (rc=$RC)"
fi
rm -f .retry_n

# 13) persistent failure trips the circuit breaker (and does not loop forever)
# shellcheck disable=SC2016
AGENT_FAIL=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; exit 1' _)
run build 10 --max-retries 0 --retry-base-delay 0 --max-consecutive-failures 2 -- "${AGENT_FAIL[@]}"
if [[ "$RC" -eq 1 ]] && grep -q "Circuit breaker: 2 consecutive" <<<"$OUT"; then
  pass "circuit breaker stops after N consecutive failures"
else
  fail "circuit breaker did not trip on persistent failure (rc=$RC)"
fi

# 14) --metrics logs a header + one row per iteration, with start/end timestamps and a parent column
rm -f metrics.tsv
run build 2 --metrics metrics.tsv -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 && -f metrics.tsv ]] \
  && head -1 metrics.tsv | grep -q "start_timestamp" \
  && head -1 metrics.tsv | grep -q "end_timestamp" \
  && head -1 metrics.tsv | grep -q "parent" \
  && head -1 metrics.tsv | grep -q "cost" \
  && [[ "$(($(wc -l < metrics.tsv) - 1))" -eq 2 ]] && grep -q $'\tok\t' metrics.tsv; then
  pass "metrics ledger logs a header + a row per iteration"
else
  fail "metrics ledger did not log expected rows (rc=$RC)"
fi
rm -f metrics.tsv

# 14b) telemetry is on by default (no --metrics flag) and lands in wgm's own scratch dir
rm -rf .wgm/metrics.tsv
run build 1 -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 && -f .wgm/metrics.tsv ]] && [[ "$(($(wc -l < .wgm/metrics.tsv) - 1))" -eq 1 ]]; then
  pass "telemetry is on by default at .wgm/metrics.tsv"
else
  fail "default telemetry ledger was not written (rc=$RC)"
fi

# 14c) --metrics off disables the ledger entirely
rm -rf .wgm/metrics.tsv
run build 1 --metrics off -- "${AGENT_PROGRESS[@]}"
if [[ "$RC" -eq 0 && ! -f .wgm/metrics.tsv ]]; then
  pass "--metrics off disables telemetry"
else
  fail "--metrics off did not disable telemetry (rc=$RC)"
fi

# 14d) $WGM_PARENT_TASK is recorded so swarm lanes attribute iterations to their parent task
rm -f metrics.tsv
export WGM_PARENT_TASK="lane-7"
run build 1 --metrics metrics.tsv -- "${AGENT_PROGRESS[@]}"
unset WGM_PARENT_TASK
if [[ "$RC" -eq 0 ]] && tail -1 metrics.tsv | grep -q "lane-7"; then
  pass "WGM_PARENT_TASK populates the parent column"
else
  fail "WGM_PARENT_TASK did not populate the parent column (rc=$RC)"
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
if [[ "$RC" -eq 0 ]] && grep -q "metrics=m.tsv cost_cmd=set max_cost=0" <<<"$OUT"; then
  pass "dry-run surfaces the metrics knobs (incl. max_cost)"
else
  fail "dry-run did not surface the metrics knobs (rc=$RC)"
fi

# 17) --max-cost halts the build loop once cumulative cost crosses the ceiling
run build 10 --cost-cmd 'echo 5' --max-cost 12 -- "${AGENT_PROGRESS[@]}"
iters="$(grep -c "wgm build" <<<"$OUT" || true)"
if [[ "$RC" -eq 0 ]] && grep -q "Reached max cost (15 >= 12)" <<<"$OUT" && [[ "$iters" -eq 3 ]]; then
  pass "max-cost halts the loop once cumulative cost is reached (3 iterations, 5+5+5=15>=12)"
else
  fail "max-cost did not halt the loop as expected (rc=$RC, iters=$iters)"
fi

# 18) --max-cost without --cost-cmd warns instead of silently never triggering
run build --dry-run --max-cost 10 -- true
if [[ "$RC" -eq 0 ]] && grep -q -- "--max-cost is set but --cost-cmd is not" <<<"$OUT"; then
  pass "max-cost without cost-cmd warns instead of silently no-op'ing"
else
  fail "did not warn when max-cost set without cost-cmd (rc=$RC)"
fi

# 19) a non-numeric --max-cost is rejected before running
run build --max-cost abc --dry-run -- true
if [[ "$RC" -eq 2 ]] && grep -q "non-negative number for --max-cost" <<<"$OUT"; then
  pass "rejects a non-numeric --max-cost"
else
  fail "did not reject a bad --max-cost (rc=$RC)"
fi

# 20) default --max-cost (0 = unlimited) never halts the loop early — existing behavior unchanged
run build 3 --cost-cmd 'echo 999' -- "${AGENT_PROGRESS[@]}"
iters="$(grep -c "wgm build" <<<"$OUT" || true)"
if [[ "$RC" -eq 0 ]] && ! grep -q "Reached max cost" <<<"$OUT" && [[ "$iters" -eq 3 ]]; then
  pass "default max-cost (0) never halts the loop early"
else
  fail "unexpected early halt with default max-cost (rc=$RC, iters=$iters)"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "loop harness: GREEN"
  exit 0
else
  echo "loop harness: RED" >&2
  exit 1
fi
