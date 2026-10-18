# Contributing to wgm

Thanks for your interest in improving **wgm**. It's a portable [Agent Skill](https://agentskills.io):
a single `SKILL.md` protocol at the repo root, supported by `references/`, `assets/`, `scripts/`, and
`docs/`. Contributions that sharpen the lifecycle, the backpressure discipline, or the docs are very
welcome.

## Ground rules

- **`SKILL.md` is the protocol.** Keep it operational and lean (target ≤ ~500 lines). Push theory,
  rationale, and long-form detail into `references/`.
- **Docs are split by audience.** `docs/operator/` is for people running wgm; `docs/agent/` is for
  the agent's own behavior. Prefer **Mermaid** diagrams for flows.
- **Never let the doc/install checks go red.** They are the project's deterministic backpressure —
  the same idea wgm preaches.
- **Don't clobber `AGENTS.md`.** wgm's own artifact-safety rules apply to this repo too.

## Dev prerequisites

| Tool | Used for |
|---|---|
| `bash`, [`shellcheck`](https://www.shellcheck.net/) | shell scripts + lint |
| `jq` | `scripts/check-evals.sh` (evals fixture schema check) |
| `pwsh` (PowerShell 7+) | the Windows installer + its test harness |
| `python3` + `pip` | `skills-ref` (skill validator) |

Install the validator once:

```bash
pip install "git+https://github.com/agentskills/agentskills.git#subdirectory=skills-ref"
```

## The backpressure suite (run before every PR)

`make validate` is the complete portable local suite. The canonical bash harness inventory is
`Makefile`'s `test` recipe; CI includes those harnesses, including audit and devcontainer checks,
and adds `skills-ref` and PowerShell checks in `ci.yml`, plus `actionlint` in `lint.yml`.
The docs gate rejects a local harness missing from CI's literal run-command inventory; it does
not evaluate workflow conditions or arbitrary shell/Make logic. See the precise
[gate contract](docs/reference/gates.md#the-one-command).

These are selected commands for focused runs, not a second authoritative harness inventory:

```bash
shellcheck scripts/*.sh                      # lint
for s in scripts/*.sh; do bash -n "$s"; done  # shell syntax
( cd .. && skills-ref validate wgm )          # skill is valid (run from the parent dir)
bash scripts/check-docs.sh                    # docs structure, links, mermaid, placeholders
bash scripts/test-check-docs.sh               # docs regressions, including local/CI harness inventory
bash scripts/test-check-doc-sync.sh           # doc-sync findings and fail-closed Git inspection
bash scripts/check-evals.sh                   # evals/evals.json schema (agentskills.io convention)
bash scripts/test-install.sh                  # bash installer harness
bash scripts/test-plugin-registry.sh          # real plugin discovery + callable-handler parity
bash scripts/test-stage10-memory.sh           # Stage 10 evidence/memory boundary harness
bash scripts/test-stage10-runner.sh           # bounded direct-process contract and authority boundary
bash scripts/test-stage10-qualification.sh    # qualification ladder and live-evidence boundary
bash scripts/test-stage10-live-qualification.sh # offline scope/hash/expiry/budget authority contract
bash scripts/test-stage10-router.sh           # transparent route policy
bash scripts/test-stage10-experiments.sh      # baseline comparison and feature economy
bash scripts/test-stage10-execution.sh        # isolated local branch/worktree experiment execution
bash scripts/test-stage10-pr.sh               # report-derived, human-gated local PR bundle
bash scripts/test-stage10-policy.sh           # offline learned-policy comparison
bash scripts/test-stage10-deferred-e2e.sh     # final disposable deferred-boundary integration
bash scripts/test-loop.sh                     # loop.sh limits + resilience + metrics harness
bash scripts/test-swarm.sh                    # swarm.sh parallel-worktree harness
bash scripts/test-audit.sh                    # audit.sh dispatch harness, fixture agents only
bash scripts/test-harvest-hive.sh             # harvest-hive.sh anonymize + consent harness
bash scripts/test-devcontainer.sh             # devcontainer.sh sandbox harness (real podman/docker cases)
bash scripts/test-grade-evals.sh              # grade-evals.sh plumbing harness, fake agent (7 cases)
pwsh -File scripts/test-install.ps1           # PowerShell installer harness
actionlint                                    # lint .github/workflows/*.yml (CI: lint.yml)
```

> `skills-ref validate wgm` must be run from the **parent** directory, because the validator requires
> the skill folder's basename to equal the skill name (`wgm`).

Run the complete local suite with **`make validate`** (lint + docs + `Makefile`'s bash harnesses); `make help`
lists every target (`make update` refreshes your installed copy, `make test`, `make lint`, …).

The devcontainer harness prefers Podman, falls back to Docker, and visibly skips real-engine cases
only when neither is installed; its disposable test image is separate from the operator's base image.
Fixture agents do not provide live-provider evidence. For per-iteration doc-sync, `--warn` downgrades
undocumented-surface findings only: invalid/non-commit bases or failed Git inspection still report
`ERROR`, exit `2`, and never print `doc-sync: GREEN`. Correct the input or inspection failure and retry.

## Optional: grading a `SKILL.md`/`references/*` change before landing it

`scripts/grade-evals.sh` mechanizes `references/evals.md`'s automated grading protocol — it runs
each `evals/evals.json` case through your configured agent (same `$WGM_AGENT`/`--agent`/`--`
convention as `scripts/loop.sh`), grades the transcript, and (with `--baseline <git-ref>`) gates on
non-regression against a prior revision. It is **not** part of the backpressure suite above and
never runs in CI — it costs real agent/API calls — so run it by hand when a change might affect
behavior quality:

```bash
./scripts/grade-evals.sh                        # grade every case against the current SKILL.md
./scripts/grade-evals.sh --baseline main         # ...and gate on non-regression vs. main
bash scripts/test-grade-evals.sh                 # its own fake-agent smoke test (CI-safe, free)
```

## Making a change

1. Fork and branch from `main`.
2. Make the change; keep edits surgical and scoped.
3. Run `make validate` and the applicable CI-only checks above — get them green.
4. Open a PR using the template. Describe the change and note which checks you ran.
5. CI must pass before merge — both `.github/workflows/ci.yml` (validation) and
   `.github/workflows/lint.yml` (actionlint).

## Reporting bugs & ideas

Use the issue templates (bug report / feature request). For anything security-sensitive, follow
[`SECURITY.md`](SECURITY.md) instead of opening a public issue.

## Learning from users

If you want wgm to learn from a failure pattern or a surprising outcome, please use the
`Heuristic / learning report` issue template. Share only sanitized traces, and include enough
context that maintainers can turn the report into a better heuristic, doc note, or holdout scenario.
This is the path we should use for our own dogfood runs too.

Durable, cross-project lessons graduate into [`references/heuristics.md`](references/heuristics.md) —
wgm's curated juice ledger — and from there into the protocol. See the
[growth flywheel](docs/plans/2026-06-16_GROWTH_LOOP.md) and
[`references/self-improvement.md`](references/self-improvement.md) for how a report becomes a durable
upgrade.

By contributing, you agree your contributions are licensed under the project's [MIT License](LICENSE).
