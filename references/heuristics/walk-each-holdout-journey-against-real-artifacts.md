---
section: Comparative & hard-to-test scoring
order: 8
---
- **Heuristic:** walk each holdout journey against real artifacts as soon as they exist (existing
  builds, corpora, or template output at Plan-exit; otherwise right after the first build task) and
  add a task, or fix the scenario, for any expectation they cannot reach.
  **Why:** a scenario expected a marker in an exported function, but the code template printed it
  elsewhere, so no feature task could earn those points. **Provenance:** `[learn]` issue #133.
  **Landed in:** `references/scenarios.md` (Authoring).
