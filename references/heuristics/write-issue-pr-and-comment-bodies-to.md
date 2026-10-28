---
section: Loop discipline
order: 17
pin: references/ralph-loop.md :: **Pass bodies by file.**
---
- **Heuristic:** write issue, PR, and comment bodies to a file and pass them with `--body-file`;
  never put Markdown backticks in a double-quoted shell argument.
  **Why:** POSIX shells run backticks inside double quotes as command substitution, and a
  Windows-to-WSL hop hides the quoting. **Provenance:** `[learn]` issue #129. **Landed in:**
  `references/ralph-loop.md` (Standing guardrails).
