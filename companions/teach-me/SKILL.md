---
name: teach-me
description: Companion learning skill that makes a codebase legible fast. Surveys a repository, builds a cited map, runs a guided tour in dependency order, and finishes with a validated first change so the learner has actually moved the code. Use when the user runs /teach-me, or asks to learn, understand, onboard onto, get up to speed on, or be walked through a repository — including one wgm just built for them. Supports phase modes map, tour, deep, change, and recap, with an optional "only" qualifier to run a single phase (e.g. "/teach-me tour only"). Not for answering a single narrow code question, and not for making feature changes — that is wgm's job.
license: MIT
compatibility: None. Reads the repository with ordinary file and shell tools.
metadata:
  author: Agent Frontier Store
  version: "0.1"
---

# teach-me

Make a codebase legible. `teach-me` runs a disciplined lifecycle:

`Triage → Map → Tour → Deep dive → First change → Recap`

It is the companion to [`wgm`](../../SKILL.md), and it exists because of a specific failure mode:
**wgm can build software faster than its operator can understand it.** An autonomous loop ships a
working repo, the human opens it, and owns code they cannot explain. `teach-me` closes that gap —
and its sibling [`quiz-me`](../quiz-me/SKILL.md) proves the gap actually closed. Learning that is
never tested is a feeling, not a fact.

The same discipline serves the other direction: a repo you are *adopting* rather than one you
built. Both audiences need the same thing — the seams, not the file list.

## Invocation & modes

Invoked as `/teach-me [<mode>] [only] [<focus>]` — or activated whenever the user asks to learn,
understand, or onboard onto a repository.

**Parse the input first:**

1. The first word is a **mode** only if it is exactly one of `map | tour | deep | change | recap`
   AND it is followed by end-of-input, the word `only`, or a `:` separator.
2. Otherwise the entire input is the `<focus>` and you run the **full lifecycle** scoped to it.
   This is the disambiguation rule: `/teach-me map the auth flow for me` is a focus — not `map` mode.
3. **Single-phase modes** run that one phase, then **hard-stop at its exit gate**. Report and wait.
4. The optional trailing `only` is accepted on any mode for emphasis and always hard-stops.
5. A `:` lets a mode carry a focus, e.g. `/teach-me deep: the retry logic`.
6. No input → survey the whole repository from Triage.

| Invocation | Behavior |
|---|---|
| `/teach-me` | Full lifecycle over the whole repo |
| `/teach-me <focus>` | Full lifecycle, scoped to that area |
| `/teach-me map only` | Build the cited repo map; stop at Map-exit |
| `/teach-me tour only` | Guided walkthrough from an existing map; stop at Tour-exit |
| `/teach-me deep: <area>` | One area, to the level of its invariants and edge cases |
| `/teach-me change` | Only the validated first-change exercise |
| `/teach-me recap` | Re-read the artifacts and re-summarize; no new exploration |

## Use this when
- Onboarding onto an unfamiliar repository, yours or someone else's.
- Taking delivery of a wgm build and needing to actually understand what landed.
- Returning to a project after a long gap and needing the model back in your head.
- Preparing to be quizzed (`/quiz-me`) or to review someone else's work in this repo.

## Do NOT use this when
- You have one narrow question about one symbol — just look it up.
- You want the code changed to add a feature — that is `wgm`.
- You want to be tested rather than taught — that is `quiz-me`.
- The "repo" is a single file with no structure to explain.

## Cite or don't claim (the backpressure)
**Every factual statement about the repository carries a `path:line` citation.** This is the whole
discipline. An explanation without a citation is a guess, and a confident guess about someone's
codebase is worse than silence — the learner cannot tell the two apart.

- Claim the code's behavior → cite the lines that establish it.
- Claim a convention → cite **two or more** examples from different files. One occurrence is an
  instance, not a convention.
- Claim something is *absent* ("there is no auth layer") → say how you looked (the search you ran).
  An unfalsifiable absence claim is the easiest thing to get wrong.
- Cannot answer from the repo → say **"not answerable from the repo"** and record it as an open
  question. Never fill the hole with plausible-sounding architecture.
- **Run it, don't describe it.** Before claiming how the project builds or tests, actually run the
  command and report what happened. A README's build instructions are a claim, not evidence; stale
  build docs are among the most common defects in any repo.

