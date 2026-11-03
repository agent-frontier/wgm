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
Three are worth reporting, all labelled:

- **Lifecycle effectiveness** = active agent time ÷ lifecycle wall time. Includes coordination.
- **Implementation parallelism** = allocated lane time ÷ the longest lane (the critical path).
  Excludes coordination, so the pair separates coordination overhead from lane execution.
- **Retry / loop-tax ratio** = failed or retried turns (`result=fail` or `plan_changed=0`) ÷ total
  turns. Exposes how much spend and time went into fix-and-retry churn versus first-pass progress
  (adapted from [`Keesan12/martin-loop`](https://github.com/Keesan12/martin-loop)'s loop-tax audit).

Neither is billing data, and neither is a causal speedup claim — you did not run the counterfactual
serial build. From one run they are operational heuristics for capacity planning and nothing more.
Report **peak concurrency** and the **critical path** alongside them; a high ratio with a critical
path equal to wall time means one lane gated everything and the parallelism bought little.

## What the tooling records
- **Per turn** (`.wgm/metrics.tsv`, on by default; `--metrics off` to disable): `start_timestamp`,
  `end_timestamp`, `iter`, `mode`, `agent`, `duration_s`, `plan_changed`, `result`, `cost`,
  `parent`. `result` is normally `ok` or `fail`; a build that reaches the configured repeated
  no-progress limit records `stall`. The `parent` column comes from `$WGM_PARENT_TASK`, which
  `swarm.sh` sets per lane, so every turn attributes to the lane that ran it.
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

## Efficiency report — first use and fields

`python3 scripts/telemetry.py report --ledger .wgm/telemetry/events.ndjson [--run ID] [--sessions DIR]... [--orchestrator-session FILE] [--baseline REPORT.json] [--provenance measured|reconstructed] [--json OUT] [--md OUT]` turns the event ledger plus pi session logs into the clocks above without inventing values; `record --ledger PATH KIND key=value ...` appends one event.

### First use — record a run, then report
Copy-pasteable; the ledger path is declared once, every event carries the same `run` id, and the run is only *complete* once the `verified` milestone names the expected `publication`.

```bash
L=.wgm/telemetry/events.ndjson; T="python3 scripts/telemetry.py"
$T record --ledger $L expect run=demo publication=pub-1                        # before the run starts
$T record --ledger $L estimate run=demo unit_class=learn units=2 human_hours=3 by=operator
$T record --ledger $L run run=demo edge=start label=demo
$T record --ledger $L span run=demo edge=start span=g1 cat=gate name=validate
$T record --ledger $L span run=demo edge=end span=g1 rc=0
$T record --ledger $L candidate run=demo sha=abc123 decision=accept
$T record --ledger $L unit run=demo id=u1 class=learn status=done
$T record --ledger $L milestone run=demo name=verified publication=pub-1
$T record --ledger $L run run=demo edge=end
$T report --ledger $L --run demo --json /tmp/demo.json --md /tmp/demo.md
```

Expect `clocks.complete: true` and `clocks.wall_basis: "verified"` (wall = run start to the `verified` milestone for `pub-1`; `window.accounting_end` is that instant). Drop the `verified` line and the report says `incomplete` (an `expect`ed publication is unverified) — or `ready-to-test` / `window` when nothing was `expect`ed; without a `run start` the wall basis is `unavailable`. Pass `--sessions DIR` (pi session logs) for agent time; without it agent measures are unavailable, not zero.

### Required fields per kind
Every event: `v`=1, `ts` ISO-8601, string `kind`, and a non-empty string `run` (the run it belongs to). In this table "string" = non-empty string (an empty string is never valid, including optional `sha`/`publication`), "integer" excludes booleans, "number" = finite and not boolean.

| `kind` | Required fields |
|---|---|
| `run` | `edge` ∈ start, end (optional `label`) |
| `phase` | `name` string, `edge` ∈ start, end |
| `span` | `span` string (the span id), `edge` ∈ start, end; start also `cat` string (optional `name`, `lane`, `session`); end also integer `rc` |
| `candidate` | `sha` string, `decision` ∈ accept, reject |
| `unit` | `id` string, `class` string, `status` string (only `done` counts) |
| `milestone` | `name` ∈ ready-to-test, merged, verified; `sha` and `publication`, when present, are strings |
| `expect` | `publication` string |
| `estimate` | `unit_class` string, `units` number > 0, `human_hours` number > 0, `by` string |

### Interpretation

**Efficiency report (`scripts/telemetry.py`).** **Ownership.** An event without a `run` is *unowned*: it belongs to no run, is excluded from every report and is counted once in `data_quality.unowned_events` (whole ledger, whichever run is selected). There are no intentional globals. Run selection: `--run`, else the only run in the ledger (several runs without `--run` is an error). **Validation.** Of the selected run's events one that fails its kind's required fields is *invalid*: excluded and counted in `data_quality.invalid_events`; unknown kinds are only `unknown_kinds`. A selected run with no valid events (none at all, or all invalid) exits 2 with a one-line stderr message naming the run and its invalid-event count (`0 invalid` when it has none; no report). `gates.unknown` counts gate spans whose valid start has no valid end (also in `unmatched_spans`): an unknown outcome is never counted as passed or failed. Span and phase edges pair in ledger (append) order, never by timestamp: an end appended after its start but timestamped earlier is a negative interval (counted, excluded), an end with no open start or a start still open is unmatched, and a repeated start for an open id replaces the earlier one (which is unmatched). Malformed lines, unowned/invalid/unknown events, unmatched edges, negative intervals, excluded and clipped turns, missing fields, duplicate session files and missing inputs are *counted* under `data_quality`, never repaired; untimed turns are reported as `agents.turns_untimed` and `orchestrator.turns_untimed`. Candidate counts are measured; first-pass yield, compression, implementation parallelism and candidate retry tax are all heuristics. **Wall basis** (`clocks.wall_basis`): `unavailable` when the selected run has no valid `run start`: nothing start-dependent is measured — `wall_s`, `window.accounting_end` and every `wall_to_*` are null, `complete` is false, per-class wall, compression and baseline factors are null/refused (`no run start`), no turn window is applied (agent turns are still parsed and reported), and estimates are `estimates.unverifiable` (reason `no run start`, no `factor_x`); `verified` when the run is complete (every `expect`ed publication has a `verified` milestone carrying its id; with no `expect`, at least one `verified`), wall = start to the last `verified`; `incomplete` when some expected publication is unverified (wall = run window, `missing_publications` lists them, baseline factors are refused); otherwise `ready-to-test` (wall = start to the ready milestone) if one exists, else `window` (run start to run end, else the last event). The shipped per-unit wall stops at the last `verified` publication, later than the freeze-at-the-ready-to-test-gate clock above; that earlier clock is still reported as `wall_to_ready_s` (with `wall_to_merged_s`, `wall_to_verified_s`), so quote the basis next to any wall figure. **Agent time and the one accounting window.** Agent time comes from session logs (measured, a lower bound): a turn is a user message up to the next user message, ending at its last message. Session figures use the SAME window as the wall: `[run start, accounting end]`, accounting end = run start + `clocks.wall_s`, reported as `window.accounting_end` (ISO-8601 UTC; null when the wall is unavailable). A timed turn that does not intersect the window is *excluded* (`excluded_turns`); one that crosses a window edge is *clipped*: only the overlap counts toward active time, per-lane active time and peak concurrency, while its usage (model, tool, tokens, cost) is counted in full; it counts once in `data_quality.clipped_turns` and as one timed turn. An untimed turn (nothing after the user message) counts iff its start lies inside the window. This applies to agents and orchestrator alike. A timed turn whose end precedes its start is excluded and counted in `data_quality.negative_intervals`. A `durationMs`, `totalTokens` or cost value that is not a finite number ≥ 0 is treated as missing (`missing_fields`, one per message) and adds nothing. Each session file is read once by real path (repeat sightings add to `duplicate_session_files`); the orchestrator file is never an agent input even under a `--sessions` dir, and is reported separately as `orchestrator{turns, turns_untimed, active_s, model_s, tool_s, tokens, cost}`, outside agent totals and peak concurrency; a `--sessions` path or orchestrator file that is absent or unreadable adds to `missing_inputs`. `agents.available` is true only when at least one agent session file was read; otherwise agent measures are null (Markdown says unavailable), not zero, and compression is null. Tokens and cost are measured from session usage fields, are not billing data. **Honest labels.** In the Markdown every line that prints an active-time figure says "lower bound" and every line that prints a cost or token figure says "session usage"; agent-work compression = (agent active + orchestrator model time) ÷ wall (heuristic); implementation parallelism = Σ per-lane agent-span lifetimes ÷ the longest (heuristic, capacity upper bound); candidate retry tax = rejected ÷ evaluated candidates (heuristic), a different ratio from the turn-based retry / loop-tax ratio above. **Per-class usage is whole-run:** every `per_class.<c>` row carries `usage_basis: "whole-run"`; per-unit agent active time, cost and tokens are WHOLE-RUN totals (agents and/or orchestrator) ÷ that class's units — not attributed to the class and not additive across classes — and every Markdown line printing one says "whole-run". Per-class wall divides the whole wall by that class's units and sets `shared_wall` when several classes ran. **Baseline.** Keep the `--json` report of a prior run per work class and pass it as `--baseline`. The factor (baseline ÷ current) is "Nx vs baseline under these boundaries"; it is neither a conservative bound nor an intrinsic improvement, and its VALUE is computed whenever both values are non-zero (descriptive). Comparability is per metric: `baseline.factors.<class>` = `{wall_per_unit_x, agent_active_per_unit_x, cost_per_unit_x, comparable: {wall, agent_active, cost}, not_comparable: {<metric>: [reason, …]} (false metrics only), baseline_provenance}`. *wall*: both runs complete, same wall basis, neither class row shared-wall. *agent_active*: wall's conditions AND both reports have `agents.available` true AND `agents.turns_untimed` 0. *cost*: wall's conditions AND both reports have `data_quality.missing_fields` 0 AND `clipped_turns` 0 AND both include an orchestrator object or both none. Each reason names the failed condition and side ("untimed turns (baseline)", "agents unavailable (current)", "missing usage fields (baseline)", "clipped turns (current)", "orchestrator inclusion differs", "wall basis differs", "shared wall (current)"); a baseline report that lacks the key needed to judge a condition gives "baseline coverage unknown" for that metric. Nothing is inferred: wall is judged only from the baseline's explicit boolean `clocks.complete`, its `clocks.wall_basis` and the class row's boolean `shared_wall` — a missing or non-boolean key gives "baseline coverage unknown" for wall and therefore for agent_active and cost too (completion is never inferred from `wall_basis`; a missing `shared_wall` is never read as false). Record `--provenance reconstructed` for a baseline rebuilt after the fact; it is carried into every factor and never presented as newly measured. Zero denominators give null factors plus a named refusal. **Estimates.** An `estimate` is *pre-registered* iff its `ts` ≤ the run start AND its line precedes the selected run's first `run start` event in the ledger (append order); a human-time factor is reported only for those. This is classification by timestamp and ledger order only — not proof of prior registration. An estimate with `ts` ≤ start but appended after the run start is `estimates.unverifiable` with a `reason` naming the ledger order ("backdated"); with no run start the reason is "no run start". Later estimates are listed as ignored. **No causal speedup, no billing claim:** none of these figures is either; no serial counterfactual was run.

## Cross-links
[`ralph-loop.md`](ralph-loop.md) (the loop these clocks measure) ·
[`scoring.md`](scoring.md) (satisfaction scoring, the other number a run reports) ·
[`subagents.md`](subagents.md) (lane/role dispatch) ·
[`heuristics.md`](heuristics.md) (the curated ledger these lessons came from).
