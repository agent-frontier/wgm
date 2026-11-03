---
section: Swarm & parallelism
order: 154
pin: references/subagents.md :: **Snapshot every lane workspace before integrating.**
---
- **Heuristic:** run `jj status` inside every lane workspace before integrating parallel lanes.
  **Why:** an edit is recorded only when jj runs inside its workspace, so integration reads a stale tree.
  **Provenance:** `[learn]` issue #154. **Landed in:** `references/subagents.md`.
