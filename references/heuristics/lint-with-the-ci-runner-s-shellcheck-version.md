---
section: Backpressure
order: 166
pin: references/ralph-loop.md :: **Match the CI runner's observed ShellCheck version locally.**
---
- **Heuristic:** match the CI runner's observed ShellCheck version locally (from the CI log or the
  runner image's package list), reproduce with that exact release, and annotate indirect
  invocations. Call it a pin only where a pin exists.
  **Why:** newer local ShellCheck can be silent where CI fails with SC2317.
  **Provenance:** `[learn]` issue #166; corrected by docs-audit A7. **Landed in:** `references/ralph-loop.md`.
