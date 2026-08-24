# Constitution: <project name>

> Project-wide principles every spec, plan, and task must honor. Written once (Triage/Plan), revised
> rarely and deliberately. wgm loads this first and checks every artifact against it at the
> Plan-exit gate. A slice may deviate only by recording the reason in the table below.

## Principles
1. **Code quality** — <the bar: readability, module boundaries, naming, error handling>.
2. **Testing** — <what must be tested and how: unit/integration, coverage floor, no untested merges>.
3. **Security & privacy** — <secrets handling, authz model, input validation, data we never log>.
4. **UX & consistency** — <house style, accessibility, copy tone, design system to follow>.
5. **Performance** — <budgets that matter, e.g. p95 latency, bundle size, memory ceiling>.
6. **Ruggedness** — <the bar for holding up in the field: named actual operators and environment,
   few moving parts, visible rather than silent degradation, atomic and recoverable changes>.

## Ruggedness gate (non-negotiable)
Every plan and every reviewed diff carries **exactly one** ruggedness verdict — produced by
`/rugged plan` / `/rugged review` when the companion is discoverable, or by wgm's embedded five-step
rubric run inline (recording the missing capability) when it is not. An absent verdict is a gate
FAIL, never a pass, on every track including Quick.

| Verdict | Effect | Required recovery |
|---|---|---|
| **RUGGED** | passes the gate | none — record the verdict and continue |
| **FRAGILE** | blocks | a remediation task in `IMPLEMENTATION_PLAN.md`, fixed before the gate re-runs |
| **UNKNOWN** | blocks | a validation-signal task that creates the missing deterministic field/stress evidence |

Plan-exit judges plan readiness (an exact runnable field/stress/recovery check *design*); Review
judges real implementation evidence. See `SKILL.md`, "The ruggedness gate".

## Non-negotiables
- <A hard constraint that must never be violated, e.g. "no PII in logs", "never break the public API">.

## Tech constraints
- **Must use:** <languages, frameworks, services that are fixed>.
- **Must avoid:** <tech that is off-limits, and why>.
- **Deployment target:** <where this runs>.

## Recording deviations
When a slice must break a principle, log it here so the next agent sees the trade-off instead of
"fixing" it back.

| Date | Principle | Why we deviated | Scope |
|---|---|---|---|
| <yyyy-mm-dd> | <principle> | <reason / trade-off> | <where it applies> |

**Version**: <constitution-version> | **Ratified**: <yyyy-mm-dd> | **Last Amended**: <yyyy-mm-dd>
