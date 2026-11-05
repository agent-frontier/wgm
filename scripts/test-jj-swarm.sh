#!/usr/bin/env bash
#
# wgm/test-jj-swarm.sh — exercise the real jj/Git hybrid swarm in disposable local repositories.
# No model, remote service, real HOME, or operator checkout is needed. Missing jj or Git without
# the orphan-worktree capability is a developer prerequisite failure, not a skipped green test.

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
# (the F12 self-test below runs this harness again as a child: it must use the REAL binaries its parent resolved, not
# the parent's PATH wrappers it inherited — otherwise the child's wrapper would exec the parent's wrapper forever)
REAL_JJ="${WGM_TEST_REAL_JJ:-$(command -v jj || true)}"
REAL_GIT="${WGM_TEST_REAL_GIT:-$(command -v git)}"
FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
# F12: an intermittent acceptance-only failure is undiagnosable without the real jj view. Every failure prints
# jj's actual `workspace list` (stdout AND stderr) and the parent checkout's `git status --porcelain`, taken
# with the real binaries (never the fault-injecting wrappers) and never allowed to fail the harness itself.
fail_diagnostics() {
  [[ -n "${PROJECT:-}" && -d "${PROJECT:-}" ]] || { printf '  (diagnostics: no fixture project yet)\n' >&2; return 0; }
  {
    printf '  --- jj workspace list (stdout+stderr) in %s ---\n' "$PROJECT"
    (cd "$PROJECT" && "$REAL_JJ" --ignore-working-copy workspace list 2>&1) | sed 's/^/  /' || true
    printf '  --- parent git status --porcelain ---\n'
    "$REAL_GIT" -C "$PROJECT" status --porcelain 2>&1 | sed 's/^/  /' || true
  } >&2 || true
}
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; fail_diagnostics; }
# (F12: EVERY failure — including a prerequisite one — goes through `fail`, so it prints the real workspace list,
# stderr and the parent's status; before any fixture project exists the diagnostics say so.)
if [[ -z "$REAL_JJ" ]]; then
  fail "jj 0.46.0 or newer is required for the jj swarm development harness."
  exit 1
fi

TMP="$(mktemp -d)"
RUNPID=""
trap 'if [[ -n "$RUNPID" ]]; then kill -TERM "$RUNPID" 2>/dev/null || true; fi; cd /; rm -rf "$TMP" "$ISO_HOME"' EXIT
# (HOME/XDG_CONFIG_HOME are already throwaway — see the top of this file; the fixture home lives under TMP from here on.
# Rootless Podman finds its image store through the REAL XDG_DATA_HOME, passed explicitly to the engine cases only.)
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
  forget-error:forget) exit 79 ;;
  forget-slow:forget) printf 'started\n' > "$WGM_TEST_SIGNAL_DIR/forget-started"; sleep 3; exec "$WGM_TEST_REAL_JJ" "$@" ;;
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
# (test seam: WGM_TEST_PREREQ_SELFTEST=1 makes this prerequisite fail on purpose — see the self-test just below)
if [[ -n "${WGM_TEST_PREREQ_SELFTEST:-}" ]]; then
  preflight_out="$(cd "$PROJECT" && "$SWARM" --backend jj --no-such-flag-for-selftest 2>&1)"; preflight_rc=$?
else
  preflight_out="$(cd "$PROJECT" && "$SWARM" --backend jj -n 1 --dry-run -- true 2>&1)"; preflight_rc=$?
fi
set -e
if [[ "$preflight_rc" -ne 0 ]]; then
  fail "jj workspace harness prerequisite preflight failed (rc=$preflight_rc): $preflight_out"
  exit 1
fi
# F12 self-test: drive the failing-prerequisite path (in a child run of this very harness) and assert the
# diagnostics appear: the failure message, jj's real workspace list and the parent's git status.
if [[ -z "${WGM_TEST_PREREQ_SELFTEST:-}" ]]; then
  set +e
  selftest_out="$(WGM_TEST_PREREQ_SELFTEST=1 bash "${BASH_SOURCE[0]}" 2>&1)"; selftest_rc=$?
  set -e
  if [[ "$selftest_rc" -eq 1 ]] && grep -Fq 'prerequisite preflight failed' <<<"$selftest_out" \
     && grep -Fq 'jj workspace list' <<<"$selftest_out" && grep -Fq 'git status --porcelain' <<<"$selftest_out" \
     && grep -Eq '^  default: ' <<<"$selftest_out"; then
    pass "a failing prerequisite prints its message plus jj workspace list and the parent's git status (F12)"
  else
    fail "prerequisite failure bypassed the diagnostics (rc=$selftest_rc): $selftest_out"
  fi
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
  local expected records
  expected="$(printf '%s\t%s' "$1" "$2")"
  # Capture first, then match: `jj ... | grep -q` under pipefail is a FLAKE — grep -q exits on the first
  # match, jj can then die of SIGPIPE (status 141) and the whole pipeline reports "not found" although the
  # workspace exists (the intermittent acceptance-only failure of F12).
  records="$(cd "$PROJECT" && jj --ignore-working-copy workspace list -T 'name ++ "\t" ++ root ++ "\n"')" || return 1
  grep -Fxq -- "$expected" <<<"$records"
}
parent_unchanged() {
  [[ "$(git -C "$PROJECT" rev-parse HEAD)" == "$BASE" ]] \
    && [[ "$(git -C "$PROJECT" symbolic-ref -q HEAD)" == refs/heads/main ]] \
    && [[ -z "$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all)" ]] \
    && [[ -z "$(git --git-dir="$REMOTE" for-each-ref)" ]]
}
# LIVENESS waits (is the fixture alive / has it reached state X?) get a generous, overridable window: under host load
# (CI runs this suite beside other jobs) startup is slow, and a timeout here is a flake, not a finding. They never
# decide a property under test; on timeout they say WHAT was awaited and for HOW LONG.
WAIT_SECS="${WGM_TEST_WAIT_SECS:-120}"
wait_until() {  # wait_until DESCRIPTION CMD… — poll CMD until it succeeds or WAIT_SECS elapse
  local what="$1" deadline=$((SECONDS + WAIT_SECS)); shift
  while ! "$@"; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then printf 'timeout: waited %ss for %s\n' "$WAIT_SECS" "$what" >&2; return 1; fi
    sleep 0.05
  done
}
# shellcheck disable=SC2317,SC2329  # invoked indirectly (by wait_until)
file_exists() { [[ -e "$1" ]]; }
# shellcheck disable=SC2317,SC2329  # invoked indirectly (by wait_until)
glob_matches() { compgen -G "$1" >/dev/null; }
# shellcheck disable=SC2317,SC2329  # invoked indirectly (by wait_until)
log_has() { [[ -f "$1" ]] && grep -q "$2" "$1"; }
wait_file() { wait_until "file $1" file_exists "$1"; }
wait_glob() { wait_until "a file matching $1" glob_matches "$1"; }
wait_log() { wait_until "'$2' in $1" log_has "$1" "$2"; }
# shellcheck disable=SC2317,SC2329  # invoked indirectly (by wait_until)
proc_gone() {
  local state
  kill -0 "$1" 2>/dev/null || return 0
  state="$(ps -o stat= -p "$1" 2>/dev/null || true)"
  [[ "$state" == *Z* || -z "$state" ]]
}
process_stopped() { wait_until "process $1 to stop" proc_gone "$1"; }

# Remove only this disposable fixture's workspaces/refs between cases, never the operator's.
# Count the SUCCESSFUL open/openat/openat2 calls in a `strace -f -y` log whose RETURNED descriptor resolves to TARGET
# (`= 3</…/target>`). Never argv/execve mentions: `strace -f` also follows into a container's process tree, where an
# agent's own `ln -s … target` would otherwise be miscounted as a host read.
strace_resolved_opens() {  # strace_resolved_opens LOG TARGET
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk -v t="$2" 'index($0, "<" t ">") && $0 ~ /(open|openat|openat2)[( ]/ && $0 ~ /= [0-9]+<[^>]*>[[:space:]]*$/ { n++ } END { print n + 0 }' "$1"
}
# Same, for every open that resolves to anything UNDER a directory (a whole second repository).
strace_resolved_opens_under() {  # strace_resolved_opens_under LOG DIR
  [[ -f "$1" ]] || { echo 0; return 0; }
  awk -v t="$2" 'index($0, "<" t "/") && $0 ~ /(open|openat|openat2)[( ]/ && $0 ~ /= [0-9]+<[^>]*>[[:space:]]*$/ { n++ } END { print n + 0 }' "$1"
}
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
# Each check is evaluated ONCE, at the moment of the run, and its value kept: if this ever fails, the failure
# message shows which check was false THEN (an after-the-fact re-check can already be true again — F12).
chk_ws1=n; workspace_at wgm-swarm-1 "$PROJECT/.wgm/worktrees/wgm-swarm-1" && chk_ws1=y
chk_ws2=n; workspace_at wgm-swarm-2 "$PROJECT/.wgm/worktrees/wgm-swarm-2" && chk_ws2=y
chk_c1="$(git -C "$PROJECT" rev-list --count "$BASE..wgm/swarm/1" 2>&1 || true)"
chk_c2="$(git -C "$PROJECT" rev-list --count "$BASE..wgm/swarm/2" 2>&1 || true)"
chk_m1="$(grep -c 'lesson from wgm/swarm/1' "$PROJECT/.wgm/memories.md" 2>&1 || true)"
chk_m2="$(grep -c 'lesson from wgm/swarm/2' "$PROJECT/.wgm/memories.md" 2>&1 || true)"
chk_led=n; [[ -f "$PROJECT/.wgm/metrics/wgm-swarm-1.tsv" ]] && chk_led=y
chk_par=n; parent_unchanged && chk_par=y
chk_head="$(git -C "$PROJECT" rev-parse HEAD 2>&1 || true)"
chk_stat="$(git -C "$PROJECT" status --porcelain=v1 --untracked-files=all 2>&1 || true)"
if [[ "$RC" -eq 0 && "$chk_ws1" == y && "$chk_ws2" == y && "$chk_c1" == 1 && "$chk_c2" == 1 \
      && "$chk_m1" -ge 1 && "$chk_m2" -ge 1 && "$chk_led" == y && "$chk_par" == y ]]; then
  pass "real jj workspaces produce isolated Git branches, memories, and telemetry"
else
  fail "real jj two-stream run failed (rc=$RC): $OUT
  checks at run time: ws1=$chk_ws1 ws2=$chk_ws2 commits1=$chk_c1 commits2=$chk_c2 mem1=$chk_m1 mem2=$chk_m2 ledger=$chk_led parent_unchanged=$chk_par HEAD=$chk_head base=$BASE status=[$chk_stat]"
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
   && grep -q 'work on wgm/swarm/1' <<<"$(git -C "$PROJECT" show wgm/swarm/1:IMPLEMENTATION_PLAN.md)" \
   && grep -q 'work on wgm/swarm/2' <<<"$(git -C "$PROJECT" show wgm/swarm/2:IMPLEMENTATION_PLAN.md)" \
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
  pass "explicit --backend git workflow does not invoke jj"
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
  fail "in-project TMPDIR disrupted the parent guard (rc=$RC): $OUT
