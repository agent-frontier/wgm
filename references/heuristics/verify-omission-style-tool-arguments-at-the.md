---
section: Backpressure
order: 17
---
- **Heuristic:** verify omission-style tool arguments at the real model→adapter→CLI boundary, and
  normalize only the contract-documented sentinel for that exact field.
  **Why:** real models can serialize "missing" as a sentinel string that a fake harness never emits; global normalization erases
  legitimate values and hides invalid input instead of rejecting it. **Provenance:** `[learn]`
  issue #106. **Landed in:** `references/ralph-loop.md` (Backpressure in depth) ·
  `references/subagents.md` · `evals/evals.json`.
