# Local devcontainer sandbox — the default for loops and swarms (Podman-first)

`scripts/loop.sh` runs **sandboxed by default**: every agent invocation, gate command, `--notify` and
`--cost-cmd` string goes through one helper (`sandbox_exec` → `devcontainer.sh run --same-path`) into a
throwaway container, while loop.sh itself, swarm.sh, the guards, git bookkeeping and telemetry stay on the
host. `scripts/swarm.sh` defaults to `--backend jj` and each lane's loop runs in its own container mounting
that lane's workspace. This is **not** the scenario-validation container
(`references/validation-env.md`, which runs the app *under test*); this runs the **agent**.
Opt out with `--no-devcontainer` / `WGM_DEVCONTAINER=0` (labelled `sandbox: OFF — unsandboxed (<reason>)`);
force with `--devcontainer` / `WGM_DEVCONTAINER=1` (no working engine → exit 2). With no engine, an
interactive run is asked once (install Podman/Docker, or record a decline); a headless run fails closed.
The full operator contract — guarantee, residual risk, mounts, credentials, record, flags, exit codes — is in
`docs/operator/devcontainers.md`; this page is the short protocol view.

**Guarantee and residual risk.** The agent cannot read or write outside the project (lane) tree, this
repository's git store and its own throwaway credential copies, and wgm never follows agent-written symlinks,
consumes agent-redirected git metadata, runs the agent-written tree's hooks/filters/fsmonitor on the host, or
executes scripts the agent can edit. Nothing the agent writes inside the container persists outside the project tree and this repository's git directory, and that git directory's executable configuration (`config`, `config.worktree`, `hooks`, `info`, `objects/info`) is read-only inside. A hostile agent can still change this repository's content and history
(lanes commit, so its objects and refs are writable) and so influence tools that later process the repository
outside wgm — your host commits/hooks, CI. The sandbox protects the home directory, credentials and other
projects, **not this repository's history**. Host-side hardening: when the skill directory lies inside the project or git dir, loop.sh/swarm.sh run from a
run-private copy outside every mount, re-executed before preflight or any container; `PATH` directories inside a
writable mount are dropped, and an executable symlinking into one is exit 2 (wrapper scripts outside the project
that execute project files are an unanalyzed residual); a directory wgm cannot inspect is exit 2 before any container.
Before wgm reads any agent-writable file (memories, plan, ownership manifest, status files) it requires the file
and its in-project ancestors to be real non-symlink entries and the file regular — else exit 2 naming the path,
nothing read or passed to a helper. A symlinked `config`/`config.worktree` is refused (exit 2 before any container; replace it with a regular file). Include targets are
pinned by their content as resolved at capture time; a changed included file → exit 2 before host git. SIGINT/SIGTERM removes every container wgm started
(agent, gates, `--cost-cmd`, `--notify`, readiness, probe, smoke, preflight) by name with zero grace, printing
`retained container <name>` when absence cannot be confirmed.
No container ever mounts the parent checkout: swarm's preflight (readiness, probe, smoke) runs in a throwaway preflight
workspace at the parent's HEAD (same backend and git store, so the same approval record), removed afterwards, also on
refusal and interruption. Host git protections are set in the environment of wgm's whole host process tree (`GIT_CONFIG_COUNT`/`KEY`/`VALUE` for `core.fsmonitor=false`, `core.hooksPath=/dev/null` and `protocol.allow=never`; `GIT_ALLOW_PROTOCOL` set and empty; `GIT_NO_LAZY_FETCH=1`; `GIT_TERMINAL_PROMPT=0`), so helper scripts, lane loops and git spawned by jj inherit them; they are never passed into containers. Consequence: wgm's host-side git never runs a repository-configured command — hooks, fsmonitor, transports, filter drivers (clean/smudge/process), diff drivers (textconv/command), `diff.external`, credential helpers, the pager and the editor are all disabled for wgm's own host git calls. Trade-off: a file under a filter (e.g. Git LFS) whose timestamp changed may look modified to wgm and the run stops (fail closed); run `git status` yourself once in the checkout to refresh the index, then rerun.
Credential values never appear on any command line (host clean environment built in-process; containers get `--env NAME`
only); every token file in the record must remain a readable regular file or the run exits 2 `credential <file> not
reachable`. Engine calls during cleanup are time-bounded, so a hung engine client cannot stall exit — wgm prints
`retained container <name>` instead.
**Pointers first.** After every contained command, before wgm's host side touches git at all, it compares the git pointer files — the worktree `.git` file, the admin `gitdir` and `commondir`, and `objects/info/alternates` — with the values pinned before the first container; any change exits 2 at once, naming the file ("pointers were redirected … nothing was scanned or opened"). Swarm checks every lane against the parent's git common dir captured at start and retains a redirected lane. Recovery: restore the pointer's original content (a worktree's admin `commondir` is normally `../..`; `.git` in a worktree reads `gitdir: <COMMON>/worktrees/<NAME>`), then rerun. Only after this check passes does the entry check below run. Before wgm's host side runs git on a repository or worktree it checks, without following symlinks, that every git-dir entry git may open (index, HEAD, refs, packed-refs, logs, info, worktree admin dirs, objects) is a regular file or a real directory; a symlink or special file → exit 2 naming the path (swarm retains the affected lane and exits non-zero). Recovery: remove the link itself (`rm <PATH>`), never its target; for an index then run `git reset` in that checkout; rerun. **Residual risk:** an agent in a sibling lane running at the same moment could swap such an entry between the check and git's open; closing that requires a shared-git quiescence protocol (recorded follow-up). 
When wgm cannot confirm that a container is gone after a contained command returns (e.g. an agent timeout followed by a failed engine removal), the run stops at once with exit 2 — it does not verify, inspect, continue or retry — and prints `retained container <name>`. Recovery: `podman rm -f -t 0 <name>` / `docker rm -f <name>`, verify it is gone (`podman ps -a --filter name=<name>`), then rerun. Container absence is the prerequisite for every host-side check of the agent's tree.
**Containment loss is terminal for the whole swarm.** If any lane (or the preflight) cannot confirm that one of its containers is gone, or swarm's own container sweep cannot confirm absence, swarm stops: it prints every `retained container <name>` with its recovery (`podman rm -f -t 0 <name>` / `docker rm -f <name>`, then verify absence), reports every lane and the preflight workspace as retained with their recovery lines, exits non-zero, and does **not** inspect lanes, consolidate memories or tear anything down — even with `--cleanup`. Recovery order: remove the containers and verify they are gone, then inspect/merge the lanes, then clean up (`jj workspace forget <name>` / `git worktree remove`), then rerun.
Host disk janitors (e.g. a daily `podman image prune -a`) can remove `localhost/wgm-devcontainer-base:latest`; wgm rebuilds it on the next sandboxed run and real-engine test cases skip visibly while it is absent — exclude that image from the janitor.
Platform scope: field-validated on Linux/Podman; macOS and WSL
rely on the readiness probe to fail closed.

