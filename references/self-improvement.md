# Self-improvement — how wgm harvests, reports, and retains its juice

wgm captures lessons every run, but `.wgm/memories.md` is local and git-ignored. This file is the
mechanism that turns those ephemeral lessons into durable upgrades to the shared skill — the **Hive
Growth Loop**: one funnel, four sources, a mandatory anonymize step, and (once a project consents
once) automatic upstream reporting with no further per-run asking. See the original design in
[`docs/plans/2026-06-16_GROWTH_LOOP.md`](../docs/plans/2026-06-16_GROWTH_LOOP.md) and the
consent/automation extension in
[`docs/plans/2026-07-06_HIVE_GROWTH_LOOP.md`](../docs/plans/2026-07-06_HIVE_GROWTH_LOOP.md).

The flywheel: **capture → swarm harvest → harvest → anonymize → report → curate →
self-optimize → promote → re-install**.

## Capture — four sources feed one funnel
- `.wgm/memories.md` — gotchas, stall fixes, patterns, dead ends (token-budgeted, pruned).
- `.wgm/scores.md` — the satisfaction trajectory that exposes stalls.
- **Swarm-stream memories (new).** Each `scripts/swarm.sh` stream keeps its own isolated
  `.wgm/memories.md` in its own worktree; a standing post-run step consolidates every stream's file
  into the invoking worktree's `.wgm/memories.md`, tagged by origin branch, before any cleanup. See
  **Swarm harvest** below.
- **This project's own GitHub Issues (new).** A project's open issues are backlog/context for
  Triage's *discovery* step, not raw input `Harvest` scans the way it scans `.wgm/memories.md` — see
  [`issue-intake.md`](issue-intake.md) for the discovery and traceability discipline. wgm's own
  `[learn]`-labelled issues are one specialized case of this same channel (see **Relationship to
  `[learn]` issues** in that doc).
- Cross-pollinate / external research (below) is the fourth channel, feeding wgm-the-skill's own
  growth from sibling projects rather than from this build.

These are the raw juice. They stay lean: only what helps the *next iteration* of *this* build — the
swarm and issue channels widen where that juice comes from, but keeping the file small still depends
on the later Record-step trim discipline; swarm consolidation itself appends the full per-stream
files first.

## Swarm harvest (consolidating parallel streams)
`scripts/swarm.sh` fans work into parallel git worktrees so streams never collide — but that also
means each stream's lessons stay stranded in its own worktree unless something brings them back.
Terminology here is exact: **swarm** = the parallel-worktree mechanism in `scripts/swarm.sh`; a
**stream** = one worktree/branch inside that swarm; the **hive** = the shared upstream
`agent-frontier/wgm` that consented builds ultimately report to.
The standing (unconditional, no flag) post-run step in `scripts/swarm.sh` does exactly that: after
all streams finish and before any `--cleanup` removes their worktrees, it appends each stream's
`.wgm/memories.md` into the invoking worktree's `.wgm/memories.md`, each block tagged with an HTML
comment naming its origin branch (e.g. `<!-- from wgm/swarm/2 -->`). This always runs — every swarm
run pays this small local cost, whether or not the project has consented to automatic upstream
reporting (below). Harvest then reads the consolidated file exactly as it would a single-stream
build's; a swarm-sourced lesson is just one more candidate, not a different kind of one.
Important: `scripts/swarm.sh` does **not** trim after consolidation; it appends each per-stream file
verbatim. The ~2000-token trim rule only re-enters later when an agent does the Record-step memory
maintenance described in `references/ralph-loop.md` / `references/artifacts.md`, not during swarm
consolidation itself.

**Worked example:** if stream 1 and stream 2 each wrote their own `.wgm/memories.md`, the invoking
worktree's consolidated file grows by tagged blocks in exactly this format:

```md
<!-- from wgm/swarm/1 -->

- Retry after regenerating the lockfile before escalating the build harness.

<!-- from wgm/swarm/2 -->

- Capture the flaky seed before rerunning the validator.
```

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

## Anonymize (mandatory, every path, not a lever)
Harvest's **sanitized** criterion above is a judgment call: does this lesson touch the host's code,
secrets, URLs, or data at all? Anonymize is the mechanical follow-up that runs regardless of that
judgment, on every candidate lesson before it is ever drafted for upstream publication — because a
judgment call can be wrong, and automatic reporting (below) removes the human read-through that used
to be the last check that would have caught it.

