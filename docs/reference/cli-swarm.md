# wgm CLI reference: swarm.sh

`scripts/swarm.sh` fans the Ralph loop out across **parallel streams**, each isolated in its own
`git worktree` on its own branch so they never collide. Each stream runs `scripts/loop.sh build`.
When the streams finish, you review and merge the branches yourself.

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

## Flags

| Flag | Default | Description |
|---|---|---|
| `--tasks FILE` | — | One stream per non-empty, non-`#` line. Each line becomes that stream's `--request` scope. |
| `-n`, `--count N` | — | Run N identical streams. Ignored when `--tasks` is given. Useful for racing or diversity. |
| `--max-iterations N` | `0` | Per-stream iteration cap. `0` runs until each stream self-stops. |
| `--prefix NAME` | `wgm/swarm` | Branch and worktree name prefix. |
| `--worktree-dir DIR` | `.wgm/worktrees` | Base directory for the worktrees. Gitignored by wgm. |
| `--cleanup` | off | Remove the worktree directories when done. **Branches are kept** for merging. |
| `--dry-run` | off | Print the plan; create no worktrees and run nothing. |
| `-h`, `--help` | — | Show usage. |

Everything after `--` is forwarded verbatim to each stream's `loop.sh`. Streams always run with
`--commit`, so each branch carries its work.

## Partitioning rules

These are defaults that materially affect whether a swarm succeeds.

| Rule | Why it matters |
|---|---|
| Give every stream a **disjoint, non-overlapping file set** | Disjoint lanes make consolidation an octopus merge with zero conflicts. Overlapping lanes risk something worse than a conflict: one lane silently reverting a sibling's edits. |
| Size the swarm to your host's **concurrency cap**, and treat the remainder as backfill | Hosts cap concurrent background agents. N lanes does not mean N simultaneous agents; queued lanes should start as running lanes go idle. |
| Prefer a **full-shell agent** for lanes with nested-path deliverables | A constrained file-writer that cannot create intermediate directories does not fail loudly. It flattens paths, hides content in bootstrap scripts, and stops committing. |
| Run the **consolidation gate** after merging | Cross-link integrity and UTF-8 double-encoding are defects no single lane can see. `scripts/check-docs.sh` catches both. |

## Lane safety

Each lane's request is pinned to its absolute worktree path and expected branch, and the lane
**refuses to run** if the guard finds it anywhere else.

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

To drop a stream you do not want:

```bash
git worktree remove .wgm/worktrees/wgm-swarm-1
git branch -D wgm/swarm/1
```

To clear one leftover worktree and branch:

```bash
git worktree remove --force .wgm/worktrees/wgm-swarm-1
git branch -D wgm/swarm/1
```

For the wgm source checkout, `make clean-worktrees` remains a convenience wrapper around this
target-project-independent Git cleanup.

## After every run

`swarm.sh` always consolidates each stream's `.wgm/memories.md` back into the invoking worktree,
then hands the result to `scripts/harvest-hive.sh`. That dispatch is unconditional and safe to
ignore: the courier owns every consent and anonymization decision itself, and a harvest hiccup never
fails the swarm. See [Self-improvement](../../references/self-improvement.md).

After each lane exits, `swarm.sh` verifies the artifact rather than trusting the process status:
`status=ok, commits=0` is converted to a hard failure. Read the corresponding `.wgm/swarm-logs/`
entry, fix the agent's write/tool permission or task scope, and rerun before merging any branch.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Every stream finished successfully. |
| `1` | One or more streams failed (see `.wgm/swarm-logs/*.log`), a lane produced zero commits, or no streams started. |
| `2` | Misconfiguration: not a git repository, bad flag, missing `--tasks` file, or no agent configured. |

## What to do next

- [loop.sh reference](cli-loop.md) — the per-stream runner and its flags.
- [Telemetry](../../references/telemetry.md) — reading the swarm summary without fooling yourself.
- [Subagents](../../references/subagents.md) — lane hygiene and the role swarm.
