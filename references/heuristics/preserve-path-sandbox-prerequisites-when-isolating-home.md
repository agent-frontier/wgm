---
section: Backpressure
order: 145
pin: references/validation-env.md :: **Isolating HOME must keep path-sandbox prerequisites.**
pin: references/validation-env.md :: **Restore read-only prerequisites (procedure).**
---
- **Heuristic:** when isolating `HOME`, inventory HOME-relative companion repositories during
  preflight and restore verified read-only copies inside the isolation; never copy credentials or
  runtime state, never weaken the sandbox or assertions, re-run affected cases then the full gate.
  **Why:** isolation can remove legitimate prerequisites, failing sandbox cases before their logic.
  **Provenance:** `[learn]` issue #145. **Landed in:** `references/validation-env.md`.
