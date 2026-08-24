# Evals — does wgm's *output* meet the bar? (not just "does it trigger")

A structured, repo-root fixture (`evals/evals.json`) of realistic prompts paired with an expected
outcome and a set of checkable assertions — adopted from the
[`agentskills.io` specification's own `evaluating-skills.mdx`](https://github.com/agentskills/agentskills/blob/main/docs/skill-creation/evaluating-skills.mdx),
the standard wgm's `SKILL.md` already conforms to for structure and validation
(`skills-ref validate wgm`). This closes half of the "skill-behaviour eval" gap
[`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`](../docs/plans/2026-06-16_RALPH_LANDSCAPE.md)'s watchlist
called for (trigger + lifecycle tests):
[`references/trigger-eval.md`](trigger-eval.md) shipped the trigger half; this is the lifecycle
half. To be precise about what "closes" means here — the *fixture format* now exists; running and
grading it end-to-end still requires a maintainer or a future automated judge (see "How this
differs" and "Automated grading protocol" below).

## How this differs from `trigger-eval.md`
The two fixtures are complementary, not duplicative — they grade different questions:

| | `trigger-eval.md` | `evals/evals.json` (this) |
|---|---|---|
| Question | *Should* wgm activate for this query? | *Given* wgm activates, is the output good? |
| Grades | `SKILL.md`'s frontmatter `description`, mode-parsing rule, use/don't-use bullets | `SKILL.md`'s full instructions end-to-end |
| Shape | A should/should-not table, human-graded | Prompt + expected_output + assertions, human- or LLM-graded |
| Structural backpressure today | An `awk` column-completeness check | `scripts/check-evals.sh` (schema: valid JSON, required keys, non-empty assertions) |

Both share the same honesty scoping: **neither is a script wgm runs on itself.** No live
agent-skill host is wired into this repo to actually invoke wgm as a subagent and grade the
transcript — that requires a harness like Claude Code's subagent isolation or a separate session
per run (see `evaluating-skills.mdx`'s "Spawning runs"). Until then, both fixtures are graded by a
maintainer or a future automated judge; only their *shape* is checked mechanically today.

## What's in `evals/evals.json`
Eleven cases against wgm's own `SKILL.md`, following the upstream schema (`skill_name`, `evals[]` of
`id` / `prompt` / `expected_output` / optional `files` / `assertions`).

The five lifecycle cases:
1. A full-lifecycle greenfield build — proves Triage → Grill → Plan → Loop actually happens, with a
   `Gate check:` block and a validation command run before any task is marked done.
2. A `/wgm plan:`-scoped request — proves it hard-stops at Plan-exit, no Loop iteration runs.
3. A trivial one-file edit (mirrors `trigger-eval.md` row 13) — proves wgm stays out of the way.
4. The mode-vs-request disambiguation case (mirrors `trigger-eval.md` row 5) — proves `/wgm build
   the auth module` gets full-lifecycle treatment, not single-task `build` mode.
5. A Quick-track obvious fix — proves ceremony actually scales down (no scenarios, no Preflight).

The six ruggedness-gate cases (`SKILL.md`, "The ruggedness gate"), one per distinction the gate has
to make — a mandatory gate with no fixture coverage decays into a suggestion, so
`scripts/test-check-evals.sh` asserts all six ids stay present and that each verdict is asserted on:
6. A Plan-exit with a **RUGGED** readiness verdict — proves the gate passes on plan-readiness
   evidence (an exact runnable check design), not on field evidence from unwritten code.
7. A **FRAGILE** verdict — proves it blocks Plan-exit and records a remediation task.
8. An **UNKNOWN** verdict — proves it blocks and records a validation-signal task, never a soft pass.
9. The Quick track's **inline** rubric — proves the invariant survives when the companion isn't
   invoked.
10. A **missing companion** — proves the embedded rubric runs and the missing capability is recorded
    instead of the absence counting as a pass.
11. A requested **bypass** — proves the gate is protocol, not a recommendation that a hurried
    operator can wave off.

## Running an eval by hand
Per `evaluating-skills.mdx`'s pattern: run the prompt twice — once with wgm loaded, once without (or
against a previous `SKILL.md` revision) — in a clean context each time, save outputs, then grade each
assertion PASS/FAIL with concrete evidence (quote the transcript, don't just assert an opinion).
Compare token/time cost against the baseline; a change that improves pass rate but triples tokens is
a different trade-off than one that's both better and cheaper.

## Automated grading protocol
`bash scripts/check-evals.sh` is schema-only (always-on, free, part of `make validate`/CI), and
`bash scripts/test-check-evals.sh` proves that gate fails closed — plus pins the six ruggedness-gate
cases in place, the one content assertion the schema check cannot make.
**`scripts/grade-evals.sh`** is the real, opt-in mechanization of the protocol below — it costs real
agent/API calls, so it is never wired into CI; run it by hand before landing a `SKILL.md`/
`references/*` change that might affect behavior quality. Design note: it grades a candidate
revision of `SKILL.md` by embedding its text directly into the case prompt (not by relying on
wherever an installed skill copy happens to live), so results never depend on install-path staleness
— see `docs/plans/2026-07-08_SKILLOPT_ADOPTION.md` for the full evaluation that led to this shape,
including why it deliberately does **not** depend on the `microsoft/SkillOpt` package itself.

- **Target output schema:** the `grading.json` shape from
  [`anthropics/skills`' `skill-creator`](https://github.com/anthropics/skills/tree/main/skills/skill-creator)
  `references/schemas.md`, reduced to its lean core —
  `{"expectations":[{"text","passed","evidence"}],"summary":{"passed","failed","total","pass_rate"}}`.
  The fuller upstream schema's `execution_metrics`/`timing`/`claims`/`user_notes_summary` fields are
  intentionally left out; wgm's own `evals/evals.json` assertions are already plain strings, so they
  map directly onto the grader's expected inputs without needing that extra machinery.
- **Grader-agent pattern:** for each case, `scripts/grade-evals.sh` spawns a grader subagent call
  (the same configured agent, a fresh prompt) that follows the `anthropics/skills` `agents/grader.md`
  pattern — hand it the transcript plus the case's assertions, and it writes `grading.json` with a
  cited evidence snippet for every assertion. `summary` is always recomputed locally from
  `expectations[]` rather than trusted from the grader's own arithmetic.
- **Usage:** `./scripts/grade-evals.sh` grades every case against the current `SKILL.md`, using the
  same `$WGM_AGENT`/`--agent`/`--` convention as `scripts/loop.sh`. Add `--baseline <git-ref>` to
  also grade against `SKILL.md` as it existed at that ref and print a gate verdict — `ACCEPT` (no
  case regressed) or `REGRESSION` (exit 1) — the one idea borrowed from SkillOpt's validation gate,
  expressed as a single comparison rather than a training loop.
- **Not yet automated:** aggregating *many* paired runs into a `benchmark.json` (mean/stddev/min/max
  across repeated trials) is `skill-creator`'s `python -m scripts.aggregate_benchmark` — still a
  manual step if you want it; `scripts/grade-evals.sh` covers one paired run per invocation, which
  is enough to gate a single change.

## Adding a case
- Start small (2-3), vary phrasing and formality, include at least one edge case.
- Write assertions that are specific and checkable ("a `Gate check:` block is printed"), not vague
  ("the output is good").
- Run `bash scripts/check-evals.sh` — schema backpressure only; it does not grade the case.

## Placement & backpressure
`evals/evals.json` lives at the repo root (alongside `SKILL.md`), matching the upstream convention
of `evals/` sitting next to the skill it tests. `assets/evals.template.json` is the reusable
skeleton for other skills/projects wgm builds. `scripts/check-evals.sh` validates the fixture's
schema and is part of `make validate` / CI, same as `scripts/check-docs.sh`. `scripts/grade-evals.sh`
is **not** part of `make validate`/CI — it costs real agent/API calls, so it stays a manual,
opt-in step (`scripts/test-grade-evals.sh` is its own fake-agent smoke test and *is* CI-safe).

## Cross-links
[`references/trigger-eval.md`](trigger-eval.md) (the companion trigger-classification fixture) ·
[`references/scoring.md`](scoring.md) (the LLM-as-judge pattern grading follows) ·
[`references/self-improvement.md`](self-improvement.md) (where this was assimilated from external
research) · [`references/heuristics.md`](heuristics.md) (Comparative & hard-to-test scoring — the
SkillOpt-derived gate heuristic) · `assets/evals.template.json` · `scripts/check-evals.sh` ·
`scripts/grade-evals.sh` · `docs/plans/2026-07-08_SKILLOPT_ADOPTION.md`.
