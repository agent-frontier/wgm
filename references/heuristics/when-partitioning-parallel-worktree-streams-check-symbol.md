---
section: Swarm & parallelism
order: 7
---
- **Heuristic:** when partitioning parallel worktree streams, check symbol- and API-level intent
  (`replace`/`delete`/`rename` vs. `extend`/`call`) in addition to file ownership before coding.
  **Why:** two streams can touch completely disjoint files and still silently break each other at
  integration time if one replaces or deletes an interface another stream extends or calls.
  **Provenance:** external research, `naw103/foremerge`. **Landed in:** `references/subagents.md`
  (Worktree swarm dispatch) · `docs/operator/running-the-loop.md` (Planning a swarm well).
