# Self-improvement — how wgm harvests, reports, and retains its juice

wgm captures lessons every run, but `.wgm/memories.md` is local and git-ignored. This file is the
mechanism that turns those ephemeral lessons into durable upgrades to the shared skill. See the
design in [`docs/plans/2026-06-16_GROWTH_LOOP.md`](../docs/plans/2026-06-16_GROWTH_LOOP.md).

The flywheel: **capture → harvest → report → curate → self-optimize → promote → re-install**.

## Capture (already happens)
- `.wgm/memories.md` — gotchas, stall fixes, patterns, dead ends (token-budgeted, pruned).
- `.wgm/scores.md` — the satisfaction trajectory that exposes stalls.
These are the raw juice. They stay lean: only what helps the *next iteration* of *this* build.

## Harvest (at Ship/Handoff)
After the build is green, scan `.wgm/memories.md` for a lesson that is:
1. **Durable** — it will still be true next month, not a one-off detail of this task.
2. **Cross-project** — it would help wgm in a *different* codebase, not just this one.
3. **Sanitized** — it describes wgm's behavior, never the host's code, secrets, URLs, or data.

A lesson that fails any of the three stays local. One that passes is a candidate to report.

## Report (outbound, opt-in)
File the candidate to [`agent-frontier/wgm`](https://github.com/agent-frontier/wgm) as a `[learn]`
report using the [`heuristic_report.yml`](../.github/ISSUE_TEMPLATE/heuristic_report.yml) template
(`gh issue create --repo agent-frontier/wgm --template heuristic_report.yml`, or fill the fields).

Rules:
- **Opt-in.** Off by default. Report upstream only when the user asks, on a wgm dogfood run, or when
  the project explicitly enables it. Never auto-file from a client repo.
- **De-dup.** Search open `learning`-labelled issues first; add a comment to an existing one rather
  than opening a duplicate.
- **One lesson per report.** Keep each report a single thought, so it maps to a single PR later.

## Self-optimize (inbound, via CI)
A triaged issue is turned into exactly one PR by an agent that runs **with wgm loaded**:
- **Recommended:** assign the labelled issue to the **GitHub Copilot coding agent**. The repo's
  [`.github/workflows/copilot-setup-steps.yml`](../.github/workflows/copilot-setup-steps.yml)
  preinstalls wgm so the agent follows the protocol and opens one PR — "one thought" the maintainer
  merges.
- **Alternative:** a self-hosted, label-gated workflow that invokes a headless agent on the issue
  body. More control, but it spends model credits and needs a token — keep it opt-in.
- **No auto-merge.** Every turn is a human-reviewed PR, and it must pass the same backpressure suite
  (`check-docs`, `skills-ref`, the harnesses) as any other change.

## Promote & retain (the ledger)
When a PR lands a durable lesson, record it in [`heuristics.md`](heuristics.md) — the curated juice
ledger — and fold it into wherever it belongs:
- a one-liner heuristic → `heuristics.md` (always) and, if it changes behavior, `SKILL.md`;
- a recurring failure pattern → a new **holdout scenario** so a future build is graded against it;
- a "why" that needs space → a `references/` or `docs/` note.

**Strategic forgetting.** The ledger is the long-term memory; `.wgm/memories.md` is the short-term
buffer. Prune the buffer aggressively; only graduated lessons persist.

## What this is not
- Not telemetry — nothing is sent automatically; reporting is an explicit, sanitized issue.
- Not auto-merge — the maintainer gates every promotion.
- Not a dumping ground — a lesson earns a ledger entry only by being durable and cross-project.

## Cross-links
[`heuristics.md`](heuristics.md) · [`ralph-loop.md`](ralph-loop.md) (memory) ·
[`artifacts.md`](artifacts.md) (memory format + token economy) ·
[`docs/plans/2026-06-16_GROWTH_LOOP.md`](../docs/plans/2026-06-16_GROWTH_LOOP.md) (the full design).
