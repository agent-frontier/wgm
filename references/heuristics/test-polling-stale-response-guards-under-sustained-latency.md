---
section: Backpressure
order: 162
pin: references/hard-to-test-domains.md :: **Test polling stale-response guards under sustained latency.**
---
- **Heuristic:** test latency longer than the poll interval; use monotonic last-applied ordering and a bounded in-flight window.
  **Why:** discarding all responses once a newer request starts starves progress.
  **Provenance:** `[learn]` issue #162. **Landed in:** `references/hard-to-test-domains.md`.
