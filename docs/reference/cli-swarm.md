# wgm CLI reference: swarm.sh

`scripts/swarm.sh` fans the Ralph loop out across **parallel streams**, each in a separate working
directory and Git branch. The default backend is **jj** (colocated Jujutsu workspaces) when the repository
is already a jj repository and jj 0.46.0+ and Git `worktree add --orphan` are available; otherwise swarm
prints one visible notice and falls back to **Git worktrees** (`--backend git` selects them explicitly).
Both run the existing Git-committing `scripts/loop.sh build`, and **each lane's loop runs sandboxed in its
own container** mounting that lane's workspace (see [Sandbox](#sandbox-default)); you review and merge the
branches yourself. Isolation prevents live file contention, not integration conflicts.

**Note:** This is parallelism across *tasks*. It is distinct from the **role swarm** — the twelve
role-specialized subagents described in [subagents](../../references/subagents.md), which is
parallelism across *reviewer roles* within one task.

## Syntax

```bash
WGM_SKILL_ROOT="${WGM_SKILL_ROOT:-$HOME/.agents/skills/wgm}"
"$WGM_SKILL_ROOT/scripts/swarm.sh" --tasks FILE [FLAGS] -- AGENT_ARGV...
"$WGM_SKILL_ROOT/scripts/swarm.sh" -n COUNT     [FLAGS] -- AGENT_ARGV...
```

Run the installed skill path from the target project's root. A checkout-local `./scripts/swarm.sh`
also works when you are developing wgm itself.

## Before you begin

- The project must be a git repository with an `IMPLEMENTATION_PLAN.md` in the root or `.wgm/`.
  Run `/wgm plan` first if you do not have one.
