# wgm self-improvement harvest — batch 1 (issues #29-#37)

**Date:** 2026-07-04 · **Status:** shipping via PR to `main`.

## Problem

wgm's growth flywheel (`references/self-improvement.md`, `docs/plans/2026-06-16_GROWTH_LOOP.md`)
captures dogfood lessons as `[learn]` heuristic-report issues on `agent-frontier/wgm`, but capture
without promotion is only half the loop. Nine open, well-formed `learning`-labelled issues (#29-#37)
had accumulated — real lessons from real dogfood runs (a Rust FFI crate swarm, a manual-merge
autopilot loop that reached 18 open PRs, a Node/elm-pages build on a newer-than-tested runtime, two
web-SEO clone builds, and more) — sitting unread instead of changing how wgm behaves.

## What shipped

All 9 issues promoted in one batch (itself an application of the #36 heuristic below: with only one
other PR open on the repo, one more consolidated PR stays well under the "cap concurrent open PRs"
guidance rather than flooding the maintainer with 9 separate ones). Three overlapping issues
(#32, #33, #35) were consolidated into two coherent sections instead of three redundant patches.

| Group | Issues | Landed in |
|---|---|---|
| Loop discipline | #37 (format only touched files), #31 (search-before-build → deps/companions), #36 (cap open PRs in autopilot) | `references/ralph-loop.md` (Standing guardrails, Stop/regenerate conditions), `SKILL.md` (Loop Analyze/Implement, Stop conditions) |
| Runtime de-risking | #34 (prove an unusual runtime at T1) | `references/ralph-loop.md` (Backpressure in depth), `SKILL.md` (Plan-exit gate) |
| Comparative scoring | #32 (SEO/ranking proxy vs. incumbent), #33 (relative-to-incumbent scoring), #35 (ads/CWV as a perf constraint) | `references/hard-to-test-domains.md` (new "Web SEO / ranking" section), `references/scoring.md` (new "Relative-to-incumbent scoring" section) |
| Swarm planning | #29 (partition file ownership), #30 (feasibility spikes as a stream, NO-GO ≠ stall) | `docs/operator/running-the-loop.md` (new "Planning a swarm well" subsection), `references/stall-recovery.md` (Detecting a stall) |

Every heuristic also gained a dated, provenance-cited entry in `references/heuristics.md` (two new
sections: "Comparative & hard-to-test scoring," "Swarm & parallelism"), following the ledger's
existing Heuristic/Why/Provenance/Landed-in shape.

## Decisions

- **One PR for all 9**, not nine PRs — a direct application of issue #36's own heuristic. Splitting
  would have meant opening a 10th open PR in an otherwise single-open-PR repo; batching them keeps
  the open-PR count low while each issue still gets referenced individually (`Closes #29` … `Closes
  #37`) so merging auto-closes the whole backlog.
- **Consolidated overlapping issues** (#32/#33/#35 all describe the same "unobservable claim → proxy
  → score against a served incumbent" pattern) into two sections rather than three separate patches,
  per curator judgment at the Promote stage — the ledger stays lean and the protocol doesn't repeat
  itself three times for one idea.
- **Chose better-fitting homes than a couple of the issues' own suggestions** where the literal
  "Landed in" field would have diluted a tightly-scoped file: #34's suggestion of
  `references/validation-env.md` (which is scoped tightly to OCI/Podman containers) was redirected
  to `references/ralph-loop.md`'s "Backpressure in depth," which already owns the "first task =
  validation signal" rule this heuristic extends.
- **Issues left open, referenced with `Closes #N`** for GitHub to auto-close on merge — not manually
  closed now, consistent with "no auto-merge, ever; the maintainer gates every promotion."

## Validation

`make validate` (shellcheck + `bash -n` + `scripts/check-docs.sh` + install/loop/swarm harnesses),
`skills-ref validate wgm` (from the parent dir), and `actionlint` — all green. `SKILL.md` grew from
267 to 274 lines (still well under its ~500-line budget). Demo validation: all 6 keyword probes
(`format only`, `mandated companion`, `Web SEO`, `incumbent`, `feasibility spike`, `file ownership`)
and all 9 issue-number citations independently confirmed present via `grep`, matching the tier-1
holdout scenario (`scenarios/heuristics-harvest-tier1.yaml`) — each heuristic is findable exactly
where an agent would consult it mid-loop, not just archived in the ledger.
