---
section: Loop discipline
order: 3
---
- **Heuristic:** in an autonomous, manual-merge loop, cap concurrent open PRs (~3-5); past the cap,
  the next iteration consolidates existing PRs instead of opening another one. **Why:** an
  open-ended stream of net-new PRs floods the maintainer and deepens the shared-file conflict
  surface while nothing actually lands — merged value beats more net-new work. **Provenance:** wgm
  dogfood, `[learn]` issue #36 (18 PRs open, 0 merged). **Landed in:** `references/ralph-loop.md`
  (Stop/regenerate conditions) · `SKILL.md` Stop conditions.
