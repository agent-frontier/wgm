---
section: Comparative & hard-to-test scoring
order: 7
pin: references/scoring.md :: **The scenario's own rule sets partial-score severity.**
---
- **Heuristic:** let a holdout scenario's own scoring and tier text set the severity of a partial
  score on it; keep a validator's conflicting label as a tracked follow-up.
  **Why:** a validator can call a gap blocking that the scenario explicitly downgrades. The rule
  never overrides a failing deterministic gate or a blocking correctness finding.
  **Provenance:** `[learn]` issue #122. **Landed in:** `references/scoring.md` (Running the judge).
