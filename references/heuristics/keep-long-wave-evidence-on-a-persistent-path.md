---
section: Swarm & parallelism
order: 148
pin: references/subagents.md :: **Keep long-wave evidence on a persistent path.**
---
- **Heuristic:** keep a long wave's working directory (logs, prompts, review outputs) on a
  persistent path from the start, never `/tmp`; copy evidence into the repository as produced and
  re-execute rather than reconstruct lost evidence.
  **Why:** a host temp cleaner deleted mid-wave review files, so earlier rounds could be cited only
  from summaries and a judge withheld credit for the lost raw logs.
  **Provenance:** `[learn]` issue #148. **Landed in:** `references/subagents.md`.
