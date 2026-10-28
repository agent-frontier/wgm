---
section: Swarm & parallelism
order: 3
---
- **Heuristic:** partition a worktree swarm's file ownership, not just its features; route shared
  additions into each stream's own module and treat any unavoidable shared declaration file as a
  known, append-only merge point. **Why:** worktree isolation only prevents *live* contention — two
  peer streams touching the same shared module still surfaces as a merge conflict at the most
  expensive moment, integration time. **Provenance:** wgm dogfood, `[learn]` issue #29 (Rust FFI
  crate, two streams sharing one declaration file). **Landed in:**
  `docs/operator/running-the-loop.md` (Swarm — Planning a swarm well).
