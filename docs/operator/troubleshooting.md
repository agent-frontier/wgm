# Troubleshooting (operator)

## Executive overview

- **For:** anyone hitting a snag installing or running wgm.
- **First move:** every wgm gate prints a `Gate check:` block naming the failed item. Read that
  before anything else — it usually names the fix.
- **How this page is organized:** by stage — Install · Companions · Loop · Sandbox · Validation · Artifacts ·
  Contributing. Each entry is symptom, cause, resolution.
- **Most common three:** the skill is not listed (wrong directory name, or the session needs a
  restart); `build` refuses to start (no `IMPLEMENTATION_PLAN.md` yet); the loop never stops (pass a
  max, or drop a `STOP` sentinel).
- **Next:** [Installation](installation.md) · [Run the loop](running-the-loop.md) ·
  [Reference](../reference/README.md).

## Before you troubleshoot

Three checks resolve most reports:

1. **Read the gate output.** wgm prints `Gate check:` with a PASS or FAIL per item at every phase
   boundary. The failing item names the problem.
2. **Restart the agent session.** Skills are scanned at session start, so a freshly installed skill
   is invisible to an already-running session.
3. **Confirm the directory name.** The skill folder must be named exactly `wgm`, matching the `name:`
   field in its `SKILL.md` frontmatter. The same rule applies to `teach-me`, `quiz-me`, and `rugged`.

## Install

### The agent does not list wgm

| | |
|---|---|
| **Symptom** | The install reports success, but the client does not offer `/wgm`. |
| **Cause** | The folder is not where the client scans, the directory name does not match the skill name, or the session has not re-scanned. |
| **Resolution** | Confirm the path against the table in [Installation](installation.md). Ensure the directory is named exactly `wgm`. Restart the agent session. For project scope, start the agent from that project's root. |

### The curl one-liner does nothing, or prints 404

| | |
|---|---|
| **Symptom** | The piped installer exits silently or reports a 404. |
| **Cause** | The repository must be public for the unauthenticated one-liner to fetch. `curl -f` also exits silently on a 404, so a failed install can look like a no-op. |
| **Resolution** | Install from a clone instead: `git clone … && ./scripts/install.sh`. To see the real status, re-run the raw URL without `-f`. |

### "Failed to fetch wgm (…)"

| | |
|---|---|
| **Symptom** | The installer reports a fetch failure. |
| **Cause** | When piped with no local checkout, the installers self-fetch. This message means both the tarball download and the `git clone` fallback failed. |
| **Resolution** | Check connectivity, the `--ref` you passed, and `WGM_REPO` / `WGM_REF`. Or install from a clone. See [Installers reference](../reference/cli-install.md). |

### The Windows side did not get wgm after a WSL install

| | |
|---|---|
| **Symptom** | wgm works in WSL but a native-Windows agent cannot see it. |
| **Cause** | The mirror runs for **user-scope** installs only — not `--project` or `--dir` — and is skipped by `--no-windows`. It may also have failed to resolve your Windows home. |
| **Resolution** | Read the installer's note line. If it says it could not resolve your Windows home, pass `--windows-home /mnt/c/Users/you`. Confirm your Windows agent scans `%USERPROFILE%\.agents\skills\wgm`. |

### install.ps1 unexpectedly ran inside WSL

| | |
|---|---|
| **Symptom** | A PowerShell install produced a Linux-side install. |
| **Cause** | On Windows with a WSL distro present, a user-scope `install.ps1` delegates to the bash installer in WSL on purpose, so both homes are covered. |
| **Resolution** | Pass `-NoWsl` for a native-Windows install, or `-WslDistro NAME` to pick a distro. |

### PowerShell symlink or junction fails

| | |
|---|---|
| **Symptom** | A warning about junction creation during install. |
| **Cause** | Creating a junction can require elevated privileges. |
| **Resolution** | None needed — `install.ps1` falls back to a copy automatically and warns. Pass `-Method copy` to skip the attempt entirely. |

### How do I update an existing install?

Re-run the same installer. wgm refreshes a directory it recognizes as its own **in place**, with no
`--force` needed, and adds the Windows mirror if it was missing. From a clone, `make update` pulls
and reinstalls in one step.

## Companion skills

### teach-me, quiz-me, or rugged is missing

| | |
|---|---|
| **Symptom** | `/wgm` works but `/teach-me`, `/quiz-me`, or `/rugged` is not offered. |
| **Cause** | The install used `--no-companions` or `-NoCompanions`, or it ran from a source tree predating that companion, or the client has not re-scanned. |
| **Resolution** | Re-run the installer without the opt-out flag and restart the session. Confirm `SKILLS_DIR/teach-me/SKILL.md`, `SKILLS_DIR/quiz-me/SKILL.md`, and `SKILLS_DIR/rugged/SKILL.md` exist — they must be **siblings** of `wgm`, not nested inside it. |

### The installer says "companion not in this source, skipping"

| | |
|---|---|
| **Symptom** | That line appears during install. |
| **Cause** | The source tree or tarball has no `companions/` directory — an older release. |
| **Resolution** | Install from a newer ref: `--ref main`, or `--ref latest` for the newest published release. |

## Role agents (the swarm)

