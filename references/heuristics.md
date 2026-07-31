# Heuristics — wgm's retained juice

The curated, version-controlled ledger of **durable, cross-project** lessons that have graduated out
of ephemeral `.wgm/memories.md` into the shared skill. This is wgm's long-term memory: each entry
changed how wgm behaves *everywhere*, not just in one build. See
[`self-improvement.md`](self-improvement.md) for how lessons get here.

**Adding an entry** (one thought per entry, newest at the top of its section):
- **Heuristic** — the durable rule, stated as an imperative.
- **Why** — the failure it prevents or the value it adds.
- **Provenance** — where it was learned (a dogfood run, a `[learn]` issue, an influence).
- **Landed in** — the skill artifact that now enforces it.

Prune or merge entries that a protocol change has made redundant — the ledger stays lean, like the
memory it graduates from. (Status: zero entries pruned across 4 consolidation rounds so far — 41
entries and counting; not yet a problem at this size, but a future round should watch for when a
prune becomes due — `docs/audit/README.md`.)

## Triage & Grill
- **Heuristic:** run a cross-requirement consistency scan before leaving Grill: contradictions,
  vague thresholds, and undefined referenced concepts must be resolved or made measurable.
  **Why:** requirements that look fine in isolation can still be mutually impossible or vague enough
  to fork the implementation once design starts. **Provenance:** external research, Kiro's
  `kiro.dev/docs/specs/analyze-requirements/`. **Landed in:** `references/grilling.md`
  (Grill-exit gate).
- **Heuristic:** reserve the Quick track for work that fits in one short prompt and one agent turn
  once clarification lands; if it still needs research or unsettled decisions, pay the loop tax.
  **Why:** "small diff" is not the same as "small ambiguity surface" — under-scoping a decisionful
  task as Quick skips exactly the ceremony that keeps it from drifting. **Provenance:** external
  research, `open-gsd/gsd-core`'s `docs/explanation/context-engineering.md` +
  `docs/explanation/the-phase-loop.md`. **Landed in:** `SKILL.md` (Triage track table).
- **Heuristic:** when a Quick-track task is genuinely a single task — one fix, one validation
  command, no multi-step demo path — let that task's own validation command double as the
  demo-validation task, and allow a single short paragraph in place of a formal plan/spec file.
  **Why:** two independent real dogfood runs in the same session, on unrelated codebases (a 3-file
  Java/Quarkus fix and a 2-file .NET fix), converged on the same friction without prompting: a
  formal plan artifact and a *separate* demo-validation task both felt like ceremony when the fix
  task and the demo path were already the same thing. **Provenance:** wgm dogfood, `[learn]` issue
  #56 (`SchwartzKamel/floci-az` Event Hubs `tls-cert` fix + `SchwartzKamel/blogster` `PostsController`
  compile-blocker fix). **Landed in:** `SKILL.md` (Plan-exit gate).
- **Heuristic:** scan ambiguity against a named taxonomy, then ask the highest
  **Impact × Uncertainty** question with a recommendation-first format.
  **Why:** a fixed scan catches the missing dimension an ad-hoc interview forgets, and a
  recommendation-first multiple-choice prompt lets the user advance with a one-word "yes" instead of
  spending a turn restating your own best option. **Provenance:** external research,
  `github/spec-kit`'s `templates/commands/clarify.md`. **Landed in:** `references/grilling.md`.

## Planning & artifact quality
- **Heuristic:** treat a spec-quality checklist as "unit tests for English," and re-run it after
  each accepted Grill answer until the pass count stabilizes.
  **Why:** readiness scoring works better as a confirmation step than as the first place basic
  requirement rot is discovered; a living checklist surfaces clarity/coverage gaps while they are
  still cheap to fix. **Provenance:** external research, `github/spec-kit`'s
  `templates/commands/checklist.md` + `templates/commands/specify.md`. **Landed in:**
  `references/artifacts.md`.

