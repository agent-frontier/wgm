# Docs, self, and audit-of-audits review

**Verdict: RED - 5 RED and 9 AMBER findings.** The existing checks pass, but do not
establish several documented guarantees. This review records 12 Agent actions and
2 Operator actions; it does not implement or automatically queue them.

- **Date / evidence cutoff:** 2026-10-18T0618Z.
- **Source baseline:** `c7b031799b58c0b50ce8f5762e65ac390d81063c`, captured at
  2026-10-18T05:46:12Z with a clean worktree.
- **Track / trigger:** Standard, explicit review-only request: docs audit, self-audit,
  and audit-of-audits using multiple personas.
- **Method:** four independent persona contexts, then a separate writer verifying and
  consolidating their findings. Twenty candidate IDs map to the 14 findings below.
- **Scope:** contributor/operator entry points, protocol and reference contracts,
  candidate-relevant scripts and CI, and the four prioritized August audit reports.
  This is not an exhaustive code, security, external-link, or orphan-document audit.
- **Artifact placement:** this requested repository review extends the existing
  tracked `docs/audit/` paper trail. Existing plans, specs, and `AGENTS.md` are unchanged.

## Results by requested layer

| Layer | Verdict | What the evidence establishes |
|---|---|---|
| Documentation | RED | Incorrect approval-pause expectations, artifact-retention advice, runtime-limit wording, and a broken command example. |
| wgm self-audit | RED | A false-green comparison check, overstated CI coverage, and unresolved review/history-governance contracts. |
| Audit-of-audits | AMBER | Missing historical dissent records and limitations in resource resolution, mutation coverage, and verdict presentation. |

## Persona findings

Original severities and every candidate ID are preserved here. Different coverage
does not imply disagreement or endorsement by a persona that did not raise an item.

### Junior developer - clarity and onboarding

| Candidates | Original severity | Verified disposition |
|---|---|---|
| J1: approval pause; J2: ignored deliverables; J3: broken Bash example | RED | A1, A5, A6 |
| J4: action category mistaken for completion; J5: missing dissent | AMBER | A3, A12 |

### Senior developer - correctness and maintainability

| Candidates | Original severity | Verified disposition |
|---|---|---|
| S1: invalid-base GREEN; S2: ignored deliverables; S3: hard-deadline claim | RED | A4, A5, A2 |
| S4: installed audit resources; S5: missing dissent | AMBER | A8, A12 |

### Principal developer - architecture and consistency

| Candidates | Original severity | Verified disposition |
|---|---|---|
| P1: durable artifacts treated as scratch in ignore rules and snapshots | RED | A5; separate snapshot observation narrowed to AMBER A7 |
| P2: installed resources; P3: author-review fallback; P4: published-history repair; P5: missing dissent | AMBER | A8, O1, O2, A12 |

### Project manager - status and traceability

| Candidates | Original severity | Verified disposition |
|---|---|---|
| M1: downstream evidence retention | RED | A5 |
| M2: CI parity; M3: Stage 10 status pointer; M4: missing dissent; M5: GREEN banner | AMBER | A9, workspace-bounded A11, A12, presentation-only A10 |

## Consolidated report

### README index check

The sections below follow the Get started, Operator guide, Concepts, Reference, and
Plans/audit navigation in `README.md` and `docs/README.md`. Structural checks passed
on the baseline. A11 concerns a semantic status pointer, not a missing Markdown link.
No exhaustive orphan, anchor, or external-URL coverage is claimed.

### Agent actions - all OPEN

Classification means an agent can perform the action, not that it has been assigned,
queued, or completed. Citations refer to the pinned source unless stated otherwise.

