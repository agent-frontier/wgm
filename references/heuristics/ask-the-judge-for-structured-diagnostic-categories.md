---
section: Comparative & hard-to-test scoring
order: 3
---
- **Heuristic:** ask the judge for structured diagnostic categories alongside the numeric score.
  **Why:** recurring low scores are easier to fix when the failure class (`auth`, `http-status`,
  etc.) is tracked across iterations instead of buried in free-form prose. **Provenance:** external
  research, `foundatron/octopusgarden`'s `internal/llm/prompt.go`. **Landed in:**
  `references/scoring.md`.
