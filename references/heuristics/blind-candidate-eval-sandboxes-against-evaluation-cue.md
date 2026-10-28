---
section: Comparative & hard-to-test scoring
order: 11
---
- **Heuristic:** blind candidate eval sandboxes against evaluation-cue keywords (`eval`, `grade`,
  `judge`, `benchmark`, `rubric`) and avoid chain-eliciting prompts that ask the candidate to
  self-report which rules it followed.
  **Why:** tool-using agents inspect their working directory and alter behavior when they detect an
  evaluation harness, and self-reported rule-following is not evidence of artifact behavior.
  **Provenance:** external research, `backnotprop/pstack`'s `skills/poteto-mode/playbooks/eval.md`.
  **Landed in:** `scripts/grade-evals.sh` · `scripts/test-grade-evals.sh` · `references/evals.md`.
