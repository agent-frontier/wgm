# Reference: Stage 10 memory

## Executive overview

- **For:** maintainers and fresh agents who need a compact picture of a repository and its known execution environment.
- **What it is:** local JSONL observations plus generated Markdown views.
- **Safety:** no model call, network call, credential-file read, or write outside the project's `.wgm/` directory.
- **Canonical gate:** `bash scripts/test-stage10-memory.sh`.
- **Next:** use the explicit harness qualification ladder before route selection.

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

`inspect` captures Git identity, tracked-file hashes, entry points, Makefile validation targets, known harness metadata, executable presence, and safe current-host/provider/model signals when the host exposes them.

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

`validated` needs one evidence reference. `corroborated` needs at least two. `promoted` needs at least two and one `human-approved:` reference. Credential-like values and multiline fields are rejected.

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

Later Stage 10 qualification progresses through:

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

## What to do next

- [Run the Ralph loop](../operator/running-the-loop.md) — execute one fresh-context iteration.
- [Gates](gates.md) — see the complete repository validation suite.
- [Harness portability](../../references/harness-portability.md) — review compatibility evidence.
- [Stage 10 memory protocol](../../references/stage10-memory.md) — agent-facing record and safety contract.
