---
section: Planning & artifact quality
order: 2
pin: references/scenarios.md :: **A scenario may tighten its spec, never weaken it.**
---
- **Heuristic:** let a scenario tighten its governing spec but never weaken it, and map each atomic
  expectation (one step may hold several) to one direct assertion before final scoring.
  **Why:** a looser scenario awards full marks to a build that violates its spec, and a step with
  several expectations can pass on one. **Provenance:** `[learn]` issue #127. **Landed in:**
  `references/scenarios.md` (Scenarios vs specs vs backpressure).
