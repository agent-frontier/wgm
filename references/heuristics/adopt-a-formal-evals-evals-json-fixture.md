---
section: Backpressure
order: 5
---
- **Heuristic:** adopt a formal `evals/evals.json` fixture (prompt + expected_output + assertions,
  graded with/without the skill) as a skill's own output-quality self-test, distinct from a
  trigger-classification fixture (`scripts/check-evals.sh` checks the fixture's shape only; grading
  stays manual/LLM-judged). **Why:** a skill's prompt-engineering (its `SKILL.md`/references
  text) has no natural unit test; a structured eval schema gives it one, closing exactly the
  self-test gap a trigger-only fixture leaves open. **Provenance:** external research,
  `agentskills/agentskills`'s `evaluating-skills.mdx` (the specification wgm already conforms to for
  `SKILL.md` structure). **Landed in:** `references/evals.md` · `evals/evals.json` ·
  `scripts/check-evals.sh`.
