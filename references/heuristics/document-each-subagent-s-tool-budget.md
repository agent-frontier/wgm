---
section: Swarm & parallelism
order: 4
---
- **Heuristic:** document each subagent's tool budget as a proposed machine-readable `groups:`
  schema, not prose alone — even before any host actually enforces it.
  **Why:** prompt text says what a role *should* do; structured `read` / `edit` / `command` /
  `mcp` groups make the contract portable to hosts that can actually enforce it and clarify which
  roles are read-only. **Provenance:** external research, `RooCodeInc/Roo-Code`'s
  `packages/types/src/tool.ts`. **Landed in:** `references/subagents.md` (illustrative example
  mappings only, cross-checked against each archetype's real tool list — no `.github/agents/*.agent.md`
  file has a `groups:` frontmatter field yet, and no host enforces one; this entry describes a
  documented proposal, not yet an applied rule).
