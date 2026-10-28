---
section: Triage & Grill
order: 4
---
- **Heuristic:** run a cross-requirement consistency scan before leaving Grill: contradictions,
  vague thresholds, and undefined referenced concepts must be resolved or made measurable.
  **Why:** requirements that look fine in isolation can still be mutually impossible or vague enough
  to fork the implementation once design starts. **Provenance:** external research, Kiro's
  `kiro.dev/docs/specs/analyze-requirements/`. **Landed in:** `references/grilling.md`
  (Grill-exit gate).
