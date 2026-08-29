# Reference: Stage 10 offline orchestration

## Executive overview

- **For:** maintainers and fresh agents who need a compact picture of a repository and its known execution environment.
- **What it is:** an evidence-first memory layer plus a bounded process contract, offline qualification, routing, experiment-comparison, and policy-comparison commands.
- **Default safety:** inspection and fixture gates make no model or network call, read no credential file, and write only under the target project's `.wgm/` directory.
- **Canonical gates:** `bash scripts/test-stage10-memory.sh` for memory, `bash scripts/test-stage10-runner.sh` for bounded execution, and `bash scripts/test-stage10-e2e.sh` for the composed offline path.
- **Authority:** live execution, branch/worktree creation, PR creation, deployment, merge, publication, and policy activation remain explicit human-authorized boundaries.

> **Offline/fixture boundary:** every shipped Stage 10 harness and the default inspection path is deterministic and local. No shipped command silently performs a live provider call, creates a branch or PR, merges, deploys, publishes, or activates policy.

## Artifact map

| Command | Writes | First reader | Bounds / authority |
|---|---|---|---|
| `stage10_memory.py inspect` | observations, `brief.md`, `system-map.md` | human + tooling | generated views: 120 lines / 16,000 bytes each; local only |
| `stage10_memory.py brief` | `brief.md` and `system-map.md` | human + tooling | regenerates bounded generated views; local only |
| `stage10_memory.py record` | append-oriented `memory.jsonl` | tooling + maintainer | summary: 240 characters; source ledgers: 10 MiB; provenance required |
| `stage10_memory.py migrate` | `memory.jsonl` plus generated views | tooling + maintainer | legacy sources remain unchanged; idempotent import |
| `stage10_qualification.py qualify` | `harnesses/qualification.jsonl` | tooling + maintainer | manifest: 1 MiB; command: 2,000 characters; phase timeout: 1–600 seconds |
| `stage10_runner.py run` | `runs/result.json` | tooling + maintainer | manifest: 1 MiB; direct argv: 128 items / 64,000 characters; timeout: 0.01–600 seconds; diagnostic: ≤64,000 characters |
| `stage10_router.py route` | `routing/decision.json` and `decision.md` | human decision-maker | manifest: 1 MiB / 100 routes; transparent policy; no execution |
| `stage10_experiments.py compare` | `experiments/report.json` and `.md` | human decision-maker | manifest: 1 MiB / 100 candidates; comparison only; no branch or PR |
| `stage10_policy.py compare` | `routing/policy/comparison.json` and `.md` | human decision-maker | manifest: 1 MiB / 10,000 tasks; offline comparison; no activation |
| `test-stage10-e2e.sh` | temporary fixture state and report | maintainer | disposable fixture; no model, network, or external write |

## Inspect a repository

Run from the target repository root:

```bash
python3 scripts/stage10_memory.py inspect --root .
```

Expected output:

```text
stage10 inspect: wrote 3 observations to .wgm/stage10/observations.jsonl
stage10 inspect: wrote human brief to .wgm/stage10/brief.md
stage10 inspect: wrote system map to .wgm/stage10/system-map.md
stage10 inspect: no model call, network call, or credential-file read
```

`inspect` captures Git identity, tracked-file hashes, entry points, Makefile validation targets, known harness metadata, executable presence, and safe current-host/provider/model signals when the host exposes them. The allowlist is the `SAFE_ENV_KEYS` constant in [`scripts/stage10_memory.py`](../../scripts/stage10_memory.py); arbitrary environment variables and credential stores are not inspected.

## Read the generated views

- `.wgm/stage10/brief.md` is the short human-facing view.
- `.wgm/stage10/system-map.md` is the fuller deterministic map.
- `.wgm/stage10/observations.jsonl` is the source record for tooling.
- `.wgm/stage10/memory.jsonl` is the source record for Stage 10 lessons and decisions.