$(tail -n 6 "$PROJECT"/.wgm/swarm-logs/wgm-internal-tmp-*.log 2>&1)
tmpdir left: $(find "$PROJECT/unignored-tmp" -mindepth 1 2>&1 | tr '\n' ' ') status: $(git -C "$PROJECT" status --porcelain 2>&1 | tr '\n' ' ')"
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
# The fixture removes ONLY jj: every other host tool wgm uses stays reachable (symlinks to their real paths), so the
# host-git boundary has what it needs and the failure under test is the missing jj and nothing else.
for tool in bash git dirname basename find readlink stat mktemp sha256sum shasum awk sed grep egrep cp mv rm mkdir rmdir ln \
            chmod cat date sleep kill ps env timeout gtimeout flock id uname cut tr tee sort uniq wc head tail xargs \
            printf test true false pwd ls touch tty script; do
  tp="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$tp" && "$tp" == /* && "$tool" != jj ]] && ln -sf "$tp" "$TMP/no-jj-bin/$tool"
done
set +e
OUT="$(cd "$PROJECT" && PATH="$TMP/no-jj-bin" "$SWARM" --backend jj -n 1 -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -qi 'jj' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]] && parent_unchanged; then
  pass "missing jj is rejected before mutation"
else
  fail "missing jj was not rejected cleanly (rc=$RC): $OUT"
fi
# (b) the host-git boundary's refusal is surfaced verbatim, never as "Not inside a git repository": a PATH with NO
# `find` makes the boundary refuse (exit 2); a real non-repository keeps the repository message.
mkdir -p "$TMP/no-find-bin"
for tool in bash git dirname basename readlink stat mktemp awk sed grep cp rm mkdir cat; do
  tp="$(command -v "$tool" 2>/dev/null || true)"; [[ -n "$tp" ]] && ln -sf "$tp" "$TMP/no-find-bin/$tool"
done
set +e
OUT="$(cd "$PROJECT" && PATH="$TMP/no-find-bin" "$SWARM" -n 1 --dry-run -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 2 ]] && ! grep -Fq 'Not inside a git repository' <<<"$OUT" && grep -Eiq 'sandbox:|refus|find' <<<"$OUT"; then
  pass "a host-git boundary refusal is surfaced verbatim (exit 2), not masked as 'not a repository'"
else
  fail "boundary refusal masked or wrong status (rc=$RC): $OUT"
fi
NOREPO="$(mktemp -d /tmp/wgm-nonrepo.XXXXXX)"   # outside every repository ($TMP itself lies inside one)
set +e
OUT="$(cd "$NOREPO" && "$SWARM" -n 1 --dry-run -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 2 ]] && grep -Fq 'Not inside a git repository' <<<"$OUT"; then pass "a real non-repository still reports 'Not inside a git repository'"
else fail "non-repository message wrong (rc=$RC): $OUT"; fi
rmdir "$NOREPO" 2>/dev/null || true
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
# EVENT-DRIVEN: lane 1 blocks on its release file (not a fixed sleep); wait (generously) for lane 2's end marker
# while the swarm is provably still running, and only then release lane 1.
end_seen=0
if wait_file "$TMP/signals/first-started" && wait_glob "$PROJECT/.wgm/metrics/.wgm-order-2-end-*"; then end_seen=1; fi
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
  if [[ "$RC" -eq 143 ]] && process_stopped "$agent_pid" \
     && [[ -f "$PROJECT/.wgm/worktrees/wgm-active-term-1/pending.txt" ]] \
     && workspace_at wgm-active-term-1 "$PROJECT/.wgm/worktrees/wgm-active-term-1"; then
    pass "SIGTERM after lane dispatch stops the active lane group, retains pending work and exits 143 (the originating signal)"
  else
    fail "active termination left a running agent, lost pending work or did not exit 143 (rc=$RC)"
  fi
else
  fail "active termination fixture never started"
  kill -TERM "$RUNPID" 2>/dev/null || true
  set +e; wait "$RUNPID"; set -e; RUNPID=""
fi
reset_fixture
# SIGINT after lane dispatch exits 130 (the originating signal), like SIGTERM exits 143. (A non-interactive shell starts async jobs with
# SIGINT IGNORED, which cannot be trapped — see the launcher note below.)
# (If THIS harness was itself started as a background job — CI wrappers, nohup, `cmd &` — it inherited SIGINT=SIG_IGN, which
# every child inherits and which no bash `trap`/`set -m` can undo. The swarm under test is therefore started through an exec
# helper that restores the DEFAULT SIGINT disposition first, so the case tests swarm's handler, not the launcher.)
rm -f "$TMP/signals/agent-pid"
if command -v python3 >/dev/null 2>&1; then sigint_dfl=(python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])')
elif command -v perl >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # perl source text
  sigint_dfl=(perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' --)
else sigint_dfl=(); fi
if [[ ${#sigint_dfl[@]} -eq 0 ]]; then
  echo "skip: neither python3 nor perl to restore SIGINT (SIGINT-after-dispatch case)"
else
(cd "$PROJECT" && exec "${sigint_dfl[@]}" "$SWARM" --backend jj -n 1 --prefix wgm/active-int --max-iterations 1 --cleanup -- "${AGENT_WAIT[@]}") > "$TMP/active-int.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/agent-pid"; then
  agent_pid="$(<"$TMP/signals/agent-pid")"
  kill -INT "$RUNPID"
  set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
  if [[ "$RC" -eq 130 ]] && process_stopped "$agent_pid" \
     && [[ -f "$PROJECT/.wgm/worktrees/wgm-active-int-1/pending.txt" ]] \
     && workspace_at wgm-active-int-1 "$PROJECT/.wgm/worktrees/wgm-active-int-1"; then
    pass "SIGINT after lane dispatch stops the active lane group, retains pending work and exits 130 (the originating signal)"
  else
    fail "SIGINT after dispatch did not exit 130 / left an agent / lost pending work (rc=$RC agent-stopped=$(process_stopped "$agent_pid" >/dev/null 2>&1 && echo y || echo n) pending=$([[ -f "$PROJECT/.wgm/worktrees/wgm-active-int-1/pending.txt" ]] && echo y || echo n) handler-ran=$(grep -c 'Interrupted:' "$TMP/active-int.log" || true)): $(cat "$TMP/active-int.log")"
  fi
else
  fail "SIGINT fixture never started"
  kill -TERM "$RUNPID" 2>/dev/null || true
  set +e; wait "$RUNPID"; set -e; RUNPID=""
fi
fi
reset_fixture
rm -f "$TMP/signals/agent-pid"
(cd "$PROJECT" && exec "$SWARM" --backend git -n 1 --prefix wgm/git-term --max-iterations 1 --cleanup -- "${AGENT_WAIT[@]}") > "$TMP/git-term.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/agent-pid"; then
  agent_pid="$(<"$TMP/signals/agent-pid")"
  kill -TERM "$RUNPID"
  set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
  if [[ "$RC" -eq 143 ]] && process_stopped "$agent_pid" \
     && [[ -f "$PROJECT/.wgm/worktrees/wgm-git-term-1/pending.txt" ]]; then
    pass "SIGTERM also stops the Git lane group, retains pending work and exits 143"
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
native_files="$(cd "$NATIVE" && jj --ignore-working-copy file list -r @)"  # capture first: no pipefail/SIGPIPE flake
if ! grep -Fxq 'auto-track-probe.txt' <<<"$native_files"; then
  pass "jj lifecycle override does not auto-track a new untracked file"
else
  fail "jj lifecycle override still snapshotted a new untracked file"
fi

# F12 self-check: a failure message must carry jj's workspace list and the parent's porcelain status, so an
# intermittent acceptance-only failure is diagnosable from the log alone.
diag_out="$(fail_diagnostics 2>&1)"
if grep -Fq 'jj workspace list' <<<"$diag_out" && grep -Fq 'git status --porcelain' <<<"$diag_out" \
   && grep -Fq 'default' <<<"$diag_out"; then
  pass "failure diagnostics print jj workspace list and the parent's git status"
else
  printf 'FAIL: failure diagnostics missing the workspace list or parent status: %s\n' "$diag_out" >&2
  FAILED=1
fi

# The default backend is jj in a colocated jj repository and the notice-bearing Git fallback elsewhere.
run --tasks "$TMP/tasks.txt" --dry-run -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -Fq 'backend=jj' <<<"$OUT"; then
  pass "swarm defaults to the jj backend in a colocated jj repository"
else
  fail "default backend was not jj in a colocated repo (rc=$RC): $OUT"
fi
run_in "$PLAIN" --tasks "$TMP/tasks.txt" --dry-run -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 0 ]] && grep -Fq 'backend=git' <<<"$OUT" && grep -Fq 'using the git backend' <<<"$OUT"; then
  pass "a repository without jj falls back to git with one visible notice"
else
  fail "no visible git fallback outside a jj repository (rc=$RC): $OUT"
fi
# A dirty parent is a refusal, never a silent fallback to Git (default backend, colocated repo).
printf 'dirty\n' >> "$PROJECT/protected.txt"
run --tasks "$TMP/tasks.txt" -- "${AGENT_OK[@]}"
if [[ "$RC" -eq 2 ]] && grep -Fq 'clean parent' <<<"$OUT" && ! grep -Fq 'using the git backend' <<<"$OUT"; then
  pass "a dirty parent exits 2 without falling back to git"
else
  fail "dirty parent did not refuse with exit 2 (rc=$RC): $OUT"
fi
git -C "$PROJECT" checkout -q -- protected.txt


# ---- V5: supervised preflight + accountable teardown of the throwaway preflight workspace -------------------------
# Engines that cannot run make the (sandboxed-by-default) preflight refuse AFTER its throwaway workspace exists, so
# teardown is exercised without a container. HOME/XDG_CONFIG_HOME are already throwaway; stdin is never a tty.
STUBE="$TMP/engstub"; mkdir -p "$STUBE"
for e in podman docker; do printf '#!/bin/sh\nexit 1\n' > "$STUBE/$e"; chmod +x "$STUBE/$e"; done
pf_registered() { (cd "$PROJECT" && jj --ignore-working-copy workspace list -T 'name ++ "\n"' 2>&1) | grep -c '^wgm-preflight-' || true; }
# (a) a jj whose `workspace forget` fails: the retained workspace is NAMED with its exact recovery, status non-zero
set +e
OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER WGM_TEST_JJ_FAULT=forget-error PATH="$STUBE:$PATH" "$SWARM" -n 1 --prefix wgm/pfa -- "${AGENT_OK[@]}" </dev/null 2>&1)"; RC=$?
set -e
pf_name="$(grep -o 'retained preflight workspace wgm-preflight-[0-9]*' <<<"$OUT" | awk '{print $4}' | head -1)"
pf_path="$(grep -o 'retained preflight workspace [^ ]* at [^ ]*' <<<"$OUT" | awk '{print $6}' | head -1)"
if [[ "$RC" -ne 0 && -n "$pf_name" && -d "$pf_path" ]] \
   && grep -Fq "recover: jj workspace forget $pf_name && rm -rf $pf_path" <<<"$OUT" \
   && grep -Fq 'workspace forget' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]]; then
  pass "failed preflight-workspace teardown prints the exact retained line + recovery, exits non-zero, creates no lane"
else
  fail "retained-workspace accounting missing (rc=$RC name=[$pf_name] path=[$pf_path]): $OUT"
fi
# the printed recovery command works
if [[ -n "$pf_name" ]]; then (cd "$PROJECT" && jj workspace forget "$pf_name" >/dev/null 2>&1); rm -rf "$pf_path" "$(dirname "$pf_path")"; fi
if [[ "$(pf_registered)" == 0 ]]; then pass "the printed recovery command clears the retained preflight workspace"; else fail "recovery did not clear the retained workspace"; fi
git -C "$PROJECT" worktree prune; reset_fixture
# (b) TERM while teardown is running: teardown finishes first (workspace really gone), then exit 143
rm -f "$TMP/signals/forget-started"
(cd "$PROJECT" && exec env -u WGM_DEVCONTAINER WGM_TEST_JJ_FAULT=forget-slow PATH="$STUBE:$PATH" "$SWARM" -n 1 --prefix wgm/pfb -- "${AGENT_OK[@]}" </dev/null) > "$TMP/pfb.log" 2>&1 &
RUNPID=$!
if wait_file "$TMP/signals/forget-started"; then kill -TERM "$RUNPID"; fi
set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
if [[ "$RC" -eq 143 && "$(pf_registered)" == 0 ]] && ! compgen -G "$TMPDIR/wgm-swarm-pf.*" >/dev/null && ! grep -q 'retained preflight' "$TMP/pfb.log"; then
  pass "TERM during teardown: teardown completes, no preflight workspace left, exit 143"
else
  fail "TERM during teardown mishandled (rc=$RC registered=$(pf_registered)): $(cat "$TMP/pfb.log")"
fi
git -C "$PROJECT" worktree prune; reset_fixture

# ---- V15/B4 (T8): the PUBLISHED jj setup fence in docs/reference/cli-swarm.md is EXTRACTED and EXECUTED --------------
# (so doc drift breaks this test): with failing prerequisites it must stop the chain with that step's own status and
# mutate nothing; with successful prerequisites it completes and keeps swarm's exit status through cleanup.
DOC_SWARM="${WGM_DOC_CLI_SWARM:-$ROOT/docs/reference/cli-swarm.md}"
T8D="$TMP/t8"; mkdir -p "$T8D/bin" "$T8D/skill/scripts" "$T8D/proj"
FENCE="$(awk '/^```bash$/ { f = 1; buf = ""; next } /^```$/ { if (f && buf ~ /swarm\.sh/ && buf ~ /IMPLEMENTATION_PLAN\.md/ && buf ~ /workspace root/) { printf "%s", buf; exit } f = 0; next } f { buf = buf $0 "\n" }' "$DOC_SWARM")"
if [[ -z "$FENCE" ]]; then
  fail "T8: could not extract the jj setup fence from $DOC_SWARM"
else
  # stubs: jj/git behave unless a fail-flag file exists (status = the file's content); swarm.sh records its argv
  for tool in jj git; do
    cat > "$T8D/bin/$tool" <<'SH'
#!/usr/bin/env bash
tool="$(basename "$0")"; key="$tool:$*"
for f in "$T8_FLAGS"/*; do
  [[ -f "$f" ]] || continue
  pat="$(basename "$f")"; pat="${pat//__/ }"
  if [[ "$key" == *"$pat"* ]]; then exit "$(cat "$f")"; fi
done
case "$key" in
  jj:--version) echo "jj 0.46.0" ;;
  git:--version) echo "git version 2.43.0" ;;
  *"workspace root") pwd ;;
esac
exit 0
SH
    chmod +x "$T8D/bin/$tool"
  done
  cat > "$T8D/skill/scripts/swarm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T8_CALLS"
exit "$(cat "$T8_SWARM_RC" 2>/dev/null || echo 0)"
SH
  chmod +x "$T8D/skill/scripts/swarm.sh"
  printf '# plan\n' > "$T8D/proj/IMPLEMENTATION_PLAN.md"
  t8_run() {  # t8_run → sets T8RC; env: T8_FLAGS dir with fail flags, T8_SWARM_RC
    : > "$T8_CALLS"
    set +e
    (cd "$T8D/proj" && PATH="$T8D/bin:$PATH" WGM_SKILL_ROOT="$T8D/skill" T8_FLAGS="$T8_FLAGS" T8_CALLS="$T8_CALLS" T8_SWARM_RC="$T8_SWARM_RC" bash -c "$FENCE" >"$TMP/t8.out" 2>&1)
    T8RC=$?
    set -e
  }
  export T8_CALLS="$T8D/calls" T8_SWARM_RC="$T8D/swarm-rc"; : > "$T8_CALLS"
  t8_tasks_before="$(find /tmp -maxdepth 1 -name 'wgm-tasks.*' 2>/dev/null | wc -l)"
  # (1) failing prerequisite: `jj ... workspace root` exits 3 -> the chain stops with status 3, swarm never runs
  T8_FLAGS="$T8D/flags-fail"; mkdir -p "$T8_FLAGS"; printf '3\n' > "$T8_FLAGS/jj:--ignore-working-copy__workspace__root"
  echo 0 > "$T8_SWARM_RC"; t8_run
  if [[ "$T8RC" -eq 3 && ! -s "$T8_CALLS" ]]; then pass "T8: a failing jj prerequisite stops the published fence with its own status (3); swarm never ran"
  else fail "T8: failing jj prerequisite did not stop the chain (rc=$T8RC calls=[$(cat "$T8_CALLS")]): $(cat "$TMP/t8.out")"; fi
  # (2) failing prerequisite: no IMPLEMENTATION_PLAN.md -> non-zero, swarm never ran
  T8_FLAGS="$T8D/flags-ok"; mkdir -p "$T8_FLAGS"
  mv "$T8D/proj/IMPLEMENTATION_PLAN.md" "$T8D/plan.hold"; t8_run
  if [[ "$T8RC" -ne 0 && ! -s "$T8_CALLS" ]]; then pass "T8: a missing IMPLEMENTATION_PLAN.md stops the published fence (rc=$T8RC); swarm never ran"
  else fail "T8: missing plan did not stop the chain (rc=$T8RC calls=[$(cat "$T8_CALLS")]): $(cat "$TMP/t8.out")"; fi
  mv "$T8D/plan.hold" "$T8D/proj/IMPLEMENTATION_PLAN.md"
  # (2b) `git status` prints NOTHING and exits 73: the fence must exit 73 (a silent failure is still a failure), never
  # call swarm, and create no task file
  T8_FLAGS="$T8D/flags-gitstatus"; mkdir -p "$T8_FLAGS"; printf '73\n' > "$T8_FLAGS/git:status"
  echo 0 > "$T8_SWARM_RC"; t8_run
  if [[ "$T8RC" -eq 73 && ! -s "$T8_CALLS" ]] && [[ "$(find /tmp -maxdepth 1 -name 'wgm-tasks.*' 2>/dev/null | wc -l)" -le "$t8_tasks_before" ]]; then
    pass "T8: a silent failing \`git status\` (exit 73) stops the published fence with 73; swarm never ran, no task file"
  else
    fail "T8: silent git status failure did not stop the chain with its own status (rc=$T8RC calls=[$(cat "$T8_CALLS")]): $(cat "$TMP/t8.out")"
  fi
  T8_FLAGS="$T8D/flags-ok"
  # no mutation by the failing runs: no task file left behind in /tmp, nothing created in the project
  t8_tasks_after="$(find /tmp -maxdepth 1 -name 'wgm-tasks.*' 2>/dev/null | wc -l)"
  if [[ "$t8_tasks_after" -le "$t8_tasks_before" && "$(find "$T8D/proj" -mindepth 1 | wc -l)" -eq 1 ]]; then pass "T8: the failing runs mutated nothing (no task file, project untouched)"
  else fail "T8: failing runs left artifacts (tasks $t8_tasks_before -> $t8_tasks_after): $(find "$T8D/proj" -mindepth 1 | tr '\n' ' ')"; fi
  # (3) successful prerequisites: the fence completes; swarm's status is preserved through the final cleanup
  for rcv in 0 7; do
    echo "$rcv" > "$T8_SWARM_RC"; t8_run
    if [[ "$T8RC" -eq "$rcv" ]] && grep -Fq -- '--backend jj' "$T8_CALLS" && grep -Fq -- '--cleanup' "$T8_CALLS" && [[ "$(wc -l < "$T8_CALLS")" -eq 1 ]]; then
      pass "T8: successful prerequisites run swarm once and the fence exits with swarm's own status ($rcv)"
    else
      fail "T8: success path wrong for swarm status $rcv (rc=$T8RC calls=[$(cat "$T8_CALLS")]): $(cat "$TMP/t8.out")"
    fi
  done
  t8_tasks_end="$(find /tmp -maxdepth 1 -name 'wgm-tasks.*' 2>/dev/null | wc -l)"
  if [[ "$t8_tasks_end" -le "$t8_tasks_before" ]]; then pass "T8: the fence removes its task file after the swarm"; else fail "T8: the fence left its task file behind"; fi
fi

# DEFAULT sandbox (no --no-devcontainer, WGM_DEVCONTAINER unset): one preflight, one decision file, each lane's
# agent in its own container, lanes commit, the decision file is gone afterwards. Real engine only; a host
# without one skips VISIBLY so CI without an engine stays green.
BOX_ENGINE=""
for e in podman docker; do
  if command -v "$e" >/dev/null 2>&1 && XDG_DATA_HOME="$REAL_DATA_HOME" "$e" info >/dev/null 2>&1; then BOX_ENGINE="$e"; break; fi
done
BOX_IMAGE="localhost/wgm-devcontainer-base:latest"
if [[ -z "$BOX_ENGINE" ]]; then
  echo "skip: no container engine (default-sandbox swarm test)"
elif ! XDG_DATA_HOME="$REAL_DATA_HOME" "$BOX_ENGINE" image inspect "$BOX_IMAGE" >/dev/null 2>&1; then
  echo "skip: no $BOX_IMAGE image (default-sandbox swarm test)"
else
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 2 --prefix wgm/boxed --max-iterations 1 --cleanup -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
  set -e
  if [[ "$RC" -eq 0 ]] && grep -Fq "sandbox: on ($BOX_ENGINE" <<<"$OUT" \
     && grep -Fq '2/2 lanes ran the agent in a container' <<<"$OUT" \
     && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..wgm/boxed/1")" -ge 1 ]] \
     && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..wgm/boxed/2")" -ge 1 ]]; then
    pass "default-sandbox jj swarm: both lanes ran in containers and committed"
  else
    fail "default-sandbox jj swarm failed (rc=$RC): $OUT"
  fi
  if ! compgen -G "$TMPDIR/wgm-decision.*" >/dev/null && ! grep -Fq 'retained container' <<<"$OUT"; then
    pass "default-sandbox swarm deleted its decision file and left no container behind"
  else
    fail "decision file or container survived the default-sandbox swarm: $OUT"
  fi

  # Gate quoting (rugged F2) end to end: quotes, $VAR, && and spaces in sandboxed swarm gates (preflight smoke AND
  # each lane iteration run every gate separately via bash -c inside the container).
  cat > "$TMP/box-gates.yml" <<'YML'
gates:
  - sh -c 'echo ready'
  - test -n "$HOME" && echo "a b"
YML
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 1 --prefix wgm/gq --gates "$TMP/box-gates.yml" --max-iterations 1 -- "${AGENT_OK[@]}" 2>&1)"; RC=$?
  set -e
  if [[ "$RC" -eq 0 ]] && grep -Fq "sandbox: on ($BOX_ENGINE" <<<"$OUT" && grep -Fq '1/1 lanes ran the agent in a container' <<<"$OUT"; then
    pass "sandboxed swarm runs gates with quotes, \$VAR, && and spaces"
  else
    fail "sandboxed swarm refused or failed quoted gates (rc=$RC): $OUT"
  fi

  # Trusted runner BEFORE preflight (rugged r2 S39): the skill dir lives INSIDE the jj-colocated project, and the
  # agent's readiness `--version` (run in a container with the project mounted rw) replaces the skill's
  # swarm/loop/sandbox/devcontainer scripts with copies that touch a HOST marker. Swarm must already be running
  # from a private snapshot, so no marker appears and the swarm still works.
  SK="$PROJECT/skill"; MARK="$TMP/host-marker"; AGBIN="$TMP/agentbin/bin"
  rm -f "$MARK"; mkdir -p "$SK" "$AGBIN"
  cp -R "$ROOT/scripts" "$SK/scripts"; [[ ! -d "$ROOT/assets" ]] || cp -R "$ROOT/assets" "$SK/assets"
  printf '/skill/\n' >> "$PROJECT/.git/info/exclude"
  cat > "$AGBIN/evil-agent" <<AG
#!/usr/bin/env bash
if [[ -d "$SK/scripts" ]]; then
  for f in swarm loop sandbox devcontainer; do printf '#!/usr/bin/env bash\ntouch "$MARK"\n' > "$SK/scripts/\$f.sh" 2>/dev/null || true; done
fi
[[ "\${1:-}" != --version ]] || { echo "evil-agent 1"; exit 0; }
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$AGBIN/evil-agent"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SK/scripts/swarm.sh" -n 1 --prefix wgm/tr --max-iterations 1 -- "$AGBIN/evil-agent" 2>&1)"; RC=$?
  set -e
  if [[ "$RC" -eq 0 && ! -e "$MARK" ]] && grep -Fq '1/1 lanes ran the agent in a container' <<<"$OUT" \
     && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..wgm/tr/1")" -ge 1 ]] \
     && ! compgen -G "$TMPDIR/wgm-runner.*" >/dev/null; then
    pass "in-project skill dir: swarm runs from a private snapshot before preflight; a contained agent cannot plant host code"
  else
    fail "trusted-runner-before-preflight violated (rc=$RC marker=$([[ -e "$MARK" ]] && echo PLANTED || echo none)): $OUT"
  fi
  rm -rf "$SK"

  # C4 (rugged r6, S44/S44b): NO container ever mounts the PARENT checkout, and every host git call (swarm, lane
  # loops, the parent guard, jj's children) is neutralized. The parent has an operator-configured IN-TREE
  # fsmonitor hook and clean filter; the readiness command rewrites them (it could, if the parent were mounted).
  FX="$TMP/fsmrepo"; FXS="$TMP/fx-sent"; FXSHIM="$TMP/fx-shim"; AGBIN2="$TMP/agentbin2/bin"
  mkdir -p "$FX/tools" "$FXS" "$FXSHIM" "$AGBIN2"
  git -C "$FX" init -q -b main
  git -C "$FX" config user.name fixture; git -C "$FX" config user.email fixture@example.invalid
  printf '/.wgm/\n' > "$FX/.gitignore"; printf '# plan\n' > "$FX/IMPLEMENTATION_PLAN.md"
  printf '*.dat filter=wgmclean\n' > "$FX/.gitattributes"; printf 'data\n' > "$FX/a.dat"
  printf '#!/bin/sh\ntouch "%s/fsm-fired"\nprintf "tok\\0"\n' "$FXS" > "$FX/tools/fsm.sh"
  printf '#!/bin/sh\ntouch "%s/clean-fired"\ncat\n' "$FXS" > "$FX/tools/clean.sh"
  chmod +x "$FX/tools/fsm.sh" "$FX/tools/clean.sh"
  git -C "$FX" add -A && git -C "$FX" commit -qm seed
  git -C "$FX" config core.fsmonitor "$FX/tools/fsm.sh"
  git -C "$FX" config filter.wgmclean.clean "$FX/tools/clean.sh"
  (cd "$FX" && jj git init --colocate >/dev/null 2>&1)
  FXBASE="$(git -C "$FX" rev-parse HEAD)"
  FX_CLEAN_SUM="$(sha256sum < "$FX/tools/clean.sh")"; FX_FSM_SUM="$(sha256sum < "$FX/tools/fsm.sh")"
  # positive controls: plain host git fires BOTH operator hooks, and a rewritten clean script fires too
  touch "$FX/a.dat"; git -C "$FX" status >/dev/null 2>&1
  if [[ -e "$FXS/fsm-fired" && -e "$FXS/clean-fired" ]]; then pass "C4 fixture: plain host git fires the in-tree fsmonitor hook and the clean filter"
  else fail "C4 fixture broken: plain git did not fire both hooks (fsm=$([[ -e "$FXS/fsm-fired" ]] && echo y || echo n) clean=$([[ -e "$FXS/clean-fired" ]] && echo y || echo n))"; fi
  rm -f "$FXS"/*
  # the attack: a readiness command that rewrites both in-tree scripts to touch HOST markers
  cat > "$AGBIN2/evil-agent" <<AG
#!/usr/bin/env bash
for f in clean fsm; do
  [[ -d "$FX/tools" ]] && printf '#!/bin/sh\ntouch "$FXS/EVIL-%s"\ncat\n' "\$f" > "$FX/tools/\$f.sh" 2>/dev/null
done
[[ "\${1:-}" != --version ]] || { echo "evil-agent 1"; exit 0; }
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$AGBIN2/evil-agent"
  cp "$FX/tools/clean.sh" "$TMP/clean.orig"; printf '#!/bin/sh\ntouch "%s/EVIL-clean"\ncat\n' "$FXS" > "$FX/tools/clean.sh"
  # (core.fsmonitor=false here: wgm's own argv cannot disable a clean FILTER, which is why the parent must never be mounted)
  touch "$FX/a.dat"; git -C "$FX" -c core.fsmonitor=false status >/dev/null 2>&1
  if [[ -e "$FXS/EVIL-clean" ]]; then pass "C4 fixture: a rewritten clean script would fire on the host"; else fail "C4 fixture: rewritten clean script did not fire"; fi
  cp "$TMP/clean.orig" "$FX/tools/clean.sh"; rm -f "$FXS"/*; git -C "$FX" status >/dev/null 2>&1; rm -f "$FXS"/*
  # shims OUTSIDE every mount: git logs a verdict per host call, the engine logs its argv
  REAL_PODMAN="$(command -v "$BOX_ENGINE")"
  cat > "$FXSHIM/git" <<SH
#!/usr/bin/env bash
a="\$*"
[[ "\$a" == *"worktree add -h"* ]] && exec "$REAL_GIT" "\$@"
n="\${GIT_CONFIG_COUNT:-0}"; cfg=""; i=0
while [[ "\$i" -lt "\$n" ]]; do k="GIT_CONFIG_KEY_\$i"; v="GIT_CONFIG_VALUE_\$i"; cfg+=" \${!k}=\${!v}"; i=\$((i + 1)); done
ok=1
for need in core.fsmonitor=false core.hooksPath=/dev/null protocol.allow=never; do
  [[ "\$a" == *"\$need"* || "\$cfg" == *"\$need"* ]] || ok=0
done
[[ "\${GIT_ALLOW_PROTOCOL+set}" == set && -z "\${GIT_ALLOW_PROTOCOL}" && "\${GIT_NO_LAZY_FETCH:-}" == 1 ]] || ok=0
if [[ "\$ok" == 1 ]]; then echo "OK \$PPID" >> "$FXS/../fx-git.log"; else echo "BAD (\$PWD) \$a [cfgcount=\${GIT_CONFIG_COUNT-unset} cfg=\$cfg allow=\${GIT_ALLOW_PROTOCOL-unset} lazy=\${GIT_NO_LAZY_FETCH-unset} ppid=\$PPID]" >> "$FXS/../fx-git.log"; fi
exec "$REAL_GIT" "\$@"
SH
  cat > "$FXSHIM/$BOX_ENGINE" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FXS/../fx-engine.log"
exec "$REAL_PODMAN" "\$@"
SH
  chmod +x "$FXSHIM/git" "$FXSHIM/$BOX_ENGINE"; rm -f "$TMP/fx-git.log" "$TMP/fx-engine.log"
  set +e
  OUT="$(cd "$FX" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$FXSHIM:$PATH" "$SWARM" -n 1 --prefix wgm/c4 --max-iterations 1 -- "$AGBIN2/evil-agent" 2>&1)"; RC=$?
  set -e
  fx_bad="$(grep -c '^BAD' "$TMP/fx-git.log" 2>/dev/null || true)"; fx_ok="$(grep -c '^OK' "$TMP/fx-git.log" 2>/dev/null || true)"
  fx_parent_mount="$(grep -cE "(source|src)=$FX(,| |$)|-v $FX:" "$TMP/fx-engine.log" 2>/dev/null || true)"
  fx_runs="$(grep -c '^run ' "$TMP/fx-engine.log" 2>/dev/null || true)"
  if [[ "$RC" -eq 0 && ! -e "$FXS/fsm-fired" && ! -e "$FXS/EVIL-clean" && ! -e "$FXS/EVIL-fsm" ]] \
     && [[ "$FX_CLEAN_SUM" == "$(sha256sum < "$FX/tools/clean.sh")" && "$FX_FSM_SUM" == "$(sha256sum < "$FX/tools/fsm.sh")" ]] \
     && [[ "$(git -C "$FX" -c core.fsmonitor=false rev-parse HEAD)" == "$FXBASE" ]] \
     && [[ -z "$(git -C "$FX" -c core.fsmonitor=false status --porcelain)" ]]; then
    pass "C4: no host sentinel fired, the parent's scripts and tree are untouched"
  else
    fail "C4 violated (rc=$RC) fsm=$([[ -e "$FXS/fsm-fired" ]] && echo FIRED || echo no) evil=$(find "$FXS" -mindepth 1 2>&1 | tr '\n' ' '): $OUT"
  fi
  if [[ "$fx_runs" -ge 2 && "$fx_parent_mount" -eq 0 ]]; then pass "C4: no container engine argv names the parent checkout as a mount source ($fx_runs runs)"
  else fail "C4: parent mounted or no engine runs traced (runs=$fx_runs parent-mounts=$fx_parent_mount): $(head -c 600 "$TMP/fx-engine.log" 2>&1)"; fi
  if [[ "$fx_ok" -ge 5 && "$fx_bad" -eq 0 ]]; then pass "C4: every traced host git call carries the protections ($fx_ok calls)"
  else fail "C4: unprotected host git calls (ok=$fx_ok bad=$fx_bad): $(grep '^BAD' "$TMP/fx-git.log" 2>&1 | head -5)"; fi
  if ! compgen -G "$TMPDIR/wgm-swarm-pf.*" >/dev/null && ! git -C "$FX" worktree list | grep -q 'wgm-swarm-pf\|preflight' \
     && ! (cd "$FX" && jj --ignore-working-copy workspace list 2>&1) | grep -q preflight; then
    pass "C4: the throwaway preflight workspace is gone (temp dir, git worktree list, jj workspace list)"
  else fail "C4: preflight workspace left behind: $(git -C "$FX" worktree list 2>&1 | tr '\n' ' ')"; fi

  # ---- V5 (real engine) --------------------------------------------------------------------------------------
  # S45: SIGTERM while the readiness `--version` is running inside the preflight workspace's container. swarm must
  # exit promptly (<20 s), leave no container and no preflight workspace (or print the exact retained line).
  AGBIN4="$TMP/agentbin4/bin"; mkdir -p "$AGBIN4"
  cat > "$AGBIN4/slow-agent" <<'AG'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then touch "$PWD/.slow-started"; sleep 60; exit 0; fi
exit 0
AG
  chmod +x "$AGBIN4/slow-agent"
  # (only THIS fixture repository's containers count — wgm names them wgm-<repo key8>-<pid>-<seq>; another run on the same
  # host, e.g. a concurrent gate, legitimately creates containers of its own repositories)
  s45_key="$(printf '%s' "$(readlink -f "$PROJECT/.git")" | sha256sum | cut -c1-8)"
  names_before="$(XDG_DATA_HOME="$REAL_DATA_HOME" "$BOX_ENGINE" ps -a --filter label=wgm.devcontainer=1 --format '{{.Names}}' 2>/dev/null | grep "^wgm-${s45_key}-" | sort || true)"
  (cd "$PROJECT" && exec env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 1 --prefix wgm/s45 -- "$AGBIN4/slow-agent" </dev/null) > "$TMP/s45.log" 2>&1 &
  RUNPID=$!
  s45_seen=0
  if wait_glob "$TMPDIR/wgm-swarm-pf.*/ws/.slow-started"; then s45_seen=1; fi
  t0=$SECONDS
  [[ "$s45_seen" -eq 1 ]] && kill -TERM "$RUNPID"
  set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
  s45_secs=$((SECONDS - t0))
  names_after="$(XDG_DATA_HOME="$REAL_DATA_HOME" "$BOX_ENGINE" ps -a --filter label=wgm.devcontainer=1 --format '{{.Names}}' 2>/dev/null | grep "^wgm-${s45_key}-" | sort || true)"
  new_containers="$(comm -13 <(printf '%s\n' "$names_before") <(printf '%s\n' "$names_after") | tr '\n' ' ')"
  if [[ "$s45_seen" -eq 1 && "$RC" -eq 143 && "$s45_secs" -lt 20 && -z "${new_containers// /}" && "$(pf_registered)" == 0 ]] \
     && ! compgen -G "$TMPDIR/wgm-swarm-pf.*" >/dev/null; then
    pass "S45: TERM during slow readiness: exit 143 in ${s45_secs}s, no container, no preflight workspace"
  else
    fail "S45: TERM during readiness (seen=$s45_seen rc=$RC secs=$s45_secs containers=[$new_containers] registered=$(pf_registered)): $(cat "$TMP/s45.log")"
  fi
  git -C "$PROJECT" worktree prune; reset_fixture

  # a failed teardown after a SUCCESSFUL preflight is never green and starts no lane
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" WGM_TEST_JJ_FAULT=forget-error "$SWARM" -n 1 --prefix wgm/pfd --max-iterations 1 -- "${AGENT_OK[@]}" </dev/null 2>&1)"; RC=$?
  set -e
  pf_name="$(grep -o 'retained preflight workspace wgm-preflight-[0-9]*' <<<"$OUT" | awk '{print $4}' | head -1)"
  pf_path="$(grep -o 'retained preflight workspace [^ ]* at [^ ]*' <<<"$OUT" | awk '{print $6}' | head -1)"
  if [[ "$RC" -ne 0 && -n "$pf_name" ]] && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-pfd-1" ]] && ! git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/pfd/1; then
    pass "unverifiable preflight teardown fails the run before any lane (retained line printed)"
  else
    fail "retained preflight workspace did not fail the run cleanly (rc=$RC): $OUT"
  fi
  if [[ -n "$pf_name" ]]; then (cd "$PROJECT" && jj workspace forget "$pf_name" >/dev/null 2>&1); rm -rf "$pf_path" "$(dirname "$pf_path")"; fi
  git -C "$PROJECT" worktree prune; reset_fixture

  # T2 (spec fixtures): failing gate, interactive "proceed anyway" at the ONE preflight, 2 lanes -> exactly ONE
  # prompt, lanes start silently (the decision file carries the override), each lane's gate still fails its
  # iteration; a headless rerun refuses before any lane.
  AGBIN3="$TMP/agentbin3/bin"; mkdir -p "$AGBIN3"
  cat > "$AGBIN3/ok-agent" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$AGBIN3/ok-agent"
  printf 'gates:\n  - false\n' > "$TMP/fail-gates.yml"
  if command -v script >/dev/null 2>&1; then
    # the answer is typed at once but stdin stays OPEN until the run ends (no fixed 30 s window the prompt could miss)
    timeout 900 script -qec "cd '$PROJECT' && env -u WGM_DEVCONTAINER XDG_DATA_HOME='$REAL_DATA_HOME' '$SWARM' -n 2 --prefix wgm/t2 --gates '$TMP/fail-gates.yml' --max-iterations 1 -- '$AGBIN3/ok-agent'" /dev/null > "$TMP/t2.log" 2>&1 < <(printf 'y\n'; exec sleep 1000) 2>&1 || true
    kill "$!" 2>/dev/null || true   # the stdin feeder (process substitution)
    t2_prompts="$(grep -c 'Proceed anyway' "$TMP/t2.log" || true)"
    t2_lane_prompts="$(cat "$PROJECT"/.wgm/swarm-logs/wgm-t2-*.log 2>/dev/null | grep -c '\[y/N\]\|Proceed anyway' || true)"
    t2_gatefail="$(grep -l 'Project gate failed' "$PROJECT"/.wgm/swarm-logs/wgm-t2-*.log 2>/dev/null | wc -l)"
    if [[ "$t2_prompts" -eq 1 && "$t2_lane_prompts" -eq 0 && "$t2_gatefail" -eq 2 ]] && grep -Fq 'sandbox: on' "$TMP/t2.log"; then
      pass "T2: one interactive 'proceed anyway', both lanes start silently, each lane's gate still fails its iteration"
    else
      fail "T2 wrong (prompts=$t2_prompts lane-prompts=$t2_lane_prompts lanes-with-gate-failure=$t2_gatefail): $(tail -n 30 "$TMP/t2.log")"
    fi
    set +e
    OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 2 --prefix wgm/t2b --gates "$TMP/fail-gates.yml" --max-iterations 1 -- "$AGBIN3/ok-agent" </dev/null 2>&1)"; RC=$?
    set -e
    if [[ "$RC" -eq 2 && ! -e "$PROJECT/.wgm/worktrees/wgm-t2b-1" ]] && ! git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/t2b/1 \
       && grep -Fq 'no lane was created' <<<"$OUT"; then
      pass "T2: the headless rerun refuses (exit 2) before any lane starts"
    else
      fail "T2 headless rerun did not refuse cleanly (rc=$RC): $OUT"
    fi
  else
    echo "skip: no script(1) for the pty (T2 interactive case)"
  fi
  git -C "$PROJECT" worktree prune

  # V7 (rugged r9, S49): a lane whose CONTAINED commit hook swaps a tracked directory for a symlink to a canary
  # outside every mount. `--cleanup` must not read through the symlink (no host open resolves outside the lane)
  # and must retain the lane naming the path. Observer: strace -f -y with a positive control (visible skip without).
  if ! command -v strace >/dev/null 2>&1; then
    echo "skip: no strace (symlinked-ancestor cleanup trace)"
  else
    SY="$TMP/symrepo"; SYOUT="$TMP/sym-outside"; SYAG="$TMP/agentbin5/bin"
    mkdir -p "$SY/payload" "$SY/tools" "$SYOUT" "$SYAG"
    git -C "$SY" init -q -b main
    git -C "$SY" config user.name fixture; git -C "$SY" config user.email fixture@example.invalid
    printf '/.wgm/\n' > "$SY/.gitignore"; printf '# plan\n' > "$SY/IMPLEMENTATION_PLAN.md"
    printf 'tracked payload\n' > "$SY/payload/item"; printf '#!/bin/sh\nexit 0\n' > "$SY/tools/precommit.sh"
    git -C "$SY" add -A && git -C "$SY" commit -qm seed
    printf '#!/bin/sh\nsh tools/precommit.sh\n' > "$SY/.git/hooks/pre-commit"; chmod +x "$SY/.git/hooks/pre-commit"
    printf 'CANARY-OUTSIDE\n' > "$SYOUT/item"
    (cd "$SY" && jj git init --colocate >/dev/null 2>&1)
    # the agent rewrites the tracked helper (and declares it); the contained commit then runs it via the hook
    cat > "$SYAG/sym-agent" <<AG
