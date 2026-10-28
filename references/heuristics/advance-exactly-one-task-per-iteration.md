---
section: Loop discipline
order: 1
---
- **Heuristic:** advance exactly one task per iteration and write handoff-quality state before
  stopping. **Why:** a fresh context must be able to resume from the plan alone.
  **Provenance:** Ralph loop. **Landed in:** `SKILL.md` Iteration-exit gate.
