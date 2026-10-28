---
section: Backpressure
order: 1
---
- **Heuristic:** a high satisfaction score never overrides a failing deterministic check.
  **Why:** an LLM judge can be charmed; a failing test cannot. **Provenance:** holdout-scoring +
  octopusgarden. **Landed in:** `SKILL.md` Backpressure · `wgm-validator`.
