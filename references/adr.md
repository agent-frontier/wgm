# ADRs — document why a hard decision was taken

Architecture Decision Records (ADRs) capture **why** a hard-to-reverse choice was made, so a fresh
agent or human can understand the trade-off later instead of re-litigating it from the resulting
code alone. This formalizes the "ADR discipline (3-criterion gate)" that wgm had previously parked
as an also-ran candidate in [`docs/plans/2026-06-16_PLAN.md`](../docs/plans/2026-06-16_PLAN.md),
borrowing the pattern idea from [`mattpocock/skills`](https://github.com/mattpocock/skills).

## When an ADR is warranted

Write an ADR only when **all three** of these hold:

1. **Hard to reverse later** — once other code, docs, or workflows build on this choice, changing it
   would be materially expensive or disruptive.
2. **Cross-cutting** — the decision affects multiple specs, components, or recurring patterns rather
   than one isolated implementation detail.
3. **Genuinely debatable** — the "obvious" choice is not actually obvious; a reasonable engineer
   could have gone another way.

If any of those fail, prefer ordinary spec/plan notes. Not every decision needs an ADR; otherwise
the practice turns into ceremony and the important records disappear into noise.

## What it captures

An ADR records:
- **The decision** — what was chosen.
- **The context / forces** — the constraints, goals, risks, and pressures that made the decision
  necessary.
- **Alternatives considered** — the realistic options and why they were rejected.
- **Consequences** — the trade-offs, follow-on constraints, and costs accepted by choosing it.

## Where it lives

Store ADRs under the same root-vs-`.wgm/` placement rule used by the other artifacts in
[`references/artifacts.md`](artifacts.md):
- **Greenfield / root placement:** `specs/adr/NNNN-title.md`
- **Existing-project / `.wgm/` placement:** `.wgm/specs/adr/NNNN-title.md`

Create the ADR during **Plan** if the decision is already known then, or during the **Loop** the
moment a qualifying decision is actually made. Use [`assets/adr.template.md`](../assets/adr.template.md)
as the starting shape.

## Guardrails

- Keep ADRs short and decision-specific; they are not mini-specs.
- Record the trade-off when the choice is made, not weeks later from memory.
- Supersede an old ADR with a new one when the decision changes; do not silently edit history into
  looking inevitable.

## Cross-links

`references/artifacts.md` · `assets/adr.template.md` · `docs/plans/2026-06-16_PLAN.md`
