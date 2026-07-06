# Hive growth loop — unify lessons, anonymize first, consent once

**Date:** 2026-07-06 · **Status:** adopted design record for extending the growth flywheel into a
single hive-facing funnel for wgm's own protocol.

> **Protocol decision for wgm itself.** Per `references/adr.md`'s ADR gate and
> `references/artifacts.md`'s placement rules, this lives in `docs/plans/` rather than `specs/adr/`:
> the repo's root `specs/` tree is deliberately excluded, and the precedent for wgm-the-skill's own
> hard-to-reverse protocol decisions is a dated design record here.

## Executive overview

wgm's current flywheel in `references/self-improvement.md` already knows how to harvest a durable,
cross-project lesson from `.wgm/memories.md` and report it upstream. But the funnel is incomplete in
two ways: it misses lessons produced by `scripts/swarm.sh`'s parallel streams, and its Report step is
still ask-based every single time. That blocks the "continuous automatic growth" the session wanted.

This record adopts a single **Hive Growth Loop**: one funnel that ingests lessons from four sources —
local `.wgm/memories.md`, `scripts/swarm.sh` stream-local memories consolidated by a standing step, a
project's own open GitHub Issues as backlog/context, and Cross-pollinate external research — then
**always anonymizes each lesson before any publication draft exists at all**. Upstream reporting to
`agent-frontier/wgm` becomes fully automatic only after a project has made a one-time, committed team
decision in `.github/wgm-hive.yml`; after that, no per-run re-asking is required.

## The decision

Adopt a unified **Hive Growth Loop** with these rules:

1. **One funnel, four sources.** The growth loop ingests signal from:
   - the existing per-run `.wgm/memories.md` channel in `references/self-improvement.md`;
   - each parallel stream or node memory produced by `scripts/swarm.sh`, consolidated by a standing
     post-run step rather than left isolated in each worktree;
   - the host project's own open GitHub Issues, treated as backlog/context that can surface durable
     friction and recurring demand;
   - the existing Cross-pollinate external-research channel in `references/self-improvement.md`.
2. **Anonymize first, always.** Every lesson is anonymized before wgm drafts anything for upstream
   publication — manual or automatic. Consent changes whether wgm may publish; it does **not** change
   whether wgm must sanitize.
3. **Consent is one-time and committed.** Triage (Phase 0 in `SKILL.md`) checks for
   `.github/wgm-hive.yml`. If the file is absent, that absence itself means "new project for consent
   purposes," so wgm asks once. If the file is present — whether the answer is effectively yes or no —
   wgm never asks again unless the file is deleted.
4. **Automatic means automatic after consent.** When `.github/wgm-hive.yml` says the project consents,
   wgm files anonymized lessons upstream to `agent-frontier/wgm` automatically from then on, with no
   further per-run prompting. If consent is absent or declined, the local harvest still runs; only the
   upstream publish leg stays off.
5. **Use the existing subagent idiom, not a new mechanism.** The courier/consolidator role is added as
   `wgm-hermes`, borrowing the messenger/shared-bus framing from the Hermes pattern but translating it
   into the subagent dispatch model already documented in `references/subagents.md`. Provenance stays a
   first-class concern rather than an afterthought.
6. **No change to merge safety.** This decision automates filing an issue, never opening or merging a
   PR. The no-auto-merge rule remains unchanged.

## Context / forces

- `scripts/swarm.sh` fans work out into parallel git worktrees, and each stream keeps its own isolated
  local state. Today that is excellent for independence and poor for learning: nothing in the script
  consolidates the durable lessons spread across those per-stream memories.
- `references/self-improvement.md`'s current Report rule is intentionally conservative: opt-in,
  off-by-default, and ask-based every time. That protected client repos, but it also meant the same
  consent friction repeated forever, even after a team had already decided it wanted the loop on.
- The opposite extreme — publishing automatically from any project, forever, with no consent and no
  anonymization — is not acceptable. Filing into a public third-party repo without a human in the loop
  creates a real leak/spam risk, especially because the growth loop's raw input can contain
  project-identifying details before it is distilled.
- The consent artifact belongs in `.github/wgm-hive.yml`, not `.wgm/`. `references/artifacts.md`
  makes `.wgm/` deliberately local and gitignored; that is correct for scratch state and wrong for a
  one-time team decision that must survive across clones and teammates.
- `.agent/` and `.ai/` were considered as possible shared agent-config homes and rejected. In this
  ecosystem, `AGENTS.md` is the actual cross-tool convention, while this repo already uses `.github/`
  as its normalized, tool-agnostic shared-config home.
- The trigger point has to be Triage in `SKILL.md`, because that is where wgm already decides how a
  run will operate and where artifact placement / protocol setup decisions belong.
- The design needs provenance, not just publication. The Hermes framing fits that need, and
  `references/subagents.md` already gives wgm a way to express a courier role without inventing a
  separate coordination system.

## Alternatives considered

### Keep Report ask-based forever (status quo)
Rejected. `references/self-improvement.md`'s current rule is safe, but it does not satisfy the
session's explicit goal: continuous automatic growth, including lessons discovered by swarm runs.
Leaving the friction in place keeps the existing blind spot and guarantees repetitive per-run asking.

### Make reporting fully automatic with zero consent step
Rejected after the session's safety discussion. This would maximize convenience at the cost of
publishing to a public third-party repo from unfamiliar client projects with no one-time team choice
and no stable boundary on surprise behavior. The risk is not theoretical; it is the predictable
failure mode if automatic publication ever sees unsanitized or identifying context.

### Store consent in `.wgm/`
Rejected. `references/artifacts.md` defines `.wgm/` as local, gitignored, per-build/per-clone state.
That makes it the wrong place for "ask once, then never ask again": every new machine, teammate, or
clone would effectively become a new consent event.

### Invent a new `.agent/` or `.ai/` directory
Rejected. There is no established cross-tool standard there to justify adding a new top-level config
convention, while this repo already normalizes shared automation/config under `.github/`. Creating a
new directory would add novelty without buying portability.

## Consequences

- wgm gains a new committed artifact type, `.github/wgm-hive.yml`, and Triage gains a new
  once-per-project consent question whose answer persists until that file is deleted.
- Anonymization becomes mandatory and non-configurable on every lesson path — manual harvest,
  automatic reporting, single-stream, or swarm. That is additional processing, but it is the safety
  condition that makes the automatic path acceptable at all.
- `scripts/swarm.sh` gains a standing post-run consolidation step with no extra operator flag. Every
  swarm run now pays that small local aggregation cost, even when upstream reporting is disabled.
- A new `wgm-hermes` role must be documented alongside the existing roster in `references/subagents.md`
  and dispatched from two places: after every swarm run, and at Ship/Handoff for ordinary single-stream
  runs.
- The host project's own open GitHub Issues become part of the growth loop's input surface, so the
  flywheel learns not only from what happened during the run but also from the backlog/context the
  project is already signaling.
- This is ADR-worthy under `references/adr.md`'s gate: it is hard to reverse once projects begin to
  rely on the presence or absence of `.github/wgm-hive.yml`; it is cross-cutting across `SKILL.md`,
  `references/self-improvement.md`, `references/subagents.md`, `references/artifacts.md`, and
  `scripts/swarm.sh`; and it is genuinely debatable because a reasonable engineer could prefer keeping
  upstream reporting ask-every-time forever.

## Cross-links

`references/adr.md` · `references/self-improvement.md` · `references/artifacts.md` ·
`references/subagents.md` · `scripts/swarm.sh` · `SKILL.md` ·
`docs/plans/2026-06-16_GROWTH_LOOP.md` · `docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md`
