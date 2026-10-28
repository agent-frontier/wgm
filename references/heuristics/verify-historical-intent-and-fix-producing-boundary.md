---
section: Loop discipline
order: 139
pin: references/ralph-loop.md :: Fix the producing boundary, not downstream consumer shims
---
- **Heuristic:** verify historical intent (`git log -p -S "<symbol>"`) before calling an absence,
  omitted fallback, or isolated boundary a bug, and fix the producing boundary once rather than
  adding downstream consumer repair shims.
  **Why:** an isolation or omission is often a deliberate architectural or security boundary, and
  consumer-side repair shims leave the producer emitting bad state while multiplying representations.
  **Provenance:** external research, `NousResearch/hermes-agent`'s `AGENTS.md` +
  `morluto/rea`'s `AGENTS.md`. **Landed in:** `references/ralph-loop.md` (Standing guardrails) ·
  `companions/rugged/SKILL.md` (Phase 4 — Simplify).
