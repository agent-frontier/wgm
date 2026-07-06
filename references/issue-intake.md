# Issue intake — backlog discovery and tracker traceability

wgm already knows how to turn a request into a plan and a loop. This note adds one missing input
channel: a project's own GitHub Issues. The discipline is generic to any repo wgm is building in,
with `agent-frontier/wgm` as the first dogfood case, and it keeps issue handling attached to the
existing lifecycle rather than inventing a parallel system.
In projects that enable the Hive Growth Loop via `.github/wgm-hive.yml`, this same discovery-and-traceability discipline is also one of the four capture channels described in [`self-improvement.md`](self-improvement.md).

## Scope

This capability has **two distinct sub-behaviors** and they should not be conflated:

1. **Backlog discovery** — when wgm starts with **no explicit request**, Triage may look at the
   project's open issues and choose a candidate `<request>` to work on next.
2. **Traceability linking** — once a request is already known, Plan may link it to a matching open
   issue so the work stays connected to an upstream tracker.

The first behavior is about **finding work**. The second is about **anchoring known work**. An
explicit user request always wins over backlog discovery; issue intake is an extra source of work,
not silent replacement of the user's ask.

## Backlog discovery (Triage only, and only when no request was given)

`../SKILL.md` Phase 0 already says that **no input** means "operate on the current conversation
context; begin at Triage." When that context does **not** already name a concrete request, and the
repo has a GitHub remote, Triage may treat the issue backlog as a candidate source for the next
`<request>`.

Use the project's open issues as input with `gh issue list`. This is a **candidate-source**
heuristic, not a mandate:

- Reach for it only when there is **no explicit request** to honor.
- Skip it when the repo is not connected to GitHub, when `gh` cannot address the host repo, or when
  the current context already identifies a task clearly enough.
- Treat the chosen issue as the seed request for Grill/Plan, not as permission to skip those phases.

In other words: issue intake helps wgm decide **what to work on next** when nobody already told it.
It does **not** let wgm override a live instruction with whatever happens to be open in the backlog.

## Traceability linking (once the request is known)

Once a request exists — whether it came from the user directly or from backlog discovery — search
the open issues for one that clearly matches the task at hand. If a match is found:

- treat that issue's **title + body** as the authoritative tracker context for acceptance criteria,
  scope, and edge cases;
- record the issue number in the task's existing **`tracker reference`** field in
  `IMPLEMENTATION_PLAN.md`; and
- keep the task wording and the tracker reference aligned so a fresh agent can see the relationship
  without transcript archaeology.

This is not a new artifact and not a new field. It is a stricter use of the traceability hook that
already exists in [`artifacts.md`](artifacts.md): the task's `tracker reference` becomes the durable
link back to the upstream issue.

## Prioritization when the backlog has several open issues

When backlog discovery surfaces multiple plausible issues, use a simple, explicit heuristic:

1. **Prioritize by label first.** In a repo using the standard labels already common here, prefer
   actionable product work before softer inquiry: `bug` before `enhancement` before `question`.
   Other existing labels refine that picture, not replace it: `documentation` is still actionable,
   `learning` is valid but specialized, and `invalid` / `wontfix` are not candidates to pick up as
   new implementation work.
2. **Break ties by age.** All else equal, take the **oldest** qualifying issue first.
3. **Respect the open-PR cap.** `ralph-loop.md` already says to cap concurrent open PRs at roughly
   **3–5**. Past that cap, the next iteration should not discover another net-new issue; it should
   become a **consolidation** task that helps land, merge, or rebase existing work instead.

This keeps issue intake aligned with Ralph's throughput rule: merged value beats an ever-growing
stack of new branches.

## Linking and auto-closing convention

If a task's `tracker reference` names a GitHub issue, carry that linkage forward into the eventual
commit message or PR description with **`Closes #N`** or **`Fixes #N`**.

That convention matches the repo's existing practice and the PR template's Summary guidance. Its
effect is intentional:

- merging the human-reviewed PR auto-closes the linked issue;
- no separate `gh issue close` call is needed; and
- auto-closing the issue does **not** imply auto-merge of the PR.

The human still reviews and merges the change. The issue closes only as a side effect of that
approved merge.

## Relationship to `[learn]` issues

[`self-improvement.md`](self-improvement.md)'s Report → Self-optimize → Promote pipeline is **not a
separate competing issue system**. It is a **specialized subset** of this same discovery +
traceability discipline.

A `learning`-labelled `[learn]` issue is simply one particular kind of backlog item:

- it can be **discovered** the same way other open issues are discovered;
- it can be **linked** the same way other work is linked through `tracker reference`; and
- it still flows through the existing self-improvement promotion path because its content is about
  improving wgm itself.

The general rule is: all issues enter through one intake discipline; `[learn]` issues just have an
extra downstream graduation path once they land.

## Lifecycle attachment points

Attach the behavior to the existing lifecycle at four points:

- **Triage (Phase 0)** — backlog discovery may supply the next `<request>`, but only when there was
  no explicit request already.
- **Plan (Phase 2)** — record the matched issue in the task's `tracker reference` field in
  `IMPLEMENTATION_PLAN.md`.
- **Loop / Record (Phase 3, step 5)** — preserve the tracker linkage in the iteration's recorded
  outcome so the eventual commit/PR can carry `Closes #N` / `Fixes #N`.
- **Ship / Handoff (Phase 4)** — include the closing keyword in the commit message or PR
  description that ships the task.

This keeps issue intake inside the current state machine instead of bolting on a side workflow.

## Cross-links
[`../SKILL.md`](../SKILL.md) (Phase 0 Triage · Phase 2 Plan · Phase 3 Record · Phase 4 Ship/Handoff) ·
[`artifacts.md`](artifacts.md) (`tracker reference` and plan-task fields) ·
[`ralph-loop.md`](ralph-loop.md) (concurrent-PR cap and consolidation heuristic) ·
[`self-improvement.md`](self-improvement.md) (`[learn]` issues as the specialized subset) ·
[`subagents.md`](subagents.md) (`wgm-hermes`, the courier that also draws on this source).
