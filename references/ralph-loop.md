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
- **De-risk an unusual runtime at T1.** If the build's host runtime is newer, older, or odder than a
  key tool's tested baseline (a bleeding-edge language major vs. a framework's LTS target), make the
  *first* task prove the whole toolchain end-to-end — install it, get a trivial hello-world through
  the real build/run path, assert the real output exists — before any feature work, and pre-commit a
  fallback (pin a known-good version) in case it misbehaves. This extends "the first task is to
  build a validation signal" to the runtime/environment axis, not just the test harness.
- Prefer fast, deterministic signals. A 2-second deterministic check beats a 30-second flaky one.
- **Spec-drift pre-check (optional, cheap).** Before running the task's full validation command,
  diff the files actually touched against the task's declared files/areas in
  `IMPLEMENTATION_PLAN.md`. A mismatch (e.g. a task scoped to `schema/` touching UI files) is a
  cheap, early signal of scope or spec drift — worth flagging before spending the validation budget
  on a run that was never going to prove the right thing. Adapted from `saitarrun/devforge-ai`'s
  `ralph-loop` skill (its "Sentinel" health check, which also flags "context drift" — a new log
  entry conspicuously shorter than prior ones).
- Include at least one **end-to-end demo check** that exercises the spec's smallest demo path —
  narrow unit/build checks can pass while the actual user flow is broken.
- Only when no deterministic check can exist (UX feel, copy, aesthetics) fall back to an
  LLM-as-judge with a binary pass/fail; record its prompt and verdict, and accept that it varies
  run to run.
- For holistic/holdout judgment, an LLM-as-judge **satisfaction score (0–100)** against holdout
  scenarios can augment binary checks; converge to a threshold (default 95). Deterministic checks
  still gate "done." See `scoring.md` and `scenarios.md`.
- "Important: when authoring code and docs, capture the *why* — and the test that proves it."
- **Project-wide gates (a floor):** an optional `wgm.yml` (or `.wgm/gates.yml`) lists commands every
  iteration must keep green — a backpressure floor independent of each task's own check. `loop.sh`
  injects them into every build prompt (`--gates FILE` to override).

## Standing guardrails
Inject these into **every** iteration — they prevent recurring loop failures:
- **Search before you build.** Before adding code, grep the codebase for an existing implementation
  (parallel searches help). The classic Ralph failure is re-implementing something that already
  exists because one quick search came up empty. Don't assume a feature is missing — prove it is.
  **Widen the search past the local repo:** also check declared dependencies, mandated companion
  tools, and the platform/runtime for the capability — a project's "additive to X, never duplicate
  X" rule is only enforceable if Analyze actually inspects X. If a dependency or companion already
  ships it, drop the build task, wire/enable the existing provider instead, and record why.
- **Document why each test exists.** When you add a test, record in a comment what behavior it proves
  and why it matters. A fresh context that can't see the rationale may delete the test as an orphan,
  silently dropping coverage.
- **Format only what you touched.** Never run a project- or crate-wide auto-formatter mid-iteration —
  it rewrites files this task never touched, leaving stray churn that can block a branch switch and
  buries the one-task diff in reformatting noise. Hand-format to the house style, or format only the
  exact files this task changed; run a full reformat (if ever needed) as its own separate, reviewed
  change.

## Memory (cross-iteration learning)
Fresh context per iteration is Ralph's strength, but it also forgets. A small, token-budgeted
`.wgm/memories.md` closes that gap without re-polluting context:
- **Recall in Analyze:** read it first so you don't re-hit a known gotcha or re-walk a dead end.
- **Append in Record:** add the one-line lesson from this iteration (a fix that worked, a gotcha, a
  stall's cause). Keep it within ~2000 tokens — trim the oldest when over.
- **Cross-check prior commitments at Ship/Handoff:** if a previous session's memories include an
  explicit "resolve to..." / "next time..." commitment and this build reused the same
  `.wgm/memories.md`, add a one-line ✅/❌ note on whether it actually happened. This is a
  deliberately lighter-weight adaptation of
  [`BMAD-METHOD`](https://github.com/bmad-code-org/BMAD-METHOD)'s
  `src/bmm-skills/4-implementation/bmad-retrospective/SKILL.md`, not BMAD's full ceremony — wgm
  has no epic/story structure to retro against.
- **Promote at handoff:** a lesson that is durable and cross-project can graduate upstream — a
  sanitized `[learn]` report that lands in the shared skill's ledger (`references/self-improvement.md`).
- It is **not** `AGENTS.md` (curated how-to) or `IMPLEMENTATION_PLAN.md` (task state); it is the raw
  lessons log. See `references/artifacts.md`.

## Context-hygiene gate (every iteration)
- Read the minimum set, not the whole repo.
- Advance exactly one task.
- End by writing handoff-quality state into the plan.
- If context feels bloated, stop and hand off rather than push on.

## Context rotation (summarize, then refresh)
Long in-session runs degrade as the window fills — the ecosystem's fix is to **rotate context at a
token threshold** (e.g. cursor rotates ~80k tokens) and **summarize forward** (Vercel's loop) so no
progress is lost. wgm's rule:
- **Set a budget.** Pick a threshold well below the model's window — a practical default is ~50% of
  it, or a host-configured token cap. Treat crossing it as a stop signal, not a soft suggestion.
- **Summarize before you rotate.** Write handoff-quality state into `IMPLEMENTATION_PLAN.md` (task
  statuses + the exact next step) and append durable lessons to `.wgm/memories.md`. The summary —
  not the transcript — is what survives the rotation.
- **Rotate to fresh context.** Start the next iteration clean, reloading only the lean plan, the
  relevant spec, `.wgm/memories.md`, and `specs/CONTEXT.md` — never the old transcript.
- **Ralph-full already rotates** every iteration (a fresh process per loop); **Ralph-lite** rotates
  on the threshold. Either way the persistent files are the memory — keep them lean (`artifacts.md`).

## Stop / regenerate conditions
- All must-have tasks are `done` → ship/handoff.
- The same task fails ~3 times, or the satisfaction score stalls → first run a **wonder/reflect**
  recovery and consider model escalation (`stall-recovery.md`); if still stuck, record the blocker,
  stop, ask or regenerate the plan. Regenerating the plan is cheap; a loop going in circles is not.
- The trajectory is clearly wrong (building the wrong thing, duplicating work) → stop and re-plan.
- **Autonomous + manual-merge: cap concurrent open PRs (~3-5).** In an autopilot loop that ships one
  PR per iteration into a repo a human merges by hand, an open-ended stream of net-new PRs floods the
  maintainer and deepens the shared-file conflict surface while nothing actually lands. Past the cap,
  the next iteration's task becomes **consolidation** — help land, rebase, or merge existing PRs —
  instead of opening another one; merged value beats more net-new work.

## Keep AGENTS.md lean
`AGENTS.md` is operational only: how to build, run, and validate, plus durable codebase patterns.
Status updates and progress notes belong in `IMPLEMENTATION_PLAN.md`. A bloated `AGENTS.md`
pollutes every future iteration's context.
