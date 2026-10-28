---
section: Backpressure
order: 2
---
- **Heuristic:** for native apps, games, GUIs, or engines, the *first* task is building the headless
  harness (output capture, state probes, crash soaks). **Why:** there is no natural unit test to
  lean on, so a deterministic signal must be manufactured before any feature work.
  **Provenance:** hard-to-test-domains work. **Landed in:** `references/hard-to-test-domains.md`.
