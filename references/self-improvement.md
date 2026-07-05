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

**A recurring docs-audit finding is a candidate too.** If the same issue shows up in a `docs/audit/*`
report across more than one project (e.g. a persona repeatedly flags the same category of drift),
that pattern is exactly the kind of durable, cross-project, sanitized lesson this harvest step looks
for — treat it the same as a `.wgm/memories.md` entry (`references/docs-audit.md`).
- **Flag plan-invalidating discoveries in the plan itself.** If a lesson learned during this build
  invalidates an assumption behind a still-`pending` task in `IMPLEMENTATION_PLAN.md`, annotate that
  task explicitly (for example `[INVALIDATES: task T7's assumption about X]`) rather than only
  silently appending the lesson to memories. This is the lightweight version of the "significant
  discovery" check from [`BMAD-METHOD`](https://github.com/bmad-code-org/BMAD-METHOD)'s
  `src/bmm-skills/4-implementation/bmad-retrospective/SKILL.md`, not BMAD's full ceremony — wgm
  has no epic/story structure to retro against.

## Cross-pollinate (a second channel — external research)
The flywheel above harvests *internal* lessons from this project's own dogfooding. wgm also grows by
scanning **sibling agent-skill projects on GitHub** for patterns worth assimilating. This is
research, not the per-build code-style seeding `references/gene-transfusion.md` describes — that's a
different, per-project technique used in Triage/Plan to seed one build from one exemplar; this is
wgm-the-skill improving itself from the wider ecosystem.

Reach for it opportunistically, or when a user asks wgm to grow/improve itself. How it works:
1. **Search** GitHub (the GitHub MCP tools, or `web_search` for repo discovery followed by
   `github-mcp-server-get_file_contents` for precision) for skills/frameworks solving problems
   adjacent to wgm's own phases — grilling, loop mechanics, scoring, docs audits, self-testing.
2. **Evaluate** each candidate the same way an internal lesson is judged: durable? Would it help in a
   *different* codebase, not just cosmetic to this one? Can it be sanitized (cite the source repo,
   respect its licence)?
3. **Land it directly.** Because this is discovered while already working *in* `agent-frontier/wgm`,
   skip the outbound `[learn]`-issue round-trip below — that pipeline exists specifically for lessons
   learned while dogfooding wgm *in a different host repo*. Implement the change directly and cite
   the source in `heuristics.md`'s **Provenance** field, exactly as existing entries already do
   (e.g. "ghuntley/Ralph standing guardrail," "Superpowers two-stage review," "octopusgarden").
4. **Not every finding is a change.** A candidate that only confirms an existing design choice is
   already sound is worth a one-line citation, not a behavior change — record the "why we didn't
   change this" so a future pass doesn't re-litigate settled ground.

**Worked example (this session):** researched `saitarrun/devforge-ai` (a sibling `ralph-loop`
skill), `mattpocock/skills` (the credited origin of wgm's `grill-me`-inspired Grill phase), and
`agentskills/agentskills` (the specification wgm's `SKILL.md` already conforms to). Landed: a
spec-drift pre-check in `references/ralph-loop.md`, the `evals/` self-test convention in
`references/evals.md`, and a citation in `references/grilling.md` confirming an existing design
choice. See `references/heuristics.md` for the graduated entries.

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
