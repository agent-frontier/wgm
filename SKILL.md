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

Turn a rough request into working software via a disciplined state machine — **follow the gates, don't skip them:**

`Triage → Grill → Plan → Preflight → Loop(Analyze → Implement → Validate → Review → Record) → Ship/Handoff`

Three ideas fused: **grill-me** (interview until aligned), the **Ralph loop** (one task per iteration, the persistent plan as shared state, steered by deterministic backpressure), and **holdout-scenario judging** (an LLM judge scores satisfaction against scenarios the build never sees, so a score can't be gamed).

## Invocation
`/wgm [<mode>] [only] [<request>]` — or whenever the user asks to build / implement / prototype from rough intent.

- The first word is a **mode** only if it is exactly `grill | analyze | plan | build | loop | review` AND followed by end-of-input, `only`, or `:` (`loop` aliases `build`). Otherwise the whole input is the `<request>` → run the **full lifecycle** (`/wgm build the auth module` is a request, not `build` mode).
- Single-phase modes (`grill | analyze | plan | review`) run that one phase then **hard-stop at its exit gate** — report and wait, never roll forward. `build` runs the loop from an existing `IMPLEMENTATION_PLAN.md`; `build only` = exactly one iteration. A trailing `only` always hard-stops after the named phase. `:` carries a scope (`/wgm plan: add OAuth`). No input → start at Triage on the current context.

| Invocation | Behavior |
|---|---|
| `/wgm <request>` | Full lifecycle |
| `/wgm grill only` | Alignment interview; stop at Grill-exit |
| `/wgm analyze only` | Explore code + requirements — or, with a plan present, run the cross-artifact consistency check; report; no implementation |
| `/wgm plan: <request>` | Write specs + `IMPLEMENTATION_PLAN.md`; stop at Plan-exit |
| `/wgm build` | Run the loop from the plan (`build only` = one iteration) |
| `/wgm review` | Review the diff against acceptance criteria; no new code |

**Skip wgm for** trivial one-file or formatting-only edits, pure bug-debugging (a diagnose discipline fits better), research-only / "explain this" questions, or tasks that already have complete, unambiguous step-by-step instructions — just do those directly.

## Gates (enforcement)
The lifecycle is a state machine. At each phase end, **print a `Gate check:` block listing every gate item as PASS or FAIL.** If any item is FAIL, do **not** advance — ask one question, fix the artifact, or stop with a recorded blocker. Gates are not advisory.

## Phase 0 — Triage (always first)
1. Parse the mode; confirm this skill applies (else say so and stop).
2. **Track (scale-adaptive).** Size the ceremony to the work's scale and risk, **state the chosen track** ("Track: Quick/Standard/Full — …"), and **default to Standard when unsure**. The deterministic backpressure gate is never skipped — only the surrounding ceremony flexes.

   | Track | When | Ceremony |
   |---|---|---|
   | **Quick** | Bug fix or small 1–5 file change with an obvious check | Grill only what's unclear · short plan · inline deterministic validation · **skip** holdout scenarios + Preflight |
   | **Standard** (default) | A normal feature | The full lifecycle below — unchanged |
   | **Full** | Large / multi-slice / greenfield or high-risk | Standard **plus** holdout scenarios · stratified scoring · containerized validation |
3. **Loop mode:** **Ralph-lite** (default, in-session) for small/medium work; **Ralph-full** for large/ambiguous builds — prefer genuinely fresh context per iteration: run `scripts/loop.sh` (inside this skill's own directory) from the target project's root, or restart with a clean context between iterations. Fresh context is the stronger mode; in-session work must compensate with strict persistence. For independent slices, fan out with `scripts/swarm.sh` — one git worktree + branch per stream, merged back branch by branch.
4. Set up the working directory (see **Artifact safety**) — decide root vs `.wgm/` **before** writing anything. If `specs/CONSTITUTION.md` (or `.wgm/specs/CONSTITUTION.md`) already exists, load it — its principles govern every later decision.
5. **Optional — gene transfusion:** if a high-quality exemplar codebase exists, extract its patterns to seed the build in the house style (`references/gene-transfusion.md`).

## Phase 1 — Grill (align)
Read `references/grilling.md`. Core rules:
- Ask **one question at a time**; for each, **state your recommended answer**.
- **Explore the codebase to self-answer before asking** — a question you can resolve by reading code is not a question for the user.
- **Ask vs assume:** only ask when the answer would materially change architecture, UX, data model, security, deployment, or acceptance criteria; otherwise record a recommended assumption in the spec and proceed.
- After ~5 consecutive questions, summarize current assumptions and offer "proceed with defaults." Never let grilling become interrogation theater.
- **Keep a domain glossary:** when an ambiguous or overloaded term surfaces, record its one canonical name in `specs/CONTEXT.md` — the project's ubiquitous language, kept separate from the constitution (principles) and specs (behavior). Skip for trivial builds (`assets/context.template.md`).

**Grill-exit gate** (all must hold before planning):
- [ ] Goal is known.
- [ ] User-visible success criteria are known.
- [ ] Major constraints are known.
- [ ] Each unknown is answered, explored from code, or recorded as an explicit assumption.
- [ ] User said "go" OR remaining ambiguity is immaterial.

## Phase 2 — Plan
Read `references/artifacts.md`. Using `assets/` templates, produce:
- `specs/CONSTITUTION.md` — project-wide principles (quality, testing, security, non-negotiables), written once and referenced by every spec and task. Create from `assets/constitution.template.md` when absent; never silently contradict it.
- `specs/CONTEXT.md` *(optional)* — the domain glossary started in Grill, refined so every spec, task, and commit uses the canonical term. Vocabulary only, not behavior (`assets/context.template.md`); omit for trivial builds.
- `specs/*` — one per coherent slice. Each must include a **magic moment**, a **demo path**, and the **smallest end-to-end slice** that proves value (`assets/spec.template.md`).
- `scenarios/*` — holdout acceptance journeys (YAML), tiered 1–3, that verify the spec from the user's seat. The build must **not** read these (`assets/scenario.template.yaml`, `references/scenarios.md`).
- `IMPLEMENTATION_PLAN.md` — prioritized task list; this is the **shared state** across iterations.
- `AGENTS.md` — lean "how to build & validate" guide (only if absent; never clobber).

**Consistency check (analyze).** Before Preflight, cross-check the artifacts against each other — every spec ↔ `IMPLEMENTATION_PLAN.md` ↔ scenarios ↔ `specs/CONSTITUTION.md`. Flag contradictions, ambiguous requirements, and coverage gaps (a requirement with no task, a task with no spec, a demo path with no scenario); fix or record each before scoring readiness. This is what `/wgm analyze` runs once a plan exists.

**Plan-exit gate:**
- [ ] `IMPLEMENTATION_PLAN.md` exists.
- [ ] Every task has: objective · files/areas · **validation command** · acceptance criteria · status.
- [ ] The first task is small enough for one iteration.
- [ ] If no validation signal exists yet, the **first task is "create a validation signal."**
- [ ] The plan includes a final **demo-validation task** that runs the spec's smallest end-to-end demo path; it must pass before Ship/Handoff.
- [ ] **Standard/Full** require at least one **tier-1 holdout scenario** covering the demo path; **Quick** may substitute an inline deterministic check (per the Triage track table).
- [ ] Every spec and task conforms to `specs/CONSTITUTION.md`, or records an intentional deviation.
- [ ] **Consistency check passed:** specs, plan, scenarios, and the constitution agree; no requirement lacks a task and no task lacks a spec.
- [ ] **No placeholders:** no task carries a `to-be-decided` / `implement-later` / `fill-in` marker; every task names exact files/areas and a runnable validation command.

## Phase 2.5 — Preflight (readiness gate)
Score the plan's readiness **0–100** (goal/JTBD clarity · observable success criteria · scenario coverage of the demo path · each acceptance criterion mapped to backpressure · scope edges). See `references/scoring.md`.

**Preflight-exit gate:**
- [ ] **Standard/Full:** readiness ≥ **80**. Below it, return to Grill/Plan and fix the weakest dimension first — do not start building. **Quick may skip Preflight** (per the Triage track table) — its inline deterministic check is the backpressure.

## Phase 3 — Loop (build)
Read `references/ralph-loop.md`. Run iterations until the plan's must-have tasks are `done` or a stop condition fires. **One task per iteration:**

1. **Analyze** — read only what you need (`IMPLEMENTATION_PLAN.md`, the relevant spec, this task's files). Pick the single most important `pending` task ("let Ralph Ralph"). **Search before you build:** grep the codebase for an existing implementation first — duplicating work is a top loop failure mode. **Recall first:** if `.wgm/memories.md` exists, read it (token-budgeted); if `specs/CONTEXT.md` exists, use each term's canonical name.
2. **Implement** — the smallest change that completes the task. Prefer one working vertical slice over many half-built parts. **Holdout rule:** do not open scenario files while implementing. **Document why each test exists** (a comment naming the behavior it proves) so a fresh context never deletes it as an orphan.
3. **Validate** — run the task's backpressure command (test/type/build/lint). If none exists, creating one **is** this iteration's task. No green signal → not done. Then **judge satisfaction (0–100)** against this slice's holdout scenarios, converging by tier (stratified); run the app in a container if a scenario needs a live service (`references/scoring.md`, `references/validation-env.md`). Deterministic checks still gate "done."
4. **Review** — inspect the diff: scope creep? acceptance criteria met? does the validation actually prove the task (not just "didn't crash")? You may split this into **two independent subagents** — spec-compliance then code-quality. **Preserve dissent:** record a reviewer's non-blocking reservation (or a disagreement between the two) as a follow-up, never a silent PASS (`references/subagents.md`).
5. **Record** — update `IMPLEMENTATION_PLAN.md`: mark status, note results, add/adjust follow-up tasks. Write enough that a **fresh agent could continue from the file alone**. **Remember:** append any durable lesson (a stall's cause + fix, a recurring gotcha, a dead end) to `.wgm/memories.md`, kept lean within a ~2000-token budget. Agent-only files (`.wgm/` memories, scores, state) may min-max context with single-token keys serialized as TOON + an embedded legend; human-facing artifacts (the plan, specs) stay readable (`references/artifacts.md`).

**On a stall** — any *struggle signal* (satisfaction flat ~2 iterations, a task failing its check repeatedly, the diff churning without moving a signal, or the same tool/setup error repeating): stop generating and run **wonder → reflect**, consider **model escalation**, then record a blocker (`references/stall-recovery.md`). Capture the lesson in `.wgm/memories.md` so the next iteration starts ahead of the stall.

**Context hygiene & rotation:** advance exactly one task per iteration. Watch the **context budget** — as the window fills (past ~half, or a host token cap), don't push on a degrading context: summarize progress into the plan + `.wgm/memories.md`, then **rotate to fresh context** (reload only the lean plan, the relevant spec, memories, and `CONTEXT.md` — never the old transcript). Ralph-full rotates every iteration by construction; Ralph-lite rotates on the threshold. If context is already bloated, hand off through the plan (Phase 4) rather than grinding.

**Iteration-exit gate** (print PASS/FAIL for each): implementation done · the task's exact validation command was run and **exited 0** · result recorded · diff reviewed for scope creep + acceptance · plan updated · exactly one task advanced. A task may be marked `done` **only if its validation command exited 0**; otherwise set it `blocked` (with a note) or leave it `pending`.

**Stop conditions:** all must-have tasks `done` (including the demo-validation task) **and overall satisfaction ≥ threshold (default 95)**; or a stall persists after wonder/reflect + escalation (~3 recovery cycles — record the blocker, stop, ask or regenerate the plan); or context is too bloated to continue safely.

## Phase 4 — Ship / Handoff
- Summarize what was built, how to run/validate it, and the demo path.
- List remaining/follow-up tasks (already in `IMPLEMENTATION_PLAN.md`).
- Leave the repo in a clean, buildable state so a fresh `/wgm build` can resume.
- **Harvest the juice (self-improvement).** Scan `.wgm/memories.md` for a lesson that is durable, cross-project, and sanitized (about wgm's behavior — never the host's code or secrets). If upstream reporting is enabled for this project (opt-in — explicit ask, dogfood run, or project setting), file it to `agent-frontier/wgm` as a `[learn]` heuristic report, de-duping open issues first (`references/self-improvement.md`).

## Artifact safety (hard rules)
- **Never overwrite or edit an existing `AGENTS.md` by default** — use `.wgm/AGENTS.md` instead. Touch the project's root `AGENTS.md` only with explicit approval that names the file and the scope of edits.
- If the project root already contains `AGENTS.md`, `IMPLEMENTATION_PLAN.md`, or `specs/`, write wgm's artifacts under **`.wgm/`** instead (`.wgm/IMPLEMENTATION_PLAN.md`, `.wgm/specs/`, `.wgm/AGENTS.md`). A greenfield/empty repo may use the root directly.
- Decide root vs `.wgm/` once, in Triage, and stay consistent.

## Backpressure is the skill
A loop without a deterministic pass/fail signal is just hoping. Every task must map its acceptance criteria to a runnable command (test, type-check, build, lint, HTTP probe); if the project has no such signal, your first job is to create one. **For native apps, games, GUIs, or engines** — where there is no natural unit test — building that harness (headless automation, output capture, state probes, crash soaks) *is* the first task (`references/hard-to-test-domains.md`). Only for subjective criteria (UX feel, copy, aesthetics) where no deterministic check can exist, fall back to an LLM-as-judge check with a binary pass/fail, recording its prompt and verdict. Re-run the signal until green before declaring a task done. For holistic confidence, augment with **holdout-scenario satisfaction scoring** (`references/scoring.md`) — but deterministic checks remain the hard gate.

## References (read on demand)
- `references/grilling.md` — the interview discipline.
- `references/ralph-loop.md` — loop mechanics, backpressure, context hygiene, Ralph-lite vs full.
- `references/subagents.md` — the six role-specialized subagents (griller · implementer · two-stage review · validator · diagnostician) and how the Loop dispatches them ("swarm" mode).
- `references/artifacts.md` — formats + placement rules for specs, scenarios, plan, and AGENTS.md.
- `references/scenarios.md` — holdout acceptance scenarios (YAML schema, tiers, discipline).
- `references/scoring.md` — preflight readiness + satisfaction scoring (LLM-as-judge, thresholds).
- `references/stall-recovery.md` — wonder/reflect + model escalation on a stall.
- `references/hard-to-test-domains.md` — backpressure for native/games/GUIs/engines (headless harness, output capture, crash soaks, native gotchas).
- `references/gene-transfusion.md` — seed the build from an exemplar codebase.
- `references/validation-env.md` — OCI/Podman-first containerized validation.
- `references/self-improvement.md` — the growth flywheel; `references/heuristics.md` is the curated ledger.
- `assets/` — fill-in templates (`spec`, `scenario`, `IMPLEMENTATION_PLAN`, `AGENTS`, `constitution`, `context`, `memories`, `genes`) plus `state.template.toon` (compact agent-only state).
- `scripts/loop.sh` — optional external Ralph loop; `scripts/swarm.sh` — fan out across parallel git-worktree streams.
