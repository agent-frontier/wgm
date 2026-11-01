---
section: Review
order: 149
pin: references/scenarios.md :: **Exclude holdouts from review artifacts, not just prompts.**
pin: references/subagents.md :: **Build reviewer inputs from path allow-lists.**
---
- **Heuristic:** exclude holdouts from review artifacts, not just reviewer prompts; build role
  inputs from explicit path allow-lists before materializing diffs, test that excluded paths never
  appear, and on exposure preserve the incident and withhold blind satisfaction claims.
  **Why:** a broad baseline diff can embed hidden scenarios in an otherwise read-only review.
  **Provenance:** `[learn]` issue #149. **Landed in:** `references/scenarios.md`,
  `references/subagents.md`.
