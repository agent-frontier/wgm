---
section: Backpressure
order: 160
pin: references/ralph-loop.md :: **A green build is not capability evidence.**
---
- **Heuristic:** verify helper binaries and dynamic data in the shipped non-root runtime and assert the packaged check executed; keep execution separate from detection yield.
  **Why:** a zero-result scan can mean zero checks ran.
  **Provenance:** `[learn]` issue #160. **Landed in:** `references/ralph-loop.md`.