## The one design constraint: don't inflate disk per project
The naive approach — a `"build"` devcontainer.json per project — costs one multi-GB image per
project. wgm's approach costs **one image, total**:
- `scripts/devcontainer.sh init` scaffolds a `devcontainer.json` that references a **shared,
  prebuilt `"image"`** (`localhost/wgm-devcontainer-base:latest`), never a per-project `"build"`.
- The project directory is **bind-mounted**, never `COPY`'d into the image, so the image stays
  generic and tiny (~400MB) regardless of repo size or project count.
- `build-base` is **idempotent** — it no-ops (skip, don't rebuild) once the tag already exists
  locally, unless `--force`. Rebuilding a shared image on every run would defeat the point.
- `prune` reports `system df` and removes only **wgm-labeled** stopped containers / dangling
  images — never the shared tag itself, never anything without the label.

## Podman-first, Docker fallback
Same convention as `loop.sh --container`. `scripts/devcontainer.sh` talks to `podman`/`docker`
directly (no dependency on the separate `@devcontainers/cli`) — the scaffolded `devcontainer.json`
is still a standards-compliant [containers.dev](https://containers.dev) artifact any devcontainer
CLI or VS Code can also open for interactive work.

## Subcommands
`init` (scaffold) · `build-base` (build once, idempotent) · `run -- <cmd...>` (execute sandboxed,
auto-builds on first use) · `prune` (disk hygiene). See `docs/operator/devcontainers.md` for the
full flag reference and examples.

## Permission parity (the load-bearing gotcha)
`run` executes as the **calling host user's UID:GID**, not the image's baked UID, and adds
Podman's `--userns=keep-id` (rootless Podman otherwise remaps the caller to a different apparent
UID inside its user namespace; Docker needs no such flag). Without this, a bind-mounted project
directory that isn't world-readable (a `mktemp -d`-style `0700` dir is the common trap) is
unreadable/unwritable inside the sandbox even though the mount itself "succeeds."

## Bringing your own agent CLI
The shared image is deliberately generic — it bakes in no vendor's CLI. The agent's (and `node`'s) install
prefix is derived statically (no host `npm`/`node` runs): a binary inside the project needs no mount; a path
with `/lib/node_modules/` → the part before it; `<dir>/bin/<name>` → `<dir>`; else its own directory — mounted
**read-only** at the same path. A prefix the mount policy refuses (e.g. `$HOME`) is exit 2. OS-owned prefixes (`/usr`, `/bin`, `/sbin`, `/lib`, `/lib32`, `/lib64`, `/libx32`) are never mounted; a CLI installed there must be provided by the image — the readiness probe proves it, otherwise exit 2 with the project-image recipe. Every other derived prefix is checked and mounted read-only, or refused with a named exit 2. Host environment: wgm first restricts itself to an allowlist (`WGM_*`, essentials, candidate credential names), then, once you approve, keeps only the approved credential names; values never appear on a command line, and swarm carries the approved names into every lane. If the CLI is not
usable inside, the readiness probe exits 2 with the fix: build a project image
(build it with `"$ENGINE" build -t "$TAG" -f "$CF" .` — the published block in `docs/operator/devcontainers.md` — then `--devcontainer-image "$TAG"`).

jj is not bundled and the image's Git (2.39.5 in a bookworm fixture) cannot `worktree add --orphan`, so jj
workspace creation stays on the host; only each lane's loop is containerized.

## Credentials and mounts
The agent has its skill inside the container: the running wgm skill bundle is mounted **read-only** at its host path and at the agent's conventional skills dir under the
container HOME (`~/.agents/skills/wgm` plus the agent-specific dir), so the agent has its skill inside the sandbox and cannot modify wgm from there.
Never the whole `$HOME`, never `~/.ssh`, `~/.gnupg`, `~/.aws`, never `~/.gitconfig` (commit identity travels as
`GIT_AUTHOR_*`/`GIT_COMMITTER_*` env). Per agent, its token file and the top-level regular files of its config
dir are **copied** into a throwaway `0700` dir (deleted after the run) and mounted at `$HOME/<rel>` — refreshed
tokens are not written back; prefer API-key env auth (passed by name only, values never written). The project
mounts rw at its same absolute path; the git common dir rw for lane workspaces, with `config`,
`config.worktree`, `hooks/`, `info/`, `objects/info/` mounted read-only on top. Extra `--devcontainer-mount`
entries are read-only regular files/dirs only; every bind is non-recursive. The approval lives outside the
repository at `${XDG_CONFIG_HOME:-$HOME/.config}/wgm/sandbox/<repo-key>.yml` (`0600`, never mounted).

## `loop.sh` / `swarm.sh` integration
`--devcontainer` keeps its name but now means the boundary above; the old whole-loop re-exec is removed.
`WGM_IN_DEVCONTAINER=1` is set in every container (recursion guard; a run already inside reports
`sandbox=inside`). `$WGM_*` control variables and approved credential env *names* are forwarded. `--dry-run`
is non-mutating: it prints the decision (or the unresolved prerequisite) and prompts, records, probes and
launches nothing.

## When NOT to use it
If the loop is already running somewhere sufficiently isolated (CI, a disposable VM, a Codespace), or a
`--notify` needs a host-only integration, opt out explicitly with `--no-devcontainer` (or
`WGM_DEVCONTAINER=0`). That is an operator choice, labelled in the log and metrics — never a silent
fallback; a missing toolchain is fixed with a project image, not by leaving the sandbox.

## Cross-links
`references/ralph-loop.md` (Ralph-lite vs Ralph-full) · `references/validation-env.md` (the
*other* container use case — validating the app under test) · `docs/operator/devcontainers.md` ·
`docs/operator/running-the-loop.md`.