- Configure an agent, either with `$WGM_AGENT` or as argv after `--`.
- Partition your work into disjoint slices. This is not optional advice — see
  [Partitioning rules](#partitioning-rules).
- For the default jj backend, the checkout must already be a colocated jj repository (swarm never runs
  `jj git init` for you) and you need [Jujutsu](https://docs.jj-vcs.dev/latest/install-and-setup/) 0.46.0
  or newer and Git with `git worktree add --orphan` (normally upstream Git 2.42+; vendor backports work).
  The capability is checked before any lane is created, including on `--dry-run`.
- For the sandbox, install Podman or Docker (or accept the one-time question; headless runs fail closed
  — see [Sandbox](#sandbox-default)).

### Backend prerequisite outcomes

| Situation | Default (no `--backend`) | Explicit `--backend jj` | Explicit `--backend git` |
|---|---|---|---|
| Not a jj repository / not colocated | one notice, **Git backend** | exit 2 with guidance | Git backend |
| jj missing or older than 0.46.0 | one notice, **Git backend** | exit 2 with guidance | Git backend |
| Git lacks `worktree add --orphan` | one notice, **Git backend** | exit 2 with guidance | Git backend |
| Colocated jj, tooling present | **jj backend** | jj backend | Git backend |
| jj backend selected, parent dirty, or `.wgm` runtime / lane path not ignored | exit 2, no lane created | exit 2, no lane created | n/a |

Swarm never initializes jj; colocation stays your explicit, local decision. A dirty parent or unignored
path is a configuration fault to fix (or pass `--backend git`), not a reason for silent fallback.

## Try the jj backend

> **Experimental:** real jj 0.46.0, deterministic agents, and a small real-agent bakeoff were
> exercised in disposable Linux fixtures. Throughput gains, macOS and Windows-origin behavior are not
> established, and it is the default only where its prerequisites hold (see the table above). Failed or unverified lanes are retained for inspection; see
> the [decision record](../plans/2026-10-29_JJ_WORKSPACES_EVALUATION.md).

Start in a **clean** project-root Git checkout that you have chosen to use with jj. If it is not
already a jj workspace, `jj git init --colocate` explicitly initializes one in that checkout and
changes local repository metadata; wgm never runs it for you. Follow the [jj setup
instructions](https://docs.jj-vcs.dev/latest/install-and-setup/) and configure Git commit identity.

The parent must have no tracked or non-ignored untracked changes. Its `.wgm` runtime paths
(`.wgm/metrics/`, `.wgm/swarm-logs/`, and `.wgm/memories.md`) must be Git-ignored; an in-project
`--worktree-dir` must also be ignored. An existing tracked `.wgm` file remains tracked and protected.
For example, a project may choose to ignore `/.wgm/` locally or in `.gitignore` while deliberately
keeping already-tracked files; do not silently change a project's ignore policy. Put the task file
inside an ignored path or outside the checkout.

Before running, verify that an `IMPLEMENTATION_PLAN.md` exists in the root or `.wgm/`, that the
checkout is already colocated, and that every runtime path below is ignored. Add missing rules only
with the project's consent. The block below runs in a subshell with `set -eu`: **each prerequisite
stops the chain with its own non-zero status** (and a diagnostic), swarm only starts when all hold, and
the temporary task file is removed by an `EXIT` trap that **keeps swarm's exit status**. Paste it as-is;
the last line prints the status and leaves the block's own status equal to it (no bare `exit`, so pasting into an interactive shell is safe).

```bash
# Run from the already-colocated project root. This check creates no jj metadata there.
(
  set -eu
  jj --version
  git --version  # informative; the swarm checks --orphan capability, including backports
  jj --ignore-working-copy workspace root
  st="$(git status --short)"   # standalone assignment: a failing git stops the block with its own status
  test -z "$st" || { echo 'parent is not clean' >&2; printf '%s\n' "$st" >&2; exit 1; }
  for path in .wgm/.wgm-ignore-probe .wgm/metrics/.wgm-ignore-probe \
    .wgm/swarm-logs/.wgm-ignore-probe .wgm/memories.md .wgm/worktrees/.wgm-ignore-probe; do
    git check-ignore --no-index -q -- "$path" || { printf 'Must be ignored: %s\n' "$path" >&2; exit 1; }
  done
  test -f IMPLEMENTATION_PLAN.md || test -f .wgm/IMPLEMENTATION_PLAN.md || { echo 'no IMPLEMENTATION_PLAN.md' >&2; exit 1; }
  TASKS_FILE="$(mktemp /tmp/wgm-tasks.XXXXXX)" # outside the clean checkout
  trap 'rm -f "$TASKS_FILE"' EXIT              # cleanup never changes the exit status
  printf 'implement slice A\nimplement slice B\n' > "$TASKS_FILE"
  WGM_SKILL_ROOT="${WGM_SKILL_ROOT:-$HOME/.agents/skills/wgm}"
  "$WGM_SKILL_ROOT/scripts/swarm.sh" --backend jj --tasks "$TASKS_FILE" --max-iterations 1 --cleanup -- copilot --allow-all-tools -p
)
rc=$?; echo "swarm block exit status: $rc"; (exit "$rc")   # block status = subshell status
```

For **each custom lane directory inside the project**, check its own ignore rule before using
`--worktree-dir` (external directories do not need a project ignore rule):

```bash
LANE_DIR='.wgm/custom-lanes'
git check-ignore --no-index -q -- "$LANE_DIR/.wgm-ignore-probe" || printf 'Must be ignored: %s\n' "$LANE_DIR"
# Then add: --worktree-dir "$LANE_DIR"
```

This is a **hybrid**, not a native-jj commit runner: jj creates colocated workspaces (and their
underlying Git worktrees), then the loop commits to `wgm/swarm/N` using Git. While a lane runs, do
not use `jj new`, rebase, switch branches, or commit in that lane: moving Git HEAD or the branch tip
fails its guard. The orchestrator uses a per-command `snapshot.auto-track="none()"` override for jj
workspace creation/removal; it does not change your jj configuration. jj may refresh metadata in
the clean parent's Git index during removal; its staged tree is checked in the fixture. See the
[comparison and measurement boundary](../plans/2026-10-29_JJ_WORKSPACES_EVALUATION.md).

## Flags

| Flag | Default | Description |
|---|---|---|
| `--tasks FILE` | — | One stream per non-empty, non-`#` line. Each line becomes that stream's `--request` scope. |
| `-n`, `--count N` | — | Run N identical streams. Ignored when `--tasks` is given. Useful for racing or diversity. |
| `--max-iterations N` | `0` | Per-stream iteration cap. `0` runs until each stream self-stops. |
| `--prefix NAME` | `wgm/swarm` | Branch and workspace/worktree name prefix. |
| `--backend git\|jj` | `jj` when the repo is colocated jj and jj ≥ 0.46.0 + `worktree add --orphan` exist, else `git` (one visible notice) | Colocated jj workspaces, or Git worktrees. An explicit `--backend jj` keeps the hard failure when its prerequisites are missing. |
| `--devcontainer` | sandbox on by default | Force the sandbox for every lane: no working engine → exit 2. |
| `--no-devcontainer` | off | Opt out: lanes' agents run on the host, labelled `sandbox: OFF (<REASON>)`. Contradicting `--devcontainer` → exit 2. |
| `--devcontainer-image TAG` | record / shared base | Image for every lane's container. |
| `--worktree-dir DIR` | `.wgm/worktrees` | Base directory for lanes; in-project jj directories must be Git-ignored. |
| `--gates FILE` | auto-detect `wgm.yml` or `.wgm/gates.yml` | Forward the chosen project-gate file to every lane. Each gate is handed to the sandbox separately (never joined with `&&`) and runs as `bash -c "$gate"`; only one quote pair wrapping the whole `gates.yml` entry is stripped (the same rule as `loop.sh`). |
| `--cleanup` | off | Remove only verified successful, clean lanes. Failed, dirty, ignored-data, or unverified lanes are retained; branches remain. |
| `--dry-run` | off | Print the plan and the sandbox decision (or the unresolved prerequisite); create no workspaces or worktrees, prompt for nothing, write no record, run no smoke or readiness probe and launch no container. |
| `-h`, `--help` | — | Show usage. |

Everything after `--` is forwarded verbatim to each stream's `loop.sh`. Streams always run with
`--commit`, so each branch carries its work.

## Partitioning rules

These are defaults that materially affect whether a swarm succeeds.

| Rule | Why it matters |
|---|---|
| Give every stream a **disjoint, non-overlapping file set** | Disjoint lanes make consolidation an octopus merge with zero conflicts. Overlapping lanes risk something worse than a conflict: one lane silently reverting a sibling's edits. |
| Limit each batch to your host's **safe concurrency** | Every ready lane is launched concurrently; there is no built-in queue or backfill. Run remaining tasks in later batches. |
| Prefer a **full-shell agent** for lanes with nested-path deliverables | A constrained file-writer that cannot create intermediate directories does not fail loudly. It flattens paths, hides content in bootstrap scripts, and stops committing. |
| Run the **consolidation gate** after merging | Cross-link integrity and UTF-8 double-encoding are defects no single lane can see. `scripts/check-docs.sh` catches both. |

## Sandbox (default)

**Host vs container.** The host creates, integrates and removes the jj workspaces / Git worktrees (jj is
not in the shared image and its Git is too old for `worktree add --orphan`), runs the guards, git
bookkeeping, memory consolidation and telemetry, and uses Git *plumbing only* on agent-written trees (with
hooks, fsmonitor and transports disabled). The one exception is the parent guard, which runs host
porcelain on **your parent checkout only** — no container ever mounts the parent checkout — with the same neutralizing
protections. Host git protections are set in the environment of wgm's whole host process tree (`GIT_CONFIG_COUNT`/`KEY`/`VALUE` for `core.fsmonitor=false`, `core.hooksPath=/dev/null` and `protocol.allow=never`; `GIT_ALLOW_PROTOCOL` set and empty; `GIT_NO_LAZY_FETCH=1`; `GIT_TERMINAL_PROMPT=0`), so helper scripts, lane loops and git spawned by jj inherit them; they are never passed into containers. Consequence: wgm's host-side git never runs a repository-configured command — hooks, fsmonitor, transports, filter drivers (clean/smudge/process), diff drivers (textconv/command), `diff.external`, credential helpers, the pager and the editor are all disabled for wgm's own host git calls. Trade-off: a file under a filter (e.g. Git LFS) whose timestamp changed may look modified to wgm and the run stops (fail closed); run `git status` yourself once in the checkout to refresh the index, then rerun. Each lane's **container** runs the agent, the gates, and the git commits (the
repository's real hooks run there, contained). A lane workspace's `.git` is a file pointing at the
repository's common git dir outside the lane folder, so each lane container also mounts that dir at the
same absolute path (read-only `config`, `config.worktree`, `hooks/`, `info/`, `objects/info/` on top); the
run fails visibly if it is unreachable. Mount inventory, credentials and record:
[devcontainers](../operator/devcontainers.md).

**Preflight never uses the parent.** Swarm's preflight (agent readiness, capability probe, gate smoke) runs in a
throwaway *preflight workspace* created at the parent's HEAD with the same backend (same git store, so the same approval
record applies) and removed afterwards — also on refusal and on interruption. SIGINT/SIGTERM stops the preflight promptly
(its containers are removed by name with zero grace) and removes the workspace; if removal cannot be verified, swarm
prints `retained preflight workspace <NAME> at <PATH> — recover: jj workspace forget <NAME> && rm -rf <PATH>` (git
backend: `git worktree remove --force <PATH>`) and exits non-zero. Swarm refuses a parent index that is not a regular file (e.g. replaced by a symlink in the shared git dir): exit 2 naming
it, with the preflight workspace retained and its recovery line; see [troubleshooting](../operator/troubleshooting.md#swarm-refuses-the-parent-index).
wgm copies the parent index only without following symlinks, into a private directory outside every mount. Lanes never mount the parent either.

**Pointers first.** After every contained command, before wgm's host side touches git at all, it compares the git pointer files — the worktree `.git` file, the admin `gitdir` and `commondir`, and `objects/info/alternates` — with the values pinned before the first container; any change exits 2 at once, naming the file ("pointers were redirected … nothing was scanned or opened"). Swarm checks every lane against the parent's git common dir captured at start and retains a redirected lane. Recovery: restore the pointer's original content (a worktree's admin `commondir` is normally `../..`; `.git` in a worktree reads `gitdir: <COMMON>/worktrees/<NAME>`), then rerun. Only after this check passes does the entry check below run.

**Containment loss is terminal for the whole swarm.** If any lane (or the preflight) cannot confirm that one of its containers is gone, or swarm's own container sweep cannot confirm absence, swarm stops: it prints every `retained container <NAME>` with its recovery (`podman rm -f -t 0 <NAME>` / `docker rm -f <NAME>`, then verify absence), reports every lane and the preflight workspace as retained with their recovery lines, exits non-zero, and does **not** inspect lanes, consolidate memories or tear anything down — even with `--cleanup`. Recovery order: remove the containers and verify they are gone, then inspect/merge the lanes, then clean up (`jj workspace forget <NAME>` / `git worktree remove`), then rerun.

**Git-dir entry checks.** Before wgm's host side runs git on a repository or worktree it checks, without following symlinks, that every git-dir entry git may open (index, HEAD, refs, packed-refs, logs, info, worktree admin dirs, objects) is a regular file or a real directory; a symlink or special file → exit 2 naming the path (swarm retains the affected lane and exits non-zero). Recovery: remove the link itself (`rm <PATH>`), never its target; for an index then run `git reset` in that checkout; rerun. **Residual risk:** an agent in a sibling lane running at the same moment could swap such an entry between the check and git's open; closing that requires a shared-git quiescence protocol (recorded follow-up).


**One decision, handed to every lane.** `swarm.sh` runs `sandbox.sh preflight` **once**, interactively when
possible, *before creating any lane*; a refusal (exit 2) creates no workspace, branch, worktree directory or
lane. It then writes the complete decision (sandbox/engine/reason/agents/mounts/env/image and any
interactive "proceed anyway" smoke override) to a run-scoped `0600` file in a `0700` directory under
`$TMPDIR` — outside the project and every mount, never mounted — and passes `WGM_SANDBOX_DECISION=<PATH>` to
each lane; a lane's `loop.sh` uses it verbatim (no preflight, no prompt) and swarm deletes it on exit. If a
gate smoke fails and you choose to proceed, each lane's own iteration gate still runs and still fails its
iteration; a headless rerun without the override exits 2 with zero lanes.

Mounts are derived at every launch from the working tree; the decision file carries only credentials, env
names, the image and approved extra mounts (one naming project/common-dir/overlay mounts is refused).

**What it does and does not give you.** Separate containers do **not** give each lane its own Git
authority: all lanes share one git store, and there is no quiescence protocol yet, so a sibling can change
shared refs between two host reads, and lanes can write the parent's index in the shared git dir, so the
parent guard's verdict can be skewed (no code runs from it). A hostile agent can change this repository's content and history and
so influence tools that later process it outside wgm. The sandbox protects your home directory,
credentials and other projects, not the repository. After its lanes exit, swarm removes any container still
named with its lanes' prefixes and prints `retained container <NAME>` for any it cannot confirm gone. If the engine cannot be
inspected or a lane container cannot be confirmed removed, it prints `cleanup unverified: retained container
wgm-<KEY8>-<LOOP PID>-*` per lane loop and exits non-zero (unless the run already failed);
on SIGINT/SIGTERM swarm TERMs every lane group and a supervised preflight, waits up to 24 s (cleanup deadline 16 s + 8 s margin) for their bounded container cleanup and retained-handle reporting, then KILLs what remains and reaps every name left in the shared live-container registry, printing the exact `retained container <NAME>` for any it cannot confirm gone; an interrupted swarm can therefore take up to ~24 s to exit.
Host scratch: `loop.sh` keeps its host-side temp files in a run-private `0700` directory outside every mount (under
`$TMPDIR`, or `/tmp` when `$TMPDIR` is inside the project), and swarm gives each lane a private `TMPDIR` outside the
checkout so lane temp files never look like parent-checkout drift.
Telemetry reports `sandbox: on (<ENGINE>) — <N>/<M> lanes ran the agent in a container` or
`sandbox: OFF (<REASON>)`. Field-validated on Linux/Podman; macOS and WSL rely on the readiness probe to
fail closed.

## Lane safety

Each lane's request is pinned to its absolute worktree path and expected branch. The host checks
path, branch, and tip before/after agent turns and before its own commit; it also fingerprints the
parent's tracked changes, index, non-runtime untracked path status, and non-lane refs. Parent drift
stops the run and retains lanes. The jj backend additionally checks workspace registration and the
Git store. Both backends refuse ambient Git repository/index/object-store/namespace overrides such
as `GIT_INDEX_FILE`, `GIT_DIR`, and `GIT_WORK_TREE`; unset them before running. A guard is **not a sandbox**: it cannot prevent arbitrary agent commands, detect a change
reverted between checks, or notice content changes to an already-untracked parent file whose status
stays the same. The default container sandbox is what confines an agent's file access; with
`--no-devcontainer` only the guards remain, so avoid it for agents you do not trust.

**Caution:** This guard exists because of a real failure. In a 32-lane run, several lanes executed
git from the parent checkout on a later turn and one advanced local `main`. If this happens to you,
never repair it by discarding commits — preserve reachability first (keep the accidental commits on
the intended branch plus an explicit recovery branch), then restore the intended checkout.

## Telemetry output

After the streams finish, `swarm.sh` prints a `== swarm telemetry ==` block. It reports **three
clocks that must never be conflated**:

| Metric | Meaning | Honest label |
|---|---|---|
| `wall time (parent)` | Parent elapsed, frozen at the ready-to-test gate | Exact |
| `lane time (allocated)` | Sum of lane lifetimes | **Capacity upper bound** — includes parked time |
| `agent time (active)` | Sum of per-turn durations from the lanes' ledgers | **Measured lower bound** |
| `parked time` | Allocated minus active | Real capacity, but not work |
| `peak concurrency` | Most lanes alive at any one instant | Exact |
| `critical path` | The longest single lane | Exact |
| `lifecycle effectiveness` | active ÷ wall | Operational heuristic |
| `implementation parallelism` | allocated ÷ longest lane | Operational heuristic |

**Caution:** Never call parked-lane lifetime "agent-hours." A lane alive between turns still burns
lifetime, so summing lifetimes and dividing by wall time produces a flattering number that is not
work done. Both ratios are operational heuristics from one run — not billing data, and not a causal
speedup claim. See [Telemetry](../../references/telemetry.md).

Per-lane ledgers are written to `.wgm/metrics/PREFIX-N.tsv` in the **parent** worktree, so the
summary survives `--cleanup` removing the lane's worktree.

## Merging and cleanup

To merge a stream's work:

```bash
git merge wgm/swarm/1
```

`--cleanup` preserves a failed, dirty, renamed, detached, or otherwise unverified lane, and also
retains successful lanes containing ignored files outside `.wgm`/`.jj` or modified tracked `.wgm`
files. Before manual cleanup, inspect the lane and preserve anything valuable, including ignored
files. Successful cleanup can delete untracked/ignored `.wgm` scratch and jj metadata.

```bash
git worktree list
git -C .wgm/worktrees/wgm-swarm-1 status --short
# jj backend: inspect the registration, then only after saving work remove the named workspace
jj --ignore-working-copy workspace list
jj workspace remove wgm-swarm-1
# Git backend instead: git worktree remove .wgm/worktrees/wgm-swarm-1
# Only after review, if intentionally discarding the branch:
git branch -D wgm/swarm/1
```

`jj workspace remove` can delete ignored files; the operation log is not a backup for them. If a
cleanup command fails, it may already have removed the workspace: inspect both registration and
branch before retrying. `make clean-worktrees` is a **Git-only** convenience target for the wgm
source checkout: it removes clean registered worktrees under `.wgm/worktrees/`, keeps all branches,
and refuses a checkout containing `.jj`. Git may remove ignored files even without `--force`, so
inspect them first; this is not an automatic recovery step.

## After every run

`swarm.sh` consolidates memories only from successful, identity-verified lanes when the parent has
not drifted, then hands the consolidated file to `scripts/harvest-hive.sh` if any were copied.
Failed/unverified lane memories remain in the retained lane for manual review and are not harvested.
The courier owns consent and anonymization; a harvest hiccup never fails the swarm. See
[Self-improvement](../../references/self-improvement.md).

After each lane exits, `swarm.sh` verifies the artifact rather than trusting the process status:
`status=ok, commits=0` is converted to a hard failure. Read the corresponding `.wgm/swarm-logs/`
entry, fix the agent's write/tool permission or task scope, and rerun before merging any branch.

## Exit codes

Exit **2 is not only "no lane was created"**: a preflight refusal creates none, but a post-run trust loss also exits 2 **with every lane
retained**, while a post-run containment loss exits **1** with every lane retained. Use the phase table to know what exists afterwards.

| Code | Meaning |
|---|---|
| `0` | Every stream finished successfully. |
| `1` | A lane, identity/parent check, setup, artifact, or cleanup failed; inspect `.wgm/swarm-logs/*.log` and retained lanes. See the phase table for containment loss. |
| `2` | Misconfiguration (bad flag, missing prerequisites, explicit `--backend jj` without colocation/jj/`--orphan`, dirty jj parent, unsafe jj paths), a sandbox preflight refusal, or a trust loss — see the phase table. |
| `130` | Interrupted by **SIGINT** at any phase (preflight, lane preparation, lane execution, result inspection, `--cleanup`). Can take up to ~24 s: see [Sandbox](#sandbox-default). |
| `143` | Interrupted by **SIGTERM** at any phase, with the same handlers and retention as SIGINT. |

### Exact exit status per terminal phase, and what each retains

Unless noted, no host git/jj command runs after the loss.

| Phase | Exit | Messages / handles printed | Retained |
|---|---|---|---|
| Preflight refusal (engine, credentials, mount, readiness or smoke refused by `sandbox.sh preflight`, including a failed headless approval) | **2** | `swarm: sandbox preflight refused; no lane was created.` plus the preflight's own fix-it text | Nothing: the throwaway preflight workspace is torn down and verified gone first. If that verification fails: `retained preflight workspace <NAME> at <PATH> — recover: jj workspace forget <NAME> && rm -rf <PATH>` (git backend: `git worktree remove --force <PATH>`), still exit 2 |
| Preflight containment loss (a container's absence cannot be confirmed) | **2** | `retained container <NAME> — recover: podman rm -f -t 0 <NAME>` (docker: `docker rm -f <NAME>`) for each, then `retained preflight workspace <NAME> at <PATH> — recover: …` | The unconfirmed container(s), the preflight workspace and its private dir (and the registry dir, `sandbox: ownership record kept`); no jj/git teardown |
| Preflight trust loss (executable config, hooks, includes, pointers or links of the shared store changed) | **2** | `✗ trust lost in the shared git store during the preflight …`, `trust lost <PATH>` or the verifier's message, `recovery: …`, `retained preflight workspace <NAME> at <PATH> — recover: …` | The preflight workspace; no jj/git run against the store |
| Preflight succeeded but its workspace teardown cannot be verified | **1** (**2** if the index/pins were tampered) | `swarm: the preflight workspace could not be removed; no lane was created.` plus the `retained preflight workspace …` line | The preflight workspace; no lane created |
| Post-run containment loss (any lane or sweep container unconfirmed) | **1** | `✗ containment lost: …`; `retained container <NAME> — recover: <ENGINE> rm -f <NAME>` per container; `retained lane N at <DIR> (branch <B> kept) — recover: after removing the container(s) above: jj workspace forget <NAME> && rm -rf <DIR>` (git backend: `git worktree remove --force <DIR>`) per lane | Every started lane (workspace and branch) and the containers; no git-dir scan, parent inspection, lane-file inspection, memory consolidation, `--cleanup` teardown or telemetry |
| Post-run trust loss (a lane loop's trust-lost file is non-empty, or swarm's pin verification fails) — also when detected during dispatch (no lane started) | **2** | `✗ trust lost in the shared git store …`; `trust lost <PATH>` line(s) and the verifier's message; `recovery: restore the named path from a known-good copy … then re-run.`; `retained lane N at <DIR> (branch <B> kept) — recover: after the restore above: jj workspace forget <NAME> && rm -rf <DIR>` | Every prepared lane (workspace and branch); no further host git/jj (no inspection, consolidation or cleanup) |
| **SIGINT** — at any phase: during the preflight, lane preparation, lane execution, result inspection or `--cleanup` | **130** | `Interrupted: stopping active lane groups; remaining workspaces and branches are retained for inspection.`; `retained container <NAME>` for any container not confirmed gone; during the preflight the workspace is torn down or its `retained preflight workspace …` line is printed | Lane workspaces and branches (never auto-removed on interrupt); active lane groups get 24 s to clean up their containers before KILL |
| **SIGTERM** — at any phase, same handlers | **143** | Same as SIGINT | Same as SIGINT |
| Ordinary lane failures / dirty retained lanes | **1** | per-lane `✗ stream …` lines | The failed or dirty lanes and their branches |

Containment loss takes precedence over trust loss when both occurred (it is checked first). A signal that arrives while the preflight
workspace is being torn down is remembered and honoured (130/143) only after the teardown finished. A fully green run exits 0, or 1 if the
preflight workspace teardown ended unverifiable. Recovery order is in
[troubleshooting](../operator/troubleshooting.md#swarm-stopped-on-containment-loss-retained-containers-lanes-and-preflight-workspace).

## What to do next

- [loop.sh reference](cli-loop.md) — the per-stream runner and its flags.
- [Telemetry](../../references/telemetry.md) — reading the swarm summary without fooling yourself.
- [Subagents](../../references/subagents.md) — lane hygiene and the role swarm.
