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
3. **Land it directly.** This shortcuts the outbound `[learn]`-issue round-trip described in
   **Report** below — but only when *both* conditions hold: the finding came from **external
   research**, *and* it was found while already working in `agent-frontier/wgm`. An *internal*
   lesson discovered mid-session in this same repo does not qualify for this shortcut — the Report
   pipeline exists specifically for lessons learned while dogfooding wgm *in a different host repo*,
   and still takes that outbound round-trip. When both conditions do hold, implement the change
   directly and cite the source in `heuristics.md`'s **Provenance** field as `external research,
   <owner/repo>'s <thing>` (e.g. `external research, saitarrun/devforge-ai's ralph-loop skill`) —
   the expected prefix for this provenance category, distinguishing it from a bare design-lineage
   citation predating this mechanism (e.g. "ghuntley/Ralph standing guardrail," "Superpowers
   two-stage review," "octopusgarden") or an internal `wgm dogfood, [learn] issue #N` entry.
   **Hyperlink the citation's fullest or first mention** in the landed reference content itself —
   `` [`owner/repo`](https://github.com/owner/repo) ``, not just a bare backticked name (the
   `heuristics.md` Provenance field stays a plain compact citation regardless); later, secondary
   mentions of the same repo elsewhere may stay bare backticks.
4. **Not every finding is a change.** A candidate that only confirms an existing design choice is
   already sound is worth a one-line citation, not a behavior change — record the "why we didn't
   change this" so a future pass doesn't re-litigate settled ground.
5. **A single research session's findings may be batched into one or a few PRs.** The Report
   section's "one lesson per report" discipline (below) guards against an unrelated flood of separate
   `[learn]` issues arriving from different dogfood runs; that "flood the maintainer" risk doesn't
   apply the same way to one contributor's own direct-land research pass over a single sitting.
   Batching a session's related findings into one or a few PRs is fine — it is the real, repeated
   practice so far, not an exception to be justified each time.
6. **Sync the summary docs in the same PR.** If the landed change modifies a checklist or schema
   inside a `references/*.md` file, grep `SKILL.md` and `docs/agent/*.md` for any restatement of the
   same content (an inline gate checklist, a mirrored signal list, a restated field) and update it in
   the same PR. Two references/*.md checklist changes drifted from their `SKILL.md` mirrors this way
   in one round before this rule existed (round-3 docs audit, `docs/audit/` — the Grill-exit gate and
   the stall-signal list) — don't defer the sync to a later audit pass; the audit is a backstop, not
   the mechanism that's supposed to catch this.

**Worked example (this session):** researched `saitarrun/devforge-ai` (a sibling `ralph-loop`
skill), `mattpocock/skills` (the credited origin of wgm's `grill-me`-inspired Grill phase), and
`agentskills/agentskills` (the specification wgm's `SKILL.md` already conforms to). Landed: a
spec-drift pre-check in `references/ralph-loop.md`, the `evals/` self-test convention in
`references/evals.md`, and a citation in `references/grilling.md` confirming an existing design
choice — all three batched into one PR rather than three separate ones (see step 5). See
`references/heuristics.md` for the graduated entries.

## Health check (a standing guardrail against self-referential drift)
Harvest is designed to be cross-project by definition (above: "it would help wgm in a *different*
codebase"), and Cross-pollinate reads *other* GitHub repos' source for the same reason — both have
delivered on that (issues #29-#37, #56-#57; the external-research citations throughout
`heuristics.md`). The risk isn't that either channel is structurally confined to this repo; it's
that both are cheaper to keep running than the thing that actually feeds Harvest real material:
**running wgm on an unfamiliar real project and reporting what genuinely broke.** A run of
self-referential meta-work (auditing this repo's own docs) or Cross-pollinate assimilation (reading
about other tools without ever running wgm against a real one) can quietly substitute for that,
because neither leaves the repo to go find out. Nothing else in this file polices that balance, so
make it explicit and checkable rather than something a maintainer has to reconstruct by hand:

- **Real-dogfood cadence — update this line whenever a new one lands:** last real, cross-project
  `[learn]` issue(s) — issues **#56-#57, #59** (2026-07-05), sourced from two genuinely different
  real projects (`SchwartzKamel/floci-az`, Java/Quarkus, and `SchwartzKamel/blogster`, .NET);
  issue #59 is the stale-clone / retired-target lesson harvested from the `blogster` run. Previously:
  issues #29-#37 (2026-06-28/29), sourced from a Rust FFI crate's swarm file-ownership, an
  `elm-pages`/`lamdera` build on a newer-than-LTS Node, a web-SEO/CWV comparative-scoring project,
  and a feasibility-spike case.
- **The rule:** a run of docs-audit passes and/or Cross-pollinate (external-research) PRs with *no*
  real dogfood issue landing in between is not evidence that "no more growth is needed" — it is a
  signal to go dogfood a real, different project before adding another audit round or another
  assimilated finding. Concretely: after roughly 3 self-referential or external-research PRs in a
  row with no real-dogfood issue between them, the next self-improvement action should be running
  wgm on a real project, not another audit or assimilation pass.
- **Target-freshness guardrail:** before counting a local clone as that next real dogfood
  project, `git fetch` it and check for archival/retirement signals (`ARCHIVED.md`, a retirement
  commit message, or GitHub's archived flag); a stale clone can masquerade as a live target and
  waste a run on a project the owner already retired.
- **Worked example:** [`docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md`](../docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md)
  reconstructed exactly this pattern from the repo's own history (17 of 46 merged PRs, in one ~20-hour
  stretch, almost entirely self-referential, with zero new real dogfood issues since 06-29) and used
  it to justify pausing meta-work in favor of two fresh dogfood runs against unrelated real projects.

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
[`heuristics.md`](heuristics.md) · [`evals.md`](evals.md) (a Cross-pollinate-landed capability) ·
[`ralph-loop.md`](ralph-loop.md) (memory) ·
[`artifacts.md`](artifacts.md) (memory format + token economy) ·
[`docs/plans/2026-06-16_GROWTH_LOOP.md`](../docs/plans/2026-06-16_GROWTH_LOOP.md) (the full design) ·
[`docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md`](../docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md)
(the Health check section's worked example).
