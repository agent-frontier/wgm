---
section: Loop discipline
order: 4
---
- **Heuristic:** extend "search before you build" past the local repo to declared dependencies and
  mandated companion tools; if one already ships the capability, drop the task and wire it in.
  **Why:** a repo-only grep can't see a capability that lives in a sibling tool the project composes
  with, so it stays invisible to the standard guardrail. **Provenance:** wgm dogfood, `[learn]` issue
  #31. **Landed in:** `references/ralph-loop.md` (Standing guardrails) · `SKILL.md` Loop · Analyze.
