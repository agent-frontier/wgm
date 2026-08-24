# Docs audit — the core, automatic paper trail

Documentation quality is a **mandatory lifecycle requirement**. Dispatch has two honest paths: a host
with a native subagent mechanism runs the five roles itself, and every other host runs
`scripts/audit.sh`, the portable dispatcher that drives the same five roles through one opaque
headless agent command. What the portable runner still cannot do is launch *host* subagents — five
briefs against one agent buys independence of context and lens, not of model or tooling. A compatible
host should run the audit without requiring a separate user reminder; if neither dispatch path is
available, the operator must record that limitation rather than claiming the audit passed. This
reference defines when the audit runs, who reviews (four personas), how a technical writer consolidates
their feedback, and what durable artifact it leaves behind: the **paper trail**.

This complements, and never replaces, `scripts/check-docs.sh` — the deterministic **structural**
check (required files, balanced fences, dead links, placeholders, and explicitly marked complete
tables). That check stays the fast, cheap, every-run gate. This audit is the slower, qualitative pass
over what the docs actually *say* and whether a reader can execute the path.

## Why this exists
A loop that only checks structure can still ship stale, misleading, or contradictory prose. And a
qualitative review that isn't wired into the lifecycle only happens when someone remembers to ask for
it — which means most of the time, it doesn't happen, and it leaves no record that it didn't. Both
gaps are closed the same way wgm closes every other gap: make it a gate, and make the gate leave
evidence.

## When it runs (tied to the Triage track, `SKILL.md`)
| Track | Docs audit behavior |
|---|---|
| **Quick** | Skipped. `scripts/check-docs.sh` (structural) remains the only docs gate. |
| **Standard** (default) | Runs **once, at Ship/Handoff** (mandatory) — produces the paper trail before the build can be declared shipped. |
| **Full** | Runs at **Plan-exit** (a baseline pass over the specs/`AGENTS.md`/README as they stand before any code is written) **and** at Ship/Handoff (final), plus opportunistically whenever a Review step sees a diff touching `docs/`, `README*.md`, `AGENTS.md`, or `specs/*`. |

A missing or failing audit at a required gate blocks Ship the same way a failing test does — see the
Ship/Handoff step in `SKILL.md`.

**Batching across a same-session run of PRs (Standard track).** A dedicated audit MAY be deferred
across multiple same-session Standard-track PRs — an agent shipping several small PRs back-to-back
in one session need not stop and dispatch the full four-persona swarm after every single one. What
stays mandatory: a **consolidated pass runs before the session ends**, or before a small cap of
further Standard-track PRs land (the same ~3-5 range already used as the loop's own concurrent-open-PR
ceiling — `references/heuristics.md`, "Loop discipline"), whichever comes first. This deferral is a
cadence, not an exemption: the requirement that a full pass eventually happens over every shipped PR
is never waived, only its batching made explicit instead of silently practiced. A consolidated report
that explicitly names the PR range it covers (the "Covers" column in `docs/audit/README.md`) is
exactly this mechanism working as intended — see `docs/audit/README.md`'s index for a live example of
one dedicated pass consolidating several same-session PRs at once.

## The four personas
Each persona reviews the same doc set through one lens and produces a short, structured finding list
— **observation → severity → recommended action**. No persona edits anything; each only reports.

| Persona | Lens | Typical questions it asks |
|---|---|---|
| **Junior developer** | Clarity & onboarding | Could I get productive from this doc alone? Are terms defined before use? Are steps copy-pasteable? Does it assume knowledge it never gave me? |
| **Senior developer** | Correctness, completeness, maintainability | Is this technically accurate against the current code/behavior? Do the examples still run? Are edge cases and error handling documented, not just the happy path? Does it use `specs/CONTEXT.md`'s canonical terms? |
| **Principal developer** | Architecture, strategic fit, consistency | Does this conform to `specs/CONSTITUTION.md`? Is there drift between what the docs claim and the system's actual boundaries? Do two docs contradict each other? Is this even the right doc to have, or should it be merged/retired as the system grows? |
| **Project manager** | Status, risk, traceability | Does the doc reflect current project status accurately? Are risks/blockers visible? Is progress traceable back to the plan/issues? Would a stakeholder reading only this know what's shipped vs. pending? |

