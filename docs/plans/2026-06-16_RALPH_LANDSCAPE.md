# wgm vs the Ralph ecosystem — competitive landscape

**Date:** 2026-06-16 · **Source:** [awesome-ralph](https://github.com/snwfdhmp/awesome-ralph) (snwfdhmp)

> A companion to [the roadmap](2026-06-16_PLAN.md). That doc compared wgm to the spec-driven crowd
> (Spec Kit, BMAD, Superpowers…); this one tracks wgm against **the Ralph ecosystem itself** — the
> loop runners, orchestrators, and tool-specific implementations catalogued in `awesome-ralph`.
> "wgm vs the world." Re-run the survey periodically and refresh the table + watchlist.

## The one-line difference

Almost everything in `awesome-ralph` is a **loop runner** — a script or binary that re-invokes an
agent until a spec is met (`while :; do cat PROMPT.md | agent ; done`). **wgm is not (only) a
runner — it is a portable [Agent Skill](https://agentskills.io)**: a `SKILL.md` protocol any
compatible agent loads, *plus* an optional host-agnostic runner (`scripts/loop.sh`). So wgm competes
on **discipline** (grill → governed plan → holdout-judged loop), not on being one more loop.

## The ecosystem at a glance

**Methodology / playbooks**
- [how-to-ralph-wiggum](https://github.com/ghuntley/how-to-ralph-wiggum) — Huntley's official playbook (the source).
- [ralph-playbook](https://github.com/ClaytonFarr/ralph-playbook) — methodology, diagrams, "signs and gates".

**Orchestrators and standalone runners**
- [ralph-orchestrator](https://github.com/mikeyobrien/ralph-orchestrator) — Rust; 7 backends; Hat-System personas; TUI.
- [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) — exit detection, rate limiting, circuit breaker.
- [choo-choo-ralph](https://github.com/mj-meyer/choo-choo-ralph) — Beads-powered 5-phase workflow; compounding knowledge.
- [smart-ralph](https://github.com/tzachbon/smart-ralph) — spec-driven (research / requirements / design / tasks).
- [ralph-starter](https://github.com/rubenmarcus/ralph-starter) — GitHub/Linear/Notion integrations; presets; **cost tracking**.
- [snarktank/ralph](https://github.com/snarktank/ralph) — PRD-driven; auto-branching; flowchart visualization.
- [iannuttall/ralph](https://github.com/iannuttall/ralph) — minimal file-based loop (codex/claude/droid/opencode).
- [nitodeco/ralph](https://github.com/nitodeco/ralph), [oh-my-ralph](https://github.com/vivganes/oh-my-ralph), [ralph-wiggum-bdd](https://github.com/marcindulak/ralph-wiggum-bdd) (BDD), [ml-ralph](https://github.com/pentoai/ml-ralph) (ML experiments).

**Tool-specific and multi-agent**
- [ralph-wiggum-cursor](https://github.com/agrimsingh/ralph-wiggum-cursor) — Cursor; token tracking; **context rotation at 80k**.
- [opencode-ralph-wiggum](https://github.com/Th0rgal/opencode-ralph-wiggum) — OpenCode; mid-loop context injection; **struggle detection**.
- [ralph for Copilot](https://github.com/aymenfurter/ralph) — VS Code extension; visual Control Panel; Progress Timeline.
- [ralph-tui](https://github.com/subsy/ralph-tui) — TUI orchestrator; task-tracker integration; interactive PRD.
- [Goose Ralph Loop](https://block.github.io/goose/docs/tutorials/ralph-loop/) — Block's Goose; **cross-model review**; recipes.
- [ralph-loop-agent](https://github.com/vercel-labs/ralph-loop-agent) — Vercel TS SDK; verification callbacks; **context summarization**.
- [multi-agent-ralph-loop](https://github.com/alfredolopez80/multi-agent-ralph-loop) — **parallel multi-agent** work streams.

## wgm vs representative projects

| Project | What it is | wgm's edge | What wgm could borrow |
|---|---|---|---|
| ralph-orchestrator | Rust runner; 7 backends; Hat personas; TUI | Portable `SKILL.md` (no binary); holdout judge; grill | A TUI / dashboard; richer per-persona dispatch |
| ralph-claude-code | Claude loop: exit detection, rate-limit, circuit breaker | Host-agnostic; governance stack | **Circuit-breaker** beyond idle-timeout; rate-limit handling |
| choo-choo-ralph | Beads 5-phase; compounding knowledge | Holdout judging; one-file portability | **Beads-style** structured knowledge (vs flat `memories.md`) |
| ralph-starter | CLI; GitHub/Linear/Notion; presets; cost tracking | Skill + judge; governed plan | **Cost / token tracking**; task-tracker integrations |
| ralph-wiggum-cursor | Cursor; token tracking; context rotation at 80k | Runs on any agent, not just Cursor | **Context rotation / summarization** at a token threshold |
| opencode-ralph-wiggum | OpenCode; mid-loop injection; struggle detection | Holdout judge; governance | **Struggle detection** (auto stall trip) |
| Goose Ralph Loop | Cross-model review; recipes | Two-stage subagent review already shipped | Cross-**model** (not just role) review |
| multi-agent-ralph-loop | Parallel multi-agent streams | Sequenced subagent roles + backpressure | **Parallel worktree** loops |

## Where wgm sits

```mermaid
quadrantChart
  title wgm vs the Ralph ecosystem
  x-axis Plain loop --> Governed and holdout-judged
  y-axis Standalone runner --> Portable Agent Skill
  quadrant-1 Governed and portable
  quadrant-2 Portable, light process
  quadrant-3 Standalone, light
  quadrant-4 Standalone, governed
  wgm: [0.9, 0.92]
  ralph-orchestrator: [0.58, 0.18]
  choo-choo-ralph: [0.72, 0.26]
  smart-ralph: [0.62, 0.32]
  ralph-claude-code: [0.44, 0.22]
  ralph-starter: [0.4, 0.34]
  Goose Ralph: [0.52, 0.24]
```

## Read-out

- **Where wgm is alone:** the only entrant that is a **portable Agent Skill** (loads into Copilot,
  Claude, Codex, Cursor…) rather than a standalone runner, and the only one pairing deterministic
  backpressure with **holdout-scenario LLM judging** (anti-reward-hacking). Its **grill** interview
  and **governance stack** (constitution · consistency gate · no-placeholder · scale-adaptive
  tracks · two-stage subagent review) run deeper than the ecosystem norm.
- **Where wgm already matches the field:** fresh-context loop, signs and gates, `wgm.yml`
  backpressure gates, loop limits (runtime / idle / checkpoint), memories, model escalation, and a
  host-agnostic `loop.sh`.
- **Watchlist (borrow next):** cost / token tracking (ralph-starter, cursor) · context
  rotation / summarization at a token threshold (cursor at 80k, vercel) · automated struggle /
  circuit-breaker detection (opencode, ralph-claude-code) · task-tracker integrations
  (Linear / Notion / GitHub) · a TUI / dashboard · Beads-style structured knowledge
  (choo-choo-ralph) · parallel multi-agent worktrees (multi-agent-ralph-loop).

## How this was tracked
Surveyed from [awesome-ralph](https://github.com/snwfdhmp/awesome-ralph) on 2026-06-16. The
positioning is qualitative (a read of each project's README), meant to be re-run and refreshed as
the ecosystem moves — not a precise score.