## Loop discipline
- **Heuristic:** default to Ralph-full (genuinely fresh context per iteration via `scripts/loop.sh`)
  whenever a non-interactive agent invocation is available, not only for large/ambiguous builds;
  reserve Ralph-lite (in-session) for interactive-only hosts or Quick-track work.
  **Why:** the original technique's own definition is "Ralph is a technique. In its purest form,
  Ralph is a Bash loop" — a single monolithic process with progress living on disk, not model
  context, between passes. Treating in-session execution as the default rather than the fallback
  quietly settles for the weaker, compromise form of the technique even when the purer form is one
  subprocess call away. **Provenance:** external research, `ghuntley/how-to-ralph-wiggum` +
  ghuntley.com/loop (Geoffrey Huntley's original Ralph definition). **Landed in:** `SKILL.md`
  (Phase 0 — Decide loop mode) · `references/ralph-loop.md` (Ralph-lite vs Ralph-full) ·
  `docs/operator/running-the-loop.md`.
- **Heuristic:** verify the project's working tree is clean before the first loop iteration.
  **Why:** prompt-only skills lack shadow-checkpoint infrastructure; a clean git baseline keeps the
  repo's own history as a reliable rollback path when an iteration destabilizes the tree.
  **Provenance:** external research, `RooCodeInc/Roo-Code`'s
  `src/services/checkpoints/ShadowCheckpointService.ts`. **Landed in:** `SKILL.md` (Phase 2.5 —
  Preflight).
- **Heuristic:** before treating a local clone as a live dogfood target, `git fetch` it and
  check for archival/retirement signals (`ARCHIVED.md`, a retirement/archive commit message, or
  GitHub's archived-repository flag). **Why:** a stale local clone can silently hide that upstream
  has already been retired, so wgm can do technically correct work and even open a real PR against a
  project whose owner has already declared no further work is expected. **Provenance:** wgm
  dogfood, `[learn]` issue #59 (`SchwartzKamel/blogster`, stale local clone masking upstream
  retirement). **Landed in:** `references/self-improvement.md` (Health check target-freshness
  guardrail).
- **Heuristic:** treat an A→B→A→B alternation across four iterations as a named oscillation, and
  break it with a no-revert, different-architecture steer.
  **Why:** generic diff churn notices motion but misses the stronger signal that the loop is
  literally bouncing between two states; naming it justifies a harder intervention than another
  small tweak. **Provenance:** external research, `foundatron/octopusgarden`'s
  `internal/attractor/oscillation.go`. **Landed in:** `references/stall-recovery.md`.
- **Heuristic:** when the genes artifact reveals a component DAG, converge the components in
  topological mini-loops before running the full integration pass.
  **Why:** foundational layers stabilize cheaper in isolation, and later layers get higher-signal
  context from already-converged dependencies instead of fighting the whole stack at once.
  **Provenance:** external research, `foundatron/octopusgarden`'s `docs/gene-transfusion.md` +
  `internal/attractor/toposort.go`. **Landed in:** `references/gene-transfusion.md`.
- **Heuristic:** after a task's validation command exits 0, commit that iteration with a
  Conventional Commits message. **Why:** one green task per commit keeps history aligned with the
  plan's one-task loop without leaving broken commits behind. **Provenance:** external research,
  `Aider-AI/aider`'s Conventional-Commits-style auto-commit workflow. **Landed in:** `SKILL.md`
  Loop · Record · `references/ralph-loop.md` (The per-iteration algorithm).
- **Heuristic:** search exact task-named identifiers first, then follow their callers/importers
  before deciding where to edit. **Why:** conceptual keyword search misses the real change surface,
  and stopping at the defining file misses the files that actually need changing. **Provenance:**
  external research, `Aider-AI/aider`'s `aider/repomap.py`. **Landed in:**
  `references/ralph-loop.md` (Standing guardrails).
- **Heuristic:** before running a task's full validation command, diff actually-touched files
  against its declared files/areas from `IMPLEMENTATION_PLAN.md` as a cheap pre-check.
  **Why:** a mismatch (e.g. a task scoped to `schema/` touching UI files) is an early signal of
  scope/spec drift — catching it before the validation budget is spent beats discovering it only
  after a full, possibly expensive run finishes. **Provenance:** external research,
  `saitarrun/devforge-ai`'s `ralph-loop` skill (its "Sentinel" health check). **Landed in:**
  `references/ralph-loop.md` (Backpressure in depth).
- **Heuristic:** never run a project- or crate-wide auto-formatter mid-iteration; format only the
  exact files this task touched. **Why:** a blanket formatter rewrites untouched files, leaving
  stray churn that blocks a branch switch and buries the one-task diff in reformatting noise.
  **Provenance:** wgm dogfood, `[learn]` issue #37 (Rust `cargo fmt -p` rewrote 14 files, 2 were the
  task). **Landed in:** `references/ralph-loop.md` (Standing guardrails) · `SKILL.md` Loop · Implement.
