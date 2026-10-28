---
section: Backpressure
order: 13
---
- **Heuristic:** when a project has a deploy pipeline distinct from its per-PR CI, treat PR-level
  green as proof a change is safe to merge, never as proof it shipped — explicitly check the
  separate deploy workflow's own latest run whenever a task's acceptance criteria implies reaching
  a live deployment, and treat a red one as a standing blocker surfaced immediately, not deferred to
  Ship/Handoff. **Why:** a real session merged 8 CI-green PRs while a separate post-merge deploy
  workflow's migration step had been silently failing since the first merge — 7 consecutive failed
  deploys, invisible for hours until the human asked why "complete" work wasn't live. **Provenance:**
  wgm dogfood, `[learn]` issue #60. **Landed in:** `references/ralph-loop.md` (Backpressure in
  depth) · `SKILL.md` (Loop Validate step · Ship/Handoff).
