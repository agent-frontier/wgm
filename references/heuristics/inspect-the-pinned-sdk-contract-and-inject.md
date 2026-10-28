---
section: Backpressure
order: 14
---
- **Heuristic:** inspect the pinned SDK contract and inject delayed or rejected async through the real
  SDK before trusting mocks.
  **Why:** synchronous or method-level mocks hide missing awaits, detached initialization failures,
  and credential-cleanup bugs that appear only at the real async boundary. **Provenance:** `[learn]`
  issue #113. **Landed in:** `references/ralph-loop.md` (Backpressure in depth) ·
  `references/subagents.md` · `evals/evals.json`.
