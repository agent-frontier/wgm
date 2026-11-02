---
section: Backpressure
order: 166
pin: references/ralph-loop.md :: **Run the CI runner's pinned ShellCheck version locally.**
---
- **Heuristic:** run the CI runner's pinned ShellCheck locally and annotate indirect invocations.
  **Why:** newer local ShellCheck can be silent where CI fails with SC2317.
  **Provenance:** `[learn]` issue #166. **Landed in:** `references/ralph-loop.md`.
