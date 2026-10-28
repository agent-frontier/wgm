---
section: Loop discipline
order: 137
pin: references/ralph-loop.md :: Monotonic plan progress & untrusted-content quarantine.
---
- **Heuristic:** enforce monotonic task completion (`status: done` / `[x]` counts never decrease
  across a build iteration) and quarantine raw external web/search content out of auto-loaded plan
  and memory files.
  **Why:** stale-read or concurrent writes silently clobber completed tasks without invalidating
  Markdown syntax, and untrusted third-party text pasted into `IMPLEMENTATION_PLAN.md` or
  `.wgm/memories.md` is re-injected into context on every subsequent iteration. **Provenance:**
  external research, `OthmanAdi/planning-with-files`. **Landed in:** `scripts/loop.sh`
  (`plan_done_count`) · `scripts/test-loop.sh` · `references/ralph-loop.md` (Standing guardrails).
