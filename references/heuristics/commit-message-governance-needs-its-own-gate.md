---
section: Local sandboxing (devcontainers)
order: 4
---
- **Heuristic:** commit-message governance needs its own gate, and **merge commits are governed
  commits**. **Why:** product gates cannot see trailers, so a run reaches a green exact-tree gate
  while a generated merge commit carries none of the mandated trailers every head commit has.
  Preserve published history: record the offending SHA and a forward-only correction/attestation;
  block handoff pending an explicit maintainer decision, never an automatic waiver. A sibling merge
  does not erase the original violation, and the checker stays RED for any range containing it.
  **Provenance:** `[learn]` issue #82.
  **Landed in:** `scripts/check-trailers.sh` · `scripts/test-check-trailers.sh` · `SKILL.md` Phase 4.