- **Heuristic:** extend "search before you build" past the local repo to declared dependencies and
  mandated companion tools; if one already ships the capability, drop the task and wire it in.
  **Why:** a repo-only grep can't see a capability that lives in a sibling tool the project composes
  with, so it stays invisible to the standard guardrail. **Provenance:** wgm dogfood, `[learn]` issue
  #31. **Landed in:** `references/ralph-loop.md` (Standing guardrails) · `SKILL.md` Loop · Analyze.
- **Heuristic:** in an autonomous, manual-merge loop, cap concurrent open PRs (~3-5); past the cap,
  the next iteration consolidates existing PRs instead of opening another one. **Why:** an
  open-ended stream of net-new PRs floods the maintainer and deepens the shared-file conflict
  surface while nothing actually lands — merged value beats more net-new work. **Provenance:** wgm
  dogfood, `[learn]` issue #36 (18 PRs open, 0 merged). **Landed in:** `references/ralph-loop.md`
  (Stop/regenerate conditions) · `SKILL.md` Stop conditions.
- **Heuristic:** search the codebase for an existing implementation before building anything.
  **Why:** assuming a feature is missing and rebuilding it is a top loop-failure mode.
  **Provenance:** ghuntley/Ralph standing guardrail. **Landed in:** `SKILL.md` Loop · Analyze.
- **Heuristic:** advance exactly one task per iteration and write handoff-quality state before
  stopping. **Why:** a fresh context must be able to resume from the plan alone.
  **Provenance:** Ralph loop. **Landed in:** `SKILL.md` Iteration-exit gate.

## Backpressure
- **Heuristic:** when a project has a deploy pipeline distinct from its per-PR CI, treat PR-level
  green as proof a change is safe to merge, never as proof it shipped — explicitly check the
  separate deploy workflow's own latest run whenever a task's acceptance criteria implies reaching
  a live deployment, and treat a red one as a standing blocker surfaced immediately, not deferred to
  Ship/Handoff. **Why:** a real session merged 8 CI-green PRs while a separate post-merge deploy
  workflow's migration step had been silently failing since the first merge — 7 consecutive failed
  deploys, invisible for hours until the human asked why "complete" work wasn't live. **Provenance:**
  wgm dogfood, `[learn]` issue #60. **Landed in:** `references/ralph-loop.md` (Backpressure in
  depth) · `SKILL.md` (Loop Validate step · Ship/Handoff).
- **Heuristic:** when a skill already has an eval fixture, standardize the *graded* output on a
  per-run `grading.json` plus a cross-run `benchmark.json` before inventing bespoke summaries.
  **Why:** fixed schemas make manual judging automatable later, preserve assertion-level evidence,
  and make with-skill vs. baseline deltas comparable across runs. **Provenance:** external
  research, `anthropics/skills` `skill-creator` (`agents/grader.md`,
  `scripts/aggregate_benchmark.py`, `references/schemas.md`). **Landed in:**
  `references/evals.md` (Automated grading protocol).
- **Heuristic:** a trigger-eval table can be made executable by converting it to
  `{query, should_trigger}` JSON and detecting tool-use events early in the host stream, rather
  than waiting for full completion. **Why:** repeated trigger checks are stochastic and expensive;
  early event detection makes parallel trigger-rate measurement tractable. **Provenance:** external
  research, `anthropics/skills` `skill-creator/scripts/run_eval.py`. **Landed in:**
  `references/trigger-eval.md` (How to use this).
- **Heuristic:** adopt a formal `evals/evals.json` fixture (prompt + expected_output + assertions,
  graded with/without the skill) as a skill's own output-quality self-test, distinct from a
  trigger-classification fixture (`scripts/check-evals.sh` checks the fixture's shape only; grading
  stays manual/LLM-judged). **Why:** a skill's prompt-engineering (its `SKILL.md`/references
  text) has no natural unit test; a structured eval schema gives it one, closing exactly the
  self-test gap a trigger-only fixture leaves open. **Provenance:** external research,
  `agentskills/agentskills`'s `evaluating-skills.mdx` (the specification wgm already conforms to for
  `SKILL.md` structure). **Landed in:** `references/evals.md` · `evals/evals.json` ·
  `scripts/check-evals.sh`.
