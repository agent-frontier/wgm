---
section: Comparative & hard-to-test scoring
order: 9
---
- **Heuristic:** measure bounded engines at their configured time, memory, and size caps, not only
  on small fixtures, and treat growth beyond the design's expected complexity as a defect.
  **Why:** a quadratic scan and a per-byte map near 157 MiB passed every small-fixture test.
  **Provenance:** `[learn]` issue #135. **Landed in:** `references/hard-to-test-domains.md` (Build
  the harness first).
