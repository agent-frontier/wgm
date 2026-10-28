---
section: Review
order: 6
pin: references/subagents.md :: **Review one immutable commit.**
---
- **Heuristic:** give every reviewer one immutable commit and pause the writer until the verdict is
  in; if the commit moves, discard the stale review and restart against the new commit.
  **Why:** a review of a live worktree, or one reused after a revision, cannot be tied to the code
  that ships. **Provenance:** `[learn]` issue #119. **Landed in:** `references/subagents.md`
  (Dispatch points).
