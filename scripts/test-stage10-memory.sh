#!/usr/bin/env bash
#
# wgm/test-stage10-memory.sh — deterministic backpressure for the Stage 10 memory foundation.
#
# This harness uses a disposable Git repository and the real stage10_memory.py command. It proves
# the high-risk boundaries before any model or router exists: deterministic observation, safe host
# signals, human-readable generated output, evidence-bearing standing, promotion refusal, source
# staleness, credential refusal, and cleanup. A green process with no observable artifact is not
# enough for Stage 10.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMORY="$ROOT/scripts/stage10_memory.py"
FAILED=0
PASSED=0
pass() { printf 'ok:   %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ -f "$MEMORY" ]] || { fail "missing $MEMORY"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-stage10-memory.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
ROOT_STATE_SNAPSHOT="$TMP/root-stage10.before"
: >"$ROOT_STATE_SNAPSHOT"
if [[ -d "$ROOT/.wgm/stage10" ]]; then
  find "$ROOT/.wgm/stage10" -type f -print | sort | while IFS= read -r path; do
    cksum "$path"
  done >"$ROOT_STATE_SNAPSHOT"
fi
mkdir -p "$PROJECT/scripts" "$PROJECT/docs" "$PROJECT/.github/workflows"

# The fixture is intentionally small but shaped like a real repository: source inventory, a
# validation target, a workflow, and one script. Git history gives observations a real baseline.
cat >"$PROJECT/Makefile" <<'EOF'
.PHONY: test validate

test:
	@printf 'fixture tests pass\n'

validate: test
EOF
cat >"$PROJECT/README.md" <<'EOF'
# Fixture project

The fixture has a deterministic validation path.
EOF
cat >"$PROJECT/scripts/check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fixture check\n'
EOF
chmod +x "$PROJECT/scripts/check.sh"
cat >"$PROJECT/.github/workflows/ci.yml" <<'EOF'
name: fixture-ci
on: [push]
jobs: {}
EOF
# This file must never appear in observations or the generated brief, even though it exists in the
# fixture. The test proves the scanner's safe-path boundary without inspecting its contents later.
printf 'SECRET_TOKEN=fixture-secret-value\n' >"$PROJECT/.env"

if ! git -C "$PROJECT" init -q; then
  fail "could not initialize fixture Git repository"
  exit 1
fi
git -C "$PROJECT" config user.email stage10@example.invalid
git -C "$PROJECT" config user.name stage10-fixture
git -C "$PROJECT" add Makefile README.md scripts/check.sh .github/workflows/ci.yml .env
git -C "$PROJECT" commit -q -m 'fixture: establish baseline'

OUT=""; RC=0
run_memory() {
  set +e
  OUT="$(AI_AGENT=pi PI_CODING_AGENT=true PI_PROVIDER=fixture-provider \
    PI_MODEL=fixture-model PI_REASONING_LEVEL=low \
    PYTHONDONTWRITEBYTECODE=1 python3 "$MEMORY" "$@" 2>&1)"
  RC=$?
  set -e
}

# 1) Inspect writes both source observations and the generated reader-facing view, without a model
# or network. This is the smallest end-to-end memory slice.
run_memory inspect --root "$PROJECT"
if [[ "$RC" -eq 0 ]] && [[ -f "$PROJECT/.wgm/stage10/observations.jsonl" ]] \
   && [[ -f "$PROJECT/.wgm/stage10/brief.md" ]] \
   && [[ -f "$PROJECT/.wgm/stage10/system-map.md" ]] \
   && grep -q "no model call, network call, or credential-file read" <<<"$OUT"; then
  pass "inspect writes observations and a generated brief without model/network work"
else
  fail "inspect did not create the expected artifacts (rc=$RC): $OUT"
fi

# 2) Harness presence and the current host are separate facts. Provider/model signals are allowed;
# the secret-bearing .env is not copied into the output.
BRIEF="$PROJECT/.wgm/stage10/brief.md"
if grep -q 'Current-harness signal: \*\*pi\*\*' "$BRIEF" \
   && grep -q 'fixture-provider.*fixture-model' "$BRIEF" \
   && ! grep -q 'fixture-secret-value\|SECRET_TOKEN' "$BRIEF"; then
  pass "brief reports safe current-host signals and omits credential content"
else
  fail "brief exposed the wrong host facts or a credential-like value"
fi

# 2c) The executable mapping and static compatibility registry are two sources of truth. Keep them
# aligned or lint must make the disagreement visible before routing consumes the inventory.
if grep -q '"unmapped_registry_ids":\[\]' "$PROJECT/.wgm/stage10/observations.jsonl"; then
  pass "known harness registry entries have executable mappings"
else
  fail "harness registry and executable mapping are inconsistent"
fi

# 2a) Holdout material is deliberately placed under .wgm/scenarios. The inspector must not copy or
# cite it into either source observations or the human brief; the actual scenario judge owns that
# directory and remains outside the inspect path.
mkdir -p "$PROJECT/.wgm/scenarios"
printf 'HOLDOUT-ONLY-CONTENT\n' >"$PROJECT/.wgm/scenarios/hidden.yaml"
run_memory inspect --root "$PROJECT"
if [[ "$RC" -eq 0 ]] \
   && ! grep -R -q 'HOLDOUT-ONLY-CONTENT\|hidden.yaml' "$PROJECT/.wgm/stage10"; then
  pass "inspect leaves holdout scenario content outside observations and brief"
else
  fail "inspect copied or cited holdout scenario content (rc=$RC): $OUT"
fi

# 2b) Even an allowlisted host variable is treated as untrusted input. A model/provider value that
# resembles a token is redacted before it reaches the observation source or human view.
SECRET_STATE="$PROJECT/.wgm/stage10-secret"
set +e
SECRET_OUT="$(AI_AGENT=pi PI_CODING_AGENT=true PI_PROVIDER=fixture-provider \
  PI_MODEL='sk-secret-value-12345' PI_REASONING_LEVEL=low \
  PYTHONDONTWRITEBYTECODE=1 python3 "$MEMORY" inspect --root "$PROJECT" \
  --state-dir "$SECRET_STATE" 2>&1)"
SECRET_RC=$?
set -e
if [[ "$SECRET_RC" -eq 0 ]] \
   && ! grep -R -q 'sk-secret-value-12345' "$SECRET_STATE" \
   && grep -R -q '<redacted>' "$SECRET_STATE"; then
  pass "credential-like allowlisted host signals are redacted before persistence"
else
  fail "credential-like host signal was persisted (rc=$SECRET_RC): $SECRET_OUT"
fi

# 3) The view is for humans: it has the expected sections, provenance/refresh instructions, and a
# bounded size instead of dumping raw JSONL into the default surface.
lines="$(wc -l < "$BRIEF")"
bytes="$(wc -c < "$BRIEF")"
if grep -q '^## Snapshot$' "$BRIEF" && grep -q '^## Harnesses$' "$BRIEF" \
   && grep -q '^## Memory$' "$BRIEF" \
   && grep -q 'Refresh with:' "$BRIEF" \
   && [[ "$lines" -le 120 ]] && [[ "$bytes" -le 16000 ]] \
   && ! grep -q 'SECRET_TOKEN' "$BRIEF"; then
  pass "generated human brief is cited, structured, and bounded (${lines} lines, ${bytes} bytes)"
else
  fail "generated brief is not human-readable/bounded (${lines} lines, ${bytes} bytes)"
fi

# 4) A validated record carries an explicit standing, source, and evidence. It is appended to the
# source ledger rather than silently replacing prior history.
run_memory record --root "$PROJECT" --kind lesson --standing validated --scope task \
  --summary 'The fixture validation target is the cheapest deterministic backpressure.' \
  --source 'README.md:3' --evidence 'command:make validate'
if [[ "$RC" -eq 0 ]] && grep -q 'stage10 record: appended mem-' <<<"$OUT" \
   && grep -q 'fixture validation target' "$PROJECT/.wgm/stage10/memory.jsonl"; then
  pass "validated memory records preserve standing, source, and evidence"
else
  fail "validated memory record was not appended correctly (rc=$RC): $OUT"
fi

run_memory brief --root "$PROJECT"
if [[ "$RC" -eq 0 ]] && grep -q 'validated.*fixture validation target' "$BRIEF"; then
  pass "brief renders the recorded memory with its standing"
else
  fail "brief did not render the recorded memory (rc=$RC): $OUT"
fi

# 5) Legacy flat ledgers are imported into the Stage 10 source without being deleted or treated as
# authoritative. A second migration must be idempotent rather than duplicating history.
mkdir -p "$PROJECT/.wgm"
printf '# legacy lessons\n\n- Legacy lesson survives migration.\n' >"$PROJECT/.wgm/memories.md"
printf '| Iteration | Tier | Score | Note | Dominant diagnostic |\n|---|---|---|---|---|\n| 1 | 1 | 100 | Legacy score survives | none |\n' >"$PROJECT/.wgm/scores.md"
legacy_mem_before="$(cksum "$PROJECT/.wgm/memories.md")"
legacy_scores_before="$(cksum "$PROJECT/.wgm/scores.md")"
run_memory migrate --root "$PROJECT"
if [[ "$RC" -eq 0 ]] \
   && grep -q 'imported 2 legacy records' <<<"$OUT" \
   && grep -q 'Legacy lesson survives migration' "$PROJECT/.wgm/stage10/memory.jsonl" \
   && grep -q 'Legacy score: 1 · 1 · 100' "$PROJECT/.wgm/stage10/memory.jsonl" \
   && [[ "$(cksum "$PROJECT/.wgm/memories.md")" == "$legacy_mem_before" ]] \
   && [[ "$(cksum "$PROJECT/.wgm/scores.md")" == "$legacy_scores_before" ]]; then
  pass "legacy memory and score ledgers import without data loss"
else
  fail "legacy ledgers were not imported safely (rc=$RC): $OUT"
fi
run_memory migrate --root "$PROJECT"
if [[ "$RC" -eq 0 ]] && grep -q 'imported 0 legacy records' <<<"$OUT"; then
  pass "legacy migration is idempotent"
else
  fail "legacy migration duplicated records (rc=$RC): $OUT"
fi

# 5b) A suspicious legacy entry must fail the whole migration before appending any partial result.
legacy_count_before="$(wc -l < "$PROJECT/.wgm/stage10/memory.jsonl")"
printf '%s\n' '- Legacy token=must-not-persist' >>"$PROJECT/.wgm/memories.md"
run_memory migrate --root "$PROJECT"
legacy_count_after="$(wc -l < "$PROJECT/.wgm/stage10/memory.jsonl")"
if [[ "$RC" -ne 0 ]] && [[ "$legacy_count_after" -eq "$legacy_count_before" ]] \
   && ! grep -q 'must-not-persist' "$PROJECT/.wgm/stage10/memory.jsonl"; then
  pass "suspicious legacy migration fails without a partial append"
else
  fail "suspicious legacy migration partially persisted data (rc=$RC): $OUT"
fi

# 6) Promotion is deliberately harder than observation. One evidence reference must not become
# broad router policy just because an agent requested a stronger label.
run_memory record --root "$PROJECT" --kind decision --standing promoted --scope project \
  --summary 'A single run proves the universal route.' --source 'README.md:1' \
  --evidence 'command:make validate'
if [[ "$RC" -ne 0 ]] && grep -q 'requires at least two independent evidence references' <<<"$OUT"; then
  pass "promotion without corroborating evidence is rejected"
else
  fail "promotion gate accepted an under-evidenced record (rc=$RC): $OUT"
fi

# 7) The memory lint gate is the backpressure: the baseline is green before a source changes.
run_memory lint --root "$PROJECT"
if [[ "$RC" -eq 0 ]] && grep -q 'stage10 lint: GREEN' <<<"$OUT"; then
  pass "lint accepts the valid observation and memory ledgers"
else
  fail "valid memory ledgers did not lint cleanly (rc=$RC): $OUT"
fi

# 8) A changed hashed source invalidates the observation. The tool must report stale evidence rather
# than quietly allowing the old system map to steer a later iteration.
printf '\nchanged after observation\n' >>"$PROJECT/README.md"
run_memory lint --root "$PROJECT"
if [[ "$RC" -ne 0 ]] && grep -q 'source changed: README.md' <<<"$OUT"; then
  pass "lint marks changed source evidence stale and exits nonzero"
else
  fail "lint did not catch the changed source (rc=$RC): $OUT"
fi

# 9) A suspicious record is refused before it can poison the append-only source ledger.
run_memory record --root "$PROJECT" --kind lesson --standing observed --scope task \
  --summary 'Use token=do-not-store-this in the next route.' --source 'README.md:1' \
  --evidence 'command:make validate'
if [[ "$RC" -ne 0 ]] && grep -q 'looks credential-bearing' <<<"$OUT"; then
  pass "credential-like memory content is refused before persistence"
else
  fail "credential-like memory content was accepted (rc=$RC): $OUT"
fi

# 10) The write boundary is real: an explicit state directory outside the project .wgm area is
# rejected rather than turning the inspect command into an arbitrary file writer.
run_memory inspect --root "$PROJECT" --state-dir "$TMP/outside-state"
if [[ "$RC" -ne 0 ]] && grep -q 'must remain under' <<<"$OUT" \
   && [[ ! -e "$TMP/outside-state" ]]; then
  pass "state output is confined to the project .wgm boundary"
else
  fail "state output escaped the .wgm boundary (rc=$RC): $OUT"
fi

# 11) The fixture state is isolated from the wgm checkout: this prevents a test run from writing a
# repository-level memory or Python bytecode artifact as a side effect. Preserve an existing Stage 10
# snapshot because a real maintainer may already have inspected this checkout before running tests.
ROOT_STATE_AFTER="$TMP/root-stage10.after"
: >"$ROOT_STATE_AFTER"
if [[ -d "$ROOT/.wgm/stage10" ]]; then
  find "$ROOT/.wgm/stage10" -type f -print | sort | while IFS= read -r path; do
    cksum "$path"
  done >"$ROOT_STATE_AFTER"
fi
if cmp -s "$ROOT_STATE_SNAPSHOT" "$ROOT_STATE_AFTER" \
   && [[ ! -e "$ROOT/scripts/__pycache__" ]] \
   && [[ -f "$PROJECT/.wgm/stage10/brief.md" ]] \
   && [[ -f "$PROJECT/.wgm/stage10/system-map.md" ]]; then
  pass "fixture state stays isolated and leaves no repository bytecode"
else
  fail "memory harness leaked or changed state in the wgm repository"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "stage10 memory harness: GREEN ($PASSED assertions passed)"
  exit 0
else
  echo "stage10 memory harness: RED" >&2
  exit 1
fi
