---
section: Loop discipline
order: 19
---
- **Heuristic:** when pausing mid-iteration or picking up an interrupted session, leave a clean
  `wip:` checkpoint commit plus a cold-start resume note, and on pickup neither re-derive already-
  completed tasks from scratch nor trust an uncommitted self-report without checking the artifact.
  **Why:** mid-iteration stops otherwise leave dirty trees that the next session either discards or
  burns half its context re-auditing from zero. **Provenance:** external research,
  `backnotprop/pstack`'s `playbooks/pause-safely.md` + `playbooks/session-pickup.md`. **Landed in:**
  `references/ralph-loop.md` (Context rotation) · `SKILL.md` (Context hygiene & rotation).
