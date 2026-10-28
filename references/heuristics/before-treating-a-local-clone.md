---
section: Loop discipline
order: 13
---
- **Heuristic:** before treating a local clone as a live dogfood target, `git fetch` it and
  check for archival/retirement signals (`ARCHIVED.md`, a retirement/archive commit message, or
  GitHub's archived-repository flag). **Why:** a stale local clone can silently hide that upstream
  has already been retired, so wgm can do technically correct work and even open a real PR against a
  project whose owner has already declared no further work is expected. **Provenance:** wgm
  dogfood, `[learn]` issue #59 (`SchwartzKamel/blogster`, stale local clone masking upstream
  retirement). **Landed in:** `references/self-improvement.md` (Health check target-freshness
  guardrail).
