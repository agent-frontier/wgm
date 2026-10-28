---
section: Backpressure
order: 6
---
- **Heuristic:** a trigger-eval table can be made executable by converting it to
  `{query, should_trigger}` JSON and detecting tool-use events early in the host stream, rather
  than waiting for full completion. **Why:** repeated trigger checks are stochastic and expensive;
  early event detection makes parallel trigger-rate measurement tractable. **Provenance:** external
  research, `anthropics/skills` `skill-creator/scripts/run_eval.py`. **Landed in:**
  `references/trigger-eval.md` (How to use this).
