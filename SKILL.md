---
name: wgm
description: Autonomous build skill that turns a rough request into working software through a relentless requirements interview (grill), a persistent plan, and a Ralph-style build loop (analyze → implement → validate → review → record). Use when the user runs /wgm, or asks to build, implement, prototype, or ship a feature or app from rough intent; when a task is ambiguous and needs requirements interrogation before coding; or for multi-step feature work that benefits from a planned, test-validated iterative loop. Supports phase modes grill, analyze, plan, build, and review, with an optional "only" qualifier to run a single phase (e.g. "/wgm analyze only"). Not for trivial one-file edits, pure debugging, or research-only questions.
license: MIT
compatibility: Optional Podman or Docker (OCI) for containerized scenario validation; none otherwise.
metadata:
  author: Agent Frontier Store
  version: "0.3"
---

# wgm

Turn a rough request into working software. `wgm` runs a disciplined lifecycle:

`Triage → Grill → Plan → Preflight → Loop(Analyze → Implement → Validate → Review → Record) → Ship/Handoff`

It marries three ideas: **grill-me** (interview the human relentlessly until alignment), the
**Ralph loop** (one task per iteration, persistent plan as shared state, steered by deterministic
backpressure), and **holdout-scenario judging** (after octopusgarden): an LLM judge scores
satisfaction against scenarios the build never sees, so a high score can't be gamed. This file is
the protocol. Follow it like a state machine — do not skip gates.

## Invocation & modes

Invoked as `/wgm [<mode>] [only] [<request>]` — or activated whenever the user asks to build /
implement / prototype something from rough intent.

**Parse the input first:**

1. Look at the first word. It is a **mode** only if it is exactly one of
   `grill | analyze | plan | build | loop | review` AND it is followed by end-of-input, the word
   `only`, or a `:` separator. (`loop` is an alias of `build`.)
2. Otherwise the entire input is the `<request>` and you run the **full lifecycle**. This is the
   disambiguation rule: `/wgm build the auth module` is a request — not `build` mode.
3. **Single-phase modes** — `grill`, `analyze`, `plan`, `review` — run that one phase, then
   **hard-stop at its exit gate**. Report and wait; do not roll forward into the next phase.
4. **`build`** runs the build loop (it loads an existing `IMPLEMENTATION_PLAN.md`). `build only`
   runs exactly one iteration, then stops.
5. The optional trailing `only` is accepted on any mode for emphasis and always hard-stops after
   the named phase (redundant for the single-phase modes; meaningful for `build only`).
6. A `:` lets a mode carry a request/scope, e.g. `/wgm plan: add OAuth login`.
7. No input → operate on the current conversation context; begin at Triage. If the project has open
   GitHub Issues and no request is otherwise evident, they are a candidate source for `<request>` —
   never a silent override of one already given (`references/issue-intake.md`).

| Invocation | Behavior |
|---|---|
| `/wgm <request>` | Full lifecycle on the request |
| `/wgm grill only` | Just the alignment interview; stop at Grill-exit |
| `/wgm analyze only` | Explore code + requirements — or, with a plan present, run the cross-artifact consistency check; report findings; do not implement |
| `/wgm plan: <request>` | Write specs + `IMPLEMENTATION_PLAN.md`; stop at Plan-exit |
| `/wgm build` | Run the build loop from the existing plan (`build only` = one iteration) |
| `/wgm review` | Review current diff against acceptance criteria; no new code; ends with a recorded ruggedness verdict |

## Use this when
- Building or implementing a feature/app/prototype from rough or ambiguous intent.
- Multi-step work that benefits from a plan + iterative, test-validated execution.
- The user explicitly runs `/wgm`.

## Do NOT use this when
- Trivial one-file edits or formatting-only changes — just do them.
- Pure debugging of a specific bug — a dedicated diagnose discipline fits better.
- Research-only / "explain this" questions with no build intent.
- The task already has complete, unambiguous step-by-step instructions.

## Related Skills & Plugins

**[teach-me](companions/teach-me/SKILL.md) / [quiz-me](companions/quiz-me/SKILL.md)** — two of the
three companion skills that ship with wgm and install beside it. wgm can build software faster than
its operator can understand it, which leaves a human owning code they cannot explain. `teach-me`
makes a repo legible (a cited map, a tour in execution order, one validated first change); `quiz-me`
proves the learning landed (one question at a time, graded against the code, scored by tier). At
**Ship/Handoff**, when a build was largely autonomous or the operator is new to the codebase, offer
`/teach-me` — a handoff summary the operator cannot act on is not a handoff.

