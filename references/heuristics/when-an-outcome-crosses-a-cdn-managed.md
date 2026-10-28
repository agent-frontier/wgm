---
section: Backpressure
order: 12
---
- **Heuristic:** when an outcome crosses a CDN, managed proxy, gateway, mesh, or ingress, read that
  intermediary's documented eligibility and transformation rules before optimizing the surrounding
  config.
  **Why:** request-side cache ineligibility can make a correct origin policy inert, while a downstream
  encoder may make an added compression tier a regression; the named artifacts can be internally
  correct and still not decide the outcome. **Provenance:** `[learn]` issue #87. **Landed in:**
  `references/ralph-loop.md` (Analyze) · `references/docs-audit.md`.