Severity taxonomy, used by all four: **RED** (blocker — actively wrong or misleading), **AMBER**
(major — incomplete, unclear, or drifting), **GREEN** (minor/nit, or no finding).

**Execute the published examples, don't just read them.** "Do the examples still run?" is a
*command to run*, not a question to reason about, and it must be run **against the artifacts the
example actually names** — not a synthetic fixture that resembles them. A synthetic fixture proves
the example's shape; only the real artifact proves the example. This matters most where one option
or flag accepts more than one contract: if a published invocation works against one contract and
silently misbehaves against another, the fix is not a doc tweak — **give the contracts distinct
names and flags, document the boundary between them, and add a misuse regression test** before
closing the finding. A doc-only fix leaves the trap armed for the next reader
(`[learn]` issue #71).

For the **PM** lens, also check whether
[`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`](../docs/plans/2026-06-16_RALPH_LANDSCAPE.md)'s
"point-in-time snapshot" has fallen meaningfully behind the sources that have since been
assimilated. Sweep **both** of these, not just the first: (a)
[`references/heuristics.md`](heuristics.md)'s **Provenance** fields, and (b) any new external-tool
citation landing anywhere else in `references/*.md` this round — a watchlist item can be overtaken
by a topical reference file (a new pattern doc, a loop-mechanics addition) documenting it as an
optional/future pattern without ever touching `heuristics.md`, which is invisible to a check scoped
to (a) alone. If either has drifted, flag it as a finding; do not silently treat the landscape
snapshot as current.

## Evidence and executability gate
Accuracy and executability are separate properties. A sentence can match the code and still leave a
new operator unable to reach the intended state, especially when a prerequisite is phrased as a
capability ("provide a database", "ensure the service is reachable", "have IDs ready"). Treat that
shape as incomplete until the page supplies a runnable command or links to the exact page that does.

For every getting-started or task journey:
- execute the published commands end to end in a clean environment, against the real artifacts they
  name; do not substitute a synthetic fixture that merely resembles them;
- trace every prerequisite to the command or page that satisfies it and reject circular prerequisites;
- deliberately run one invalid or degraded path and record the real operator-facing error string;
- check placeholders and required options by running the command, not by confirming that the prose is
  factually accurate.

For reference tables, a `<!-- wgm: complete-table -->` marker opts the immediately following table
into the structural gate. Every cell must be populated from the validating source; blank cells and
placeholder dashes are open questions, not "not applicable" defaults. Derive constraints from parser
and validation logic, not only from nearby constants or description strings.

When a task crosses an intermediary owned by neither the caller nor the target (CDN, managed proxy,
gateway, mesh, ingress, or platform service), verify that component's documented request eligibility,
response transformation, and cache/compression rules before recommending a change. If the named
artifacts are inert in production, record the actual fix location instead of polishing a cosmetic
config.

## The technical writer (consolidation)
One additional role — the **technical writer** — takes all four persona outputs and produces the
single artifact an operator actually reads. It does not add new opinions of its own; it normalizes.

**Consolidation algorithm:**
1. **Dedupe** — the same underlying issue raised by more than one persona becomes one entry, noting
   which personas raised it.
2. **Preserve dissent** — when personas disagree (different severity, or conflicting recommended
   actions), do **not** average or silently pick a winner. Record it explicitly as a `Dissent` note,
   the same discipline `references/subagents.md` already uses for the two-stage code review — applied
   here across four voices instead of two.
   If all four reports converge with zero dissent, say so in the header — `Unanimous: no dissent recorded` — adapted from `BMAD-METHOD`'s Anti-Consensus Club (`src/core-skills/bmad-party-mode/customize.toml`), surfacing easy agreement as a data point instead of silently assuming it.
3. **Verify before promotion** — persona observations and severity are hypotheses, not Agent actions.
   Verify every finding against the real artifact and its source of truth before classifying it.
   Weight the highest-severity findings first because a false RED/AMBER action is more damaging than a
   missed nit. Record rejected or already-mitigated findings in a `Rejected findings` table with the
   exact command/source check and the evidence that disproved the claim; do not silently drop them.
4. **Classify strictly by kind of action, never by persona.** Every surviving finding becomes exactly
   one of:
   - **Agent action** — the agent can execute this directly and deterministically (fix a broken
     link, update a stale example, add a missing section, sync a duplicated file). No human judgment
     required.
   - **Operator action** — requires a human decision, external confirmation, or access the agent
     doesn't have (deprecate a doc, confirm a security claim with the team, approve a scope change,
     resolve a genuine policy question).
   - A finding's persona of origin is irrelevant to this classification — a junior-dev-raised typo is
     still an *Agent action*; a PM-raised status question can still be an *Operator action* even
     though it came from the "status" lens. The kind of action decides the bucket, nothing else.
