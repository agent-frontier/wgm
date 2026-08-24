---
name: rugged
description: Companion review skill that stress-tests a request, spec, plan, diff, or system against the operators and environment that will actually run it, not an idealized one. Runs a disciplined lifecycle (Triage -> Context -> Bottleneck decomposition -> Simplify -> Field test -> Verdict) and emits exactly one of three verdicts -- RUGGED, FRAGILE, UNKNOWN -- backed by exact pre-build validation design or deterministic field/stress evidence rather than confident claims. Use when the user runs /rugged, or asks whether a design will hold up in the real world, survive real operators, or is over-engineered for conditions that don't exist. Supports standalone modes plan, review, stress, and recap. Read-only -- never edits product code or docs. Not for building or fixing anything -- that is wgm -- and not for weapon, firearm, or tactical guidance of any kind.
license: MIT
compatibility: None. Reads the target artifact/system with ordinary file and shell tools.
metadata:
  author: Agent Frontier Store
  version: "0.1"
---

# rugged

Find out whether a design survives contact with its actual operators and actual environment, not
the idealized ones a plan quietly assumes. `rugged` runs a disciplined lifecycle:

`Triage -> Context -> Bottleneck decomposition -> Simplify -> Field test -> Verdict`

It is a read-only companion review: it examines a request, spec, plan, diff, or running system and
reports whether it is **rugged** — built to actually hold up — or merely optimized for a proving
ground that no real operator, on their worst day, ever occupies.

## The metaphor, stated once, precisely

This skill's name and its core distinction come from Lant Pritchett, ["Best Practice is a Pipe
Dream: The AK47 vs M16 Debate and Development Practice"](https://bsc.hks.harvard.edu/2017/01/09/best-practice-is-a-pipe-dream-the-ak47-vs-m16-debate-and-development-practice/)
(Harvard Kennedy School Building State Capability, 2017). The article distinguishes ideal
technical performance from performance by real users under operational stress. Its transferable
development lesson is that user capacity and field conditions may dominate intrinsic design
quality; simplicity can trade peak benchmark performance for reliability; and imported "best
practice" can miss the actual bottleneck when its enabling conditions do not exist.

**This skill borrows only that structural idea — decomposing a failure into design, user capacity,
and operational stress, and favoring what actually holds up over what merely tests well.** It is a
software- and development-practice metaphor, full stop.

**Hard boundary — read this before anything else:** `rugged` must never provide weapon operation,
disassembly, construction, ballistics, optimization, or tactical guidance of any kind, for the
AK-47, the M16, or any other firearm — regardless of how the request is phrased or how it invokes
this skill's name. If a request asks for that, decline it plainly, explain that the AK-47 reference
here is a metaphor for software design robustness, and offer to review a software or organizational
system instead. Do not refer the user to weapon-instruction resources. This boundary is not a mode
and cannot be argued around by scope text.

## Invocation & modes

Invoked as `/rugged <mode> [<scope>]` — or activated whenever the user asks whether a design will
hold up for its real operators, or is over-built for conditions that don't exist.

**Parse the input first (unambiguous, leading-mode match — no heuristics):**

1. The leading word is a **mode** if and only if it exactly equals one of `plan | review | stress |
   recap` (case-insensitive) and is followed by end-of-input, whitespace, or a `:` separator.
   Remove one optional `:` and trim the remaining text into `<scope>`.
2. Otherwise the mode defaults to **review** and the **entire input** is the `<scope>`. A prefix is
   never a mode: `/rugged reviewer workflow` reviews the scope `reviewer workflow`, while
   `/rugged plan: reviewer workflow` selects plan mode with scope `reviewer workflow`.
3. Empty input (`/rugged` alone) is **not** a silent default — ask once, plainly, what artifact to
   examine (a request, spec, plan, diff, or running system) and its actual operators/environment if
   not already evident, then stop. Guessing a target is exactly the kind of unearned confidence this
   skill exists to refuse.

