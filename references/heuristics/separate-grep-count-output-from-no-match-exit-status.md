---
section: Loop discipline
order: 140
pin: scripts/loop.sh :: plan_done_count()
pin: references/ralph-loop.md :: separate no-match exit status (`|| true`) from count output
---
- **Heuristic:** separate `grep -c` no-match exit status (`|| true`) from its count output in shell
  progress counters, and regression-test `0`, `1`, and multiple completed tasks explicitly.
  **Why:** with zero matches `grep -c` prints `0` and exits `1`, so `grep -c ... || echo 0` emits
  two lines (`0\n0`) that break numeric comparisons with an arithmetic syntax error even when the
  runner itself exits `0`. **Provenance:** `[learn]` issue #140. **Landed in:** `scripts/loop.sh` ·
  `scripts/test-loop.sh` · `references/ralph-loop.md`.