5. **Structure the report using the project's own README index.** Read the root `README.md` and
   `docs/README.md` (or their equivalents in the host project). Use their existing index/Map
   structure — operator docs vs. agent docs, or whatever grouping the project's own README already
   declares — as the section scaffold for the consolidated report, rather than inventing a new
   taxonomy. As part of this step, verify the index itself: flag any README entry that links to a
   missing file, and any doc that exists but isn't indexed anywhere.

## Fleet rewrite controls
When a docs fleet applies a structural standard, structure is a compression device, not permission to
inflate every page. Before dispatch, record line counts per file and in aggregate. Give each lane a
target band with both a ceiling and a floor, name what may be removed (for example, result statements
that merely restate an action), and name what must survive (verification points, warnings, security
statements, and runnable commands). After consolidation, measure the same counts again and run a
corpus-wide consistency scan; a net line-count improvement can hide both last-copy deletion and
structure bloat.

When a fact is corrected, sweep the full corpus for both the old and new values, including files whose
titles are unrelated and historical/runbook copies. Search copy-paste commands separately. If a
document cites a measured number or external rule, record the tool/source, inputs, date, and
regeneration command so another reviewer can falsify it.

## The paper trail (the artifact)
- **Format:** one file per audit run, from `assets/docs-audit-report.template.md` — four persona
  sections, then the consolidated Agent-action / Operator-action tables, a `Rejected findings`
  table with verification evidence, then a Dissent section.
- **Placement** follows the same root-vs-`.wgm/` rule as every other artifact
  (`references/artifacts.md`): a greenfield project writes to `docs/audit/`; a project that already
  has `AGENTS.md` / `IMPLEMENTATION_PLAN.md` / `specs/` writes to `.wgm/docs/audit/` instead. Decide
  once, in Triage, and stay consistent.
- **Naming:** `docs/audit/<UTC-timestamp>_<slug>.md`, e.g. `docs/audit/2026-06-20T1830Z_auth-feature.md`.
- **Index:** maintain `docs/audit/README.md`, newest-first, one line per report: date, one-line
  verdict (worst severity found), link.
- **Never gitignored by default.** This is the one hard rule to get right: the audit trail is
  *evidence of work done* for a human operator, so a downstream project must commit it like any other
  deliverable. The exception is wgm's own tool repository, whose `.gitignore` treats its own dogfood
  scaffolding (`/IMPLEMENTATION_PLAN.md`, `/specs/`, `/scenarios/`, `/.wgm/`) as ephemeral because the
  repo ships templates, not live plans — that repo-specific choice must never be copied into a project
  wgm is building for someone else.

