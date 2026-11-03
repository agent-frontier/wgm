---
section: Backpressure
order: 173
pin: references/ralph-loop.md :: **Test capacity bounds one byte past the limit.**
---
- **Heuristic:** build valid retained input so the next operation exceeds the documented capacity
  bound by exactly one byte; a record-multiple (aligned) fill is not enough. Assert output size and
  retained-generation bytes, kill a raised-limit mutant, and count compilation failures separately
  from assertion kills.
  **Why:** an aligned fill passes while a small limit increase survives.
  **Provenance:** `[learn]` issue #173. **Landed in:** `references/ralph-loop.md`.
