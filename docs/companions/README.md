# Companion skills: teach-me, quiz-me, and rugged

Three skills install alongside wgm. Two solve a problem wgm creates: **it can build software faster
than its operator can understand it.** You take delivery of a working repository and own code you
cannot explain. The third solves a different problem: a plan or diff can look sound and still be
built for operators and conditions that don't exist.

`teach-me` closes the understanding gap. `quiz-me` proves it actually closed. `rugged` checks
whether the result — or the plan for it — actually holds up in the field.

## Executive overview

- **For:** anyone who owns a codebase they did not write line by line, or anyone about to build or
  ship something and wants to know if it will survive its real operators and environment.
- **You'll get:** from `teach-me`/`quiz-me` — a cited map, a guided tour, a validated change, and an
  honest score on what you retained. From `rugged` — one unhedged verdict (RUGGED, FRAGILE, or
  UNKNOWN) on whether a design holds up, plus the single highest-leverage next action.
- **Why three skills:** a tour produces the *feeling* of understanding; only being tested
  distinguishes that feeling from the real thing. Separately, a design can pass every test its
  authors thought of and still fail its actual operators — that needs a dedicated, read-only check.
- **Watch out:** none of the three modify your product code. `teach-me`'s one exception (the
  first-change exercise) is reverted by default; `rugged` writes only under `.wgm/rugged/`.
- **Next:** [Get started](../get-started/README.md) if wgm itself is not installed yet.

## When to use which

| Situation | Use |
|---|---|
| wgm just built something and you need to understand it | `/teach-me`, then `/quiz-me` |
| You are adopting an unfamiliar repository | `/teach-me` |
| You are returning to a project after months away | `/teach-me recap`, then `/quiz-me` |
| You are about to go on call for a service | `/quiz-me` |
| You want to know if a teammate can safely change this code | `/quiz-me` |
| A plan, spec, or diff claims something will "just work" | `/rugged` |
| You suspect a design is over-built for an idealized deployment | `/rugged` |
| You want a second opinion before building, not just after | `/rugged plan` |
| You have one narrow question about one function | Neither — just look it up |
| You want the code or design changed | Neither — that is `/wgm` |

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

## rugged

```
/rugged MODE [scope]
```

Runs `Triage → Context → Bottleneck decomposition → Simplify → Field test → Verdict`. Unlike
`teach-me`/`quiz-me`, it is **read-only**: it never edits product code or docs, and it judges
robustness rather than comprehension.

| Invocation | Behavior |
|---|---|
| `/rugged review [scope]` | Full lifecycle end to end; ends at Verdict. Default when no mode word matches. |
| `/rugged plan [scope]` | Judges whether a request/spec/plan is rugged enough to build, before anything exists to test. |
| `/rugged stress [scope]` | Focuses on Field test: names the deterministic evidence required and checks what's actually offered. |
| `/rugged recap` | Re-reads past verdicts and open gaps from `.wgm/rugged/`; no new exploration. |

It names the **actual** operators and environment a design will run in — not the idealized ones a
plan quietly assumes — then decomposes expected failure into intrinsic design constraints, user
capacity, and operational stress, and asks what evidence would actually settle the question. It
always ends in exactly one unhedged verdict:

| Verdict | Means |
|---|---|
| **RUGGED** | Idealized assumptions are removed and every load-bearing claim has exact field/stress evidence (or, in plan mode, an exact validation design). The only passing verdict. |
| **FRAGILE** | It works only under idealized conditions, or carries components unjustified by the actual operators/environment. |
| **UNKNOWN** | The evidence needed to judge RUGGED vs. FRAGILE is missing. Treated as a blocking gap, never a soft pass. |

**Where the name comes from:** the skill's core distinction — intrinsic design vs. real user
capacity vs. operational stress — is a software-and-development-practice metaphor drawn from one
cited source. See [`companions/rugged/SKILL.md`](../../companions/rugged/SKILL.md) for the exact
citation and the full lifecycle; it is stated once there rather than repeated here.

**Not for:** getting a design fixed (that's `/wgm`, since `rugged` only names the problem and the
next action) or learning/being quizzed on a codebase (that's `teach-me`/`quiz-me`).

## Artifacts

`teach-me` and `quiz-me` write only under `.wgm/learning/`; `rugged` writes only under
`.wgm/rugged/`:

| File | Contents |
|---|---|
| `.wgm/learning/MAP.md` | The cited repository map: what it is, how to run it, entry points, shape, data, conventions, invariants, open questions |
| `.wgm/learning/progress.md` | What the tour covered and what it deferred |
| `.wgm/learning/quiz-log.md` | Every question, tier, area, grade, and citation |
| `.wgm/rugged/` | Each review's Context, Bottleneck decomposition, Field-test gaps, and Verdict, so `/rugged recap` resumes without re-deriving them |

Because these persist, a later session resumes instead of re-surveying, and `quiz-me` can start from
your weakest recorded area.

**`MAP.md` has a second reader.** wgm's Analyze step reads it when present, for the entry points,
structure, and invariants its deliberately narrow per-task read never builds. That makes the map
worth keeping current — and worth deleting rather than leaving stale, since a wrong map misleads
every later build. wgm never *generates* the map itself: surveying a repo mid-iteration would trade
the whole context budget for orientation, so it recommends `/teach-me` instead.

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

They live in `companions/teach-me/`, `companions/quiz-me/`, and `companions/rugged/` in this
repository, and install to `SKILLS_DIR/teach-me`, `SKILLS_DIR/quiz-me`, and `SKILLS_DIR/rugged`.

**Note:** They must be siblings of `wgm`, not nested inside it, because a skills client discovers one
skill per directory. A companion nested under `wgm/` would be invisible.

## What to do next

- [Get started](../get-started/README.md) — install wgm and the companions.
- [Installers reference](../reference/cli-install.md) — the `--no-companions` flag and install targets.
- [Troubleshooting](../operator/troubleshooting.md) — if a companion does not appear.