### The wgm roles do not appear in my host's agent list

| | |
|---|---|
| **Symptom** | `/wgm` works, but the host offers no `wgm-implementer`, `wgm-spec-reviewer`, or docs-audit personas. |
| **Cause** | Role subagents load from the host's own agent directory, never from inside the skill folder. Either no host client was selected, `--no-agents` / `-NoAgents` was passed, the host has no subagent primitive at all, or the session has not re-scanned. |
| **Resolution** | Re-run with a host selected — `--client copilot`, `--client claude`, or `--client all` — then restart the session. Confirm the files: `ls ~/.copilot/agents/wgm-*.agent.md` or `ls ~/.claude/agents/wgm-*.md` for a user install; `.github/agents/` or `.claude/agents/` for a project install. If your host has no subagent mechanism, that is expected: see the next entry. |

### My host has no agent directory at all

| | |
|---|---|
| **Symptom** | The installer prints that the `.agents` client gets no role adapters, or the host is Pi and nothing was written. |
| **Cause** | Not a failure. The Agent Skills standard defines skills, not subagents, and Pi ships without a subagent primitive by design, so wgm refuses to invent a directory no host reads. |
| **Resolution** | Use `bash scripts/audit.sh` for the docs-audit swarm. Correctness still needs two independent non-author review passes: use separate fresh reviewer invocations or an independent human handoff; if unavailable, the gate is blocked. Inline ruggedness remains permitted but is not correctness self-review. Capabilities and evidence are recorded in `compatibility/harnesses.json`. |

### The installer says "exists and is not wgm's"

| | |
|---|---|
| **Symptom** | One or more role files were skipped during install. |
| **Cause** | A file of that name already exists in the agent directory and does not end with wgm's `wgm-role-agent-adapter` marker for *this* host and file — usually one of your own agents that shares a wgm role name, a wgm file whose marker you deleted or pushed out of last place by appending text, or a marker copied from another host or role. wgm never overwrites a file it cannot prove it wrote. |
| **Resolution** | Rename your file, or pass `--force` / `-Force` to replace it deliberately. |

### Uninstall left wgm role files behind

| | |
|---|---|
| **Symptom** | After `--uninstall`, `wgm-*.agent.md` or `wgm-*.md` files remain in an agent directory, and the installer said "no wgm adapter receipt entries or marked adapter files". |
| **Cause** | Those files do not end with this host's `wgm-role-agent-adapter` marker, so wgm has no evidence it wrote them — they were placed there by hand, copied from elsewhere (including from the other host's directory), had the marker edited out, or gained text below it. Removal is by marker, not by name. |
| **Resolution** | Remove them by hand, or re-run the installer once with `--force` (which rewrites and stamps them) and then uninstall. |

## Running the loop

### "No agent configured."

