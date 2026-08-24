# Harness portability — the capability/evidence contract

wgm used to say it runs on "any compatible coding agent." That is unfalsifiable: no file named the
harnesses, no field recorded what had actually been observed, and nothing failed when the claim
drifted. This document and [`compatibility/harnesses.json`](../compatibility/harnesses.json) replace
it with a claim that can be checked and can be *wrong*:
[`scripts/check-harnesses.sh`](../scripts/check-harnesses.sh) enforces the shape and the evidence
rules, and [`scripts/test-check-harnesses.sh`](../scripts/test-check-harnesses.sh) mutation-tests the
gate so it cannot decay into a gate that always passes.

The record is the source of truth. This page is the contract in prose.

## Portable kernel vs host adapters

wgm is two things wearing one name, and the difference is exactly what portability turns on.

| Layer | What it is | What it needs from a harness |
|---|---|---|
| **Portable kernel** | The protocol itself — Triage, Grill, Plan, Preflight, and the loop (Analyze → Implement → Validate → Review → Record), plus the artifacts on disk and the deterministic gates | A model that can read `SKILL.md` and run shell commands. Skill *discovery* is a convenience; a host without it can still be handed the protocol explicitly. |
| **Host adapters** | Everything the protocol delegates to the host: role-subagent dispatch (the two-stage review and the five-role docs-audit swarm), custom-agent formats, host-specific permission flags | A host primitive wgm does not implement — and, for the swarm, agent definitions in that host's format. wgm ships them for one host today (`.github/agents/*.agent.md`). |

A harness that lacks an adapter capability is not incompatible; it is **degraded in a named way**,
with a named fallback (usually: run the passes inline and sequentially, preserving dissent — see
[subagents](subagents.md)). For the docs-audit swarm the named fallback is `scripts/audit.sh`, which
is *designed* to dispatch all five roles through whatever headless command the host documents, so a
host with no subagent primitive has a path to running the audit rather than only recording it
unavailable. Whether that path has actually been exercised on a given harness is that entry's own
evidence question — several entries record it as design intent against a documented interface, not as
an observed run — and even where it works it buys independence of context and lens, never of model or
tooling. The kernel keeps steering on the project's own validation command
either way, because the backpressure comes from the project, not from the harness.

## Evidence tiers

Exactly four statuses exist. The checker rejects any other value.

<!-- wgm: complete-table -->

| Status | Means | Requires |
|---|---|---|
| `Verified` | wgm has been run here, end to end | Recorded **discovery** evidence, recorded **non-interactive invocation** evidence, and at least one recorded **end-to-end wgm journey** — as evidence objects with references, plus authoritative source URLs |
| `Expected` | Contract-fit on the vendor's documentation, untested by wgm | Documented discovery paths and a documented non-interactive mode. May **not** carry journey evidence: if a journey exists, the entry is Verified or the evidence is not real |
| `Degraded` | wgm runs, but a named host capability is missing | A non-empty `missing_capability` and a named `fallback`. A host with no subagent primitive (`subagents.capability: none`) may hold no other status |
| `Unknown` | No reliable evidence either way | No evidence objects at all. Sources may still record what a vendor documents |

Two sentinels keep the honest cases expressible without weakening the "non-empty value" rule:
`skill_discovery.paths: ["none-documented"]` and `invocation.command: "none-documented"`. An entry
carrying either may not be `Verified` or `Expected`.

**A status is about wgm's evidence, not about a vendor's quality.** `Expected` is a prediction;
`Unknown` is an admission. Neither is a complaint about the harness.

## What is on the record today

Summarized from [`compatibility/harnesses.json`](../compatibility/harnesses.json); that file wins
any disagreement, and the gate fails if an entry here is deleted from it.

<!-- wgm: complete-table -->

