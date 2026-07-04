# loop.sh cost ceiling (--max-cost)

**Date:** 2026-07-04 · **Status:** shipping via PR to `main`.

## Problem

`scripts/loop.sh` already guards unattended runs against runaway *time* (`--max-runtime-seconds`,
`--idle-timeout`) and runaway *failure* (`--max-retries`, `--max-consecutive-failures`), and it can
already **measure** cost per iteration (`--metrics` + `--cost-cmd`) — but nothing stops the loop
because of it. An operator who sets a long unattended Ralph-full run has no equivalent of
`--max-runtime-seconds` for spend: the loop will happily keep calling the agent all night, however
much that costs. This exact gap was flagged as an open follow-up in the original competitive-analysis
roadmap: `docs/plans/2026-06-16_PLAN.md`, "item 7 follow-ups" — *"API spend/cost ceilings with
real-time tracking... candidates for `loop.sh` once a host-agnostic signal exists."* The
host-agnostic signal (`--cost-cmd`) has existed since that doc was written; the ceiling did not.

## What shipped

- **`scripts/loop.sh`**: a new `--max-cost N` flag (default `0` = unlimited, unchanged behavior).
  - `record_metrics()` now accumulates a running `CUM_COST` total from `--cost-cmd`'s output on
    *every* iteration, independent of whether `--metrics FILE` is also set (previously cost was only
    computed at all when a metrics file was configured).
  - A build-mode check (alongside the existing idle-timeout check) stops the loop once
    `CUM_COST >= MAX_COST`, printing `Reached max cost (X >= Y)`.
  - Non-numeric `--max-cost` values are rejected at parse time (exit 2), consistent with the script's
    other numeric flags — but unlike the strictly-integer flags, `--max-cost` accepts decimals
    (`^[0-9]+(\.[0-9]+)?$`), since a cost figure is often fractional.
  - Setting `--max-cost` without `--cost-cmd` prints an explicit startup warning (the ceiling can
    never be evaluated) rather than silently doing nothing.
  - `--dry-run` surfaces `max_cost=` alongside `metrics=`/`cost_cmd=` so an operator can confirm the
    ceiling before an unattended run.
- **`scripts/test-loop.sh`**: 4 new cases (16 → 20 total) — the dry-run surfacing, a *real*
  (non-dry-run) run that halts at the exact right iteration against a stub `--cost-cmd`, the
  no-`--cost-cmd` warning, the non-numeric rejection, and confirmation that the default (`0`) never
  halts early.
- **Docs**: a new "Cost ceiling" subsection in `docs/operator/running-the-loop.md` (right after the
  existing Metrics ledger section it depends on), plus a `README.md` capabilities-bullet mention.

## Decisions

- **Float arithmetic via `awk`**, not `bc` — `awk` is available everywhere bash is; `bc` is not
  always installed. All cost-ceiling comparisons (`CUM_COST >= MAX_COST`, the "is the ceiling even
  active" check) are single `awk 'BEGIN{...}'` one-liners.
- **Cost accumulation decoupled from `--metrics`.** The original `record_metrics()` computed `cost`
  only when a metrics file was configured; `--max-cost` needed to work standalone, so cost
  computation now happens unconditionally whenever `--cost-cmd` is set, with the metrics-file-write
  still gated separately.
- **Scoped to `build` mode**, matching `--idle-timeout` and checkpointing — single-phase modes always
  run exactly one iteration regardless, so a cost ceiling has nothing to guard there.
- **Corrected a wrong assumption mid-build:** the initial spec assumed `scripts/swarm.sh` streams
  would inherit `--max-cost` "for free" via flag passthrough. Checking `swarm.sh`'s actual invocation
  (`"$LOOP" build "$MAXIT" "${reqflag[@]}" --commit -- "${AGENT_ARGV[@]}"`) showed this is false — it
  forwards only its own curated flags plus the agent argv, not arbitrary `loop.sh` flags. Per-stream
  or aggregate swarm-level cost capping is recorded as a genuine, separate follow-up rather than
  something this change already provides.

## Validation

`bash -n` + `shellcheck` on `scripts/loop.sh` (clean), `bash scripts/test-loop.sh` (20/20, was 16/20
before this change), `make validate` (shellcheck, check-docs, install/loop/swarm harnesses),
`skills-ref validate wgm`, and `actionlint` — all green.

**Demo validation (the real proof):** test case 17 runs the actual loop (not a dry-run) with a stub
agent that always "succeeds" and a stub `--cost-cmd 'echo 5'` plus `--max-cost 12`; it halts after
exactly 3 iterations (cumulative 5+5+5=15 ≥ 12) instead of continuing to its 10-iteration cap — proof
the ceiling works end-to-end, not just that the flag parses.
