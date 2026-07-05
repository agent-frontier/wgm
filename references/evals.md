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
Five cases against wgm's own `SKILL.md`, following the upstream schema (`skill_name`, `evals[]` of
`id` / `prompt` / `expected_output` / optional `files` / `assertions`):
1. A full-lifecycle greenfield build — proves Triage → Grill → Plan → Loop actually happens, with a
   `Gate check:` block and a validation command run before any task is marked done.
2. A `/wgm plan:`-scoped request — proves it hard-stops at Plan-exit, no Loop iteration runs.
3. A trivial one-file edit (mirrors `trigger-eval.md` row 13) — proves wgm stays out of the way.
4. The mode-vs-request disambiguation case (mirrors `trigger-eval.md` row 5) — proves `/wgm build
   the auth module` gets full-lifecycle treatment, not single-task `build` mode.
5. A Quick-track obvious fix — proves ceremony actually scales down (no scenarios, no Preflight).

## Running an eval by hand
Per `evaluating-skills.mdx`'s pattern: run the prompt twice — once with wgm loaded, once without (or
against a previous `SKILL.md` revision) — in a clean context each time, save outputs, then grade each
assertion PASS/FAIL with concrete evidence (quote the transcript, don't just assert an opinion).
Compare token/time cost against the baseline; a change that improves pass rate but triples tokens is
a different trade-off than one that's both better and cheaper.

## Automated grading protocol (when a live agent-skill host is available)
This repo's current automation still stops at `bash scripts/check-evals.sh`: **schema only**. The
protocol below is what to follow by hand or via future automation; it is **not** a new script
landing in this PR.

- **Target output schema:** use the `grading.json` shape from
  [`anthropics/skills`' `skill-creator`](https://github.com/anthropics/skills/tree/main/skills/skill-creator)
  `references/schemas.md` as the canonical per-run output —
  `{"expectations":[{"text","passed","evidence"}],"summary":{"passed","failed","total","pass_rate"}}`.
  wgm's own `evals/evals.json` assertions are already plain strings, so they map directly onto the
  grader's expected inputs.
- **Grader-agent pattern:** for each wgm run, spawn a grader subagent that follows
  `anthropics/skills` `agents/grader.md`, hand it the run transcript plus the case's assertions, and
  have it write `grading.json` with a cited evidence snippet for every assertion.
- **Aggregation:** once you have multiple paired runs with and without wgm, run
  `python -m scripts.aggregate_benchmark <workspace>` from the same `skill-creator` repo. That
  produces a `benchmark.json` with mean/stddev/min/max for pass rate, time, and tokens, plus the
  delta between the with-wgm and baseline configurations — the concrete schema
  `evaluating-skills.mdx` names without pinning down for wgm.

## Adding a case
- Start small (2-3), vary phrasing and formality, include at least one edge case.
- Write assertions that are specific and checkable ("a `Gate check:` block is printed"), not vague
  ("the output is good").
- Run `bash scripts/check-evals.sh` — schema backpressure only; it does not grade the case.

## Placement & backpressure
`evals/evals.json` lives at the repo root (alongside `SKILL.md`), matching the upstream convention
of `evals/` sitting next to the skill it tests. `assets/evals.template.json` is the reusable
skeleton for other skills/projects wgm builds. `scripts/check-evals.sh` validates the fixture's
schema and is part of `make validate` / CI, same as `scripts/check-docs.sh`.

## Cross-links
[`references/trigger-eval.md`](trigger-eval.md) (the companion trigger-classification fixture) ·
[`references/scoring.md`](scoring.md) (the LLM-as-judge pattern grading follows) ·
[`references/self-improvement.md`](self-improvement.md) (where this was assimilated from external
research) · `assets/evals.template.json` · `scripts/check-evals.sh`.