- **Heuristic:** when the build runtime is newer/odder than a key tool's tested baseline, make T1
  prove the whole toolchain end-to-end (a hello-world that really builds/runs) and pre-commit a
  runtime-pin fallback before feature work. **Why:** mid-build tooling stalls invalidate work that
  assumed a green build; a five-minute hello-world surfaces the incompatibility while it's still
  trivial to route around. **Provenance:** wgm dogfood, `[learn]` issue #34 (elm-pages/lamdera on a
  newer-than-LTS Node). **Landed in:** `references/ralph-loop.md` (Backpressure in depth) ·
  `SKILL.md` Plan-exit gate.
- **Heuristic:** before checking whether a runtime/toolchain is *newer* than a tool's tested
  baseline, first do a trivial presence check (`which <tool>` / a version probe) that it is
  installed **at all** — a distinct, cheaper, more basic failure mode than a version mismatch.
  **Why:** a real dogfood run's very first validation attempt failed immediately because the
  sandbox had no `java`/`JAVA_HOME` installed, forcing a mid-task detour to fetch a repo-local JDK
  before any real work could start — a one-line presence check at T1 is strictly cheaper than
  proving full end-to-end runtime compatibility and catches this more basic failure mode first.
  **Provenance:** wgm dogfood, `[learn]` issue #57 (`SchwartzKamel/floci-az`,
  Java/Quarkus). **Landed in:** `references/ralph-loop.md` (Backpressure in depth).
- **Heuristic:** for native apps, games, GUIs, or engines, the *first* task is building the headless
  harness (output capture, state probes, crash soaks). **Why:** there is no natural unit test to
  lean on, so a deterministic signal must be manufactured before any feature work.
  **Provenance:** hard-to-test-domains work. **Landed in:** `references/hard-to-test-domains.md`.
- **Heuristic:** a high satisfaction score never overrides a failing deterministic check.
  **Why:** an LLM judge can be charmed; a failing test cannot. **Provenance:** holdout-scoring +
  octopusgarden. **Landed in:** `SKILL.md` Backpressure · `wgm-validator`.

## Token economy
- **Heuristic:** single-token compaction is model-specific — verify keys against the target
  tokenizer; short ASCII keys are the portable default. **Why:** a CJK glyph is 1 token in OpenAI
  o200k but 2–3 in cl100k, so "kanji == 1 token" is false in general.
  **Provenance:** tiktoken measurement during the token-economy pass. **Landed in:**
  `references/artifacts.md` (Token economy) · `assets/state.template.toon`.
- **Heuristic:** declare keys once (tabular/TOON) for any state reloaded every iteration.
  **Why:** repeating verbose keys per row taxes every loop's context budget.
  **Provenance:** token-economy pass. **Landed in:** `references/artifacts.md` (Token economy).

## Review
- **Heuristic:** treat a zero-findings PASS as a claim that must be justified in one sentence, not a
  silent default. **Why:** "PASS, nothing to say" hides whether the reviewer actually examined the
  artifact; requiring a clean-pass rationale keeps review high-signal without importing a
  false-positive culture. **Provenance:** external research, `BMAD-METHOD`
  `docs/explanation/adversarial-review.md` (adapted, not its "must find issues" rule). **Landed
  in:** `references/subagents.md` · `wgm-spec-reviewer` + `wgm-quality-reviewer`.
- **Heuristic:** route credible issues that clearly pre-date the current diff into a durable
  deferred-work ledger instead of blocking the present task. **Why:** pre-existing defects are real,
  but making every current change pay their cost confuses review signal and stalls unrelated
  progress; a dated ledger preserves them without misattributing them to the diff. **Provenance:**
  external research, `BMAD-METHOD` code-review triage/presentation steps (`step-03-triage.md`,
  `step-04-present.md`). **Landed in:** `references/subagents.md` (`.wgm/deferred-work.md` lane).
- **Heuristic:** run two independent review passes — spec-compliance, then code-quality.
  **Why:** a single reviewer conflates "right thing" with "built correctly" and blesses its own
  assumptions. **Provenance:** Superpowers two-stage review. **Landed in:** `references/subagents.md`
  · `wgm-spec-reviewer` + `wgm-quality-reviewer`.