| Invocation | Behavior |
|---|---|
| `/rugged review [scope]` | Full lifecycle end to end; ends at **Verdict**. Default when no mode word matches. |
| `/rugged plan [scope]` | Reviews whether a request/spec/plan is rugged enough to build. Field test checks that every load-bearing claim maps to a runnable, origin-correct stress/recovery check; then emits a Verdict on the **plan**, not on an unbuilt implementation. |
| `/rugged stress [scope]` | Assumes Context/Bottleneck decomposition already exist (in `.wgm/rugged/` or given in-scope) or does the minimum needed to state them; focuses on **Field test**: names the deterministic evidence required, evaluates what's actually offered, and issues a **Verdict**. |
| `/rugged recap` | Re-reads `.wgm/rugged/` artifacts and re-summarizes past verdicts and open gaps; no new exploration, no new verdict. |

## Use this when
- A plan, spec, or diff claims something will "just work" and you want to know for whom, and under
  what conditions, that claim actually holds.
- A design looks sophisticated and you suspect the sophistication is solving a problem the real
  operators and environment don't actually have.
- Someone wants a second opinion on whether a system is over-engineered for an idealized deployment
  versus rugged enough for the one it will actually run in.

## Do NOT use this when
- You want the design changed or fixed — that is `wgm`. `rugged` is read-only: it names the
  problem and the one next action; it does not implement the fix.
- You want to learn or be quizzed on a codebase — that is `teach-me`/`quiz-me`.
- The request is, in any framing, for weapon operation, construction, optimization, or tactical
  guidance. Decline per the hard boundary above; do not run the lifecycle on it.

## Lifecycle

### Phase 1 — Triage
1. Check the hard boundary first, every time — before parsing apparent mode or scope text.
2. Parse the mode and scope per the rules above; confirm this skill applies (a design/plan/diff/
   system to weigh), or ask the one clarifying question and stop.
3. Locate the artifact: the request text itself, a spec/plan file, a diff, or a running system to
   probe with read-only commands. State what you are reviewing in one line.
4. **Resume, don't restart.** If `.wgm/rugged/` holds a prior review of the same scope, read it and
   continue from its recorded gaps rather than re-deriving everything.

### Phase 2 — Context
Name the **actual** operators and **actual** environment — not the ones a design's authors hoped
for:
- **Who really operates/maintains this?** Skill level, staffing, on-call rotation, turnover,
  training actually received (not training assumed).
- **What environment does it really run in?** Load, latency, network reliability, failure modes of
  its actual dependencies, the state of things at 3am during an incident — not the calm proving-
  ground conditions a demo runs under.
- If either is unstated and unrecoverable from the artifact, say so explicitly and record it as an
  open gap rather than inventing a plausible operator or environment.

