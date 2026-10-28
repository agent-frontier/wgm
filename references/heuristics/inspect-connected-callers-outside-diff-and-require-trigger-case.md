---
section: Review
order: 139
pin: references/subagents.md :: connected callers outside the diff
---
- **Heuristic:** when reviewing a change that alters a signature, return value, event payload, or
  shared contract, grep and inspect connected callers outside the diff, require every finding to
  name a concrete trigger case ("no case, no finding"), and honor explicit `shortcut: <limit>,
  <when to upgrade>` comments unless expected load already crosses that limit.
  **Why:** benchmarks show 22% of regressions break untouched callers outside the diff, while
  speculative "consider..." findings add noise and punish documented scale trade-offs.
  **Provenance:** external research, `DietrichGebert/ponytail`'s `skills/ponytail-review/SKILL.md` +
  `skills/ponytail/SKILL.md`. **Landed in:** `references/subagents.md` (Why two stages) ·
  `.github/agents/wgm-quality-reviewer.agent.md` · `references/ralph-loop.md` (Standing guardrails).