## Comparative & hard-to-test scoring
- **Heuristic:** before accepting an automated edit to a skill/protocol document, gate it on a
  held-out or baseline comparison — never accept on the generator's own say-so.
  **Why:** a skill document that edits itself without a comparison against a prior-known-good
  revision can drift or regress silently; a simple non-regression check (candidate pass_rate ≥
  baseline pass_rate on the same held-out cases — a distinct, boolean-per-assertion mechanism from
  this file's own 0-100 continuous satisfaction score, `references/scoring.md`) catches that before
  the edit ships, without needing a full training loop. **Provenance:** external research,
  `microsoft/SkillOpt`'s validation-gate design (rollout → reflect → bounded edit → accept only if
  it beats a held-out score). **Landed in:** `references/evals.md`, `scripts/grade-evals.sh`
  (`docs/plans/2026-07-08_SKILLOPT_ADOPTION.md`).
- **Heuristic:** record a threshold-clearing scenario that later drops below threshold as a named
  regression, not just a lower score.
  **Why:** overall satisfaction can stay flat or even rise while one once-working scenario breaks;
  explicit regression tracking catches the slip early and demands diagnosis instead of averaging it
  away. **Provenance:** external research, `foundatron/octopusgarden`'s
  `internal/attractor/regression.go`. **Landed in:** `references/scoring.md`.
- **Heuristic:** ask the judge for structured diagnostic categories alongside the numeric score.
  **Why:** recurring low scores are easier to fix when the failure class (`auth`, `http-status`,
  etc.) is tracked across iterations instead of buried in free-form prose. **Provenance:** external
  research, `foundatron/octopusgarden`'s `internal/llm/prompt.go`. **Landed in:**
  `references/scoring.md`.
- **Heuristic:** when "better X" is the goal but X is unobservable in CI (live SEO/Google rank,
  "beats the incumbent"), pin it to a deterministic proxy and score it head-to-head against a served
  incumbent, not just an absolute threshold. **Why:** an absolute pass is blind to "worse than the
  thing you're replacing"; a live baseline also blocks gaming and surfaces the incumbent's own
  failures as the proof. **Provenance:** wgm dogfood, `[learn]` issues #32, #33.
  **Landed in:** `references/hard-to-test-domains.md` (Web SEO / ranking) ·
  `references/scoring.md` (Relative-to-incumbent scoring).
- **Heuristic:** treat ad/analytics/third-party scripts as a Core Web Vitals constraint gated in the
  same audit as the content, never bolted on. **Why:** monetization/telemetry is the classic way a
  content site destroys the performance it depends on (layout shift, main-thread blocking, LCP
  regressions) — reserved-space wrappers + deferred scripts + a shared CLS/LCP gate turn "the ad
  shows up" into "the ad shows up *and* CWV stays in budget." **Provenance:** wgm dogfood, `[learn]`
  issue #35. **Landed in:** `references/hard-to-test-domains.md` (Web SEO / ranking).

## Swarm & parallelism
- **Heuristic:** document each subagent's tool budget as a proposed machine-readable `groups:`
  schema, not prose alone — even before any host actually enforces it.
  **Why:** prompt text says what a role *should* do; structured `read` / `edit` / `command` /
  `mcp` groups make the contract portable to hosts that can actually enforce it and clarify which
  roles are read-only. **Provenance:** external research, `RooCodeInc/Roo-Code`'s
  `packages/types/src/tool.ts`. **Landed in:** `references/subagents.md` (illustrative example
  mappings only, cross-checked against each archetype's real tool list — no `.github/agents/*.agent.md`
  file has a `groups:` frontmatter field yet, and no host enforces one; this entry describes a
  documented proposal, not yet an applied rule).
- **Heuristic:** partition a worktree swarm's file ownership, not just its features; route shared
  additions into each stream's own module and treat any unavoidable shared declaration file as a
  known, append-only merge point. **Why:** worktree isolation only prevents *live* contention — two
  peer streams touching the same shared module still surfaces as a merge conflict at the most
  expensive moment, integration time. **Provenance:** wgm dogfood, `[learn]` issue #29 (Rust FFI
  crate, two streams sharing one declaration file). **Landed in:**
  `docs/operator/running-the-loop.md` (Swarm — Planning a swarm well).
- **Heuristic:** bless a feasibility-spike as a first-class parallel swarm stream whose deliverable
  is a go/no-go verdict, and treat a well-supported NO-GO as a PASS, not a stall. **Why:** a spike
  that reshapes the backlog (drops a now-duplicate task, promotes a patchable sub-win, records a
  settled question) is one of the highest-value outcomes a run can produce — misreading it as a
  failure would suppress exactly the signal that saves the most wasted work. **Provenance:** wgm
  dogfood, `[learn]` issue #30. **Landed in:** `docs/operator/running-the-loop.md` (Swarm — Planning
  a swarm well) · `references/stall-recovery.md` (Detecting a stall).