#!/usr/bin/env bash
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
printf '#!/bin/sh\nrm -rf payload\nln -s "$SYOUT" payload\nexit 0\n' > tools/precommit.sh
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md
printf "IMPLEMENTATION_PLAN.md\ntools/precommit.sh\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$SYAG/sym-agent"
    set +e
    (cd "$SY" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" strace -f -y -qq -e trace=openat,open,openat2,newfstatat,readlink,readlinkat,statx,execve -o "$TMP/sym-strace.log" \
      "$SWARM" -n 1 --prefix wgm/sy --max-iterations 1 --cleanup -- "$SYAG/sym-agent" </dev/null > "$TMP/sym.out" 2>&1)
    RC=$?
    set -e
    sy_lane="$SY/.wgm/worktrees/wgm-sy-1"
    # positive control: the observer DOES see a read through that symlink (this is what the unsafe code path did)
    set +e
    strace -f -y -qq -e trace=openat -o "$TMP/sym-ctl.log" cat "$sy_lane/payload/item" >/dev/null 2>&1
    set -e
    sy_ctl="$(strace_resolved_opens "$TMP/sym-ctl.log" "$SYOUT/item")"
    sy_hits="$(strace_resolved_opens "$TMP/sym-strace.log" "$SYOUT/item")"
    sy_hash="$(grep -c 'hash-object' "$TMP/sym-strace.log" 2>/dev/null || true)"
    if [[ "$sy_ctl" -ge 1 && -L "$sy_lane/payload" ]]; then pass "S49 fixture: the contained hook really replaced payload/ with a symlink, and strace sees reads through it"
    else fail "S49 fixture/observer not qualified (control hits=$sy_ctl, symlink=$([[ -L "$sy_lane/payload" ]] && echo y || echo n)): $(cat "$TMP/sym.out")"; fi
    if [[ "$sy_hits" -eq 0 && "$sy_hash" -ge 1 && -d "$sy_lane" ]] && grep -Fq 'unsafe lane path payload/item' "$TMP/sym.out" \
       && grep -Eq 'dirty or unverified lane retained at .*wgm-sy-1' "$TMP/sym.out"; then
      pass "S49: no host open resolves outside the lane; the lane is retained and payload/item is named as unsafe"
    else
      fail "S49: cleanup read through a symlinked ancestor or lost the lane (rc=$RC outside-hits=$sy_hits hash-execs=$sy_hash): $(cat "$TMP/sym.out")"
    fi
    (cd "$SY" && jj workspace forget wgm-sy-1 >/dev/null 2>&1) || true
    git -C "$SY" worktree prune
  fi

  # V8 (rugged r10, S50a/S50b). Lanes can write the SHARED git dir. (a) A lane swaps the PARENT's index for a symlink to
  # a host-only canary: the parent guard must not read through it (strace -f -y, qualified by a positive control),
  # must not copy it into the shared git dir, and the run refuses. (b) A lane rewrites a clean-filter helper under
  # <common>/custom/: no host git call may run it (sentinel), while plain host git does (positive control).
  if ! command -v strace >/dev/null 2>&1; then
    echo "skip: no strace (parent index symlink / configured-command cases)"
  else
    SA="$TMP/idxrepo"; SACAN="$TMP/idx-canary"; SAAG="$TMP/agentbin6/bin"; mkdir -p "$SA" "$SAAG"
    git -C "$SA" init -q -b main
    git -C "$SA" config user.name fixture; git -C "$SA" config user.email fixture@example.invalid
    printf '/.wgm/\n' > "$SA/.gitignore"; printf '# plan\n' > "$SA/IMPLEMENTATION_PLAN.md"
    git -C "$SA" add -A && git -C "$SA" commit -qm seed
    (cd "$SA" && jj git init --colocate >/dev/null 2>&1)
    printf 'CANARY-S50A-HOST-ONLY\n' > "$SACAN"
    cat > "$SAAG/idx-agent" <<AG
#!/usr/bin/env bash
[[ "\${1:-}" != --version ]] || { echo "idx-agent 1"; exit 0; }
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
rm -f "$SA/.git/index" 2>/dev/null; ln -s "$SACAN" "$SA/.git/index" 2>/dev/null
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$SAAG/idx-agent"
    # variant: the same swap performed by the PREFLIGHT readiness command (shared git dir is writable there too)
    cat > "$SAAG/idx-agent-pf" <<AG
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then rm -f "$SA/.git/index" 2>/dev/null; ln -s "$SACAN" "$SA/.git/index" 2>/dev/null; echo "idx-agent-pf 1"; exit 0; fi
exit 0
AG
    chmod +x "$SAAG/idx-agent-pf"
    # positive control: plain host git through such an index symlink IS observed reading the canary
    cp "$SA/.git/index" "$TMP/idx.orig"; rm -f "$SA/.git/index"; ln -s "$SACAN" "$SA/.git/index"
    strace -f -y -qq -e trace=openat -o "$TMP/idx-ctl.log" git -C "$SA" status >/dev/null 2>&1 || true
    sa_ctl="$(strace_resolved_opens "$TMP/idx-ctl.log" "$SACAN")"
    rm -f "$SA/.git/index"; cp "$TMP/idx.orig" "$SA/.git/index"
    if [[ "$sa_ctl" -ge 1 ]]; then pass "S50a fixture: the observer sees plain git read the canary through an index symlink"
    else fail "S50a observer not qualified (control hits=$sa_ctl)"; fi
    set +e
    (cd "$SA" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" strace -f -y -qq -e trace=openat,open,openat2,execve -o "$TMP/idx-strace.log" \
      "$SWARM" -n 1 --prefix wgm/sa --max-iterations 1 -- "$SAAG/idx-agent" </dev/null > "$TMP/idx.out" 2>&1)
    RC=$?
    set -e
    sa_hits="$(strace_resolved_opens "$TMP/idx-strace.log" "$SACAN")"
    sa_leak="$(grep -rl 'CANARY-S50A' "$SA/.git" 2>/dev/null | grep -vc "^$SA/.git/index$" || true)"
    [[ -z "${S50_DEBUG:-}" ]] || { cp "$TMP/idx-strace.log" /tmp/s50-strace.log; cp "$TMP/idx.out" /tmp/s50.out; }
    if [[ "$sa_hits" -eq 0 && "$sa_leak" -eq 0 ]] && ! compgen -G "$SA/.git/wgm-parent-index.*" >/dev/null \
       && [[ "$RC" -ne 0 ]] && grep -Eq 'not a regular file|symlink or special file|trust lost .*/\.git/index' "$TMP/idx.out"; then
      pass "S50a: no host read resolves to the canary, nothing of it lands in the git dir, the guard refuses the symlinked index"
    else
      fail "S50a: the guard read through / copied a symlinked parent index (rc=$RC hits=$sa_hits leaked-files=$sa_leak): $(tail -n 12 "$TMP/idx.out")"
    fi
    rm -f "$SA/.git/index"; git -C "$SA" read-tree HEAD
    (cd "$SA" && jj workspace forget wgm-sa-1 >/dev/null 2>&1) || true
    git -C "$SA" worktree prune
    # preflight-time swap: the host must not run jj/git against the tampered index (no read of the canary), the
    # preflight workspace is retained with its recovery line, no lane starts
    set +e
    (cd "$SA" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/idx2-strace.log" \
      "$SWARM" -n 1 --prefix wgm/sa2 --max-iterations 1 -- "$SAAG/idx-agent-pf" </dev/null > "$TMP/idx2.out" 2>&1)
    RC=$?
    set -e
    sa2_hits="$(strace_resolved_opens "$TMP/idx2-strace.log" "$SACAN")"
    if [[ "$sa2_hits" -eq 0 && "$RC" -ne 0 && ! -e "$SA/.wgm/worktrees/wgm-sa2-1" ]] && grep -Eq 'not a regular file|symlink or special file' "$TMP/idx2.out" \
       && grep -Fq 'retained preflight workspace' "$TMP/idx2.out"; then
      pass "S50a (preflight): no host read resolves to the canary; the workspace is retained with its recovery line; no lane started"
    else
      fail "S50a (preflight): host touched the swapped index or continued (rc=$RC hits=$sa2_hits): $(tail -n 12 "$TMP/idx2.out")"
    fi
    pf2="$(grep -o 'retained preflight workspace [^ ]* at [^ ]*' "$TMP/idx2.out" | awk '{print $4, $6}' | head -1)"
    rm -f "$SA/.git/index"; git -C "$SA" read-tree HEAD
    if [[ -n "$pf2" ]]; then (cd "$SA" && jj workspace forget "${pf2%% *}" >/dev/null 2>&1); rm -rf "$(dirname "${pf2#* }")"; fi
    git -C "$SA" worktree prune

    # (b) a configured clean-filter helper under <common>/custom/, rewritten by the lane
    SBR="$TMP/filtrepo"; SBS="$TMP/filt-sent"; SBAG="$TMP/agentbin7/bin"; mkdir -p "$SBR" "$SBS" "$SBAG" "$SBR/.git/custom"
    git -C "$SBR" init -q -b main
    git -C "$SBR" config user.name fixture; git -C "$SBR" config user.email fixture@example.invalid
    printf '/.wgm/\n' > "$SBR/.gitignore"; printf '# plan\n' > "$SBR/IMPLEMENTATION_PLAN.md"
    printf '*.dat filter=wgm50b\n' > "$SBR/.gitattributes"; printf 'data\n' > "$SBR/a.dat"
    printf '#!/bin/sh\ntouch "%s/helper-fired"\ncat\n' "$SBS" > "$SBR/.git/custom/clean.sh"; chmod +x "$SBR/.git/custom/clean.sh"
    git -C "$SBR" config filter.wgm50b.clean "$SBR/.git/custom/clean.sh"
    git -C "$SBR" add -A && git -C "$SBR" commit -qm seed
    (cd "$SBR" && jj git init --colocate >/dev/null 2>&1)
    cat > "$SBAG/filt-agent" <<AG
#!/usr/bin/env bash
printf '#!/bin/sh\ntouch "$SBS/EVIL-helper"\ncat\n' > "$SBR/.git/custom/clean.sh" 2>/dev/null
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$SBAG/filt-agent"
    # positive control: plain host git fires the helper (and a rewritten one) when the stat is stale
    touch "$SBR/a.dat"; git -C "$SBR" status >/dev/null 2>&1
    if [[ -e "$SBS/helper-fired" ]]; then pass "S50b fixture: plain host git runs the configured clean-filter helper"; else fail "S50b fixture broken: helper did not fire"; fi
    rm -f "$SBS"/*; git -C "$SBR" status >/dev/null 2>&1; rm -f "$SBS"/*
    cp "$SBR/.git/custom/clean.sh" "$TMP/clean50b.orig"
    set +e
    (cd "$SBR" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 1 --prefix wgm/sb --max-iterations 1 -- "$SBAG/filt-agent" </dev/null > "$TMP/filt.out" 2>&1)
    RC=$?
    set -e
    if [[ ! -e "$SBS/helper-fired" && ! -e "$SBS/EVIL-helper" ]] && grep -Fq 'EVIL-helper' "$SBR/.git/custom/clean.sh"; then
      pass "S50b: the lane rewrote the configured helper under the shared git dir and no host git call ran it (rc=$RC)"
    else
      fail "S50b: a repository-configured filter command ran on the host (sentinels: $(find "$SBS" -mindepth 1 2>&1 | tr '\n' ' ') rewritten=$(grep -c EVIL-helper "$SBR/.git/custom/clean.sh")): $(tail -n 12 "$TMP/filt.out")"
    fi
    (cd "$SBR" && jj workspace forget wgm-sb-1 >/dev/null 2>&1) || true
    git -C "$SBR" worktree prune
  fi

  # V10 (rugged r11, S51): the operator's post-commit hook runs a tracked helper the AGENT changed; the CONTAINED
  # commit swaps the lane's own worktree-admin index for a symlink to a host-only canary. Swarm (cleanup included)
  # must never open it: zero resolved opens (strace -f -y), non-zero exit, lane retained, recovery line printed.
  if ! command -v strace >/dev/null 2>&1; then
    echo "skip: no strace (S51 lane admin index symlink)"
  else
    S51="$TMP/s51repo"; S51CAN="$TMP/s51-canary"; S51AG="$TMP/agentbin8/bin"
    mkdir -p "$S51/tools" "$S51AG"
    git -C "$S51" init -q -b main
    git -C "$S51" config user.name fixture; git -C "$S51" config user.email fixture@example.invalid
    printf '/.wgm/\n' > "$S51/.gitignore"; printf '# plan\n' > "$S51/IMPLEMENTATION_PLAN.md"
    printf '#!/bin/sh\nexit 0\n' > "$S51/tools/post.sh"
    git -C "$S51" add -A && git -C "$S51" commit -qm seed
    printf '#!/bin/sh\nsh tools/post.sh\n' > "$S51/.git/hooks/post-commit"; chmod +x "$S51/.git/hooks/post-commit"
    printf 'CANARY-S51-HOST-ONLY\n' > "$S51CAN"
    (cd "$S51" && jj git init --colocate >/dev/null 2>&1)
    cat > "$S51AG/s51-agent" <<AG
#!/usr/bin/env bash
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "\${1:-}" != --version ]] || { echo "s51-agent 1"; exit 0; }
printf '#!/bin/sh\nADM="\$(git rev-parse --git-dir)"\nrm -f "\$ADM/index"\nln -s "$S51CAN" "\$ADM/index"\nexit 0\n' > tools/post.sh
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md
printf "IMPLEMENTATION_PLAN.md\ntools/post.sh\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$S51AG/s51-agent"
    set +e
    (cd "$S51" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/s51-strace.log" \
      "$SWARM" --backend jj -n 1 --prefix wgm/s51 --max-iterations 1 --cleanup -- "$S51AG/s51-agent" </dev/null > "$TMP/s51.out" 2>&1)
    RC=$?
    set -e
    s51_hits="$(strace_resolved_opens "$TMP/s51-strace.log" "$S51CAN")"
    s51_lane="$S51/.wgm/worktrees/wgm-s51-1"
    # positive control: plain host git on the retained lane IS observed opening the canary through the admin index
    set +e
    strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/s51-ctl.log" git -C "$s51_lane" status >/dev/null 2>&1
    set -e
    s51_ctl="$(strace_resolved_opens "$TMP/s51-ctl.log" "$S51CAN")"
    if [[ "$s51_ctl" -ge 1 ]]; then pass "S51 fixture: the contained commit really swapped the lane admin index, and the observer sees plain git read the canary"
    else fail "S51 fixture/observer not qualified (control hits=$s51_ctl): $(tail -n 15 "$TMP/s51.out")"; fi
    if [[ "$s51_hits" -eq 0 && "$RC" -ne 0 && -d "$s51_lane" ]] && grep -Fq 'worktrees/wgm-s51-1/index' "$TMP/s51.out" \
       && grep -Eq "Recovery: remove the LINK itself|trust lost .*worktrees/wgm-s51-1/index" "$TMP/s51.out" && grep -Eq 'recover|recovery' "$TMP/s51.out"; then
      pass "S51: zero host opens of the canary, non-zero exit, lane retained, offending path and recovery printed"
    else
      fail "S51: swarm read through the lane's admin index or lost the lane (rc=$RC hits=$s51_hits): $(tail -n 15 "$TMP/s51.out")"
    fi
    (cd "$S51" && jj workspace forget wgm-s51-1 >/dev/null 2>&1) || true
    git -C "$S51" worktree prune
  fi

  # V11 (rugged r13, S52): a lane's agent redirects its worktree-admin `commondir` to a SECOND repository outside every
  # mount. The host must refuse BEFORE scanning/opening anything there: zero successful opens under that repository,
  # lane retained with a recovery line naming the pointer, non-zero exit.
  if ! command -v strace >/dev/null 2>&1; then
    echo "skip: no strace (S52 redirected commondir)"
  else
    S52="$TMP/s52repo"; S52O="$TMP/s52-other"; S52AG="$TMP/agentbin9/bin"
    mkdir -p "$S52" "$S52O" "$S52AG"
    git -C "$S52" init -q -b main
    git -C "$S52" config user.name fixture; git -C "$S52" config user.email fixture@example.invalid
    printf '/.wgm/\n' > "$S52/.gitignore"; printf '# plan\n' > "$S52/IMPLEMENTATION_PLAN.md"
    git -C "$S52" add -A && git -C "$S52" commit -qm seed
    git -C "$S52O" init -q -b main
    git -C "$S52O" config user.name other; git -C "$S52O" config user.email other@example.invalid
    printf 'OTHER-REPO-CANARY\n' > "$S52O/secret.txt"; git -C "$S52O" add -A && git -C "$S52O" commit -qm other
    (cd "$S52" && jj git init --colocate >/dev/null 2>&1)
    cat > "$S52AG/s52-agent" <<AG
#!/usr/bin/env bash
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "\${1:-}" != --version ]] || { echo "s52-agent 1"; exit 0; }
printf '%s\n' "$S52O/.git" > "\$(git rev-parse --git-dir)/commondir" 2>/dev/null
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$S52AG/s52-agent"
    set +e
    (cd "$S52" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/s52-strace.log" \
      "$SWARM" --backend jj -n 1 --prefix wgm/s52 --max-iterations 1 --cleanup -- "$S52AG/s52-agent" </dev/null > "$TMP/s52.out" 2>&1)
    RC=$?
    set -e
    s52_hits="$(strace_resolved_opens_under "$TMP/s52-strace.log" "$S52O")"
    s52_lane="$S52/.wgm/worktrees/wgm-s52-1"
    set +e
    strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/s52-ctl.log" git -C "$s52_lane" status >/dev/null 2>&1
    set -e
    s52_ctl="$(strace_resolved_opens_under "$TMP/s52-ctl.log" "$S52O")"
    if [[ "$s52_ctl" -ge 1 ]]; then pass "S52 fixture: the lane's commondir really points at the other repository, and the observer sees plain git open it"
    else fail "S52 fixture/observer not qualified (control hits=$s52_ctl): $(tail -n 15 "$TMP/s52.out")"; fi
    if [[ "$s52_hits" -eq 0 && "$RC" -ne 0 && -d "$s52_lane" ]] && grep -Eiq 'redirected|commondir|trust lost .*worktrees/wgm-s52-1' "$TMP/s52.out" \
       && grep -Eq "restore the lane's git pointers|restore the named path" "$TMP/s52.out"; then
      pass "S52: zero host opens under the other repository, lane retained, pointer recovery printed, non-zero exit"
    else
      fail "S52: swarm opened the redirected repository or lost the lane (rc=$RC hits=$s52_hits): $(tail -n 15 "$TMP/s52.out")"
    fi
    (cd "$S52" && jj workspace forget wgm-s52-1 >/dev/null 2>&1) || true
    git -C "$S52" worktree prune
  fi

  # V13 (S55): the lane's agent replaces <COMMON>/worktrees with a symlink to a HOST-side outside copy that holds the
  # lane's admin dir (regular commondir). Zero host opens under the copy, lane retained, recovery printed, non-zero
  # exit. With a real engine the read-only config.worktree overlays nested inside worktrees/ may make the in-container
  # `mv` fail (EBUSY): then the attack did not happen and the case is reported as a visible skip, not a pass.
  if ! command -v strace >/dev/null 2>&1; then
    echo "skip: no strace (S55 replaced <common>/worktrees)"
  else
    S55="$TMP/s55repo"; S55O="$TMP/s55-copy"; S55AG="$TMP/agentbin10/bin"
    mkdir -p "$S55" "$S55O" "$S55AG"
    git -C "$S55" init -q -b main
    git -C "$S55" config user.name fixture; git -C "$S55" config user.email fixture@example.invalid
    printf '/.wgm/\n' > "$S55/.gitignore"; printf '# plan\n' > "$S55/IMPLEMENTATION_PLAN.md"
    git -C "$S55" add -A && git -C "$S55" commit -qm seed
    (cd "$S55" && jj git init --colocate >/dev/null 2>&1)
    # the copy of worktrees/ on the host (what the link will point at): filled by the agent's mv/cp route below
    cat > "$S55AG/s55-agent" <<AG
#!/usr/bin/env bash
if [[ -n "\${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "\$WGM_CAPABILITY_PROBE_CONTENT" > "\$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "\${1:-}" != --version ]] || { echo "s55-agent 1"; exit 0; }
C="$S55/.git"
if mv "\$C/worktrees" "\$C/worktrees.moved" 2>/dev/null; then ln -s "$S55O" "\$C/worktrees" 2>/dev/null; cp -a "\$C/worktrees.moved/." "$S55O/" 2>/dev/null; fi
printf -- "- work\\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\\n" > "\$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$S55AG/s55-agent"
    set +e
    (cd "$S55" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/s55-strace.log" \
      "$SWARM" --backend jj -n 1 --prefix wgm/s55 --max-iterations 1 --cleanup -- "$S55AG/s55-agent" </dev/null > "$TMP/s55.out" 2>&1)
    RC=$?
    set -e
    s55_hits="$(strace_resolved_opens_under "$TMP/s55-strace.log" "$S55O")"
    if [[ ! -L "$S55/.git/worktrees" ]]; then
      echo "skip: S55 attack not possible with a real engine here (the in-container mv of <common>/worktrees was refused: nested read-only overlays); covered at the loop level by lane u's stub-engine test"
      [[ "$s55_hits" -eq 0 ]] || fail "S55: host opened files under the copy although no link was planted (hits=$s55_hits)"
    else
      # positive control: the contained agent cannot reach the host-side copy dir, so the copy is filled HERE from the
      # moved admin dirs; plain host git through the planted link must then be seen opening files under it
      cp -a "$S55/.git/worktrees.moved/." "$S55O/" 2>/dev/null || true
      set +e
      strace -f -y -qq -e trace=openat,open,openat2 -o "$TMP/s55-ctl.log" git -C "$S55/.wgm/worktrees/wgm-s55-1" status >/dev/null 2>&1
      set -e
      s55_ctl="$(strace_resolved_opens_under "$TMP/s55-ctl.log" "$S55O")"
      if [[ "$s55_ctl" -ge 1 ]]; then pass "S55 fixture: <common>/worktrees is a link to the outside copy and the observer sees plain git open it"
      else fail "S55 fixture/observer not qualified (control hits=$s55_ctl)"; fi
      if [[ "$s55_hits" -eq 0 && "$RC" -ne 0 && -d "$S55/.wgm/worktrees/wgm-s55-1" ]] && grep -Fq 'worktrees' "$TMP/s55.out" \
         && grep -Eiq 'recover|remove the LINK|restore' "$TMP/s55.out"; then
        pass "S55: zero host opens under the outside copy, lane retained, recovery printed, non-zero exit"
      else
        fail "S55: swarm read through the replaced worktrees dir or lost the lane (rc=$RC hits=$s55_hits): $(tail -n 15 "$TMP/s55.out")"
      fi
      rm -f "$S55/.git/worktrees"; [[ ! -d "$S55/.git/worktrees.moved" ]] || mv "$S55/.git/worktrees.moved" "$S55/.git/worktrees"
    fi
    (cd "$S55" && jj workspace forget wgm-s55-1 >/dev/null 2>&1) || true
    git -C "$S55" worktree prune
  fi

  # V15/B2: swarm's private artifacts (decision file, containment files, preflight workspace, temp dir) must lie
  # outside EVERY mount — an approved read-only extra mount that contains TMPDIR must receive nothing. The TMPDIR dir
  # inside it is made read-only, so any attempt to create something there fails the run loudly.
  B2X="$TMP/b2-extra"; mkdir -p "$B2X/tmp"; printf 'shared reference data\n' > "$B2X/data.txt"; chmod 555 "$B2X/tmp"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" TMPDIR="$B2X/tmp" "$SWARM" -n 1 --prefix wgm/b2 --max-iterations 1 --devcontainer-mount "$B2X" -- "$TMP/agentbin3/bin/ok-agent" </dev/null 2>&1)"; RC=$?
  set -e
  b2_left="$(find "$B2X/tmp" -mindepth 1 2>/dev/null | wc -l)"
  if [[ "$RC" -eq 0 && "$b2_left" -eq 0 ]] && grep -Fq 'sandbox: on' <<<"$OUT" && [[ "$(git -C "$PROJECT" rev-list --count "$BASE..wgm/b2/1")" -ge 1 ]]; then
    pass "B2: with TMPDIR inside an approved read-only extra mount, swarm creates nothing there and still runs sandboxed"
  else
    fail "B2: private swarm artifacts went into (or were blocked by) the extra mount (rc=$RC left=$b2_left): $(tail -n 12 <<<"$OUT")"
  fi
  chmod 755 "$B2X/tmp"; git -C "$PROJECT" worktree prune; reset_fixture

  # V16/B1+C7 (swarm side): (1) an APPROVED env credential holding a synthetic value reaches EACH lane's container
  # (digest), an unapproved one does not; (2) no external tool runs before the in-process allowlist (strace -f -v
  # execve trace: a non-allowlisted probe variable appears in no exec after swarm's own start); (3) a SUPPLIED
  # decision inside an approved extra mount is refused.
  if ! command -v strace >/dev/null 2>&1; then
    echo "skip: no strace (swarm environment allowlist trace)"
  else
    V16AG="$TMP/agentbin12/bin"; mkdir -p "$V16AG"
    cat > "$V16AG/claude" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "${1:-}" != --version ]] || { echo "claude 1"; exit 0; }
mkdir -p .wgm
printf 'A=%s O=%s\n' "$(printf %s "${ANTHROPIC_API_KEY-}" | sha256sum | cut -c1-16)" "$([[ -n "${OPENAI_API_KEY+x}" ]] && echo SET || echo unset)" > .wgm/envdigest.txt
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$V16AG/claude"
    # headless approval record for this repository: agent claude, env ANTHROPIC_API_KEY only
    v16_key="$(printf '%s' "$(readlink -f "$PROJECT/.git")" | sha256sum | cut -c1-16)"
    v16_dir="$XDG_CONFIG_HOME/wgm/sandbox"; mkdir -p "$v16_dir"; chmod 700 "$XDG_CONFIG_HOME/wgm" "$v16_dir"
    printf '# wgm sandbox decisions\nengine_declined: false\ndeclined_at:\nagents: claude\nimage:\ntokens:\ncopies:\nmounts:\nenv:\n  - ANTHROPIC_API_KEY\n' > "$v16_dir/$v16_key.yml"; chmod 600 "$v16_dir/$v16_key.yml"
    v16_secret="s3cret-anthropic-$$"; v16_expect="$(printf %s "$v16_secret" | sha256sum | cut -c1-16)"
    # positive control for the execve observer: the probe variable IS visible in an exec's environment
    UNALLOWED_PROBE=probe-value-$$ strace -f -v -s 8192 -qq -e trace=execve -o "$TMP/v16-ctl.log" true >/dev/null 2>&1 || true
    v16_ctl="$(grep -c "UNALLOWED_PROBE=probe-value-$$" "$TMP/v16-ctl.log" 2>/dev/null || true)"
    if [[ "$v16_ctl" -ge 1 ]]; then pass "V16 fixture: the execve observer shows a probe variable in an exec's environment"; else fail "V16 observer not qualified (hits=$v16_ctl)"; fi
    set +e
    (cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" ANTHROPIC_API_KEY="$v16_secret" OPENAI_API_KEY="unapproved-$$" UNALLOWED_PROBE="probe-value-$$" \
      strace -f -v -s 8192 -qq -e trace=execve -o "$TMP/v16-strace.log" \
      "$SWARM" -n 2 --prefix wgm/v16 --max-iterations 1 -- "$V16AG/claude" </dev/null > "$TMP/v16.out" 2>&1)
    RC=$?
    set -e
    v16_ok=0
    for n in 1 2; do
      d="$(cat "$PROJECT/.wgm/worktrees/wgm-v16-$n/.wgm/envdigest.txt" 2>/dev/null || true)"
      [[ "$d" == "A=$v16_expect O=unset" ]] && v16_ok=$((v16_ok + 1))
    done
    # exec lines AFTER swarm's own bash starts (the first `bash …/swarm.sh` exec; the env/shebang chain before it
    # legitimately carries the polluted environment; only SUCCESSFUL execs count — env's PATH search tries many
    # nonexistent `<dir>/bash` first): none may carry the probe or the
    # unapproved credential in its environment; the approved one may (it reaches the engine by name)
    v16_late_probe="$(awk '/ = 0$/ && /execve\("[^"]*\/bash", \["bash", "[^"]*swarm\.sh"/ && !found { found = 1; next } found && / = 0$/ { print }' "$TMP/v16-strace.log" | grep -c "UNALLOWED_PROBE=" || true)"
    # credential-TABLE names are candidates until the decision exists (lane u's two-phase allowlist), so the early
    # bootstrap execs may carry them; what must hold: no CONTAINER LAUNCH exec ever carries the unapproved one, and
    # the approved one is there (it reaches the engine by inherited name)
    v16_run_all="$(grep ' = 0$' "$TMP/v16-strace.log" | grep -c 'execve("[^"]*/\(podman\|docker\)", \["[^"]*", "run"' || true)"
    v16_run_bad="$(grep ' = 0$' "$TMP/v16-strace.log" | grep 'execve("[^"]*/\(podman\|docker\)", \["[^"]*", "run"' | grep -c 'OPENAI_API_KEY=unapproved' || true)"
    v16_run_good="$(grep ' = 0$' "$TMP/v16-strace.log" | grep 'execve("[^"]*/\(podman\|docker\)", \["[^"]*", "run"' | grep -c "ANTHROPIC_API_KEY=$v16_secret" || true)"
    if [[ "$RC" -eq 0 && "$v16_ok" -eq 2 && "$v16_late_probe" -eq 0 && "$v16_run_all" -ge 2 && "$v16_run_bad" -eq 0 && "$v16_run_good" -ge 1 ]]; then
      pass "V16: the approved credential reaches both lanes' containers (digest), the unapproved one does not, and no exec after swarm's start sees a non-allowlisted variable"
    else
      fail "V16 violated (rc=$RC lanes-with-correct-digest=$v16_ok late-probe-execs=$v16_late_probe launches=$v16_run_all unapproved-in-launch=$v16_run_bad approved-in-launch=$v16_run_good): $(tail -n 12 "$TMP/v16.out")"
    fi
    rm -f "$v16_dir/$v16_key.yml"; git -C "$PROJECT" worktree prune; reset_fixture
    # (3) a supplied decision inside an approved read-only extra mount is refused (exit 2), nothing runs
    V16X="$TMP/v16-extra"; mkdir -p "$V16X/dec"; chmod 700 "$V16X/dec"
    printf 'sandbox=on\nengine=%s\nreason=engine-found\nimage=localhost/wgm-devcontainer-base:latest\nrecord=\n' "$BOX_ENGINE" > "$V16X/dec/decision"; chmod 600 "$V16X/dec/decision"
    set +e
    OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" WGM_SANDBOX_DECISION="$V16X/dec/decision" "$SWARM" -n 1 --prefix wgm/v16b --devcontainer-mount "$V16X" -- "$V16AG/claude" </dev/null 2>&1)"; RC=$?
    set -e
    if [[ "$RC" -eq 2 ]] && grep -Fq 'lies inside the mount' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/worktrees" ]]; then
      pass "B2: a supplied decision inside an approved extra mount is refused (exit 2) before any lane"
    else
      fail "B2: supplied decision inside an approved mount was not refused (rc=$RC): $OUT"
    fi
    reset_fixture
  fi

  # V23/T10: ONE sandboxed 2-lane swarm audit of host git. A git PATH shim (outside every mount) records, for EVERY host
  # git call — swarm itself, its lane loops, the parent guard, jj's children — the cwd, the full argv (unit-separator
  # joined, so paths with spaces survive) and the protection environment (config pairs, GIT_ALLOW_PROTOCOL,
  # GIT_NO_LAZY_FETCH). Asserted: every call carries the protections (argv `-c` or GIT_CONFIG_* env, the empty-but-SET
  # GIT_ALLOW_PROTOCOL, GIT_NO_LAZY_FETCH=1); and PORCELAIN (status, diff, add, commit, checkout, …) appears ONLY with the
  # PARENT checkout as target (cwd / -C / --git-dir) — never on an agent-written lane tree (C2/C4 parent exception).
  AU="$TMP/t10"; AUP="$TMP/t10-parent"; mkdir -p "$AU/shim" "$AUP" "$TMP/agentbin13/bin"
  git -C "$AUP" init -q -b main
  git -C "$AUP" config user.name fixture; git -C "$AUP" config user.email fixture@example.invalid
  printf '/.wgm/\n' > "$AUP/.gitignore"; printf '# plan\n' > "$AUP/IMPLEMENTATION_PLAN.md"
  git -C "$AUP" add -A && git -C "$AUP" commit -qm seed
  (cd "$AUP" && jj git init --colocate >/dev/null 2>&1)
  cat > "$TMP/agentbin13/bin/audit-agent" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "${1:-}" != --version ]] || { echo "audit-agent 1"; exit 0; }
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$TMP/agentbin13/bin/audit-agent"
  cat > "$AU/shim/git" <<SH
#!/usr/bin/env bash
us=\$'\\x1f'; argv=""; for a in "\$@"; do argv+="\$a\$us"; done
cfg=""; n="\${GIT_CONFIG_COUNT:-0}"; i=0
while [[ "\$i" -lt "\$n" ]]; do k="GIT_CONFIG_KEY_\$i"; v="GIT_CONFIG_VALUE_\$i"; cfg+="\${!k}=\${!v} "; i=\$((i + 1)); done
printf '%s\\x1e%s\\x1e%s\\x1e%s\\x1e%s\\x1e%s\\n' "\$PWD" "\$cfg" "\${GIT_ALLOW_PROTOCOL+set}:\${GIT_ALLOW_PROTOCOL}" "\${GIT_NO_LAZY_FETCH-unset}" "\${WGM_SWARM_LANE:-0}" "\$argv" >> "$AU/git-calls.tsv"
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$AU/shim/git"; : > "$AU/git-calls.tsv"
  set +e
  OUT="$(cd "$AUP" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$AU/shim:$PATH" "$SWARM" -n 2 --prefix wgm/t10 --max-iterations 1 -- "$TMP/agentbin13/bin/audit-agent" </dev/null 2>&1)"; RC=$?
  set -e
  t10_classify() {  # t10_classify TSV PARENT_PHYS → sets au_total au_prot_bad au_porc_bad au_parent_porc au_lane_seen
    local au_parent="$2" au_cwd au_cfg au_allow au_lazy au_argv av a j sub tgt tgt_c need au_blob porcelain_re
    au_total=0; au_prot_bad=""; au_porc_bad=""; au_parent_porc=0; au_lane_seen=0
    porcelain_re='^(status|diff|switch|branch|checkout|add|commit|merge|rebase|stash|reset|restore|clean|log|pull|fetch|push|cherry-pick|revert|tag|am|apply)$'
    while IFS=$'\x1e' read -r au_cwd au_cfg au_allow au_lazy _ au_argv; do
      [[ -n "$au_argv" ]] || continue
      au_total=$((au_total + 1))
      IFS=$'\x1f' read -r -a av <<<"$au_argv"
      [[ "${av[0]:-}" == worktree && "${av[1]:-}" == add && "${av[2]:-}" == -h ]] && continue   # the capability help probe reads no repository
      # protections: argv -c pairs or the GIT_CONFIG_* environment, plus the empty-but-set allowlist and no lazy fetch
      au_blob="${au_argv//$'\x1f'/ } $au_cfg"
      for need in core.fsmonitor=false core.hooksPath=/dev/null protocol.allow=never; do
        [[ "$au_blob" == *"$need"* ]] || au_prot_bad+="[missing $need: ${au_argv//$'\x1f'/ }] "
      done
      [[ "$au_allow" == "set:" && "$au_lazy" == 1 ]] || au_prot_bad+="[allow=$au_allow lazy=$au_lazy: ${au_argv//$'\x1f'/ }] "
      # target dir: the last -C / --git-dir before the subcommand, else the cwd; subcommand = first non-option word
      tgt="$au_cwd"; j=0; sub=""
      while [[ "$j" -lt "${#av[@]}" ]]; do
        a="${av[$j]}"
        case "$a" in
          -c) j=$((j + 2)); continue ;;
          -C) tgt="${av[$((j + 1))]:-$tgt}"; [[ "$tgt" == /* ]] || tgt="$au_cwd/$tgt"; j=$((j + 2)); continue ;;
          --git-dir) tgt="$(dirname "${av[$((j + 1))]:-$tgt}")"; j=$((j + 2)); continue ;;
          --git-dir=*) tgt="$(dirname "${a#--git-dir=}")"; j=$((j + 1)); continue ;;
          -*) j=$((j + 1)); continue ;;
          *) sub="$a"; break ;;
        esac
      done
      tgt_c="$(cd "$tgt" 2>/dev/null && pwd -P || printf '%s' "$tgt")"
      case "$tgt_c" in "$au_parent"/.wgm/worktrees/*) au_lane_seen=$((au_lane_seen + 1)) ;; esac
      if [[ "$sub" =~ $porcelain_re || ( "$sub" == ls-files && " ${av[*]} " == *" -m "* ) ]]; then
        if [[ "$tgt_c" == "$au_parent" ]]; then au_parent_porc=$((au_parent_porc + 1))
        else au_porc_bad+="[porcelain '$sub' on $tgt_c] "; fi
      fi
    done < "$1"
  }
  au_parent="$(cd "$AUP" && pwd -P)"
  t10_classify "$AU/git-calls.tsv" "$au_parent"
  if [[ "$RC" -eq 0 && "$au_total" -gt 50 && -z "$au_prot_bad" && -z "$au_porc_bad" && "$au_parent_porc" -ge 1 && "$au_lane_seen" -ge 1 ]]; then
    pass "T10: all $au_total host git calls of a sandboxed 2-lane swarm carry the protections; porcelain only on the parent ($au_parent_porc calls), never on a lane tree ($au_lane_seen lane-tree calls seen)"
  else
    fail "T10 audit failed (rc=$RC calls=$au_total parent-porcelain=$au_parent_porc lane-calls=$au_lane_seen): protections: ${au_prot_bad:0:600} porcelain: ${au_porc_bad:0:600} | $(tail -n 6 <<<"$OUT")"
  fi
  # negative control for the classifier itself: a lane-tree `status` WITHOUT protections and a parent `status` WITH them
  # must be told apart (the audit above would otherwise pass vacuously)
  us=$'\x1f'; rs=$'\x1e'
  printf '%s\n' "$au_parent${rs}core.fsmonitor=false core.hooksPath=/dev/null protocol.allow=never ${rs}set:${rs}1${rs}0${rs}status${us}--porcelain${us}" \
                "$au_parent/.wgm/worktrees/x${rs}${rs}unset:${rs}unset${rs}1${rs}status${us}" > "$AU/synthetic.tsv"
  t10_classify "$AU/synthetic.tsv" "$au_parent"
  if [[ "$au_total" -eq 2 && "$au_parent_porc" -eq 1 && "$au_porc_bad" == *"porcelain 'status' on $au_parent/.wgm/worktrees/x"* && "$au_prot_bad" == *"missing core.fsmonitor=false"* ]]; then
    pass "T10: the audit classifier flags a protection-less lane-tree porcelain call and accepts a protected parent one"
  else
    fail "T10: classifier negative control failed (total=$au_total parent-porc=$au_parent_porc porc-bad=[$au_porc_bad] prot-bad=[${au_prot_bad:0:200}])"
  fi
  git -C "$AUP" worktree prune

  # V30: telemetry's "n/m lanes ran the agent in a container" counts ONLY ledger rows written during THIS run. Ledger paths
  # are reused per prefix/lane number and loop.sh appends: a PREVIOUS run's `container:podman` row for lane 1 must not count
  # a lane that refuses during setup this run (an engine shim fails its container launch, so its capability probe never
  # runs the agent and no row is written); lane 2 runs normally and still counts.
  mkdir -p "$TMP/agentbin14/bin" "$TMP/v30/shim" "$PROJECT/.wgm/metrics"
  [[ -x "$TMP/agentbin14/bin/v27-agent" ]] || { cat > "$TMP/agentbin14/bin/v27-agent" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "${1:-}" != --version ]] || { echo "v27-agent 1"; exit 0; }
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
    chmod +x "$TMP/agentbin14/bin/v27-agent"; }
  printf 'start_timestamp\tend_timestamp\titer\tmode\tagent\tduration_s\tplan_changed\tresult\tcost\tparent\tsandbox\n2020-01-01T00:00:00Z\t2020-01-01T00:00:09Z\t1\tbuild\told\t9\ty\tok\t0\tprevious-run\tcontainer:podman\n' > "$PROJECT/.wgm/metrics/wgm-v30-1.tsv"
  cat > "$TMP/v30/shim/$BOX_ENGINE" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == run && "\$*" == *"/.wgm/worktrees/wgm-v30-1"* ]]; then echo "Error: simulated launch failure for lane 1" >&2; exit 125; fi
exec "$(command -v "$BOX_ENGINE")" "\$@"
SH
  chmod +x "$TMP/v30/shim/$BOX_ENGINE"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$TMP/v30/shim:$PATH" "$SWARM" -n 2 --prefix wgm/v30 --max-iterations 1 -- "$TMP/agentbin14/bin/v27-agent" </dev/null 2>&1)"; RC=$?
  set -e
  lane1_rows_now="$(wc -l < "$PROJECT/.wgm/metrics/wgm-v30-1.tsv")"
  if grep -Fq 'sandbox: on (' <<<"$OUT" && grep -Fq '1/2 lanes ran the agent in a container' <<<"$OUT" && [[ "$lane1_rows_now" -eq 2 ]]; then
    pass "V30: a lane that refused during setup is not counted from a previous run's container row (1/2); the normal lane still counts"
  else
    fail "V30 telemetry counted a stale row or miscounted (rc=$RC lane-1 ledger lines=$lane1_rows_now): $(grep -v dropped <<<"$OUT" | tail -n 14) $(tail -n 6 "$PROJECT"/.wgm/swarm-logs/wgm-v30-2.log 2>&1)"
  fi
  git -C "$PROJECT" worktree prune; reset_fixture

  # V27 (U49): per-call pin verification stays ON through inspection, consolidation and cleanup. (a) A change to the shared
  # config made AFTER the post-run verification and BEFORE consolidation: the git shim runs the first post-run `rev-list`
  # normally, then edits the store host-side; the NEXT swarm host git call must be refused before git runs (ZERO further
  # swarm-level shim calls), swarm exits 2 with `trust lost`, nothing is consolidated, the lanes are retained. Run for
  # lanes INSIDE the parent and for an EXTERNAL `--worktree-dir` (lanes in the same git store but outside the parent and its
  # git dir). (b) A normal `--cleanup` run (both placements) still succeeds: the pins are re-captured after each lane removal.
  mkdir -p "$TMP/agentbin14/bin"
  cat > "$TMP/agentbin14/bin/v27-agent" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "${1:-}" != --version ]] || { echo "v27-agent 1"; exit 0; }
mkdir -p .wgm; printf 'lesson\n' > .wgm/memories.md
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$TMP/agentbin14/bin/v27-agent"
  V27DIR="$TMP/v27"
  for v27 in internal external; do
    rm -rf "$V27DIR"; mkdir -p "$V27DIR/shim" "$V27DIR/state"
    v27_wt=(); [[ "$v27" == external ]] && { mkdir -p "$TMP/v27-extlanes"; v27_wt=(--worktree-dir "$TMP/v27-extlanes"); }
    V27CFG="$PROJECT/.git/config"; cp "$V27CFG" "$V27DIR/config.orig"
    cat > "$V27DIR/shim/git" <<SH
#!/usr/bin/env bash
st="$V27DIR/state"
printf '%s lane=%s pin=%s %s\n' "\$(date +%s.%N)" "\${WGM_SWARM_LANE:-0}" "\${WGM_PIN_FILE:+set}" "\$*" >> "\$st/log"
if [[ -n "\${WGM_PIN_FILE:-}" && "\${WGM_SWARM_LANE:-0}" == 0 && ! -e "\$st/t-edit" && " \$* " == *" rev-list "* ]]; then
  "$REAL_GIT" "\$@"; rc=\$?
  date +%s.%N > "\$st/t-edit"; printf '[wgm-selftest]\n\tchanged = after-post-run-verification\n' >> "$V27CFG"
  exit \$rc
fi
exec "$REAL_GIT" "\$@"
SH
    chmod +x "$V27DIR/shim/git"
    set +e
    OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$V27DIR/shim:$PATH" "$SWARM" -n 2 --prefix wgm/v27 --max-iterations 1 --cleanup "${v27_wt[@]}" -- "$TMP/agentbin14/bin/v27-agent" </dev/null 2>&1)"; RC=$?
    set -e
    v27_t="$(cat "$V27DIR/state/t-edit" 2>/dev/null || true)"
    v27_after=-1
    [[ -z "$v27_t" ]] || v27_after="$(awk -v t="$v27_t" '$1 > t && $2 == "lane=0" { n++ } END { print n + 0 }' "$V27DIR/state/log" 2>/dev/null)"
    if [[ -n "$v27_t" && "$RC" -eq 2 && "$v27_after" -eq 0 ]] && grep -Fq 'trust lost' <<<"$OUT" && grep -Fq 'retained lane 1 at' <<<"$OUT" \
       && [[ ! -e "$PROJECT/.wgm/memories.md" ]] && ! grep -Fq 'consolidated' <<<"$OUT"; then
      pass "V27 ($v27 lanes): a store change after the post-run verification is refused at the NEXT swarm git call (zero further git), exit 2, nothing consolidated, lanes retained"
    else
      fail "V27 ($v27 lanes) violated (rc=$RC edited=[$v27_t] swarm-calls-after=$v27_after): $(grep -v dropped <<<"$OUT" | tail -n 14)"
    fi
    cp "$V27DIR/config.orig" "$V27CFG"; git -C "$PROJECT" worktree prune; reset_fixture; rm -rf "$TMP/v27-extlanes"
    # (b) a normal --cleanup run, same placement: succeeds, lanes removed, branches kept
    v27b_wt=(); [[ "$v27" == external ]] && { mkdir -p "$TMP/v27-extlanes"; v27b_wt=(--worktree-dir "$TMP/v27-extlanes"); }
    set +e
    OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 2 --prefix wgm/v27n --max-iterations 1 --cleanup "${v27b_wt[@]}" -- "$TMP/agentbin14/bin/v27-agent" </dev/null 2>&1)"; RC=$?
    set -e
    if [[ "$RC" -eq 0 ]] && grep -Fq 'sandbox: on' <<<"$OUT" && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/v27n/1 \
       && git -C "$PROJECT" show-ref --verify --quiet refs/heads/wgm/v27n/2 && ! grep -Fq 'trust lost' <<<"$OUT" \
       && [[ -z "$(find "$PROJECT/.wgm/worktrees" "$TMP/v27-extlanes" -mindepth 1 -maxdepth 1 -name 'wgm-v27n-*' 2>/dev/null)" ]]; then
      pass "V27 ($v27 lanes): a normal sandboxed --cleanup run succeeds — lanes removed, branches kept, pins re-captured after each removal"
    else
      fail "V27 ($v27 lanes) normal --cleanup run failed (rc=$RC): $(grep -v dropped <<<"$OUT" | tail -n 14)"
    fi
    git -C "$PROJECT" worktree prune; reset_fixture; rm -rf "$TMP/v27-extlanes"
  done

  # V25 (U48 caller path): swarm captures its pins in a SUBSHELL, so only WGM_PIN_FILE makes its OWN host git calls verify
  # them. The shared store's config / hook content changes host-side BETWEEN two swarm host git calls (no contained command
  # in between): the git shim runs the first post-capture `status` normally, then changes the store; the NEXT swarm host
  # git call must be refused (exit 2, `trust lost`) before git runs — the shim records ZERO further swarm calls — and the
  # run ends with exit 2, no lane started, every prepared lane retained with its recovery line.
  V25DIR="$TMP/v25"; mkdir -p "$TMP/agentbin11/bin"
  [[ -x "$TMP/agentbin11/bin/mem-agent" ]] || { printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/agentbin11/bin/mem-agent"; chmod +x "$TMP/agentbin11/bin/mem-agent"; }
  for v25 in config hooks; do
    rm -rf "$V25DIR"; mkdir -p "$V25DIR/shim" "$V25DIR/state"
    V25CFG="$PROJECT/.git/config"; cp "$V25CFG" "$V25DIR/config.orig"
    if [[ "$v25" == config ]]; then v25_edit="printf '[wgm-selftest]\\n\\tchanged = between-two-swarm-git-calls\\n' >> '$V25CFG'"
    else v25_edit="printf '#!/bin/sh\\nexit 0\\n' > '$PROJECT/.git/hooks/v25-between-calls'"; fi
    cat > "$V25DIR/shim/git" <<SH
#!/usr/bin/env bash
st="$V25DIR/state"
printf '%s lane=%s pin=%s %s\n' "\$(date +%s.%N)" "\${WGM_SWARM_LANE:-0}" "\${WGM_PIN_FILE:+set}" "\$*" >> "\$st/log"
if [[ -n "\${WGM_PIN_FILE:-}" && "\${WGM_SWARM_LANE:-0}" == 0 && ! -e "\$st/t-edit" && " \$* " == *" status "* ]]; then
  "$REAL_GIT" "\$@"; rc=\$?
  date +%s.%N > "\$st/t-edit"; $v25_edit
  exit \$rc
fi
exec "$REAL_GIT" "\$@"
SH
    chmod +x "$V25DIR/shim/git"
    set +e
    OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$V25DIR/shim:$PATH" "$SWARM" -n 2 --prefix wgm/v25 --max-iterations 1 -- "$TMP/agentbin11/bin/mem-agent" </dev/null 2>&1)"; RC=$?
    set -e
    v25_t="$(cat "$V25DIR/state/t-edit" 2>/dev/null || true)"
    v25_after=-1
    [[ -z "$v25_t" ]] || v25_after="$(awk -v t="$v25_t" '$1 > t && $2 == "lane=0" { n++ } END { print n + 0 }' "$V25DIR/state/log" 2>/dev/null)"
    if [[ -n "$v25_t" && "$RC" -eq 2 && "$v25_after" -eq 0 ]] && grep -Fq 'trust lost' <<<"$OUT" && grep -Fq 'retained lane 1 at' <<<"$OUT" \
       && grep -Fq 'recovery:' <<<"$OUT" && [[ ! -e "$PROJECT/.wgm/memories.md" ]] && ! grep -Fq '↗ stream' <<<"$OUT"; then
      pass "V25 ($v25): a change between two swarm host git calls is refused at the NEXT call (zero further git), exit 2, trust lost, no lane started, lanes retained"
    else
      fail "V25 ($v25) violated (rc=$RC edited=[$v25_t] swarm-calls-after=$v25_after): $(grep -v dropped <<<"$OUT" | tail -n 14)"
    fi
    cp "$V25DIR/config.orig" "$V25CFG"; rm -f "$PROJECT/.git/hooks/v25-between-calls"
    git -C "$PROJECT" worktree prune; reset_fixture
  done

  # V24 (U46 contract): SIGTERM to swarm during a slow readiness in the preflight container, with an engine whose `rm`
  # HANGS and whose `ps` FAILS (nothing can be confirmed gone). Swarm must exit bounded, and EVERY container name that was
  # launched must be printed as `retained container <name>` (never silently lost). Variant 2 forces swarm to KILL the
  # preflight child before its own handler finishes (WGM_CHILD_GRACE=1): swarm itself must then reap the shared
  # registry and print the handles. The shim launches the REAL podman; only the exact names it logged are removed after.
  AGBIN4="${AGBIN4:-$TMP/agentbin4/bin}"; mkdir -p "$AGBIN4"
  # shellcheck disable=SC2016  # the stub's own source text
  [[ -x "$AGBIN4/slow-agent" ]] || { printf '#!/usr/bin/env bash\nif [[ "${1:-}" == --version ]]; then touch "$PWD/.slow-started"; sleep 60; exit 0; fi\nexit 0\n' > "$AGBIN4/slow-agent"; chmod +x "$AGBIN4/slow-agent"; }
  REAL_ENG24="$(command -v "$BOX_ENGINE")"
  for v24 in default-grace forced-kill; do
    D24="$TMP/v24-$v24"; rm -rf "$D24"; mkdir -p "$D24/shim"
    cat > "$D24/shim/$BOX_ENGINE" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  run) name=""; prev=""; for a in "\$@"; do [[ "\$prev" == --name ]] && name="\$a"; prev="\$a"; done
       printf '%s\n' "\$name" >> "$D24/names" ;;
  rm) sleep 600; exit 0 ;;
  ps) exit 1 ;;
esac
exec "$REAL_ENG24" "\$@"
SH
    chmod +x "$D24/shim/$BOX_ENGINE"
    grace_env=(); [[ "$v24" == forced-kill ]] && grace_env=(WGM_CHILD_GRACE=1)
    (cd "$PROJECT" && exec env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$D24/shim:$PATH" "${grace_env[@]}" "$SWARM" -n 1 --prefix wgm/v24 -- "$AGBIN4/slow-agent" </dev/null) > "$D24/out" 2>&1 &
    RUNPID=$!
    v24_seen=0; if wait_glob "$TMPDIR/wgm-swarm-pf.*/ws/.slow-started"; then v24_seen=1; fi
    t0=$SECONDS
    [[ "$v24_seen" -eq 1 ]] && kill -TERM "$RUNPID"
    set +e; wait "$RUNPID"; RC=$?; set -e; RUNPID=""
    v24_secs=$((SECONDS - t0))
    v24_missing=""; v24_n=0
    while IFS= read -r nm; do
      [[ -n "$nm" ]] || continue
      v24_n=$((v24_n + 1))
      grep -Fq "retained container $nm" "$D24/out" || v24_missing+="$nm "
    done < <(sort -u "$D24/names" 2>/dev/null)
    # cleanup of OUR containers only, by the exact names the shim logged, with the real engine
    while IFS= read -r nm; do [[ -n "$nm" ]] && XDG_DATA_HOME="$REAL_DATA_HOME" "$REAL_ENG24" rm -f -t 0 "$nm" >/dev/null 2>&1; done < <(sort -u "$D24/names" 2>/dev/null)
    if [[ "$v24_seen" -eq 1 && "$RC" -eq 143 && "$v24_secs" -lt 75 && "$v24_n" -ge 1 && -z "$v24_missing" ]]; then
      pass "V24 ($v24): SIGTERM with a hanging rm and failing ps: exit 143 in ${v24_secs}s, all $v24_n launched container(s) printed as retained"
    else
      fail "V24 ($v24) violated (seen=$v24_seen rc=$RC secs=$v24_secs launched=$v24_n unprinted=[$v24_missing]): $(tail -n 12 "$D24/out")"
    fi
    # a retained (containment-lost) preflight workspace and its private dirs belong to THIS run's TMPDIR: remove them
    # so the next variant's readiness wait cannot see this one's marker
    v24_ws="$(cd "$PROJECT" && "$REAL_JJ" --ignore-working-copy workspace list -T 'name ++ "\n"' 2>/dev/null)"
    while IFS= read -r pw; do [[ "$pw" == wgm-preflight-* ]] && (cd "$PROJECT" && "$REAL_JJ" workspace forget "$pw" >/dev/null 2>&1); done <<<"$v24_ws"
    rm -rf "$TMPDIR"/wgm-swarm-pf.* "$TMPDIR"/wgm-loop.* "$TMPDIR"/wgm-swarm-ctl.* 2>/dev/null
    git -C "$PROJECT" worktree prune; reset_fixture
  done

  # V14 (rugged r18, S57/S57b): CONTAINMENT LOSS IS TERMINAL FOR THE WHOLE SWARM. An engine shim makes one launch fail
  # with a client error whose container then cannot be confirmed gone (rm fails, ps still lists it). Timestamped
  # git/jj shims record which calls come from the swarm itself (no WGM_SWARM_LANE) and when.
  C14="$TMP/c14"; mkdir -p "$C14" "$TMP/agentbin11/bin"
  REAL_ENG14="$(command -v "$BOX_ENGINE")"
  cat > "$TMP/agentbin11/bin/mem-agent" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "${1:-}" != --version ]] || { echo "mem-agent 1"; exit 0; }
mkdir -p .wgm; printf 'lesson from lane\n' > .wgm/memories.md
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$TMP/agentbin11/bin/mem-agent"
  make_c14_shims() {  # make_c14_shims FAILMATCH
    rm -rf "$C14/shim" "$C14/state"; mkdir -p "$C14/shim" "$C14/state"
    cat > "$C14/shim/$BOX_ENGINE" <<SH
#!/usr/bin/env bash
st="$C14/state"
case "\${1:-}" in
  run)
    if [[ "\$*" == *"$1"* ]]; then
      name=""; prev=""; for a in "\$@"; do [[ "\$prev" == --name ]] && name="\$a"; prev="\$a"; done
      printf '%s\n' "\$name" >> "\$st/lost-names"
      echo "Error: simulated client error: could not start the container" >&2; exit 125
    fi ;;
  rm)
    last="\${@: -1}"
    if [[ -f "\$st/lost-names" ]] && grep -Fxq "\$last" "\$st/lost-names"; then
      [[ -e "\$st/t-rm" ]] || date +%s.%N > "\$st/t-rm"
      echo "Error: simulated: cannot remove \$last" >&2; exit 1
    fi ;;
  ps)
    "$REAL_ENG14" "\$@"; rc=\$?
    [[ -f "\$st/lost-names" ]] && cat "\$st/lost-names"
    exit \$rc ;;
esac
exec "$REAL_ENG14" "\$@"
SH
    for t in git jj; do
      real="$(command -v "$t")"
      cat > "$C14/shim/$t" <<SH
#!/usr/bin/env bash
printf '%s lane=%s %s\n' "\$(date +%s.%N)" "\${WGM_SWARM_LANE:-0}" "\$*" >> "$C14/state/gj.log"
exec "$real" "\$@"
SH
    done
    chmod +x "$C14/shim/"*
  }
  c14_swarm_calls_after_rm() {  # count of swarm-level (lane=0) git/jj calls logged after the first failing rm
    local t; t="$(cat "$C14/state/t-rm" 2>/dev/null || true)"
    [[ -n "$t" ]] || { echo -1; return 0; }
    awk -v t="$t" '$1 > t && $2 == "lane=0" { n++ } END { print n + 0 }' "$C14/state/gj.log" 2>/dev/null
  }
  # --- S57: lane 1's launch fails and its container cannot be confirmed gone; lane 2 healthy; --cleanup
  make_c14_shims "/worktrees/wgm-s57-1"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$C14/shim:$PATH" "$SWARM" -n 2 --prefix wgm/s57 --max-iterations 1 --cleanup -- "$TMP/agentbin11/bin/mem-agent" </dev/null 2>&1)"; RC=$?
  set -e
  c14_name="$(head -1 "$C14/state/lost-names" 2>/dev/null || true)"
  c14_after="$(c14_swarm_calls_after_rm)"
  if [[ "$RC" -ne 0 && -n "$c14_name" && "$c14_after" -eq 0 ]] && grep -Fq "retained container $c14_name" <<<"$OUT" \
     && grep -Fq 'retained lane 1 at' <<<"$OUT" && grep -Fq 'retained lane 2 at' <<<"$OUT" && grep -Fq 'recover:' <<<"$OUT" \
     && [[ -d "$PROJECT/.wgm/worktrees/wgm-s57-1" && -d "$PROJECT/.wgm/worktrees/wgm-s57-2" && ! -e "$PROJECT/.wgm/memories.md" ]] \
     && ! grep -Fq 'consolidated' <<<"$OUT"; then
    pass "S57: containment loss stops the whole swarm: exact handle + recovery, both lanes retained, no consolidation/cleanup, zero swarm git/jj after the loss"
  else
    fail "S57 violated (rc=$RC name=[$c14_name] swarm-calls-after-loss=$c14_after memories=$([[ -e "$PROJECT/.wgm/memories.md" ]] && echo CONSOLIDATED || echo none)): $(tail -n 25 <<<"$OUT")"
  fi
  reset_fixture
  # --- S57b: the PREFLIGHT readiness launch fails the same way: no jj/git teardown, the workspace is retained
  make_c14_shims "wgm-swarm-pf"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$C14/shim:$PATH" "$SWARM" -n 1 --prefix wgm/s57b --max-iterations 1 -- "$TMP/agentbin11/bin/mem-agent" </dev/null 2>&1)"; RC=$?
  set -e
  c14_name="$(head -1 "$C14/state/lost-names" 2>/dev/null || true)"
  c14_after="$(c14_swarm_calls_after_rm)"
  pfb_path="$(grep -o 'retained preflight workspace [^ ]* at [^ ]*' <<<"$OUT" | awk '{print $6}' | head -1)"
  pfb_name="$(grep -o 'retained preflight workspace wgm-preflight-[0-9]*' <<<"$OUT" | awk '{print $4}' | head -1)"
  pfb_list="$(cd "$PROJECT" && jj --ignore-working-copy workspace list -T 'name ++ "\n"' 2>&1)"
  if [[ "$RC" -ne 0 && -n "$c14_name" && "$c14_after" -eq 0 && -n "$pfb_name" && -d "$pfb_path" ]] \
     && grep -Fq "retained container $c14_name" <<<"$OUT" && grep -Fq "recover: jj workspace forget $pfb_name" <<<"$OUT" \
     && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-s57b-1" ]] && grep -Fxq "$pfb_name" <<<"$pfb_list"; then
    pass "S57b: containment loss in the preflight retains its workspace with exact handles, no jj/git teardown, no lane"
  else
    fail "S57b violated (rc=$RC name=[$c14_name] swarm-calls-after-loss=$c14_after pf=[$pfb_name $pfb_path]): $(tail -n 25 <<<"$OUT")"
  fi
  if [[ -n "$pfb_name" ]]; then (cd "$PROJECT" && jj workspace forget "$pfb_name" >/dev/null 2>&1); rm -rf "$(dirname "$pfb_path")"; fi
  git -C "$PROJECT" worktree prune
  reset_fixture

  # V19/B1(b) (rugged G7 r28): the shared git store's pointer/config pins are captured by swarm once (before any lane
  # container) and verified before ANY post-run host git. The in-container agent cannot rewrite the read-only
  # config overlay, so a stand-in does it from the HOST while the lane's container runs: the engine shim appends a
  # line to the shared `config` (same type, regular file, new content) on the lane's first `run`. The lane loop must
  # exit 2 (trust lost), and swarm must stop at once: exit 2, `trust lost <path>`, the lane retained with its recovery,
  # and ZERO swarm-level git/jj calls after the change (timestamped shims, like S57).
  make_c14_shims "__no_such_match__"
  V19CFG="$PROJECT/.git/config"; cp "$V19CFG" "$TMP/v19-config.orig"
  cat > "$C14/shim/$BOX_ENGINE" <<SH
