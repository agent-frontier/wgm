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
Point at a source directory and survey it; distill genes across:
- **Structure** — directory layout, module boundaries, entry points.
- **Naming** — file/symbol conventions.
- **Errors** — how failures are raised, wrapped, surfaced.
- **Tests** — framework, layout, fixtures; what a "good test" looks like here.
- **Utilities/idioms** — key helpers to reuse rather than re-implement.
- **Dependencies/stack** — the libraries and versions the house uses.
- **API/UX** — request/response shapes, CLI/TUI conventions.

Write the result to the genes artifact (`assets/genes.template.md`).

## How genes are used
Genes become durable **signs** the agent follows every iteration (`references/ralph-loop.md`): fold
them into `AGENTS.md`'s "Codebase patterns" (or `.wgm/AGENTS.md`) and reference them from specs. A
later iteration reading `AGENTS.md` inherits the house style for free.

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
