# Docs Audit Report — 2026-08-20T0744Z — capability-hardening-final

> Focused Ship/Handoff review of the current capability-hardening diff. The clean pre-code
> `origin/main` baseline is preserved in
> [the baseline report](2026-08-20T0718Z_capability-hardening-baseline.md); this report does not
> retroactively change that RED verdict.

- **Scope:** current `chore/harden-learn-issues` worktree; all files changed for issues #87–#96,
  the baseline audit artifact, and their deterministic harnesses.
- **Track:** Full
- **Trigger:** Ship/Handoff
- **Overall verdict:** AMBER — the ten-issue hardening slice is verified; pre-existing documentation
  and host-integration findings remain outside this slice.

## Persona findings

### Junior developer — clarity & onboarding

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `docs/reference/cli-loop.md`, `docs/operator/troubleshooting.md` | Capability probes, no-progress stalls, phase artifacts, and commit ownership now have copy-pasteable recovery guidance. | GREEN | None for this slice. |
| `docs/get-started/README.md`, `docs/get-started/first-build.md` | The hardening adds executable-prerequisite guidance, but the older generic `mycli` worked example remains a separate follow-up. | AMBER | Operator action: choose and publish a real fixture or explicitly label the example illustrative. |

### Senior developer — correctness, completeness, maintainability

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `scripts/loop.sh`, `scripts/test-loop.sh` | Source-first checks confirm capability probing, bounded no-progress behavior, phase-artifact freshness/content, `.wgm/AGENTS.md` placement, STOP handling, renames, and frugal/main escalation. | GREEN | None for this slice. |
| `scripts/swarm.sh`, `scripts/test-swarm.sh` | Zero-commit lanes fail, lane logs survive cleanup, and the harness verifies the artifact rather than only exit status. | GREEN | None for this slice. |
| `scripts/check-docs.sh`, `scripts/test-check-docs.sh` | Complete-table parsing supports outer-pipe and standard Markdown rows; protocol contracts fail closed in an isolated copy without mutating the source tree. | GREEN | None for this slice. |

### Principal developer — architecture, strategic fit, consistency

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `SKILL.md`, `references/subagents.md`, reviewer briefs | Author-independent adversarial review is distinct from process-only self-review, and docs-audit findings require source verification with rejected-finding evidence. | GREEN | None for this slice. |
| `references/ralph-loop.md`, `references/docs-audit.md`, `docs/style-guide.md` | Intermediary rules, corpus fact sweeps, rewrite size bands, executable journeys, and complete-table contracts are aligned across protocol and docs. | GREEN | None for this slice. |
| `docs/audit/2026-08-20T0718Z_capability-hardening-baseline.md` | The baseline report intentionally records RED pre-existing findings; it is not evidence that the current slice is fully green across the whole repository. | AMBER | Preserve the baseline report and track unrelated findings separately. |

### Project manager — status, risk, traceability

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `IMPLEMENTATION_PLAN.md`, baseline and final audit reports | All ten issue references map to changed source, tests, and protocol evidence; remote issue closure remains dependent on the reviewed PR merge. | GREEN | Merge the reviewed PR, then verify issue state and report the merge SHA. |
| `docs/audit/README.md` | Baseline and final focused reports are indexed newest-first. | GREEN | Keep both reports as the baseline-to-final paper trail. |

## Consolidated report (wgm-docs-writer)

### Agent actions

| # | Finding | Verification | Disposition |
|---|---|---|---|
| 1 | #87 intermediary rules | `bash scripts/check-docs.sh`; source inspection of Analyze/audit guidance | Landed in the hardening slice. |
| 2 | #88 corpus fact sweeps | Source inspection of old/new-value and regeneration guidance | Landed in the hardening slice. |
| 3 | #89 rewrite budgets | `references/docs-audit.md` and `docs/style-guide.md` require measured floor/ceiling bands | Landed in the hardening slice. |
| 4 | #90 complete tables | `bash scripts/test-check-docs.sh` and `bash scripts/check-docs.sh` | Landed and verified red/green. |
| 5 | #91 executable journeys | `references/docs-audit.md` and `docs/get-started/README.md` | Landed as an audit contract; real downstream project execution remains operator-dependent. |
| 6 | #92 zero-commit lanes | `bash scripts/test-swarm.sh` | Landed and verified. |
| 7 | #93 finding adjudication | protocol contract gate plus report template | Landed and verified. |
| 8 | #94 capability/no-progress guards | `bash scripts/test-loop.sh` | Landed and verified, including escalation and phase artifacts. |
| 9 | #95 commit ownership | `bash scripts/test-loop.sh` | Landed and verified for dirty, undeclared, manifest, and rename cases. |
| 10 | #96 independent review | independent spec/quality review PASS plus protocol source checks | Landed and independently reviewed. |

### Operator actions

| # | Finding | Why it remains operator work |
|---|---|---|
| 1 | Publish a real first-build fixture and exact external Copilot permission contract. | This depends on the target CLI version, credential policy, and canonical demo project. |
| 2 | Decide whether `loop.sh --container` should own engine detection or remain a prompt preference. | This changes runtime behavior and deployment expectations. |
| 3 | Wire host-level automatic docs-audit/Hive dispatch and define empty-memory behavior. | The repository cannot grant host dispatcher or external-reporting authority to itself. |
| 4 | Resolve historical plan/index freshness and the pre-existing audit RED findings. | They predate this slice and require maintainer policy, not a silent scope expansion. |

### Rejected findings (verified false or already mitigated)

| Finding | Verification performed | Evidence / disposition |
|---|---|---|
| Exit-zero swarm lanes are still accepted with zero commits. | `bash scripts/test-swarm.sh`; `scripts/swarm.sh` status conversion | Rejected for the current slice; the zero-commit case fails. |
| The docs protocol can be weakened without a deterministic signal. | Isolated temp-copy deletion of a required phrase in `scripts/test-check-docs.sh` | Rejected for the current slice; the copy turns red and the real source remains unchanged. |
| Extract cannot use `.wgm/AGENTS.md`. | Positive `.wgm/AGENTS.md` harness case in `scripts/test-loop.sh` | Rejected; both root and `.wgm/AGENTS.md` section changes are supported. |

### Dissent

| Finding | Persona views | Preserved as |
|---|---|---|
| Overall docs readiness | The hardening files and gates are GREEN; the baseline personas still identify unrelated RED host/documentation gaps. | AMBER focused verdict, with unrelated work retained as Operator actions rather than hidden. |

## Validation

- `make validate` — GREEN
- Independent spec review — PASS
- Independent quality review — PASS
- `bash scripts/check-docs.sh` after the docs harness exits — GREEN

## Verdict history

- [2026-08-20T0718Z baseline](2026-08-20T0718Z_capability-hardening-baseline.md) — RED
  pre-code snapshot.
- This focused final pass — AMBER for the requested slice; unrelated baseline findings remain
  explicitly recorded.
