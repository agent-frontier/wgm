# wgm CLI reference: swarm.sh

`scripts/swarm.sh` fans the Ralph loop out across **parallel streams**, each in a separate working
directory and Git branch. Git worktrees are the default; `--backend jj` opts into colocated Jujutsu
workspaces. Both run the existing Git-committing `scripts/loop.sh build`; you review and merge the
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
- To try jj, install [Jujutsu](https://docs.jj-vcs.dev/latest/install-and-setup/) 0.46.0 or newer
  and Git with `git worktree add --orphan` (normally upstream Git 2.42+; vendor backports work).
  The jj backend checks the capability before creating a lane, including on `--dry-run`; it fails
  with guidance rather than silently falling back. The default Git backend does not need this check.

## Try the jj backend

> **Experimental:** real jj 0.46.0, deterministic agents, and a small real-agent bakeoff were
> exercised in disposable Linux fixtures. Production use, macOS, Windows-origin behavior, and
> throughput gains are not established. Failed or unverified lanes are retained for inspection; see
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
with the project's consent; do not continue if a path is reported as unignored.

```bash
# Run from the already-colocated project root. This check creates no jj metadata there.
jj --version
git --version  # informative; the swarm checks --orphan capability, including backports
jj --ignore-working-copy workspace root
git status --short
for path in .wgm/.wgm-ignore-probe .wgm/metrics/.wgm-ignore-probe \
  .wgm/swarm-logs/.wgm-ignore-probe .wgm/memories.md .wgm/worktrees/.wgm-ignore-probe; do
  git check-ignore --no-index -q -- "$path" || printf 'Must be ignored: %s\n' "$path"
done
test -f IMPLEMENTATION_PLAN.md || test -f .wgm/IMPLEMENTATION_PLAN.md
TASKS_FILE="$(mktemp /tmp/wgm-tasks.XXXXXX)" # outside the clean checkout
printf 'implement slice A\nimplement slice B\n' > "$TASKS_FILE"
WGM_SKILL_ROOT="${WGM_SKILL_ROOT:-$HOME/.agents/skills/wgm}"
"$WGM_SKILL_ROOT/scripts/swarm.sh" --backend jj --tasks "$TASKS_FILE" --max-iterations 1 --cleanup -- copilot --allow-all-tools -p
rm -f "$TASKS_FILE"
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
| `--backend git\|jj` | `git` | Git worktrees, or explicitly selected colocated jj workspaces. |
| `--worktree-dir DIR` | `.wgm/worktrees` | Base directory for lanes; in-project jj directories must be Git-ignored. |
| `--gates FILE` | auto-detect `wgm.yml` or `.wgm/gates.yml` | Forward the chosen project-gate file to every lane. |
| `--cleanup` | off | Remove only verified successful, clean lanes. Failed, dirty, ignored-data, or unverified lanes are retained; branches remain. |
| `--dry-run` | off | Print the plan; create no worktrees and run nothing. |
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

## Lane safety

Each lane's request is pinned to its absolute worktree path and expected branch. The host checks
path, branch, and tip before/after agent turns and before its own commit; it also fingerprints the
parent's tracked changes, index, non-runtime untracked path status, and non-lane refs. Parent drift
stops the run and retains lanes. The jj backend additionally checks workspace registration and the
Git store. Both backends refuse ambient Git repository/index/object-store/namespace overrides such
as `GIT_INDEX_FILE`, `GIT_DIR`, and `GIT_WORK_TREE`; unset them before running. A guard is **not a sandbox**: it cannot prevent arbitrary agent commands, detect a change
reverted between checks, or notice content changes to an already-untracked parent file whose status
stays the same. Use a sandbox for agents you do not trust.

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

| Code | Meaning |
|---|---|
| `0` | Every stream finished successfully. |
| `1` | A lane, identity/parent check, setup, artifact, or cleanup failed; inspect `.wgm/swarm-logs/*.log` and retained lanes. |
| `2` | Misconfiguration: bad flag, missing prerequisites, non-colocated/dirty jj parent, or unsafe jj paths. |
| `130` | Graceful interruption; active lane process groups are stopped and remaining lanes retained for inspection. |

## What to do next

- [loop.sh reference](cli-loop.md) — the per-stream runner and its flags.
- [Telemetry](../../references/telemetry.md) — reading the swarm summary without fooling yourself.
- [Subagents](../../references/subagents.md) — lane hygiene and the role swarm.
