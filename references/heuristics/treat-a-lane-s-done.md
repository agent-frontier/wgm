---
section: Local sandboxing (devcontainers)
order: 5
---
- **Heuristic:** treat a lane's `done` as an **unverified assertion** and check the named file,
  symbol, and command before integrating. **Why:** in one Full-track run four of five tasks marked
  done carried a false claim — a test file that existed nowhere, a layout claim contradicted by the
  source it named. Every claim read plausibly; only a symbol-level grep exposed them.
  **Provenance:** `[learn]` issue #75. **Landed in:** `SKILL.md` (Loop step 4) ·
  `references/subagents.md` · `.github/agents/wgm-spec-reviewer.agent.md`.
