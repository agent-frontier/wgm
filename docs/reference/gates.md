# Reference: gates and validation commands

wgm steers on **backpressure** — deterministic pass/fail signals. This page lists every gate this
repository ships, what each one proves, and when it runs.

**Note:** These gates validate *wgm itself*. They are not what wgm runs against **your** project —
there, the backpressure is your own project's test, build, lint, or probe command.

## The one command

```bash
make validate
```

This is the complete portable local suite. CI includes the same bash harness inventory, including
audit and devcontainer checks, plus the `skills-ref`, PowerShell, and separate `actionlint` checks
listed below.

`check-docs.sh` compares literal `bash scripts/test-*.sh` commands in `Makefile`'s `test` recipe
with single-line and literal-block (`run: |`) steps in `.github/workflows/ci.yml`. Every local entry
must appear in CI; missing inputs or an empty local inventory fail. Comments, step names, and echoed
commands do not count. This is an inventory check, not a general Make/shell/YAML interpreter: it
does not evaluate conditional execution. Keep these invocations literal; `actionlint` separately
checks workflow syntax.

| Target | Runs | Purpose |
|---|---|---|
| `make lint` | `shellcheck` plus `bash -n` on every script | Shell correctness and style. |
| `make docs` | `check-docs.sh`, `check-evals.sh`, `check-harnesses.sh`, `sync-agent-adapters.sh --check` | Documentation, fixture, harness-contract structure, and role-adapter derivation. |
| `make test` | Bash harnesses explicitly listed in `Makefile`'s `test` recipe | Behavior of the shipped scripts; not every manual/platform-specific `test-*.sh` file. |
| `make validate` | All three | The complete gate. Alias: `make check`. |

## Structural gates

These check artifacts and fail on drift. They are safe to run any time.

| Script | Checks | Exit |
|---|---|---|
| `check-docs.sh` | docs/ structure and required files; balanced code fences; internal relative links resolve; no leftover placeholders; operator docs carry an executive overview; agent files carry required frontmatter and sections; every `references/*.md` is indexed in README; no UTF-8 double-encoding; marked complete tables have no blank cells; review/evidence/executability protocol contracts remain present; local bash harness inventory is included in CI run steps | `0` green, `1` red |
| `check-evals.sh` | `evals/evals.json` is valid JSON with an allow-listed key set, and every case carries `id`, `prompt`, `expected_output`, and a non-empty `assertions` array | `0` green, `1` red, `2` `jq` missing |
| `check-harnesses.sh` | `compatibility/harnesses.json` — allow-listed keys at every level; only the four statuses `Verified`, `Expected`, `Degraded`, `Unknown`; non-empty discovery paths, invocation command, and `https://` sources; `Verified` only with discovery **and** invocation **and** end-to-end journey evidence; no duplicate or missing harness entries | `0` green, `1` red, `2` `jq` missing |
| `check-trailers.sh` | Every commit in `BASE..HEAD` — **merge commits included** — carries the trailers the repository mandates | `0` green, `1` red |
| `check-doc-sync.sh` | A successfully inspected diff that adds public surface (a CLI flag, a shell function, a script or config file) also touched a documentation path | `0` green or advisory finding, `1` undocumented surface, `2` invalid input / inspection error (even with `--warn`) |

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

**Caution:** If a non-compliant commit is already published, do not rewrite shared history or
promote a sibling replacement merge. Record the offending SHA, missing trailers, and a forward-only
correction/attestation. Handoff stays blocked pending an explicit, recorded maintainer decision;
there is no automatic waiver. A later attestation does not erase the original violation: the checker
remains RED for any audit range containing it. Prevent future violations with explicit merge
`--subject`/`--body` trailers before publishing.

### check-doc-sync.sh

Catches documentation drift in the iteration that causes it, rather than several merged PRs later
when a batch audit finally notices.

```bash
scripts/check-doc-sync.sh --base HEAD~1 --warn
```

The default compares HEAD's first parent with HEAD. `--base REF` must resolve to a commit
(commit-ish tags are accepted); if it resolves to current HEAD, inspection covers staged and
unstaged worktree changes plus non-ignored untracked files. With no parent commit, the default
also inspects that worktree. A repository without a committed HEAD is an error, not a clean diff.
Paths and untracked-file discovery use the Git worktree root, even when invoked from a subdirectory.

Use `--warn` for the advisory mode the Record step uses: an undocumented-surface finding prints
`WARN` and exits `0`; without it that finding exits `1`. A successful inspection with no finding
prints `GREEN`. Invalid/empty/non-commit bases or failed Git operations (including diff, tree, or
untracked-file inspection) identify the input or operation, print `ERROR`, and exit `2`, **even with
`--warn`**, without a GREEN verdict. Correct the ref or repository/inspection failure and retry.

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

The harnesses use fixture agents and throwaway repositories, so **no paid agent/model calls or
provider credentials are needed**. The devcontainer harness prefers Podman and falls back to Docker;
real build/run/prune cases visibly skip only when neither is installed. With an engine present it
uses a dedicated disposable test image (building it may need registry/network access), not the
operator's shared base image. These fixtures are not live-provider evidence.

Stage 10's live-qualification harness is explicitly a local contract test: CI sets
`WGM_STAGE10_LIVE_ALLOWED=false`, rejects live-authorization files, and runs only disposable doubles.
A green CI job is never live-provider evidence; a real live record requires the separately documented
operator authorization and `--allow-live` path.

