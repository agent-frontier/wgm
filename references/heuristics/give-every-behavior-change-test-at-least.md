---
section: Backpressure
order: 27
---
- **Heuristic:** give every behavior-change test at least one input where the old and new code
  disagree, and make scoping tests assert that out-of-scope data is absent.
  **Why:** tests built on inputs both versions handle the same way pass before and after the fix,
  and a presence-only scope test misses leaks. **Provenance:** `[learn]` issue #131. **Landed in:**
  `references/ralph-loop.md` (Backpressure in depth).
