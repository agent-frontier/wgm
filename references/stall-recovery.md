# Stall recovery — wonder / reflect & model escalation

The loop's default failure rule is blunt: "same task fails ~3 times → stop." Before giving up, run a
structured recovery borrowed from octopusgarden — **wonder** (diagnose wide), then **reflect** (fix
narrow) — and escalate the model only when cheap effort plateaus.

## Detecting a stall
A **stall** is any of:
- The satisfaction score (`references/scoring.md`) doesn't improve for ~2 consecutive iterations.
- The same task fails its backpressure ~2–3 times.
- The diff churns (edit / revert / edit) without moving a signal.

When you detect a stall, **stop generating** and recover.

## Wonder (diagnose — think wide)
A deliberately divergent pass. Do **not** write code. Step back and enumerate hypotheses for *why*
it's stuck, then rank them:
- Wrong abstraction or data model.
- Missing dependency, config, or environment/setup issue.
- Misread requirement or **misunderstood scenario expectation**.
- Flaky, wrong, or too-coarse validation signal.
- Task is too big to land in one iteration.

Output a short ranked diagnosis: the single **most likely** cause and the cheapest way to test it.

## Reflect (fix — think narrow)
A convergent, low-temperature pass. Take the top hypothesis and make the **smallest, most targeted
change** that addresses it — one surgical edit, or one corrected signal/scenario reading — then
**re-validate immediately**. Do not broaden scope, refactor, or fix unrelated things during reflect.
One hypothesis, one change, one re-check.

## Model escalation (cost-aware)
- Start on a **frugal/cheap model** for routine iterations.
- After ~**2** consecutive non-improving iterations, **escalate** to a stronger model — and/or run
  wonder/reflect on the stronger model — to break the stall.
- After ~**5** consecutive improving iterations, **downgrade** back to frugal to save cost.
- In a skill this is operator guidance; `scripts/loop.sh` exposes a frugal agent and an escalation
  agent (`WGM_FRUGAL_AGENT` + escalation) so a fresh-context loop can switch automatically.

## Where it slots in the loop
`Analyze → Implement → Validate → Review → (stall? wonder → reflect → re-Validate) → Record`.
Recovery happens after a failing Validate/Review on a stall, before you Record or stop.

## Hard stop / regenerate
If wonder/reflect plus escalation still don't improve the signal after ~3 recovery cycles, **stop**:
record the blocker in `IMPLEMENTATION_PLAN.md` and regenerate the plan or ask the human. Regenerating
the plan is cheap; a loop going in circles is not.

## Cross-links
`references/ralph-loop.md` · `references/scoring.md` · `scripts/loop.sh`
