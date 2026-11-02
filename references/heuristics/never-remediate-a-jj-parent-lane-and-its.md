---
section: Swarm & parallelism
order: 168
pin: references/subagents.md :: **Never remediate a parent lane and its child lane concurrently.**
---
- **Heuristic:** fix stacked lanes one at a time and resolve divergence by the copy matching the lane report.
  **Why:** concurrent amend and edit yields divergent copies and stale snapshots.
  **Provenance:** `[learn]` issue #168. **Landed in:** `references/subagents.md`.
