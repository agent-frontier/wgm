---
section: Backpressure
order: 172
pin: references/ralph-loop.md :: **Bounded output capture must carry overflow to the gate.**
---
- **Heuristic:** propagate overflow and end-of-stream state from the capture boundary to the completion gate and reject when evidence was lost.
  **Why:** a retained tail can look like success while the failure prefix was discarded.
  **Provenance:** `[learn]` issue #172. **Landed in:** `references/ralph-loop.md`.