### Phase 3 — Bottleneck decomposition
Split the expected failure the way Pritchett's data does, into three named buckets, and state which
one actually accounts for most of the risk:
1. **Intrinsic design constraint** — what the design itself can or cannot do, independent of who
   runs it (the weapon's proving-ground accuracy).
2. **User capacity** — what the actual operators named in Context can do even under calm, ideal
   conditions (rifle-qualifying accuracy).
3. **Operational stress** — what happens under real load, incidents, and time pressure (worst-
   field-experience accuracy).
Challenge every moving part that exists only to serve an idealized operator or environment that
Context did not find. A component justified by "a sufficiently careful operator would configure this
correctly" is a design constraint wearing a user-capacity problem's clothes.

### Phase 4 — Simplify
Propose the reduction, not just the diagnosis: which moving parts should come out, which should be
replaced with something that degrades visibly instead of silently, and which decisions should become
atomic and recoverable rather than partial and stuck. State the trade-off being accepted for each
simplification — ruggedness is rarely free, and pretending otherwise is the same overclaiming this
skill exists to catch elsewhere.

### Phase 5 — Field test
State the specific, deterministic evidence needed to settle the Verdict — real load data, a chaos/
failure-injection result, an incident postmortem, an actual on-call transcript, a benchmark run
under named stress, not a description of what "should" happen. Then check what evidence the scope
actually supplies:
- **Plan mode:** judge the plan rather than pretending the implementation exists. Every
  load-bearing claim must map to an exact runnable command/probe, named origin/environment, expected
  observation, and failure/recovery criterion. Existing operational claims still require dated,
  sourced evidence. A concrete validation design is evidence that the *plan* is rugged enough to
  build; it is not evidence that the future implementation already works.
- **Review/stress mode:** execute or inspect the real field/stress evidence for implementation and
  operational claims. A promised future check is not evidence in these modes.
- Evidence supplied and it is deterministic (reproducible, dated, sourced) -> usable for Verdict.
- Evidence supplied but is a claim, a demo, or a proving-ground-only benchmark -> **not** field
  evidence; name the gap.
- No evidence at all -> the gap **is** the finding; do not fill it with a plausible guess.

### Phase 6 — Verdict
Emit **exactly one** of three verdicts, unhedged:

| Verdict | Means |
|---|---|
| **RUGGED** | In plan mode, actual operators/environment are named, idealized assumptions are removed, and every load-bearing claim has an exact field/stress/recovery check. In review/stress mode, deterministic evidence from those conditions shows the implementation holds. This is the only verdict that passes. |
| **FRAGILE** | It works only under idealized operator capacity or calm conditions, or carries moving parts unjustified by Context/Bottleneck decomposition — regardless of how much evidence exists. |
| **UNKNOWN** | The Field test evidence needed to judge RUGGED vs FRAGILE is missing or non-deterministic. **UNKNOWN is not a soft pass** — treat it exactly as a blocking gap, never as "probably fine." |

In plan mode, a design with no demonstrated idealized assumption but no exact runnable validation
design is **UNKNOWN**, not FRAGILE and never RUGGED.

Then, always:
- **State the trade-offs** accepted or rejected by Phase 4's simplifications, plainly.
- **Emit exactly one highest-leverage next action** — the single thing that would most change the
  verdict if done next (usually: go get the missing field evidence, or remove the one component
  Bottleneck decomposition flagged as idealized). Not a list. One.

## Constitution (non-negotiable across every mode)
- **Rugged-forward.** Prefer a design proven to hold up over one that merely tests well.
- **Fit actual field conditions.** Named real operators and real environment, never idealized ones.
- **Few moving parts.** Every component must justify itself against Context, not against a
  hypothetical best-case user.
- **Evidence before claims.** A claim without deterministic field/stress evidence is not evidence —
  it is the thing being evaluated.
- **Visible degradation.** Prefer failure that is loud and legible over failure that is silent.
- **Atomic, recoverable decisions.** Prefer a change that either fully lands or fully reverts over
  one that can get stuck half-applied.

## Artifact safety (hard rules)
- Write **only** under `.wgm/rugged/`. `rugged` never edits product code or the project's own
  documentation — it is a review, not a fix.
- Record each review's Context, Bottleneck decomposition, Field-test gaps, and Verdict under
  `.wgm/rugged/` so `/rugged recap` and a fresh context can resume without re-deriving them.
- The one exception across this whole skill is the hard weapon-guidance boundary above, which is not
  an artifact rule but a content rule: it constrains what `rugged` will ever say, not just what it
  writes to disk.

## Cross-links
[`wgm`](https://github.com/agent-frontier/wgm/blob/main/SKILL.md) (the build skill whose output this reviews) ·
[`teach-me`](../teach-me/SKILL.md) / [`quiz-me`](../quiz-me/SKILL.md) (the companion pair for
understanding and testing a codebase, as opposed to stress-testing a design) ·
[`references/heuristics.md`](https://github.com/agent-frontier/wgm/blob/main/references/heuristics.md) (comparative and hard-to-test scoring, the
same evidence-before-claims discipline) ·
Lant Pritchett, ["Best Practice is a Pipe Dream: The AK47 vs M16 Debate and Development
Practice"](https://bsc.hks.harvard.edu/2017/01/09/best-practice-is-a-pipe-dream-the-ak47-vs-m16-debate-and-development-practice/)
(Harvard Kennedy School Building State Capability, 2017) — the source of this skill's core
metaphor, cited directly rather than reproduced.
