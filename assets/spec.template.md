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
| Criterion | How it's verified (command/check) |
|---|---|
| <criterion> | <`npm test ...` / `pytest ...` / curl probe / type-check / LLM-judge> |

## Holdout scenarios
- **Files:** <`scenarios/*.yaml` (or `.wgm/scenarios/`) that verify this slice from the user's seat>
- **Holdout rule:** authored here, but the Implement step must NOT read them — only Validate/Review
  judges against them. Tier them 1–3 for stratified validation. See `references/scenarios.md`.

## Assumptions
- <Recommended assumption made during grilling, to be confirmed if it proves wrong>

## Out of scope (this pass)
- <Explicit non-goal>