**[rugged](companions/rugged/SKILL.md)** — the third companion skill, a read-only reviewer that
stress-tests a request, spec, plan, diff, or system against its *actual* operators and environment,
ending in one unhedged verdict (RUGGED, FRAGILE, or UNKNOWN). **wgm's ruggedness gate uses `/rugged`
whenever it is discoverable and embeds the same rubric as an inline fallback when it is not** — see
"The ruggedness gate" below, which runs at Plan-exit and at the Loop's Review step on every track. An
operator may also invoke it directly, outside any gate, for a second opinion on whether a design
holds up or is over-built for conditions that don't exist (`companions/rugged/SKILL.md`).

**sofaking** — Stack Overflow for Agents knowledge integration. When installed, a compatible host
adapter may invoke sofaking at:
- **Plan phase** — search prior art and validate architecture choices before implementing.
- **Validate phase** — verify outcomes and contribute durable learnings back to SOFA.

Sofaking is optional; the portable `loop.sh` runner does not dispatch plugin hooks directly. A host
adapter must own invocation, timeout, enablement, and failure reporting; wgm continues normally if
the adapter or plugin is unavailable.

**[SkillOpt-Sleep](https://github.com/microsoft/SkillOpt)** — an external, optional nightly
self-evolution companion for coding-agent skill documents (harvest sessions → mine recurring tasks →
replay → consolidate behind a held-out validation gate → stage a proposal for human adopt). It is
not a wgm dependency and nothing in this protocol requires it; a user who wants it can register its
Copilot MCP-server plugin independently. Its harvest step reads Claude Code/Codex session transcripts
only (no Copilot CLI transcript source yet), so it is most directly usable against wgm's Claude Code
install target. wgm's own take on the same discipline — a dependency-free, opt-in grading/gate
script for its own `evals/evals.json` — is `scripts/grade-evals.sh`
(`references/evals.md`); see `docs/plans/2026-07-08_SKILLOPT_ADOPTION.md` for the full evaluation.

## Gates (enforcement)
The lifecycle is a state machine. At each phase end, **print a `Gate check:` block listing every gate item as PASS or FAIL.** If any item is FAIL, do **not** advance — ask one question, fix the artifact, or stop with a recorded blocker. Gates are not advisory.

## The ruggedness gate (every track, never skipped)
Deterministic checks prove a change *works*; they cannot prove it **holds up for the operators and
environment that will actually run it**. wgm settles that question twice — at **Plan-exit** and at
the Loop's **Review** step — and it is a protocol requirement on every track, not a recommendation.
A missing or hedged ruggedness verdict is a gate FAIL, exactly like a missing validation command.

**How it runs.** Prefer the companion: `/rugged plan <scope>` at Plan-exit, `/rugged review <scope>`
(or `/rugged stress <scope>` when only the field evidence is in question) at Review. **If the
companion is not discoverable** — not installed, or the host cannot invoke it — run the embedded
rubric below inline yourself and record the fallback explicitly ("rugged companion unavailable —
embedded rubric run inline"). An absent `/rugged` is a **recorded missing capability plus a
fallback, never an automatic pass**.

**Embedded rubric — the fallback, and the Quick track's normal form.** Five steps, one line each:
1. **Actual operator & environment** — who really runs and maintains this, at what load, with which
   dependency failure modes, at 3am during an incident. If it is unstated and unrecoverable, say so
   and record the gap; never invent a plausible operator.
2. **Bottleneck decomposition** — split the expected failure into *intrinsic design constraint* ·
   *user capacity* · *operational stress*, and name which bucket carries most of the risk.
3. **Simplify** — which moving part comes out, or is replaced by one that degrades visibly instead
   of silently, and the trade-off accepted for it.
4. **Exact check** — the runnable command/probe, its origin/environment, the expected observation,
   and the failure/recovery criterion. "It should work" is not a check.
5. **Exactly one verdict** — RUGGED, FRAGILE, or UNKNOWN. Two verdicts, a hedge, or no verdict is
   itself a FAIL.

**Verdict semantics** — identical whether the companion or the inline rubric produced them:

| Verdict | Gate | Required follow-up |
|---|---|---|
| **RUGGED** | PASS | none — record the verdict and continue |
| **FRAGILE** | **BLOCKS** | record a **remediation task** in `IMPLEMENTATION_PLAN.md` (the one highest-leverage next action), fix it, then re-run the gate |
| **UNKNOWN** | **BLOCKS** | record a **validation-signal task** that creates the missing deterministic field/stress evidence. UNKNOWN is never "probably fine" |

When Plan-exit is blocked, revise the plan with the named remediation or validation-signal task and
re-run `/rugged plan`; the evidence itself is owed at that task's Review verdict, not before the
Loop can start.

**Plan-exit judges the plan, not an implementation that doesn't exist yet.** Use `/rugged plan`'s
plan-readiness semantics: every load-bearing claim maps to an *exact runnable* field/stress/recovery
check (command · origin/environment · expected observation · failure + recovery criterion). Do
**not** demand real field evidence from unwritten code — that is Review/stress's job. A demonstrated
idealized operator or environment is **FRAGILE**; without one, a missing exact check design is
**UNKNOWN**; only an assumption-free plan with an exact check design is **RUGGED**.

**Track shape.** **Standard/Full** record a `/rugged plan` result at Plan-exit and a `/rugged review`
result at Review. **Quick** runs the same five-step rubric **inline** in its short plan and its
review — it may skip *invoking the companion*; it may never skip the *invariant*.

**Record it** where a fresh context will find it: the verdict, its date, the scope, whether the
companion or the inline fallback produced it, and any task it spawned all go into
`IMPLEMENTATION_PLAN.md` (plus `.wgm/rugged/` for both companion and inline fallback runs) —
`references/artifacts.md`.
When a blocked gate is rerun, replace the prior verdict for that scope with the new current verdict;
retain superseded verdicts only as dated history, never as a second current verdict.

## Phase 0 — Triage (always first)
1. Parse the mode; confirm this skill applies (else say so and stop).
2. **Check consent — before anything else.** Look for `.github/wgm-hive.yml`
   (`assets/wgm-hive.template.yml`). If it doesn't exist yet, this absence is what makes it "a new
   project" for consent purposes: ask, as literally the first question of the entire run (ahead of
   plugin discovery, ahead of Grill's own first question), whether this project consents to wgm
   anonymizing and automatically reporting durable lessons upstream to `agent-frontier/wgm` — the
   Hive Growth Loop (the funnel that harvests, anonymizes, and reports durable lessons upstream to
   `agent-frontier/wgm`). Write the file with the answer either way, so it is never asked again unless a
   human deletes it. If the file already exists, skip this step entirely; its content governs the
   run, not a fresh question (`references/self-improvement.md`).
3. **Discover plugins.** If `~/.copilot/skills/*/plugin.toml` exists, a host adapter may load plugin
   metadata (name, hooks, dependencies) before planning. The portable runner treats this metadata as
   informational and does not invoke plugin hooks itself; missing plugins or dependencies are
   warnings, not blockers.
4. **Track (scale-adaptive).** Size the ceremony to the work's scale and risk, **state the chosen track** ("Track: Quick/Standard/Full — …"), and **default to Standard when unsure**. The deterministic backpressure gate is never skipped — only the surrounding ceremony flexes.

   | Track | When | Ceremony |
   |---|---|---|
   | **Quick** | Bug fix or small 1–5 file change with an obvious check, and completable from a single short prompt in one agent turn once grilling clears (no unsettled research/decisions) | Grill only what's unclear · short plan · inline deterministic validation · **inline** ruggedness rubric (the invariant is never skipped) · **skip** holdout scenarios + Preflight + the docs-audit swarm (`scripts/check-docs.sh` structural check only) |
   | **Standard** (default) | A normal feature | The full lifecycle as written below — unchanged, including the `/rugged plan` + `/rugged review` ruggedness gate; the docs-audit swarm runs once, at Ship/Handoff |
   | **Full** | Large / multi-slice / greenfield or high-risk | Standard **plus** holdout scenarios · stratified scoring · containerized validation · a Plan-exit **baseline** docs-audit pass |
5. Decide loop mode — **prefer Ralph-full whenever it is practically invocable**:
   - **Ralph-full (preferred default)**: genuinely fresh context per iteration is the purer, stronger
     form of the technique — reach for it whenever a non-interactive agent invocation is available
     (an operator-set `WGM_AGENT`, or a known CLI — `copilot`, `claude`, `codex`, `aider` — on `PATH`
     with a print/non-interactive mode). Run the bundled loop runner (`scripts/loop.sh` **inside this
     skill's own directory**, the base dir this `SKILL.md` loads from) **from the target project's
     root**, or restart with a clean context between iterations. For a locally sandboxed, disk-
     conscious run, add `--devcontainer` (`references/devcontainers.md`). For independent slices, fan
     out in parallel with `scripts/swarm.sh` — one git worktree + branch per stream, merged back
     branch by branch; every swarm run also standingly consolidates each stream's `.wgm/memories.md`
     lessons back into the main worktree (`references/self-improvement.md`, "Swarm harvest").
   - **Ralph-lite (fallback)**: run the loop in-session when no headless invocation is available (a
     purely interactive host) or the track is **Quick** (a whole subprocess loop is overkill for one
     short prompt). In-session work must compensate for accumulating context with strict persistence
     to `IMPLEMENTATION_PLAN.md`.
6. Set up the working directory (see **Artifact safety**). Decide root vs `.wgm/` **before**
   writing anything. If a `specs/CONSTITUTION.md` (or `.wgm/specs/CONSTITUTION.md`) already exists,
   load it — its principles govern every later decision.
7. **Optional — gene transfusion:** if a high-quality exemplar codebase exists, extract its patterns
   to seed the build in the house style (`references/gene-transfusion.md`).
8. **Optional — orient in an unfamiliar codebase.** Analyze reads only what one task needs, so wgm
   never forms a whole-repo model on its own. In a large brownfield repo, read
   `.wgm/learning/MAP.md` if it is present. If it is absent and the codebase is large and unfamiliar,
   **recommend `/teach-me` to the operator — do not dispatch it and do not survey the repo yourself.**
   Orientation is worth one deliberate pass, never a silent tax on every iteration
   (`companions/teach-me/SKILL.md`).

## Phase 1 — Grill (align)
Read `references/grilling.md`. Core rules:
- Ask **one question at a time**. For every question, **state your recommended answer**.
- **Explore the codebase to self-answer before asking.** A question you can resolve by reading code
  is not a question for the user.
- **Ask vs assume:** only ask when the answer would materially change architecture, UX, data model,
  security, deployment, or acceptance criteria. Otherwise record a recommended assumption in the
  spec and proceed.
- **Cap interrogation:** after ~5 consecutive questions, summarize current assumptions and offer
  "proceed with defaults." Never let grilling become interrogation theater.
- **Keep a domain glossary.** When alignment surfaces a term that is ambiguous, overloaded, or easy
  to confuse, record it in `specs/CONTEXT.md` with its one canonical name — the project's ubiquitous
  language, kept separate from the constitution (principles) and specs (behavior). Skip it for
  trivial builds (`assets/context.template.md`).

**Grill-exit gate** (all must hold before planning):
- [ ] Goal is known.
- [ ] User-visible success criteria are known.
- [ ] Major constraints are known.
- [ ] Acceptance criteria are consistent, non-redundant, and have explicit defaults/boundaries — no
      vague thresholds, no undefined referenced concepts (full detail: `references/grilling.md`).
- [ ] Each unknown is answered, explored from code, or recorded as an explicit assumption.
- [ ] User said "go" OR remaining ambiguity is immaterial.

## Phase 2 — Plan
Read `references/artifacts.md`. Produce, using `assets/` templates:
- `specs/CONSTITUTION.md` — project-wide principles (quality, testing, security, non-negotiables),
  written once and referenced by every spec and task. Create it from
  `assets/constitution.template.md` when absent; never silently contradict it.
- `specs/CONTEXT.md` *(optional)* — the domain glossary (ubiquitous language) started in Grill;
  refine it here so every spec, task, and commit uses the canonical term. Vocabulary only, not
  behavior (`assets/context.template.md`). Omit for trivial builds with no special vocabulary.
- `specs/*` — one per coherent slice. Each spec must include a **magic moment**, a **demo path**,
  and the **smallest end-to-end slice** that proves value (see `assets/spec.template.md`).
- `scenarios/*` — holdout acceptance journeys (YAML), tiered 1–3, that verify the spec from the
  user's seat. The build must **not** read these; they're judged in Validate/Review
  (`assets/scenario.template.yaml`, `references/scenarios.md`).
- `IMPLEMENTATION_PLAN.md` — prioritized task list; this is the **shared state** across iterations.
- `AGENTS.md` — lean operational "how to build & validate" guide (only if absent; never clobber).

**Consistency check (analyze).** Before Preflight, cross-check the artifacts against each other:
every spec ↔ `IMPLEMENTATION_PLAN.md` ↔ scenarios ↔ `specs/CONSTITUTION.md`. Flag contradictions,
ambiguous requirements, and coverage gaps — a requirement with no task, a task with no spec, a demo
path with no scenario — and fix or record each before scoring readiness. This is what `/wgm analyze`
runs once a plan exists (`references/artifacts.md`).

**Plan-exit gate:**
- [ ] `IMPLEMENTATION_PLAN.md` exists (see the Quick-track single-task exception below).
- [ ] Every task has: objective · files/areas · **validation command** · acceptance criteria · status.
- [ ] The first task is small enough for one iteration.
- [ ] If no validation signal exists yet, the **first task is "create a validation signal"** — this
      includes proving an unusually new/old runtime or toolchain end-to-end (not just a test
      harness) when it's riskier than a key tool's tested baseline (`references/ralph-loop.md`).
- [ ] The plan includes a final **demo-validation task** that runs the spec's smallest end-to-end
      demo path; it must pass before Ship/Handoff. **Exception:** when a **Quick**-track build is
      genuinely one task (one fix, one validation command, no multi-step demo path), that task's own
      validation command *is* the demo-validation task — don't require a separate one, and a single
      short paragraph may stand in for a formal plan/spec file (`references/heuristics.md`, `[learn]`
      issue #56).
- [ ] **Standard/Full** require at least one **tier-1 holdout scenario** covering the spec's demo
      path; **Quick** may substitute an inline deterministic check (per the Triage track table).
- [ ] Every spec and task conforms to `specs/CONSTITUTION.md`, or records an intentional deviation.
- [ ] **Consistency check passed:** specs, plan, scenarios, and the constitution agree; no
      requirement lacks a task and no task lacks a spec.
- [ ] **No placeholders:** no task carries a `to-be-decided` / `implement-later` / `fill-in` marker;
      every task names exact files/areas and a runnable validation command.
- [ ] **Ruggedness gate (all tracks):** a `/rugged plan` result for this plan/specs exists — or, when
      the companion is not discoverable, the embedded rubric was run inline and that fallback is
      recorded — carrying **exactly one** verdict, and that verdict is **RUGGED**. **FRAGILE** →
      record the remediation task and stay FAIL; **UNKNOWN** → record the validation-signal task and
      stay FAIL. Judge *plan readiness* (an exact runnable field/stress/recovery check design), not
      field evidence from code that doesn't exist yet. **Quick** runs the same rubric inline rather
      than invoking the companion; it never skips it (see "The ruggedness gate").
- [ ] **Full track only:** a baseline docs-audit pass has run over the specs/`AGENTS.md`/README as
      they stand before any code is written (`references/docs-audit.md`).

## Phase 2.5 — Preflight (readiness gate)
Before looping, score the plan's readiness **0–100** (goal/JTBD clarity · observable success
criteria · scenario coverage of the demo path · each acceptance criterion mapped to backpressure ·
scope edges). See `references/scoring.md`. Also verify the project's working tree is clean (`git
status`, skip if not a git repo) before starting the Loop — an uncommitted clean baseline means `git
checkout -- .` can always undo one iteration's file changes.

**Preflight-exit gate:**
- [ ] **Standard/Full:** readiness ≥ **80** (recommended). Below it, return to Grill/Plan and fix the
      weakest dimension first — do not start building. **Quick may skip Preflight** (per the Triage
      track table) — its inline deterministic check is the backpressure.
- [ ] Working tree is clean (`git status`) before the first loop iteration (skip if not a git repo).

## Phase 3 — Loop (build)
Read `references/ralph-loop.md`. Run iterations until the plan's must-have tasks are `done` or a
stop condition fires. **One task per iteration.** Each iteration:

1. **Analyze** — read only what you need: `IMPLEMENTATION_PLAN.md`, the relevant spec, and the
   files for this one task. Pick the single most important `pending` task ("let Ralph Ralph").
   **Search before you build:** grep the codebase for an existing implementation first — don't
   assume a feature is missing; duplicating work is a top loop failure mode. **Widen the search past
   the local repo** to declared dependencies and mandated companion tools; if one already ships the
   capability, drop the task and wire it in instead (`references/ralph-loop.md`).
   **Recall first:** if `.wgm/memories.md` exists, read it (token-budgeted) so you don't repeat a
   past gotcha, stall, or dead end. If `specs/CONTEXT.md` exists, consult it so you use each domain
   term's canonical name — consistent naming, fewer tokens. If `.wgm/learning/MAP.md` exists (written
   by `/teach-me`), read it for entry points, structure, and invariants — the whole-repo model this
   deliberately narrow per-task read never builds. **Never generate that map mid-loop:** surveying
   the repo is `/teach-me`'s job, and doing it here trades the whole iteration's context budget for
   orientation (`companions/teach-me/SKILL.md`).
2. **Implement** — make the smallest change that completes that task. Prefer one working vertical
   slice over many half-built parts. **Holdout rule:** do not open scenario files while implementing.
   **Document why each test exists:** when you add a test, note in a comment what behavior it proves,
   so a fresh context never deletes it as an orphan. **Format only what you touched:** never run a
   project-wide auto-formatter mid-iteration — it buries the one-task diff in reformatting noise.
3. **Validate** — run the task's backpressure command (test/type/build/lint). If none exists,
   creating one **is** this iteration's task. No green signal → not done. **If the project has a
   deploy pipeline distinct from its per-PR CI, PR-level green is not proof of a real deploy** —
   check that separate workflow's own latest run when a task's acceptance criteria implies reaching
   a running deployment, and treat a red one as a standing blocker surfaced now, not deferred to
   Ship/Handoff (`references/ralph-loop.md`, Backpressure in depth). Then **judge satisfaction
   (0–100)** against this slice's holdout scenarios, converging by tier (stratified); run the app in
   a container if a scenario needs a live service (`references/scoring.md`,
   `references/validation-env.md`). Deterministic checks still gate "done."
4. **Review** — inspect the diff: scope creep? acceptance criteria met? does the validation
   actually prove the task (not just "didn't crash")? Run **two independent reviewer passes** —
   spec-compliance then code-quality — and ensure neither reviewer produced the artifact it is
   judging. A self-critique may cover process, cost, scope, and missing measurements, but it cannot
   satisfy an adversarial correctness-review gate; point the independent reviewer at load-bearing
   claims instead (`references/subagents.md`). **Preserve dissent:** record a reviewer's non-blocking
   reservation or a disagreement between the two as a follow-up, never a silent PASS.
   **Verify claims against the code, don't skim them:** a `done` in the plan — especially one written
   by a swarm lane — is an *unverified assertion*. For each acceptance bullet, check the artifact:
   does the named file exist, does the claimed symbol/constant/branch actually appear, does the named
   command run? Grep, don't trust plausible prose (`references/subagents.md`, "Worktree swarm").
   **Ruggedness verdict — required, every Review:** run `/rugged review` (or `/rugged stress`) over
   this diff when the companion is discoverable, otherwise run the embedded rubric inline and record
   the fallback. Neither reviewer may declare PASS without that verdict in hand: **FRAGILE** blocks
   `done` and spawns a remediation task, **UNKNOWN** blocks `done` and spawns a validation-signal
   task, and an absent `/rugged` is never a pass (see "The ruggedness gate").
5. **Record** — update `IMPLEMENTATION_PLAN.md`: mark status, note results, add/adjust follow-up
   tasks. Write enough that a **fresh agent could continue** from the file alone. Once that
   validation command exits 0, commit the iteration with a Conventional Commits message (`type:
   imperative description`, ≤72 chars; one iteration, one commit); if git is unavailable, the
   plan-file record is still required. **Doc-sync check:** if this iteration's diff adds **new
   public surface** — a CLI subcommand or flag, a public function, a new config file — and touches
   no documentation path, surface that in the plan ("new public surface added, no doc file touched
   — confirm intentional or add a follow-up task") rather than leaving it for the Ship/Handoff
   audit. Batched audits find this class several merged PRs late, and the fix cost scales with how
   many accumulated; `scripts/check-doc-sync.sh --warn` runs it deterministically (`[learn]` issue
   #78). **Remember:** append any durable lesson (a stall's cause +
   fix, a recurring gotcha, a dead end) to `.wgm/memories.md`,
   kept lean within a ~2000-token budget. **Agent-only files** (`.wgm/` memories, scores, any
   agent-only state) may min-max context with **single-token keys serialized as TOON + an embedded
   legend**; human-facing artifacts (the plan, specs) stay readable (`references/artifacts.md`).

**On a stall** — any *struggle signal*: satisfaction flat ~2 iterations, a task failing its check
repeatedly, the diff churning without moving a signal, the same tool/setup error repeating, or an
A→B→A→B oscillation across the last 4 iterations — stop generating and run **wonder → reflect**, and
consider **model escalation**, before recording a
blocker (`references/stall-recovery.md`). Capture what you learn in `.wgm/memories.md` so the next
iteration starts ahead of the stall.

**Context hygiene & rotation:** advance exactly one task per iteration. Watch the **context budget**:
as the window fills (past ~half, or a host-set token cap), don't push on a degrading context —
**summarize progress into the plan + `.wgm/memories.md`, then rotate to fresh context** (reload only
the lean plan, the relevant spec, memories, and `CONTEXT.md` — never the old transcript). Ralph-full
rotates every iteration by construction; Ralph-lite rotates on the threshold. If context is already
bloated, stop and hand off through the plan (Phase 4) rather than grinding (`references/ralph-loop.md`).

**Iteration-exit gate** (print PASS/FAIL for each): implementation done · the task's exact
validation command was run and **exited 0** · result recorded · diff reviewed for scope creep +
acceptance · **exactly one ruggedness verdict recorded for this diff, and it is RUGGED** · plan
updated · exactly one task advanced. A task may be marked `done` **only if its validation command
exited 0** and its ruggedness verdict is RUGGED; otherwise set it `blocked` (with a note) or leave
it `pending`, with the remediation (FRAGILE) or validation-signal (UNKNOWN) task recorded.

**Stop conditions:** all must-have tasks `done` (including the demo-validation task) **and overall
satisfaction ≥ threshold (default 95)**; or a stall persists after wonder/reflect + escalation (~3
recovery cycles — record the blocker, stop, ask or regenerate the plan); or context is too bloated
to continue safely. **Swarm lanes / long-lived builds:** meet the **integration-freshness barrier** before exiting: 1) check the integration SHA used by the lane's last validation; 2) refresh the lane from the current integration head if stale; 3) rerun dependency-aware cross-slice gates (not just lane-local); 4) record the refreshed SHA and results in the shared plan. **Autonomous + manual-merge:** cap concurrent open PRs (~3-5) — past the cap, the
next iteration is a consolidation task (help land existing PRs), not another net-new one
(`references/ralph-loop.md`).

## Phase 4 — Ship / Handoff
- Summarize what was built, how to run/validate it, and what the demo path is.
- **Report telemetry (three clocks, never conflated).** Report **wall time** (frozen at the
  ready-to-test gate, before reporting overhead), **allocated lane time** (a capacity upper bound —
  a parked lane still burns lifetime, so this is *never* "agent-hours"), and **active agent time**
  (summed per-turn durations — a measured lower bound), plus parked time, timed-vs-missing turn and
  lane counts, peak concurrency, and critical-path duration. `scripts/swarm.sh` prints this block
  and `.wgm/metrics.tsv` records it per turn. Keep missing telemetry explicit rather than estimating
  it, and label every ratio an operational heuristic — not billing data and not a causal speedup
  claim (`references/telemetry.md`).
- For larger or multi-session builds, an optional morning-after run report may be left from `assets/morning-report.template.md` (pattern borrowed from [elves](https://github.com/aigorahub/elves)).
- List remaining/follow-up tasks (already in `IMPLEMENTATION_PLAN.md`).
- **Offer `/teach-me` when the operator is about to own code they did not write.** After a largely
  autonomous run — or for an operator new to this codebase — a summary is not comprehension. Point
  them at `/teach-me` (cited map, tour, one validated change) and `/quiz-me` to confirm it landed
  (`companions/teach-me/SKILL.md`).
- Leave the repo in a clean, buildable state so a fresh `/wgm build` can resume.
- **If a separate deploy pipeline exists, confirm it's actually green** — not just the PR-level CI
  that gated each merge (`references/ralph-loop.md`, Backpressure in depth). A merged, CI-green PR
  can still sit behind a silently-failing post-merge deploy; don't report work "complete" on PR
  status alone when the spec's demo path implies a live deployment.
- **Audit the history, not just the tree.** Deterministic product gates cannot see commit-message
  governance, so a run can reach a green exact-tree gate and still ship a non-compliant history.
  When the repository mandates commit trailers, treat **merge commits as first-class governed
  commits**: pass `gh pr merge --merge` an explicit `--subject`/`--body` whose final block carries
  the trailers, and audit every introduced commit (`scripts/check-trailers.sh`, or `git rev-list
  <base>..HEAD` + `git show -s --format=%B`). A generated merge commit is the usual offender — every
  head commit complies and the merge button's synthesised commit does not. If a non-compliant merge
  is **already published, do not rewrite shared history**: build a replacement two-parent merge from
  the same parents with the trailers present and prove `old^{tree} == replacement^{tree}` before
  promoting it (`[learn]` issue #82).
- **Audit the docs — mandatory lifecycle evidence (Standard/Full).** Run the docs-audit swarm: four
  independent persona reviews (junior dev · senior dev · principal dev · PM), consolidated by a
  technical-writer role into one paper-trail report — every action item labeled strictly **Agent
  action** or **Operator action** — committed under `docs/audit/` (or `.wgm/docs/audit/`). Dispatch
  it with the host's subagents, or on a host without them with `scripts/audit.sh`, which drives the
  same five roles through one headless agent command (independence of context and lens, not of model
  or tooling — record that). A consolidated pass must eventually cover every Standard-track PR;
  Quick tracks rely on `scripts/check-docs.sh` alone.
- **Harvest the juice (self-improvement).** Scan `.wgm/memories.md` — including any swarm-consolidated
  stream lessons folded into it — for a lesson that is durable, cross-project, and sanitized (about
  wgm's behavior — never the host's code or secrets), then **always anonymize it** before drafting
  anything. (This project's own GitHub Issues are a separate Hive Growth Loop source: they inform
  *backlog discovery*, not this scan — `references/issue-intake.md`.) If `.github/wgm-hive.yml` says
  this project has consented, file it to `agent-frontier/wgm` as a `[learn]` heuristic report
  automatically, de-duping open issues first — no further asking. If the file is absent or declines,
  fall back to asking (explicit ask, dogfood run, or project setting), same as before. This is how
  wgm grows from every codebase (`references/self-improvement.md`, `references/issue-intake.md`).

## Artifact safety (hard rules)
- **Never overwrite or edit an existing `AGENTS.md` by default** — use `.wgm/AGENTS.md` instead.
  Touch the project's root `AGENTS.md` only with explicit approval that names the file and the
  scope of edits.
- If the project root already contains `AGENTS.md`, `IMPLEMENTATION_PLAN.md`, or `specs/`, write
  wgm's artifacts under **`.wgm/`** instead: `.wgm/IMPLEMENTATION_PLAN.md`, `.wgm/specs/`,
  `.wgm/AGENTS.md`.
- A greenfield/empty repo may use the root directly.
- Decide root vs `.wgm/` once, in Triage, and stay consistent.

## Backpressure is the skill
**Backpressure is a deterministic pass/fail signal** — a test, type-check, build, lint, or HTTP
probe — that gates whether a task can be called done. A loop without one is just hoping. Every task
must map its acceptance criteria to a runnable command. If the project has no such signal, your
first job is to create one. **For native apps, games, GUIs, or engines** — where there is no natural unit test — building that harness (headless automation, output capture, state probes, crash soaks) *is* the first task; see `references/hard-to-test-domains.md`. Only for subjective criteria (UX feel, copy,
aesthetics) where no deterministic check can exist, fall back to an LLM-as-judge check with a
binary pass/fail, and record its prompt and verdict. Re-run the signal until green before declaring
a task done. For holistic, end-to-end confidence, augment with **holdout-scenario satisfaction
scoring** (`references/scoring.md`) — but deterministic checks remain the hard gate.

## References
- `references/grilling.md` — the interview discipline.
- `references/trigger-eval.md` — a hand-curated should/should-not-trigger fixture to catch drift in
  the mode-parsing rule or the "Use this when"/"Do NOT use this when" boundary.
- `references/evals.md` — the companion output-quality fixture (`evals/evals.json`): given wgm
  triggers, is the result actually good? Adopted from the `agentskills.io` spec's own eval
  discipline.
- `references/ralph-loop.md` — loop mechanics, backpressure, context hygiene, Ralph-lite vs full.
- `references/memory-patterns.md` — optional structured/layered memory upgrades for long Full-track
  builds that outgrow the flat `.wgm/memories.md` log (the flat log stays the default).
- `references/local-models.md` — a token-input budget playbook for locally-hosted, small-context
  models (e.g. ~65k tokens): narrower reads, earlier context rotation, tighter memory budgets, and
  repurposing frugal/main escalation as a context-size tier.
- `references/subagents.md` — the twelve role-specialized subagents (griller · implementer ·
  two-stage review · validator · diagnostician · the five-role docs-audit swarm · `wgm-hermes`, the
  hive courier) and how the Loop dispatches them ("swarm" mode).
- `references/docs-audit.md` — the mandatory docs-audit paper trail: four dev/PM personas plus a
  technical-writer consolidator, Agent-vs-Operator action classification, and artifact placement.
- `references/issue-intake.md` — backlog discovery from a project's own GitHub Issues, tracker-
  reference traceability, and the `Closes #N` linking convention.
- `references/artifacts.md` — formats + placement rules for specs, scenarios, plan, AGENTS.md, and
  `.github/wgm-hive.yml`.
- `references/adr.md` — ADR discipline for hard-to-reverse, cross-cutting decisions.
- `references/scenarios.md` — holdout acceptance scenarios (YAML schema, tiers, discipline).
- `references/scoring.md` — preflight readiness + satisfaction scoring (LLM-as-judge, thresholds).
- `references/telemetry.md` — the three clocks (wall · allocated lane time · active agent time), why
  parked lane lifetime is never "agent-hours", and what Ship/Handoff must report.
- `references/stall-recovery.md` — wonder/reflect + model escalation on a stall.
- `references/hard-to-test-domains.md` — backpressure for native/games/GUIs/engines (headless harness, output capture, crash soaks, symbolized repro, native gotchas).
- `references/gene-transfusion.md` — seed the build from an exemplar codebase.
- `references/validation-env.md` — OCI/Podman-first containerized validation.
- `references/devcontainers.md` — running the loop itself sandboxed in a disk-conscious local
  devcontainer (shared base image, `scripts/devcontainer.sh`).
- `references/self-improvement.md` — the Hive Growth Loop: harvest lessons from every source
  (dogfood memories, swarm streams, this project's own Issues, cross-pollinated external research),
  always anonymize, and report upstream automatically once a project consents via
  `.github/wgm-hive.yml`; `references/heuristics.md` is the curated ledger.
- `assets/` — fill-in templates scaffolded per-build (`spec`, `scenario`, `IMPLEMENTATION_PLAN`, `AGENTS`, `constitution`, `context`, `memories`, `genes`, `docs-audit-report`, optional `sprint-status`, optional `adr`, optional `morning-report`, `wgm-hive.template.yml`), plus `state.template.toon` (compact agent-only state), `evals.template.json` (wgm's own self-test fixture skeleton — not scaffolded into arbitrary builds; see `references/evals.md`), and `devcontainer/` (the shared devcontainer.json + Containerfile templates `scripts/devcontainer.sh init` scaffolds).
- `scripts/loop.sh` — optional external Ralph loop (`--devcontainer` runs it sandboxed); `scripts/swarm.sh` — fan it out across parallel git-worktree streams. `scripts/check-trailers.sh` — audit every introduced commit (merges included) for mandated trailers. `scripts/check-doc-sync.sh` — flag a diff that adds public surface without touching docs. `scripts/devcontainer.sh` — init/build-base/run/prune a shared local sandbox. `scripts/harvest-hive.sh` — the Hive Growth Loop's courier (anonymize, consent-check, publish). `scripts/install.sh` / `install.ps1` — installers.
- `references/PLUGIN_PROTOCOL.md` — plugin contract (discovery, hooks, structured I/O, error handling).
- `references/plugin-integration.md` — where plugins attach in Triage/Plan/Validate.