Generated views name their inputs and refresh command. The brief and system map are each limited to 120 lines and 16,000 bytes.

## Record a lesson

```bash
python3 scripts/stage10_memory.py record \
  --kind lesson \
  --standing validated \
  --scope task \
  --summary 'The validation target is the cheapest backpressure.' \
  --source 'CONTRIBUTING.md:40' \
  --evidence 'command:make validate'
```

`validated` needs one evidence reference. `corroborated` needs at least two. `promoted` needs at least two and one `human-approved:` reference. Credential-like values and multiline fields are rejected. For example, this intentionally exits nonzero before writing a record:

```bash
python3 scripts/stage10_memory.py record --scope task \
  --summary 'token=redacted' --source 'README.md:1' --evidence 'command:example'
# stage10: ERROR: summary looks credential-bearing; replace the token-shaped value with &lt;redacted&gt; or rewrite it as non-assignment prose before recording
```

The refusal is about the assignment-shaped text, even though the displayed value is a placeholder.

## Migrate legacy memory

```bash
python3 scripts/stage10_memory.py migrate --root .
```

The command imports `.wgm/memories.md` and `.wgm/scores.md` idempotently, leaves both files unchanged, and makes the Stage 10 ledger authoritative for generated views.

## Lint freshness and safety

```bash
python3 scripts/stage10_memory.py lint --root .
```

Exit `0` means observations, records, generated views, bounds, and source hashes are current. A malformed record, suspicious value, changed source, missing generated view, or incompatible harness-registry mapping exits nonzero.

The command reports executable presence only. It does not prove authentication, live protocol support, tool capability, or a successful Ralph run.

## Qualification boundary

Stage 10 qualification progresses through:

```text
present → contract-valid → protocol-ready → tool-ready
        → Ralph-smoke-passed → qualified → corroborated
```

Live qualification must be explicit and budgeted. Demo/fixture checks remain distinct from live evidence.

## Qualify a harness fixture

Qualification is phase-aware and fail-closed. Provide an explicit JSON manifest with `routes`, an optional `evidence` value (`fixture` by default), and commands keyed by `contract`, `protocol`, `tool`, `ralph-smoke`, `repeated`, or `benchmark`:

```bash
python3 scripts/stage10_qualification.py qualify --root . --manifest /path/to/fixture.json
```

The command writes `.wgm/stage10/harnesses/qualification.jsonl`. Each record preserves the route, phase, fixture/live evidence class, environment fingerprint, exact command, duration, status, diagnostic, and revalidation condition. Manifest commands are tokenized and run with `shell=False`; missing commands are `unknown`, not passes; a failed or timed-out phase stops that route. Live evidence requires both `allow_live: true` in the manifest and the explicit `--allow-live` flag, and is never inferred from fixture output. Diagnostics are redacted before persistence. The focused gate uses disposable fake commands and does not call a model or network:

```bash
bash scripts/test-stage10-qualification.sh
```

## Run one bounded process

The generic runner is the shared provider-agnostic process contract for later execution adapters. Its
manifest is structured data, not a shell command:

```json
{
  "argv": ["/path/to/fixture-command", "literal; shell punctuation is data"],
  "cwd": ".",
  "timeout_seconds": 5,
  "evidence": "fixture",
  "diagnostic_limit": 4000
}
```

Run it from the target repository root with an output path under `.wgm`:

```bash
python3 scripts/stage10_runner.py run \\
  --root . \\
  --manifest ./run.json \\
  --output .wgm/stage10/runs/result.json
```

The runner invokes the exact `argv` vector with `shell=False`, starts it in a new process group,
drains stdout/stderr while retaining only the configured diagnostic bound, and redacts
credential-shaped diagnostics before writing JSON. It constructs a small environment from safe
ambient basics plus explicit `env` values or an in-bound `environment_file`; it records keys and
hashes, not environment values. `cwd` and `environment_file` must resolve under `--root`, and the
result must remain under `--root/.wgm`; invalid paths are rejected before the child is spawned.

