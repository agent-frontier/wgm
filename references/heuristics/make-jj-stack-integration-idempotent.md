---
section: Swarm & parallelism
order: 155
pin: references/subagents.md :: **Make stack integration idempotent.**
---
- **Heuristic:** rebase only when the parent differs; integrate twice and compare tip ids.
  **Why:** a no-op rebase rewrites the commit id that reviews are bound to.
  **Provenance:** `[learn]` issue #155. **Landed in:** `references/subagents.md`.
