#!/usr/bin/env bash
#
# wgm/test-jj-swarm.sh — exercise the real jj/Git hybrid swarm in disposable local repositories.
# No model, remote service, real HOME, or operator checkout is needed. Missing jj or Git without
# the orphan-worktree capability is a developer prerequisite failure, not a skipped green test.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="$ROOT/scripts/swarm.sh"
REAL_JJ="$(command -v jj || true)"
REAL_GIT="$(command -v git)"
if [[ -z "$REAL_JJ" ]]; then
  echo "FAIL: jj 0.46.0 or newer is required for the jj swarm development harness." >&2
  exit 1
fi

FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

TMP="$(mktemp -d)"
RUNPID=""
trap 'if [[ -n "$RUNPID" ]]; then kill -TERM "$RUNPID" 2>/dev/null || true; fi; cd /; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$TMP/guard-tmp"
mkdir -p "$XDG_CONFIG_HOME/jj" "$TMP/bin" "$TMP/signals" "$TMPDIR"
printf '[user]\nname = "wgm fixture"\nemail = "wgm-fixture@example.invalid"\n' > "$XDG_CONFIG_HOME/jj/config.toml"
export WGM_TEST_REAL_JJ="$REAL_JJ" WGM_TEST_REAL_GIT="$REAL_GIT" WGM_TEST_GH_MARKER="$TMP/gh-called" WGM_TEST_SIGNAL_DIR="$TMP/signals"

# A wrapper injects failures at the actual jj boundary; ordinary calls exec the installed binary.
# Post-success failures prove that the caller cannot assume a failed command made no changes.
cat > "$TMP/bin/jj" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
operation=""
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == workspace ]]; then operation="${args[$((i + 1))]}"; break; fi
done
if [[ "${WGM_TEST_REQUIRE_NO_AUTOTRACK:-0}" == 1 && ( "$operation" == add || "$operation" == remove ) ]]; then
  found=0
  for ((i = 0; i + 1 < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == --config && "${args[$((i + 1))]}" == 'snapshot.auto-track="none()"' ]]; then found=1; fi
  done
  if [[ "$found" -ne 1 ]]; then printf 'missing override\n' > "$WGM_TEST_SIGNAL_DIR/auto-track-missing"; exit 76; fi
fi
case "${WGM_TEST_JJ_FAULT:-}:$operation" in
  old-version:*) if [[ "${1:-}" == --version ]]; then echo 'jj 0.1.0'; exit 0; fi ;;
  unexpected:*) printf 'called\n' > "$WGM_TEST_SIGNAL_DIR/unexpected-jj"; exit 97 ;;
  add-error:add) "$WGM_TEST_REAL_JJ" "$@" || exit $?; exit 71 ;;
  add-term:add) "$WGM_TEST_REAL_JJ" "$@" || exit $?; kill -TERM "$PPID"; exit 0 ;;
  remove-error:remove) exit 72 ;;
  remove-after-error:remove) "$WGM_TEST_REAL_JJ" "$@" || exit $?; exit 73 ;;
  remove-term:remove) kill -TERM "$PPID"; exit 74 ;;
esac
exec "$WGM_TEST_REAL_JJ" "$@"
SH
chmod +x "$TMP/bin/jj"
# Faults at the Git boundary prove that partial creation and false-success removal stay visible.
cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
# Only the preflight help probe is faked; all ordinary Git commands delegate to real Git.
if [[ "${WGM_TEST_GIT_HELP:-}" == backport && "${1:-}" == --version ]]; then
  echo 'git version 2.39.5'
  exit 0
fi
if [[ "${1:-}" == worktree && "${2:-}" == add && "${3:-}" == -h && -n "${WGM_TEST_GIT_HELP:-}" ]]; then
  printf 'called\n' > "$WGM_TEST_SIGNAL_DIR/git-help-called"
  case "$WGM_TEST_GIT_HELP" in
    supported129|backport) echo 'usage: git worktree add [--orphan] <path>' >&2; exit 129 ;;
    supported0) echo 'usage: git worktree add [--orphan] <path>'; exit 0 ;;
    alternate129) echo '    --[no-]orphan  create an orphan worktree' >&2; exit 129 ;;
    missing129) echo 'usage: git worktree add [-f] <path>' >&2; exit 129 ;;
    missing0) echo 'usage: git worktree add [-f] <path>'; exit 0 ;;
    error128) echo 'error: unable to inspect --orphan support' >&2; exit 128 ;;
    error129) echo 'fatal: unable to inspect --orphan support' >&2; exit 129 ;;
    unavailable127) exit 127 ;;
  esac
fi
operation=""
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == worktree ]]; then operation="${args[$((i + 1))]}"; break; fi
  if [[ "${args[$i]}" == status ]]; then operation=status; break; fi
done
case "${WGM_TEST_GIT_FAULT:-}:$operation" in
  guard-status-error:status) [[ -z "${GIT_INDEX_FILE:-}" ]] || exit 77 ;;
  add-error:add) "$WGM_TEST_REAL_GIT" "$@" || exit $?; exit 75 ;;
  remove-lie:remove) exit 0 ;;
esac
exec "$WGM_TEST_REAL_GIT" "$@"
SH
chmod +x "$TMP/bin/git"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'hosting client invoked\n' > "$WGM_TEST_GH_MARKER"
exit 98
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

PROJECT="$TMP/repo with spaces"
REMOTE="$TMP/remote.git"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name 'wgm fixture'
git -C "$PROJECT" config user.email 'wgm-fixture@example.invalid'
printf '/.wgm/\n*.cache\n' > "$PROJECT/.gitignore"
printf '# plan\n\n- seed\n' > "$PROJECT/IMPLEMENTATION_PLAN.md"
printf 'protected baseline\n' > "$PROJECT/protected.txt"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm seed
BASE="$(git -C "$PROJECT" rev-parse HEAD)"
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
(cd "$PROJECT" && jj git init --colocate >/dev/null)
printf 'first independent task\nsecond independent task\n' > "$TMP/tasks.txt"
# Exercise the real preflight before fault injection so missing prerequisites fail once, visibly.
set +e
preflight_out="$(cd "$PROJECT" && "$SWARM" --backend jj -n 1 --dry-run -- true 2>&1)"; preflight_rc=$?
set -e
if [[ "$preflight_rc" -ne 0 ]]; then
  echo 'FAIL: jj workspace harness prerequisite preflight failed:' >&2
  printf '%s\n' "$preflight_out" >&2
  exit 1
fi

