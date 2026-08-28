# Reference: gates and validation commands

wgm steers on **backpressure** — deterministic pass/fail signals. This page lists every gate this
repository ships, what each one proves, and when it runs.

**Note:** These gates validate *wgm itself*. They are not what wgm runs against **your** project —
there, the backpressure is your own project's test, build, lint, or probe command.

## The one command

```bash
make validate
```

This is the full local suite, and it is what CI runs (minus `skills-ref`, `actionlint`, and the
PowerShell harness, which CI adds). Expect roughly a minute.

| Target | Runs | Purpose |
|---|---|---|
| `make lint` | `shellcheck` plus `bash -n` on every script | Shell correctness and style. |
| `make docs` | `check-docs.sh`, `check-evals.sh`, `check-harnesses.sh` | Documentation, fixture, and harness-contract structure. |
| `make test` | Every `test-*.sh` harness | Behavior of the shipped scripts. |
| `make validate` | All three | The complete gate. Alias: `make check`. |

## Structural gates

These check artifacts and fail on drift. They are safe to run any time.

| Script | Checks | Exit |
|---|---|---|
| `check-docs.sh` | docs/ structure and required files; balanced code fences; internal relative links resolve; no leftover placeholders; operator docs carry an executive overview; agent files carry required frontmatter and sections; every `references/*.md` is indexed in README; no UTF-8 double-encoding; marked complete tables have no blank cells; review/evidence/executability protocol contracts remain present | `0` green, `1` red |
| `check-evals.sh` | `evals/evals.json` is valid JSON with an allow-listed key set, and every case carries `id`, `prompt`, `expected_output`, and a non-empty `assertions` array | `0` green, `1` red, `2` `jq` missing |
| `check-harnesses.sh` | `compatibility/harnesses.json` — allow-listed keys at every level; only the four statuses `Verified`, `Expected`, `Degraded`, `Unknown`; non-empty discovery paths, invocation command, and `https://` sources; `Verified` only with discovery **and** invocation **and** end-to-end journey evidence; no duplicate or missing harness entries | `0` green, `1` red, `2` `jq` missing |
| `check-trailers.sh` | Every commit in `BASE..HEAD` — **merge commits included** — carries the trailers the repository mandates | `0` green, `1` red |
| `check-doc-sync.sh` | A diff that adds public surface (a CLI flag, a shell function, a script or config file) also touched a documentation path | `0` green or `--warn`, `1` red |

### check-trailers.sh

Product gates cannot see commit-message policy, so a run can reach a fully green tree and still ship
a non-compliant history. The usual offender is a **generated merge commit**: every head commit
carries the required trailers and the merge button's synthesized commit carries none.

```bash
scripts/check-trailers.sh --base main --trailer Co-authored-by --trailer Copilot-Session
```

Required keys come from `--trailer` flags, or one-per-line from `.wgm/required-trailers` or
`.github/required-trailers`. With neither present the check is an explicit no-op — this is opt-in
governance, not an imposed policy.

**Caution:** If a non-compliant merge is already published, do not rewrite shared history. Build a
replacement two-parent merge from the same parents with the trailers present, and prove
`old^{tree} == replacement^{tree}` before promoting it.

### check-doc-sync.sh

Catches documentation drift in the iteration that causes it, rather than several merged PRs later
when a batch audit finally notices.

```bash
scripts/check-doc-sync.sh --base HEAD~1 --warn
```

Use `--warn` for the advisory mode the Record step uses: it reports and exits `0`. Omit it to fail.

### check-harnesses.sh

Turns wgm's portability claim into something that can be wrong. `compatibility/harnesses.json`
records one entry per agent harness — discovery paths, the non-interactive invocation contract,
subagent capability, the fallback used without it, wgm's adapter status, per-OS evidence, and
authoritative source URLs — and this gate enforces the evidence rules behind the four statuses.

```bash
bash scripts/check-harnesses.sh
WGM_HARNESSES=path/to/other.json bash scripts/check-harnesses.sh   # check one fixture
```

`Verified` is the only status that requires recorded discovery **plus** non-interactive invocation
**plus** an end-to-end wgm journey; `Expected` may not carry journey evidence, `Degraded` must name
the missing capability and its fallback, and `Unknown` may carry no evidence at all. The gate fails
closed on malformed JSON, a missing file, duplicate ids, unsupported values, and on the deletion of
any harness wgm publishes a claim about. It needs no network and no vendor CLI — see
[harness portability](../../references/harness-portability.md).

