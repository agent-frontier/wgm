---
section: Loop discipline
order: 9
---
- **Heuristic:** when the genes artifact reveals a component DAG, converge the components in
  topological mini-loops before running the full integration pass.
  **Why:** foundational layers stabilize cheaper in isolation, and later layers get higher-signal
  context from already-converged dependencies instead of fighting the whole stack at once.
  **Provenance:** external research, `foundatron/octopusgarden`'s `docs/gene-transfusion.md` +
  `internal/attractor/toposort.go`. **Landed in:** `references/gene-transfusion.md`.
