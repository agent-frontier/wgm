---
section: Comparative & hard-to-test scoring
order: 151
pin: references/scoring.md :: **Cite authored severity before a score becomes a hard stop.**
pin: .github/agents/wgm-validator.agent.md :: every blocker cites an authored gate
pin: evals/evals.json :: authored-severity-before-hard-stop
---
- **Heuristic:** require each validator blocker to cite an authored unconditional gate, a failing
  deterministic check, or an independently substantiated correctness defect; classify weighted or
  capped partial scores separately, and correct conflicting labels transparently without raising
  scores, rewriting history, weakening assertions, or inventing evidence.
  **Why:** an evidence-limited partial score was promoted to an unconditional stop although the
  authored scoring set only an overall threshold and no per-scenario minimum.
  **Provenance:** `[learn]` issue #151. **Landed in:** `references/scoring.md`,
  `.github/agents/wgm-validator.agent.md`, `evals/evals.json`.