| Harness | Proves |
|---|---|
| `test-install.sh` | Install, idempotent re-run, uninstall, WSL mirroring, companion install, `--no-companions` |
| `test-install.ps1` | The same, for the PowerShell installer |
| `test-plugin-registry.sh` | Isolated no-dependency discovery and execution of a real plugin `invoke` handler through `wgm_plugin_registry.py` |
| `test-stage10-memory.sh` | Deterministic Stage 10 observations, system map, human brief, safe host signals, standing, migration, redaction, staleness, and `.wgm` confinement |
| `test-stage10-runner.sh` | Published JSON/Bash example executed unchanged; direct argv execution, process-group timeout cleanup, bounded/redacted diagnostics, safe environment input, evidence classification, and path/authority confinement |
| `test-stage10-qualification.sh` | Phase-aware harness qualification, bounded commands, fixture/live separation, timeout handling, redacted diagnostics, and `.wgm` confinement |
| `test-stage10-live-qualification.sh` | Offline test doubles proving manifest opt-in, explicit confirmation, exact scope/hash/expiry/budget authorization, T10-backed execution, and fixture/live evidence separation |
| `test-stage10-router.sh` | Transparent capability/evidence filtering, deterministic route ordering, decision cards, and safe output confinement |
| `test-stage10-experiments.sh` | Frozen-baseline comparison, hard non-regression, negative-result retention, feature economy, and no-merge authority |
| `test-stage10-execution.sh` | Disposable local Git fixtures proving pre-mutation baseline/dirty/collision/path guards, isolated branch/worktree identity, T10-backed finite-budget checks, allowed-file scope, negative retention/cleanup, successful local retention, and unchanged source/remotes |
| `test-stage10-pr.sh` | Disposable local Git fixtures proving failed/stale/tampered/out-of-scope/under-retired evidence refusal, absent/expired/mismatched approval refusal, final-candidate snapshot binding, bounded report-derived JSON/Markdown output, and unchanged local/remote authority |
| `test-stage10-policy.sh` | Offline learned-policy comparison, sparse-history deferral, per-task regression rejection, metric direction, and no-activation authority |
| `test-stage10-deferred-e2e.sh` | Final disposable composition of T10-T13, T7, prior T1-T9 gates, and the T14 ShellCheck/boundary gate; artifact-derived bounded reporting; unauthorized live refusal; authorized local-double labeling; positive/negative worktree lifecycle; explicit approval gating; and unchanged real/fixture checkout and remotes |
| `test-loop.sh` | Limit knobs, capability probe, no-progress stall, project-gate execution, container selection, phase artifacts, watchdog timeout, harvest idempotency, commit ownership, retry and circuit breaker, metrics ledger, cost ceiling |
| `test-swarm.sh` | Parallel branches, worktree/artifact pinning, project-gate propagation, partial-setup failure, zero-commit failure, memory consolidation, telemetry summary |
| `test-audit.sh` | Docs-audit dispatch: argument errors, dry-run, four independent personas, writer-after-four ordering, a failed/empty/banner persona blocking the writer, report-contract validation for personas and the writer, terminal (never-retried) repository-change detection including a role that commits, stashes, creates a gitignored path, or overwrites an existing ignored file such as `.env` or an untracked non-ignored scratch file, the unknown-origin delta report, worktree-root lock serialization from a subdirectory, bounded retries, the timeout bound and its cooperative fallback, the non-git refusal and `--allow-unguarded`, concurrency locking, report placement, argv/stdin agent modes |
| `test-devcontainer.sh` | Sandbox init, base-image build, run, prune |
| `test-harvest-hive.sh` | Anonymization, consent state machine, and the fail-closed publish contract |
| `test-grade-evals.sh` | Grading, baseline comparison, accept and regression verdicts |
| `test-check-evals.sh` | The schema gate rejects unknown and missing keys, and the shipped fixture keeps its pinned ruggedness, evidence-boundary, numerical/API/performance, and cleanup ids and assertions |
| `test-check-harnesses.sh` | The harness-contract gate rejects an invalid status, a missing discovery path, a `Verified` entry with no evidence, malformed JSON, a deleted harness entry, and a duplicate id — while still accepting a valid `Degraded` entry |
| `test-check-docs.sh` | The docs gate rejects missing phase/runtime/action/authority/governance contracts, mojibake, broken links, unbalanced fences, blank marked-table cells, and missing local harnesses in CI; comments/echoes do not satisfy inventory parity, while literal run blocks do |
| `test-check-trailers.sh` | Bare generated merges fail; forward-only attestations preserve history and cannot clear the original violation |
| `test-check-doc-sync.sh` | Undocumented surface is caught; valid default/ref/HEAD, staged/unstaged/untracked, and advisory paths are preserved; invalid/non-commit refs and injected Git inspection failures cannot become GREEN or advisory success |

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

In addition to the portable local suite, CI runs these checks you can also run locally:

| Check | Local equivalent |
|---|---|
| `skills-ref validate` on wgm and all three companions (`ci.yml`) | `pip install skills-ref`, then `skills-ref validate wgm` from the parent directory |
| `actionlint` on the workflow files (`lint.yml`) | `actionlint .github/workflows/*.yml` |
| PowerShell parse plus `test-install.ps1` (`ci.yml`) | `pwsh ./scripts/test-install.ps1` |

**Note:** `skills-ref` requires the skill directory's basename to equal the skill name, so validate
`wgm` from the repository's parent directory and the companions from inside `companions/`.

## What to do next

- [Contributing](../../CONTRIBUTING.md) — development prerequisites and the contribution flow.
- [Artifacts](artifacts.md) — every file wgm reads and writes.
- [Harness portability](../../references/harness-portability.md) — what `check-harnesses.sh` enforces, and which harnesses are actually verified.
- [Backpressure in depth](../../references/ralph-loop.md) — the discipline these gates implement.
