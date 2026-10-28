---
section: Comparative & hard-to-test scoring
order: 5
---
- **Heuristic:** before accepting an automated edit to a skill/protocol document, gate it on a
  held-out or baseline comparison — never accept on the generator's own say-so.
  **Why:** a skill document that edits itself without a comparison against a prior-known-good
  revision can drift or regress silently; a simple non-regression check (candidate pass_rate ≥
  baseline pass_rate on the same held-out cases — a distinct, boolean-per-assertion mechanism from
  this file's own 0-100 continuous satisfaction score, `references/scoring.md`) catches that before
  the edit ships, without needing a full training loop. **Provenance:** external research,
  `microsoft/SkillOpt`'s validation-gate design (rollout → reflect → bounded edit → accept only if
  it beats a held-out score). **Landed in:** `references/evals.md`, `scripts/grade-evals.sh`
  (`docs/plans/2026-07-08_SKILLOPT_ADOPTION.md`).
