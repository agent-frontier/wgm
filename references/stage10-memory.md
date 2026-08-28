# Stage 10 memory — evidence before authority

Stage 10 memory is a local, evidence-first layer for understanding a repository and its execution environment. It is not a replacement for the constitution, specs, implementation plan, or deterministic validation.

The implementation follows three useful patterns: Luria's source/view split and explicit standing; Weightless's layered qualification and fail-closed boundaries; and vLLM's separation of environment facts, model/runtime facts, tests, and benchmarks.

## The one command

Run from the target repository root:

```bash
python3 scripts/stage10_memory.py inspect --root .
```

This writes:

- `.wgm/stage10/observations.jsonl` — deterministic source observations.
- `.wgm/stage10/brief.md` — concise generated hot view for humans and fresh agents.
- `.wgm/stage10/system-map.md` — fuller generated map of entry points, gates, and harnesses.

The command makes no model call, network call, or credential-file read. It reports executable presence and safe host signals, but presence is not authentication or qualification.

The focused gate is:

```bash
bash scripts/test-stage10-memory.sh
```

The real-checkout freshness check is:

```bash
python3 scripts/stage10_memory.py lint --root .
```

## Sources and views

Observations and memory records are append-oriented sources. The brief and system map are generated views. Edit the sources or rerun `inspect`; do not hand-edit generated Markdown.

Every generated view includes its source paths and refresh command. The default brief is bounded to 120 lines and 16,000 bytes so the human surface stays useful instead of becoming a transcript archive.

## Observation scope

The first slice records:

- Git root, branch, and head.
- Tracked-file inventory and safe content hashes.
- Sensitive-path counts without reading sensitive contents.
- Repository entry points, scripts, docs, Makefile targets, and validation targets.
- Static compatibility metadata for known harnesses.
- Executable presence for known harness commands.
- Current harness/provider/model signals exposed through a small non-secret allowlist or a safe parent-process name.

The scanner does not claim to know semantic dependencies, provider authentication, tool-call support, live service health, or successful Ralph execution. Those belong to later qualification levels.

## Memory record contract

Append a record with:

```bash
python3 scripts/stage10_memory.py record \
  --kind lesson \
  --standing validated \
  --scope task \
  --summary 'The validation target is the cheapest backpressure.' \
  --source 'CONTRIBUTING.md:40' \
  --evidence 'command:make validate'
```

Each record has a stable identity derived from kind, scope, summary, and source, plus:

| Field | Meaning |
|---|---|
| `kind` | `observation`, `lesson`, `invariant`, `decision`, `route`, `experiment`, or `failure` |
| `standing` | `observed`, `validated`, `corroborated`, `promoted`, `stale`, or `rejected` |
| `scope` | The task, subsystem, project, or host boundary where the claim applies |
| `source` | Where the claim came from |
| `evidence` | Commands, files, runs, or approvals supporting it |
| `environment` | Non-secret branch/head/harness/provider/model context |
| `revalidate_when` | What change should make the claim run through review again |

## Standing and promotion

```text
observed → validated → corroborated → promoted
                 ↘ stale / rejected
```

- `observed`: recorded once; never a routing authority.
- `validated`: confirmed by a deterministic check; task-local use only.
- `corroborated`: supported by at least two independent evidence references.
- `promoted`: corroborated and explicitly carries `human-approved:` evidence.
- `stale`: source, validation, code, or environment no longer matches.
- `rejected`: tested and disproven; retain it as avoidance knowledge.

A model's confidence is not evidence. The tool rejects credential-like values, multiline records, and promotion without sufficient evidence.

## Legacy migration

Stage 10 can import the old flat ledgers without deleting them:

```bash
python3 scripts/stage10_memory.py migrate --root .
```

By default it reads `.wgm/memories.md` and `.wgm/scores.md`, appends idempotent Stage 10 records, and leaves both source files unchanged. The legacy files are compatibility inputs only; Stage 10's `memory.jsonl` is authoritative for its generated views.

## Harness inventory boundary

The harness section is an inventory, not a qualification result:

```text
present → contract-valid → protocol-ready → tool-ready
        → Ralph-smoke-passed → qualified → corroborated
```

`inspect` performs only the first inventory step and records unknowns. A later qualification command must make live calls explicit, bounded, disposable, and separately evidenced.

## Failure handling

The memory command fails closed when:

- a JSONL record is malformed or duplicated;
- a standing lacks the evidence it requires;
- a tracked source changes after observation;
- a brief or system map exceeds its bound;
- a credential-like value appears;
- a state directory escapes the project's `.wgm/` boundary;
- the compatibility registry names a harness with no executable mapping.

Failure leaves the source records intact so the operator can inspect and recover.

## Human surface

Read `.wgm/stage10/brief.md` first. It answers:

1. What repository and revision were observed?
2. What are the important entry points and validation targets?
3. Which harnesses are present and which one appears current?
4. What does the evidence not prove yet?
5. Which memories are validated, stale, or uncertain?

Raw JSONL is for tooling and investigation. It is never the default human handoff.

## What Stage 10 memory does not do

- It does not call a model during `inspect`.
- It does not read API keys or credential stores.
- It does not modify source code, specs, governance, CI, or provider configuration.
- It does not select a route, run an experiment, open a PR, deploy, or merge.
- It does not make a single successful observation into project-wide policy.

Those capabilities are later Stage 10 slices and must reuse this evidence boundary.
