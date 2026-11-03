---
section: Swarm & parallelism
order: 165
pin: references/subagents.md :: **Delegated validation denial is not a product failure.**
---
- **Heuristic:** treat a denied delegated validation as blocked evidence, and rerun the exact check in an authorized context before changing product code.
  **Why:** a source-only worker unable to execute a check says nothing about the product.
  **Provenance:** `[learn]` issue #165. **Landed in:** `references/subagents.md`.