Scrub, at minimum:
- project, org, and repo names (the host project's, not wgm's own);
- file paths and directory structure specific to the host project;
- URLs, hostnames, and endpoints that aren't already public/wgm's own;
- usernames, emails, and any credential-shaped string (tokens, keys, connection strings).

Keep only the generalizable technical lesson — the same bar `heuristics.md` entries already hold
themselves to. **This is a first-pass deterministic scrub, not a redaction guarantee** — state that
limitation plainly wherever this step is described or implemented; it lowers risk, it does not
eliminate the need for the criteria in Harvest above. Anonymization applies whether a report ends up
filed by hand or automatically (below); it does not apply to Cross-pollinate's inbound direction
(reading *other* repos' public source raises citation/licensing concerns, not host-data exposure).
`wgm-hermes` (`references/subagents.md`) is the subagent role that owns this step end to end —
aggregate, anonymize, check consent, publish — named for the messenger-god framing of this courier
role, translated into wgm's existing subagent-dispatch idiom rather than a new mechanism;
`heuristics.md`'s own **Provenance** field already gives wgm a concrete way to preserve where a
lesson came from.

**Worked example:** a raw memory line like `- Repro at https://build.internal/runbook from /home/alice/acme/service with TOKEN=ghp_example123; notify alice@example.com about acme/api.` is anonymized (verified against the actual script output) into `- Repro at <redacted-url> from <redacted-path> with <redacted-credential> notify <redacted-email> about <redacted-repo>.` — note the credential-token match also absorbs its trailing punctuation (the `;` disappears along with the token), a small but real artifact of the regex, not a typo here. Separately, a *standalone* internal-style hostname not already inside a URL — e.g. `- Saw it happen on build.internal again today.` — becomes `- Saw it happen on <redacted-host> again today.`; a hostname that's already part of a matched URL (like `build.internal` above) is redacted as part of that URL instead, not a second time.

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

## Report (outbound, opt-in by default, automatic once consented)
File the candidate to [`agent-frontier/wgm`](https://github.com/agent-frontier/wgm) as a `[learn]`
report using the [`heuristic_report.yml`](../.github/ISSUE_TEMPLATE/heuristic_report.yml) template
(`gh issue create --repo agent-frontier/wgm --template heuristic_report.yml`, or fill the fields).
Every candidate is anonymized (above) before it is ever drafted, on either path below.

Rules:
- **Opt-in by default.** Off by default. Without consent (below), report upstream only when the
  user asks or on a wgm dogfood run. Never auto-file from a client repo that hasn't consented.
- **De-dup.** Search open `learning`-labelled issues first; add a comment to an existing one rather
  than opening a duplicate. This still applies on the automatic path.
- **One report per harvest run, not per lesson.** `scripts/harvest-hive.sh` anonymizes and files the
  *current consolidated* `.wgm/memories.md` as a single report — it does not (yet) split a
  multi-entry file into one issue per lesson. Keep the source file itself lean and single-threaded
  (`references/artifacts.md`'s token budget already asks for this) so a report stays a coherently
  single thought in practice; treat true per-lesson extraction as a known follow-up, not a shipped
  guarantee.

### Consent & continuous mode
This section is the canonical source for the one-time consent-question wording; other docs/templates
(such as `SKILL.md`, `references/artifacts.md`, and `assets/wgm-hive.template.yml`) should cite this
section rather than restating the prompt verbatim.

Triage (`SKILL.md` Phase 0) checks the project root for `.github/wgm-hive.yml`
(`assets/wgm-hive.template.yml` is the scaffold). Its presence or absence — not a per-run
question — decides which path applies:

- **Absent, human present → ask once, then never again.** If the file doesn't exist, that absence is
  what makes this "a new project" for consent purposes: wgm asks the consent question as the literal
  first thing it does in Triage, before any other Triage or Grill question. Whatever the answer, wgm
  writes `.github/wgm-hive.yml` with it — `consent: true` or `consent: false` — so the question is
  never asked again on this project unless a human deletes the file. The file is committed (not
  `.wgm/`, which is gitignored/local-only) so the decision is made once for the whole team, not once
  per clone or machine.
- **Absent, no human present (headless/non-interactive)** — `scripts/harvest-hive.sh` (dispatched
  standing after every swarm, and at Ship/Handoff) never persists a decision on an absent human's
  behalf: it declines *for that run only* and leaves the file unwritten, so the next interactive
  Triage session still gets to ask a real person. This mirrors `references/stall-recovery.md`'s
  existing unattended convention (preserve, don't guess) rather than inventing a new one. The same
  safe degrade holds under concurrency too: if multiple non-interactive `scripts/harvest-hive.sh`
  runs arrive at once (for example, nearby swarm streams finishing together), each one independently
  declines for its own run and writes nothing, so there is no shared mutable `false` race to win.
- **Present, `consent: true` and `auto_report: true` (its default)** — fully automatic. Filing
  happens with no further per-run prompting: anonymized, de-duped, one report per harvest run. This
  is what makes "continuous automatic growth" real instead of aspirational.
- **Present, `consent: true` but `auto_report: false`** — local anonymize/harvest still runs and is
  printed for a human to read, but nothing is filed upstream; use this to review drafts before
  turning the last switch on.
- **Present, `consent: false` (regardless of `auto_report`)** — today's ask-based path, permanently:
  local Capture/Harvest still run (the `sources:` list can trim which channels feed even that, though
  anonymization itself is never a listed, toggle-able field); only the upstream publish leg waits for
  an explicit ask.
- **Standing dispatch, consent-gated filing.** `scripts/swarm.sh` unconditionally hands its
  just-consolidated memories to `scripts/harvest-hive.sh` after every run — that *dispatch* always
  happens; whether it actually *files* anything upstream still depends entirely on the consent state
  above, exactly as it would at Ship/Handoff.
- **Automatic reporting still counts as self-referential when it's about wgm's own repo.** Filing a
  `[learn]` issue automatically doesn't change what it *is* — the **Health check** guardrail above
  still applies to it exactly as it would to a hand-filed one; automation is not a loophole around
  "go dogfood a real project."
- **No change to merge safety.** This only automates filing an *issue*; it never opens or merges a
  PR. **Self-optimize** below is unaffected and still always human-reviewed.

`wgm-hermes` is the subagent that runs this whole path — aggregate the consolidated sources,
anonymize, read `.github/wgm-hive.yml`, and (if consented) file or update the issue
(`references/subagents.md`).

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
- **No telemetry without consent, ever** — once a project consents, reporting genuinely is automatic
  and unprompted per run; that's the honest trade being made, not a contradiction. What's guaranteed
  instead: it can never start without an explicit, recorded, committed, reversible decision in
  `.github/wgm-hive.yml`; it is never silent instrumentation (every report is anonymized first and
  stays a plain, human-readable GitHub issue, not a telemetry payload); and it can be turned off
  again just as explicitly by editing or deleting that same file.
- Not auto-merge — the maintainer gates every promotion; consent only ever automates filing an
  issue, never opening or merging a PR.
- Not a dumping ground — a lesson earns a ledger entry only by being durable and cross-project.

## Cross-links
[`heuristics.md`](heuristics.md) · [`evals.md`](evals.md) (a Cross-pollinate-landed capability) ·
[`ralph-loop.md`](ralph-loop.md) (memory) ·
[`artifacts.md`](artifacts.md) (memory format + token economy + `.github/wgm-hive.yml` placement) ·
[`issue-intake.md`](issue-intake.md) (the GitHub-Issues source channel + `[learn]`'s place within it) ·
[`subagents.md`](subagents.md) (`wgm-hermes`) ·
[`docs/plans/2026-06-16_GROWTH_LOOP.md`](../docs/plans/2026-06-16_GROWTH_LOOP.md) (the original design) ·
[`docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md`](../docs/plans/2026-07-05_GROWTH_HEALTH_CHECK.md)
(the Health check section's worked example) ·
[`docs/plans/2026-07-06_HIVE_GROWTH_LOOP.md`](../docs/plans/2026-07-06_HIVE_GROWTH_LOOP.md)
(the consent/anonymize/automation extension recorded in this file).
