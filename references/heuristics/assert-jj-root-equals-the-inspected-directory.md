---
section: Swarm & parallelism
order: 156
pin: references/subagents.md :: **Assert `jj root` equals the inspected directory.**
---
- **Heuristic:** require `jj root` to equal the directory, else report uninspectable.
  **Why:** jj resolves the parent repository, so a plain nested directory looks like a clean workspace.
  **Provenance:** `[learn]` issue #156. **Landed in:** `references/subagents.md`.
