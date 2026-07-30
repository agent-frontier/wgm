# Telemetry — measuring a build without lying about it

A parallel build invites a very specific kind of self-deception: sum every lane's lifetime, divide
by wall time, and report a large multiple as "speedup." That number is almost always wrong, and it
is wrong in the flattering direction. This note fixes the vocabulary and says what to report.

It exists because the same measurement defect recurred across several dogfood runs
(`references/heuristics.md`; `[learn]` issues #70, #72, #74, #84, #85). The implementation lives in
[`../scripts/loop.sh`](../scripts/loop.sh) (per-turn ledger) and
[`../scripts/swarm.sh`](../scripts/swarm.sh) (the aggregate summary).

## Three clocks, never conflated

| Clock | What it measures | Honest label |
|---|---|---|
| **Wall time** | Parent elapsed, triage → the ready-to-test gate | Exact |
| **Lane time (allocated)** | Σ lane lifetimes (launch → lane's accepted head) | **Capacity upper bound** |
| **Agent time (active)** | Σ per-*turn* durations | **Measured lower bound** |

The gap between allocated and active is **parked time** — a lane that is alive but between turns,
waiting on review, or blocked. It is real capacity and worth reporting, but it is not work.

> **The rule that matters: never call parked-lane lifetime "agent-hours."** A 32-lane run that
> reserved 42.4 lane-hours while most specialist lanes idled between baseline analysis, review, and
> docs audit did roughly nothing like 42.4 hours of work. Lane lifetime is what you *allocated*;
> turn durations are what you *spent*.

Static per-lane utilization is not a substitute for agent-level timing either: when a swarm expands
elastically, later agents never roll into the original lane rows, and utilization computed over
those fixed rows understates the run badly (one measured case: 21% static utilization against a
2.66x observed concurrency ratio).

## Freeze the measurement at the gate
Stop the wall clock when the **deterministic ready-to-test gate passes** — before metrics export,
report writing, and handoff overhead. Otherwise the act of measuring inflates the thing measured,
and runs become incomparable depending on how much reporting each did afterward.

## Report missing telemetry; never estimate it
If turns finished without durations, say so:

- publish **timed vs missing** turn counts and **completed vs started** lane counts;
- label the active total explicitly as a **lower bound**;
- when active durations are unavailable *entirely*, publish only wall time, lane allocation, and
  turn count — and say the active figure is unavailable.

An estimate silently replaces a measurement with a guess, and the guess is what gets quoted later.
`swarm.sh` prints the counts and appends a lower-bound warning whenever anything is unmetered.

## Ratios are heuristics, not claims
Two are worth reporting, both labelled:

- **Lifecycle effectiveness** = active agent time ÷ lifecycle wall time. Includes coordination.
- **Implementation parallelism** = allocated lane time ÷ the longest lane (the critical path).
  Excludes coordination, so the pair separates coordination overhead from lane execution.

Neither is billing data, and neither is a causal speedup claim — you did not run the counterfactual
serial build. From one run they are operational heuristics for capacity planning and nothing more.
Report **peak concurrency** and the **critical path** alongside them; a high ratio with a critical
path equal to wall time means one lane gated everything and the parallelism bought little.

## What the tooling records
- **Per turn** (`.wgm/metrics.tsv`, on by default; `--metrics off` to disable): `start_timestamp`,
  `end_timestamp`, `iter`, `mode`, `agent`, `duration_s`, `plan_changed`, `result`, `cost`,
  `parent`. The `parent` column comes from `$WGM_PARENT_TASK`, which `swarm.sh` sets per lane, so
  every turn attributes to the lane that ran it.
- **Per lane** (`.wgm/metrics/<prefix>-<n>.tsv`): the same ledger, written into the **parent**
  worktree so the summary survives `--cleanup` removing the lane's worktree.
- **Per run**: the `== swarm telemetry ==` block — the three clocks, parked time, lane and turn
  counts, peak concurrency, critical path, and the two labelled ratios.

Timestamps are recorded automatically for every turn precisely so a later swarm expansion cannot be
undercounted by a ledger that only knew about the original lanes.

## Reporting at Ship/Handoff
Ship/Handoff reports wall time, active agent time, timed vs unmetered counts, peak concurrency, and
critical-path duration (`../SKILL.md` Phase 4). Report **coordination and audit rework separately**
from implementation, along with the final-gate first-pass rate and holdout satisfaction: a run that
reached the gate quickly but failed it three times is not the same run as one that passed first try,
and a single blended ratio hides the difference.

## Cross-links
[`ralph-loop.md`](ralph-loop.md) (the loop these clocks measure) ·
[`scoring.md`](scoring.md) (satisfaction scoring, the other number a run reports) ·
[`subagents.md`](subagents.md) (lane/role dispatch) ·
[`heuristics.md`](heuristics.md) (the curated ledger these lessons came from).
