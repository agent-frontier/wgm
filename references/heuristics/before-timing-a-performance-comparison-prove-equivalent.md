---
section: Comparative & hard-to-test scoring
order: 6
---
- **Heuristic:** before timing a performance comparison, prove equivalent semantics and measure with
  warmups, repeated pinned runs, and disclosed caveats.
  **Why:** a faster number is meaningless if the candidate changed the result, compiler mode, input
  distribution, or just won one noisy cold run. **Provenance:** `[learn]` issue #108. **Landed
  in:** `references/grilling.md` · `references/ralph-loop.md` (Backpressure in depth) ·
  `references/scoring.md` · `references/evals.md` · `evals/evals.json` ·
  `scripts/test-check-evals.sh`.
