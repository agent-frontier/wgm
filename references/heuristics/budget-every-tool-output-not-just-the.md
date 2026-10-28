---
section: Token economy
order: 3
---
- **Heuristic:** budget every tool output, not just the window — if a result may exceed ~2k tokens,
  write it to a file and print one summary line; view with ranges and search count-first.
  **Why:** one oversized output (a 300-hit grep, a full disassembly) overflows the window in a
  single step, so the ~50% rotation never fires. **Provenance:** `[learn]` issue #117. **Landed
  in:** `references/ralph-loop.md` (Tool-output budget) · `SKILL.md` (Context hygiene & rotation).
