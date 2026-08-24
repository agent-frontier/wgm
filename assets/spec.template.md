# Spec: <slice name>

> One spec per coherent slice. Keep these sections; flex the rest per project.
> Must conform to `specs/CONSTITUTION.md` — note any intentional deviation under Assumptions.

## JTBD (job to be done)
<What job is the user hiring this to do, and for whom?>

## User-visible success criteria
- <Observable "done" #1>
- <Observable "done" #2>

## Magic moment
- **The whoa:** <the single thing that should impress the user>
- **Demo path:** <the exact steps to experience it>
- **Smallest end-to-end slice:** <the minimal vertical slice that proves the value>
- **Merely functional vs magical:** <what would make this feel flat, so we avoid it>

## Acceptance criteria → backpressure
Phrase each criterion in **EARS** (see `references/artifacts.md`) — e.g. "When [trigger], the
[system] shall [response]" — so it is unambiguous and a command or judge can settle it.

| Criterion (EARS) | How it's verified (command/check) |
|---|---|
| <criterion> | <`npm test ...` / `pytest ...` / curl probe / type-check / LLM-judge> |
| When a user submits valid credentials, the API shall return 200 with a token | `pytest -k login_ok` |

## Holdout scenarios
- **Files:** <`scenarios/*.yaml` (or `.wgm/scenarios/`) that verify this slice from the user's seat>
- **Holdout rule:** authored here, but the Implement step must NOT read them — only Validate/Review
  judges against them. Tier them 1–3 for stratified validation. See `references/scenarios.md`.

## Ruggedness (rugged gate)
Who and what this slice must actually survive — filled at Plan, re-checked at Review.

- **Actual operators:** <who really runs/maintains this: skill level, staffing, on-call, turnover>
- **Actual environment:** <load, latency, dependency failure modes, what 3am during an incident looks like>
- **Dominant risk bucket:** <intrinsic design constraint | user capacity | operational stress — and why>
- **Simplification accepted:** <the moving part removed, or made to degrade visibly, and its trade-off>
- **Exact field/stress/recovery check:** <runnable command/probe · origin/environment · expected observation · failure + recovery criterion>
- **Plan-exit verdict:** <RUGGED | FRAGILE | UNKNOWN> — <yyyy-mm-dd> · produced by <`/rugged plan` | inline rubric (companion unavailable)>

Exactly one verdict. RUGGED passes. FRAGILE blocks and needs a remediation task; UNKNOWN blocks and
needs a validation-signal task that creates the missing evidence. An absent verdict is a gate FAIL,
never a pass. See `SKILL.md`, "The ruggedness gate".

## Assumptions
- <Recommended assumption made during grilling, to be confirmed if it proves wrong>

## Out of scope (this pass)
- <Explicit non-goal>
