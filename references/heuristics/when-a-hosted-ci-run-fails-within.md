---
section: Backpressure
order: 26
---
- **Heuristic:** when a hosted CI run fails within seconds and no job starts, read its annotations
  for a billing or spending-limit block before editing workflow files.
  **Why:** that signature is an account block, neither a pass nor a source failure; disclose it
  and keep the exact local gates authoritative. **Provenance:** `[learn]` issue #130. **Landed
  in:** `references/ralph-loop.md` (Backpressure in depth).
