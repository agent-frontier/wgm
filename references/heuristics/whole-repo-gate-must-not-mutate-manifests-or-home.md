---
section: Backpressure
order: 150
pin: references/validation-env.md :: **A whole-repo gate must not mutate the tree or the real HOME.**
pin: references/validation-env.md :: **Prove the gate did not mutate the repository (procedure).**
---
- **Heuristic:** keep a whole-repo gate from rewriting tracked dependency manifests (prefer stdlib
  over a direct use of an indirect-only dependency) and run it with an isolated `HOME` whose
  prerequisite paths point only at verified read-only copies (never an operator checkout or the
  real HOME), so tool tests cannot read credentials or leave untracked artifacts.
  **Why:** `go fmt`/`go vet` can rewrite `go.mod`, and real-HOME tests leak or read operator state.
  **Provenance:** `[learn]` issue #150. **Landed in:** `references/validation-env.md`.
