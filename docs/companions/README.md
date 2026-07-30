# Companion skills: teach-me and quiz-me

Two skills install alongside wgm and solve a problem wgm creates: **it can build software faster
than its operator can understand it.** You take delivery of a working repository and own code you
cannot explain.

`teach-me` closes that gap. `quiz-me` proves it actually closed.

## Executive overview

- **For:** anyone who owns a codebase they did not write line by line — whether an agent built it or
  a previous team did.
- **You'll get:** a cited map of the repository, a guided tour, one validated change you made
  yourself, and an honest score on what you actually retained.
- **Why two skills:** a tour produces the *feeling* of understanding. Only being tested distinguishes
  that feeling from the real thing.
- **Watch out:** neither skill modifies your code. The single exception is `teach-me`'s first-change
  exercise, which is reverted by default.
- **Next:** [Get started](../get-started/README.md) if wgm itself is not installed yet.

## When to use which

| Situation | Use |
|---|---|
| wgm just built something and you need to understand it | `/teach-me`, then `/quiz-me` |
| You are adopting an unfamiliar repository | `/teach-me` |
| You are returning to a project after months away | `/teach-me recap`, then `/quiz-me` |
| You are about to go on call for a service | `/quiz-me` |
| You want to know if a teammate can safely change this code | `/quiz-me` |
| You have one narrow question about one function | Neither — just look it up |
| You want the code changed | Neither — that is `/wgm` |

## teach-me

```
/teach-me [MODE] [only] [FOCUS]
```

Runs `Triage → Map → Tour → Deep dive → First change → Recap`.

| Invocation | Behavior |
|---|---|
| `/teach-me` | Full lifecycle over the whole repository |
| `/teach-me FOCUS` | Full lifecycle, scoped to that area |
| `/teach-me map only` | Build the cited map, then stop |
| `/teach-me tour only` | Guided walkthrough from an existing map |
| `/teach-me deep: the retry logic` | One area, down to its invariants and edge cases |
| `/teach-me change` | Only the validated first-change exercise |
| `/teach-me recap` | Re-read the artifacts and re-summarize; no new exploration |

### The rule that makes it trustworthy

**Cite or don't claim.** Every factual statement about your repository carries a `path:line`
citation. A convention needs **two or more** citations from different files, because one occurrence
is an instance, not a convention.

When the repository cannot answer something, `teach-me` says *"not answerable from the repo"* and
records it as an open question rather than inventing plausible architecture.

**Note:** It also **runs** your build and test commands rather than repeating what your README
claims. Stale build instructions are among the most common defects in any repository, and a tour
that trusts them teaches you something false on day one.

### The first-change exercise

The tour ends by having you make a small, real, **validated** change — then revert it. Understanding
that has never touched the code is untested.

If your project has no validation signal at all, that finding is the most valuable thing the session
produced. `teach-me` will say so plainly and point you at `/wgm` to create one.

## quiz-me

```
/quiz-me [MODE] [only] [FOCUS]
```

Runs `Triage → Calibrate → Quiz(Ask → Grade → Drill) → Score → Report`.

| Invocation | Behavior |
|---|---|
| `/quiz-me` | Full lifecycle, converging tier by tier |
| `/quiz-me FOCUS` | Scoped to one area |
| `/quiz-me warmup only` | A few questions to locate your level |
| `/quiz-me drill: error handling` | Repeated questions on one weak area until it converges |
| `/quiz-me exam` | A scored, no-hints run across all tiers |
| `/quiz-me review` | Report past scores and gaps; ask nothing new |

### Difficulty tiers

| Tier | Tests | A miss means |
|---|---|---|
| 1 — Orientation | What it is, how to run it, where execution starts | Go back to `/teach-me`; more questions will not help |
| 2 — Working knowledge | Data flow, error handling, what a change would touch | You cannot yet safely make a change here |
| 3 — Mastery | Invariants, failure modes, "what breaks if…" | You can change it, but not extend it confidently |

Tiers converge in order, so a pile of easy passes cannot mask a broken tier 3.

### What makes the score mean something

**Questions are held out.** `quiz-me` draws from what the tour did *not* literally show you —
consequences rather than displayed lines, and questions that require combining two places in the
codebase. Answering from memory of a single screen measures recall, not understanding.

**Grading is against the code, with citations.** Not against the grader's impression. A right model
in imprecise words is correct; the precise term is a note, not a deduction.

**Confidently wrong is reported separately from "I don't know."** These are not the same finding:
one is a gap, the other is a future incident. Averaging them into a single number hides the more
serious one.

**Caution:** The skill will not soften a grade to be encouraging. An inflated score is the one
output that actively causes harm — it certifies someone as ready who is not.

## Artifacts

Both skills write only under `.wgm/learning/`:

| File | Contents |
|---|---|
| `.wgm/learning/MAP.md` | The cited repository map: what it is, how to run it, entry points, shape, data, conventions, invariants, open questions |
| `.wgm/learning/progress.md` | What the tour covered and what it deferred |
| `.wgm/learning/quiz-log.md` | Every question, tier, area, grade, and citation |

Because these persist, a later session resumes instead of re-surveying, and `quiz-me` can start from
your weakest recorded area.

**Note:** Quiz results are personal to the learner. The skill never publishes them into an issue,
commit message, or external service — quietly publishing a score is the fastest way to make an
honest "I don't know" impossible.

## A worked sequence

```bash
# 1. Understand what you now own.
/teach-me

# 2. Find out what actually stuck.
/quiz-me

# 3. Drill whatever the report flagged weak.
/teach-me deep: the retry logic
/quiz-me drill: the retry logic

# 4. Fix what the tour exposed — stale docs, a red suite, a missing gate.
/wgm add a regression test for the retry backoff
```

Step 4 matters. Learning a repository is one of the better ways to find its bugs, and the finding is
wasted if it stops at "noted."

## Installing or skipping the companions

They install automatically alongside wgm as sibling skill directories. To skip them:

```bash
./scripts/install.sh --no-companions          # bash
./scripts/install.ps1 -NoCompanions           # PowerShell
```

They live in `companions/teach-me/` and `companions/quiz-me/` in this repository, and install to
`SKILLS_DIR/teach-me` and `SKILLS_DIR/quiz-me`.

**Note:** They must be siblings of `wgm`, not nested inside it, because a skills client discovers one
skill per directory. A companion nested under `wgm/` would be invisible.

## What to do next

- [Get started](../get-started/README.md) — install wgm and the companions.
- [Installers reference](../reference/cli-install.md) — the `--no-companions` flag and install targets.
- [Troubleshooting](../operator/troubleshooting.md) — if a companion does not appear.
