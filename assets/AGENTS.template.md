# AGENTS.md

> Operational guide only — how to build, run, and validate this project, plus durable codebase
> patterns. **No status or progress notes** (those live in `IMPLEMENTATION_PLAN.md`). Keep this
> lean: it loads into every iteration's context.

## Build & run
```bash
<install deps, e.g. npm install / uv sync>
<run the app, e.g. npm run dev / python -m app>
```

## Validate (backpressure)
```bash
<the pass/fail signal, e.g. npm test / pytest / npm run typecheck / npm run lint>
```
- The loop is not done on a task until this is green for that task.

## Operational notes
- <env vars, services, ports, fixtures the agent needs to know>

## Codebase patterns
- <conventions, key utilities, and where to find them — the "signs" the agent should follow>