#!/usr/bin/env bash
st="$C14/state"
if [[ "\${1:-}" == run && "\$*" == *"/worktrees/wgm-v19-1"* && ! -e "\$st/t-edit" ]]; then
  date +%s.%N > "\$st/t-edit"
  printf '[wgm-selftest]\n\tchanged = by-stand-in-for-the-agent\n' >> "$V19CFG"
fi
exec "$REAL_ENG14" "\$@"
SH
  chmod +x "$C14/shim/$BOX_ENGINE"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$C14/shim:$PATH" "$SWARM" -n 1 --prefix wgm/v19 --max-iterations 1 --cleanup -- "$TMP/agentbin11/bin/mem-agent" </dev/null 2>&1)"; RC=$?
  set -e
  v19_t="$(cat "$C14/state/t-edit" 2>/dev/null || true)"
  v19_after=-1
  [[ -z "$v19_t" ]] || v19_after="$(awk -v t="$v19_t" '$1 > t && $2 == "lane=0" { n++ } END { print n + 0 }' "$C14/state/gj.log" 2>/dev/null)"
  if [[ -n "$v19_t" && "$RC" -eq 2 && "$v19_after" -eq 0 ]] && grep -Fq 'trust lost' <<<"$OUT" && grep -Fq "$PROJECT/.git" <<<"$OUT" \
     && grep -Fq 'retained lane 1 at' <<<"$OUT" && grep -Fq 'recovery:' <<<"$OUT" \
     && [[ -d "$PROJECT/.wgm/worktrees/wgm-v19-1" && ! -e "$PROJECT/.wgm/memories.md" ]] && ! grep -Fq 'consolidated' <<<"$OUT"; then
    pass "V19: a changed shared config stops the swarm: exit 2, trust lost <path>, lane retained, zero swarm git/jj afterwards"
  else
    fail "V19 violated (rc=$RC edited=[$v19_t] swarm-calls-after=$v19_after): $(tail -n 25 <<<"$OUT")"
  fi
  cp "$TMP/v19-config.orig" "$V19CFG"; git -C "$PROJECT" worktree prune; reset_fixture

  # V20/B2 (rugged G7 r29): the PREFLIGHT's containers can change the shared store too. A stand-in (engine shim, from the
  # host — the read-only config overlay blocks the in-container write) changes the shared `config` while the
  # preflight readiness container is launched. The preflight exits 2 (trust lost); swarm must then NOT run its
  # jj/git teardown against the changed store: exit 2, `trust lost <path>`, the preflight workspace retained with its
  # recovery line (still registered), no lane, and ZERO swarm-level git/jj calls after the change (timestamped shims).
  make_c14_shims "__no_such_match__"
  V20CFG="$PROJECT/.git/config"; cp "$V20CFG" "$TMP/v20-config.orig"
  cat > "$C14/shim/$BOX_ENGINE" <<SH
