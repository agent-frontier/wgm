# Gene transfusion — seed the build from an exemplar

**Gene transfusion** extracts proven coding patterns — "genes" — from an exemplar codebase so wgm
builds in the house style instead of reinventing conventions. It is octopusgarden's `extract` idea,
adapted as an optional wgm step that feeds the loop's "patterns/signs."

## When to use it (optional)
Use it in **Triage/Plan** when a high-quality exemplar exists:
- a reference repo or the team's flagship service,
- a sibling module you want to match,
- a design system or component library.

Skip it for pure greenfield with no exemplar — there are no genes to transfuse.

## How it works (agent-driven)
Point at a source directory and survey it. octopusgarden's actual `extract` prompt asks for
**PATTERN**, **INVARIANTS**, **EDGE CASES**, **STACK**, **STRUCTURE**, **BOOT**, **BUILD**, and
optionally **COMPONENTS** (`foundatron/octopusgarden`, `internal/gene/analyze.go`); wgm keeps that
shape in spirit but adapts the survey to its own house-style artifact.

Distill genes across:
- **Pattern** — the primary architectural pattern the exemplar repeats.
- **Structure** — directory layout, module/component boundaries.
- **Invariants** — hard rules always followed: naming, error handling, auth, validation.
- **Edge cases** — failures, timeouts, retries, missing data, concurrency edges.
- **Dependencies/stack** — the languages, frameworks, and libraries the house uses.
- **Boot/entry-point** — startup path, config loading, dependency wiring, server listen / CLI init.
- **Build/CI** — build tool, Dockerfile strategy, CI hooks, local run commands.
- **Utilities/idioms** — key helpers to reuse rather than re-implement.
- **Tests** — framework, layout, fixtures; what a "good test" looks like here.
- **API/UX** — request/response shapes, CLI/TUI conventions.

The first seven dimensions are the closest match to octopusgarden's source prompt; `Utilities/idioms`,
`Tests`, and `API/UX` are explicit wgm additions. That correction matters: octopusgarden's scanner
skips test files, so wgm should not imply that its older list was octopusgarden's exact schema.

Write the result to the genes artifact (`assets/genes.template.md`).

## How genes are used
Genes become durable **signs** the agent follows every iteration (`references/ralph-loop.md`): fold
them into `AGENTS.md`'s "Codebase patterns" (or `.wgm/AGENTS.md`) and reference them from specs. A
later iteration reading `AGENTS.md` inherits the house style for free.

## Composed convergence (multi-layer builds, optional)
If the genes artifact identifies a clear dependency DAG between architectural components, the Loop
need not converge the whole system in one monolithic pass. Borrow octopusgarden's composed-
convergence idea (`foundatron/octopusgarden`, `docs/gene-transfusion.md` +
`internal/attractor/toposort.go`): topologically sort the components, run each as its own mini-loop
in dependency order, give each pass the already-converged upstream files as context, then finish
with an integration-validation pass across the merged whole. If any component fails to converge,
fall back to the ordinary monolithic loop rather than forcing a broken merge.

## Guardrails
- Extract **patterns, not wholesale code.** Respect the exemplar's licence and copyright; cite source
  file paths so a human can verify.
- Keep the genes artifact **lean** — it loads into every iteration's context like `AGENTS.md`; bloat
  pollutes the loop.
- Note the exemplar's licence if any code-like snippet is quoted.

## Placement (artifact-safety)
Write genes to `.wgm/genes.md`, or fold them directly into `AGENTS.md` "Codebase patterns." Honor the
root-vs-`.wgm/` rule from `references/artifacts.md`.

## Cross-links
`references/artifacts.md` · `references/ralph-loop.md` · `assets/genes.template.md`
