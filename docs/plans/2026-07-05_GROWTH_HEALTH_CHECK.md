# Growth health check — are we at a good point, or an echo chamber?

**Date:** 2026-07-05 · **Status:** honest self-assessment, requested directly ("be honest if we're
at a good point and need to do more testing with projects") · **Verdict: AMBER.** Solid foundation,
but recent growth has quietly become self-referential. See
[`references/self-improvement.md`](../../references/self-improvement.md) for the mechanism this
assessment feeds a guardrail into.

> **Point-in-time verdict, not a living tracker** (matching
> [`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`](2026-06-16_RALPH_LANDSCAPE.md)'s own convention).
> The live, continuously-updated signal is `references/self-improvement.md`'s **Health check**
> section's "real-dogfood cadence" line — check that first; this doc is the one-time reconstruction
> that justified adding it, not something to keep re-deriving by hand.

## The question

wgm's growth flywheel is: **capture → harvest → report → curate → self-optimize → promote →
re-install** (`docs/plans/2026-06-16_GROWTH_LOOP.md`). It runs on *real* signal — lessons distilled
from actually using wgm to build something, in a codebase wgm doesn't already know. This doc checks
whether that is still what's happening, using the repo's own history as evidence rather than
impression.

## What the evidence shows

```mermaid
timeline
  title agent-frontier/wgm — self-referential vs. real-dogfood signal
  2026-06-16 to 06-21 : PRs #1-#28 — build wgm itself (self-referential, expected at this stage)
  2026-06-28 to 06-29 : Issues #29-#37 filed — REAL cross-project dogfood lessons
  2026-07-04 23:15 to 2026-07-05 19:57 (~20h) : PRs #38-#55 — 17 of 46 total merged PRs, almost entirely self-referential
```

| Period | PRs / issues | Nature | Real project involved? |
|---|---|---|---|
| 2026-06-16 → 06-21 | PRs #1-#28 | Build wgm's own core protocol/features | No — expected at bootstrap |
| 2026-06-28 → 06-29 | Issues #29-#37 opened | **Genuine** dogfood lessons: a Rust FFI crate (swarm file-ownership, #29), a feasibility-spike pattern (#30), search-before-you-build for deps (#31), SEO/CWV comparative scoring (#32-#33, #35), a newer-than-LTS Node/`elm-pages`/`lamdera` build (#34), PR-cap discipline (#36), format-only-touched-files (#37) | **Yes** — different real projects |
| 2026-07-04T23:16 | All 9 issues closed via PR #39 | Harvested into `heuristics.md` in one batch | (retroactive harvest of the above) |
| 2026-07-04T23:15 → 2026-07-05T19:57 (~20h) | PRs #38, #40-#55 (17 of 46 total merged PRs — over a third of the project's entire history, in one contiguous stretch; `#39` gets its own row above) | 4 rounds of docs-audit swarms auditing wgm's *own* docs; several "assimilate GitHub agent-skill findings" PRs that read *other* repos' source (`BMAD-METHOD`, `github/spec-kit`, `open-gsd/gsd-core`, `foundatron/octopusgarden`, `Aider-AI/aider`, `RooCodeInc/Roo-Code`, Kiro, `saitarrun/devforge-ai`, `agentskills/agentskills`) and grafted ideas in as prose; meta-features (devcontainer sandbox, sofaking plugin scaffolding, a cost ceiling) | **No** — none of these PRs ran wgm against an unfamiliar real project |

Supporting signals, checked directly rather than assumed (as they stood before this session's own
dogfood runs below — see the dated update note at the end of this section):

- **Zero new real `[learn]` issues since 2026-06-29.** `gh issue list --repo agent-frontier/wgm
  --state open` and `gh issue list --repo agent-frontier/wgm --state closed --label learning` both
  confirmed it at the time this doc was drafted — the only 9 that existed were #29-#37, all filed in
  a 24-hour window over a week before the latest burst.
- **Zero open issues, zero open PRs** at the time this doc was drafted — the backlog was empty. A
  good moment to redirect effort, not a sign more internal work was queued and waiting.
- **No release has ever been cut** (`gh release list`, `git tag` both empty) despite
  `.github/workflows/release.yml` existing — the flywheel's "re-install and get sharper" leg has
  never actually been exercised by a real downstream pull.
- **The test suite never runs a real agent.** `scripts/test-loop.sh:9` states outright: *"has a real
  pass/fail signal. No real agent, model, or network is needed."* It validates shell mechanics
  (retry/backoff/cost-ceiling/flag-parsing) — never a real build outcome. `evals/evals.json` has 5
  cases and tests trigger/mode-parsing, not build quality (`scripts/check-evals.sh` output: `evals
  fixture schema valid (5 case(s))`).
- **The project's own audit reports already show symptoms of the echo chamber**, independent of
  this assessment:
  - `references/heuristics.md` had grown to 36 `**Heuristic:**` / `**Provenance:**` entries; its own
    ledger intro says to "prune or merge entries that a protocol change has made redundant" — zero
    had ever been pruned (flagged in
    `docs/audit/2026-07-05T0751Z_pr47-48-post-merge-audit.md:96`).
  - `docs/plans/2026-06-16_RALPH_LANDSCAPE.md:10` had to be honestly re-scoped mid-session from a
    "living tracker" to a disclosed "point-in-time snapshot" — it was never refreshed by any of the
    7+ external-research sources landed since, because the process never asked it to be
    (`docs/audit/2026-07-05T0751Z_pr47-48-post-merge-audit.md:98`).
  - The identical citation-hyperlinking defect recurred across audit rounds 2, 3, and 4
    (`docs/audit/2026-07-05T0751Z_pr47-48-post-merge-audit.md:95`) — a symptom of auditing the same
    self-generated content repeatedly rather than content that's been pressure-tested by outside use.

**Update (same session, same branch):** the two "zero" facts above already changed by the time this
branch was ready to open as a PR — acting on this doc's own recommendation, this session ran two
real dogfood probes and harvested `[learn]` issues **#56** and **#57** from them (promoted into
`references/heuristics.md`, now 38 entries, in the same commit). That is the diagnosis working as
intended, not a contradiction: see `references/self-improvement.md`'s Health check section for the
now-current cadence line, which this doc's own guardrail requires be kept up to date going forward.

## Root cause

Two of the flywheel's three channels are healthy and cheap to keep running: **self-referential
meta-work** (building wgm's own features) and **cross-pollination** (external research —
`references/self-improvement.md`'s "Cross-pollinate" section, reading sibling projects on GitHub).
Both are low-friction because they never leave the repo. The third channel — **real dogfood
harvest**, the one the whole flywheel exists to serve — requires something slower and less
comfortable: actually running wgm start-to-finish on an unfamiliar, real, possibly messy codebase
and reporting what genuinely broke. Nothing in the protocol currently makes that imbalance visible;
a maintainer has to reconstruct it by hand, the way this doc just did.

## Verdict

**Good foundation. Not yet at a healthy steady state.** CI is green, the backlog is empty, the
harvest mechanism *works* — it fired once, cleanly, on real signal (issues #29-#37 → PR #39). But
"growing more" right now by adding another docs-audit round or another external-research assimilation
PR has diminishing, even slightly negative, returns: the symptoms above (an unpruned ledger, a
landscape doc quietly going stale, a recurring citation bug) are what an echo chamber looks like
before it gets worse. The highest-leverage next step is generating **fresh, real signal** — which is
exactly what this session's two dogfood runs against real, unrelated external projects
(`SchwartzKamel/floci-az`, Java/Quarkus, and `SchwartzKamel/blogster`, .NET — see issues #56 and #57)
were for — not another pass over wgm's own prose.

## What this doc feeds

A durable guardrail landed in `references/self-improvement.md` alongside this doc: a visible
"real-dogfood cadence" marker and an explicit rule that docs-audit rounds and cross-pollination
don't count as a substitute for real dogfood signal. The goal is that the next time this question
comes up, the answer is a one-line lookup, not a multi-hour reconstruction.

## Cross-links
[`references/self-improvement.md`](../../references/self-improvement.md) (the guardrail this
feeds) · [`references/heuristics.md`](../../references/heuristics.md) (the ledger flagged above) ·
[`docs/plans/2026-06-16_GROWTH_LOOP.md`](2026-06-16_GROWTH_LOOP.md) (the flywheel design) ·
[`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`](2026-06-16_RALPH_LANDSCAPE.md) (the doc that had to be
re-scoped) · [`docs/audit/2026-07-05T0751Z_pr47-48-post-merge-audit.md`](../audit/2026-07-05T0751Z_pr47-48-post-merge-audit.md)
(independent corroboration).
