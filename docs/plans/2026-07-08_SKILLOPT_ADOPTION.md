# SkillOpt's grading discipline — adopt the idea, not the package

**Date:** 2026-07-08 · **Status:** accepted · **Trigger:** direct research request ("look at
https://github.com/microsoft/SkillOpt can we optimize wgm with it? plan it out and let's see if
there's value in doing so at all") · Follows the ADR (Architecture Decision Record) shape from
[`references/adr.md`](../../references/adr.md) / [`assets/adr.template.md`](../../assets/adr.template.md);
recorded under `docs/plans/` per that file's own carve-out for this repo (root `/specs/adr/` is
gitignored scratch here — see `.gitignore`).

## Context

[`microsoft/SkillOpt`](https://github.com/microsoft/SkillOpt) (MIT, PyPI `skillopt`) treats an
agent's skill document as trainable "weights": rollout → reflect → bounded edit → **validation
gate** — a candidate edit is accepted only if it strictly beats a held-out score. Its
`SkillOpt-Sleep` companion runs this nightly for coding agents: harvest real session transcripts →
mine recurring tasks → replay → consolidate behind the same gate → stage a proposal for human
review/adopt. It already ships Claude Code, Codex, and Copilot-MCP-server plugin shells.

wgm already has the same idea, informally:
- `references/self-improvement.md`'s Hive Growth Loop (harvest → anonymize → report → curate) is
  SkillOpt-Sleep's harvest/mine/consolidate, minus a quantitative gate — curation today is human
  judgment on GitHub, not a held-out score.
- `references/evals.md` **already names the exact gap** SkillOpt fills: its "Automated grading
  protocol" section specifies a target schema (`grading.json`, from `anthropics/skills`
  `skill-creator`) and mechanism (a grader subagent per `agents/grader.md`), then says plainly:
  "this is not a new script landing in this PR." wgm had already designed this, just never built it.
- `references/scoring.md`'s "Relative-to-incumbent scoring" section is already the same shape as
  SkillOpt's gate: score a candidate against a live baseline, accept only at parity-or-better.

Three explicit constraints shaped the evaluation (session preferences, applied broadly): stay
**portable/lean** (avoid a new runtime dependency if avoidable), prefer the **simplest elegant
solution** (never add complexity for its own sake), and **minimize steps** in any resulting
workflow (a "rule of 3" — few clicks/commands to get value).

Two concrete gaps rule out depending on the real package as-is:
- `skillopt_sleep/harvest.py` and `harvest_codex.py` read **Claude Code** and **Codex** local
  transcript files; neither reads Copilot CLI's own session storage, so SkillOpt-Sleep's harvest
  stage can't run against wgm's Copilot CLI install target today (only the Claude Code target would
  work out of the box).
- The full `skillopt` package's dependencies (`openai`, `azure-identity`, `numpy`, `openpyxl`, …) are
  a real new Python/API-key surface for a repo that is deliberately bash + Markdown, with exactly one
  existing Python helper (`scripts/wgm_plugin_registry.py`).

A third piece — SkillOpt's rule-based judge vocabulary (`judges.py`: `contains` / `regex` /
`section_present` / `min_chars` / `max_chars`) — is built for benchmark-style ground truth. Most of
`evals/evals.json`'s own assertions are procedural/behavioral ("no task is marked done without its
validation command having been run and shown to exit 0"), not lexical, so a mechanical rule-checker
would only cover a slice of them — duplicating judgment logic the existing LLM-judge pattern
(`scoring.md`) already covers more directly, for the cost of a new schema and a new vocabulary to
maintain.

## Decision

Adopt the **technique**, not the **package**, in two tiers:

1. **Document it** — a `SkillOpt-Sleep` bullet in `SKILL.md`'s Related Skills & Plugins section, a
   `heuristics.md` entry (Provenance: external research), and this record.
2. **Build the one real gap it names, leanly** — `scripts/grade-evals.sh`, a new script that
   mechanizes `evals.md`'s already-specified automated grading protocol (the grader-agent pattern,
   the `grading.json` schema) using conventions that already exist (`loop.sh`'s
   `$WGM_AGENT`/`--agent` invocation, `scoring.md`'s judge-prompt shape). It adds exactly one new
   idea borrowed from SkillOpt — an optional `--baseline REF` flag (REF being a git ref) that gates on non-regression
   against a prior `SKILL.md` revision — expressed as a single comparison, not a package, a schema
   change, or a judge vocabulary.

Declined for now: depending on the real `skillopt`/`skillopt-sleep` PyPI package (no native
Copilot-CLI harvest; a real new dependency; solves nightly-automation, which wgm doesn't need yet
when the cheap version already closes the named gap).

## Alternatives considered

- **Depend on the real `skillopt-sleep` package directly** (register its Copilot MCP server, point
  it at wgm's own repo) — not chosen: no Copilot-CLI transcript harvest yet (would silently run on
  zero real sessions for this install target), and it pulls in a Python/API-key dependency surface
  this repo has deliberately avoided.
- **Build a Copilot-CLI harvest adapter ourselves, then use the real package** — not chosen: real
  engineering (a new harvest module, credential/config plumbing) to enable a nightly-automation
  capability wgm doesn't have a demonstrated need for yet; revisit only if Tier 2 proves valuable and
  demand grows for full automation.
- **Port SkillOpt's hard/soft rule-judge vocabulary into `evals/evals.json`** (a `checks` array of
  `contains`/`regex`/... per assertion) — not chosen: most existing assertions are procedural, not
  lexical, so this would cover a minority of cases while adding a new schema and an op vocabulary to
  keep in sync — the "simplest elegant solution" constraint argues against it when the existing
  LLM-judge pattern already handles these more directly.
- **Do nothing (Tier 1 only, no script)** — not chosen: `evals.md` already specifies the automated
  grading protocol in enough detail that building it is a small, self-contained, dependency-free
  task; leaving it undocumented-but-unbuilt indefinitely was the status quo this research was asked
  to re-examine.

## Consequences

- **Upside:** wgm gains a real, runnable version of the automated grading protocol `evals.md` always
  intended, plus a lightweight non-regression gate for `SKILL.md` changes — with zero new
  dependencies, zero `evals/evals.json` schema changes, and a single-command default invocation.
- **Upside:** the research is preserved and citable (`heuristics.md`, this record) even though the
  package itself isn't adopted — a future pass can revisit Tier 3 cheaply if circumstances change
  (e.g. Copilot CLI grows a stable local transcript format).
- **Trade-off:** `scripts/grade-evals.sh` duplicates a small amount of `loop.sh`'s agent-invocation
  logic rather than refactoring it into a shared function — an explicit lean/low-risk choice (avoid
  touching the well-tested `loop.sh`) accepted in exchange for a few duplicated lines.
- **Trade-off:** grading still costs real agent/API calls per run, so it stays **opt-in**, never
  wired into `make validate` or CI — a maintainer must remember to run it before landing a
  behavior-affecting `SKILL.md`/`references/*` change; it does not (yet) run automatically on every
  PR the way `scripts/check-evals.sh`'s schema check does.
