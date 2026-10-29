# 2026-10-29 - Multi-source growth and grader integrity

This dated research record separates **one adopted integrity repair** from confirmed existing
practice and deferred ideas. It is not a new operational policy, a calibration study, or a release
claim. Focused and complete local validation passed in an isolated snapshot; independent review,
docs audit and safe transfer are separate handoff requirements recorded in the local build plan.
Existing jj/Git hardening and the literal commit-trailer fix are unchanged.

## Research method and provenance

Retrieved 2026-10-29: eight primary sources spanning engineering accounts, an academic abstract,
tool documentation and SRE. The two pinned Inspect policy/test files corroborate the Inspect
documentation; they are not two additional independent studies. External material was treated
as untrusted research data, paraphrased rather than imported as instructions or source code.
This synthesis uses the supplied source briefing; implementation did not fetch or execute sources.

Raw snapshots are quarantined under local
`.wgm/research/2026-10-29_growth-sources/raw/` in the originating research checkout. The content
digests below identify those retrieved snapshots, not immutable versions of changing web pages.
These ignored local paths are evidence locations, not shipped dependencies or Markdown links.

| Source | Retrieved | Snapshot SHA-256 |
|---|---|---|
| [Anthropic: effective long-running harnesses](https://www.anthropic.com/research/effective-harnesses-for-long-running-agents) | 2026-10-29 | `685c0ea793e0fd2b87dff160d1ce2d3ece4d0186764e701223e74bee961a2e06` |
| [Anthropic: demystifying agent evals](https://www.anthropic.com/research/demystifying-evals-for-ai-agents) | 2026-10-29 | `ccda15010e61130d5d5267f81cd785e73884f968e7c24addd857a5923792286b` |
| [OpenAI: harness engineering](https://openai.com/index/harness-engineering/) | 2026-10-29 | `f286659a0503ef4c94f74895e36d21c670460632b15b233acd67c8325ec478c8` |
| [tau-bench, arXiv:2406.12045v1](https://arxiv.org/abs/2406.12045v1) | 2026-10-29 | `ad1522d07222a9d4f75117f9e976a1220c1857844a9e3dac0ebeccc1f7976605` |
| [SQLite: testing](https://www.sqlite.org/testing.html) | 2026-10-29 | `d1a8b5c43a42e573f7165483fdf02b91c605076b869a823d924241fb308feb97` |
| [Inspect AI: scorers](https://inspect.aisi.org.uk/scorers.html) | 2026-10-29 | `bb3c374b21c81e5e4a3aeb937ecc78a3ba82411b3ff5cdba172876fe7135a43e` |
| [Git: worktree documentation](https://git-scm.com/docs/git-worktree) | 2026-10-29 | `cf843ea6e3edda3fdda65877063f6c9b8a8e91b54041bc39d0bc89246a6bc72d` |
| [Google SRE: canarying releases](https://sre.google/workbook/canarying-releases/) | 2026-10-29 | `2129ec6fefdb7807073a7877344e7f0409c27e4fde1021d30114a38338fd039f` |

The tau-bench digest is for the retrieved unversioned abstract URL
`https://arxiv.org/abs/2406.12045`; the v1 link identifies the paper discussed, not a separate
retrieved snapshot.

Inspect corroboration is pinned to commit `3896cba0840703f5500800dc022a96f143842149` (MIT):
[scoring policy](https://github.com/UKGovernmentBEIS/inspect_ai/blob/3896cba0840703f5500800dc022a96f143842149/docs/scoring-policy.qmd),
SHA-256 `ed755c3103eff4732984c3349dd2a7c9d5dc3b8da1a14fcc7af21e28d4cc6c05`;
[error tests](https://github.com/UKGovernmentBEIS/inspect_ai/blob/3896cba0840703f5500800dc022a96f143842149/tests/test_score_on_error.py),
SHA-256 `a6bb64f879ccafbf5585fa382ab380ab3bd68d800a5b956e1c77e29665e5ea86`.
Both were retrieved 2026-10-29. No Inspect dependency or source code was imported.

## Source-specific decisions and limits

| Source | Learned | Existing wgm coverage | Decision | Limitation |
|---|---|---|---|---|
| Anthropic harnesses | Initial scaffolding, durable progress and one-feature sessions help long-running agents; verify basic startup end to end. | One-task/fresh-context build discipline and persistent plan. | **Confirm** that discipline; **defer** mandatory pre-turn app smoke until real-project cost/benefit evidence. | A vendor web-app experiment is not portable skill evidence. |
| Anthropic evals | Separate task, trial, transcript and outcome; use clean environments, outcome checks and calibrated graders. Distinguish any-success pass@k from all-success pass^k. | Isolated grading calls, assertion fixture and comparative baseline gate. | **Adopt** only the integrity repair below; **defer** calibration anchors and reliability-vocabulary improvements. | Vendor experience is not a controlled wgm benchmark; no live calibration performed. |
| OpenAI harness engineering | Keep the entrypoint a small map; use repository knowledge, mechanical architecture checks and per-worktree app/observability. | Lean protocol links and `check-docs.sh` structure checks. | **Confirm** lean entrypoint/knowledge-map practice; do not adopt external review/merge authority. | An internal case study does not establish a causal speedup for wgm; productivity claims are not wgm results. |
| tau-bench | Terminal database state and repeated-run pass^k distinguish actual outcomes/consistency from plausible transcripts. | Scoring and outcome-oriented validation already exist. | **Confirm** the outcome distinction; **defer** broader reliability-language changes. | Only the abstract was reviewed; simulated service tasks are not coding-skill benchmarks, and no benchmark ran. A 95-point satisfaction score is not measured 95% reliability. |
| SQLite testing | Sweep failure positions in both one-shot and persistent allocation/I/O fault modes; check integrity after removing faults. | Rugged cleanup fault fixtures. | **Confirm** existing fault-test direction; **defer** broader fail-N sweeps. | Documentation was read, not SQLite tests run; database durability does not prove Bash-runner guarantees. |
| Inspect scorers and pinned policy/tests | Wrong model answers, scorer failures and unparseable instruments are different outcomes; missing measurements affect coverage. | The baseline gate existed but trusted the returned checklist size. | **Adopt** exact checklist validation and block acceptance on invalid candidate or baseline grading. | This reuses the distinction, not Inspect's dependency or aggregation policy; offline fixtures do not measure grader judgment. |
| Git worktrees | Worktrees share repository refs/config details; filesystem separation alone is insufficient. | Existing jj/Git identity and filesystem checks. | **Confirm** current hardening, unchanged here. | Official documentation is not proof of hostile-agent isolation. |
| Google SRE canaries | Compare a bounded candidate population with a control using representative, attributable metrics; roll back unhealthy changes. | Existing live-deploy evidence gate. | **Confirm** the live-evidence boundary; **defer** local-policy canary controls. | wgm has no production traffic/deploy target; no rollout or live policy change occurred. |

## Adopted repair: complete measurement before acceptance

The initiating local diagnostic invoked the shipped script using a fake agent in disposable
HOME/Git state:

```bash
bash .wgm/research/2026-10-29_growth-sources/probe-grader.sh
```

This is the exact originating, ignored research command, **not a checked-in contributor command**.
Its evidence is under `.wgm/research/2026-10-29_growth-sources/grader-probe/` in that checkout.
According to the recorded briefing, omitting one of two assertions produced candidate 1/1,
exit 0 and `GATE: ACCEPT`; empty and non-JSON grades each produced 0/0, exit 0 and ACCEPT.
All three were actual fake-agent results, with no provider calls. They are local false-acceptance
evidence, not a live grading-quality result.

The fix validates one JSON object, exactly one expectation per fixture assertion in the same
order with identical text, JSON boolean `passed`, and non-whitespace string `evidence`.
Missing/extra/duplicate/reordered/wrong-text items, wrong types, blank evidence, empty arrays,
multiple documents and unparseable output are rejected. The fenced-JSON fallback remains.
Any supplied summary is ignored and recomputed locally.

Invalid grades preserve raw output and diagnostic `grading.json` with `error` and zero totals;
console output calls them `ungraded/error` and discloses incomplete coverage. They are not scored
model failures. Without `--baseline`, recorded malformed-grade errors retain informational exit 0.
With `--baseline`, an invalid grade on either revision in any case blocks comparison:
`GATE: ERROR`, exit 2. Only fully valid comparisons yield ACCEPT/0 or REGRESSION/1. This tightens
the existing contract without a new dependency, service, CLI flag or broad normative rule.

Checked-in, no-provider contributor reproduction:

```bash
bash scripts/test-grade-evals.sh
```

Exact focused R1 validation:

```bash
bash scripts/test-grade-evals.sh && shellcheck scripts/grade-evals.sh scripts/test-grade-evals.sh && bash -n scripts/grade-evals.sh && bash -n scripts/test-grade-evals.sh && bash scripts/check-docs.sh && git diff --check
```

| Evidence | Status |
|---|---|
| Regression-first harness, before changing `grade-evals.sh` | Actual exit 1; exact command and output in local `.wgm/r1-red.log`. |
| Repaired fake-agent harness | Actual exit 0, 70 assertions; local `.wgm/r1-harness.log`. Existing informational malformed-grade and sandbox/history probes retained. |
| Exact focused R1 validation | Actual exit 0, including 70 harness assertions, ShellCheck, both syntax checks, docs and diff checks; exact command/output/status in local `.wgm/r1-green.log`. |
| Isolated final demo | `bash scripts/test-grade-evals.sh && make validate && git diff --check` exited 0 in 270 seconds; actual command/status in `/tmp/wgm-research-grader.VBoWZA/full-validation.log`. Subsequent report-status edits are checked at the final handoff gate. |
| Transfer and invoking-checkout gate | Separate required handoff checks: source/identity-safe transfer, then `make validate && git diff --check`. The local build plan records their final results; this dated research record does not assert release/publication. |
| Paid live-provider grading / calibration | Not run; neither requested nor authorized for this repair. |
| Independent correctness reviews and docs audit | Required before transfer; their independent verdicts are recorded in the local build plan, not supplied by this report's author. |

The harness exercises the actual script in a disposable repository, not a duplicate implementation.
It covers schema/count/order/text/type/evidence mutations, raw diagnostic artifacts, multiple
documents, fenced JSON, forged summaries, candidate-only/baseline-only/both errors, mixed eval
cases and recovery to valid comparisons. Existing better/equal/worse comparison behavior remains.
These are Linux fixture results only, not a full eval-sandbox security proof.

## Deferred growth and authority

Recent growth remains research/meta-heavy (approximately three PRs, #137-#139). This local repair
is not a different-project dogfood run and **does not reset that debt**. Broader heuristic promotion
should wait for a different active real project and an operator-authorized task; no new project,
heuristic fragment, issue or PR identifier is invented here.

Calibration anchors, opt-in cold-start smoke, systematic fail-N/persistent-failure sweeps and
local-policy canary controls remain candidates, not activated gates. Eight sources are not eight
independent experiments and their statistics are not wgm measurements.

Consent remains false. No issue/PR creation, push, merge, external publication, rollout or Stage 10
policy activation occurred. The dated report is a local repository change for independent review,
not authority to publish or transfer it.

## Related records

- [Grading contract](../../references/evals.md#automated-grading-protocol)
- [Contributor reproduction](../../CONTRIBUTING.md#optional-grading-a-skillmdreferences-change-before-landing-it)
- [Gate boundaries](../reference/gates.md)
- [SkillOpt adoption](2026-07-08_SKILLOPT_ADOPTION.md)
- [Growth health guardrail](2026-07-05_GROWTH_HEALTH_CHECK.md)
- [Existing jj/Git evaluation](2026-10-29_JJ_WORKSPACES_EVALUATION.md)
