# Reference: Stage 10 offline orchestration

## Executive overview

- **For:** maintainers and fresh agents who need a compact picture of a repository and its known execution environment.
- **What it is:** an evidence-first memory layer plus a bounded process contract, offline qualification, routing, isolated local experiment execution, experiment comparison, human-gated local PR preparation, and policy comparison.
- **Default safety:** inspection and fixture gates make no model or network call, read no credential file, and write only under the target project's `.wgm/` directory.
- **Canonical gates:** `bash scripts/test-stage10-memory.sh` for memory, `bash scripts/test-stage10-runner.sh` for bounded processes, `bash scripts/test-stage10-execution.sh` for isolated local experiments, `bash scripts/test-stage10-pr.sh` for PR preparation, `bash scripts/test-stage10-e2e.sh` for the composed offline path, and `bash scripts/test-stage10-deferred-e2e.sh` for the final deferred-boundary integration.
- **Authority:** `stage10_experiments.py execute` may create only its declared local experiment branch/worktree; live provider execution, remote mutation, PR creation, deployment, merge, publication, and policy activation remain separate explicit human-authorized boundaries.

> **Offline/fixture boundary:** every shipped Stage 10 harness and the default inspection path is deterministic and local. The execution harness creates branches/worktrees only inside disposable local fixtures. No shipped command silently performs a live provider call, remote mutation, PR operation, merge, deployment, publication, or policy activation.

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
| `stage10_experiments.py execute` | `experiments/executions/*.json`, one local branch/worktree, and per-check runner evidence | human reviewer | local patch/ref only; finite aggregate/check budgets; failed identities removed; no remote mutation |
| `stage10_experiments.py compare` | `experiments/report.json` and `.md` | human decision-maker | manifest: 1 MiB / 100 candidates; comparison only; no branch or PR |
| `stage10_policy.py compare` | `routing/policy/comparison.json` and `.md` | human decision-maker | manifest: 1 MiB / 10,000 tasks; offline comparison; no activation |
| `test-stage10-e2e.sh` | temporary fixture state and report | maintainer | disposable fixture; no model, network, or external write |
| `test-stage10-deferred-e2e.sh` | temporary execution/comparison/approval/gate artifacts and bounded report | maintainer | disposable Git fixture; authorized local double only; no provider, hosting, or remote write |

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

The command writes `.wgm/stage10/harnesses/qualification.jsonl`. Each record preserves the route, phase, fixture/live evidence class, environment fingerprint, exact command, duration, status, diagnostic, and revalidation condition. Manifest commands are tokenized and run with `shell=False`; missing commands are `unknown`, not passes; a failed or timed-out phase stops that route. Fixture evidence needs no live authority and is never inferred to be live. Diagnostics are redacted before persistence. The focused gate uses disposable fake commands and does not call a model or network:

```bash
bash scripts/test-stage10-qualification.sh
```

## Qualify a live harness with explicit authority

A live route is an operator action, never a CI/default-validation side effect. The live manifest
must set `allow_live: true`, declare a finite `live_budget_seconds`, and label each live route. A
separate authorization JSON binds the exact manifest bytes, exact route/phase scope, UTC expiry,
and same total execution-time budget. CI sets `WGM_STAGE10_LIVE_ALLOWED=false`, rejects live-
authorization files, and runs only the disposable contract harness below; CI success is not live
provider evidence.

```json
{
  "schema": "stage10.live-authorization.v1",
  "allow_live": true,
  "manifest_sha256": "replace-with-sha256-of-live-manifest-bytes",
  "scope": {
    "routes": {
      "maintainer-chosen-route": ["contract", "protocol", "tool", "ralph-smoke", "repeated", "benchmark"]
    }
  },
  "expires_at": "2026-08-30T20:00:00Z",
  "budget_seconds": 120
}
```

The scope must exactly equal the configured executable phases of every live route; extra,
missing, expired, hash-mismatched, or budget-mismatched authority fails before any child is
spawned. The authorization carries metadata and hashes only. Provider credentials stay in the
host's existing authentication mechanism and must not appear in either JSON file.

After a maintainer reviews both files, the explicit real-host command is:

```bash
python3 scripts/stage10_qualification.py qualify \
  --root . \
  --manifest .wgm/stage10/harnesses/live-manifest.json \
  --authorization-file .wgm/stage10/harnesses/live-authorization.json \
  --allow-live
```

Each configured live phase runs through `stage10_runner.py`'s bounded direct-argv contract. The
qualification JSONL records the authorization hash/scope/expiry, environment fingerprint, total
budget consumption, duration, status, runner result, and revalidation inputs without raw
credentials. A timeout, failure, or missing phase stays below `qualified`; even a passing result
is one dated observation and does not select a route, activate policy, prepare a PR, merge, deploy,
or publish. The automated contract gate uses local disposable commands only and makes no provider,
model, credential, or network call:

```bash
bash scripts/test-stage10-live-qualification.sh
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

Run one already-local candidate in an isolated experiment worktree:

```bash
python3 scripts/stage10_experiments.py execute \
  --root . \
  --manifest .wgm/stage10/experiments/execution.json