| ID / section | Severity / raised by | Verified finding and evidence | Required action |
|---|---|---|---|
| A1 / Get started | RED / J1 | Tutorials promise a plan-approval pause after a full-lifecycle invocation (`docs/get-started/first-build.md:30-38,73-95`; `docs/get-started/README.md:112-124`). Only single-phase modes guarantee that stop (`SKILL.md:30-40,257-285`). Source contradiction; no model run. | Show an explicit `plan:` invocation, followed by a separate `build only` continuation after approval. |
| A2 / Operator guide | RED / S3 | The advertised "Hard wall-clock cap" (`docs/operator/running-the-loop.md:134-136`) checks elapsed time only before another iteration (`scripts/loop.sh:830-845`). It does not interrupt an active agent or project gate; the separate agent watchdog is opt-in (`416-421,724-754`). | Describe a between-iteration limit and distinguish the watchdog from an end-to-end deadline over agents, gates, and retries. |
| A3 / Operator guide | AMBER / J4 | `docs/operator/playbook.md:99-102` calls Agent-action rows already fixed/queued. The actual category specifies who can act; the writer and dispatcher only consolidate/file (`references/docs-audit.md:126-136`; `.github/agents/wgm-docs-writer.agent.md:66-73`; `scripts/audit.sh:689-702`). | Separate action category from status and require explicit assignment or closure evidence. |
| A4 / Reference | RED / S1 | An invalid `--base` emits Git fatal errors, then `doc-sync: GREEN` and exit 0 without `--warn` (`scripts/check-doc-sync.sh:60-87`; `docs/reference/gates.md:55-64`). Reproduced below. | Reject unresolved/non-commit bases, propagate comparison failures, document the error, and add regression coverage. |
| A5 / Reference | RED / J2, S2, P1, M1 | Downstream instructions place durable artifacts under `.wgm/`, then recommend ignoring all of it (`docs/reference/artifacts.md:8-14,35-38,89-104`). This hides new plans/specs/audits from ordinary staging despite the retention rule (`references/artifacts.md:235-244`). wgm's own dogfood exception is legitimate. | Replace the downstream blanket ignore with selective scratch exclusions; verify both placement modes in disposable fixtures. |
| A6 / Reference | RED / J3 | Three double-backslash continuations break the literal Stage 10 Bash example (`docs/reference/stage10.md:192-195`). It exits 127 before manifest handling (`scripts/stage10_runner.py:666-680`). Reproduced below. | Use single continuations and exercise the corrected block with a harmless disposable manifest. |
| A7 / Reference | AMBER / P1 | Audit snapshots exclude `.wgm` from content fingerprints, status, and staged/unstaged diffs (`scripts/audit.sh:426-428,447-454`), including uncommitted durable artifacts. Fixing A5 does not fix this. The exclusion is disclosed (`docs/reference/cli-audit.md:105-124`); HEAD/stash guards remain. Source inspection, not a mutation reproduction. | Exclude dispatcher scratch specifically and test durable-artifact mutation detection without opening holdouts. |
| A8 / Reference | AMBER / S4, P2 | Installed dispatch runs from the target root (`docs/reference/cli-audit.md:14-21`), but its prompts name bundled briefs, discipline, and template relative to that target (`scripts/audit.sh:192-194,226-228`). Inline instructions partly mitigate missing canonical resources. No downstream model failure was exercised. | Resolve or embed instructions from the installed skill root; test a target without wgm's source layout. |
| A9 / Reference | AMBER / M2 | The local-suite-plus CI claim (`docs/reference/gates.md:15-23`) exceeds the workflow: `Makefile:60-61` includes `test-audit.sh` and `test-devcontainer.sh`; `.github/workflows/ci.yml:64-160` includes neither. Scoped call-site checks found no indirect replacement. | Reconcile inventories, run the free audit harness in CI, and explicitly document any engine-dependent exclusion. |
| A10 / Reference | AMBER / M5 | `scripts/audit.sh:534-546,696-702` checks report shape and prints `audit: GREEN` regardless of qualitative verdict. Exit 0 is correctly documented as successful consolidation (`docs/reference/cli-audit.md:174-180`); the defect is the ambiguous banner, not that exit contract. | Label dispatch completion separately from findings and add RED/AMBER report fixtures. |
| A11 / Plans | AMBER / M3 | `README.md:53` points to local artifacts for current Stage 10 scope, but this checkout's ignored `.wgm/IMPLEMENTATION_PLAN.md:3-10,75-87` covers completed Stage 8.5/9 growth. Nearby README text already links the versioned Stage 10 reference and labels local state unshipped. This is workspace-bounded evidence, not a universal installed-clone failure. | Make the versioned Stage 10 reference the public scope entry point and distinguish local task state from shared authority. |
| A12 / Audit trail | AMBER / J5, S5, P5, M4 | Neither final growth report records dissent or explicit no-dissent (`docs/audit/2026-08-20T1729Z_growth-opportunities-final.md:1-94`; `docs/audit/2026-08-20T1731Z_growth-opportunities-final.md:1-90`). The requirement predates them; see historical verification below. | Require the disposition before native-path indexing. Preserve originals; any historical addendum must use recovered evidence or explicitly state that dissent was not recorded. |

