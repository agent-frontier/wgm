---
section: Comparative & hard-to-test scoring
order: 139
pin: scripts/grade-evals.sh :: GIT_CEILING_DIRECTORIES
---
- **Heuristic:** set `GIT_CEILING_DIRECTORIES` to the throwaway sandbox in `grade-evals.sh` so a
  candidate agent cannot walk up into a parent repository's `git log` when `TMPDIR` sits inside a
  checkout, and interleave candidate/baseline trials across tasks.
  **Why:** tool-using agents can read recent commit messages from an enclosing git repo to infer what
  an eval is testing, and non-interleaved runs confound skill changes with time-of-day provider
  drift. **Provenance:** external research, `DietrichGebert/ponytail`'s
  `benchmarks/results/2026-10-07-agentic.md`. **Landed in:** `scripts/grade-evals.sh` ·
  `scripts/test-grade-evals.sh` · `references/evals.md`.
