---
section: Review
order: 3
---
- **Heuristic:** run two independent review passes — spec-compliance, then code-quality.
  **Why:** a single reviewer conflates "right thing" with "built correctly" and blesses its own
  assumptions. **Provenance:** Superpowers two-stage review. **Landed in:** `references/subagents.md`
  · `wgm-spec-reviewer` + `wgm-quality-reviewer`.
