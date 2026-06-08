# The Ralph loop

Ralph is a powerful, dumb little idea: keep restarting an agent with the same prompt and a
persistent plan on disk, let it pick the most important task, do it, validate, record, and repeat.
The plan file is the memory; each iteration is otherwise disposable. wgm adapts this for an agent.

## Core principles
- **Context is everything.** Tight task + one task per iteration = the model spends its smart-zone
  context on the work, not on archaeology. Bloated context = degraded output.
- **One task per loop.** Pick the single most important `pending` task. Finish it. Stop.
- **Patterns + backpressure steer the agent.** Two forces keep iterations on track:
  - *Patterns/signs:* existing utilities, conventions, `AGENTS.md`, specs — the agent discovers and
    follows them. When the agent drifts, add a sign.
  - *Backpressure:* a deterministic pass/fail signal (test, type-check, build, lint, HTTP probe)
    that rejects bad work. No signal → no real loop.
- **Let Ralph Ralph.** The agent chooses which task is most important and how to implement it.
  Don't micro-script; provide signs and signals and let it work.
- **Move outside the loop.** The human sits *on* the loop, not *in* it: observe failure patterns
  and add signs (a prompt note, a utility, a spec clarification) rather than hand-holding each step.

## Ralph-lite vs Ralph-full
- **Ralph-lite** — run the loop in-session. Fine for small/medium work. Compensate for context
  accumulation with strict persistence: after every iteration, write the next state into
  `IMPLEMENTATION_PLAN.md` so a fresh agent could continue.
- **Ralph-full** — the stronger mode: genuinely fresh context per iteration via `scripts/loop.sh`
  or by restarting with a clean context. Use it for large or ambiguous builds. Fresh context is the
  whole point of Ralph; honor it when the work is big.

## The per-iteration algorithm
`Analyze → Implement → Validate → Review → Record`
1. **Analyze** — read only `IMPLEMENTATION_PLAN.md`, the relevant spec, and this task's files.
2. **Implement** — smallest change that completes one task; prefer a working vertical slice.
3. **Validate** — run the task's backpressure command. Green or it isn't done.
4. **Review** — diff check: scope creep, acceptance met, signal actually proves the task.
5. **Record** — update the plan: status, results, follow-ups. Make it fresh-agent-resumable.

## Backpressure in depth
- Map every acceptance criterion to a runnable check. If the project has none, the first task is to
  build one (a failing test, a curl probe, a type-check command).
- Prefer fast, deterministic signals. A 2-second deterministic check beats a 30-second flaky one.
- Include at least one **end-to-end demo check** that exercises the spec's smallest demo path —
  narrow unit/build checks can pass while the actual user flow is broken.
- Only when no deterministic check can exist (UX feel, copy, aesthetics) fall back to an
  LLM-as-judge with a binary pass/fail; record its prompt and verdict, and accept that it varies
  run to run.
- For holistic/holdout judgment, an LLM-as-judge **satisfaction score (0–100)** against holdout
  scenarios can augment binary checks; converge to a threshold (default 95). Deterministic checks
  still gate "done." See `scoring.md` and `scenarios.md`.
- "Important: when authoring code and docs, capture the *why* — and the test that proves it."

## Context-hygiene gate (every iteration)
- Read the minimum set, not the whole repo.
- Advance exactly one task.
- End by writing handoff-quality state into the plan.
- If context feels bloated, stop and hand off rather than push on.

## Stop / regenerate conditions
- All must-have tasks are `done` → ship/handoff.
- The same task fails ~3 times, or the satisfaction score stalls → first run a **wonder/reflect**
  recovery and consider model escalation (`stall-recovery.md`); if still stuck, record the blocker,
  stop, ask or regenerate the plan. Regenerating the plan is cheap; a loop going in circles is not.
- The trajectory is clearly wrong (building the wrong thing, duplicating work) → stop and re-plan.

## Keep AGENTS.md lean
`AGENTS.md` is operational only: how to build, run, and validate, plus durable codebase patterns.
Status updates and progress notes belong in `IMPLEMENTATION_PLAN.md`. A bloated `AGENTS.md`
pollutes every future iteration's context.
