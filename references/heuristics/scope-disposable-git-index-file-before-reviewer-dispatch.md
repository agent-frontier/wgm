---
section: Review
order: 141
pin: references/subagents.md :: keep `GIT_INDEX_FILE` command-scoped
pin: .github/agents/wgm-spec-reviewer.agent.md :: never repairs or resets an unexpectedly dirty worktree
pin: .github/agents/wgm-quality-reviewer.agent.md :: never repairs or resets an unexpectedly dirty worktree
---
- **Heuristic:** keep any disposable `GIT_INDEX_FILE` used to snapshot an immutable review commit
  command-scoped (or `unset GIT_INDEX_FILE` before dispatching child agents), and have reviewers
  inspect the pinned commit SHA rather than repairing or resetting an unexpectedly dirty tree.
  **Why:** exporting `GIT_INDEX_FILE` and deleting the temporary index leaks a missing/empty index
  path into read-only reviewers, making `git status` and one-sided diffs report a fake dirty tree
  and wasting review context. **Provenance:** `[learn]` issue #141. **Landed in:**
  `references/subagents.md` (Dispatch points) · `.github/agents/wgm-spec-reviewer.agent.md` ·
  `.github/agents/wgm-quality-reviewer.agent.md` · `adapters/claude/agents/`.
