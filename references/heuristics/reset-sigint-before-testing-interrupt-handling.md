---
section: Backpressure
order: 167
pin: references/hard-to-test-domains.md :: **Reset SIGINT before testing interrupt handling.**
---
- **Heuristic:** launch the process under test with SIGINT reset to default and assert the disposition; use SIGTERM otherwise.
  **Why:** background jobs start with SIGINT ignored and bash cannot trap it.
  **Provenance:** `[learn]` issue #167. **Landed in:** `references/hard-to-test-domains.md`.