#!/usr/bin/env bash
st="$C14/state"
if [[ "\${1:-}" == run && "\$*" == *"wgm-swarm-pf"* && ! -e "\$st/t-edit" ]]; then
  date +%s.%N > "\$st/t-edit"
  printf '[wgm-selftest]\n\tchanged = during-the-preflight\n' >> "$V20CFG"
fi
exec "$REAL_ENG14" "\$@"
SH
  chmod +x "$C14/shim/$BOX_ENGINE"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" PATH="$C14/shim:$PATH" "$SWARM" -n 1 --prefix wgm/v20 --max-iterations 1 -- "$TMP/agentbin11/bin/mem-agent" </dev/null 2>&1)"; RC=$?
  set -e
  v20_t="$(cat "$C14/state/t-edit" 2>/dev/null || true)"
  v20_after=-1
  [[ -z "$v20_t" ]] || v20_after="$(awk -v t="$v20_t" '$1 > t && $2 == "lane=0" { n++ } END { print n + 0 }' "$C14/state/gj.log" 2>/dev/null)"
  v20_name="$(grep -o 'retained preflight workspace wgm-preflight-[0-9]*' <<<"$OUT" | awk '{print $4}' | head -1)"
  v20_path="$(grep -o 'retained preflight workspace [^ ]* at [^ ]*' <<<"$OUT" | awk '{print $6}' | head -1)"
  v20_list="$(cd "$PROJECT" && "$REAL_JJ" --ignore-working-copy workspace list -T 'name ++ "\n"' 2>&1)"
  if [[ -n "$v20_t" && "$RC" -eq 2 && "$v20_after" -eq 0 && -n "$v20_name" && -d "$v20_path" ]] \
     && grep -Fq 'trust lost' <<<"$OUT" && grep -Fq "recover: jj workspace forget $v20_name" <<<"$OUT" \
     && grep -Fxq "$v20_name" <<<"$v20_list" && [[ ! -e "$PROJECT/.wgm/worktrees/wgm-v20-1" ]]; then
    pass "V20: a preflight that changes the shared config stops swarm: exit 2, trust lost, workspace retained, zero swarm git/jj afterwards"
  else
    fail "V20 violated (rc=$RC edited=[$v20_t] swarm-calls-after=$v20_after pf=[$v20_name $v20_path]): $(tail -n 25 <<<"$OUT")"
  fi
  cp "$TMP/v20-config.orig" "$V20CFG"
  if [[ -n "$v20_name" ]]; then (cd "$PROJECT" && "$REAL_JJ" workspace forget "$v20_name" >/dev/null 2>&1); rm -rf "$(dirname "$v20_path")"; fi
  git -C "$PROJECT" worktree prune; reset_fixture

  # V21/B1: argv[0] is an OPAQUE pathname — a swarm whose agent executable path CONTAINS A SPACE is identified by the
  # basename of the whole path (`pi`), not by the text before the space (`bin`): with a record that approves agent `pi`
  # (and its token + config dir) the headless preflight passes, readiness runs that executable, and every lane runs
  # it unchanged with pi's credential copy present (an agent set of `bin` would be refused as unapproved).
  V21BIN="$TMP/v21 space dir/bin tools"; mkdir -p "$V21BIN" "$HOME/.pi/agent"
  printf '{}\n' > "$HOME/.pi/agent/auth.json"
  cat > "$V21BIN/pi" <<'AG'
