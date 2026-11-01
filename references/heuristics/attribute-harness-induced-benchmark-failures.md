---
section: Comparative & hard-to-test scoring
order: 147
pin: references/evals.md :: **Attribute harness-induced failures before reading a score.**
---
- **Heuristic:** attribute harness-induced failures before reading a benchmark score: count harness
  notices and refused tool attempts per run, keep the scored result strict, report checker-accepted
  voided answers only as a labeled diagnostic, fix oversized tool output at its source, and point
  the CLI temp dir at the private run directory.
  **Why:** a harness substituted large tool results with a notice naming hidden tools, so the strict
  foreign-tool rule voided most runs of the stronger model, and spill files leaked to the host.
  **Provenance:** `[learn]` issue #147. **Landed in:** `references/evals.md`.
