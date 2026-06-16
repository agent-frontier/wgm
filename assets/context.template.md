# CONTEXT — domain glossary (ubiquitous language)

<!--
The project's living vocabulary: each domain term, its precise meaning, and the ONE canonical name
to use everywhere (code, specs, UI, commits). Built during Grill as terms surface; consulted in the
loop's Analyze step so naming stays consistent and a fresh context does not re-derive what a term
means (which wastes tokens). Keep it lean — a glossary, not prose (about a 1500-token budget). This
is NOT the constitution (principles) and NOT a spec (behavior); it holds only the words and what
they denote.

Skip it for trivial builds with no special vocabulary. Add a row the moment a term is ambiguous,
overloaded, or easy to confuse with a near-synonym.
-->

## Terms

| Term | Means | Canonical name (code / UI) | Not to be confused with |
|---|---|---|---|
| <Term> | <one-line precise definition> | `<canonicalName>` | <near-synonym / alias to avoid> |

## Avoid (non-canonical aliases)

Loose words that keep creeping in, and the canonical term to use instead:

- "<loose word>" -> use **<Term>**.

## Open questions

Terms whose meaning is still unsettled — resolve in Grill before they leak into code:

- <ambiguous term> — <what is unclear>
