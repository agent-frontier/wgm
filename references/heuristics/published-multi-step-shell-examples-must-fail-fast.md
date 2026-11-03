---
section: Review
order: 164
pin: references/docs-audit.md :: **Multi-step examples must fail fast.**
---
- **Heuristic:** encode fail-fast dependencies in published shell examples and test the exact fence with a forced prerequisite failure.
  **Why:** STOP comments and final exit checks let downstream commands run.
  **Provenance:** `[learn]` issue #164. **Landed in:** `references/docs-audit.md`.
