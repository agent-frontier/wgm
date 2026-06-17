# Contributing to wgm

Thanks for your interest in improving **wgm**. It's a portable [Agent Skill](https://agentskills.io):
a single `SKILL.md` protocol at the repo root, supported by `references/`, `assets/`, `scripts/`, and
`docs/`. Contributions that sharpen the lifecycle, the backpressure discipline, or the docs are very
welcome.

## Ground rules

- **`SKILL.md` is the protocol.** Keep it operational and lean (target ≤ ~500 lines). Push theory,
  rationale, and long-form detail into `references/`.
- **Docs are split by audience.** `docs/operator/` is for people running wgm; `docs/agent/` is for
  the agent's own behavior. Prefer **Mermaid** diagrams for flows.
- **Never let the doc/install checks go red.** They are the project's deterministic backpressure —
  the same idea wgm preaches.
- **Don't clobber `AGENTS.md`.** wgm's own artifact-safety rules apply to this repo too.

## Dev prerequisites

| Tool | Used for |
|---|---|
| `bash`, [`shellcheck`](https://www.shellcheck.net/) | shell scripts + lint |
| `pwsh` (PowerShell 7+) | the Windows installer + its test harness |
| `python3` + `pip` | `skills-ref` (skill validator) |

Install the validator once:

```bash
pip install "git+https://github.com/agentskills/agentskills.git#subdirectory=skills-ref"
```

## The backpressure suite (run before every PR)

These are exactly what CI runs. All must be green:

```bash
shellcheck scripts/*.sh                      # lint
for s in scripts/*.sh; do bash -n "$s"; done  # shell syntax
( cd .. && skills-ref validate wgm )          # skill is valid (run from the parent dir)
bash scripts/check-docs.sh                    # docs structure, links, mermaid, placeholders
bash scripts/test-install.sh                  # bash installer harness (9 cases)
bash scripts/test-loop.sh                     # loop.sh limits + resilience + metrics harness (16 cases)
pwsh -File scripts/test-install.ps1           # PowerShell installer harness (5 cases)
actionlint                                    # lint .github/workflows/*.yml (CI: lint.yml)
```

> `skills-ref validate wgm` must be run from the **parent** directory, because the validator requires
> the skill folder's basename to equal the skill name (`wgm`).

## Making a change

1. Fork and branch from `main`.
2. Make the change; keep edits surgical and scoped.
3. Run the full backpressure suite above — get it green.
4. Open a PR using the template. Describe the change and note which checks you ran.
5. CI must pass before merge — both `.github/workflows/ci.yml` (validation) and
   `.github/workflows/lint.yml` (actionlint).

## Reporting bugs & ideas

Use the issue templates (bug report / feature request). For anything security-sensitive, follow
[`SECURITY.md`](SECURITY.md) instead of opening a public issue.

## Learning from users

If you want wgm to learn from a failure pattern or a surprising outcome, please use the
`Heuristic / learning report` issue template. Share only sanitized traces, and include enough
context that maintainers can turn the report into a better heuristic, doc note, or holdout scenario.
This is the path we should use for our own dogfood runs too.

Durable, cross-project lessons graduate into [`references/heuristics.md`](references/heuristics.md) —
wgm's curated juice ledger — and from there into the protocol. See the
[growth flywheel](docs/plans/2026-06-16_GROWTH_LOOP.md) and
[`references/self-improvement.md`](references/self-improvement.md) for how a report becomes a durable
upgrade.

By contributing, you agree your contributions are licensed under the project's [MIT License](LICENSE).
