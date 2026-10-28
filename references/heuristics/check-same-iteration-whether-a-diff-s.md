---
section: Local sandboxing (devcontainers)
order: 3
---
- **Heuristic:** check same-iteration whether a diff's **new public surface** was documented, rather
  than leaving it to the batched Ship/Handoff audit. **Why:** the Record step commits on a green
  validation command, so doc drift accumulates across several merged PRs before an audit finds it,
  and the fix cost scales with how many piled up. Keep it advisory so it does not fire on ordinary
  diffs — a gate that fires on everything gets ignored. **Provenance:** `[learn]` issue #78.
  **Landed in:** `scripts/check-doc-sync.sh` · `scripts/test-check-doc-sync.sh` · `SKILL.md` (Record).
