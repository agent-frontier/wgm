---
section: Backpressure
order: 23
pin: references/ralph-loop.md :: **Assert exactly what the spec makes exact.**
---
- **Heuristic:** where a spec is exact, assert exactly (event count and variant, bytes or digest,
  sequence range, the specific terminal error) and check that each test measures what its name
  claims. **Why:** a generic rejection or an error string passes while a required typed outcome is
  missing. **Provenance:** `[learn]` issue #125. **Landed in:** `references/ralph-loop.md`
  (Backpressure in depth).
