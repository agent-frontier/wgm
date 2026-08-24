# Implementation plan

> The shared state of the loop. Prioritized; the agent always takes the most important `pending`
> task. Update every iteration so a fresh agent could resume from this file alone.
> Status values: `pending | in_progress | done | blocked`.

## Convergence
- **Satisfaction threshold:** <default 95> — overall holdout-scenario score to reach before Ship.
- **Stratified order:** converge tier 1 → 2 → 3 (see `references/scoring.md`).
- **Scenarios:** <`scenarios/` or `.wgm/scenarios/`> (judged in Validate/Review; never read in Implement).

## Ruggedness gate (required — every track)
Exactly one verdict per run; record it here, not just in a transcript.

| When | Scope | Verdict | Date | Produced by | Follow-up task |
|---|---|---|---|---|---|
| Plan-exit | <plan + specs> | <RUGGED \| FRAGILE \| UNKNOWN> | <yyyy-mm-dd> | <`/rugged plan` \| inline rubric (Quick track \| companion unavailable)> | <none \| T#> |
| Review (T#) | <that task's diff> | <RUGGED \| FRAGILE \| UNKNOWN> | <yyyy-mm-dd> | <`/rugged review` \| inline rubric (companion unavailable)> | <none \| T#> |

- **RUGGED** passes. **FRAGILE** blocks: add a remediation task below and re-run the gate after it.
  **UNKNOWN** blocks: add a validation-signal task that creates the missing deterministic
  field/stress evidence — UNKNOWN is never "probably fine".
- Plan-exit judges *plan readiness* (every load-bearing claim maps to an exact runnable
  field/stress/recovery check); real implementation evidence belongs to the Review verdict.
- If `/rugged` is not discoverable, run the embedded five-step rubric inline and record the missing
  capability in "Produced by". An absent companion is a recorded fallback, never a pass.
- Quick track: same rubric, inline, recorded in one line here. See `SKILL.md`, "The ruggedness gate".

## Now (next up)

### T1 — <objective in one sentence>
- **files/areas:** <where the change likely lives>
- **validation:** <command that proves it, e.g. `npm test -- t1` / `pytest -k t1`>
- **acceptance:** <what "done" means for this task>
- **scenarios/tier:** <holdout scenario(s) this advances, + tier 1–3 — optional>
- **rugged:** <verdict recorded at Review — RUGGED required before `done`>
- **status:** pending
- **notes:** <results, blockers, links — filled in as you go>

### T2 — <objective>
- **files/areas:** <...>
- **validation:** <...>
- **acceptance:** <...>
- **status:** pending
- **notes:**

## Later (backlog)
- <task idea> — <one-line objective>

### TZ — Demo validation (required before Ship/Handoff)
- **files/areas:** <the end-to-end entry point, e.g. CLI/app/route>
- **validation:** <command that runs the spec's smallest end-to-end demo path>
- **acceptance:** the demo path from the spec runs green end-to-end
- **status:** pending
- **notes:**

## Done
- <completed task> — <what proved it>

---
<!--
First task rule: if no validation signal exists yet in this project, make T1 = "create a
validation signal" (a failing test, a build/type-check command, or an HTTP probe) before any
feature work. The plan must also include the TZ demo-validation task above, which must pass
before Ship/Handoff. **Quick-track exception:** if this build is genuinely one task (one fix, one
validation command, no multi-step demo path), that task's own validation command *is* the
demo-validation task — a separate TZ task is not required, and this file may be a single short
paragraph instead of the full template (`references/heuristics.md`, `[learn]` issue #56). A task
may be marked `done` only if its validation command exited 0 **and** its Review ruggedness verdict
is RUGGED (FRAGILE → remediation task; UNKNOWN → validation-signal task; no verdict → gate FAIL).
-->
