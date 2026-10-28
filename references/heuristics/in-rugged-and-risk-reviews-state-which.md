---
section: Review
order: 8
---
- **Heuristic:** in rugged and risk reviews, state which rung of the five-step certainty ladder each
  load-bearing claim reached (prose assertion → cited `file:line` → walked failure trace → executed
  script/test against real code → reproduced in running system), and keep empirical claims below
  rung 4 as `UNKNOWN`.
  **Why:** a plausible prose explanation of why a change is safe reads as convincing whether or not
  it is true; naming the rung separates code-reading confidence from executed proof. **Provenance:**
  external research, `backnotprop/pstack`'s `skills/blast-radius/SKILL.md`. **Landed in:**
  `companions/rugged/SKILL.md` (Phase 5 — Field test).
