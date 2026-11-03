# Validation environment — OCI containers (Podman-first)

Some scenarios (`references/scenarios.md`) need the software actually **running** — an HTTP API, a
CLI, or a TUI. A container gives a clean, reproducible, isolated place to run it so the judge
(`references/scoring.md`) grades real behavior instead of a mock. Containers are **optional**: use one
only when a scenario needs a live service.

## Podman-first, Docker fallback
Prefer **Podman** with **OCI** images (rootless by default); **Docker** is a drop-in fallback — the
same OCI image and argument-compatible commands work under either. Prefer a **`Containerfile`** (the
OCI name); fall back to `Dockerfile`. `scripts/loop.sh` resolves `--container auto` to available
Podman, then Docker, and reports `unavailable` when neither exists. `--container podman|docker`
forces one and fails clearly if that engine is absent. The runner selects and reports the engine; a
host adapter or agent owns the actual build/run/readiness/scenario execution flow below.

| Action | Podman | Docker |
|---|---|---|
| Build | `podman build -t wgm-app -f Containerfile .` | `docker build -t wgm-app -f Dockerfile .` |
| Run | `podman run --rm -d -p 8080:8080 --name wgm-app wgm-app` | `docker run --rm -d -p 8080:8080 --name wgm-app wgm-app` |
| Exec | `podman exec wgm-app <cmd>` | `docker exec wgm-app <cmd>` |
| Logs | `podman logs wgm-app` | `docker logs wgm-app` |
| Stop/rm | `podman rm -f wgm-app` | `docker rm -f wgm-app` |

## Validation flow
1. **Build** an image from the implementation.
2. **Run** the container — publish a port (HTTP), `exec` in (CLI), or attach a PTY (TUI).
3. **Wait for readiness** — poll a healthcheck/endpoint; don't grade before the service is up.
4. **Drive scenarios** — for each step, perform the action (HTTP probe / CLI exec / PTY keystrokes)
   and capture the observed output.
5. **Judge** — score satisfaction per step (`references/scoring.md`).
6. **Clean up** — remove the container (and image if ephemeral).

## When NOT to containerize
If a fast local deterministic check suffices — a unit test, a type-check, a local HTTP probe — skip
the container. Don't make Podman/Docker a hard dependency of wgm; reach for a container only when a
running service is the only way to observe the behavior a scenario describes.

A local container or offline proxy is still only local evidence. It can prove your client/protocol
path, but it is not proof of a live managed service or a public release; if acceptance says "live"
or "shipped," require that exact evidence or leave it blocked/unverified (`[learn]` issue #104).

## Safety & footguns
- Rootless Podman by default; run as a non-root user inside the image.
- Bind to **localhost**; pick a free port (and parameterize it) to avoid collisions across iterations.
- **Never** bake secrets into the image or mount credential files; pass throwaway test config only.
- Always clean up (`--rm`, remove dangling images) so iterations don't leak containers.
- **`localhost` is the right default only for a *same-side* consumer.** Bind/publish on loopback
  when the thing that calls the service runs on the same OS instance. When the consumer lives across
  a virtualization boundary — a **Windows process calling a service inside WSL**, a browser on the
  host calling a VM guest — loopback inside the guest is invisible to it: the guest's `127.0.0.1` is
  not the host's. Publish on all interfaces (or forward the port) and have the consumer use the
  guest's routable address (for WSL, the distro's IPv4) — noting that an all-interfaces bind is
  **LAN-reachable while it runs**, so keep such a service disposable, short-lived, and free of real
  data. **Verify it from the consumer's own OS**: a
  guest-side `curl` cannot observe that boundary at all, because it never crosses it. Run
  `bash scripts/test-wsl-windows-boundary.sh` on a Windows+WSL host to contrast both binds with a
  real Windows-origin probe (`[learn]` issue `agent-frontier/wgm#101`).
