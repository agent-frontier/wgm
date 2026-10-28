---
section: Triage & Grill
order: 137
pin: SKILL.md :: no high-blast-radius boundary
---
- **Heuristic:** keep high-blast-radius changes (auth, security, data migrations, public API or
  schema boundaries) off the Quick track even when the diff is 1–5 files.
  **Why:** file count measures change size, not reversibility or blast radius; a two-line auth or
  migration edit still needs Standard review and scenario assurance. **Provenance:** external
  research, `addyosmani/agent-skills`'s `skills/doubt-driven-development/SKILL.md` +
  `wanshuiyin/Auto-claude-code-research-in-sleep` (ARIS). **Landed in:** `SKILL.md` (Triage track
  table).
