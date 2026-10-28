---
section: Local sandboxing (devcontainers)
order: 9
---
- **Heuristic:** the hive courier must **fail closed** — forward exactly one lesson, then re-scan
  the scrubbed candidate and refuse publication when any host identifier or a size ceiling breach
  survives. **Why:** consent authorizes a sanitized *report*, never the source ledger; anonymizing
  and filing the whole memories file leaks host facts even when every individual scrub rule fires
  correctly, and `consent: true` must not be a bypass. **Provenance:** `[learn]` issue #79.
  **Landed in:** `scripts/harvest-hive.sh` (`select_one_lesson`, `residual_scan`, `--max-bytes`) ·
  `scripts/test-harvest-hive.sh` · `references/self-improvement.md`.