### Operator actions - all OPEN

These concern policy choices, not permission for the agent to rewrite history or
silently weaken an existing gate.

| ID / section | Severity / raised by | Verified conflict | Decision needed |
|---|---|---|---|
| O1 / Concepts | AMBER / P3 | The non-author review rule (`SKILL.md:330-335`; `references/subagents.md:101-104`) is not reconciled with the weaker serial-inline fallback (`references/subagents.md:80-85`; `docs/operator/troubleshooting.md:111-117`). | Require an independent non-author handoff, or explicitly approve a policy deviation. Serial author passes cannot silently satisfy the current rule; inline ruggedness is a separate permitted fallback. |
| O2 / Reference | AMBER / P4 | Same-parent replacement of a published merge (`SKILL.md:413-422`; `docs/reference/gates.md:51-53`) produces a sibling, not a descendant. Replacing the original rewrites ancestry; merging forward retains its noncompliant message. Equal trees do not repair immutable metadata. | Approve a forward-only correction/attestation or explicit historical exception, including how trailer checks recognize it. No history rewrite was attempted. |

## Verification and reproducibility

| Check | Actual result and boundary |
|---|---|
| Parent: `bash scripts/check-docs.sh` | Exit 0: 91 files, 41 Mermaid diagrams, 12 agent files; `docs: GREEN`. Structural evidence, not semantic correctness. |
| Parent: `make validate` at the pinned baseline | Exit 0: `validate: GREEN`. Included the audit harness and real-engine devcontainer fixture cases. Windows-boundary simulations remain explicitly unverified field evidence. |
| Parent: `bash scripts/check-docs.sh` after adding only the report/index | Exit 0: 92 files, 41 Mermaid diagrams, 12 agent files. This verifies the report's structure, not remediation of its findings. |
| `bash scripts/check-doc-sync.sh --base wgm-audit-nonexistent-base-c7b0317` | Exit 0 despite Git fatal errors; then `no changes to inspect` and `doc-sync: GREEN`. This reproduces A4, not a successful comparison. |
| `git check-ignore --no-index -v -- .wgm/IMPLEMENTATION_PLAN.md .wgm/docs/audit/example.md` | Both match `.gitignore:4:/.wgm/`; demonstrates the copied rule's mechanics, not a defect in this repository's deliberate exception. |
| `git ls-files --others --ignored --exclude-standard -- .wgm/IMPLEMENTATION_PLAN.md ':(exclude).wgm'` | No output; the same query without the exclusion lists the local plan. Source inspection establishes the additional tracked-diff exclusion in A7. |
| `bash scripts/loop.sh build --dry-run --max-runtime-seconds 1 -- true` | Exit 0; `max_runtime=1s`, `agent_timeout=0s`. No capability probe or agent execution. |
| `bash scripts/audit.sh --scope 'docs/ and README.md' --dry-run -- true` | Exit 0; four personas then writer; no invocation or report creation. This preview is not evidence of a completed portable audit. |
| `bash scripts/audit.sh --scope` | Exit 2; `--scope requires text`. |
| `bash scripts/audit.sh --dry-run --slug '../invalid' -- true` | Exit 2; lowercase-slug refusal before dispatch. |
| `grep -nE 'test-(audit\|devcontainer)\.sh' Makefile .github/workflows/ci.yml` | Only `Makefile:60-61` matches. Source inventory comparison, not a remote CI result. |

The writer ran the published Stage 10 block unchanged:

```bash
sed -n '192,195p' docs/reference/stage10.md |
  PYTHONDONTWRITEBYTECODE=1 BASH_ENV= timeout 10s bash --noprofile --norc
```

It exited **127**, reporting missing `--root, --manifest`, followed by `--root`,
`--manifest`, and `--output: command not found`. The timeout did not fire.

