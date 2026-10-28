---
section: Loop discipline
order: 14
---
- **Heuristic:** verify the project's working tree is clean before the first loop iteration.
  **Why:** prompt-only skills lack shadow-checkpoint infrastructure; a clean git baseline keeps the
  repo's own history as a reliable rollback path when an iteration destabilizes the tree.
  **Provenance:** external research, `RooCodeInc/Roo-Code`'s
  `src/services/checkpoints/ShadowCheckpointService.ts`. **Landed in:** `SKILL.md` (Phase 2.5 —
  Preflight).