- **An isolated verifier must own its target directory.** A validation chain that inherits a
  globally shared build-target override (a `*_TARGET_DIR`-style env var, a shared cache path, a
  user-level tool config) can emit artifacts *outside* the stage-local path its verifier then
  checks — and the resulting "missing artifact" error looks exactly like a product defect while
  being a harness misconfiguration. Before an isolated staged build, **clear or scope ambient target
  overrides**, or set an explicit stage-local target directory the verifier and the build agree on.
  When a clean rerun in the gate-owned environment then passes, record that outcome **separately
  from product failures** — folding an environment fault into the product's failure count corrupts
  the signal the loop steers by (`[learn]` issue #83).
- **Isolating HOME must keep path-sandbox prerequisites.** A credential-isolated `HOME` can drop
  legitimate HOME-relative companion checkouts that directory-sandbox integration checks expect, so
  status and authorization cases fail before reaching their logic. During preflight, **inventory
  HOME-relative companion repositories as validation prerequisites**; inside the isolation, restore
  verified **read-only copies** of the ones that already exist. Never weaken the sandbox or its
  assertions, and **never copy credentials or user runtime state** into the isolated HOME (hermetic
  unit cases should own their fixtures instead). After a fix, re-run the affected cases first, then
  the original full gate; keep the failure trace and distinguish cached from newly executed
  evidence (`[learn]` issue #145).
- **A whole-repo gate must not mutate the tree or the real HOME.** Formatters and vetters in the gate
  (e.g. `go fmt`/`go vet`) can rewrite tracked dependency manifests such as `go.mod` when a module
  is only an *indirect* dependency and the code newly uses it directly. Prefer the standard library
  (stdlib) over a direct use of an indirect-only dependency so the gate leaves manifests untouched.
  Run the gate with an isolated `HOME` so tool tests cannot read operator credentials or leave
  untracked artifacts. When a HOME-relative sandbox needs a prerequisite, point the expected path
  (a **symlink** is fine) only at the verified, credential-free, read-only copy the rule above
  restores inside the isolation — never at the operator's own checkout or real HOME, which a test
  could read or mutate (`[learn]` issue #150).
- **Restore read-only prerequisites (procedure).**
  1. Inventory the HOME-relative paths the gate and tests expect (grep gate and test configs for
     `$HOME/` and `~/`), recording which exist.
  2. Copy only the existing checkouts into the isolated HOME at the same relative paths, without
     credential material. One contract, enforced by the helper: refuse (exit 2, nothing created) a
     tracked `.gitconfig`, shell history (`.bash_history`, `.zsh_history`, any file whose name starts with `.` and ends `_history`, in any directory), and
     credential paths and contents. The path denylist is exactly: file names `.netrc`, `_netrc`,
     `.git-credentials`, `.npmrc`, `.pypirc`, `credentials`, `credentials.json`, `id_rsa`, `id_dsa`,
     `id_ecdsa`, `id_ed25519`, any name starting `.env`, any name ending `.pem`, `.key`, `.p12` or
     `.pfx`, and anything under a `.ssh/`, `.aws/`, `.gnupg/` or `.config/gh/` directory, all in any
     directory; contents are scanned for private-key blocks, password/token/secret/api-key
     assignments, Authorization headers and netrc passwords. Path matching uses raw NUL-delimited names, so quoted or
     non-ASCII directories cannot hide a match; offending names print with control bytes as `?`.
     A detached-HEAD source copies normally (its HEAD commit
     is recorded in the manifest). The copy carries only the tip commit's tree
     (no history, no unreachable objects, no uncommitted or untracked files, no hooks, no
     submodules); copy those deliberately if a gate needs them.
     Before copying, the function scans the tip's tracked paths and contents and refuses (exit 2,
     nothing created) on credential-looking material. This pattern-based boundary is not a
     guarantee: if a source legitimately needs such files, the operator must prepare a sanitized
     copy explicitly; review the manifest.
  3. Verify while copying: the function below drops the remote/URL, refuses symlinks that escape
     the copy, checks that no credential config survives, applies `chmod -R a-w`, proves nothing
     is writable, and prints a manifest line (path, source commit, read-only result).
     ```bash
     copy_prereq() (
       set -o pipefail
       src=$1 dst=$2
       [ -d "$src/.git" ] || [ -f "$src/.git" ] || { echo "not a git checkout: $src" >&2; exit 2; }
       commit=$(git -C "$src" rev-parse HEAD) || exit 2
       path_re='(^|/)(\.gitconfig|\.[^/]*_history|\.netrc|_netrc|\.git-credentials|\.npmrc|\.pypirc|\.env[^/]*|id_(rsa|dsa|ecdsa|ed25519)|credentials(\.json)?)$|\.(pem|key|p12|pfx)$|(^|/)\.(ssh|aws|gnupg)/|(^|/)\.config/gh/'
       names=$(mktemp) || exit 2
       trap 'rm -f "$names"' EXIT
       git -C "$src" ls-tree -r -z --name-only "$commit" > "$names" || exit 2
       rc=0; bad=$(LC_ALL=C grep -z -E "$path_re" "$names" | LC_ALL=C tr '\0' '\n' | LC_ALL=C sed 's/[^[:print:]]/?/g') || rc=$?
       [ "$rc" -le 1 ] || exit 2
       [ -z "$bad" ] || { echo "credential-looking paths:" >&2; echo "$bad" >&2; exit 2; }
       rc=0; bad=$(git -C "$src" grep -I -i -l -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
         -e '(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=]' \
         -e 'Authorization:[[:space:]]*(Bearer|Basic)' -e 'aws_secret_access_key' \
         -e 'machine [^ ]+ .*password' "$commit" --) || rc=$?
       [ "$rc" -le 1 ] || exit 2
       [ -z "$bad" ] || { echo "credential-looking content in:" >&2; echo "$bad" >&2; exit 2; }
       src_abs=$(cd "$src" && pwd -P) || exit 2
       bail() { chmod -R u+w "$dst" 2>/dev/null; rm -rf "$dst"; exit 2; }
       git clone --quiet --no-local --depth 1 --single-branch --no-checkout "file://$src_abs" "$dst" || exit 2
       git -C "$dst" remote remove origin || bail
       git -C "$dst" checkout --quiet "$commit" || bail
       head=$(git -C "$dst" rev-parse HEAD) || bail
       [ "$head" = "$commit" ] || { echo "copy HEAD differs from source HEAD $commit" >&2; bail; }
       n_all=$(git -C "$dst" cat-file --batch-all-objects --batch-check | wc -l) || bail
       n_reach=$(git -C "$dst" rev-list --objects --all | wc -l) || bail
       [ "$n_all" = "$n_reach" ] || { echo "copy holds unreachable objects" >&2; bail; }
       root=$(cd "$dst" && pwd -P) || bail
       list=$(mktemp) || bail
       find "$dst" -path "$dst/.git" -prune -o -type l -print0 > "$list" || { rm -f "$list"; bail; }
       while IFS= read -r -d '' l; do
         lt=$(readlink "$l") || bail
         ld=$(dirname "$l") || bail
         t=$(cd "$ld" && realpath -m -- "$lt") || bail
         case "$t/" in "$root"/*) ;; *) echo "escaping symlink: $l -> $lt" >&2; rm -f "$list"; bail;; esac
       done < "$list"
       rm -f "$list"
       rc=0; cfg=$(git -C "$dst" config --local --get-regexp '^(remote\.|credential|url\.|http\.)') || rc=$?
       [ "$rc" -le 1 ] || bail
       [ -z "$cfg" ] || { echo "credential/remote config survived in copy" >&2; bail; }
       chmod -R a-w "$dst" || bail
       w=$(find "$dst" ! -type l -perm -u+w -print -quit) || bail
       [ -z "$w" ] || { echo "writable path in copy: $w" >&2; bail; }
       printf 'prereq\t%s\t%s\tread-only\n' "$dst" "$commit"
     )
     copy_prereq "<src>" "<dst>"
     ```
  4. Re-run the affected cases first, keeping the failure trace, then the original full gate,
     labeling cached vs fresh evidence (`[learn]` issue #145; docs audit A2).
- **Prove the gate did not mutate the repository (procedure).**
  1. Prefer a check mode over a write mode (`gofmt -l`, `--check` flags, `go mod tidy -diff` where
     supported, `git diff --exit-code`).
  2. Take a baseline before the gate and compare after. Status and diff alone miss overwrites of
     files that already existed untracked or ignored, so also hash their contents:
     ```bash
     repo_snapshot() (
       set -o pipefail
       idx=${GIT_INDEX_FILE:-$(git rev-parse --git-path index)} || exit 2
       case "$idx" in /*) ;; *) idx=$PWD/$idx;; esac
       cd "$(git rev-parse --show-toplevel)" || exit 2
       # Non-validator: never read holdout contents. A validator may drop the excludes and the
       # private index below. Pathspecs alone are not a no-read boundary (index refresh can open
       # excluded racily-clean entries), so inspect a private copy of the index with the holdout
       # entries removed by metadata-only plumbing before any worktree inspection.
       ex=(':(top,exclude)scenarios' ':(top,exclude).wgm/scenarios')
       pidx=$(mktemp) || exit 2
       trap 'rm -f "$pidx"' EXIT
       if [ -e "$idx" ]; then cp "$idx" "$pidx" || exit 2; else GIT_INDEX_FILE=$pidx git read-tree --empty || exit 2; fi
       export GIT_INDEX_FILE=$pidx
       git ls-files -z --cached -- ':(top)scenarios' ':(top).wgm/scenarios' |
         xargs -0 -r git update-index --force-remove -- || exit 2
       git rev-parse HEAD || exit 2
       rc=0; b=$(git symbolic-ref -q HEAD) || rc=$?
       [ "$rc" -le 1 ] || exit 2
       echo "branch ${b:-detached}"
       git for-each-ref --format='%(refname) %(objectname)' || exit 2
       git status --porcelain=v1 --ignored -- "${ex[@]}" || exit 2
       h=$(git ls-files -s -z -- "${ex[@]}" | sha256sum) || exit 2; echo "index ${h%% *}"
       h=$(git diff --cached --binary -- "${ex[@]}" | sha256sum) || exit 2; echo "staged ${h%% *}"
       h=$(git diff HEAD --binary -- "${ex[@]}" | sha256sum) || exit 2; echo "diff ${h%% *}"
       h=$( { git config --local --list || [ "$?" -eq 1 ]; } | sha256sum) || exit 2; echo "config ${h%% *}"
       { git ls-files -z --others --exclude-standard -- "${ex[@]}" || exit 2
         git ls-files -z --others --ignored --exclude-standard -- "${ex[@]}" || exit 2; } | sort -zu |
       while IFS= read -r -d '' f; do
         if [ -L "$f" ]; then t=$(readlink "$f") || exit 2; echo "link $f -> $t"
         elif [ -f "$f" ]; then h=$(sha256sum < "$f") || exit 2
           if [ -x "$f" ]; then x=x; else x=-; fi; echo "file $x ${h%% *}  $f"
         else echo "skip $f"; fi
       done || exit 2
     )
     top=$(git rev-parse --show-toplevel) || exit 2
     snap=$(mktemp -d) || exit 2
     snap_real=$(cd "$snap" && pwd -P) || { rm -rf "$snap"; exit 2; }
     top_real=$(cd "$top" && pwd -P) || { rm -rf "$snap"; exit 2; }
     case "$snap_real/" in "$top_real"/*)
       rm -rf "$snap"; echo "evidence dir is inside the checkout; set TMPDIR outside it" >&2; exit 2;; esac
     repo_snapshot > "$snap/before" || { rm -rf "$snap"; exit 2; }
     gate_rc=0; <gate> || gate_rc=$?
     repo_snapshot > "$snap/after" || { rm -rf "$snap"; exit 2; }
     diff_rc=0; diff "$snap/before" "$snap/after" || diff_rc=$?
     rm -rf "$snap"
     if [ "$gate_rc" -ne 0 ]; then exit "$gate_rc"; fi
     exit "$diff_rc"
     ```
     The snapshot works on a private copy of the index (`GIT_INDEX_FILE`, removed on exit) from
     which the holdout entries are dropped with metadata-only `git update-index --force-remove`
     before any worktree inspection, because a pathspec exclude alone does not stop `git status`
     from opening excluded, racily-clean files while refreshing the real index; the caller's index
     is never written. Inspection always runs from the repository root (`git rev-parse --show-toplevel`), whatever the
     invocation directory; reported paths are root-relative. Expected non-zero statuses are captured
     conditionally, so the blocks behave identically under an inherited `set -e`. Coverage exception:
     a non-validator snapshot excludes both holdout roots (`scenarios/`, `.wgm/scenarios/`) from every
     git inspection (`:(top,exclude)` pathspecs) so their contents are never read, and changes there
     are not reported; a validator that may read holdouts can drop the excludes.
     Evidence lives outside the checkout (the block refuses to run otherwise). A gate failure wins
     over the diff; exit 2 means the repository could not be inspected, never a pass. Report diff
     lines as "changed during the gate run, origin unknown" (a concurrent editor looks identical),
     and never revert or attribute them; a pre-existing or concurrent change made
     before the baseline is not reported. Tracked manifest edits show up in the diff hash.
     "Repository state" here covers HEAD/branch, all refs (including stash and tags), the index,
     working-tree tracked/untracked/ignored content with exec bit and symlink targets, and local
     config. It does not cover other `.git/` internals such as hooks and reflogs.
  3. Keep three properties distinct: HOME isolation (credentials/user state), manifest protection
     (tracked dependency manifests), and untracked/artifact files left behind in the worktree
     (`[learn]` issue #150; docs audit A3).
- **Run the gate in an isolated HOME (recipe).** Define `copy_prereq` (above) and the function below
  in the shell that runs the gate. Record the prerequisite source paths first, then run the affected
  checks first and the original full gate second, each through `isolated_gate`. The temp HOME must lie
  outside the current checkout (refused with exit 2 otherwise, gate not run). Form:
  `isolated_gate [<src> <rel>]... -- <gate…>`: zero or more prerequisite pairs before `--`, each
  copied with `copy_prereq` into the same temp HOME before the gate; any refused copy exits 2, never
  runs the gate and removes the temp HOME. `isolated_gate -- <gate…>` runs with an empty temp HOME; a
  missing `--`, an odd number of words before it, or no gate exits 2 with nothing run. The gate's own
  status is preserved. The temp HOME is removed afterwards (bounded, a few seconds) only when every
  stage's process group (each copy, then the gate) was observed absent; or reported as `retained: <path>` on stderr.
  SIGINT/SIGTERM to this shell terminate the running stage's whole process group. The group is owned
  until it is empty: after the leader exits (normally or not) any remaining members get TERM, then KILL
  after a bounded 2 s, and in every case (members seen or not) absence is observed with
  `pgrep -g <pgid>` as a tri-state probe (exit 1 absent, 0 present, other = could not inspect), bounded
  to 2 s by one deadline covering every attempt (a probe still running at the deadline is killed and
  reaped and counts as could-not-inspect; a probe that has COMPLETED is used whatever its timing: absence observed late is still absence, the deadline bounds waiting, not truth), before moving to the next stage. An unconfirmed copy-stage group stops the recipe before the
  gate. If absence is not confirmed, the temp HOME is kept and
  `retained: <path> (process group <pgid> not confirmed empty)` is printed on stderr; the function
  returns 75 if the gate's own status was 0 (a pass is never reported over unproven cleanup), otherwise
  the gate's status. Otherwise clean up or report `retained:` and return 130/143 after a signal. The
  gate may be a command or a shell function; it runs in a subshell with `HOME` set and
  `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` exported to `.config`,
  `.local/share`, `.cache`, `.local/state` under the temp HOME (created; inherited values are
  overridden). **Limit:** app-specific overrides holding absolute paths (tool `*_HOME`, cache or
  self-update variables) are not redirected; unset or redirect them before native-app gates (see the
  native-validation rule in `references/hard-to-test-domains.md`).
  ```bash
  isolated_gate() {
    local top home hr tr pid grp rc=0 sig=0 t stage mon=+m np=0 k a r unc= pre=()
    for a in "$@"; do
      if [ "$a" = -- ]; then break; fi
      np=$((np + 1))
    done
    if [ "$np" -ge "$#" ] || [ $((np % 2)) -ne 0 ] || [ "$np" -eq $(($# - 1)) ]; then
      echo "usage: isolated_gate [<src> <rel>]... -- <gate>" >&2; return 2
    fi
    if [ "$np" -gt 0 ]; then pre=("${@:1:np}"); fi
    shift $((np + 1))
    case $- in *m*) mon=-m;; esac
    trap '[ "$sig" -ne 0 ] || sig=130; [ -z "$grp" ] || kill -TERM -- "$grp" 2>/dev/null || :' INT
    trap '[ "$sig" -ne 0 ] || sig=143; [ -z "$grp" ] || kill -TERM -- "$grp" 2>/dev/null || :' TERM
    if ! top=$(git rev-parse --show-toplevel); then trap - INT TERM; return 2; fi
    if ! home=$(mktemp -d); then trap - INT TERM; return 2; fi
    hr=$(cd "$home" && pwd -P) || hr=$home
    tr=$(cd "$top" && pwd -P) || tr=$top
    k=1
    while [ "$k" -lt "$np" ]; do
      case "${pre[k]}" in ''|/*|..|../*|*/../*|*/..) echo "unsafe relative path: ${pre[k]}" >&2; rc=2;; esac
      k=$((k + 2))
    done
    case "$hr/" in "$tr"/*) echo "temp HOME is inside the checkout; set TMPDIR outside it" >&2; rc=2;; esac
    # Scratch user-state paths (XDG only; app-specific overrides are NOT redirected, see below).
    if [ "$rc" -eq 0 ]; then
      mkdir -p "$home/.config" "$home/.local/share" "$home/.cache" "$home/.local/state" || rc=2
    fi
    if [ "$rc" -eq 0 ]; then
      k=0
      while [ "$k" -le "$np" ]; do
        set -m   # job control gives each stage its own process group
        if [ "$k" -lt "$np" ]; then
          stage=copy
          ( copy_prereq "${pre[k]}" "$home/${pre[k+1]}" ) & pid=$!
        else
          stage=gate
          ( HOME=$home; export HOME
            XDG_CONFIG_HOME=$home/.config XDG_DATA_HOME=$home/.local/share
            XDG_CACHE_HOME=$home/.cache XDG_STATE_HOME=$home/.local/state
            export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
            "$@" ) & pid=$!
        fi
        set "$mon"; grp=-$pid
        t=0
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.1
          if [ "$sig" -ne 0 ]; then t=$((t + 1)); [ "$t" -lt 30 ] || kill -KILL -- "$grp" 2>/dev/null || :; fi
        done
        rc=0; wait "$pid" 2>/dev/null || rc=$?
        # Keep owning the group until it is empty: leftover members get TERM, then KILL after 2 s.
        if kill -0 -- "$grp" 2>/dev/null; then
          kill -TERM -- "$grp" 2>/dev/null || :
          t=0
          while kill -0 -- "$grp" 2>/dev/null && [ "$t" -lt 20 ]; do sleep 0.1; t=$((t + 1)); done
          kill -KILL -- "$grp" 2>/dev/null || :
        fi
        # Confirm absence (tri-state pgrep: 1 absent, 0 present, other = cannot inspect). One deadline
        # (20 ticks of 0.1 s, plus a 3 s wall-clock backstop) covers every probe attempt; each probe
        # runs in the background in its own group, and one still running at the deadline is KILLed,
        # reaped and counted as could-not-inspect; a probe that has COMPLETED is used whatever its
        # timing (absence observed late is still absence: the deadline bounds waiting, not truth).
        t=0; k0=$SECONDS
        while :; do
          set -m; pgrep -g "$pid" >/dev/null 2>&1 & pp=$!; set "$mon"
          r=
          while kill -0 "$pp" 2>/dev/null; do
            if [ "$t" -ge 20 ] || [ $((SECONDS - k0)) -ge 3 ]; then
              kill -KILL -- "-$pp" 2>/dev/null || :; kill -KILL "$pp" 2>/dev/null || :
              r=stalled; break
            fi
            sleep 0.1; t=$((t + 1))
          done
          if [ -z "$r" ]; then r=0; wait "$pp" 2>/dev/null || r=$?; else wait "$pp" 2>/dev/null || :; fi
          if [ "$r" = 1 ]; then break; fi
          if [ "$r" != 0 ] || [ "$t" -ge 20 ] || [ $((SECONDS - k0)) -ge 3 ]; then unc=$pid; break; fi
          kill -KILL -- "$grp" 2>/dev/null || :
          sleep 0.1; t=$((t + 1))
        done
        if [ -n "$unc" ]; then break; fi
        if [ "$sig" -ne 0 ]; then break; fi
        grp=
        if [ "$stage" = copy ] && [ "$rc" -ne 0 ]; then echo "prereq copy refused" >&2; rc=2; break; fi
        if [ "$stage" = copy ]; then k=$((k + 2)); else k=$((np + 1)); fi
      done
    fi
    grp=
    if [ -z "$unc" ]; then
      set -m
      ( chmod -R u+w "$home" 2>/dev/null || :; rm -rf "$home" ) & pid=$!
      set "$mon"
      t=0
      while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 30 ]; do sleep 0.1; t=$((t + 1)); done
      if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null || :; fi
      wait "$pid" 2>/dev/null || :
      if [ -e "$home" ]; then echo "retained: $home" >&2; fi
    else
      echo "retained: $home (process group $unc not confirmed empty)" >&2
      if [ "$rc" -eq 0 ] && [ "$sig" -eq 0 ]; then rc=75; fi
    fi
    trap - INT TERM
    if [ "$sig" -ne 0 ]; then return "$sig"; fi
    return "$rc"
  }
  isolated_gate "<src>" "<rel>" -- <gate>
  ```
- **Make the container own its lifetime.** Container validation wrappers should not rely on shell
  `trap` cleanup alone — a signal before the job or container ID is recorded, a second signal during
  finalization, `--rm` deleting the cidfile before it is read, or `SIGKILL` can all leak a container.
  Run the container with `--rm` under an inner or engine timeout (`--timeout`) so it terminates and
  removes itself even if the wrapper dies; have the container write its own log and exit status into
  the mounted results directory; capture the container ID from both `--cidfile` and `run` stdout;
  ignore catchable terminating signals and join every background job first in the `EXIT` finalizer;
  and still prove container absence afterward, treating a runtime probe error as unproven rather
  than absent (residual: a container created but never started is not covered by `--rm`). Field-test
  by `SIGKILL`ing the wrapper mid-run and polling until the container is gone (`[learn]` issue #142).

## Cross-links
`references/scenarios.md` · `references/scoring.md` · `scripts/loop.sh`
