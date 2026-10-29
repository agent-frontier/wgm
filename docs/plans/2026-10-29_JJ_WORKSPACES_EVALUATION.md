# Git worktrees and Jujutsu workspaces — decision record

**Decision (2026-10-29):** Encourage contributors and interested operators to explore Jujutsu
(`jj`), and provide an explicit, experimental `swarm.sh --backend jj`. Keep Git worktrees as the
portable default and Git branches/commits as the current loop's integration contract. Neither
installing wgm nor selecting the default backend requires jj; contributing to wgm's full local test
suite does. Existing checkouts are never converted automatically.

## Why compare them?

wgm needs multiple independent working directories, recoverable lane identity, reviewable results,
and safe failure/cleanup with both human and agent operators. Jujutsu is promising for revising and
composing parallel changes, but a tool change alone does not partition tasks, settle semantic
collisions, or establish a speedup.

| Concern | Git worktrees | Jujutsu workspaces |
|---|---|---|
| Isolation | Separate working directories share a Git repository; the swarm uses a branch per lane. | Separate working directories share a jj repository, each with its own working-copy change. A **colocated** jj workspace also creates a Git worktree. |
| Working changes | Git exposes an index and explicit commits. | jj snapshots the working copy into a change and tracks its operation history; untracked files can be auto-tracked unless ignored or configured otherwise. |
| Parallel integration | Merge/rebase branches and resolve conflicts; existing Git hosting and checks apply. | Changes can be rearranged and conflicts represented in revisions. Conflicts still need explicit resolution and review. |
| Recovery | Git refs, reflogs, and worktrees are familiar to many teams. | Change identities and the operation log/undo can aid recovery, but they are not backups for ignored files and may affect shared workspace state. |
| Cost and compatibility | Git is already required by the external swarm and broadly available. | An additional tool and learning curve; version and colocated Git behavior matter. Git is still required by wgm's current loop. |

## Evidence and boundary

- On Linux with **jj 0.46.0** and Git, `bash scripts/test-jj-swarm.sh` runs real jj commands in
  disposable repositories with fake agents. It creates two colocated workspaces, runs the actual
  Git-backed loop, preserves review branches, and tests collision, drift, interruption, cleanup, and
  recovery paths. The harness requires jj and makes no provider or network call. The guard reads a
  private Git index copy; jj's own workspace removal may refresh the clean parent's index metadata,
  while the fixture checks that its staged tree remains the same.
- The same harness contains a **separate native-jj spike**, not a swarm backend: two non-colocated
  workspace changes conflict in an explicit `jj new` merge; the fixture resolves the file and uses
  `jj undo` to restore a subsequent operation. This proves that small local scenario, not automatic
  conflict resolution or a production journey.
- A colocated `jj new` can move Git HEAD to a detached state. The shipped `--backend jj` therefore
  uses jj only to create/remove workspaces; `loop.sh` still stages and commits with Git. Do not run
  jj operations that move a lane's working copy/HEAD while its loop is active. The host checks lane
  identity and parent drift, but those checks are **not a sandbox**.
- The default Git path does not invoke jj. The jj lifecycle uses a per-command
  `snapshot.auto-track="none()"` override and requires a clean, explicitly colocated parent plus
  ignored runtime paths. It does not silently convert, merge, push, or replace Git workflows.
- At this initial decision, no comparative throughput, cost, or developer-productivity benchmark
  had been run. The later local real-agent fixture below does not establish a production speedup or
  macOS, Windows-origin, or future-version evidence.

## Subsequent Linux real-agent fixture

A later local bakeoff used the same live Pi/provider/model and identical baseline across 12
synthetic swarm runs (two per backend at 1, 2, and 3 lanes) plus one two-lane run per backend on a
disposable wgm source snapshot. All 24 synthetic branches and four repository branches (two per
backend) passed independent hidden tests; each integration passed. Graceful interruption after real edits retained and replayed
four patches. The sample is too small, cache/order-sensitive, and Linux-only to establish a
performance advantage or justify changing the default; raw local transcripts are not distributed.

The bookworm pilot exposed Git 2.39.5 lacking `git worktree add --orphan`, which jj 0.46.0 needs for
colocated workspace creation. The jj backend now checks that capability before mutation (normally
available in upstream Git 2.42+; compatible backports are accepted). The default Git backend does
not require this jj-only capability. A disposable offline fixture exercised real Git 2.39.5 with
jj 0.46.0 and verified both the early refusal and a successful Git-only lane.

## Alternatives and consequences

1. **Replace Git with native jj now — deferred.** The current loop, commit ownership, Stage 10,
   checks, and handoff all assume Git. A true native jj loop needs its own ownership/commit,
   integration, recovery, and compatibility contract, not just a workspace switch.
2. **Ignore jj — rejected.** It would prevent users already using jj from exercising its workspace
   and operation model with wgm and would leave the comparison untested.
3. **Hybrid, opt-in workspace lifecycle — chosen.** It is reversible and preserves Git artifacts,
   at the cost of a new dependency for contributors, extra lifecycle guards, and manual cleanup of
   ambiguous/failed lanes. It is an exploration path, not a claim that two isolation layers are
   stacked or that jj is already faster.

Revisit the default only after representative real-agent workloads on supported platforms show a
repeatable improvement against the same Git-worktree baseline, with no safety, compatibility, or
recovery regression. Disable or narrow the jj backend if its real workspace/branch identity or
cleanup checks fail on a supported jj release; retain existing work and fall back only after an
operator inspects it. Native jj commits require a separately scoped and validated design.

## Sources

- [Git worktree documentation](https://git-scm.com/docs/git-worktree)
- [jj 0.46 working copies and workspaces](https://docs.jj-vcs.dev/v0.46.0/working-copy/#workspaces)
- [jj 0.46 Git colocation](https://docs.jj-vcs.dev/v0.46.0/git-compatibility/#colocated-jujutsugit-workspaces)
- [jj 0.46 conflicts](https://docs.jj-vcs.dev/v0.46.0/conflicts/)
- [jj 0.46 operation log](https://docs.jj-vcs.dev/v0.46.0/operation-log/)
- [wgm swarm CLI and recovery](../reference/cli-swarm.md)