| Harness | Status | Skill discovery | Non-interactive invocation | Subagents | wgm adapter |
|---|---|---|---|---|---|
| GitHub Copilot CLI | `Verified` | `~/.copilot/skills/`, `~/.agents/skills/`, `.github/skills/` | `copilot -p "…" --allow-all-tools` | host-dispatched | shipped (`.github/agents/`) |
| Claude Code | `Expected` | `~/.claude/skills/`, `.claude/skills/` | `claude -p "…" --dangerously-skip-permissions` | native, unwired | needed |
| OpenAI Codex CLI | `Expected` | `~/.agents/skills/`, repo `.agents/skills/`, `/etc/codex/skills/` | `codex exec "…"` | unknown | needed |
| Gemini CLI | `Expected` | `~/.gemini/skills/`, `~/.agents/skills/`, `.agents/skills/` | `gemini -p "…"` | unknown | needed |
| Cursor CLI | `Expected` | `.agents/skills/`, `.cursor/skills/`, user equivalents | `agent -p "…"` | native, unwired | needed |
| OpenCode | `Expected` | `.opencode/skills/`, `~/.config/opencode/skills/`, `~/.agents/skills/` | `opencode run "…"` | native, unwired | needed |
| Pi | `Degraded` | `~/.pi/agent/skills/`, `~/.agents/skills/`, `.pi/skills/`, `.agents/skills/` | `pi -p "…"` (documented, not executed) | **none — by design** | needed |
| Aider | `Degraded` | none documented | `aider --message "…" --yes-always` | none | needed (explicit `--read`) |
| Windsurf (Cascade) | `Unknown` | `~/.agents/skills/`, `~/.codeium/windsurf/skills/` | none corroborated | unknown | unknown |

One harness is `Verified`. That is the honest number, and publishing it is the point: the previous
claim implied nine.

### Reading the labels honestly

- **Even the `Verified` entry is precise about what proves what.** Copilot CLI's discovery evidence
  is the shared `~/.agents/skills/wgm` layout that
  [`scripts/test-install.sh`](../scripts/test-install.sh) asserts on every run, plus the installer
  source and the published install docs for the `~/.copilot/skills/wgm` client target — no harness
  asserts that client path today. The journey evidence is what carries the status.
- **Pi's headless details are documented, not executed.** Pi's README documents print, JSON, and RPC
  modes; wgm has never run [`scripts/loop.sh`](../scripts/loop.sh) against it, so the flags in the
  record may drift from the real CLI.
- **Codex subagent claims are unverified.** Third-party pages describe Codex delegation features
  that OpenAI's own skills documentation does not define as a dispatchable primitive.
- **OpenCode's flag surface is unverified.** `opencode run` is documented as non-interactive; the
  permission flags needed for *unattended* tool use are version-dependent. Do not copy a flag set
  out of the record into an autonomous run without checking it.
- **The Aider and Windsurf negatives are absences of documentation, checked on 2026-08-24, not
  vendor denials.** Aider documents no Agent Skills directory; Windsurf documents skill discovery
  but no corroborated non-interactive mode. Either could be wrong tomorrow, which is precisely why
  each carries a source URL and a status that can be raised by evidence.

## Pi is the next real dogfood target

Pi is deliberately the next harness to actually run, not the next one to describe:

- It implements Agent Skills natively and reads `~/.agents/skills/`, which is already where
  [`scripts/install.sh`](../scripts/install.sh) puts wgm — so the install step needs no new code.
- It ships **no sub-agent primitive on purpose**, which makes it the sharpest available test of the
  kernel/adapter split: everything except role dispatch has to work, and role dispatch has to fall
  back cleanly to inline sequential passes with dissent preserved.
- A single recorded journey there converts three claims from documented to verified, or produces a
  concrete defect list — either outcome is worth more than another Expected row.

Recording that run means adding `discovery`, `invocation`, and `journey` evidence objects to the Pi
entry. Its status stays `Degraded` until a Pi adapter exists for subagents; Degraded with evidence is
a strictly stronger statement than Expected without.

## Distribution

Skill discovery is a *loading* mechanism, not a distribution channel, and no marketplace is required
to use wgm. **GitHub Releases remain canonical** — `main` is the release line, and installs pin with
`WGM_REF` / `--ref` (see the [installers reference](../docs/reference/cli-install.md)). A published
index of where the skill can be found is separate, later work; nothing in this contract depends on
it.

## Changing the record

1. Edit [`compatibility/harnesses.json`](../compatibility/harnesses.json). Every entry carries an
   allow-listed key set — an invented or renamed field is a failure, not silent drift.
2. Raise a status only by adding evidence. Evidence objects are `kind` (`discovery`, `invocation`,
   or `journey`), `ref` (a path, a command, a URL, or a commit trail), and `detail`.
3. Never delete an entry to make the table look better. The gate lists every harness wgm publishes a
   claim about and fails when one goes missing.
4. Run the gate:

```bash
bash scripts/check-harnesses.sh        # the contract itself
bash scripts/test-check-harnesses.sh   # the gate's own mutation tests
```

Both are part of `make validate`. Neither needs the network or a vendor CLI: this checks the record,
not the harnesses — running a harness is what produces journey evidence in the first place.
