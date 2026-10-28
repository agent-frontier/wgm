---
section: Backpressure
order: 24
pin: references/ralph-loop.md :: **Prove guards with mutants.**
---
- **Heuristic:** prove each claimed guard, branch, and ordering with a mutant (a deliberate small
  break) that a test fails on; a compile error is not a kill, and every survivor is proven
  equivalent or recorded as a gap.
  **Why:** green tests passed code whose retry branch never fired, and a harness bug silently
  turned mutants into deletions. **Provenance:** `[learn]` issue #126. **Landed in:**
  `references/ralph-loop.md` (Backpressure in depth).
