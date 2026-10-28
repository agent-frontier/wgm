---
section: Backpressure
order: 7
---
- **Heuristic:** when a skill already has an eval fixture, standardize the *graded* output on a
  per-run `grading.json` plus a cross-run `benchmark.json` before inventing bespoke summaries.
  **Why:** fixed schemas make manual judging automatable later, preserve assertion-level evidence,
  and make with-skill vs. baseline deltas comparable across runs. **Provenance:** external
  research, `anthropics/skills` `skill-creator` (`agents/grader.md`,
  `scripts/aggregate_benchmark.py`, `references/schemas.md`). **Landed in:**
  `references/evals.md` (Automated grading protocol).
