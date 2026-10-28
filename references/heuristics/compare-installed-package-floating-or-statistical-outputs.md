---
section: Backpressure
order: 21
---
- **Heuristic:** compare installed-package floating or statistical outputs with documented
  absolute/relative tolerances and special-value expectations, not exact decimal strings.
  **Why:** platform math and reduction order can legitimately move low-order digits; exact-string
  goldens either flap or get "fixed" by unjustified tolerance inflation. **Provenance:** `[learn]`
  issue #110. **Landed in:** `references/ralph-loop.md` (Backpressure in depth) ·
  `references/scoring.md` · `evals/evals.json` · `scripts/test-check-evals.sh`.
