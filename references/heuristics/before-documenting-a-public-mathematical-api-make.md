---
section: Backpressure
order: 20
---
- **Heuristic:** before documenting a public mathematical API, make undefined or out-of-domain
  inputs explicit in the contract and pin them with deterministic boundary tests.
  **Why:** happy-path examples and current implementation behavior do not tell callers whether edge
  inputs error, clamp, return NaN, or carry another status. **Provenance:** `[learn]` issue #109.
  **Landed in:** `references/grilling.md` · `references/ralph-loop.md` (Backpressure in depth) ·
  `evals/evals.json` · `scripts/test-check-evals.sh`.
