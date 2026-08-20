# Reference: files wgm reads and writes

wgm is careful about other people's repositories. This page is the complete inventory of what it
reads, what it creates, and where — so nothing it does is a surprise.

## The placement rule

wgm decides **once, in Triage**, whether to use your project root or a `.wgm/` subdirectory, then
stays consistent:

| Situation | Where artifacts go |
|---|---|
| Greenfield or empty repository | The project root: `specs/`, `scenarios/`, `IMPLEMENTATION_PLAN.md` |
| The root already has `AGENTS.md`, `IMPLEMENTATION_PLAN.md`, or `specs/` | Under `.wgm/` instead |

**Caution:** wgm never overwrites an existing root `AGENTS.md` by default. It writes
`.wgm/AGENTS.md` instead, and touches your root file only with explicit approval that names the file
and the scope of edits.

## Human-facing artifacts

These are meant to be read, reviewed, and usually committed.

| Path | Written when | Purpose |
|---|---|---|
| `IMPLEMENTATION_PLAN.md` | Plan | The prioritized task list. **This is the shared state across iterations** — the one file a fresh agent must be able to resume from. |
| `specs/CONSTITUTION.md` | Plan | Project-wide principles: quality, testing, security, non-negotiables. Written once, referenced by every spec and task. |
| `specs/CONTEXT.md` | Grill or Plan | The domain glossary — one canonical name per ambiguous term. Optional; skip it for trivial builds. |
| `specs/*.md` | Plan | One spec per coherent slice, each with a magic moment, a demo path, and the smallest end-to-end slice. |
| `scenarios/*.yaml` | Plan | Holdout acceptance journeys, tiered 1–3. **The build must not read these.** |
| `AGENTS.md` | Plan, only if absent | A lean "how to build and validate" guide. Never clobbered. |
| `docs/audit/*.md` | Ship/Handoff | The docs-audit paper trail, with every action item labeled Agent action or Operator action. |
| `docs/adr/*.md` | As needed | Architecture decision records for hard-to-reverse choices. |

## Agent-only state

Everything under `.wgm/` is wgm's own working memory. It is gitignored by this repository and should
be gitignored in yours.

| Path | Written by | Purpose |
|---|---|---|
| `.wgm/memories.md` | Loop (Record) | Durable lessons: gotchas, stall causes and fixes, dead ends. Token-budgeted to roughly 2000 tokens. Read at the start of each Analyze. |
| `.wgm/metrics.tsv` | `loop.sh` | Per-iteration telemetry ledger. On by default; disable with `--metrics off`. |
| `.wgm/metrics/PREFIX-N.tsv` | `swarm.sh` | Per-lane ledgers, written into the **parent** worktree so they survive `--cleanup`. |
| `.wgm/worktrees/` | `swarm.sh` | Swarm lane worktrees. Removed by `--cleanup` or `make clean-worktrees`. |
| `.wgm/deferred-work.md` | Review | Credible issues that pre-date the current diff, recorded rather than silently dropped. |
| `.wgm/learning/MAP.md` | `teach-me` | The cited repository map: entry points, structure, conventions, invariants. **wgm's Analyze step reads it when present** — it is the whole-repo model a per-task read never builds. |
| `.wgm/learning/` | `teach-me`, `quiz-me` | Tour progress and the quiz log. |
| `.wgm/STOP` | You, or the agent | Stop sentinel. The loop ends after the current iteration. |

**Note:** Agent-only files may compress aggressively — single-token keys serialized as TOON with an
embedded legend. Human-facing artifacts stay readable prose. See
[artifacts](../../references/artifacts.md).

## Configuration files wgm reads

| Path | Read by | Purpose |
|---|---|---|
| `wgm.yml` or `.wgm/gates.yml` | `loop.sh` | A `gates:` list of commands executed by the host after every build iteration and also shown in the prompt. Auto-detected. |
| `.github/wgm-hive.yml` | Triage, `harvest-hive.sh` | Your project's Hive Growth Loop consent decision. Written once, on the first run, whichever way you answer. |
| `.wgm/required-trailers` or `.github/required-trailers` | `check-trailers.sh` | Mandated commit trailer keys, one per line. |
| `.devcontainer/devcontainer.json` | `devcontainer.sh` | The shared local sandbox definition, scaffolded by `devcontainer.sh init`. |
| `~/.copilot/skills/*/plugin.toml` | Host adapter / Triage metadata | Plugin metadata for the proposed/unwired host integration. The portable runner does not invoke hooks. |

## The consent file

`.github/wgm-hive.yml` is the one file wgm asks about before doing anything else on a new project.

```yaml
consent: false
auto_report: false
sources:
  - dogfood
  - swarm
  - issues
  - cross-pollinate
```

| Field | Effect |
|---|---|
| `consent: false` | Lessons are harvested and anonymized locally, and never leave your machine. |
| `consent: true`, `auto_report: false` | Local anonymize and harvest still run; nothing is published. |
| `consent: true`, `auto_report: true` | One anonymized lesson may be filed upstream per harvest run. |

**Note:** Anonymization is not a listed toggle either way — it always runs. Only the upstream
publish leg is governed by consent. See [self-improvement](../../references/self-improvement.md).

## Suggested .gitignore

If you let wgm work in your repository, add:

```gitignore
/.wgm/
/STOP
```

Keep `IMPLEMENTATION_PLAN.md`, `specs/`, and `scenarios/` **tracked** — they are the durable record
of what was decided and why, and reviewers need them.

**Note:** This repository gitignores `IMPLEMENTATION_PLAN.md`, `specs/`, and `scenarios/` at the
root, which looks like the opposite advice. The reason is narrow: wgm ships *templates*
(`assets/*.template.*`) and dogfoods itself in its own checkout, so live artifacts here would be
confused with shipped ones. In your project, track them.

## What to do next

- [Gates](gates.md) — what validates all of this.
- [loop.sh reference](cli-loop.md) — the flags that change where these files land.
- [Artifacts in depth](../../references/artifacts.md) — formats and the placement rules.
