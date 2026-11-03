---
section: Backpressure
order: 157
pin: references/ralph-loop.md :: **Make inspection tri-state, never a negated probe.**
---
- **Heuristic:** make process and state inspection tri-state (exit 1 absent, 0 alive, other uninspectable) and use a bracket pattern against self-match.
  **Why:** `! pgrep` and empty-output checks read a failed probe as clean.
  **Provenance:** `[learn]` issue #157. **Landed in:** `references/ralph-loop.md`.
