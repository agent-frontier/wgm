---
section: Token economy
order: 137
pin: references/ralph-loop.md :: Flush multimodal inspections within 2 actions.
---
- **Heuristic:** never read back a file you just wrote or edited in the same turn, and flush
  visual/multimodal/browser inspections to disk after at most 2 view actions.
  **Why:** a just-written file is already in active context, and unrecorded multimodal observations
  evaporate as soon as the session rotates or compacts. **Provenance:** external research,
  `OthmanAdi/planning-with-files`. **Landed in:** `references/ralph-loop.md` (Tool-output budget).
