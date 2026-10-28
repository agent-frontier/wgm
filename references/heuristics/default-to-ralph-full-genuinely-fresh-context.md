---
section: Loop discipline
order: 15
---
- **Heuristic:** default to Ralph-full (genuinely fresh context per iteration via `scripts/loop.sh`)
  whenever a non-interactive agent invocation is available, not only for large/ambiguous builds;
  reserve Ralph-lite (in-session) for interactive-only hosts or Quick-track work.
  **Why:** the original technique's own definition is "Ralph is a technique. In its purest form,
  Ralph is a Bash loop" — a single monolithic process with progress living on disk, not model
  context, between passes. Treating in-session execution as the default rather than the fallback
  quietly settles for the weaker, compromise form of the technique even when the purer form is one
  subprocess call away. **Provenance:** external research, `ghuntley/how-to-ralph-wiggum` +
  ghuntley.com/loop (Geoffrey Huntley's original Ralph definition). **Landed in:** `SKILL.md`
  (Phase 0 — Decide loop mode) · `references/ralph-loop.md` (Ralph-lite vs Ralph-full) ·
  `docs/operator/running-the-loop.md`.
