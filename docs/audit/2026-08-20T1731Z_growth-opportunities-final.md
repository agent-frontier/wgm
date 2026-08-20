# Docs Audit Report — 2026-08-20T1731Z — growth-opportunities-final

> Final focused Full-track audit after the remaining growth-opportunity implementation. The report
> distinguishes runner-owned behavior from host-owned integration and does not certify full Stage 9.

- **Scope:** T1-T4 of `.wgm/IMPLEMENTATION_PLAN.md`, public docs, gate/container selection, harvest
  ownership, plugin boundary, watchdog, swarm propagation, and the Stage 8.5/Stage 9 record.
- **Track:** Full
- **Trigger:** Ship/Handoff
- **Overall verdict:** AMBER — deterministic runner contracts are green; host-level docs-audit
  dispatch and full town-level autonomy remain operator-owned.

## Persona findings

### Junior developer

| Surface | Finding | Severity | Disposition |
|---|---|---|---|
| Public lifecycle and first-build docs | Mode semantics, project substitutions, installed skill paths, `.wgm` placement, Copilot permissions, bounded first-run command, and auth mounts are now explicit. | GREEN | No growth-slice action. |
| Docs-audit dispatch | The portable runner cannot launch host subagents; public docs now say the dispatcher is host-owned and a missing report is not green. | AMBER | Operator action: provide a compatible host dispatcher when automatic persona review is required. |

### Senior developer

| Surface | Finding | Severity | Disposition |
|---|---|---|---|
| `scripts/loop.sh` | Host project gates execute after the agent, auto container selection is explicit, hard timeout is bounded on GNU `timeout`/`gtimeout`, plan paths are selectable, and harvest is handoff-scoped/idempotent. | GREEN | Covered by `make validate`. |
| `scripts/swarm.sh` | Gate configuration propagates to lanes, lane harvest is deferred to parent consolidation, partial setup fails, and lane numbering is preserved. | GREEN | Covered by `bash scripts/test-swarm.sh`. |
| Plugin protocol | Registry and template are consistently marked proposed/unwired host integration. | GREEN | No portable runner claim remains. |

### Principal developer

| Surface | Finding | Severity | Disposition |
|---|---|---|---|
| Stage maturity record | The record separates runner-owned, host-mediated, and operator-controlled capability and rates WGM Stage 8.5 operational / Stage 9 candidate. | GREEN | Constructively critical; Full Stage 9 remains not met. |
| Host boundary | Docs-audit dispatch, full application container lifecycle, and town-level supervision remain outside the portable runner. | AMBER | Explicit Operator actions, not hidden implementation claims. |

### Project manager

| Surface | Finding | Severity | Disposition |
|---|---|---|---|
| Growth plan | T1-T5 have named scope, acceptance, validation, and status; the final report is indexed. | GREEN | Update merge SHA after delivery. |
| Delivery state | T1-T4 are deterministic-green; T5 is ready for reviewed remote delivery. | GREEN | Preserve the report and plan as the handoff record. |

## Consolidated report

### Agent actions

| # | Growth change | Evidence |
|---|---|---|
| 1 | Public semantics, first-build, plan placement, indexes, and contributor/installer guidance aligned. | `bash scripts/check-docs.sh && bash scripts/test-check-docs.sh` |
| 2 | Project gates execute in the host runner, with malformed/empty/inline/quoted syntax covered. | `bash scripts/test-loop.sh` |
| 3 | Container selection reports `auto -> podman -> docker -> unavailable`; explicit unavailable engines fail. | `bash scripts/test-loop.sh` |
| 4 | Normal-loop harvest is handoff-scoped, consent-state-aware, idempotent, timed, and suppressed in swarm lanes. | `bash scripts/test-loop.sh && bash scripts/test-swarm.sh` |
| 5 | Plugin lifecycle claims are marked proposed/unwired and host-adapter-owned. | `bash scripts/check-docs.sh` |
| 6 | Active-agent watchdogs terminate a forked child process group and record failure metrics on supported hosts. | `bash scripts/test-loop.sh` |
| 7 | Swarm gate propagation, partial setup failure, cleanup status, lane numbering, and ignored plan/spec copying are covered. | `bash scripts/test-swarm.sh` |

### Operator actions

| # | Remaining boundary | Why it remains outside the runner |
|---|---|---|
| 1 | Host-level docs-audit dispatcher and report gate | The portable runner cannot launch or authenticate arbitrary host subagents. |
| 2 | Full application container lifecycle/readiness | WGM selects the engine; a host adapter or agent owns build, run, readiness, and cleanup. |
| 3 | Full Stage 9 town-level autonomy | Persistent cross-repository supervision, autonomous experiment selection, promotion, and rollback remain future architecture. |

### Rejected findings

| Candidate finding | Verification |
|---|---|
| Project gates remain prompt-only. | Passing/failing/malformed/inline/quoted gate cases pass in `scripts/test-loop.sh`. |
| Harvest duplicates or suppresses consent transitions. | Handoff-only, lane-suppression, unchanged-memory, and consent-transition cases pass. |
| Explicit auto/container or custom plan paths fail. | Explicit-auto and custom-plan fixtures pass. |
| Swarm can report partial setup success or lose gate configuration. | Mixed-setup, gate-propagation, and lane-numbering cases pass. |
| Stage record claims Full Stage 9. | The record explicitly marks Full Stage 9 “Not met” and names the human/host gates. |

## Validation

- `make validate` — GREEN
- `bash scripts/test-loop.sh` — GREEN
- `bash scripts/test-swarm.sh` — GREEN
- `bash scripts/check-docs.sh` — GREEN
- Shell syntax and ShellCheck — GREEN

## Verdict history

- `2026-08-20T0718Z` — RED capability-hardening baseline.
- `2026-08-20T0744Z` — AMBER capability-hardening focused final.
- `2026-08-20T1729Z` — AMBER growth-opportunity pass before final boundary fixes.
- This report — AMBER for host-owned integration and future Stage 9 autonomy; the implemented
  growth runner contracts are deterministic-green.
