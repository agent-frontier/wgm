---
section: Loop discipline
order: 11
---
- **Heuristic:** treat `loop.sh --commit` as exclusive worktree ownership: require a clean baseline,
  declare iteration-owned paths, and refuse undeclared staging.
  **Why:** `git add -A` cannot distinguish a concurrent human edit from the loop's work, so a
  successful commit can silently claim unrelated changes. **Provenance:** `[learn]` issue #95.
  **Landed in:** `scripts/loop.sh`, `scripts/test-loop.sh`, `references/ralph-loop.md`.
