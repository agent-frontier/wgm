---
section: Planning & artifact quality
order: 137
pin: references/artifacts.md :: group requirements into explicit delta sections
---
- **Heuristic:** in brownfield repositories, structure spec requirements as explicit `ADDED`,
  `MODIFIED`, and `REMOVED` deltas against the existing baseline, and fold or archive completed
  deltas on ship.
  **Why:** greenfield-style specs blur existing behavior with the current change; explicit delta
  sections show reviewers and implementers the exact behavioral boundary being moved. **Provenance:**
  external research, `Fission-AI/OpenSpec`. **Landed in:** `references/artifacts.md` ·
  `assets/spec.template.md`.
