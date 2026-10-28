---
section: Backpressure
order: 18
---
- **Heuristic:** keep offline proxy, live-service, and release evidence in separate tiers.
  **Why:** a local stub or proxy can validate the path it exercised while the real managed service or
  deploy path is still broken, absent, or unobserved. **Provenance:** `[learn]` issue #104.
  **Landed in:** `references/ralph-loop.md` (Backpressure in depth) ·
  `references/validation-env.md` · `evals/evals.json`.
