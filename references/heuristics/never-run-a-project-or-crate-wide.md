---
section: Loop discipline
order: 5
---
- **Heuristic:** never run a project- or crate-wide auto-formatter mid-iteration; format only the
  exact files this task touched. **Why:** a blanket formatter rewrites untouched files, leaving
  stray churn that blocks a branch switch and buries the one-task diff in reformatting noise.
  **Provenance:** wgm dogfood, `[learn]` issue #37 (Rust `cargo fmt -p` rewrote 14 files, 2 were the
  task). **Landed in:** `references/ralph-loop.md` (Standing guardrails) · `SKILL.md` Loop · Implement.