Results classify a run as `passed`, `failed`, `timeout`, or `refused`, and include the exit code,
duration, evidence class, environment fingerprint, cleanup result, and manifest hash used for
revalidation. A `live` manifest is refused unless it carries a non-empty authority envelope with
`allow_live: true` and the caller also passes `--allow-live`; the runner never discovers or creates
that authority and never promotes a refusal to route evidence. The focused fixture gate is local,
deterministic, and provider/network-free:

```bash
bash scripts/test-stage10-runner.sh
```

## Transparent route policy

Route selection is explicit and provider-agnostic. A task manifest supplies `hard_capabilities`,
soft `preferences`, a `budget`, and optional `local_only`; each route supplies capabilities and
qualification evidence. Hard mismatches, stale evidence, inventory-only evidence, and non-local
routes are excluded before scoring. Eligible routes are ordered deterministically by preference
matches, latency, cost, then route id, and the decision JSON records alternatives, evidence,
budget, uncertainty, and rationale without prompt or secret material:

```bash
python3 scripts/stage10_router.py route --root . --manifest /path/to/routes.json
```

The manifest must be under the target project root. A qualified route needs hard-capability matches,
non-stale qualified evidence, and at least one evidence reference. The command writes both
`.wgm/stage10/routing/decision.json` and a concise `decision.md` card; no model or network call is
made by the policy. The focused offline fixture gate is `bash scripts/test-stage10-router.sh`.

## Compare experiment candidates

```bash
python3 scripts/stage10_experiments.py compare --root . --manifest /path/to/experiment.json
```

The manifest freezes a Git baseline, hypothesis, route, environment, allowed files, evaluator,
target metric/direction, non-regression checks, budget, candidates, and either two evidence-backed
retirements or a narrow evidenced exception. A candidate must provide explicit holdout and gate
results, changed files within the allowed surface, and evidence references. The command writes a
machine report and Markdown comparison under `.wgm/stage10/experiments/`; hard regressions or
missing economy evidence return nonzero. This offline comparator never creates branches, calls a
provider, opens or merges a PR, deploys, pushes, or publishes.

```bash
bash scripts/test-stage10-experiments.sh
```

The fixture deliberately includes a high-scoring regressing candidate so the hard non-regression
gate is observed rather than assumed.

## Compare a learned policy offline

```bash
python3 scripts/stage10_policy.py compare --root . --manifest /path/to/policy-history.json
```

The manifest supplies policy names, `metric_direction`, corroborated route history, and identical
incumbent/learner results for each task. Sparse history remains `deferred`; any per-task hard-gate
or holdout regression rejects promotion even when the aggregate metric improves. A recommendation
is written as JSON and Markdown under `.wgm/stage10/routing/policy/`, but activation still requires
a human-reviewed PR. This comparator is offline and never calls a provider or changes policy.

```bash
bash scripts/test-stage10-policy.sh
```

## End-to-end demonstration

Run the disposable vertical slice to compose observation/recall, qualification, transparent routing,
experiment comparison, and offline learned-policy comparison:

```bash
bash scripts/test-stage10-e2e.sh
```

It writes its concise report only inside a temporary fixture and proves the selected route,
alternatives, evidence, budget, frozen-baseline result, corroborated knowledge, and human decision
boundary. The harness uses no model or network and never creates a PR, merges, deploys, publishes, or
activates a policy automatically.

## What to do next

- [Run the Ralph loop](../operator/running-the-loop.md) — execute one fresh-context iteration.
- Read the local `.wgm/STAGE10_ROADMAP.md` and `.wgm/IMPLEMENTATION_PLAN.md` for current offline-slice status and separately authorized future boundaries.
- [Gates](gates.md) — see the complete repository validation suite.
- [Harness portability](../../references/harness-portability.md) — review compatibility evidence.
- [Stage 10 memory protocol](../../references/stage10-memory.md) — agent-facing record and safety contract.
