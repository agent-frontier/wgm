---
section: Backpressure
order: 15
---
- **Heuristic:** when a validation adapter rewrites an intermediary's published command, model its
  actual escape semantics and execute the transformed command under the real shell with
  hostile-but-valid inputs.
  **Why:** idealized string replacement can report green while the real intermediary or shell changes
  meaning on `%`, `\`, or path characters the adapter ignored. **Provenance:** `[learn]` issue #112.
  **Landed in:** `references/ralph-loop.md` (Backpressure in depth) · `references/subagents.md` ·
  `evals/evals.json`.