| | |
|---|---|
| **Symptom** | `loop.sh` or `swarm.sh` exits `2` immediately. |
| **Cause** | No agent command was supplied. |
| **Resolution** | Set `WGM_AGENT`, pass `--agent "CMD"`, or append `-- copilot -p --allow-all-tools`. See [Choosing the agent](../reference/cli-loop.md#choosing-the-agent). |

### "Refusing to run 'build': no IMPLEMENTATION_PLAN.md found."

| | |
|---|---|
| **Symptom** | `build`, `review`, or `preflight` exits `1` before doing anything. |
| **Cause** | Those modes need a plan on disk; they are not allowed to invent one. |
| **Resolution** | Run a plan pass first: `./scripts/loop.sh plan --request "…"`, or `/wgm plan`. |

### The loop never stops

| | |
|---|---|
| **Symptom** | `build` keeps iterating indefinitely. |
| **Cause** | `build` defaults to unlimited iterations. |
| **Resolution** | Pass a max (`build 20`), set the between-iteration `--max-runtime-seconds` limit or `--idle-timeout`, create a `.wgm/STOP` sentinel, or press Ctrl+C. These checks do not interrupt active work; the separate `--agent-timeout-seconds` watchdog needs GNU `timeout`/`gtimeout` for termination. In a healthy run the agent drops the sentinel itself when no must-have task remains. |

### Model escalation is not kicking in

| | |
|---|---|
| **Symptom** | A stall never escalates to the stronger model. |
| **Cause** | Escalation engages only when **both** `--frugal-agent` and a main `--agent` are set. |
| **Resolution** | Set both, and check `--escalate-after` (default `2`). See [Stall recovery](../agent/stall-recovery.md). |

### "Capability probe failed"

| | |
|---|---|
| **Symptom** | The loop exits before iteration 1 with a message that the agent did not create the disposable marker. |
| **Cause** | The headless agent can read the workspace but cannot write to it, or the invocation used a constrained/no-tools mode. |
| **Resolution** | Grant the invocation write access or use a full-shell agent, then rerun. `--dry-run` does not test this; a real `build` or `plan` always probes before spending the first iteration. |

### "No progress: plan unchanged"

| | |
|---|---|
| **Symptom** | A build exits non-zero after successful agent invocations that leave `IMPLEMENTATION_PLAN.md` unchanged. |
| **Cause** | Exit status alone is not evidence of useful work; the agent may have produced prose without an artifact or stopped without recording progress. |
| **Resolution** | Inspect the agent log and plan, fix the task or permission problem, then rerun. Increase `--max-no-progress-iterations` only when a plan-preserving iteration is intentional and documented. |

### "Agent timed out"

| | |
|---|---|
| **Symptom** | The loop reports `Agent timed out after Ns` and records a failed iteration. |
| **Cause** | `--agent-timeout-seconds N` reached its limit. On hosts without GNU `timeout` or `gtimeout`, the loop states that it is using the cooperative fallback instead of pretending to terminate the process. |
| **Resolution** | Inspect the agent output, lower the task scope, or increase the explicit timeout. Use a host with GNU `timeout`/`gtimeout` when hard process-group termination is required. |

### A `plan` or `extract` phase exits without its artifact

| | |
|---|---|
| **Symptom** | A single phase exits non-zero with `Phase artifact missing`. |
| **Cause** | The agent process returned zero without creating the plan or genes artifact promised by the phase. |
| **Resolution** | Inspect the agent's write/tool permissions and rerun with a full-shell invocation. Do not treat a prose handoff as a substitute for the named file. |

### "`--commit` requires a clean worktree" or "undeclared paths"

| | |
|---|---|
| **Symptom** | A commit-mode loop refuses to start or refuses to stage a path. |
| **Cause** | `--commit` takes exclusive ownership and will not sweep pre-existing or undeclared edits into an iteration commit. |
| **Resolution** | Move human edits to another worktree or commit them before starting. The agent must declare each intentional repository-relative file in the iteration ownership manifest; never bypass the refusal with `git add -A`. |

### The build loop edits the wrong files, or drifts

| | |
|---|---|
| **Symptom** | Changes land outside the task's stated scope. |
| **Cause** | The task's spec or plan entry is too loose to steer on. |
| **Resolution** | Add a **sign** rather than hand-holding each step: tighten the spec, add a note to `AGENTS.md`, or split the task smaller. wgm steers on patterns plus backpressure. |

### A swarm lane failed with "lane guard: expected worktree …"

| | |
|---|---|
| **Symptom** | A lane exits immediately with a guard message. |
| **Cause** | The lane's path, branch, tip, or parent state no longer matches its assignment. The host refuses its own commit; the guard is a tripwire, not a sandbox (the container is). |
| **Resolution** | Inspect the lane log, `git worktree list`, and the retained files/branch before recovery. For jj also inspect `jj --ignore-working-copy workspace list`; never run destructive cleanup before saving work. See [swarm recovery](../reference/cli-swarm.md#merging-and-cleanup). |

### The jj swarm refuses setup or retains a lane

| | |
|---|---|
| **Symptom** | An explicit `--backend jj` reports missing/old jj, unsupported Git `--orphan`, or no colocation; or the jj backend reports an unclean parent, an unignored runtime path, or changed workspace identity. (Without `--backend`, missing jj tooling or colocation only prints one notice and uses Git worktrees.) |
| **Cause** | The jj backend requires Git with `worktree add --orphan` (normally 2.42+), a clean colocated checkout, and ignored runtime/lane paths; swarm never initializes jj. Failed or ambiguous cleanup retains work. |
| **Resolution** | Install jj 0.46.0+ and compatible Git, or explicitly select `--backend git`. Inspect the parent and `jj --ignore-working-copy workspace list`; follow the [jj setup and recovery guide](../reference/cli-swarm.md#try-the-jj-backend). Do not use `make clean-worktrees` in a jj checkout. |

### A swarm lane says `ok` but has zero commits

| | |
|---|---|
| **Symptom** | The swarm summary marks a lane as failed even though the lane process exited zero. |
| **Cause** | `swarm.sh` verifies the artifact after waiting; a task lane with no reachable commit is a silent no-op, not a success. |
| **Resolution** | Read `.wgm/swarm-logs/*.log`, confirm the agent invocation has tool/write permission, and rerun the lane. Do not merge or report a zero-commit lane as completed. |

## Sandbox (default devcontainer)

Loops and swarms run sandboxed by default (see [devcontainers.md](devcontainers.md)). Every failure
below is a **fail-closed preflight** (exit 2, no iteration and no lane started) unless noted; none of
them falls back to the host. Opting out is explicit: `--no-devcontainer` or `WGM_DEVCONTAINER=0`.
`--dry-run` is non-mutating, so it is a safe way to *see* the decision or the unresolved prerequisite
(it does not claim readiness). The record is at `${XDG_CONFIG_HOME:-$HOME/.config}/wgm/sandbox/<REPO-KEY>.yml`.

### No container engine (Podman or Docker) is installed

| | |
|---|---|
| **Symptom** | Interactive: a notice with install commands and `Proceed without a sandbox and remember this? [y/N]`. Headless / `--devcontainer`: exit 2 "no container engine". |
| **Cause** | Neither `podman` nor `docker` is on `PATH`, and no decline is recorded (headless runs never decide for anyone; a forced run never accepts a decline). |
| **Recovery** | Install one — Debian/Ubuntu `sudo apt-get install -y podman`; Fedora `sudo dnf install -y podman`; Arch `sudo pacman -S podman`; macOS `brew install podman && podman machine init && podman machine start` (or Docker) — and rerun; a detected engine always overrides a recorded decline. Or answer `y` once to record the decline (loop runs then carry `sandbox: OFF — unsandboxed (recorded-decline)`), or pass `--no-devcontainer`. To clear a recorded decline set `engine_declined: false` in the record or delete the record. |
| **Verify** | `podman info >/dev/null && echo ok` (or `docker info`), then `scripts/loop.sh build --dry-run` prints `sandbox=on`. |

### The engine is installed but broken

| | |
|---|---|
| **Symptom** | Exit 2 though `podman`/`docker` exists; or an iteration fails with the engine's own message (never a host fallback). |
| **Cause** | Detection requires `<ENGINE> info` to succeed: a stopped Podman machine, an inaccessible Docker socket, a rootless-storage fault, or a stale `DOCKER_HOST`/`CONTAINER_HOST` (names pointing inside a writable mount are dropped: `sandbox: host env: dropped <NAME>`). |
| **Recovery** | Run `podman info` (or `docker info`) yourself and fix what it reports: `podman machine start`, add yourself to the `docker` group and re-login, unset a stale `DOCKER_HOST`. Rootless Podman also needs `XDG_DATA_HOME` pointing at your real image store. |
| **Verify** | `podman info >/dev/null; echo $?` prints `0`; rerun `scripts/loop.sh build --dry-run`. |

### "conflicting sandbox choices"

| | |
|---|---|
| **Symptom** | Exit 2 "conflicting sandbox choices". |
| **Cause** | `--devcontainer` together with `--no-devcontainer`, or a flag that contradicts `WGM_DEVCONTAINER` (`0` = off, `1` = force). |
| **Recovery** | Pass one choice: drop the flag, or `unset WGM_DEVCONTAINER` / set it to match. |
| **Verify** | `env | grep WGM_DEVCONTAINER`, then `scripts/loop.sh build --dry-run` prints a decision. |

### Credentials are unapproved, stale or the record is unusable

| | |
|---|---|
| **Symptom** | Interactive: `Mount these into the sandbox? [Y/n]` again. Headless (including every swarm lane): exit 2 naming the missing approval. |
| **Cause** | No record yet; the set of agents changed (main, `--agent`, or frugal); a token file's canonical target changed; a config dir became a symlink; the record is malformed (treated as absent), is a symlink, is not owned by you or is group/world-writable (refused); or the record directory lies inside a mount. A `.wgm/sandbox.yml` inside the repository is never read. |
| **Recovery** | Run once from a terminal: `scripts/sandbox.sh preflight --interactive yes --agent-cmd '<YOUR AGENT COMMAND>'` (repeat `--agent-cmd` for a frugal agent) and answer `Y`. Fix permissions with `chmod 700` on the directory and `chmod 600` on the file, replace a symlink with a regular file, or set `XDG_CONFIG_HOME` outside the project and git dir. To revoke, delete the record. |
| **Verify** | `ls -ld "${XDG_CONFIG_HOME:-$HOME/.config}"/wgm/sandbox "${XDG_CONFIG_HOME:-$HOME/.config}"/wgm/sandbox/*.yml` shows `drwx------` and `-rw-------`, then `scripts/loop.sh build --dry-run` runs without a prompt. |

### "credential … not reachable"

| | |
|---|---|
| **Symptom** | Exit 2 "credential `<file or NAME>` not reachable" — including a token file listed in the approval record that is now missing, unreadable or no longer a regular file. |
| **Cause** | An approved token file is unreadable on the host (moved, deleted, wrong permissions) or its copy is unreadable inside the container, or an approved env name is unset or empty. |
| **Recovery** | A deleted *approved* token is **not** cleared by interactive re-approval alone. Restore the file (re-login with the agent on the host so it exists), **or** remove that token's line from the approval record (the refusal prints the record's path and the exact `  - <PATH>` line under `tokens:`) or delete the record, then rerun interactively to re-approve (`scripts/sandbox.sh preflight --interactive yes --agent-cmd '<YOUR AGENT COMMAND>'`). For an unreadable file or unset env name: re-login so the file exists, `chmod u+r` it, or export the variable (API-key env auth is recommended: `export ANTHROPIC_API_KEY=…`; values travel by name only). Then rerun. Preflight does **not** check the login itself — a bad or expired login only shows at the agent's first real call. |
| **Verify** | `test -r <FILE> && echo readable`, or `test -n "${NAME:-}" && echo set`; rerun `scripts/loop.sh build --dry-run`. |

### The agent CLI is not executable inside the container

| | |
|---|---|
| **Symptom** | Exit 2 from the readiness probe naming the agent and "install the agent CLI in a project image". |
| **Cause** | The agent's first word does not resolve or run in the container (not under a mountable prefix, a wrong-architecture native binary, a missing interpreter, "exec format error", exit 126/127). |
| **Recovery** | Build a project image and select it. Create `.devcontainer/Containerfile` with `FROM localhost/wgm-devcontainer-base:latest` and the install lines, then run the published build block (`ENGINE=podman; TAG=…; CF=.devcontainer/Containerfile`, then `"$ENGINE" build -t "$TAG" -f "$CF" .`) and rerun with `--devcontainer-image "$TAG"` (or `WGM_DEVCONTAINER_IMAGE`). See [devcontainers.md](devcontainers.md#decision-order-first-match-wins). |
| **Verify** | `podman run --rm <TAG> sh -c 'command -v <AGENT> && <AGENT> --version'`; then the readiness probe passes on rerun. |

### The toolchain smoke (gate) fails inside the container

| | |
|---|---|
| **Symptom** | Preflight shows the tail of your gate command's output; interactive asks whether to proceed anyway, headless exits 2. |
| **Cause** | The shared image lacks a tool your gates need, or they depend on a host-only service. |
| **Recovery** | Add the tool via a project image as above (build, then `--devcontainer-image <TAG>`). Proceeding anyway records nothing, and every iteration's own gate still runs (and fails that iteration) — there is no host fallback; run host-side tests deliberately with `WGM_DEVCONTAINER=0`. |
| **Verify** | `podman run --rm -v "$PWD:$PWD" -w "$PWD" <TAG> <GATE COMMAND>` exits 0; preflight then passes. |

### The git common directory is unreachable

| | |
|---|---|
| **Symptom** | Exit 2 "unresolvable common dir" (or a lane's commits fail inside the container). |
| **Cause** | A lane workspace's `.git` file points at a git dir that no longer exists, was moved, or is refused by the mount policy; the container needs it at the same absolute path. |
| **Recovery** | Restore or re-create the workspace from the host (`jj workspace update-stale`, or remove and re-add the lane); never edit the `.git` pointer by hand. |
| **Verify** | `git -C <LANE> rev-parse --git-common-dir` prints an existing path; `scripts/loop.sh build --dry-run` from the lane succeeds. |

### A mount is refused

| | |
|---|---|
| **Symptom** | Exit 2 naming a path and a reason (`$HOME`/`/`, `~/.ssh`…, runtime tree, contains a socket/device/FIFO, contains a mount point, hard-linked file, a directory wgm cannot inspect, a `PATH` executable symlinked into a writable mount, config include inside a writable mount, two mounts on one path, `rw` extra mount). |
| **Cause** | The [mount policy](devcontainers.md#mounts--the-full-inventory) refused it; the message names the exact item. |
| **Recovery** | Remove or move the named item (an uninspectable directory: restore your read/execute permission on it, or move it out of the project; entries vanishing mid-scan are not failures; a `PATH` entry `<DIR>/<NAME> -> <TARGET>` pointing into the project: remove that link or drop that directory from `PATH` when running wgm) (a socket out of the tree, `git repack -a -d && git prune-packed` for hard-linked objects, re-copy hard-linked files, move an included config file outside the writable mounts), drop the extra `--devcontainer-mount` or make it a read-only file/dir, or move the install prefix. Never "fix" it by mounting `$HOME`. |
| **Verify** | `scripts/loop.sh build --dry-run` stops naming nothing; for a hard link `find . -xdev -type f -links +1 -print -quit` prints nothing. |

### "agent-written symlink at <PATH> — refusing to follow"

| | |
|---|---|
| **Symptom** | A running loop stops with exit 2 after an agent iteration, naming a path (also when wgm was about to *read* memories, the plan, the ownership manifest or a status file). |
| **Cause** | The agent created a symlink where wgm writes or reads (metrics, `.wgm/run/*`, plan, memory, manifest or status files), or at an ancestor inside the project, or the file is not regular. wgm refused to follow it; nothing was read, passed to a helper (e.g. the Hive harvest) or touched. That iteration ran. |
| **Recovery** | Inspect `ls -l <PATH>` and its ancestors, replace the symlink with the intended regular file (or remove it) after confirming its target, review the iteration's diff, and rerun. |
| **Verify** | `test ! -L <PATH>` succeeds; the loop starts and iterates. |

### A symlinked git configuration is refused

| | |
|---|---|
| **Symptom** | Exit 2 before any container, naming `config` or `config.worktree` as a symlink. |
| **Cause** | The executable git configuration must be a regular file; a symlink could point host git at a file the agent can edit, so wgm refuses it. |
| **Recovery** | Check the referent (`readlink -f .git/config` and read what it points to), then replace the symlink with a regular file holding the intended configuration: `cp --remove-destination "$(readlink -f .git/config)" .git/config` (likewise for `config.worktree`). Rerun. |
| **Verify** | `test -f .git/config && test ! -L .git/config`; a real (non-dry-run) preflight passes. |

### "git configuration changed by the agent" / "git metadata changed by the agent"

| | |
|---|---|
| **Symptom** | A running loop stops with exit 2 after an agent iteration. |
| **Cause** | (Include targets are pinned by their content as resolved at capture time, so changing an included file also trips this.) The pinned digest of `config`, `config.worktree`, `hooks/`, `info/`, alternates or admin dir names, or a pinned pointer (`.git` file/dir, `commondir`, `gitdir`), differs from before the run. Nothing was executed on the host. |
| **Recovery** | Compare against a trusted copy (`git config --show-origin -l` from a clean checkout, `ls -l .git/hooks`), restore the changed file or pointer from the host, and review the iteration's work before continuing. If you changed config yourself, do so while no loop runs. |
| **Verify** | Run a real (non-dry-run) preflight or loop: that is what captures and checks the pins; it completes an iteration without this message. `--dry-run` only shows the decision and the planned mounts — it returns before any pin is captured, so it cannot confirm this. |

### `retained container <NAME>` or `retained credential copy <PATH>`

| | |
|---|---|
| **Symptom** | After SIGINT/SIGTERM (loop and swarm exit 130 for SIGINT and 143 for SIGTERM) or a failed cleanup, the log prints the name or path. |
| **Cause** | wgm removes every container it started (agent, gates, `--cost-cmd`, `--notify`, readiness, probe, smoke, preflight) by name with zero grace and bounded waits, and prints this when absence cannot be confirmed (a hung engine client — engine calls during cleanup are time-bounded, so wgm still exits promptly; swarm prints `cleanup unverified: retained container …` — or an engine hiccup, an interrupted swarm's ~24 s cleanup window expiring, an undeletable copy). The run's own exit status is unchanged. |
| **Also** | If wgm cannot confirm a container is gone after a contained command returns (e.g. an agent timeout followed by a failed engine removal), the run stops at once with **exit 2** — it does not verify, inspect, continue or retry — and prints `retained container <NAME>`. Container absence is the prerequisite for every host-side check of the agent's tree. |
| **Recovery** | Once the engine responds: `podman rm -f -t 0 <NAME>` (or `docker rm -f <NAME>`); `chmod -R u+rwx <PATH> && rm -rf <PATH>` for a credential copy (a `0700` dir outside every mount, never mounted again). `scripts/devcontainer.sh prune` removes any other stopped wgm-labeled leftovers. |
| **Verify** | `podman ps -a --filter name=<NAME>` (or `docker ps -a --filter name=<NAME>`) lists nothing, and `podman ps -a --filter label=wgm.devcontainer=1` shows nothing stale; `test ! -e <PATH>`. Then rerun; the next run is not blocked. |

### "cleanup unverified: retained container wgm-<KEY8>-<LOOP PID>-*" (swarm)

| | |
|---|---|
| **Symptom** | After a swarm, one line per lane loop `cleanup unverified: retained container wgm-<KEY8>-<LOOP PID>-*`, and swarm exits non-zero (unless the run had already failed). |
| **Cause** | The engine could not be inspected, or a lane container could not be confirmed removed. Swarm reports it rather than claiming a clean exit. |
| **Recovery** | List: `podman ps -a --filter name=wgm-` (or `docker ps -a --filter name=wgm-`). Remove each match: `podman rm -f -t 0 <NAME>` (or `docker rm -f <NAME>`). If the engine itself is broken, fix it first (see "The engine is installed but broken"). |
| **Verify** | The same `ps -a --filter name=wgm-` command lists nothing for that swarm's prefix; the next run is not blocked. |

### "retained preflight workspace <NAME> at <PATH>" (swarm interrupted during preflight)

| | |
|---|---|
| **Symptom** | You pressed Ctrl+C (or swarm got SIGTERM) during its preflight; swarm printed `retained preflight workspace <NAME> at <PATH> — recover: jj workspace forget <NAME> && rm -rf <PATH>` and exited non-zero. |
| **Cause** | Preflight stopped promptly and removed its containers by name with zero grace, but could not verify that its throwaway preflight workspace (created at the parent's HEAD) was removed. No lane had been created. |
| **Recovery** | jj backend: `jj workspace forget <NAME> && rm -rf <PATH>`. Git backend: `git worktree remove --force <PATH>`. Also list leftovers with `podman ps -a --filter name=wgm-` (or `docker ps -a --filter name=wgm-`) and remove with `podman rm -f -t 0 <NAME>` / `docker rm -f <NAME>`. |
| **Verify** | `jj --ignore-working-copy workspace list` (or `git worktree list`) no longer lists `<NAME>`, `test ! -e <PATH>`, and a fresh swarm `--dry-run` runs. |

### Swarm stopped on containment loss (retained containers, lanes and preflight workspace)

| | |
|---|---|
| **Symptom** | Swarm prints every `retained container <NAME>` plus retained lanes (and, during preflight, the preflight workspace) with recovery lines. Exit status: **1** for a post-run containment loss (lanes retained), **2** for a preflight containment or trust loss and for a post-run trust loss (lanes retained) — see the [exact table](../reference/cli-swarm.md#exact-exit-status-per-terminal-phase-and-what-each-retains). It did not inspect lanes, consolidate memories or clean up — even with `--cleanup`. |
| **Cause** | A lane or the preflight could not confirm one of its containers gone, or swarm's own container sweep could not confirm absence. Containment loss is terminal for the whole swarm. |
| **Recovery** | In this order: (1) `podman rm -f -t 0 <NAME>` / `docker rm -f <NAME>` for each printed container, and verify absence (`podman ps -a --filter name=wgm-`); (2) inspect and merge the lanes; (3) clean up: `jj workspace forget <NAME>` / `git worktree remove <PATH>`; (4) rerun. |
| **Verify** | `ps -a --filter name=wgm-` lists nothing for the swarm's prefix; `jj --ignore-working-copy workspace list` / `git worktree list` shows only what you kept. |

### The approval record is locked, partial or malformed

| | |
|---|---|
| **Symptom** | Exit 2 naming a lock (`.lock.own` or `.lock` in the record directory) held by a live process; or, interactively, the credentials question is asked again though you approved before; headless runs exit 2. |
| **Cause** | Record writes are always locked: every writer takes the owner-record lock FILE `<DIR>/.lock.own` (created atomically together with its owner record — process id + start time) **and also** `flock <DIR>/.lock` where `flock` exists. A stale `.lock.own` (owner gone, reused pid, or older than 120 s) is broken automatically under a short breaker mutex `<DIR>/.lock.break`; a live holder fails closed with exit 2 naming the lock. A malformed or partial record (a write killed mid-way is never half-visible, but a hand-edited file can be) is treated as absent: interactive runs ask again, headless runs exit 2. |
| **Recovery** | Only if no wgm process is running (`pgrep -af 'wgm|loop.sh|swarm.sh|sandbox.sh'` shows none for this repository): `rm "${XDG_CONFIG_HOME:-$HOME/.config}/wgm/sandbox/.lock.own"`, and `rmdir "${XDG_CONFIG_HOME:-$HOME/.config}/wgm/sandbox/.lock.break"` if a leftover breaker directory exists; then rerun. For a malformed record, rerun interactively to rewrite it, or fix/delete the file. |
| **Verify** | `test ! -e "${XDG_CONFIG_HOME:-$HOME/.config}/wgm/sandbox/.lock.own"`; `scripts/loop.sh build --dry-run` completes without exit 2 (or without a prompt once the record is valid). |

### Swarm refuses the parent index

| | |
|---|---|
| **Symptom** | Swarm exits 2 naming the parent's git index, with a `retained preflight workspace <NAME> at <PATH> — recover: …` line. |
| **Cause** | The parent index (`.git/index` in the shared git dir) is not a regular file — e.g. an agent replaced it with a symlink. wgm copies the parent index only without following symlinks, into a private directory outside every mount, so it refuses instead. |
| **Recovery** | Inspect it: `ls -l .git/index`. Restore it in the parent checkout: `rm .git/index && git reset`. Then clear the retained preflight workspace (`jj workspace forget <NAME> && rm -rf <PATH>`; git backend `git worktree remove --force <PATH>`) and rerun. |
| **Verify** | `test -f .git/index && test ! -L .git/index`; `git status` shows your expected state; a swarm `--dry-run` passes. |

### The run stops because a filtered file looks modified (e.g. Git LFS)

| | |
|---|---|
| **Symptom** | A loop or swarm stops (fail closed) reporting a modified file that you did not change, in a repository using clean/smudge filters such as Git LFS. |
| **Cause** | wgm's host-side git never runs repository-configured commands (filter drivers, diff drivers/textconv, `diff.external`, credential helpers, pager, editor; hooks, fsmonitor and transports too). A filtered file whose timestamp changed can therefore look modified to it. |
| **Recovery** | Run `git status` yourself once in the checkout (it runs your filters and refreshes the index), then rerun. |
| **Verify** | `git status --short` is clean for that file; the rerun passes the check. |

### "pointers were redirected" (git pointer files changed)

| | |
|---|---|
| **Symptom** | Exit 2 naming a pointer file — the worktree `.git` file, the admin `gitdir` or `commondir`, or `objects/info/alternates` — with "pointers were redirected … nothing was scanned or opened". Swarm retains the redirected lane. |
| **Cause** | After a contained command, wgm compares these pointers with the values pinned before the first container, before its host side touches git at all. The agent changed one. |
| **Recovery** | (If a worktree admin dir itself became a symlink, pointer files are not read — exit 2 first: remove the link and move the real admin dir back.) Restore the original content: a worktree's admin `commondir` is normally `../..`; `.git` in a worktree reads `gitdir: <COMMON>/worktrees/<NAME>`; `alternates` back to its pinned content (or absent). Review the lane's work, then rerun. |
| **Verify** | `cat <FILE>` shows the restored value; `git -C <LANE> rev-parse --git-common-dir` prints the parent's common dir; the rerun passes. |

### A git-dir entry is a symlink or special file

| | |
|---|---|
| **Symptom** | Exit 2 naming a path inside a git dir (index, `HEAD`, a ref, `packed-refs`, a log, `info`, a worktree admin dir, `objects`); swarm retains the affected lane and exits non-zero. |
| **Cause** | Before running git on a repository or worktree, wgm checks without following symlinks that every entry git may open is a regular file or a real directory. A symlink or special file there (typically agent-written) fails closed. |
| **Recovery** | Inspect `ls -l <PATH>`. Remove the **link itself** — `rm <PATH>` — never its target. For an index, then run `git reset` in that checkout. Review the lane/iteration's work and rerun. |
| **Verify** | `test ! -L <PATH>`; `git status` works in that checkout; the rerun passes. **Residual:** a sibling lane running at the same moment could swap an entry between wgm's check and git's open; closing that needs a shared-git quiescence protocol (follow-up). |

## Validation

### The satisfaction score never reaches the threshold

| | |
|---|---|
| **Symptom** | The loop keeps iterating without converging. |
| **Cause** | Usually an ambiguous scenario expectation, or a demo path that is not actually wired up. |
| **Resolution** | Inspect the weakest scenario recorded in `IMPLEMENTATION_PLAN.md`. Sharpen the expectation, or split the task. For a rough prototype, lower `--threshold`. See [Scenarios and scoring](../agent/scenarios-and-scoring.md). |

### Container scenarios fail to start

| | |
|---|---|
| **Symptom** | Scenario validation cannot reach the service. |
| **Cause** | No container engine, or a port or readiness problem. |
| **Resolution** | Confirm `podman` or `docker` is installed, or pass `--container` explicitly. Check the readiness wait and that the published port is free. See [Containers](containers.md). |

### A service running in WSL is unreachable from Windows

| | |
|---|---|
| **Symptom** | The service answers `curl` inside WSL, but a Windows browser, editor, or CLI cannot connect (and a WebSocket never opens). |
| **Cause** | It is published on **WSL loopback**. The guest's `127.0.0.1` is not the Windows host's, so a loopback-only bind is invisible across the interop boundary. A Linux-side probe cannot see this at all — it never crosses the boundary. |
| **Resolution** | Publish on **all interfaces** (`0.0.0.0` / `-p`) and connect from Windows to the distro's **routed WSL IPv4** — the `src` that `ip -4 -o route get 1.1.1.1` reports on the unique default-route device, not the first global address on `lo` or a container bridge. That route lookup only consults the table; it does not send traffic. Keep `localhost` for same-side probes only. Confirm it from Windows, not from WSL: on a Windows+WSL host run `bash scripts/test-wsl-windows-boundary.sh`, which contrasts both binds with a real Windows-origin probe. On any other host it exits 3 with the reason. See [Containers](containers.md#reaching-a-service-across-an-os-boundary) and `[learn]` issue [agent-frontier/wgm#101](https://github.com/agent-frontier/wgm/issues/101). |

### A test passes alone but fails in the suite

| | |
|---|---|
| **Symptom** | An isolated re-run is green; the full gate is red. |
| **Cause** | The difference between the two runs *is* the bug — commonly a teardown race where buffered output is discarded before a consumer reads it. |
| **Resolution** | **Do not treat the isolated pass as the answer.** Inspect lifecycle ordering, synchronize producer teardown to consumer acknowledgement, stress the exact test repeatedly, then rerun the complete gate. Only a green full suite clears it. |

### A gate reports missing artifacts that clearly exist

| | |
|---|---|
| **Symptom** | An isolated staged build reports a missing artifact. |
| **Cause** | A globally shared build-target override was inherited, so the build emitted outside the stage-local path the verifier checks. This is a harness misconfiguration, not a product defect. |
| **Resolution** | Clear or scope ambient target overrides before the build, or set an explicit stage-local target directory. Record the clean rerun **separately** from product failures. |

## Artifacts

### wgm wrote files under .wgm/ instead of the repository root

| | |
|---|---|
| **Symptom** | Artifacts appear in `.wgm/` rather than where you expected. |
| **Cause** | The safety rule: when the root already has `AGENTS.md`, `IMPLEMENTATION_PLAN.md`, or `specs/`, wgm writes its own copies under `.wgm/` so it never clobbers yours. |
| **Resolution** | Working as intended. See [Artifacts](../reference/artifacts.md). |

### wgm asked about reporting lessons upstream

| | |
|---|---|
| **Symptom** | A consent question appears before anything else on a new project. |
| **Cause** | `.github/wgm-hive.yml` does not exist yet. Its absence is what defines "a new project" for consent. |
| **Resolution** | Answer once. The file is written either way and never asked about again. `consent: false` keeps every lesson local. See [the consent file](../reference/artifacts.md). |

## Contributing

### make validate fails on a fresh clone

| | |
|---|---|
| **Symptom** | `make validate` is red before you changed anything. |
| **Cause** | Usually a missing development dependency. |
| **Resolution** | Check [Requirements](../get-started/requirements.md): `shellcheck` is needed for `lint`, `jq` for `docs`, and jj 0.46.0+ for the real workspace harness. |

### check-evals.sh exits 2

| | |
|---|---|
| **Symptom** | The evals gate exits `2` rather than `0` or `1`. |
| **Cause** | `jq` is not on `PATH`. Exit `2` means misconfigured, distinct from `1` for a real failure. |
| **Resolution** | Install `jq`. |

### The docs check reports a broken link that looks fine

| | |
|---|---|
| **Symptom** | `check-docs.sh` flags a link you can follow in your editor. |
| **Cause** | Links are resolved **relative to the file containing them**. A path that works from the repository root often does not work from a nested page. |
| **Resolution** | Count the `../` hops from the linking file. From `docs/reference/`, the repository root is two levels up. |

## Still stuck?

- Re-read the protocol in [`SKILL.md`](../../SKILL.md). Every gate prints a `Gate check:` block
  naming exactly which item failed.
- Look up the exact flag in the [reference](../reference/README.md).
- Open an issue. If wgm behaved *plausibly but wrongly*, use the heuristic report template — that
  kind of report is how its heuristics improve.
