---
section: Loop discipline
order: 180
pin: references/ralph-loop.md :: **Detach anything that outlives one tool call.**
---
- **Heuristic:** launch long gates in their own session with stdin detached and a persistent log; poll
  briefly; treat an interrupted wait as unknown and never restart a live run.
  **Why:** interrupting the tool call killed background jobs in the shell's process group.
  **Provenance:** `[learn]` issue #180. **Landed in:** `references/ralph-loop.md`.
