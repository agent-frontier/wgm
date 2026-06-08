# Scenarios — the holdout acceptance set

A **scenario** is a user-journey acceptance spec: how to verify the software works from the user's
seat. wgm treats scenarios as a **holdout set** — the Implement step never reads them; only
Validate/Review (the judge) does. This is the anti-reward-hacking core borrowed from octopusgarden:
if code is generated against the same checks that grade it, the agent learns to game the checks.
Hold the scenarios out and the score means something.

## Scenarios vs specs vs backpressure
- **Specs** (`assets/spec.template.md`) say *what* to build and why — the agent reads these.
- **Scenarios** say *how to verify* from the outside — the agent must NOT read these while
  implementing; they are graded blind in Validate/Review.
- **Backpressure** (tests/types/build/lint/probes) is the deterministic pass/fail signal that gates
  "done." Scenarios **complement** backpressure with holistic, end-to-end, holdout judgment; they do
  not replace it. Deterministic checks still gate; scenarios add confidence the user flow truly works.

## Authoring (when & who)
- Write scenarios during **Grill/Plan**, from the spec's success criteria and demo path — before or
  independent of implementation.
- One coherent journey per file. Favor the **smallest end-to-end slice** that proves value first.
- Keep them black-box: phrase steps as user actions and observable expectations, not internal calls.

## YAML schema
Each scenario file (`scenarios/<name>.yaml`):

```yaml
name: <short-id>
description: <one line: the journey and why it matters>
tier: 1                     # 1 = smoke/happy-path, 2 = normal, 3 = hard/edge
target:                     # how to reach the running software (optional)
  kind: http               # http | cli | tui
  start: <command/url>     # how to start it, or where it listens
setup:                      # optional preconditions (seed data, env)
  - <precondition>
steps:
  - action: <what the user does>
    expect: <the observable outcome the judge scores>
  - action: <next user action>
    expect: <observable outcome>
```

Keep it minimal; add fields only when a scenario needs them. The judge scores each `expect` against
observed behavior (see `references/scoring.md`).

## Difficulty tiers (for stratified validation)
- **Tier 1** — smoke / happy path: the core magic moment works at all.
- **Tier 2** — normal usage: common variations and obvious error handling.
- **Tier 3** — hard / edge: boundaries, concurrency, nasty inputs, recovery.

**Stratified validation** converges one tier to threshold before advancing to the next, so a pile of
easy tier-1 passes can't mask a broken tier-3. Mechanics live in `references/scoring.md`.

## Placement (artifact-safety)
- **Greenfield/empty repo:** `scenarios/` at the project root.
- **Existing project** (already has specs/plan/AGENTS): `.wgm/scenarios/` to avoid clobbering.
- Decide root vs `.wgm/` **once, in Triage**, consistent with the other artifacts
  (`references/artifacts.md`).

## Holdout discipline (do / don't)
- **Do** author scenarios from the spec, store them, and judge against them in Validate/Review.
- **Do** run the software (a real process or a container — `references/validation-env.md`) and grade
  observed behavior.
- **Don't** open scenario files during Analyze/Implement, or copy their assertions into code or
  tests. If you need a check while implementing, write a separate deterministic backpressure test.
- **Don't** tailor code to a scenario's literal strings; build the capability, not the answer.

## Cross-links
- Grading & thresholds → `references/scoring.md`
- Running the app to validate → `references/validation-env.md`
- Loop integration → `references/ralph-loop.md`
