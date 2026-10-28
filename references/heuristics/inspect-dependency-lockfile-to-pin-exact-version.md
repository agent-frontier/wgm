---
section: Loop discipline
order: 136
pin: references/ralph-loop.md :: Pin the exact dependency version
---
- **Heuristic:** before writing framework- or SDK-specific code, inspect the project's dependency
  manifest or lockfile (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`) to pin the exact
  major/minor version in use.
  **Why:** training-memory defaults frequently mix incompatible major versions (e.g. React 18 vs 19,
  Tailwind 3 vs 4, Pydantic v1 vs v2), causing avoidable iteration churn. **Provenance:** external
  research, `addyosmani/agent-skills`'s `skills/source-driven-development/SKILL.md`. **Landed in:**
  `references/ralph-loop.md` (Standing guardrails).
