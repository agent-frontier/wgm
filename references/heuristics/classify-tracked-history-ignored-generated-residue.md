---
section: Loop discipline
order: 16
---
- **Heuristic:** classify tracked history, ignored generated residue, and unrelated user files before
  cleanup; preserve tracked metrics and remove only known task-owned stale output.
  **Why:** a blanket cleanup can erase historical evidence or concurrent work merely because it lives
  beside disposable lane files. **Provenance:** `[learn]` issue #107. **Landed in:**
  `references/artifacts.md` · `references/ralph-loop.md` · `SKILL.md` · `evals/evals.json`.
