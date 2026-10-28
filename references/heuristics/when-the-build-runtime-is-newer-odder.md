---
section: Backpressure
order: 4
---
- **Heuristic:** when the build runtime is newer/odder than a key tool's tested baseline, make T1
  prove the whole toolchain end-to-end (a hello-world that really builds/runs) and pre-commit a
  runtime-pin fallback before feature work. **Why:** mid-build tooling stalls invalidate work that
  assumed a green build; a five-minute hello-world surfaces the incompatibility while it's still
  trivial to route around. **Provenance:** wgm dogfood, `[learn]` issue #34 (elm-pages/lamdera on a
  newer-than-LTS Node). **Landed in:** `references/ralph-loop.md` (Backpressure in depth) ·
  `SKILL.md` Plan-exit gate.
