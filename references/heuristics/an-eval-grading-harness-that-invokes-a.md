---
section: Local sandboxing (devcontainers)
order: 2
---
- **Heuristic:** an eval/grading harness that invokes a **tool-enabled** agent must run it in a
  sandbox directory outside the repo under test — capturing stdout is not isolation. **Why:** the
  working directory, not the output stream, decides what an agent can touch. `grade-evals.sh`
  carried a comment claiming it "CAPTURES the response instead of letting it run for effect" while
  `cd`-ing to the repo root, so a greenfield-build grading prompt was carried out for real: a whole
  project created, a CI job matrix added, a consent file written, and nine commits landed on `main`.
  Grading prompts describe builds, and a capable agent will build them. **Provenance:** wgm dogfood
  — hit live while measuring whether a session had improved `SKILL.md`. **Landed in:**
  `scripts/grade-evals.sh` (`run_agent`'s sandbox) · `scripts/test-grade-evals.sh` (canary probe).
