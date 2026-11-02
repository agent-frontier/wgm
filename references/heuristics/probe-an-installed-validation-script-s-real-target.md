---
section: Backpressure
order: 161
pin: references/ralph-loop.md :: **Probe an installed validation script's real target.**
---
- **Heuristic:** probe the actual target before adopting an installed validation script, and preserve the original failure as origin evidence.
  **Why:** installed scripts can bind to their own distribution root.
  **Provenance:** `[learn]` issue #161. **Landed in:** `references/ralph-loop.md`.