## Local sandboxing (devcontainers)
- **Heuristic:** when sandboxing the loop itself in a local devcontainer, reference ONE shared,
  prebuilt image (`"image"`, never a per-project `"build"`), bind-mount the project instead of
  copying it in, make the build idempotent (skip an unnecessary rebuild), and label every created
  resource so cleanup can be scoped to exactly what the tool created.
  **Why:** a per-project `"build"` devcontainer.json costs a new multi-GB image per project — the
  literal disk-bloat failure mode a "manageable" local sandbox exists to avoid; an unlabeled prune
  either does nothing useful or risks touching a container/image it didn't create. **Provenance:**
  external research, `containers.dev`'s prebuilt-image reuse
  guidance + standard Docker/Podman disk-hygiene practice (`system df`, scoped `prune`).
  **Landed in:** `scripts/devcontainer.sh` · `references/devcontainers.md` ·
  `docs/operator/devcontainers.md`.
- **Heuristic:** when a sandboxed container bind-mounts a host directory, run it as the calling
  host user's UID:GID, and add Podman's `--userns=keep-id` specifically for Podman (Docker needs no
  such flag). **Why:** the image's own baked UID (even a numerically identical `1000`) is not the
  same UID as the host caller once rootless Podman's default user namespace remaps it — a
  bind-mounted directory that isn't world-readable (a `mktemp -d`-style `0700` dir is the common
  case) is silently unreadable/unwritable inside the sandbox even though the mount itself
  "succeeds," and this is easy to miss if the smoke test happens to use a world-readable directory.
  **Provenance:** wgm dogfood — discovered live while building and testing this session's
  `--devcontainer` sandbox (`scripts/test-devcontainer.sh`'s real, non-dry-run cases caught it: a
  bind-mounted file was readable in an ad hoc `/tmp` test dir but not through the harness's
  `mktemp -d` temp dir, isolating the permission mismatch). **Landed in:** `scripts/devcontainer.sh`
  (`cmd_run`'s `--user`/`--userns=keep-id`) · `references/devcontainers.md`.
- **Heuristic:** a deterministic gate is not proven by writing it — prove it goes **RED** on the
  class it claims to catch, or it is indistinguishable from no gate. **Why:** the mojibake sweep
  added for `[learn]` #67 shipped matching nothing at all: PCRE reads `\xNN` as a *character* in a
  UTF-8 locale and as a *byte* only under `LC_ALL=C`, so it reported GREEN forever over corrupt
  input. A one-line probe caught it before merge. The same class covers allow-lists that never
  reject and doc checks that never fire. **Provenance:** wgm dogfood — found while implementing
  `[learn]` issues #67 and #86 in the same pass. **Landed in:** `scripts/test-check-docs.sh` ·
  `scripts/test-check-evals.sh` · `scripts/check-docs.sh` (check 9's `LC_ALL=C` pin).
- **Heuristic:** allow-list a JSON schema by reading its **key set structurally** (`jq keys`), never
  by scanning for identifier-shaped names. **Why:** an identifier regex silently skips exactly the
  keys drift produces — `expected_output2`, `x-note` — so a renamed or typo'd field passes the gate
  it was written to stop. Required-field checks alone are also insufficient: they prove what is
  present, never that nothing unexpected is. **Provenance:** `[learn]` issue #86.
  **Landed in:** `scripts/check-evals.sh` · `scripts/test-check-evals.sh`.
- **Heuristic:** the hive courier must **fail closed** — forward exactly one lesson, then re-scan
  the scrubbed candidate and refuse publication when any host identifier or a size ceiling breach
  survives. **Why:** consent authorizes a sanitized *report*, never the source ledger; anonymizing
  and filing the whole memories file leaks host facts even when every individual scrub rule fires
  correctly, and `consent: true` must not be a bypass. **Provenance:** `[learn]` issue #79.
  **Landed in:** `scripts/harvest-hive.sh` (`select_one_lesson`, `residual_scan`, `--max-bytes`) ·
  `scripts/test-harvest-hive.sh` · `references/self-improvement.md`.
- **Heuristic:** keep three build clocks distinct — **wall**, **allocated lane time** (capacity
  upper bound), and **active agent time** (measured lower bound, summed per *turn*) — and never call
  parked-lane lifetime "agent-hours." **Why:** a lane alive between turns still burns lifetime, so
  summing lifetimes and dividing by wall time reports a flattering number that is not work done;
  static per-lane utilization also understates elastically-expanded swarms badly. Report missing
  telemetry as counts and a stated lower bound rather than estimating it, and label every ratio an
  operational heuristic — not billing data, not a causal speedup claim. **Provenance:** `[learn]`
  issues #70, #72, #74, #84, #85. **Landed in:** `references/telemetry.md` · `scripts/swarm.sh`
  (the `== swarm telemetry ==` block) · `scripts/loop.sh` (per-turn ledger) · `SKILL.md` Phase 4.
- **Heuristic:** re-pin a swarm lane's absolute worktree and branch in **every** state-mutating
  instruction, and guard before mutating. **Why:** retained context is not a guarantee — in a
  32-lane run four lanes executed git from the parent checkout on a later turn and one advanced
  local `main`. Recovery must preserve reachability first, never discard commits.
  **Provenance:** `[learn]` issue #73. **Landed in:** `scripts/swarm.sh` (lane pin + guard) ·
  `scripts/test-swarm.sh` · `references/subagents.md`.
- **Heuristic:** treat a lane's `done` as an **unverified assertion** and check the named file,
  symbol, and command before integrating. **Why:** in one Full-track run four of five tasks marked
  done carried a false claim — a test file that existed nowhere, a layout claim contradicted by the
  source it named. Every claim read plausibly; only a symbol-level grep exposed them.
  **Provenance:** `[learn]` issue #75. **Landed in:** `SKILL.md` (Loop step 4) ·
  `references/subagents.md` · `.github/agents/wgm-spec-reviewer.agent.md`.
- **Heuristic:** commit-message governance needs its own gate, and **merge commits are governed
  commits**. **Why:** product gates cannot see trailers, so a run reaches a green exact-tree gate
  while a generated merge commit carries none of the mandated trailers every head commit has. Fix a
  published offender with a replacement two-parent merge proving `old^{tree} == replacement^{tree}`
  — never by rewriting shared history. **Provenance:** `[learn]` issue #82.
  **Landed in:** `scripts/check-trailers.sh` · `scripts/test-check-trailers.sh` · `SKILL.md` Phase 4.
- **Heuristic:** check same-iteration whether a diff's **new public surface** was documented, rather
  than leaving it to the batched Ship/Handoff audit. **Why:** the Record step commits on a green
  validation command, so doc drift accumulates across several merged PRs before an audit finds it,
  and the fix cost scales with how many piled up. Keep it advisory so it does not fire on ordinary
  diffs — a gate that fires on everything gets ignored. **Provenance:** `[learn]` issue #78.
  **Landed in:** `scripts/check-doc-sync.sh` · `scripts/test-check-doc-sync.sh` · `SKILL.md` (Record).
- **Heuristic:** an eval/grading harness that invokes a **tool-enabled** agent must run it in a
  sandbox directory outside the repo under test — capturing stdout is not isolation. **Why:** the
  working directory, not the output stream, decides what an agent can touch. `grade-evals.sh`
  carried a comment claiming it "CAPTURES the response instead of letting it run for effect" while
  `cd`-ing to the repo root, so a greenfield-build grading prompt was carried out for real: a whole
  project created, a CI job matrix added, a consent file written, and nine commits landed on `main`.
  Grading prompts describe builds, and a capable agent will build them. **Provenance:** wgm dogfood
  — hit live while measuring whether a session had improved `SKILL.md`. **Landed in:**
  `scripts/grade-evals.sh` (`run_agent`'s sandbox) · `scripts/test-grade-evals.sh` (canary probe).
- **Heuristic:** a probe that is supposed to make a gate fail must be **verified to have applied**
  before its result is believed. **Why:** three probes in one session were silently inert — a `sed`
  whose `||` broke the `s|…|…|` delimiter and edited nothing, and a canary test naming an eval id
  absent from the harness fixture, so the run aborted on "unknown eval id" and the assertion passed
  without ever exercising the code. Each looked like proof the gate worked. Assert the edit changed
  the file, or the probe tests nothing but your own optimism. **Provenance:** wgm dogfood.
  **Landed in:** `scripts/test-grade-evals.sh` · this ledger.
