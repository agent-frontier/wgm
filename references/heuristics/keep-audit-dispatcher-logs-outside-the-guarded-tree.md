---
section: Swarm & parallelism
order: 171
pin: references/subagents.md :: **Keep dispatcher logs outside the guarded tree.**
---
- **Heuristic:** write audit dispatcher logs outside the guarded tree and rerun the complete audit; never waive or weaken the guard.
  **Why:** a log inside the tree trips the repository-state guard.
  **Provenance:** `[learn]` issue #171. **Landed in:** `references/subagents.md`.
