---
section: Swarm & parallelism
order: 5
---
- **Heuristic:** let lanes commit only on their own branch; only the orchestrator pushes, opens or
  merges PRs, deletes or recreates refs, and removes worktrees, unless it delegates one named
  action and records that delegation. **Why:** integration actions scattered across lane agents
  change shared state under the agent that owns convergence and cannot be audited in one place.
  **Provenance:** `[learn]` issue #123. **Landed in:** `references/subagents.md` (Worktree swarm
  dispatch).
