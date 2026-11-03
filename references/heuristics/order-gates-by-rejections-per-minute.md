---
section: Swarm & parallelism
order: 178
pin: references/ralph-loop.md :: **Order gates by rejections per minute.**
---
- **Heuristic:** order acceptance gates by measured rejections per minute; overlap the slowest hard gate
  in its own process group, cancel the group on any rejection, still require it green, and serialize
  full suites across parallel acceptances.
  **Why:** a late-running cheap review made every rejection first pay for a full suite.
  **Provenance:** `[learn]` issue #178. **Landed in:** `references/ralph-loop.md`.