#!/usr/bin/env bash
if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi
[[ "${1:-}" != --version ]] || { echo "pi 1"; exit 0; }
mkdir -p .wgm
printf 'EXE=%s AUTH=%s\n' "$0" "$([[ -r "$HOME/.pi/agent/auth.json" ]] && echo yes || echo no)" > .wgm/pi-ran.txt
printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"
AG
  chmod +x "$V21BIN/pi"
  v21_key="$(printf '%s' "$(readlink -f "$PROJECT/.git")" | sha256sum | cut -c1-16)"
  v21_dir="$XDG_CONFIG_HOME/wgm/sandbox"; mkdir -p "$v21_dir"; chmod 700 "$XDG_CONFIG_HOME/wgm" "$v21_dir"
  printf '# wgm sandbox decisions\nengine_declined: false\ndeclined_at:\nagents: pi\nimage:\ntokens:\n  - %s\ncopies:\n  - %s\nmounts:\nenv:\n' \
    "$(readlink -f "$HOME/.pi/agent/auth.json")" "$(readlink -f "$HOME/.pi/agent")" > "$v21_dir/$v21_key.yml"; chmod 600 "$v21_dir/$v21_key.yml"
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" "$SWARM" -n 2 --prefix wgm/v21 --max-iterations 1 -- "$V21BIN/pi" </dev/null 2>&1)"; RC=$?
  set -e
  v21_ok=0
  for n in 1 2; do
    d="$(cat "$PROJECT/.wgm/worktrees/wgm-v21-$n/.wgm/pi-ran.txt" 2>/dev/null || true)"
    [[ "$d" == "EXE=$V21BIN/pi AUTH=yes" ]] && v21_ok=$((v21_ok + 1))
  done
  if [[ "$RC" -eq 0 && "$v21_ok" -eq 2 ]] && grep -Fq 'sandbox: on' <<<"$OUT"; then
    pass "V21: an agent executable path with a space is identified as pi: approved record matches, readiness passes, both lanes run it unchanged with pi's credentials"
  else
    fail "V21 violated (rc=$RC lanes-ok=$v21_ok): $(tail -n 15 <<<"$OUT")"
  fi
  rm -f "$v21_dir/$v21_key.yml"; git -C "$PROJECT" worktree prune; reset_fixture

  # Mount contract (C1): a lane container sees ITS lane, the shared git dir and its own config.worktree
  # READ-ONLY — and not the parent checkout. The probe agent records what it can do inside its container.
  # shellcheck disable=SC2016
  AGENT_BOXPROBE=(bash -c 'if [[ -n "${WGM_CAPABILITY_PROBE_FILE:-}" ]]; then printf "%s" "$WGM_CAPABILITY_PROBE_CONTENT" > "$WGM_CAPABILITY_PROBE_FILE"; exit 0; fi; cfg="$(git rev-parse --git-dir)/config.worktree"; { if (: >> "$cfg") 2>/dev/null; then echo cfg-writable; else echo cfg-readonly; fi; if [[ -e "$WGM_TEST_PARENT/protected.txt" ]]; then echo parent-visible; else echo parent-hidden; fi; if git rev-parse --git-common-dir >/dev/null 2>&1; then echo common-reachable; fi; } > .wgm/probe.txt; printf -- "- work\n" >> IMPLEMENTATION_PLAN.md; printf "IMPLEMENTATION_PLAN.md\n" > "$WGM_OWNERSHIP_MANIFEST"' _)
  set +e
  OUT="$(cd "$PROJECT" && env -u WGM_DEVCONTAINER XDG_DATA_HOME="$REAL_DATA_HOME" WGM_TEST_PARENT="$PROJECT" "$SWARM" -n 1 --prefix wgm/mnt --max-iterations 1 -- "${AGENT_BOXPROBE[@]}" 2>&1)"; RC=$?
  set -e
  probe="$(cat "$PROJECT/.wgm/worktrees/wgm-mnt-1/.wgm/probe.txt" 2>&1 || true)"
  if [[ "$RC" -eq 0 ]] && grep -Fxq cfg-readonly <<<"$probe" && grep -Fxq parent-hidden <<<"$probe" && grep -Fxq common-reachable <<<"$probe"; then
    pass "lane container: own config.worktree read-only, git dir reachable, parent checkout not mounted"
  else
    fail "lane container mounts wrong (rc=$RC) probe=[$probe]: $OUT"
  fi
fi

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
  echo 'jj swarm harness: GREEN'
  exit 0
else
  echo 'jj swarm harness: RED' >&2
  exit 1
fi