For A12, `git --no-pager show 15694c3^:references/docs-audit.md` at lines 109-113 and
`git --no-pager show 15694c3^:assets/docs-audit-report.template.md` at lines 68-74
establish the pre-existing requirement. That parent is
`692760791e028cae468631610f431e3bc25a0887`. A case-insensitive search for
`dissent|unanimous` across both complete growth reports returned no matches.

## Rejected findings

No numbered candidate was wholly rejected. These screening hypotheses were rejected
against qualifying text; they are not additional findings.

| Hypothesis | Verification / disposition |
|---|---|
| First-build still requires a nonexistent demo as a literal runnable artifact | `docs/get-started/first-build.md:3-4,143-150` requires real-project substitutions. Rejected; A1 is a separate approval-pause defect. |
| Ignored dogfood files must ship in every clone | `references/artifacts.md:235-244` explicitly permits this tool repository's exception. Rejected; A5 concerns downstream advice. |
| Portable scripts must launch host-native subagents | `references/docs-audit.md:3-10` and `references/harness-portability.md:19-30` disclose the ownership/fallback boundary. Rejected; A8 and O1 are narrower conflicts. |
| The growth record certifies full Stage 9 autonomy | `docs/plans/2026-08-20_WGM_STAGE_8_PLUS_GROWTH.md:162-175,208-213` names missing autonomy and says "Not met." Rejected. |
| An old landscape snapshot is automatically a misleading current survey | `docs/plans/2026-06-16_RALPH_LANDSCAPE.md:10-18` explicitly labels it non-living and redirects to provenance. Rejected; no fresh external survey is claimed. |

## Dissent and verification narrowing

**No persona disagreement was recorded in overlapping findings.** This does not
mean every persona independently endorsed every item.

- P1's compound RED survives as A5; its separately verified snapshot observation is
  AMBER A7 because the exclusion is disclosed and no mutation was exercised.
- M3 remains AMBER only for the inspected workspace's pointer. The local-only qualifier
  and nearby versioned guidance rule out a universal shipped-product claim.
- M5 remains AMBER only for banner ambiguity. Successful consolidation's documented
  exit semantics are not themselves a defect.

## Verdict history

The [capability baseline](2026-08-20T0718Z_capability-hardening-baseline.md) was RED;
its [focused final](2026-08-20T0744Z_capability-hardening-final.md) was AMBER. The
[1729 growth final](2026-08-20T1729Z_growth-opportunities-final.md) and
[1731 growth final](2026-08-20T1731Z_growth-opportunities-final.md) were also AMBER.
This broader, later RED verdict is not a like-for-like regression measurement.

Those reports' deterministic-green statements remain dated, scoped claims.
Their persona headings do not independently prove invocation provenance. The missing
dissent disposition is a contemporaneous integrity gap, not proof of disagreement,
absent reviews, or invalid historical test results. The outcome cannot be reconstructed
from the inspected records; no unanimity has been invented or retroactively added.

## Self-audit of this run

- Four real, independent persona contexts preceded the separate writer. Independence
  of models or tooling is not claimed. The orchestrator checked candidate accounting,
  citation bounds, report wording, and validation output; that is not another independent
  persona pass.
- Reviews left tracked source unchanged. The only deliverables are this report and
  its index entry. No underlying finding was remediated and no existing audit was rewritten.
- The full suite exercises local fixtures, including disposable container cases;
  it does not certify live model behavior, downstream installations, Windows-origin
  field behavior, provider qualification, deployment, or remote merge recovery.
- Root `specs/CONSTITUTION.md` and the plan used for A11 are ignored workspace evidence,
  not files shipped by the pinned commit. Holdouts were not opened or scored.
- No build loop, readiness score, satisfaction score, or product Ship approval applies.
  An audit can be complete while its audited subject remains RED.
- Build-style wall-to-ready-test, allocated-lane, active/parked-agent, peak-concurrency,
  and critical-path clocks were not instrumented. Five role invocations have no collected
  per-turn durations (0 timed / 5 missing); no worktree lanes were used (0 / 0).
  The four persona calls were submitted in parallel; no speedup or billing claim is made.
- `.github/wgm-hive.yml:2-3` declines upstream lesson reporting. No learning issue or
  external knowledge post was created.
