---
section: Review
order: 7
---
- **Heuristic:** give a task's first candidate both full review passes; a later fix round that
  changes only the lines its findings named may take a scoped re-review, in which a non-author
  reviewer checks every changed line against those findings while the relevant checks rerun green.
  **Why:** a full re-review of a two-line fix costs a whole review cycle, while closing it unchecked
  throws the review away; a wider change, or a fix the checker wrote, still earns both full passes.
  **Provenance:** `[learn]` issue #121. **Landed in:** `references/subagents.md` (Dispatch points).
