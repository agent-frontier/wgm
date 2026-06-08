# Implementation plan

> The shared state of the loop. Prioritized; the agent always takes the most important `pending`
> task. Update every iteration so a fresh agent could resume from this file alone.
> Status values: `pending | in_progress | done | blocked`.

## Now (next up)

### T1 — <objective in one sentence>
- **files/areas:** <where the change likely lives>
- **validation:** <command that proves it, e.g. `npm test -- t1` / `pytest -k t1`>
- **acceptance:** <what "done" means for this task>
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
before Ship/Handoff. A task may be marked `done` only if its validation command exited 0.
-->
