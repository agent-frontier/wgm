---
section: Backpressure
order: 8
---
- **Heuristic:** mark complete reference tables and reject blank or placeholder cells; derive
  constraints from validation logic rather than nearby constants.
  **Why:** a blank constraint cell looks valid to structural and style checks while the code hard-fails
  on the omitted bound. **Provenance:** `[learn]` issue #90. **Landed in:** `scripts/check-docs.sh`,
  `scripts/test-check-docs.sh`, `references/docs-audit.md`.
