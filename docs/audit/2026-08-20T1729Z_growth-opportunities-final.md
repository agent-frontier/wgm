# Docs Audit Report — 2026-08-20T1729Z — growth-opportunities-final

> Focused Full-track Ship/Handoff review of the remaining growth-opportunity slice. The earlier
> capability-hardening baseline and final reports remain historical evidence; this report covers the
> current growth branch before its remote merge.

- **Scope:** T1-T4 of `.wgm/IMPLEMENTATION_PLAN.md`, public runner/docs/plugin/Hive boundaries,
  watchdog and container selection, swarm propagation, and the Stage 8.5 / Stage 9 record.
- **Track:** Full
- **Trigger:** Ship/Handoff
- **Overall verdict:** AMBER — deterministic growth contracts are green; host-owned docs-audit
  dispatch and full town-level autonomy remain explicitly outside the portable runner.

## Persona findings

### Junior developer — clarity & onboarding

| Surface | Observation | Severity | Action |
|---|---|---|---|
| Public mode and first-build docs | Mode semantics now match `SKILL.md`; the first-build page labels project-specific commands as substitutions instead of inventing `mycli` or `src/`. | GREEN | None for this slice. |
| Loop/devcontainer examples | Copilot permission flags, installed-skill paths, `.wgm` creation, and scoped auth mounts are now shown in the primary examples. | GREEN | None for this slice. |
| Docs-audit dispatch | The public protocol now states that persona dispatch is host-owned and that a missing host dispatcher is not a green audit. | AMBER | Operator action: provide the host dispatcher or retain the recorded limitation. |

### Senior developer — correctness

| Surface | Observation | Severity | Action |
|---|---|---|---|
| `scripts/loop.sh` | Project gates execute after successful agent work; malformed, empty, inline, and quoted gate forms are covered; failure cannot finish a bounded run green. | GREEN | None for this slice. |
| `scripts/loop.sh`, `scripts/test-loop.sh` | `auto -> podman -> docker -> unavailable`, explicit plan paths, GNU timeout/gtimeout watchdogs, process-group checks, consent-aware harvest dedupe, and gate/manifest recovery are covered. | GREEN | None for this slice. |
| `scripts/swarm.sh`, `scripts/test-swarm.sh` | Parent gate configuration propagates to lanes, lane harvest is suppressed until parent consolidation, partial setup fails, and lane numbering remains aligned. | GREEN | None for this slice. |
| Plugin materials | Plugin hooks and timeout/enablement behavior are consistently marked proposed/unwired host integration. | GREEN | None for this slice. |

### Principal developer — architecture

| Surface | Observation | Severity | Action |
|---|---|---|---|
| Stage record | The record separates runner-owned, host-mediated, and operator-controlled behavior and calls WGM Stage 8.5 operational / Stage 9 candidate rather than Full Stage 9. | GREEN | Keep this rubric current after each growth pass. |
| Self-improvement | Normal-loop harvest is consent-gated, handoff-scoped, idempotency-keyed by memories plus consent state, and suppressed inside swarm lanes until parent consolidation. | GREEN | None for this slice. |
| Docs-audit swarm | The portable runner still cannot launch host subagents or enforce report presence; the public contract now says so explicitly. | AMBER | Operator action: integrate a host dispatcher if automatic persona execution is required. |

### Project manager — status and traceability

| Surface | Observation | Severity | Action |
|---|---|---|---|
| `.wgm/IMPLEMENTATION_PLAN.md` | T1-T4 have named files, acceptance, validation, and recorded results; T5 records this final audit and merged-delivery gate. | GREEN | Update the merge SHA after remote delivery. |
| Public growth record | The operator hypothesis, independent rating, shipped evidence, current status matrix, and future Stage 9 work are distinguishable. | GREEN | Keep the current release line synchronized after merge. |
| Remaining scope | Host docs-audit dispatch, true container readiness probes, and town-level autonomy remain future/operator-owned work rather than silently shipped features. | AMBER | Preserve as explicit follow-up, not as an implementation claim. |

## Consolidated report

### Agent actions

| # | Finding | Evidence | Disposition |
|---|---|---|---|
| 1 | Public mode/first-build/install/index contracts were contradictory. | `bash scripts/check-docs.sh`; updated README, first-build, requirements, plans index, and operator docs | Implemented. |
| 2 | Project gates were prompt-only and gate syntax was under-specified. | `bash scripts/test-loop.sh`; host `run_project_gates` and parser regressions | Implemented. |
| 3 | Container selection claimed fallback without runner ownership. | `bash scripts/test-loop.sh`; explicit `auto` and unavailable-state behavior | Implemented for selection/reporting; app execution remains host/agent-owned. |
| 4 | Harvest could duplicate, suppress consent transitions, or run in swarm lanes. | `bash scripts/test-loop.sh`, `bash scripts/test-swarm.sh`; handoff flag, consent-aware hash, lane suppression | Implemented. |
| 5 | Plugin lifecycle claims exceeded portable runner ownership. | Protocol banners, artifact reference, plugin template, and registry wording | Relabeled proposed/unwired host integration. |
| 6 | Active-agent hard timeout and process-group cleanup were absent. | `bash scripts/test-loop.sh`; forked child timeout fixture and metrics assertion | Implemented on GNU `timeout`/`gtimeout` hosts with cooperative fallback. |
| 7 | Swarm setup, gate propagation, and plan/artifact state could drift. | `bash scripts/test-swarm.sh`; parent config propagation, lane numbering, setup failure cases | Implemented for tested lane state. |

### Operator actions

| # | Finding | Why it remains operator-owned |
|---|---|---|
| 1 | Host-level four-persona docs-audit dispatch and report gating | `loop.sh` cannot grant or assume host subagent orchestration authority. |
| 2 | Full container readiness and app lifecycle execution | Engine selection is now truthful, but the host/agent owns building, starting, probing, and cleaning the application under test. |
| 3 | Full Stage 9 town-level autonomy | Persistent cross-repository supervisor, autonomous experiment selection, promotion policy, and rollback remain future architecture. |

### Rejected findings

| Candidate finding | Verification | Disposition |
|---|---|---|
| Project gates are still prompt-only. | Failing and passing gate fixtures in `scripts/test-loop.sh`. | Rejected for the normal loop path. |
| Explicit `--container auto` fails. | Explicit-auto dry-run fixture and current resolver. | Rejected. |
| Consent-disabled harvest permanently suppresses later consent. | Consent-state transition fixture in `scripts/test-loop.sh`. | Rejected. |
| Swarm lanes duplicate harvest side effects. | Parent-only hook fixture in `scripts/test-swarm.sh`. | Rejected. |
| Stage record claims Full Stage 9. | Growth record rubric and self-critique section. | Rejected; Full Stage 9 is explicitly marked not met. |

## Validation

- `make validate` — GREEN
- `bash scripts/test-loop.sh` — GREEN
- `bash scripts/test-swarm.sh` — GREEN
- `bash scripts/check-docs.sh` — GREEN
- Shell syntax and ShellCheck — GREEN

## Verdict history

- `2026-08-20T0718Z` capability-hardening baseline — RED, pre-existing growth contracts.
- `2026-08-20T0744Z` capability-hardening focused final — AMBER.
- This report — AMBER for host-owned docs-audit dispatch and future Stage 9 autonomy; the T1-T4
  growth implementation is deterministic-green and ready for reviewed delivery.
