# Morning-After Run Report Template

> One file per larger or multi-session build handoff. Copy this into `docs/handoff/<UTC-timestamp>_<slug>.md`
> (or `.wgm/docs/handoff/...` in existing-project mode) and fill it from durable docs plus live
> PR/CI state — not from transcript archaeology. This follows the "morning-after run report" pattern
> noted for [elves](https://github.com/aigorahub/elves) in `docs/plans/2026-06-16_RALPH_LANDSCAPE.md`.

# Morning-After Run Report — <UTC timestamp> — <slug>

- **Scope:** <feature / slice / branch set>
- **Operator:** <name or team>
- **Plan of record:** <path to IMPLEMENTATION_PLAN.md or .wgm/IMPLEMENTATION_PLAN.md>
- **Resume command:** <for example: `/wgm build` or `./scripts/loop.sh build 20 -- ...`>

## What shipped
| PR / change | State | Link | Notes |
|---|---|---|---|
| <#123> | <merged \| open \| draft> | <url> | <what landed> |

## Validation state
| Command | Latest result | Where it ran | Notes |
|---|---|---|---|
| <npm test> | <green \| red> | <local \| CI link> | <what it proves / failing area> |

## What remains
- Remaining tasks live in **`IMPLEMENTATION_PLAN.md`**: <link/path + the next not-done task(s)>
- Known blockers / operator decisions: <none | bullets>

## How to resume cold
1. Read the current `IMPLEMENTATION_PLAN.md` status and the most recent spec/demo-path task notes.
2. Check the PR/CI links above for anything that changed after the last loop iteration.
3. Resume with the command in **Resume command**, starting from the next `pending` or `blocked` task.
