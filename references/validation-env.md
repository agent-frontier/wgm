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
     credential material: never copy dotfiles or credential stores (git/gh/ssh/netrc config,
     credential helpers, shell history, runtime state). The copy carries only the tip commit's tree
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
       path_re='(^|/)(\.netrc|_netrc|\.git-credentials|\.npmrc|\.pypirc|\.env(\..+)?|id_(rsa|dsa|ecdsa|ed25519)|credentials(\.json)?)$|\.(pem|key|p12|pfx)$|(^|/)\.(ssh|aws|gnupg)/|(^|/)\.config/gh/'
       paths=$(git -C "$src" ls-tree -r --name-only "$commit") || exit 2
       bad=$(printf '%s\n' "$paths" | grep -E "$path_re"); rc=$?
       [ "$rc" -le 1 ] || exit 2
       [ -z "$bad" ] || { echo "credential-looking paths:" >&2; echo "$bad" >&2; exit 2; }
       bad=$(git -C "$src" grep -I -i -l -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
         -e '(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=]' \
         -e 'Authorization:[[:space:]]*(Bearer|Basic)' -e 'aws_secret_access_key' \
         -e 'machine [^ ]+ .*password' "$commit" --); rc=$?
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
       cfg=$(git -C "$dst" config --local --get-regexp '^(remote\.|credential|url\.|http\.)'); rc=$?
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
       git rev-parse HEAD || exit 2
       b=$(git symbolic-ref -q HEAD); rc=$?
       [ "$rc" -le 1 ] || exit 2
       echo "branch ${b:-detached}"
       git for-each-ref --format='%(refname) %(objectname)' || exit 2
       git status --porcelain=v1 --ignored || exit 2
       h=$(git ls-files -s -z | sha256sum) || exit 2; echo "index ${h%% *}"
       h=$(git diff --cached --binary | sha256sum) || exit 2; echo "staged ${h%% *}"
       h=$(git diff HEAD --binary | sha256sum) || exit 2; echo "diff ${h%% *}"
       h=$(git config --local --list | sha256sum) || exit 2; echo "config ${h%% *}"
       { git ls-files -z --others --exclude-standard || exit 2
         git ls-files -z --others --ignored --exclude-standard || exit 2; } | sort -zu |
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
     <gate>; gate_rc=$?
     repo_snapshot > "$snap/after" || { rm -rf "$snap"; exit 2; }
     diff "$snap/before" "$snap/after"; diff_rc=$?
     rm -rf "$snap"
     [ "$gate_rc" -ne 0 ] && exit "$gate_rc"; exit "$diff_rc"
     ```
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
