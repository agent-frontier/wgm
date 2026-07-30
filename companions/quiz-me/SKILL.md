---
name: quiz-me
description: Companion assessment skill that grills a user on a codebase until their understanding is proven rather than assumed. Asks one question at a time, grades every answer against the real code with citations, scores 0-100 by difficulty tier, and drills the weak areas it finds. Use when the user runs /quiz-me, or asks to be quizzed, tested, grilled, or checked on a repository — including one wgm just built for them. Supports phase modes warmup, drill, exam, and review, with an optional "only" qualifier to run a single phase (e.g. "/quiz-me drill only"). Not for teaching or explaining the codebase — that is teach-me — and not for reviewing code changes.
license: MIT
compatibility: None. Reads the repository with ordinary file and shell tools.
metadata:
  author: Agent Frontier Store
  version: "0.1"
---

# quiz-me

Find out what the learner actually knows. `quiz-me` runs a disciplined lifecycle:

`Triage → Calibrate → Quiz(Ask → Grade → Drill) → Score → Report`

It is the companion to [`teach-me`](../teach-me/SKILL.md) and the enforcement half of the pair.
`teach-me` creates the *feeling* of understanding; only being tested distinguishes that feeling
from the real thing. Reading an explanation produces recognition — "yes, that looks familiar" —
which is a much weaker signal than recall, and it is the one people consistently mistake for
mastery. This skill produces recall under pressure, then reports honestly on what came back.

It inherits its interview discipline directly from [`wgm`](../../SKILL.md)'s Grill phase, pointed
the other way: wgm grills the human about *what they want*; `quiz-me` grills them about *what is
actually in the repo*. And it inherits wgm's **holdout** discipline, which is what makes the score
mean anything — see "Holdout rule" below.

## Invocation & modes

Invoked as `/quiz-me [<mode>] [only] [<focus>]` — or activated whenever the user asks to be
quizzed, tested, or grilled on a repository.

**Parse the input first:**

1. The first word is a **mode** only if it is exactly one of `warmup | drill | exam | review` AND
   it is followed by end-of-input, the word `only`, or a `:` separator.
2. Otherwise the entire input is the `<focus>` and you run the **full lifecycle** scoped to it.
   This is the disambiguation rule: `/quiz-me review the caching layer` is a focus — not `review` mode.
3. **Single-phase modes** run that one phase, then **hard-stop at its exit gate**.
4. The optional trailing `only` is accepted on any mode and always hard-stops after that phase.
5. A `:` lets a mode carry a focus, e.g. `/quiz-me drill: error handling`.
6. No input → quiz the whole repository, starting at tier 1.

| Invocation | Behavior |
|---|---|
| `/quiz-me` | Full lifecycle across the repo, converging tier by tier |
| `/quiz-me <focus>` | Full lifecycle, scoped to that area |
| `/quiz-me warmup only` | A few tier-1 questions to locate their level; stop |
| `/quiz-me drill: <area>` | Repeated questions on one weak area until it converges |
| `/quiz-me exam` | A scored, no-hints run across all tiers |
| `/quiz-me review` | Re-read past scores, report gaps and trends; ask nothing new |

## Use this when
- Someone claims (or hopes) they understand a repository and it matters whether they do.
- Right after `/teach-me`, to convert a tour into tested knowledge.
- After taking delivery of a wgm build, before shipping or operating it.
- Before an on-call rotation, a code-review responsibility, or a handover.

## Do NOT use this when
- The user wants to *learn* the repo — run `/teach-me` first. Quizzing someone on material they
  have never seen teaches nothing and is merely unpleasant.
- The user asked a question — answer it. Do not turn a request for help into an interrogation.
- You are reviewing a diff or a PR — that is code review, not assessment of a person.

## Question discipline
Adapted from [`references/grilling.md`](../../references/grilling.md), inverted:

- **One question at a time. Always.** Never bundle. Never present a numbered list of questions and
  ask them to "answer any." A bundle lets the learner answer the easy one and quietly skip the one
  that would have exposed the gap.
- **Never reveal the answer before they answer.** Not as a hint, not as a "for example," not
  embedded in the phrasing of the question. This is the single easiest way to destroy a quiz's
  signal, and it is easy to do by accident when trying to be helpful.