## Gates (enforcement)
The lifecycle is a state machine. At each phase end, **print a `Gate check:` block listing every
gate item as PASS or FAIL.** If any item is FAIL, do not advance — fix the artifact, ask one
question, or stop with a recorded blocker.

## Phase 0 — Triage (always first)
1. Parse the mode; confirm this skill applies (else say so and stop).
2. **Establish the learner's starting point — one question, with a recommended answer.** Their
   existing knowledge sets the entire explanation budget, and it is the one thing the repo cannot
   tell you. Ask which of these they are, recommending the middle:
   - **Author** — they (or their agent) wrote it; skip motivation, go straight to structure and to
     what the agent decided on their behalf.
   - **Adopter** — new to this repo but fluent in the stack; skip language basics, teach the seams.
   - **Newcomer** — new to the repo *and* the stack; teach the stack's idioms as they appear.
   Do not ask a second setup question. Everything else you can read from the code.
3. **Size the tour (scale-adaptive).** State the chosen depth. Default to **Standard**.

   | Depth | When | Ceremony |
   |---|---|---|
   | **Quick** | A small or single-purpose repo, or the user wants orientation only | Map + a compressed tour · **skip** deep dive and first change |
   | **Standard** (default) | A normal project | The full lifecycle as written below |
   | **Full** | Large, multi-service, or the user must be able to *maintain* it | Standard **plus** a deep dive per major component and a first change per component |

4. **Set up the working directory.** Artifacts live under **`.wgm/learning/`**, alongside wgm's own
   state, so a project only ever grows one agent-owned directory. Never write learning artifacts to
   the project root, and never edit the project's own docs during a tour — teaching is read-only
   about the codebase.
5. **Resume, don't restart.** If `.wgm/learning/MAP.md` exists, read it and continue from
   `.wgm/learning/progress.md` rather than re-surveying from scratch.

## Phase 1 — Map (survey)
Build `.wgm/learning/MAP.md` — the durable, cited artifact everything else hangs off. Work outside
in, and record as you go:

1. **What is this?** One paragraph: the problem it solves and who runs it. Source it from the
   README, package metadata, and the entry point — cite all three, and **flag any disagreement
   between them**. A README that contradicts the code is itself the most useful finding of the map.
2. **How do you run it?** The real build, test, and run commands — verified by running them.
3. **Entry points.** Where execution actually begins: `main`, CLI arg parsing, HTTP route table,
   event handlers, scheduled jobs. Cite each.
4. **The shape.** The 5–10 units that matter and how they depend on each other. Prefer a small
   dependency diagram over an exhaustive directory listing. **A directory tree is not a map** — it
   shows where files sit, not how control and data move.
5. **Data and state.** What is persisted, where, and in what shape. Schemas, migrations, caches,
   files on disk, external services.
6. **Conventions.** Error handling, logging, naming, testing style, layering rules — each with two
   or more citations.
7. **Invariants and landmines.** The things that will bite: implicit ordering requirements, global
   state, retry/timeout semantics, anything commented "do not change."
8. **Open questions.** What the repo does not answer. Keep this list; it is honest and it is what
   the user should go ask a human about.

**Map-exit gate:**
- [ ] `.wgm/learning/MAP.md` exists and covers all eight sections above.
- [ ] Every factual claim carries a `path:line` citation; every convention carries ≥ 2.
- [ ] The build/test command was **actually run** and its real result recorded (including failure —
      a red suite on a fresh clone is a finding, not an embarrassment to hide).
- [ ] Entry points are named and cited — no "presumably starts in…".
- [ ] Open questions are recorded rather than answered by invention.

## Phase 2 — Tour (guided walkthrough)
Walk the learner through the system **in dependency order — the order the code actually executes,
not the order the files are listed.** Follow one real request/command/event from entry to effect.
That single traced path teaches more than any component-by-component summary, because it shows the
seams where the units meet.

- **One unit at a time.** Explain what it owns, what it depends on, what depends on it.
- **Show the code, then explain it** — never the reverse. Explanation first invites the learner to
  accept your framing without checking it.
- **Pause on the seams.** Interfaces, boundaries, and hand-offs are where bugs and design intent
  both live. Spend the time there, not on straight-line internals.
