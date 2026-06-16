# Stall recovery — wonder / reflect & model escalation

The loop's default failure rule is blunt: "same task fails ~3 times → stop." Before giving up, run a
structured recovery borrowed from octopusgarden — **wonder** (diagnose wide), then **reflect** (fix
narrow) — and escalate the model only when cheap effort plateaus.

## Detecting a stall (struggle signals)
A **stall** is any of these *struggle signals* — treat them as an automatic trip into recovery, not a
soft hint:
- The satisfaction score (`references/scoring.md`) doesn't improve for ~2 consecutive iterations.
- The same task fails its backpressure ~2–3 times.
- The diff churns (edit / revert / edit) without moving a signal.
- The same tool or setup error repeats (a missing dependency, an env issue, a flaky command).

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

## Destabilizing fix while unattended → preserve, revert, hand off
Sometimes the *correct* fix makes things temporarily worse: a test goes red, or it **exposes a
deeper latent fault** (enabling real behaviour reaches code paths that were previously dead). If you
**cannot fully validate it right now** — you're unattended, it needs human sign-off, or it carries
save-format / data-migration risk — do **not** ship a red suite and do **not** paper over it with a
guess. Instead:
- **Preserve** the work on a clearly-named WIP branch (push it) and/or a patch artifact, so nothing
  is lost.
- **Revert** the working tree to the last green baseline; re-run the suite to confirm it's green
  again.
- **Hand off** with a precise root-cause note: what's *proven* to work, what's broken, the **exact
  repro**, and the **acceptance test** that will confirm the eventual fix.

A separate **low-risk hardening track** (e.g. defensive bounds-guards), validated by that *same*
acceptance test, often de-risks or outright unblocks the high-risk fix on the next pass. This keeps
the headline progress (the work exists, reviewable) without trading away a stable, shippable
baseline. See [`hard-to-test-domains.md`](hard-to-test-domains.md).

## Where it slots in the loop
`Analyze → Implement → Validate → Review → (stall? wonder → reflect → re-Validate) → Record`.
Recovery happens after a failing Validate/Review on a stall, before you Record or stop.

## Hard stop / regenerate
If wonder/reflect plus escalation still don't improve the signal after ~3 recovery cycles, **stop**:
record the blocker in `IMPLEMENTATION_PLAN.md` and regenerate the plan or ask the human. Regenerating
the plan is cheap; a loop going in circles is not.

## Cross-links
`references/ralph-loop.md` · `references/scoring.md` · `references/hard-to-test-domains.md` · `scripts/loop.sh`
