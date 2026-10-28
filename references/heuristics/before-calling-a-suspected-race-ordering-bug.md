---
section: Backpressure
order: 22
---
- **Heuristic:** before calling a suspected race, ordering bug, leak, or unbounded growth confirmed
  (or ruled out), measure it with a minimal instrumented probe: a counter, a byte tally, a stress
  loop. **Why:** code-tracing missed an unbounded eviction loop, a stress-only race, and a double
  send that only a count of bytes on the wire exposed. **Provenance:** `[learn]` issue #124.
  **Landed in:** `references/stall-recovery.md` (Wonder).
