---
section: Comparative & hard-to-test scoring
order: 4
---
- **Heuristic:** record a threshold-clearing scenario that later drops below threshold as a named
  regression, not just a lower score.
  **Why:** overall satisfaction can stay flat or even rise while one once-working scenario breaks;
  explicit regression tracking catches the slip early and demands diagnosis instead of averaging it
  away. **Provenance:** external research, `foundatron/octopusgarden`'s
  `internal/attractor/regression.go`. **Landed in:** `references/scoring.md`.