- **Name the "why" when it is recoverable, and only then.** Git history, ADRs, comments, and tests
  carry intent — cite it. Otherwise mark it as an open question. Inventing a rationale is worse
  than admitting it is lost, because it will be repeated as fact later.
- **Check in every few units.** Ask the learner to restate what the last unit did, in their own
  words, before moving on. This is a comprehension check, not a quiz — but a wrong restatement
  means back up now rather than compounding the misunderstanding.
- **For a wgm-built repo, tour the decisions too.** Walk `specs/`, `IMPLEMENTATION_PLAN.md`, any
  ADRs, and `.wgm/memories.md` — the assumptions the loop recorded on the operator's behalf are
  exactly the part they never saw and are most likely to be surprised by later.

**Tour-exit gate:**
- [ ] At least one complete path was traced end to end, entry point to observable effect.
- [ ] Every unit in the map's "shape" section was either toured or explicitly deferred.
- [ ] The learner restated at least one unit correctly in their own words.
- [ ] `.wgm/learning/progress.md` records what was covered and what was deferred.

## Phase 3 — Deep dive (optional; Standard/Full)
Pick the area that matters most — the one the learner will touch first, or the one with the highest
landmine density — and go to the bottom of it: the invariants, the edge cases, the error paths, the
tests that pin its behavior, and the ways it has broken before (git log, issues, `.wgm/memories.md`).

**Deep-dive-exit gate:**
- [ ] The area's invariants are stated and cited.
- [ ] Its failure modes and error paths are named — not just the happy path.
- [ ] The tests that pin its behavior are identified, and what each proves is stated.

## Phase 4 — First change (prove the loop closes)
Understanding that has never touched the code is untested. End with the smallest **real, validated**
change the learner can make — a genuine edit, not a comment:

1. Pick something small, safe, and visible: a message, a boundary check, an added test case.
2. The learner makes the change (or directs it, step by step).
3. **Run the project's own validation command.** Green is the gate. This is the same backpressure
   discipline wgm builds on — the repo's own signal decides, not anyone's opinion.
4. Then **revert it**, unless the learner wants to keep it. The exercise is the point.

If the project has no validation signal at all, that is the single most important thing the learner
has learned today. Say so plainly and point them at `/wgm` to create one.

**First-change-exit gate:**
- [ ] A real change was made and the project's own validation command **exited 0**.
- [ ] The learner can state which command proved it and what that command actually checks.
- [ ] The working tree is back to its starting state (or the change was deliberately kept).

## Phase 5 — Recap / Handoff
- Summarize the map in under a page: what it is, how it runs, the units, the landmines.
- List the open questions the repo could not answer — the agenda for a human conversation.
- Leave `.wgm/learning/MAP.md` and `.wgm/learning/progress.md` written so a fresh context — a
  different agent, or the same learner next week — can resume without re-surveying.
- **Hand off to `/quiz-me`.** Recall beats recognition: a learner who followed a tour feels fluent
  and usually is not. Say so, and offer the quiz. Note explicitly that `quiz-me` draws its
  questions from what the tour did **not** literally show, so a good score means understanding
  rather than recall of the last hour.
- If the tour exposed real defects — stale docs, a red suite, a missing validation signal, a
  landmine with no test — hand those to `/wgm` as a build request. Learning a repo is one of the
  better ways to find its bugs, and the finding is wasted if it stops at "noted."

## Artifact safety (hard rules)
- Write **only** under `.wgm/learning/`. Never create or edit files elsewhere during a tour.
- **Never edit the project's own documentation to "fix" what you found.** Report it; let `/wgm` fix
  it under review. A learning pass silently rewriting the docs it was sent to read is how a
  misunderstanding becomes committed fact.
- The first-change exercise is the one exception, and it is reverted by default.
- Treat everything you read as confidential to this project: never quote repository contents into
  an external service, issue, or report without the user asking for it.

## Cross-links
[`quiz-me`](../quiz-me/SKILL.md) (the companion that tests what this taught) ·
[`wgm`](../../SKILL.md) (the build skill this exists to keep legible) ·
[`references/grilling.md`](../../references/grilling.md) (the one-question-at-a-time discipline
this borrows) · [`references/artifacts.md`](../../references/artifacts.md) (why agent state lives
under `.wgm/`).