## Dispatch (who runs this)
See `references/subagents.md` for the five archetypes (`wgm-docs-junior`, `wgm-docs-senior`,
`wgm-docs-principal`, `wgm-docs-pm`, `wgm-docs-writer`) and the "docs-audit swarm" dispatch order.
The four persona passes are independent of each other (order doesn't matter, and they may run in
parallel); the technical writer always runs last, after all four have reported.

### Portable dispatch (`scripts/audit.sh`)
A host with its own subagent mechanism dispatches the five roles directly. Every other host has
`scripts/audit.sh`: an **opaque-command orchestrator** that drives the same five roles through one
headless agent command, configured exactly like `scripts/loop.sh` (`$WGM_AGENT`, `--agent "CMD"`, a
`--` argv passthrough invoked without eval, and `WGM_PROMPT_STDIN=1` for stdin agents). It assumes no
marketplace, no custom-agent registry, and no proprietary subagent API — only that a command can be
handed a prompt. Full flags in [`docs/reference/cli-audit.md`](../docs/reference/cli-audit.md).

**Ownership boundary — the part that keeps the audit honest:**

| Owner | Owns |
|---|---|
| The four personas | Findings through one lens. Read-only: they never edit a file, never fix a defect, and never classify Agent vs Operator action. |
| `wgm-docs-writer` | Consolidation only — dedupe, dissent, verification, and strict Agent/Operator labels. It adds no opinions of its own. |
| The dispatcher | Ordering, scope equality, failure handling, and **writing every artifact**. It reviews nothing. |

What the dispatcher enforces rather than merely requests:
- **Four identical, bounded scopes.** Every persona receives the same scope text, and none is told
  where another's report lives — independence of lens is the reason there are four.
- **Writer last, on four real reports.** If any persona fails, times out, edits the tree, or returns
  nothing, the writer does **not** run and the whole audit exits non-zero with the reason. Three
  reports consolidated into one file would read as a complete audit with a lens silently missing.
- **No success-shaped artifact from a failed run.** A failing writer produces no file at all; the
  paper trail never gains an entry that implies a pass.
- **Read-only roles, checked not trusted.** The git working tree is snapshotted around every role and
  a mutation fails the run.
- **The holdout stays holdout.** `scenarios/` is never read, named, or modified here — that is
  `wgm-validator`'s alone.
- **Report contract, either half.** `$WGM_AUDIT_REPORT_FILE` is exported per role; a role writes
  there *or* prints to stdout, which the dispatcher captures. An agent that cannot write files is
  still a usable reviewer.

**Placement is a real choice, not a synonym.** `docs/audit/` is the committed paper trail a human
reads; `.wgm/docs/audit/` is wgm's own local path for a project that already owns its `docs/` tree.
The dispatcher picks by the same rule as every other artifact (`references/artifacts.md`) and prints
which rule it applied, so the choice stays visible instead of implied.

**Honest boundary.** Running one agent five times buys independence of *context and lens*, not of
model or tooling. It is a fallback, not an equal: prefer a host that genuinely dispatches
role-specialized subagents, and where neither is available, record the limitation rather than
recording a passing audit.

## Model selection
The four persona reviewers can run on a frugal model — each is a bounded, single-lens read-only pass.
The technical writer earns a more capable model: consolidation, dissent-preservation, and correct
Agent/Operator classification is the part that is easy to get subtly wrong.

## Cross-links
`references/subagents.md` (dispatch + dissent-preservation) · `references/artifacts.md` (artifact
placement rules) · `scripts/audit.sh` + [`docs/reference/cli-audit.md`](../docs/reference/cli-audit.md)
(the portable dispatcher) · `scripts/check-docs.sh` (the structural check this complements) ·
`docs/operator/playbook.md` (how an operator reads the resulting report) ·
`references/self-improvement.md` (a recurring finding across projects is a `[learn]` candidate).
