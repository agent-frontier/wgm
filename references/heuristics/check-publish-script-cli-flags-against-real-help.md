---
section: Backpressure
order: 158
pin: references/ralph-loop.md :: **Check every CLI flag a publish/release script passes
---
- **Heuristic:** grep the real `--help` for every flag a publish script passes, with a bogus-flag counterfactual.
  **Why:** fake executables on PATH cannot see flag drift.
  **Provenance:** `[learn]` issue #158. **Landed in:** `references/ralph-loop.md`.
