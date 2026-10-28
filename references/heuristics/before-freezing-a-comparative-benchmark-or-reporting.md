---
section: Comparative & hard-to-test scoring
order: 10
---
- **Heuristic:** before freezing a comparative benchmark or reporting a speedup, confirm the harness
  separates a known-bad case from a good case, name the physical/code limiter ("why not double?")
  from profiler/counter evidence, rule out skipped/cached/errored work, and record `(run_count,
  median, spread, named_limiter)`.
  **Why:** a comparative win can come from an insensitive harness or skipped/cached work unless the
  bounding resource and spread are named alongside the number. **Provenance:** external research,
  `backnotprop/pstack`'s `skills/principle-explain-the-number/SKILL.md` + `playbooks/hillclimb.md`.
  **Landed in:** `references/scoring.md` (Relative-to-incumbent scoring).