## Behavior harnesses

Each shipped script has a harness proving it does what it claims. They use fake agents and throwaway
repositories, so **no real agent, model, network, or token is needed**.

| Harness | Proves |
|---|---|
| `test-install.sh` | Install, idempotent re-run, uninstall, WSL mirroring, companion install, `--no-companions` |
| `test-install.ps1` | The same, for the PowerShell installer |
| `test-plugin-registry.sh` | Isolated no-dependency discovery and execution of a real plugin `invoke` handler through `wgm_plugin_registry.py` |
| `test-stage10-memory.sh` | Deterministic Stage 10 observations, system map, human brief, safe host signals, standing, migration, redaction, staleness, and `.wgm` confinement |
| `test-loop.sh` | Limit knobs, capability probe, no-progress stall, project-gate execution, container selection, phase artifacts, watchdog timeout, harvest idempotency, commit ownership, retry and circuit breaker, metrics ledger, cost ceiling |
| `test-swarm.sh` | Parallel branches, worktree/artifact pinning, project-gate propagation, partial-setup failure, zero-commit failure, memory consolidation, telemetry summary |
| `test-audit.sh` | Docs-audit dispatch: argument errors, dry-run, four independent personas, writer-after-four ordering, a failed/empty/banner persona blocking the writer, report-contract validation for personas and the writer, terminal (never-retried) repository-change detection including a role that commits, stashes, creates a gitignored path, or overwrites an existing ignored file such as `.env` or an untracked non-ignored scratch file, the unknown-origin delta report, worktree-root lock serialization from a subdirectory, bounded retries, the timeout bound and its cooperative fallback, the non-git refusal and `--allow-unguarded`, concurrency locking, report placement, argv/stdin agent modes |
| `test-devcontainer.sh` | Sandbox init, base-image build, run, prune |
| `test-harvest-hive.sh` | Anonymization, consent state machine, and the fail-closed publish contract |
| `test-grade-evals.sh` | Grading, baseline comparison, accept and regression verdicts |
| `test-check-evals.sh` | The schema gate rejects unknown and missing keys |
| `test-check-harnesses.sh` | The harness-contract gate rejects an invalid status, a missing discovery path, a `Verified` entry with no evidence, malformed JSON, a deleted harness entry, and a duplicate id — while still accepting a valid `Degraded` entry |
| `test-check-docs.sh` | The docs gate rejects mojibake, broken links, unbalanced fences, and blank marked-table cells |
| `test-check-trailers.sh` | The trailer audit catches a bare generated merge commit |
| `test-check-doc-sync.sh` | The doc-sync gate fires on undocumented surface and stays quiet otherwise |

**Note:** A gate is only proven by watching it go **red** on the class it claims to catch. A
mojibake sweep once shipped here matching nothing at all, because PCRE reads `\xNN` as a character
unless `LC_ALL=C` forces byte semantics — it reported green over corrupt input. Every gate now ships
with a harness that fails it deliberately.

## Not in the suite

| Script | Why it is excluded |
|---|---|
| `grade-evals.sh` | Costs real agent and API calls (one task call plus one grader call per case, doubled with `--baseline`). Run it by hand before landing a `SKILL.md` or `references/` change that could affect behavior quality. |
| `harvest-hive.sh` | Has a real external side effect (filing a public issue). The harness exercises it only on guaranteed no-network paths. |

## Additional gates in CI

`.github/workflows/ci.yml` adds three checks you can also run locally:

| Check | Local equivalent |
|---|---|
| `skills-ref validate` on wgm and all three companions | `pip install skills-ref`, then `skills-ref validate wgm` from the parent directory |
| `actionlint` on the workflow files | `actionlint .github/workflows/ci.yml` |
| PowerShell parse plus `test-install.ps1` | `pwsh ./scripts/test-install.ps1` |

**Note:** `skills-ref` requires the skill directory's basename to equal the skill name, so validate
`wgm` from the repository's parent directory and the companions from inside `companions/`.

## What to do next

- [Contributing](../../CONTRIBUTING.md) — development prerequisites and the contribution flow.
- [Artifacts](artifacts.md) — every file wgm reads and writes.
- [Harness portability](../../references/harness-portability.md) — what `check-harnesses.sh` enforces, and which harnesses are actually verified.
- [Backpressure in depth](../../references/ralph-loop.md) — the discipline these gates implement.
