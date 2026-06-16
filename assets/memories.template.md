# wgm memories — lessons that outlive one iteration

> Append-only, **token-budgeted** working memory (~2000 tokens; trim the oldest entries when over).
> The agent reads this at the start of each Analyze so it does not relearn the same lesson, and
> appends to it in Record. Lives at `.wgm/memories.md`. Distinct from `IMPLEMENTATION_PLAN.md` (task
> state), `AGENTS.md` (how to build & validate), and `.wgm/scores.md` (numeric trajectory): memories
> are the raw, accumulating lessons of *this* build.

## Gotchas (things that bit us)
- <yyyy-mm-dd> <one-line gotcha + the workaround, e.g. "tests need DATABASE_URL set; export it first">

## Stall lessons (cause -> fix)
- <yyyy-mm-dd> <what stalled> -> <the root cause> -> <the fix that actually moved the signal>

## Patterns that work here
- <yyyy-mm-dd> <a technique or convention worth repeating in this codebase>

## Dead ends (do not retry)
- <yyyy-mm-dd> <an approach that failed, and why, so a fresh context does not loop back to it>
