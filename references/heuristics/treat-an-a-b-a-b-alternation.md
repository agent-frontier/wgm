---
section: Loop discipline
order: 10
---
- **Heuristic:** treat an A→B→A→B alternation across four iterations as a named oscillation, and
  break it with a no-revert, different-architecture steer.
  **Why:** generic diff churn notices motion but misses the stronger signal that the loop is
  literally bouncing between two states; naming it justifies a harder intervention than another
  small tweak. **Provenance:** external research, `foundatron/octopusgarden`'s
  `internal/attractor/oscillation.go`. **Landed in:** `references/stall-recovery.md`.
