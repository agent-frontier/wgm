# Heuristics — wgm's retained juice

The curated, version-controlled ledger of **durable, cross-project** lessons that have graduated out
of ephemeral `.wgm/memories.md` into the shared skill. This is wgm's long-term memory: each entry
changed how wgm behaves *everywhere*, not just in one build. See
[`self-improvement.md`](self-improvement.md) for how lessons get here.

**Adding an entry** (one thought per entry, newest at the top of its section):
- **Heuristic** — the durable rule, stated as an imperative.
- **Why** — the failure it prevents or the value it adds.
- **Provenance** — where it was learned (a dogfood run, a `[learn]` issue, an influence).
- **Landed in** — the skill artifact that now enforces it.

Prune or merge entries that a protocol change has made redundant — the ledger stays lean, like the
memory it graduates from.

## Loop discipline
- **Heuristic:** search the codebase for an existing implementation before building anything.
  **Why:** assuming a feature is missing and rebuilding it is a top loop-failure mode.
  **Provenance:** ghuntley/Ralph standing guardrail. **Landed in:** `SKILL.md` Loop · Analyze.
- **Heuristic:** advance exactly one task per iteration and write handoff-quality state before
  stopping. **Why:** a fresh context must be able to resume from the plan alone.
  **Provenance:** Ralph loop. **Landed in:** `SKILL.md` Iteration-exit gate.

## Backpressure
- **Heuristic:** for native apps, games, GUIs, or engines, the *first* task is building the headless
  harness (output capture, state probes, crash soaks). **Why:** there is no natural unit test to
  lean on, so a deterministic signal must be manufactured before any feature work.
  **Provenance:** hard-to-test-domains work. **Landed in:** `references/hard-to-test-domains.md`.
- **Heuristic:** a high satisfaction score never overrides a failing deterministic check.
  **Why:** an LLM judge can be charmed; a failing test cannot. **Provenance:** holdout-scoring +
  octopusgarden. **Landed in:** `SKILL.md` Backpressure · `wgm-validator`.

## Token economy
- **Heuristic:** single-token compaction is model-specific — verify keys against the target
  tokenizer; short ASCII keys are the portable default. **Why:** a CJK glyph is 1 token in OpenAI
  o200k but 2–3 in cl100k, so "kanji == 1 token" is false in general.
  **Provenance:** tiktoken measurement during the token-economy pass. **Landed in:**
  `references/artifacts.md` (Token economy) · `assets/state.template.toon`.
- **Heuristic:** declare keys once (tabular/TOON) for any state reloaded every iteration.
  **Why:** repeating verbose keys per row taxes every loop's context budget.
  **Provenance:** token-economy pass. **Landed in:** `references/artifacts.md` (Token economy).

## Review
- **Heuristic:** run two independent review passes — spec-compliance, then code-quality.
  **Why:** a single reviewer conflates "right thing" with "built correctly" and blesses its own
  assumptions. **Provenance:** Superpowers two-stage review. **Landed in:** `references/subagents.md`
  · `wgm-spec-reviewer` + `wgm-quality-reviewer`.
