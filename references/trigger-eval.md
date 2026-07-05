# Trigger eval — should this query invoke wgm?

A small, hand-curated fixture of example queries paired with the verdict `SKILL.md`'s own
"Invocation & modes," "Use this when," and "Do NOT use this when" sections should produce. It exists
to catch **trigger drift**: a future edit to the frontmatter `description:`, the mode-parsing rule,
or the use/don't-use bullets that silently widens or narrows when wgm activates. This is the
"skill-behaviour eval" watchlist item from [`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`](../docs/plans/2026-06-16_RALPH_LANDSCAPE.md)
(after [agent-skills-eval](https://github.com/darkrishabh/agent-skills-eval) and Anthropic's
"test with real usage").

## How to use this
- **When editing `SKILL.md`'s frontmatter `description:`, "Use this when," "Do NOT use this when,"**
  **or the mode-parsing rule in "Invocation & modes":** re-check every row below still holds. A row
  whose verdict would flip is a signal the edit changed the trigger boundary — intentional or not.
- **A mode-parsing-rule edit must also re-check `evals/evals.json`.** Two of its seed cases
  (`trivial-edit-no-trigger`, `mode-vs-request-disambiguation`) intentionally mirror this file's rows
  13 and 5 respectively (see `references/evals.md`'s "What's in `evals/evals.json`"). Neither
  `scripts/check-docs.sh` nor `scripts/check-evals.sh` checks cross-file agreement — both only
  validate structure/schema within their own file — so a mode-parsing edit that flips one of those
  rows' verdict but skips its mirrored `evals.json` case is a silent semantic-divergence risk.
- **This is a fixture for a host/LLM to judge against, not a script wgm runs itself** — no live
  agent-skill host is available inside this repo to actually invoke the skill-selection classifier.
  Treat each row as a structured example a maintainer (or a future automated judge, per the
  LLM-as-judge pattern in `references/scoring.md`) can grade the current `SKILL.md` text against.
- **If/when a live host is available, this table can be mechanized:** convert the rows to a JSON
  array of `{"query":"...","should_trigger":true|false}` and run it through
  [`anthropics/skills`' `skill-creator/scripts/run_eval.py`](https://github.com/anthropics/skills/tree/main/skills/skill-creator).
  That harness runs `claude -p` queries in parallel, detects triggering early from stream-JSON
  `content_block_start` tool-use events (`Skill` / `Read`), repeats each query three times by
  default for stochasticity, and in a Claude Code environment strips `CLAUDECODE` before spawning
  the nested CLI. That is how this *could* be executed here later; it is not wired up now.
- **Structural backpressure that *does* run today:** every row must have all four columns filled in
  (no blank `Mode`/`Reason`), and `TRIGGER` rows must name a mode while `NO-TRIGGER` rows must not —
  see the validation command below.

## Should-trigger (wgm activates)

| # | Query | Verdict | Mode | Reason |
|---|---|---|---|---|
| 1 | "Build a REST API for a todo app with auth" | TRIGGER | full lifecycle | Feature/app from rough intent — "Use this when" #1 |
| 2 | "I need a dark-mode toggle for my app, built from scratch" | TRIGGER | full lifecycle | Feature from rough intent — "Use this when" #1 |
| 3 | "Implement a multiplayer lobby system for my game — plan it out first" | TRIGGER | full lifecycle | Multi-step work benefiting from a plan + iteration — "Use this when" #2 |
| 4 | "Prototype a CLI tool that scaffolds new microservices" | TRIGGER | full lifecycle | Prototype from rough intent — "Use this when" #1 |
| 5 | "/wgm build the auth module" | TRIGGER | full lifecycle (not `build` mode) | "build" is followed by more request text, not end-of-input/`only`/`:` — the explicit disambiguation example in "Invocation & modes" rule 2 |
| 6 | "/wgm grill only" | TRIGGER | `grill` (single-phase, hard-stop) | Recognized mode keyword + `only` — rule 1 |
| 7 | "/wgm plan: add OAuth login" | TRIGGER | `plan` (scoped by `:`) | Recognized mode keyword + `:` separator — rule 6 |
| 8 | "/wgm build" | TRIGGER | `build` (resumes existing plan) | Recognized mode keyword at end-of-input — rule 1 |
| 9 | "/wgm analyze only" | TRIGGER | `analyze` (single-phase, hard-stop) | Recognized mode keyword + `only` — rule 1 |
| 10 | "/wgm review" | TRIGGER | `review` (single-phase, hard-stop) | Recognized mode keyword at end-of-input — rule 1 |
| 11 | "build" (bare, no further text) | TRIGGER | `build` mode | Recognized mode keyword at end-of-input — rule 1, distinct from row 12 |
| 12 | "build a house for my cat game" | TRIGGER | full lifecycle (not `build` mode) | "build" followed by more request text — same disambiguation as row 5 |

## Should-NOT-trigger (wgm stays out of the way)

| # | Query | Verdict | Mode | Reason |
|---|---|---|---|---|
| 13 | "Fix the typo in line 42 of README.md" | NO-TRIGGER | — | Trivial one-file edit — "Do NOT use this when" #1 |
| 14 | "Why is this function returning undefined?" | NO-TRIGGER | — | Pure debugging of a specific bug — "Do NOT use this when" #2 |
| 15 | "Explain how this regex works" | NO-TRIGGER | — | Research-only, no build intent — "Do NOT use this when" #3 |
| 16 | "Rename this variable from x to count across these 3 files" | NO-TRIGGER | — | Trivial, unambiguous edit — "Do NOT use this when" #1 |
| 17 | "Here are the exact 5 steps to add this config flag: 1... 2... 3... 4... 5. Do them." | NO-TRIGGER | — | Complete, unambiguous instructions already given — "Do NOT use this when" #4 |
| 18 | "What's the difference between let and const in JS?" | NO-TRIGGER | — | Research-only / "explain this" — "Do NOT use this when" #3 |
| 19 | "Run the test suite and tell me which tests fail" | NO-TRIGGER | — | A single, already well-defined diagnostic action, no build intent |
| 20 | "Format this file with prettier" | NO-TRIGGER | — | Trivial formatting-only change — "Do NOT use this when" #1 |
| 21 | "What does this error message mean?" | NO-TRIGGER | — | Pure debugging / explain — "Do NOT use this when" #2/#3 |
| 22 | "Add a one-line copyright header to these files" | NO-TRIGGER | — | Trivial, unambiguous, small edit — "Do NOT use this when" #1 |

## Validation

```bash
# Every row has all 4 columns filled (no blank cells); TRIGGER rows name a mode, NO-TRIGGER rows don't.
awk -F'|' 'NR>4 && NF>=6 {
  verdict=$4; mode=$5; gsub(/^[ \t]+|[ \t]+$/,"",verdict); gsub(/^[ \t]+|[ \t]+$/,"",mode);
  if (verdict=="TRIGGER" && mode=="—") { print "FAIL: row missing mode: " $0; bad=1 }
  if (verdict=="NO-TRIGGER" && mode!="—") { print "FAIL: NO-TRIGGER row has a mode: " $0; bad=1 }
} END { exit bad }' references/trigger-eval.md && echo "trigger-eval structure: GREEN"
```

## Cross-links
[`SKILL.md`](../SKILL.md) ("Invocation & modes," "Use this when," "Do NOT use this when") ·
[`references/scoring.md`](scoring.md) (the LLM-as-judge pattern this fixture is designed to be graded
by) · [`references/evals.md`](evals.md) (the companion fixture: given wgm *does* trigger, is the
output good? — this file only grades whether it *should* trigger) ·
[`docs/plans/2026-06-16_RALPH_LANDSCAPE.md`](../docs/plans/2026-06-16_RALPH_LANDSCAPE.md) (the
watchlist item this closes) · [`docs/plans/2026-06-16_PLAN.md`](../docs/plans/2026-06-16_PLAN.md)
("also-ran candidates," where the ≈20-query shape was first scoped).
