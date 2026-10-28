---
section: Backpressure
order: 28
---
- **Heuristic:** guard against test tampering in the diff (deleted tests, new skip/xfail/ignore
  markers, weakened assertions) unless an acceptance criterion authorizes it, and for bug fixes
  prove the regression test fails on the merge-base and passes on `HEAD`.
  **Why:** an agent can turn a red suite green by deleting or skipping a test, and a bug-fix test
  that already passes on the unpatched base proves nothing about the fix. **Provenance:** external
  research, `no-human-ai/no_human`'s tamper guard and reproduction gate. **Landed in:**
  `references/ralph-loop.md` (Backpressure in depth) · `SKILL.md` (Loop Validate step).