```

The execution manifest is frozen before worktree creation. It uses this shape:

```json
{
  "id": "candidate-a",
  "hypothesis": "the local candidate improves the declared evaluator",
  "baseline_sha": "0123456789abcdef0123456789abcdef01234567",
  "candidate": {"patch": ".wgm/stage10/experiments/candidate.patch"},
  "route": {"id": "local-fixture"},
  "environment": {"kind": "local"},
  "allowed_files": ["src/example.py"],
  "evaluator": {
    "name": "evaluator",
    "argv": ["python3", "scripts/evaluate.py"],
    "timeout_seconds": 30
  },
  "non_regression": [{
    "name": "tests",
    "argv": ["python3", "-m", "unittest"],
    "timeout_seconds": 60
  }],
  "budget": {"seconds": 90, "cost_units": 0}
}
```

`candidate` contains exactly one local `patch` path or local Git `ref`. The source checkout must be
clean outside `.wgm`, on a branch, and exactly at `baseline_sha`. Output, branch, and worktree
collisions fail before Git mutation. The executor derives a unique branch such as
`stage10/experiment/candidate-a-9f86d081884c` (the suffix is the manifest hash) and a worktree beneath
`.wgm/stage10/worktrees/`, then verifies the actual Git root, branch, and baseline before applying
candidate material.

Evaluator and non-regression commands are direct `argv` arrays. Every check gets a generated
`stage10_runner.py` manifest/result, and its declared timeout is capped by the remaining aggregate
budget. Changed tracked and untracked files must stay within `allowed_files`. Failure, timeout, or
scope escape preserves a negative JSON report while removing the failed worktree and branch.
Success retains the local branch, worktree, report, and per-check evidence for human review. Every
outcome revalidates that the source checkout's HEAD, branch, status outside `.wgm`, and configured
remotes are unchanged.

Execution never calls a provider, pushes, merges, opens a PR, deploys, publishes, or activates
policy, and its report always sets `pr_eligible` to false. Run the focused local-fixture gate with:

```bash
bash scripts/test-stage10-execution.sh
```

`execute` is not a replacement for the comparison gate below. Only `compare` applies hard
non-regression/holdout results and the two-retirement or evidenced-exception economy rule.

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

## Prepare a human-gated local PR bundle

PR preparation consumes the retained `stage10.execution.v1` report and the corresponding
`stage10.experiment.v1` comparison report. It revalidates both source-manifest hashes, the local
base/head/worktree identities, the final candidate snapshot, exact changed-file scope, every
bounded execution check, holdout and hard-gate evidence, and T7's economy result. Passing reports
without both human controls stop as `awaiting-human-review` and emit no bundle:

```bash
python3 scripts/stage10_pr.py prepare \
  --root . \
  --execution-report .wgm/stage10/experiments/executions/candidate-report.json \
  --comparison-report .wgm/stage10/experiments/report.json
```

The approval file uses schema `stage10.pr-approval.v1`, sets `approved` to `true`, names the
approver and UTC expiry, and binds the exact execution-report SHA-256, comparison-report SHA-256,
candidate-snapshot SHA-256, local head branch, base branch, baseline SHA, and ordered
`allowed_files`. After reviewing those exact inputs, the maintainer repeats the command with:

```bash
python3 scripts/stage10_pr.py prepare \
  --root . \
  --execution-report .wgm/stage10/experiments/executions/candidate-report.json \
  --comparison-report .wgm/stage10/experiments/report.json \
  --approval-file .wgm/stage10/pr-approval.json \
  --human-approve
```

Only that matching pair writes a bounded `stage10.pr-bundle.v1` JSON manifest and generated
Markdown body beneath `.wgm/stage10/pr/`. The body includes the baseline, route/environment,
changed files, exact validation, hard/holdout/economy evidence, source hashes, negative findings,
and remaining human action. Any changed report, candidate content, branch, base, scope, or expired
approval requires fresh evidence and approval.

`stage10_pr.py` has no hosting or network client and performs no push, PR creation, merge,
deployment, publication, protected-history rewrite, or policy activation. The generated bundle is
a local handoff only; a human must review and perform every external action separately. Run its
disposable local-fixture gate with:

```bash
bash scripts/test-stage10-pr.sh
```

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

Run the final deferred-boundary integration after the focused continuation gates:

```bash
bash scripts/test-stage10-deferred-e2e.sh
```

This second disposable demonstration composes T10-backed authorized local-double qualification,
passing and negative isolated executions, T7 comparison, and T13's two-part human approval. It
hashes the prior T1-T9 and T14 gate logs into a bounded artifact-derived report, proves failed and
reviewed worktree cleanup, and snapshots both fixture and real checkout/remotes/refs/worktrees.
Actual live qualification and every push or external PR action remain explicit operator decisions;
the harness invokes no provider, model, network, hosting client, merge, deployment, publication, or
policy activation.

## What to do next

- [Run the Ralph loop](../operator/running-the-loop.md) — execute one fresh-context iteration.
- Read the local `.wgm/STAGE10_ROADMAP.md` and `.wgm/IMPLEMENTATION_PLAN.md` for current offline-slice status and separately authorized future boundaries.
- [Gates](gates.md) — see the complete repository validation suite.
- [Harness portability](../../references/harness-portability.md) — review compatibility evidence.
- [Stage 10 memory protocol](../../references/stage10-memory.md) — agent-facing record and safety contract.
