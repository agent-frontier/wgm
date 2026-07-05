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
memory it graduates from.

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
- **Heuristic:** verify the project's working tree is clean before the first loop iteration.
  **Why:** prompt-only skills lack shadow-checkpoint infrastructure; a clean git baseline keeps the
  repo's own history as a reliable rollback path when an iteration destabilizes the tree.
  **Provenance:** external research, `RooCodeInc/Roo-Code`'s
  `src/services/checkpoints/ShadowCheckpointService.ts`. **Landed in:** `SKILL.md` (Phase 2.5 —
  Preflight).
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
- **Heuristic:** declare each subagent's tool budget in machine-readable groups, not prose alone.
  **Why:** prompt text says what a role *should* do; structured `read` / `edit` / `command` /
  `mcp` groups make the contract portable to hosts that can actually enforce it and clarify which
  roles are read-only. **Provenance:** external research, `RooCodeInc/Roo-Code`'s
  `packages/types/src/mode.ts`. **Landed in:** `references/subagents.md`.
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
