# GitHub agent-skills & orchestrators landscape refresh

**Date:** 2026-10-28 · **Status:** adopted research · **Sources:** live GitHub queries across
[`topic:agentskills`](https://github.com/topics/agentskills),
[`topic:agent-skill`](https://github.com/topics/agent-skill),
[`topic:ralph-loop`](https://github.com/topics/ralph-loop), `SKILL.md` repositories, and
[`andyrewlee/awesome-agent-orchestrators`](https://github.com/andyrewlee/awesome-agent-orchestrators).

> A dated follow-up to [`2026-06-16_PLAN.md`](2026-06-16_PLAN.md),
> [`2026-06-16_RALPH_LANDSCAPE.md`](2026-06-16_RALPH_LANDSCAPE.md), and
> [`2026-07-08_SKILLOPT_ADOPTION.md`](2026-07-08_SKILLOPT_ADOPTION.md). Per
> [`references/self-improvement.md`](../../references/self-improvement.md)'s Cross-pollinate rules,
> every durable technique assimilated from this survey is also recorded with `external research`
> provenance in [`references/heuristics.md`](../../references/heuristics.md).

## Executive overview

- **Where the ecosystem moved:** the portable `SKILL.md` format ([agentskills.io](https://agentskills.io))
  and multi-agent worktree orchestrators have exploded. Alongside the original peer group
  ([`obra/superpowers`](https://github.com/obra/superpowers),
  [`mattpocock/skills`](https://github.com/mattpocock/skills),
  [`github/spec-kit`](https://github.com/github/spec-kit),
  [`mikeyobrien/ralph-orchestrator`](https://github.com/mikeyobrien/ralph-orchestrator)), a new wave
  of engineering-rigor skills and dark-factory runners has emerged — notably
  [`backnotprop/pstack`](https://github.com/backnotprop/pstack) (mirrored from `cursor/plugins/pstack`),
  [`affaan-m/ECC`](https://github.com/affaan-m/ECC),
  [`no-human-ai/no_human`](https://github.com/no-human-ai/no_human),
  [`naw103/foremerge`](https://github.com/naw103/foremerge),
  [`Keesan12/martin-loop`](https://github.com/Keesan12/martin-loop),
  [`umputun/ralphex`](https://github.com/umputun/ralphex),
  [`tzachbon/smart-ralph`](https://github.com/tzachbon/smart-ralph),
  [`0xNyk/council-of-high-intelligence`](https://github.com/0xNyk/council-of-high-intelligence), and
  [`github/gh-aw`](https://github.com/github/gh-aw).
- **Where wgm still leads:** wgm remains the only portable Agent Skill combining a relentless
  pre-code interview (`Grill`), a persistent plan + Ralph loop (`scripts/loop.sh` + `scripts/swarm.sh`),
  **blind holdout-scenario judging**, a mandatory **ruggedness gate** (`/rugged`), a **falsifiable
  harness portability contract** (`compatibility/harnesses.json`), and an offline, evidence-backed
  **Stage 10 memory & qualification layer** — all with zero third-party runtime dependencies.
- **What wgm gained from this pass:** seven surgical, zero-dependency protocol and harness upgrades
  closing gaps in test-tamper protection, cross-file swarm symbol collisions, eval-sandbox blinding,
  empirical probing during Grill, 5-rung evidence certainty in `/rugged`, mid-iteration pause/pickup,
  comparative benchmark sensitivity ("explain the number"), loop-tax telemetry, and ADR kill criteria.

## Peer comparison (2026-10 wave)

<!-- wgm: complete-table -->

| Project | What it is | Where wgm leads | What wgm assimilated |
|---|---|---|---|
| [`backnotprop/pstack`](https://github.com/backnotprop/pstack) | Rigorous engineering skills (`poteto-mode`, `blast-radius`, `eval`, `hillclimb`, `show-me-your-work`) | Holdout scenarios; deterministic `loop.sh`/`swarm.sh` + Stage 10 gates; single coherent state machine | **Empirical-probe vs. human-question** fork rule; **5-rung certainty ladder** in `/rugged`; **eval-sandbox blinding** in `grade-evals.sh`; **pause-safely & session-pickup** discipline; **explain-the-number** benchmark sensitivity |
| [`no-human-ai/no_human`](https://github.com/no-human-ai/no_human) | Local ticket-to-reviewed-PR dark factory with tamper guard and repro gate | Portable skill across 9 harnesses; holdout satisfaction scoring; Grill interview | **Test-tamper guard** (block deleted/skipped/weakened tests) and **base-vs-head bug-reproduction gate** |
| [`naw103/foremerge`](https://github.com/naw103/foremerge) | Pre-code semantic coordination protocol above Git for parallel worktree agents | Zero-binary portability; full lifecycle from Triage to Ship/Handoff | **Symbol/API-scope collision check** (`replace`/`delete` vs. `extend`/`call`) alongside file-ownership partitioning in swarms |
| [`Keesan12/martin-loop`](https://github.com/Keesan12/martin-loop) | Bounded loop controller with loop-tax auditing and run dossiers | Portable `SKILL.md` + companions (`teach-me`, `quiz-me`, `rugged`); Stage 10 offline qualification | **Retry / loop-tax ratio** in telemetry (`references/telemetry.md`) |
| [`0xNyk/council-of-high-intelligence`](https://github.com/0xNyk/council-of-high-intelligence) | Multi-persona deliberation skill with triads, duo debates, and kill criteria | Full build-and-validate loop; deterministic backpressure | Explicit **kill / reversal criterion** in `references/adr.md` and `assets/adr.template.md` |
| [`affaan-m/ECC`](https://github.com/affaan-m/ECC) | Large collection of 70+ agents and 300+ domain skills | Lean, cohesive 1-skill + 3-companion architecture with mutation-tested gates | Confirmed wgm's lean core + companion design over a 300-skill catalog |
| [`github/gh-aw`](https://github.com/github/gh-aw) | Markdown-to-GitHub-Actions compiler with read-only default and `safe-outputs` jobs | Interactive + local CLI portability; Stage 10 local authority envelopes | Confirmed wgm's Stage 10 authority separation and `wgm-hermes` fail-closed courier boundary |
| [`OthmanAdi/planning-with-files`](https://github.com/OthmanAdi/planning-with-files) | Manus-style file-backed planning with `attest-plan.sh`, monotonic progress guards, and prompt-injection quarantine | Full Ralph build loop; holdout scenarios; subagent swarm | **Monotonic `done`-count guard** in `scripts/loop.sh`; **untrusted-content quarantine** for auto-loaded plan/memory files; **no re-read after write + 2-action multimodal flush** |
| [`horizon-rust/horizon`](https://github.com/horizon-rust/horizon) | Clean-room Rust rewrite of Minecraft Java 26.3 verified by 324 differential harnesses | Portable skill across any domain/language | **Differential oracle harnesses** + `--changed` selector for ports/replacements; **scratch-home `HOME`/`XDG_*` isolation** for native/GUI runs |
| [`Fission-AI/OpenSpec`](https://github.com/Fission-AI/OpenSpec) | Spec-driven development with delta specs and change archiving | Autonomous loop + holdout judge + rugged gate | **Brownfield Delta Specs (`ADDED` / `MODIFIED` / `REMOVED`)** in `references/artifacts.md` and `assets/spec.template.md` |
| [`addyosmani/agent-skills`](https://github.com/addyosmani/agent-skills) | Production engineering skills (`doubt-driven-development`, `source-driven-development`) | External fresh-context loop (`loop.sh`); holdout scenarios | **High-blast-radius floor on Quick track** (`SKILL.md`); **lockfile version pin check** before framework/SDK code |
| [`wanshuiyin/Auto-claude-code-research-in-sleep`](https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep) | Cross-model adversarial review loops with decoupled `effort` and `assurance` axes | Deterministic software build/test gates; Stage 10 runner | **`same-family` vs. `cross-family` reviewer independence** provenance in `references/subagents.md` |

## Landed changes & provenance

1. **Test-tamper & bug-repro guard** (`no-human-ai/no_human`) — `SKILL.md` (Loop Validate step),
   `references/ralph-loop.md` (Backpressure in depth), `references/heuristics.md` (Backpressure),
   and `scripts/check-docs.sh` protocol contract.
2. **Symbol/API-scope collision check for parallel swarms** (`naw103/foremerge`) —
   `references/subagents.md` (Worktree swarm dispatch), `docs/operator/running-the-loop.md`
   (Planning a swarm well), `references/heuristics.md` (Swarm & parallelism), and
   `scripts/check-docs.sh`.
3. **Empirical probe before asking in Grill** (`backnotprop/pstack` + `tzachbon/smart-ralph`) —
   `SKILL.md` (Phase 1 — Grill), `references/grilling.md` (Rules + Anti-patterns),
   `references/heuristics.md` (Triage & Grill), and `scripts/check-docs.sh`.
4. **Five-rung certainty ladder for field/safety claims** (`backnotprop/pstack` `blast-radius`) —
   `companions/rugged/SKILL.md` (Phase 5 — Field test), `references/heuristics.md` (Review), and
   `scripts/check-docs.sh`.
5. **Anti-gaming eval sandbox blinding** (`backnotprop/pstack` `eval.md`) —
   `scripts/grade-evals.sh` (neutral `workspace.XXXXXX` sandbox basename),
   `scripts/test-grade-evals.sh` (case 9 basename assertion), `references/evals.md`,
   `references/heuristics.md` (Comparative & hard-to-test scoring), and `scripts/check-docs.sh`.
6. **Explain-the-number & benchmark sensitivity** (`backnotprop/pstack` `principle-explain-the-number`
   + `hillclimb`) — `references/scoring.md` (Relative-to-incumbent scoring) and
   `references/heuristics.md`.
7. **Pause safely & cold session pickup** (`backnotprop/pstack` `pause-safely` + `session-pickup`),
   **Retry / loop-tax ratio** (`Keesan12/martin-loop`), and **ADR kill / reversal criterion**
   (`0xNyk/council-of-high-intelligence`) — `SKILL.md`, `references/ralph-loop.md`,
   `references/telemetry.md`, `references/adr.md`, `assets/adr.template.md`, and
   `references/heuristics.md`.
8. **Monotonic plan-progress guard & untrusted-content quarantine** (`OthmanAdi/planning-with-files`) —
   `scripts/loop.sh` (`plan_done_count`), `scripts/test-loop.sh` (case 21),
   `references/ralph-loop.md` (Standing guardrails + Tool-output budget), and
   `references/heuristics.md`.
9. **Differential oracle harnesses & scratch-home `XDG_*` isolation** (`horizon-rust/horizon`),
   **Brownfield Delta Specs (`ADDED` / `MODIFIED` / `REMOVED`)** (`Fission-AI/OpenSpec`),
   **High-blast-radius floor on Quick track & lockfile version pinning** (`addyosmani/agent-skills`),
   and **`same-family` vs. `cross-family` reviewer independence** (`wanshuiyin/Auto-claude-code-research-in-sleep`) —
   `SKILL.md`, `references/hard-to-test-domains.md`, `references/artifacts.md`,
   `assets/spec.template.md`, `references/subagents.md`, `references/ralph-loop.md`,
   `references/heuristics.md`, and `scripts/check-docs.sh`.

## What to do next

- [Plans index](README.md)
- [Heuristics ledger](../../references/heuristics.md)
- [Harness portability](../../references/harness-portability.md)
