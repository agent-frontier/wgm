---
section: Backpressure
order: 146
pin: references/ralph-loop.md :: **Prove integration tests dispatch for real.**
pin: .github/agents/wgm-quality-reviewer.agent.md :: **Dispatch-evidence audit**
---
- **Heuristic:** require a nonempty fixture request through the actual entry point, observe the
  underlying transport or action, and include an omitted-dispatch counterfactual; never label a
  stub or empty-input test end-to-end.
  **Why:** empty inputs and manually incremented counters go green without crossing the production
  boundary.
  **Provenance:** `[learn]` issue #146. **Landed in:** `references/ralph-loop.md`,
  `.github/agents/wgm-quality-reviewer.agent.md`.