- **Ask about behavior and consequence, not trivia.** "What happens if this retries while the
  cache is cold?" teaches. "What is this function called on line 84?" does not. Naming questions
  test whether they memorized a tour; consequence questions test whether they built a model.
- **Prefer questions with a checkable answer.** You must be able to settle it from the code. If you
  cannot verify it yourself, you cannot grade it, and an unverifiable question invites you to grade
  your own assumption instead of their answer.
- **Never ask a question you have not first answered yourself from the code.** Read the lines,
  settle the answer, keep the citation, *then* ask. An unanchored question is how a grader ends up
  confidently marking a correct answer wrong.
- **No trick questions.** The goal is a measurement, not a defeat.
- **Cap the run.** After ~7 questions in one sitting, report and offer to continue. Fatigue depresses
  the score without telling you anything about their knowledge.
- **State the tier with each question**, so the learner knows whether they are being stretched.

## Holdout rule (why the score means something)
Questions must come from code the learner has **not just been walked through verbatim**. If a tour
literally displayed the answer twenty minutes ago, a correct answer measures short-term recall, not
understanding — the same reward-hacking failure that wgm's holdout scenarios exist to prevent.

- Read `.wgm/learning/progress.md` (if present) for what `teach-me` covered, and prefer the
  **adjacent and untoured** material: the consequences of what was shown, not the shown lines.
- Prefer questions that require **combining two places** in the codebase. Those are the ones that
  cannot be answered from memory of a single screen.
- Never paste the answering code into the question.
- If the whole repository has been toured line by line, shift to tier 3 — "what breaks if…",
  "where would you add X and what else must change" — which stays holdout even on familiar code
  because the answer is not written down anywhere.

## Difficulty tiers
- **Tier 1 — orientation.** What it is, how to run it, where execution starts, what the main units
  are. A tier-1 miss means go back to `/teach-me`; more questions will not help.
- **Tier 2 — working knowledge.** Data flow, error handling, conventions, what a given change would
  touch. This is the tier that predicts whether someone can safely make a change.
- **Tier 3 — mastery.** Invariants, failure modes, concurrency and ordering, "what breaks if,"
  where a new feature belongs and what else must move with it.

**Stratified convergence:** converge tier 1 before advancing to tier 2, and tier 2 before tier 3.
A pile of easy passes must never mask a broken tier 3 — the same rule wgm applies to scenarios.

## Gates (enforcement)
At each phase end, **print a `Gate check:` block listing every gate item as PASS or FAIL.** Do not
advance on a FAIL.

## Phase 0 — Triage (always first)
1. Parse the mode; confirm this skill applies (else say so and stop).
2. **Read the repo before asking anything.** You cannot grade a codebase you have not read. If
   `.wgm/learning/MAP.md` exists, read it — that is `teach-me`'s cited map and it is the fastest
   path to a well-anchored question set. If it does not exist, survey enough of the repo yourself
   to write questions you can answer, and say that the quiz is unmapped.
3. **Say the stakes out loud, once.** State that the score is a measurement, that a low score is
   information rather than a verdict, and that guessing is fine — an unflagged guess that happens
   to be right is the one outcome that corrupts the result, so ask them to say when they are
   guessing. Then do not moralize about it again.
4. **Resume, don't restart.** Read `.wgm/learning/quiz-log.md` if present: start from the weakest
   recorded area rather than re-asking what they already proved.

## Phase 1 — Calibrate
Ask **2–3 tier-1 questions** to locate their level. Do not score this phase; use it to choose the
starting tier. Starting three tiers above someone's level produces a demoralizing zero that
measures nothing; starting below it wastes the session.

**Calibrate-exit gate:**
- [ ] A starting tier is chosen and stated.
- [ ] Every calibration question was answerable from code you have actually read.

## Phase 2 — Quiz loop
Repeat until the stop condition fires. **Each cycle:**

1. **Ask** — one question, tier stated, answer already known to you and cited. Then stop and wait.
   Do not continue, hint, or fill the silence.