# Fixture agents obey the real capability and ownership contracts without calling a model.
# shellcheck disable=SC2016
AGENT_OK=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; branch="$(git branch --show-current)"; printf -- "- work on %s\n" "$branch" >> IMPLEMENTATION_PLAN.md; mkdir -p .wgm; printf "lesson from %s\n" "$branch" > .wgm/memories.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_DIRTY=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "recover this\n" > undeclared.txt; mkdir -p .wgm; printf "untrusted failed lesson\n" > .wgm/memories.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_TRACKED_WGM=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "tracked project edit\n" >> .wgm/tracked-state.txt; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_IGNORED=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "recover this ignored file\n" > result.cache; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_DRIFT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; jj new -m "detached lane" >/dev/null; printf -- "- recover after jj new\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_RENAME=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; jj workspace rename renamed-lane >/dev/null; printf -- "- renamed lane work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_MOVE_PARENT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; git -C "$WGM_TEST_PARENT" switch -q --detach; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_DIRTY_PARENT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf "concurrent parent edit\n" >> "$WGM_TEST_PARENT/protected.txt"; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_UNTRACKED_PARENT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf "unexpected parent file\n" > "$WGM_TEST_PARENT/untracked-parent.txt"; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_REF_PARENT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; git -C "$WGM_TEST_PARENT" branch unexpected-parent-ref; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_MIXED=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; branch="$(git branch --show-current)"; if [[ "$branch" == */1 ]]; then printf "recover\n" > undeclared.txt; else printf "started\n" > "$WGM_TEST_SIGNAL_DIR/late-started"; while [[ ! -e "$WGM_TEST_SIGNAL_DIR/release-late" ]]; do sleep 0.05; done; fi; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_WAIT=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; printf "%s\n" "$$" > "$WGM_TEST_SIGNAL_DIR/agent-pid"; printf "recover after interrupt\n" > pending.txt; while :; do sleep 1; done' _)
# shellcheck disable=SC2016
AGENT_ORDERED=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; branch="$(git branch --show-current)"; if [[ "$branch" == */1 ]]; then printf "started\n" > "$WGM_TEST_SIGNAL_DIR/first-started"; while [[ ! -e "$WGM_TEST_SIGNAL_DIR/release-first" ]]; do sleep 0.05; done; fi; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
# shellcheck disable=SC2016
AGENT_BARRIER=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; branch="$(git branch --show-current)"; printf "started\n" > "$WGM_TEST_SIGNAL_DIR/started-${branch##*/}"; while [[ ! -e "$WGM_TEST_SIGNAL_DIR/release-all" ]]; do sleep 0.05; done; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)

OUT="" RC=0
run_in() {
  local target="$1"; shift
  set +e
  OUT="$(cd "$target" && "$SWARM" "$@" 2>&1)"; RC=$?
  set -e
}
run() { run_in "$PROJECT" "$@"; }

