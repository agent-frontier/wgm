---
section: Loop discipline
order: 7
---
- **Heuristic:** search exact task-named identifiers first, then follow their callers/importers
  before deciding where to edit. **Why:** conceptual keyword search misses the real change surface,
  and stopping at the defining file misses the files that actually need changing. **Provenance:**
  external research, `Aider-AI/aider`'s `aider/repomap.py`. **Landed in:**
  `references/ralph-loop.md` (Standing guardrails).
