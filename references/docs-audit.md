# Docs audit — the core, automatic paper trail

Documentation quality is audited **automatically**, as a mandatory part of the lifecycle — an
operator should never have to ask wgm to "please review the docs." This reference defines when the
audit runs, who reviews (four personas), how a technical writer consolidates their feedback, and what
durable artifact it leaves behind: the **paper trail**.

This complements, and never replaces, `scripts/check-docs.sh` — the deterministic **structural**
check (required files, balanced fences, dead links, placeholders). That check stays the fast, cheap,
every-run gate. This audit is the slower, qualitative pass over what the docs actually *say*.

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
3. **Classify strictly by kind of action, never by persona.** Every surviving finding becomes exactly
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
4. **Structure the report using the project's own README index.** Read the root `README.md` and
   `docs/README.md` (or their equivalents in the host project). Use their existing index/Map
   structure — operator docs vs. agent docs, or whatever grouping the project's own README already
   declares — as the section scaffold for the consolidated report, rather than inventing a new
   taxonomy. As part of this step, verify the index itself: flag any README entry that links to a
   missing file, and any doc that exists but isn't indexed anywhere.

## The paper trail (the artifact)
- **Format:** one file per audit run, from `assets/docs-audit-report.template.md` — four persona
  sections, then the consolidated Agent-action / Operator-action tables, then a Dissent section.
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

## Model selection
The four persona reviewers can run on a frugal model — each is a bounded, single-lens read-only pass.
The technical writer earns a more capable model: consolidation, dissent-preservation, and correct
Agent/Operator classification is the part that is easy to get subtly wrong.

## Cross-links
`references/subagents.md` (dispatch + dissent-preservation) · `references/artifacts.md` (artifact
placement rules) · `scripts/check-docs.sh` (the structural check this complements) ·
`docs/operator/playbook.md` (how an operator reads the resulting report) ·
`references/self-improvement.md` (a recurring finding across projects is a `[learn]` candidate).
