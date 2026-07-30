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

## Ralph-lite vs Ralph-full — prefer Ralph-full whenever it's invocable
Geoffrey Huntley's original definition is blunt: *"Ralph is a technique. In its purest form, Ralph is
a Bash loop"* — `while :; do cat PROMPT.md | agent; done` — a single monolithic process, one task per
loop, with progress living on disk (not the model's context) between passes
(`ghuntley/how-to-ralph-wiggum`, ghuntley.com/loop). Staying in-session for convenience is the
*weaker*, compromise form of the technique, not the default to reach for out of habit.
- **Ralph-full (preferred whenever it's invocable)** — genuinely fresh context per iteration via
  `scripts/loop.sh`, or by restarting with a clean context. Reach for it whenever a non-interactive
  agent invocation is available: an operator-set `WGM_AGENT`, or a known CLI (`copilot`, `claude`,
  `codex`, `aider`) on `PATH` with a print/non-interactive mode. **Detecting capability:** if you
  (the in-session agent) can shell out to invoke a CLI agent non-interactively — the same check
  `scripts/loop.sh`'s wiring already assumes (`docs/operator/running-the-loop.md` "Wiring up your
  agent") — prefer launching the loop over continuing in-session, even for small/medium work. Run it
  **sandboxed and disk-conscious** with `--devcontainer` (`references/devcontainers.md`) when you
  want the loop isolated from the host without a new multi-GB image per project.
- **Ralph-lite (fallback)** — run the loop in-session when no headless invocation exists (a purely
  interactive host) or the work is **Quick**-track (a whole subprocess loop is overkill for one short
  prompt once clarification lands). Compensate for context accumulation with strict persistence:
  after every iteration, write the next state into `IMPLEMENTATION_PLAN.md` so a fresh agent could
  continue.
- **Multi-layer builds** — when `references/gene-transfusion.md`'s genes artifact reveals a clear
  component dependency DAG, neither mode has to converge the whole system in one monolithic pass:
  see that reference's "Composed convergence" section for topologically-sorted per-component
  mini-loops that finish with an integration-validation pass.

## The per-iteration algorithm
`Analyze → Implement → Validate → Review → Record`
1. **Analyze** — read only `IMPLEMENTATION_PLAN.md`, the relevant spec, and this task's files. If
   the host exposes an optional MCP code-intelligence layer (for example,
   [`oraios/serena`](https://github.com/oraios/serena)), use it to narrow symbol / call-graph /
   cross-reference lookup before falling back to grep; wgm itself does not bundle or require that
   retrieval layer.
2. **Implement** — smallest change that completes one task; prefer a working vertical slice.
3. **Validate** — run the task's backpressure command. Green or it isn't done.
4. **Review** — diff check: scope creep, acceptance met, signal actually proves the task.
5. **Record** — update the plan: status, results, follow-ups. Once the task's validation
   command exits 0, commit that iteration with a Conventional Commits message (`type: imperative
   description`, ≤72 chars; `fix` / `feat` / `refactor` / `docs` / `test` / `chore` / `build` /
   `ci`) so history mirrors the one-task loop; if git is unavailable, the plan-file record is
   still required. Adapted from `Aider-AI/aider`'s Conventional-Commits-style auto-commit habit.
   Make it fresh-agent-resumable.

## Backpressure in depth
- **PR-level CI green is not proof of a real deploy.** When a project has a deploy pipeline distinct
  from its per-PR checks — a common shape: PR-triggered checks run tests/lint/build-smoke, while a
  *separate* workflow, triggered only on push to the default branch after merge, does the real
  build-push-migrate-deploy — treat `gh pr checks` going green as proof the *change is safe to
  merge*, never as proof it *shipped*. Whenever a task's acceptance criteria implies reaching a
  running deployment (not just a merged commit), explicitly check that separate deploy workflow's
  own most-recent run status too (e.g. `gh run list --workflow=<deploy-workflow-file> --limit 1`).
  A real dogfood run merged 8 PRs across a multi-hour session, each only after its own PR-level CI
  was green, while a separate post-merge deploy workflow's database-migration step had been silently
  failing since the very first merge — 7 consecutive failed deploys, invisible because nothing ever
  checked that second workflow's run history, discovered only when the human asked why "complete"
  work wasn't visible on the live site. Treat a currently-red deploy workflow as a standing blocker
  surfaced immediately (mid-loop, at Record — not deferred to a Ship/Handoff afterthought), since
  every later iteration otherwise silently builds on an environment that never received the earlier
  "done" work (`[learn]` issue #60).
- Map every acceptance criterion to a runnable check. If the project has none, the first task is to
  build one (a failing test, a curl probe, a type-check command).
- **Check the toolchain is present before checking it's compatible.** Before reasoning about whether
  a runtime is *newer/odder* than a tool's tested baseline (below), do a trivial presence check first
  — `which <tool>` or a version probe — that the required runtime/toolchain is installed **at all**.
  A real dogfood run's first validation attempt failed immediately because the sandbox had no
  `java`/`JAVA_HOME`, forcing a mid-task detour before any real work could start; a one-line presence
  check at T1 is strictly cheaper than the end-to-end proof below and catches a more basic failure
  mode (`[learn]` issue #57).
- **De-risk an unusual runtime at T1.** If the build's host runtime is newer, older, or odder than a
  key tool's tested baseline (a bleeding-edge language major vs. a framework's LTS target), make the
  *first* task prove the whole toolchain end-to-end — install it, get a trivial hello-world through
  the real build/run path, assert the real output exists — before any feature work, and pre-commit a
  fallback (pin a known-good version) in case it misbehaves. This extends "the first task is to
  build a validation signal" to the runtime/environment axis, not just the test harness.
- Prefer fast, deterministic signals. A 2-second deterministic check beats a 30-second flaky one.
- **A green isolated retry does not clear a failed full-suite gate.** When a test fails in the suite
  and passes when run alone, the isolated pass is *not* the answer — it is a second data point, and
  the difference between the two runs is the bug. Look at lifecycle ordering first: an operating
  system can discard buffered output that was never read when a producer tears down, so a consumer
  that "sees nothing" under suite conditions is a real race, not flakiness. Fix it by synchronizing
  producer teardown to consumer acknowledgement, stress the exact test repeatedly to prove the race
  is gone, and then **rerun the complete gate** — the full suite is the gate, and only a green full
  suite clears it (`[learn]` issue #80).
- **Take test-filter evidence from the runner, not from source scans.** When acceptance or a holdout
  says "the N tests matching `<filter>` pass," get N from the **runner's own reported selected/passed
  counts** and preserve the exact command. Do not infer it by grepping source for functions whose
  names start with the filter: runners commonly match a filter *anywhere* in a fully qualified test
  name, so a static count and the real count legitimately differ. When they disagree, treat it as a
  **measurement defect in your counting method** until authoritative runner output says otherwise —
  concluding "tests are missing" from a source-prefix scan sends you chasing a phantom gap
  (`[learn]` issue #81).
- **Check whether CI is even defined on the branch you target.** A workflow can live only on an
  unmerged sibling branch, so tightly-scoped local gates go green while the workspace-wide CI that
  will eventually gate the base branch fails — on **pre-existing** debt in code your change never
  touched. Before reporting "validated," enumerate workflow files across **all** branches, not just
  base/HEAD (`git ls-tree <branch> .github/workflows`, or the host API's per-branch contents). Then
  distinguish in the handoff between *"this change's own files pass the workspace gate"* (verifiable
  now) and *"the whole workspace passes it"* (may be blocked by pre-existing debt). Record that debt
  as a dedicated chore task — do **not** fold unrelated fmt/lint cleanup into a feature PR to chase
  a not-yet-active CI, and do not let it silently sink the first PR that lands after the CI does
  (`[learn]` issue #77).
- **Known limitation: exit codes are a blunt signal.** `scripts/loop.sh` currently judges an
  iteration by process exit code only, which can miss a "succeeded but did nothing useful" response
  or treat a semantically empty exit-0 turn as progress. A future enhancement pattern is
  **semantic exit / response analysis** — inspect the response content as well as the exit code, as
  [`ralph-claude-code`](https://github.com/frankbria/ralph-claude-code) does — but that is a
  candidate upgrade, not a current `loop.sh` capability.
- **Spec-drift pre-check (optional, cheap).** Before running the task's full validation command,
  diff the files actually touched against the task's declared files/areas in
  `IMPLEMENTATION_PLAN.md`. A mismatch (e.g. a task scoped to `schema/` touching UI files) is a
  cheap, early signal of scope or spec drift — worth flagging before spending the validation budget
  on a run that was never going to prove the right thing. Adapted from
  [`saitarrun/devforge-ai`](https://github.com/saitarrun/devforge-ai)'s `ralph-loop` skill (its
  "Sentinel" health check, which also flags "context drift" — a new log
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
  Extract the key identifiers the task actually names (function / class / variable names), not just
  conceptual keywords, and search those exact names first. For each hit, also inspect what imports
  or calls it; the defining file is only half the surface area. Deprioritize identifiers that show
  up everywhere (generic helpers, framework builtins) — they are usually noise, not signal.
  Adapted from [`Aider-AI/aider`](https://github.com/Aider-AI/aider)'s `aider/repomap.py`. **Widen
  the search past the local repo:**
  also check declared dependencies, mandated companion tools, and the platform/runtime for the
  capability — a project's "additive to X, never duplicate X" rule is only enforceable if Analyze
  actually inspects X. If a dependency or companion already ships it, drop the build task,
  wire/enable the existing provider instead, and record why.
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
- **Outgrown the flat log?** For optional named alternatives for long builds, see
  `references/memory-patterns.md`.
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
- **Small/local-context models (≲65–100k tokens):** the generic ~50% default under-rotates — the
  fixed skill+plan+spec overhead is a bigger slice of a small window. Rotate earlier (~35–40% of the
  window) and read narrower; see `references/local-models.md` for concrete budgets.

## Stop / regenerate conditions
- All must-have tasks are `done` → ship/handoff.
- The same task fails ~3 times, or the satisfaction score stalls → first run a **wonder/reflect**
  recovery and consider model escalation (`stall-recovery.md`); if still stuck, record the blocker,
  stop, ask or regenerate the plan. Regenerating the plan is cheap; a loop going in circles is not.
- If `[INVALIDATES: ...]` flags (the plan-invalidating-discovery tag from
  `references/self-improvement.md`'s Harvest step) keep piling up across still-pending tasks, a
  stall pattern keeps recurring on *different* tasks, or the build's actual path no longer matches
  the spec's magic moment / demo path, treat it as **plan drift**, not just one task needing a
  better Record step.
- When the plan is structurally stale, regenerate `IMPLEMENTATION_PLAN.md` from the current spec,
  the completed work, and the accumulated memories instead of incrementally patching a plan whose
  assumptions no longer hold.
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
