---
section: Loop discipline
order: 6
---
- **Heuristic:** before running a task's full validation command, diff actually-touched files
  against its declared files/areas from `IMPLEMENTATION_PLAN.md` as a cheap pre-check.
  **Why:** a mismatch (e.g. a task scoped to `schema/` touching UI files) is an early signal of
  scope/spec drift — catching it before the validation budget is spent beats discovering it only
  after a full, possibly expensive run finishes. **Provenance:** external research,
  `saitarrun/devforge-ai`'s `ralph-loop` skill (its "Sentinel" health check). **Landed in:**
  `references/ralph-loop.md` (Backpressure in depth).
