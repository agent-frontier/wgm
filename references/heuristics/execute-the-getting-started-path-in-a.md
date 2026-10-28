---
section: Backpressure
order: 11
---
- **Heuristic:** execute the getting-started path in a clean environment, and treat capability-style
  prerequisites as incomplete until a command or exact link satisfies them.
  **Why:** accuracy audits can confirm "provide a database" is true while a newcomer still has no way
  to start one; only doing the journey exposes missing commands, options, and circular prerequisites.
  **Provenance:** `[learn]` issue #91. **Landed in:** `references/docs-audit.md` ·
  `docs/get-started/README.md`.