2. **Grade** — against the real code, with the citation:
   - **Correct** — right, and for the right reason.
   - **Partial** — right conclusion, wrong or missing mechanism. Say exactly which half was missing;
     "partial" without that is a grade the learner cannot act on.
   - **Incorrect** — wrong. Say so plainly and immediately.
   - **Unverifiable** — the repo does not settle it. **Your question was flawed, not their answer.**
     Discard it, do not score it, and do not silently count it against them.
   - Grade the **substance, not the vocabulary**. A right model in imprecise words is correct; the
     precise term is a note, not a deduction. Grading fluency instead of understanding is the most
     common way an assessment measures the wrong thing entirely.
   - Grade the **answer given**, not the answer you hoped for. If a different-but-correct reading
     of the code supports them, they are right and your expected answer was incomplete.
3. **Teach the miss, briefly.** On anything less than correct, show the code and the citation now —
   a miss is the moment the answer sticks. Two or three sentences, then move on. Do not slide into
   a full `teach-me` tour mid-quiz.
4. **Drill** — a wrong answer sets the topic for the next question. Ask the **same concept from a
   different angle**, not the same question reworded. Re-asking the identical question tests whether
   they remember the correction you just gave them, which is worth nothing. Two consecutive misses
   in one area → mark it **weak**, stop drilling it, and record it for `/teach-me`. Grinding an area
   they have not been taught is not assessment, it is attrition.
5. **Record** — append to `.wgm/learning/quiz-log.md`: question, tier, area, grade, citation. Enough
   that a fresh context can resume the assessment without re-reading this conversation.

**Anti-gaming rules:**
- An answer that only restates the question is **not** correct — it is unanswered. Say so and re-ask.
- "I don't know" is an honest answer. Record it as incorrect, credit the honesty in the report, and
  never punish it more harshly than a confident wrong answer. Punishing it teaches bluffing, which
  is precisely the habit that makes someone dangerous on-call.
- Never soften a grade to be encouraging. An inflated score is the one output of this skill that
  actively causes harm: it certifies someone as ready who is not.
- Never let the learner grade themselves. "Did I get that right?" is answered by the code.

**Stop conditions:** the current tier converged at or above the threshold (default **80**) and the
target tier is reached; or the question cap for the sitting is hit; or two or more areas are marked
weak — at which point the useful next step is `/teach-me`, not more questions.

## Phase 3 — Score & Report
Produce a short, honest report:

- **Score per tier (0–100)** and overall — computed from the recorded grades, not impressions.
  Partial credit counts as half. Discarded (unverifiable) questions are excluded from the
  denominator, never counted as failures.
- **Solid areas** — what they demonstrably know, with the questions that proved it.
- **Weak areas** — what they do not, stated plainly, each with the specific concept to revisit.
- **Dangerous gaps** — anything they were *confidently wrong* about. Call these out separately.
  A known unknown is a gap; a confident wrong belief is a future incident, and averaging the two
  into one number hides the more serious one.
- **Verdict** — one line: can this person safely make changes here yet? Answer it directly.
- **Next step** — `/teach-me deep: <weak area>` for each weak area, then `/quiz-me drill: <area>`
  to re-test. Name them concretely.

**Report-exit gate:**
- [ ] Every tier attempted has a score derived from recorded grades.
- [ ] Weak areas name a **concept**, not just a file.
- [ ] Confidently-wrong answers are reported separately from "I don't know."
- [ ] `.wgm/learning/quiz-log.md` is written so a later session can resume.
- [ ] The verdict is stated in one unhedged sentence.

## Tone
Direct, not cruel. This skill is named for grilling and it should feel like one — but the pressure
belongs on the *questions*, never on the person. Do not perform disappointment, and do not perform
enthusiasm either: unearned praise is just an inflated score delivered socially. State the grade,
show the code, ask the next question.

## Artifact safety (hard rules)
- Write **only** under `.wgm/learning/`. A quiz never modifies the project's code or documentation.
- Never share a person's scores or answers outside this session — not into an issue, a commit
  message, a report, or an external service. An assessment result is personal to the learner, and
  quietly publishing it is the fastest way to make the honest "I don't know" impossible.

## Cross-links
[`teach-me`](../teach-me/SKILL.md) (the companion that teaches what this tests) ·
[`wgm`](../../SKILL.md) (the build skill whose output most needs verifying) ·
[`references/grilling.md`](../../references/grilling.md) (the interview discipline, inverted here) ·
[`references/scoring.md`](../../references/scoring.md) (stratified tier convergence and thresholds) ·
[`references/scenarios.md`](../../references/scenarios.md) (the holdout principle this borrows).
