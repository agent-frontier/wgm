---
section: Local sandboxing (devcontainers)
order: 6
---
- **Heuristic:** re-pin a swarm lane's absolute worktree and branch in **every** state-mutating
  instruction, and guard before mutating. **Why:** retained context is not a guarantee — in a
  32-lane run four lanes executed git from the parent checkout on a later turn and one advanced
  local `main`. Recovery must preserve reachability first, never discard commits.
  **Provenance:** `[learn]` issue #73. **Landed in:** `scripts/swarm.sh` (lane pin + guard) ·
  `scripts/test-swarm.sh` · `references/subagents.md`.
