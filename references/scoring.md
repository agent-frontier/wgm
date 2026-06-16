# Scoring — preflight readiness & satisfaction (LLM-as-judge)

wgm steers with **deterministic backpressure** (a runnable pass/fail check). Scoring *augments* that
with LLM-as-judge rubrics where a binary signal can't capture quality: a **preflight** readiness
score before the loop, and a **satisfaction** score during the loop. Neither replaces backpressure —
deterministic checks remain the hard gate for "done."

## Why probabilistic, not boolean
A holdout scenario graded pass/fail invites gaming and hides partial progress. A **0–100
satisfaction** score (borrowed from octopusgarden) is the probability that observed behavior
satisfies an expectation. It gives the loop a gradient to climb and resists reward-hacking, because
the generator never sees the scenarios it is graded on.

## Preflight readiness (gate before the loop)
Before the first build iteration, score the plan's readiness 0–100 across:
- **Goal/JTBD clarity** — is the job and its user unambiguous?
- **Observable success criteria** — can "done" be seen, not just asserted?
- **Scenario coverage** — do scenarios exercise the spec's demo path and magic moment?
- **Backpressure mapping** — is each acceptance criterion tied to a runnable check?
- **Scope edges** — are non-goals stated?

Recommend a **readiness threshold ≥ 80**. Below it, do not start building: return to Grill/Plan and
fix the weakest dimension first. This is the **Preflight gate** between Plan and Loop.

## Satisfaction scoring (during Validate/Review)
For each scenario **step**, the judge assigns a **0–100** score — not pass/fail — given:
1. the step's `expect` (from the holdout scenario), and
2. the observed output/behavior of the running implementation.

Aggregate: step scores → **scenario score** (mean, or min for strictness) → **overall score** (mean
across scenarios, optionally tier-weighted). **Converge** when the overall score ≥ the **threshold
(default 95)** and every deterministic check is green.

### Running the judge
Use a tight, structured judge prompt, separate from the generator:

```
You are grading one acceptance step. Output {score: 0-100, why: <one line>}.
Expectation: <step.expect>
Observed:    <captured output / HTTP response / terminal state>
Score how fully the observed behavior satisfies the expectation.
```

Keep the generator and judge **separate** (the generator must never see scenarios). Record the judge
prompt, the score, and the one-line justification — and accept that scores vary run to run.

## Stratified convergence
Grade by ascending **tier** (`references/scenarios.md`): bring tier-1 scenarios to threshold before
admitting tier-2, then tier-3. This stops easy passes from masking hard failures and focuses each
phase of the loop on the next real gap.

## Recording
- Per-iteration: note the overall score, per-tier scores, and the weakest scenario in
  `IMPLEMENTATION_PLAN.md`.
- Keep an append-only `.wgm/scores.md` (iteration · tier · score · note) so a fresh agent sees the
  numeric trajectory; record the *prose* lesson behind a jump or drop in `.wgm/memories.md`
  (`references/artifacts.md`).

## When the score stalls
A flat or falling score across ~2 iterations is a **stall**: stop adding code and switch to
**wonder/reflect** plus model escalation — see `references/stall-recovery.md`.

## Cross-links
`references/scenarios.md` · `references/stall-recovery.md` · `references/validation-env.md` ·
`references/ralph-loop.md`
