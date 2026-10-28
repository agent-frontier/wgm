---
section: Backpressure
order: 25
pin: references/ralph-loop.md :: **Named support needs a positive real-path test.**
---
- **Heuristic:** back every named-support claim (engine, profile, platform, format) with a positive
  test that drives the shipped artifact for that target through its real path and asserts its
  support level, matched rule, and evidence source. **Why:** generic matcher tests stay green while
  the bundled path is broken. **Provenance:** `[learn]` issue #128. **Landed in:**
  `references/ralph-loop.md` (Backpressure in depth).