workspace_at() {
  local expected
  expected="$(printf '%s\t%s' "$1" "$2")"
  (cd "$PROJECT" && jj --ignore-working-copy workspace list -T 'name ++ "\t" ++ root ++ "\n"') \
    | grep -Fxq -- "$expected"
}
parent_unchanged() {
  [[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$BASE" ]] \
    && [[ "$(git -C "$PROJECT" symbolic-ref -q HEAD)" == refs/heads/main ]] \
    && [[ -z "$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all)" ]] \
    && [[ -z "$(git --git-dir="$REMOTE" for-each-ref)" ]]
}
wait_file() {
  local file="$1" i
  for ((i = 0; i < 200; i++)); do [[ -e "$file" ]] && return 0; sleep 0.05; done
  return 1
}
wait_log() {
  local file="$1" pattern="$2" i
  for ((i = 0; i < 200; i++)); do
    [[ -f "$file" ]] && grep -q "$pattern" "$file" && return 0
    sleep 0.05
  done
  return 1
}
process_stopped() {
  local pid="$1" state i
  for ((i = 0; i < 100; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ "$state" == *Z* || -z "$state" ]] && return 0
    sleep 0.05
  done
  return 1
}

# Remove only this disposable fixture's workspaces/refs between cases, never the operator's.
reset_fixture() {
  local name branch names line path
  unset WGM_TEST_JJ_FAULT WGM_TEST_GIT_FAULT WGM_TEST_GIT_HELP WGM_TEST_PARENT WGM_TEST_REQUIRE_NO_AUTOTRACK
  git -C "$PROJECT" switch -q main
  git -C "$PROJECT" reset -q --hard "$BASE"
  git -C "$PROJECT" branch -D unexpected-parent-ref >/dev/null 2>&1 || true
  rm -f "$PROJECT/untracked-parent.txt"
  names="$(cd "$PROJECT" && jj --ignore-working-copy workspace list -T 'name ++ "\n"')"
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == default ]] && continue
    (cd "$PROJECT" && jj workspace remove "$name" >/dev/null 2>&1) || {
      fail "fixture cleanup could not remove workspace $name"; return 1;
    }
  done <<< "$names"
  # The Git-only compatibility case may leave a failed Git worktree that jj does not own.
  while IFS= read -r line; do
    [[ "$line" == 'worktree '* ]] || continue
    path="${line#worktree }"
    case "$path" in
      "$PROJECT"/.wgm/worktrees/*|"$TMP"/outside\ worktrees/*) git -C "$PROJECT" worktree remove --force "$path" ;;
    esac
  done < <(git -C "$PROJECT" worktree list --porcelain)
  while IFS= read -r branch; do
    [[ -z "$branch" ]] || git -C "$PROJECT" branch -D "$branch" >/dev/null
  done < <(git -C "$PROJECT" for-each-ref --format='%(refname:short)' refs/heads/wgm/)
  rm -rf "$PROJECT/.wgm" "$PROJECT/unsafe worktrees" "$PROJECT/unignored-tmp" "$TMP/outside worktrees" "$TMP/signals"
  mkdir -p "$TMP/signals"
  parent_unchanged || { fail "fixture parent or remote was not restored"; return 1; }
}

# Snapshot every local identity the preflight promises not to mutate on a negative result.
fixture_identity() {
  printf 'HEAD: %s\n' "$(git -C "$PROJECT" rev-parse HEAD)"
  if [[ "${1:-all}" == stable ]]; then
    git -C "$PROJECT" for-each-ref --format='%(refname) %(objectname)' refs/heads/ refs/tags/ refs/remotes/
  else
    git -C "$PROJECT" for-each-ref --format='%(refname) %(objectname)'
  fi
  git -C "$PROJECT" worktree list --porcelain
  (cd "$PROJECT" && jj --ignore-working-copy workspace list -T 'name ++ "\t" ++ root ++ "\n"')
  GIT_OPTIONAL_LOCKS=0 git -C "$PROJECT" status --porcelain=v1 --untracked-files=all
  if [[ -e "$PROJECT/.wgm/worktrees" || -L "$PROJECT/.wgm/worktrees" ]]; then echo 'lane-dir: present'; else echo 'lane-dir: absent'; fi
}
EXPECTED_STABLE_IDENTITY="$(fixture_identity stable)"
EXPECTED_IDENTITY="$(fixture_identity)"
reset_capability_fixture() {
  reset_fixture
  local actual
  # Successful jj operations legitimately add internal refs/jj/keep records. All user-facing refs,
  # worktrees, workspace names and status must reset; negative cases still compare every ref.
  actual="$(fixture_identity stable)"
  if [[ "$actual" != "$EXPECTED_STABLE_IDENTITY" ]]; then
    fail 'capability fixture did not return to the original stable identity'
    diff -u <(printf '%s\n' "$EXPECTED_STABLE_IDENTITY") <(printf '%s\n' "$actual") || true
    exit 1
  fi
  EXPECTED_IDENTITY="$(fixture_identity)"
}

# Git help normally exits 129. Some versions return 0 or print --[no-]orphan; a vendor may
# backport the capability without changing an older version string. The capability must win.
for help in supported129 supported0 alternate129 backport; do
  for mode in dry normal; do
    export WGM_TEST_GIT_HELP="$help"
    flags=(); [[ "$mode" == normal ]] || flags+=(--dry-run)
    prefix="wgm/cap-${help}-${mode}"
    run --backend jj -n 1 --prefix "$prefix" --max-iterations 1 --cleanup "${flags[@]}" -- "${AGENT_OK[@]}"
    if [[ "$RC" -eq 0 ]] && [[ -f "$TMP/signals/git-help-called" ]] && parent_unchanged \
       && { [[ "$mode" == dry && "$(fixture_identity)" == "$EXPECTED_IDENTITY" ]] \
         || { [[ "$mode" == normal ]] && git -C "$PROJECT" show-ref --verify --quiet "refs/heads/${prefix}/1" \
              && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..${prefix}/1")" -ge 1 ]]; }; }; then
      pass "jj accepts $help in $mode based on advertised capability"
    else
      fail "jj rejected $help in $mode or lacked a verified artifact (rc=$RC): $OUT"
    fi
    reset_capability_fixture
  done
done

# Missing or failed help must be a pre-mutation refusal, even if an error mentions --orphan.
for help in missing129 missing0 error128 error129 unavailable127; do
  for mode in dry normal; do
    before="$(fixture_identity)"
    export WGM_TEST_GIT_HELP="$help"
    flags=(); [[ "$mode" == normal ]] || flags+=(--dry-run)
    run --backend jj -n 1 --prefix "wgm/reject-${help}-${mode}" --max-iterations 1 --cleanup "${flags[@]}" -- "${AGENT_OK[@]}"
    if [[ "$RC" -eq 2 ]] && [[ -f "$TMP/signals/git-help-called" ]] \
       && grep -Fq 'git worktree add --orphan' <<<"$OUT" && grep -Fq 'Git 2.42' <<<"$OUT" \
       && grep -Fq -- '--backend git' <<<"$OUT" && [[ "$(fixture_identity)" == "$before" ]]; then
      pass "jj rejects $help in $mode before refs, paths, or workspaces change"
    else
      fail "jj did not safely reject $help in $mode (rc=$RC): $OUT"
    fi
    reset_capability_fixture
  done
done

# Git-only lanes must never perform the jj-specific capability probe, even on old help output.
export WGM_TEST_GIT_HELP=missing129
run --backend git -n 1 --prefix wgm/no-jj-git-probe --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ ! -e "$TMP/signals/git-help-called" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/no-jj-git-probe/1 && parent_unchanged; then
  pass "Git backend skips the jj capability probe and still commits"
else
  fail "Git backend invoked the jj-only probe or failed (rc=$RC): $OUT"
fi
reset_capability_fixture

# A dry run checks compatibility but creates no workspace, branch, or output directory.
run --backend jj --tasks "$TMP/tasks.txt" --dry-run -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -q 'backend=jj' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]] \
   && ! workspace_at wgm-swarm-1 "$PROJECT/.wgm/worktrees/wgm-swarm-1" && parent_unchanged; then
  pass "jj dry-run previews two streams without mutation"
else
  fail "jj dry-run did not remain read-only (rc=$RC): $OUT"
fi

# Two real colocated workspaces run the existing Git loop, produce separate branches, and harvest
# memories. The paths include spaces, and the empty remote plus parent must stay unchanged.
run --backend jj --tasks "$TMP/tasks.txt" --max-iterations 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] \
   && workspace_at wgm-swarm-1 "$PROJECT/.wgm/worktrees/wgm-swarm-1" \
   && workspace_at wgm-swarm-2 "$PROJECT/.wgm/worktrees/wgm-swarm-2" \
   && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..wgm/swarm/1")" -eq 1 ]] \
   && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..wgm/swarm/2")" -eq 1 ]] \
   && grep -q 'lesson from wgm/swarm/1' "$PROJECT/.wgm/memories.md" \
   && grep -q 'lesson from wgm/swarm/2' "$PROJECT/.wgm/memories.md" \
   && [[ -f "$PROJECT/.wgm/metrics/wgm-swarm-1.tsv" ]] && parent_unchanged; then
  pass "real jj workspaces produce isolated Git branches, memories, and telemetry"
else
  fail "real jj two-stream run failed (rc=$RC): $OUT"
fi

# The old Git-only convenience target must not unregister jj worktrees behind jj's back or delete
# any wgm branches in a colocated checkout.
set +e
OUT="$(cd "$PROJECT" && make -f "$ROOT/Makefile" clean-worktrees 2>&1)"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -q 'Refusing Git-only cleanup' <<<"$OUT" \
   && workspace_at wgm-swarm-1 "$PROJECT/.wgm/worktrees/wgm-swarm-1" \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/swarm/1; then
  pass "Git-only make cleanup refuses a jj checkout without deleting lanes"
else
  fail "make cleanup did not protect jj registrations (rc=$RC): $OUT"
fi
reset_fixture

# The Git-only convenience target handles spaces, keeps all branches, and refuses dirty worktrees.
GIT_ONLY="$TMP/git cleanup project with spaces"
mkdir -p "$GIT_ONLY"
git -C "$GIT_ONLY" init -q -b main
git -C "$GIT_ONLY" config user.name fixture
git -C "$GIT_ONLY" config user.email fixture@example.invalid
printf '/.wgm/\n' > "$GIT_ONLY/.gitignore"
printf 'baseline\n' > "$GIT_ONLY/file.txt"
git -C "$GIT_ONLY" add . && git -C "$GIT_ONLY" commit -qm seed
git -C "$GIT_ONLY" branch wgm/unrelated
git -C "$GIT_ONLY" worktree add -q -b wgm/cleanup/1 "$GIT_ONLY/.wgm/worktrees/lane one" HEAD
set +e
OUT="$(cd "$GIT_ONLY" && make -f "$ROOT/Makefile" clean-worktrees 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 0 ]] && [[ ! -e "$GIT_ONLY/.wgm/worktrees/lane one" ]] \
   && git -C "$GIT_ONLY" show-ref --verify --quiet refs/heads/wgm/cleanup/1 \
   && git -C "$GIT_ONLY" show-ref --verify --quiet refs/heads/wgm/unrelated; then
  pass "Git make cleanup handles spaces and preserves all branches"
else
  fail "Git make cleanup mishandled spaces or deleted a branch (rc=$RC): $OUT"
fi
git -C "$GIT_ONLY" worktree add -q -b wgm/cleanup/2 "$GIT_ONLY/.wgm/worktrees/dirty lane" HEAD
printf 'keep this edit\n' >> "$GIT_ONLY/.wgm/worktrees/dirty lane/file.txt"
set +e
OUT="$(cd "$GIT_ONLY" && make -f "$ROOT/Makefile" clean-worktrees 2>&1)"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -q 'keep this edit' "$GIT_ONLY/.wgm/worktrees/dirty lane/file.txt" \
   && git -C "$GIT_ONLY" show-ref --verify --quiet refs/heads/wgm/cleanup/2; then
  pass "Git make cleanup refuses a dirty worktree without deleting its branch"
else
  fail "Git make cleanup discarded a dirty worktree (rc=$RC): $OUT"
fi

# Successful cleanup removes both jj registrations/worktrees but retains reviewable Git refs.
# Require the per-command no-auto-track override on both workspace creation and removal.
export WGM_TEST_REQUIRE_NO_AUTOTRACK=1
run --backend jj --tasks "$TMP/tasks.txt" --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-swarm-1" ]] \
   && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-swarm-2" ]] \
   && ! workspace_at wgm-swarm-1 "$PROJECT/.wgm/worktrees/wgm-swarm-1" \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/swarm/1 \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/swarm/2 \
   && git -C "$PROJECT" show wgm/swarm/1:IMPLEMENTATION_PLAN.md | grep -q 'work on wgm/swarm/1' \
   && git -C "$PROJECT" show wgm/swarm/2:IMPLEMENTATION_PLAN.md | grep -q 'work on wgm/swarm/2' \
   && grep -q 'lesson from wgm/swarm/2' "$PROJECT/.wgm/memories.md" \
   && [[ ! -e "$TMP/signals/auto-track-missing" ]] && parent_unchanged; then
  pass "successful jj cleanup keeps both branches and consolidated memory"
else
  fail "successful jj cleanup lost state or left a workspace (rc=$RC): $OUT"
fi
reset_fixture

# A user-selected gate file outside the clean parent is forwarded to and executed in a jj lane.
printf 'gates:\n  - test -f protected.txt\n' > "$TMP/project-gates.yml"
run --backend jj -n 1 --prefix wgm/gates --gates "$TMP/project-gates.yml" --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -q 'Project gate 1/1' "$PROJECT/.wgm/swarm-logs/wgm-gates-1.log" && parent_unchanged; then
  pass "explicit project gate is forwarded to and executed in a jj lane"
else
  fail "jj lane did not execute the selected project gate (rc=$RC): $OUT"
fi
reset_fixture

# A custom in-project workspace directory works when its own path is ignored, including spaces.
run --backend jj -n 1 --prefix wgm/custom --worktree-dir '.wgm/custom lanes' --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ ! -e "$PROJECT/.wgm/custom lanes/wgm-custom-1" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/custom/1 && parent_unchanged; then
  pass "custom ignored in-project workspace directory works with spaces"
else
  fail "custom ignored in-project workspace directory failed (rc=$RC): $OUT"
fi
reset_fixture

# An external workspace directory need not be ignored by the parent; spaces are supported there too.
run --backend jj -n 1 --worktree-dir "$TMP/outside worktrees" --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ ! -e "$TMP/outside worktrees/wgm-swarm-1" ]] && parent_unchanged; then
  pass "external workspace directory works with spaces"
else
  fail "external workspace directory failed (rc=$RC): $OUT"
fi
reset_fixture

# The guard must inspect a private index: Git's `diff` can otherwise refresh parent index bytes.
# jj itself may refresh stat metadata during workspace removal, so that path checks the staged tree
# rather than falsely promising byte-for-byte index identity.
touch -t 200001010000 "$PROJECT/protected.txt"
index_before="$(git -C "$PROJECT" hash-object "$PROJECT/.git/index")"
run --backend git -n 1 --prefix wgm/index-git --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
index_after="$(git -C "$PROJECT" hash-object "$PROJECT/.git/index")"
if [[ "$RC" -eq 0 && "$index_before" == "$index_after" ]]; then
  pass "Git parent inspection preserves the real index bytes"
else
  fail "Git parent inspection refreshed or changed the real index (rc=$RC): $OUT"
fi
reset_fixture
touch -t 200001010000 "$PROJECT/protected.txt"
staged_before="$(git -C "$PROJECT" ls-files --stage | git -C "$PROJECT" hash-object --stdin)"
run --backend jj -n 1 --prefix wgm/index-jj --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
staged_after="$(git -C "$PROJECT" ls-files --stage | git -C "$PROJECT" hash-object --stdin)"
if [[ "$RC" -eq 0 && "$staged_before" == "$staged_after" ]]; then
  pass "jj workspace lifecycle preserves the parent's staged tree"
else
  fail "jj workspace lifecycle changed the staged tree (rc=$RC): $OUT"
fi
reset_fixture

# Git-only execution never consults jj, even if a jj executable would fail on invocation.
export WGM_TEST_JJ_FAULT=unexpected
run --backend git -n 1 --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ ! -e "$TMP/signals/unexpected-jj" ]] && parent_unchanged; then
  pass "default Git workflow does not invoke jj"
else
  fail "Git workflow unexpectedly depended on jj (rc=$RC): $OUT"
fi
reset_fixture

# A failed parent inspection cannot become a green run or leave a temporary private index behind.
export WGM_TEST_GIT_FAULT=guard-status-error
run --backend git -n 1 --prefix wgm/inspect-fail -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && grep -q 'Could not inspect the parent' <<<"$OUT" \
   && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-inspect-fail-1" ]] \
   && ! compgen -G "$PROJECT/.git/wgm-parent-index.*" >/dev/null; then
  pass "failed parent inspection refuses setup and cleans the private index"
else
  fail "failed parent inspection was accepted or leaked its private index (rc=$RC): $OUT"
fi
reset_fixture

# A user may set TMPDIR inside the source checkout. Parallel guard tempfiles must not appear as
# unexpected untracked parent edits or leak into that directory.
mkdir -p "$PROJECT/unignored-tmp"
export TMPDIR="$PROJECT/unignored-tmp"
run --backend git -n 2 --prefix wgm/internal-tmp --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && [[ -z "$(ls -A "$PROJECT/unignored-tmp")" ]] \
   && ! compgen -G "$PROJECT/.git/wgm-parent-index.*" >/dev/null; then
  pass "in-project TMPDIR does not cause parallel parent-guard drift or leaked indexes"
else
  fail "in-project TMPDIR disrupted the parent guard (rc=$RC): $OUT"
fi
export TMPDIR="$TMP/guard-tmp"
reset_fixture

# A failed Git add can already have registered a worktree/branch; never delete or hide those handles.
export WGM_TEST_GIT_FAULT=add-error
run --backend git -n 1 --prefix wgm/git-partial --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ -d "$PROJECT/.wgm/worktrees/wgm-git-partial-1" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/git-partial/1 \
   && grep -q 'wgm/git-partial/1' <<<"$OUT" && grep -q 'wgm-git-partial-1' <<<"$OUT"; then
  pass "partial Git setup failure reports its retained path and branch"
else
  fail "partial Git setup lost recoverable ownership (rc=$RC): $OUT"
fi
reset_fixture

# A removal command that falsely reports success must not become a green cleanup result.
export WGM_TEST_GIT_FAULT=remove-lie
run --backend git -n 1 --prefix wgm/git-remove --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ -d "$PROJECT/.wgm/worktrees/wgm-git-remove-1" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/git-remove/1 \
   && grep -q 'cleanup verification failed' <<<"$OUT"; then
  pass "Git cleanup verifies removal rather than trusting exit zero"
else
  fail "false-success Git cleanup was accepted (rc=$RC): $OUT"
fi
reset_fixture

# Ambient Git repository/index overrides can redirect lane commands into the parent or hide staged
# data. Both backends must reject them before any workspace or branch is created.
for backend in git jj; do
  for override in GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE; do
    prefix="wgm/override-${backend}-${override}"
    lane="${prefix//\//-}-1"
    export "$override=$TMP/unsafe-git-override"
    run --backend "$backend" -n 1 --prefix "$prefix" --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
    unset "$override"
    if [[ "$RC" -eq 2 ]] && grep -q "$override" <<<"$OUT" \
       && [[ ! -e "$PROJECT/.wgm/worktrees/$lane" ]] \
       && ! git -C "$PROJECT" show-ref --verify --quiet "refs/heads/${prefix}/1" && parent_unchanged; then
      pass "$backend rejects ambient $override before mutation"
    else
      fail "$backend did not safely reject $override (rc=$RC): $OUT"
    fi
    reset_fixture
  done
done

# Missing or unsupported jj must fail before creating any workspace; no silent Git fallback.
mkdir -p "$TMP/no-jj-bin"
ln -s "$(command -v bash)" "$TMP/no-jj-bin/bash"
ln -s "$(command -v dirname)" "$TMP/no-jj-bin/dirname"
ln -s "$(command -v git)" "$TMP/no-jj-bin/git"
set +e
OUT="$(cd "$PROJECT" && PATH="$TMP/no-jj-bin" "$SWARM" --backend jj -n 1 -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -qi 'jj' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]] && parent_unchanged; then
  pass "missing jj is rejected before mutation"
else
  fail "missing jj was not rejected cleanly (rc=$RC): $OUT"
fi
export WGM_TEST_JJ_FAULT=old-version
run --backend jj -n 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && grep -q '0.46.0' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]] && parent_unchanged; then
  pass "unsupported jj version is rejected before mutation"
else
  fail "old jj version was not rejected cleanly (rc=$RC): $OUT"
fi
reset_fixture

# Neither an ordinary Git repository nor a jj repo backed by some other Git store is acceptable.
PLAIN="$TMP/plain"
OTHER="$TMP/other"
mkdir -p "$PLAIN" "$OTHER"
for repo in "$PLAIN" "$OTHER"; do
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.invalid
  printf '# plan\n' > "$repo/IMPLEMENTATION_PLAN.md"
  git -C "$repo" add . && git -C "$repo" commit -qm seed
done
run_in "$PLAIN" --backend jj -n 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ ! -e "$PLAIN/.jj" && ! -e "$PLAIN/.wgm/worktrees" ]]; then
  pass "plain Git repository is not silently converted"
else
  fail "plain Git repository was not refused (rc=$RC): $OUT"
fi
jj git init --git-repo "$OTHER" "$PLAIN" >/dev/null
run_in "$PLAIN" --backend jj -n 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ ! -e "$PLAIN/.wgm/worktrees" ]]; then
  pass "jj backed by a different Git store is rejected"
else
  fail "mismatched jj/Git store was not rejected (rc=$RC): $OUT"
fi

# Dirty parents and unignored in-tree workspace paths cannot be snapshotted into jj implicitly.
printf 'do not snapshot\n' >> "$PROJECT/protected.txt"
run --backend jj -n 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && grep -qi 'clean' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]] \
   && grep -q 'do not snapshot' "$PROJECT/protected.txt"; then
  pass "dirty parent is rejected and its edit survives"
else
  fail "dirty parent was not rejected safely (rc=$RC): $OUT"
fi
reset_fixture
printf 'untracked parent work\n' > "$PROJECT/untracked-parent.txt"
run --backend jj -n 1 -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && grep -qi 'clean' <<<"$OUT" && [[ -f "$PROJECT/untracked-parent.txt" ]] \
   && [[ ! -e "$PROJECT/.wgm/worktrees" ]]; then
  pass "untracked parent file is not snapshotted or removed"
else
  fail "untracked parent file was not preserved (rc=$RC): $OUT"
fi
reset_fixture
run --backend jj -n 1 --worktree-dir 'unsafe worktrees' -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && grep -qi 'ignor' <<<"$OUT" && [[ ! -e "$PROJECT/unsafe worktrees/wgm-swarm-1" ]] && parent_unchanged; then
  pass "unignored workspace directory inside the parent is rejected"
else
  fail "unignored in-tree workspace directory was not rejected (rc=$RC): $OUT"
fi
reset_fixture

# A dangling symlink is a collision even though test -e returns false; its target must not be made.
mkdir -p "$PROJECT/.wgm/worktrees"
ln -s "$TMP/nonexistent-target" "$PROJECT/.wgm/worktrees/wgm-link-1"
run --backend jj -n 1 --prefix wgm/link -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ -L "$PROJECT/.wgm/worktrees/wgm-link-1" ]] \
   && [[ ! -e "$TMP/nonexistent-target" ]] && ! git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/link/1; then
  pass "dangling workspace-path symlink is retained as a collision"
else
  fail "dangling workspace symlink was followed or clobbered (rc=$RC): $OUT"
fi
reset_fixture

# A preexisting jj name must not be overwritten; a later lane may finish but the swarm stays red.
(cd "$PROJECT" && jj workspace add --name wgm-collision-1 --colocate -r "$BASE" "$TMP/owned workspace" >/dev/null)
run --backend jj -n 2 --prefix wgm/collision --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-collision-1 "$TMP/owned workspace" \
   && [[ -d "$TMP/owned workspace" ]] && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-collision-2" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/collision/2 && parent_unchanged; then
  pass "mixed workspace collision preserves the existing workspace and reports failure"
else
  fail "workspace name collision was clobbered or reported green (rc=$RC): $OUT"
fi
reset_fixture

# Existing Git branches are just as important as jj workspace names and must not be clobbered.
git -C "$PROJECT" branch wgm/branch-collision/1
run --backend jj -n 2 --prefix wgm/branch-collision --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ "$(git -C "$PROJECT" rev-parse wgm/branch-collision/1)" == "$BASE" ]] \
   && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-branch-collision-1" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/branch-collision/2 && parent_unchanged; then
  pass "existing Git branch is not clobbered by jj setup"
else
  fail "jj setup clobbered a Git branch or reported mixed setup green (rc=$RC): $OUT"
fi
reset_fixture

# A tool can create a workspace and then fail; its name/path remain discoverable for recovery.
export WGM_TEST_JJ_FAULT=add-error
run --backend jj -n 1 --prefix wgm/partial --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-partial-1 "$PROJECT/.wgm/worktrees/wgm-partial-1" \
   && [[ -d "$PROJECT/.wgm/worktrees/wgm-partial-1" ]] && grep -q 'wgm-partial-1' <<<"$OUT" && parent_unchanged; then
  pass "post-creation setup failure retains named workspace ownership"
else
  fail "post-creation failure lost its workspace or recovery name (rc=$RC): $OUT"
fi
reset_fixture

# Undeclared and ignored edits, jj-driven detached HEAD, and renamed workspace identities all
# remain recoverable; no unverifiable lane may be removed by --cleanup.
run --backend jj -n 1 --prefix wgm/dirty --max-iterations 1 --cleanup -- "${AGENT_DIRTY[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f "$PROJECT/.wgm/worktrees/wgm-dirty-1/undeclared.txt" ]] \
   && [[ -f "$PROJECT/.wgm/worktrees/wgm-dirty-1/.wgm/memories.md" ]] \
   && [[ ! -f "$PROJECT/.wgm/memories.md" ]] \
   && workspace_at wgm-dirty-1 "$PROJECT/.wgm/worktrees/wgm-dirty-1" && parent_unchanged; then
  pass "failed dirty jj lane and its untrusted memory are retained without harvest"
else
  fail "failed dirty jj lane was not retained (rc=$RC): $OUT"
fi
reset_fixture
run --backend jj -n 1 --prefix wgm/ignored --max-iterations 1 --cleanup -- "${AGENT_IGNORED[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f "$PROJECT/.wgm/worktrees/wgm-ignored-1/result.cache" ]] \
   && workspace_at wgm-ignored-1 "$PROJECT/.wgm/worktrees/wgm-ignored-1" && parent_unchanged; then
  pass "ignored non-wgm artifact prevents jj cleanup"
else
  fail "ignored jj artifact was removed (rc=$RC): $OUT"
fi
reset_fixture

# Tracked files remain project data under an otherwise ignored .wgm directory.
SAVED_BASE="$BASE"
mkdir -p "$PROJECT/.wgm"
printf 'tracked baseline\n' > "$PROJECT/.wgm/tracked-state.txt"
git -C "$PROJECT" add -f .wgm/tracked-state.txt
git -C "$PROJECT" commit -qm 'seed tracked wgm state'
BASE="$(git -C "$PROJECT" rev-parse HEAD)"
run --backend jj -n 1 --prefix wgm/tracked --max-iterations 1 --cleanup -- "${AGENT_TRACKED_WGM[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f "$PROJECT/.wgm/worktrees/wgm-tracked-1/.wgm/tracked-state.txt" ]] \
   && grep -q 'tracked project edit' "$PROJECT/.wgm/worktrees/wgm-tracked-1/.wgm/tracked-state.txt"; then
  pass "tracked .wgm project edit prevents jj cleanup"
else
  fail "tracked .wgm project edit was discarded by jj cleanup (rc=$RC): $OUT"
fi
BASE="$SAVED_BASE"
reset_fixture
run --backend jj -n 1 --prefix wgm/drift --max-iterations 1 --cleanup -- "${AGENT_DRIFT[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f "$PROJECT/.wgm/worktrees/wgm-drift-1/IMPLEMENTATION_PLAN.md" ]] \
   && grep -q 'lane guard' "$PROJECT/.wgm/swarm-logs/wgm-drift-1.log" \
   && [[ "$(git -C "$PROJECT" rev-parse wgm/drift/1)" == "$BASE" ]] \
   && workspace_at wgm-drift-1 "$PROJECT/.wgm/worktrees/wgm-drift-1" && parent_unchanged; then
  pass "jj new detachment is rejected before a host commit and retained"
else
  fail "jj-driven branch drift was not safely retained (rc=$RC): $OUT"
fi
reset_fixture
run --backend jj -n 1 --prefix wgm/rename --max-iterations 1 --cleanup -- "${AGENT_RENAME[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at renamed-lane "$PROJECT/.wgm/worktrees/wgm-rename-1" \
   && [[ -d "$PROJECT/.wgm/worktrees/wgm-rename-1" ]] && parent_unchanged; then
  pass "renamed jj workspace fails identity verification and remains recoverable"
else
  fail "renamed jj workspace was trusted or removed (rc=$RC): $OUT"
fi
reset_fixture

# A parent ref change after setup prevents jj cleanup from snapshotting or updating that parent.
export WGM_TEST_PARENT="$PROJECT"
run --backend jj -n 1 --prefix wgm/parent --max-iterations 1 --cleanup -- "${AGENT_MOVE_PARENT[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-parent-1 "$PROJECT/.wgm/worktrees/wgm-parent-1" \
   && [[ -z "$(git -C "$PROJECT" branch --show-current)" ]] && [[ -d "$PROJECT/.wgm/worktrees/wgm-parent-1" ]]; then
  pass "parent identity movement blocks cleanup and retains the lane"
else
  fail "parent identity movement did not block cleanup (rc=$RC): $OUT"
fi
reset_fixture
export WGM_TEST_PARENT="$PROJECT"
run --backend git -n 1 --prefix wgm/git-parent --max-iterations 1 --cleanup -- "${AGENT_MOVE_PARENT[@]}"
if [[ "$RC" -ne 0 ]] && [[ -d "$PROJECT/.wgm/worktrees/wgm-git-parent-1" ]] \
   && [[ -z "$(git -C "$PROJECT" branch --show-current)" ]] && grep -q 'parent Git HEAD or branch changed' <<<"$OUT"; then
  pass "parent branch movement also retains Git-backend lanes"
else
  fail "Git-backend parent movement did not block cleanup (rc=$RC): $OUT"
fi
reset_fixture

# Git permits a dirty baseline, but editing that same already-dirty tracked file during a lane must
# still change the fingerprint and stop the host before committing or cleaning the lane.
printf 'preexisting parent edit\n' >> "$PROJECT/protected.txt"
export WGM_TEST_PARENT="$PROJECT"
run --backend git -n 1 --prefix wgm/git-parent-dirty --max-iterations 1 --cleanup -- "${AGENT_DIRTY_PARENT[@]}"
if [[ "$RC" -ne 0 ]] && [[ -d "$PROJECT/.wgm/worktrees/wgm-git-parent-dirty-1" ]] \
   && grep -q 'preexisting parent edit' "$PROJECT/protected.txt" \
   && grep -q 'concurrent parent edit' "$PROJECT/protected.txt" \
   && [[ "$(git -C "$PROJECT" rev-parse wgm/git-parent-dirty/1)" == "$BASE" ]] \
   && grep -q 'parent guard' "$PROJECT/.wgm/swarm-logs/wgm-git-parent-dirty-1.log"; then
  pass "parent guard detects changes to an already-dirty tracked file before host commit"
else
  fail "parent guard missed an already-dirty parent file (rc=$RC): $OUT"
fi
reset_fixture
export WGM_TEST_PARENT="$PROJECT"
run --backend git -n 1 --prefix wgm/git-parent-untracked --max-iterations 1 --cleanup -- "${AGENT_UNTRACKED_PARENT[@]}"
if [[ "$RC" -ne 0 ]] && [[ -f "$PROJECT/untracked-parent.txt" ]] \
   && [[ -d "$PROJECT/.wgm/worktrees/wgm-git-parent-untracked-1" ]] \
   && [[ "$(git -C "$PROJECT" rev-parse wgm/git-parent-untracked/1)" == "$BASE" ]]; then
  pass "new untracked parent file stops the Git lane before host commit"
else
  fail "new untracked parent file was not detected (rc=$RC): $OUT"
fi
reset_fixture
export WGM_TEST_PARENT="$PROJECT"
run --backend git -n 1 --prefix wgm/git-parent-ref --max-iterations 1 --cleanup -- "${AGENT_REF_PARENT[@]}"
if [[ "$RC" -ne 0 ]] && git -C "$PROJECT" show-ref --verify --quiet refs/heads/unexpected-parent-ref \
   && [[ -d "$PROJECT/.wgm/worktrees/wgm-git-parent-ref-1" ]] \
   && [[ "$(git -C "$PROJECT" rev-parse wgm/git-parent-ref/1)" == "$BASE" ]]; then
  pass "non-lane Git ref drift stops the Git lane before host commit"
else
  fail "non-lane ref drift was not detected (rc=$RC): $OUT"
fi
reset_fixture
export WGM_TEST_PARENT="$PROJECT"
run --backend jj -n 1 --prefix wgm/parent-dirty --max-iterations 1 --cleanup -- "${AGENT_DIRTY_PARENT[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-parent-dirty-1 "$PROJECT/.wgm/worktrees/wgm-parent-dirty-1" \
   && grep -q 'concurrent parent edit' "$PROJECT/protected.txt"; then
  pass "concurrent parent edit blocks cleanup without being discarded"
else
  fail "concurrent parent edit was snapshotted or lost (rc=$RC): $OUT"
fi
reset_fixture

# A removal failure before deletion retains the workspace; a failure after successful deletion
# still reports failure while the Git branch stays reachable.
export WGM_TEST_JJ_FAULT=remove-error
run --backend jj -n 1 --prefix wgm/remove-before --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-remove-before-1 "$PROJECT/.wgm/worktrees/wgm-remove-before-1" \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/remove-before/1; then
  pass "jj cleanup failure retains its workspace and branch"
else
  fail "jj cleanup failure lost ownership or became green (rc=$RC): $OUT"
fi
reset_fixture
export WGM_TEST_JJ_FAULT=remove-after-error
run --backend jj -n 1 --prefix wgm/remove-after --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-remove-after-1" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/remove-after/1; then
  pass "post-removal error remains red while the branch survives"
else
  fail "post-removal error lost its branch or became green (rc=$RC): $OUT"
fi
reset_fixture

# Cleanup must wait for a late sibling even when an earlier lane failed. Once released, only the
# successful sibling is removed; the failed lane and its diagnostic file are retained.
(cd "$PROJECT" && "$SWARM" --backend jj -n 2 --prefix wgm/mixed --max-iterations 1 --cleanup -- "${AGENT_MIXED[@]}") > "$TMP/mixed.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/late-started" && wait_log "$PROJECT/.wgm/swarm-logs/wgm-mixed-1.log" 'Undeclared paths' \
   && [[ -d "$PROJECT/.wgm/worktrees/wgm-mixed-2" ]] && kill -0 "$RUNPID" 2>/dev/null; then
  pass "early failure does not clean up a still-running sibling"
else
  fail "late sibling was not preserved while running"
fi
: > "$TMP/signals/release-late"
set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
if [[ "$RC" -ne 0 ]] && [[ -f "$PROJECT/.wgm/worktrees/wgm-mixed-1/undeclared.txt" ]] \
   && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-mixed-2" ]] \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/mixed/2 && parent_unchanged; then
  pass "mixed outcomes retain the failed lane and clean only the late success"
else
  fail "mixed outcomes lost work or became green (rc=$RC)"
fi
reset_fixture

# There is no built-in concurrency cap: all three ready lanes must start before any is released.
(cd "$PROJECT" && exec "$SWARM" --backend jj -n 3 --prefix wgm/batch --max-iterations 1 --cleanup -- "${AGENT_BARRIER[@]}") > "$TMP/batch.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/started-1" && wait_file "$TMP/signals/started-2" \
   && wait_file "$TMP/signals/started-3" && kill -0 "$RUNPID" 2>/dev/null; then
  pass "all ready lanes launch concurrently without an internal queue"
else
  fail "ready lanes did not all start before release"
fi
: > "$TMP/signals/release-all"
set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
if [[ "$RC" -eq 0 ]]; then pass "concurrent batch finishes after release"; else fail "concurrent batch failed (rc=$RC)"; fi
reset_fixture

# If lane 2 finishes while the parent is still waiting for lane 1, its completion timestamp must
# already exist; using the eventual wait time would inflate lane lifetime and peak concurrency.
(cd "$PROJECT" && exec "$SWARM" --backend jj -n 2 --prefix wgm/order --max-iterations 1 --cleanup -- "${AGENT_ORDERED[@]}") > "$TMP/order.log" 2>&1 &
RUNPID=$!
end_seen=0
if wait_file "$TMP/signals/first-started"; then
  for ((i = 0; i < 200; i++)); do
    if compgen -G "$PROJECT/.wgm/metrics/.wgm-order-2-end-*" >/dev/null; then end_seen=1; break; fi
    sleep 0.05
  done
fi
if [[ "$end_seen" -eq 1 ]] && kill -0 "$RUNPID" 2>/dev/null; then
  pass "lane completion is recorded before an earlier slow sibling is waited"
else
  fail "lane completion was delayed until wait order"
fi
: > "$TMP/signals/release-first"
set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
if [[ "$RC" -eq 0 ]] && ! compgen -G "$PROJECT/.wgm/metrics/.wgm-order-*-end-*" >/dev/null; then
  pass "completion timestamps are consumed and temporary markers removed"
else
  fail "ordered-lane run failed or leaked timing markers (rc=$RC)"
fi
reset_fixture

# Graceful termination at setup, during active work, and during cleanup must not erase the named
# workspace. Active lane process groups are stopped before reporting recoverable ownership.
export WGM_TEST_JJ_FAULT=add-term
run --backend jj -n 1 --prefix wgm/setup-term --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-setup-term-1 "$PROJECT/.wgm/worktrees/wgm-setup-term-1" \
   && [[ -d "$PROJECT/.wgm/worktrees/wgm-setup-term-1" ]] && grep -q 'wgm-setup-term-1' <<<"$OUT"; then
  pass "termination during setup leaves named workspace recoverable"
else
  fail "setup termination lost workspace ownership (rc=$RC): $OUT"
fi
reset_fixture
(cd "$PROJECT" && exec "$SWARM" --backend jj -n 1 --prefix wgm/active-term --max-iterations 1 --cleanup -- "${AGENT_WAIT[@]}") > "$TMP/active-term.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/agent-pid"; then
  agent_pid="$(<"$TMP/signals/agent-pid")"
  kill -TERM "$RUNPID"
  set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
  if [[ "$RC" -ne 0 ]] && process_stopped "$agent_pid" \
     && [[ -f "$PROJECT/.wgm/worktrees/wgm-active-term-1/pending.txt" ]] \
     && workspace_at wgm-active-term-1 "$PROJECT/.wgm/worktrees/wgm-active-term-1"; then
    pass "termination stops the active lane group and retains pending work"
  else
    fail "active termination left a running agent or lost pending work (rc=$RC)"
  fi
else
  fail "active termination fixture never started"
  kill -TERM "$RUNPID" 2>/dev/null || true
  set +e; wait "$RUNPID"; set -e; RUNPID=""
fi
reset_fixture
(cd "$PROJECT" && exec "$SWARM" --backend git -n 1 --prefix wgm/git-term --max-iterations 1 --cleanup -- "${AGENT_WAIT[@]}") > "$TMP/git-term.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/agent-pid"; then
  agent_pid="$(<"$TMP/signals/agent-pid")"
  kill -TERM "$RUNPID"
  set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
  if [[ "$RC" -ne 0 ]] && process_stopped "$agent_pid" \
     && [[ -f "$PROJECT/.wgm/worktrees/wgm-git-term-1/pending.txt" ]]; then
    pass "termination also stops the Git lane group and retains pending work"
  else
    fail "Git-backend termination left a running agent or lost pending work (rc=$RC)"
  fi
else
  fail "Git-backend termination fixture never started"
  kill -TERM "$RUNPID" 2>/dev/null || true
  set +e; wait "$RUNPID"; set -e; RUNPID=""
fi
reset_fixture
export WGM_TEST_JJ_FAULT=remove-term
run --backend jj -n 1 --prefix wgm/cleanup-term --max-iterations 1 --cleanup -- "${AGENT_OK[@]}"
if [[ "$RC" -ne 0 ]] && workspace_at wgm-cleanup-term-1 "$PROJECT/.wgm/worktrees/wgm-cleanup-term-1" \
   && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/cleanup-term/1; then
  pass "termination during cleanup retains workspace and branch"
else
  fail "cleanup termination lost workspace or branch (rc=$RC): $OUT"
fi
reset_fixture

# The normal no-consent harvest must not invoke a hosting client or mutate the empty remote.
if [[ ! -e "$WGM_TEST_GH_MARKER" ]] && [[ -z "$(git --git-dir="$REMOTE" for-each-ref)" ]] && parent_unchanged; then
  pass "no-consent fixture never invokes the hosting client or changes the remote"
else
  fail "fixture crossed the harvest/remote boundary"
fi

# CI uses a pinned verifier; corrupted input must fail before extraction, and the workflow must
# actually call the verifier rather than merely documenting a checksum.
printf 'not a jj archive\n' > "$TMP/corrupt-jj.tar.gz"
set +e
OUT="$(bash "$ROOT/.github/scripts/verify-jj-archive.sh" "$TMP/corrupt-jj.tar.gz" 2>&1)"; RC=$?
set -e
# shellcheck disable=SC2016  # match the workflow's literal variable reference
if [[ "$RC" -ne 0 ]] && grep -q 'checksum mismatch' <<<"$OUT" \
   && grep -Fq 'bash .github/scripts/verify-jj-archive.sh "$RUNNER_TEMP/jj.tar.gz"' "$ROOT/.github/workflows/ci.yml"; then
  pass "CI archive verifier rejects corruption and is invoked by the workflow"
else
  fail "jj CI archive verification is missing or accepts corruption (rc=$RC): $OUT"
fi

# A separate native-jj spike demonstrates the capability being evaluated, not the shipped swarm:
# two non-colocated workspace changes conflict in an explicit merge; a human resolves the file and
# jj undo restores a subsequently created change. No automatic conflict resolution is claimed.
NATIVE="$TMP/native-jj"
mkdir -p "$NATIVE"
git -C "$NATIVE" init -q -b main
git -C "$NATIVE" config user.name fixture
git -C "$NATIVE" config user.email fixture@example.invalid
printf 'original\n' > "$NATIVE/conflict.txt"
git -C "$NATIVE" add . && git -C "$NATIVE" commit -qm seed
(cd "$NATIVE" && jj git init --colocate >/dev/null 2>&1 \
  && jj workspace add --name native-a --no-colocate -r main "$TMP/native-a" >/dev/null 2>&1 \
  && jj workspace add --name native-b --no-colocate -r main "$TMP/native-b" >/dev/null 2>&1)
printf 'alpha\n' > "$TMP/native-a/conflict.txt"
jj -R "$TMP/native-a" describe -m 'lane alpha' >/dev/null 2>&1
native_a="$(jj --ignore-working-copy -R "$TMP/native-a" log --no-graph -r @ -T 'commit_id')"
printf 'beta\n' > "$TMP/native-b/conflict.txt"
jj -R "$TMP/native-b" describe -m 'lane beta' >/dev/null 2>&1
native_b="$(jj --ignore-working-copy -R "$TMP/native-b" log --no-graph -r @ -T 'commit_id')"
jj -R "$NATIVE" new "$native_a" "$native_b" -m 'integrate fixture' >/dev/null 2>&1
conflicted="$(jj --ignore-working-copy -R "$NATIVE" log --no-graph -r @ -T 'conflict')"
printf 'resolved by operator\n' > "$NATIVE/conflict.txt"
resolved="$(jj -R "$NATIVE" log --no-graph -r @ -T 'conflict')"
before_undo="$(jj --ignore-working-copy -R "$NATIVE" log --no-graph -r @ -T 'change_id')"
jj -R "$NATIVE" new -m 'temporary change' >/dev/null 2>&1
jj -R "$NATIVE" undo >/dev/null 2>&1
after_undo="$(jj --ignore-working-copy -R "$NATIVE" log --no-graph -r @ -T 'change_id')"
if [[ "$conflicted" == true && "$resolved" == false && "$before_undo" == "$after_undo" ]]; then
  pass "native jj spike retains a conflict for manual resolution and can undo an operation"
else
  fail "native jj conflict/undo spike did not produce the expected evidence"
fi
# The same per-command override used by the swarm must suppress jj's normal untracked auto-snapshot.
printf 'untracked probe\n' > "$NATIVE/auto-track-probe.txt"
(cd "$NATIVE" && jj --config 'snapshot.auto-track="none()"' workspace add --name no-auto --no-colocate -r @- "$TMP/native-no-auto" >/dev/null 2>&1)
if ! (cd "$NATIVE" && jj --ignore-working-copy file list -r @ | grep -Fxq 'auto-track-probe.txt'); then
  pass "jj lifecycle override does not auto-track a new untracked file"
else
  fail "jj lifecycle override still snapshotted a new untracked file"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo 'jj swarm harness: GREEN'
  exit 0
else
  echo 'jj swarm harness: RED' >&2
  exit 1
fi
