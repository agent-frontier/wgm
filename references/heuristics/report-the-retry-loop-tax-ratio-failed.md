---
section: Local sandboxing (devcontainers)
order: 7
---
- **Heuristic:** report the retry / loop-tax ratio (failed or no-progress turns ÷ total turns)
  alongside wall and active agent time so fix-and-retry churn is visible separately from first-pass
  progress.
  **Why:** an unattended run can finish green after burning most of its budget on retry loops;
  surfacing the loop-tax ratio exposes thrashing that total duration alone hides. **Provenance:**
  external research, `Keesan12/martin-loop`'s loop-tax audit. **Landed in:**
  `references/telemetry.md` (Ratios are heuristics, not claims).
