# Memory patterns — optional upgrades for long builds

wgm's default memory is the flat, token-budgeted `.wgm/memories.md` log from
[`ralph-loop.md`](ralph-loop.md). Keep that default for small/medium builds. This file names two
**optional** alternatives for long Full-track builds that outgrow flat-log recall.

## Pattern 1 — Beads-style structured knowledge
Inspired by [choo-choo-ralph](https://github.com/mj-meyer/choo-choo-ralph)'s **Beads-powered**
compounding knowledge.

- **Shape:** replace one append-only page with a **small set of structured records** — by lesson
  category, tagged key/value entries, or one entry per recurring problem class.
- **Why:** once iterations pile up, a flat diary hides the one lesson you need. Structured memory
  compounds: new lessons merge into the right bucket instead of only pushing older lessons down.
- **When to reach for it:** a long **Full-track** build where `.wgm/memories.md` keeps hitting its
  ~2000-token budget and trimming lessons you later need.
- **Guardrail:** keep the structure small and queryable. The win is better recall, not permission to
  hoard context.

## Pattern 2 — Compaction-surviving layered memory
Inspired by [elves](https://github.com/aigorahub/elves)' layered memory described in
`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`.

- **Shape:** split one build's memory into layers with different reload rates — e.g. a live **Plan**
  layer, a **Survival Guide** for durable operating knowledge, a **Learnings** layer for candidate
  lessons, and an **Execution Log** for raw iteration history.
- **Promotion flow:** raw notes graduate **Execution Log → Learnings → Survival Guide** as they
  prove durable.
- **Strategic forgetting:** archive or prune stale raw entries so the actively loaded brief stays
  lean even while the underlying history keeps growing.
- **When to reach for it:** long or multi-day builds where you need both a compact working brief and
  a deeper history that survives compaction/context rotation.
- **Relation to wgm:** this mirrors wgm's existing `heuristics.md` promotion idea —
  `.wgm/memories.md` → durable ledger — but applies that promotion **inside one build**, not just at
  cross-project handoff.

## Default first
- **Flat log stays default:** for most builds, the ordinary `.wgm/memories.md` is simpler and good
  enough.
- **Upgrade only on pressure:** switch patterns only when flat-log recall is measurably failing —
  repeated trimming, missed prior lessons, or a brief that no longer stays lean.

## Cross-links
`ralph-loop.md` · `artifacts.md` · `heuristics.md`
