---
section: Backpressure
order: 16
---
- **Heuristic:** for embedded-host integrations, make the first validation task a minimal real-host
  bootstrap against the shipped runtime.
  **Why:** desktop compilation and offline tests can pass while the real host cannot load, listen, or
  discover the integration at all. **Provenance:** `[learn]` issue #111. **Landed in:**
  `references/hard-to-test-domains.md` · `references/ralph-loop.md` (Backpressure in depth) ·
  `evals/evals.json`.
