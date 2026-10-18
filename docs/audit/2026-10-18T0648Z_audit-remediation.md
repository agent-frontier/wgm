# Docs Audit Report — 2026-10-18T0648Z — audit-remediation

**Verdict: GREEN for the bounded corrections; no remaining implementation blocker.**
**Delivery at filing: pending final deterministic gates, PR approval/CI, merge/main CI and release verification.**

- **Scope:** all A1–A12 and O1–O2 from the [original RED report](2026-10-18T0618Z_docs-self-meta-review.md),
  introduced regressions and v0.5.1 preparation; not another repository-wide or security audit.
- **Track / trigger:** Full; final correction audit and Ship/Handoff preparation.
- **Source:** original `c7b031799b58c0b50ce8f5762e65ac390d81063c`; final personas reviewed
  `33e5f0b7d98771a4fcf39e7c497c771ba0465bb7`; focused documentation confirmations followed
  `f1bebc030748494be7a1c1eab79af9274277480a`.
- **Operational candidate:** `a2fcf73d96643f1faa0bcbe48d890df4d98c5433`. Its five-file V1 diff
  from `f1bebc0` has SHA-256 `e7e9f6c7fa0cf216c018324254262cfee958c53909560d3f84db2bb71fff72f5`.
  Finalization verified that identity and the observer-tested `audit.sh` bytes.
- **Method:** four independent final persona contexts, supplied blind to sibling findings,
  followed by the existing separate writer and targeted finalization checks. Later V1 evidence
  is attributed separately; independence of models or tools is not claimed.
- **Timestamp / placement:** `0648Z` identifies the remediation run, not its later evidence cutoff.
  This repository retains its tracked `docs/audit/` paper trail; historical reports stay unchanged.

## Persona findings

### Junior developer — clarity and onboarding

The `33e5f0b` worked example omitted continuation after `build only`: a real **AMBER**
finding despite other scoped GREEN results. `docs/get-started/first-build.md:147–156`
now resolves blockers and invokes `/wgm build` before demo/handoff; the junior independently
confirmed the `f1bebc0` correction. Other original IDs were verified. Missing-base `--warn`
returned 2; the original RED report passed structure checking and the 1729 growth report failed.
This persona inspected installer/guard fixtures rather than rerunning them.

### Senior developer — correctness, completeness and maintainability

**Scoped GREEN:** all fourteen IDs checked without a substantiated remaining defect at
`33e5f0b`. Help/error probes supported the contracts. JSON parsing and Bash syntax checking
were not represented as new execution of the Stage 10 example. Later V1 behavior, final CI
and publication require their separate evidence below.

### Principal developer — architecture, strategic fit and consistency

No remaining RED/AMBER issue in the initial source review; one minor **GREEN observation**
remained in the consent aside. `references/artifacts.md:211–217` no longer calls all `.wgm`
local/ignored: it explains that Triage does not discover consent there. The principal independently
confirmed `f1bebc0`; fixed `.github/` placement is unchanged. The initial A7 source confirmation
preceded, and did not disprove, the later access-observer failure.

### Project manager — status, risk and traceability

**Bounded GREEN:** all fourteen IDs checked without a substantiated PM regression. Action
category, completion, policy decisions and publication are distinct. v0.5.1 metadata is prepared,
not evidence of publication. Filing, final acceptance, CI, merge and release remain separate
delivery dependencies.

## Consolidated report

### README index check

The review follows `README.md` and `docs/README.md`: Get started → Operator guide → Concepts
→ Reference → Plans and roadmap → Audit trail. A11 now points public scope to the versioned
Stage 10 reference. The writer found no missing local targets in the inspected indexes;
this was not exhaustive orphan, anchor or external-URL validation. Companion skills are outside
this correction scope. Native validation and newest-first indexing of this report are filing gates.

### Agent actions — A1–A12 closure dispositions

Every row is an **Agent action**, not an implicit assignment or publication claim.
J/S/P/M retain the original junior/senior/principal/PM candidate IDs. Evidence keys are below.

| ID / section | Original severity / origin | Correction and source | Closure evidence / boundary |
|---|---|---|---|
| A1 / Get started | RED / J1 | Explicit planning stop, approval, one iteration and continuation. `docs/get-started/first-build.md:76–103,147–156`; `SKILL.md:30–40`; `895ccad`, then `f1bebc0`. | Corrected: T3, D and independent junior confirmation. No model-driven first-build journey claimed. |
| A2 / Operator guide | RED / S3 | Between-iteration runtime limit distinguished from the opt-in agent watchdog and any global deadline. `docs/operator/running-the-loop.md:134–148`; `scripts/loop.sh:843–845`; `895ccad`. | Corrected: T3 and writer help probe, exit 0. No new end-to-end deadline implemented. |
| A3 / Operator guide | AMBER / J4 | Action kind no longer means assigned, queued or completed. `docs/operator/playbook.md:99–106`; `895ccad`. | Corrected: T3 and source comparison with the consolidation discipline. |
| A4 / Reference | RED / S1 | Commit-only base resolution, root-normalized inspection and propagated Git failures. `scripts/check-doc-sync.sh:54–106`; `81f273d`, CI fixture correction `dbd9d73`. | Corrected: T1; writer missing/non-commit `--warn` probes both exited 2 with ERROR and no GREEN. |
| A5 / Reference | RED / J2, S2, P1, M1 | Selective downstream ignores retain durable artifacts in both layouts; blanket-rule migration explained. `docs/reference/artifacts.md:95–122`; `references/artifacts.md:14–17,211–217`; `7c431ed`, `f1bebc0`. | Corrected: T2 exercises the published ignore block; principal confirmed the consent aside. Tool-repository dogfood exception preserved. |
| A6 / Reference | RED / J3 | Complete harmless JSON and single Bash continuations. `docs/reference/stage10.md:183–223`; source-extracting `scripts/test-stage10-runner.sh:329–370`; `895ccad`. | Corrected: T3 and actual-block execution: exit 0, exact argv, `shell=false`, fixture evidence and matching manifest hash. |
| A7 / Reference | AMBER / P1 | Durable `.wgm` mutation guards and exact scratch/holdout exclusions; V1 filters a private index before worktree inspection. `scripts/audit.sh:606–729`; `7c431ed`, then `a2fcf73`. | Corrected: V1, independent spec/quality PASS, calibrated original observer and F2. Nonblocking permanent-test reservation retained below. |
| A8 / Reference | AMBER / S4, P2 | Canonical resources resolve from the installed skill root; missing resources refuse dispatch. `scripts/audit.sh:294–315`; `scripts/test-audit.sh:1425–1465`; `7c431ed`. | Corrected: T2 uses tracked source, fixture HOME and paths with spaces against a target without wgm's source layout. |
| A9 / Reference | AMBER / M2 | CI includes audit/devcontainer harnesses; literal inventory is checked. `Makefile:44–70`; `.github/workflows/ci.yml:120–144`; `scripts/test-devcontainer.sh:150–162`; `81f273d`, `dbd9d73`, `29d03fe`. | Corrected: T1/F1/F2; all 27 local Bash harnesses represented. Numeric UID:GID and writable-mount assertions replace username assumptions. Inventory is not conditional-execution proof. |
| A10 / Reference | AMBER / M5 | `audit: COMPLETE` and native checking describe structural completion, not qualitative approval. `scripts/audit.sh:248–260,949`; `7c431ed`. | Corrected: T2 RED/AMBER fixtures and N's actual original RED report. Its qualitative verdict remains RED. |
| A11 / Plans and roadmap | AMBER / M3 | Versioned Stage 10 scope is public authority; local plans/briefs describe individual runs. `README.md:53`; `docs/reference/stage10.md:13–18`; `895ccad`. | Corrected: T3 and index/source checks. Original workspace-bounded finding is not widened into a universal clone defect. |
| A12 / Audit trail | AMBER / J5, S5, P5, M4 | Shared native/portable nonempty-section enforcement, including dissent and table edges. `assets/docs-audit-report.template.md`; `references/docs-audit.md`; `scripts/audit.sh:127–260`; `7c431ed`. | Enforcement corrected: T2/N. Historical dissent is explicitly unknown below; actual filing/check/index results are recorded separately. |

### Operator actions — O1/O2 preserved-policy decisions

These remain **Operator action** classifications: deviations require human authority.
The remediation preserves existing requirements and grants no exception.

| ID / section | Original severity / origin | Preserved decision and source | Evidence / disposition |
|---|---|---|---|
| O1 / Concepts | AMBER / P3 | Require fresh non-author reviewers or independent human handoff; block Review when unavailable. Inline ruggedness cannot satisfy either correctness pass. `SKILL.md:331–335`; `references/subagents.md:80–92`; `895ccad`. | Guidance corrected under preserved policy: T3 covers obsolete wrapped formulations and permitted fallbacks. No author-review waiver approved. |
| O2 / Reference | AMBER / P4 | Preserve published ancestry, record offending SHA and forward-only correction/attestation, and require an explicit maintainer decision. `SKILL.md:419–423`; `docs/reference/gates.md:70–76`; `895ccad`. | Guidance corrected: T3 preserves the offending SHA/message and keeps its audit range RED. Equal trees or later attestation do not erase a violation. |

### Verification evidence and attribution

T1–T3 are recorded implementation/review evidence, not fresh writer executions. Independent
spec/quality PASS and RUGGED records remain in `.wgm/rugged/audit-remediation-T1.md`, `-T2.md`
and `-T3.md`; earlier negative rounds are retained. Reviewed lanes were integrated at `8eaf4cf`
after refreshing and passing the combined affected gates.

| Key | Command or evidence | Actual result / snapshot |
|---|---|---|
| T1 | `bash scripts/test-check-doc-sync.sh`; `bash scripts/test-check-docs.sh` | Recorded focused gates exited 0, including corrected CWD and inspection-failure cases. |
| T2 | `bash scripts/test-audit.sh`; `bash scripts/test-install.sh`; `bash scripts/sync-agent-adapters.sh --check` | Recorded focused gates exited 0. Earlier passes did not establish A7's no-read guarantee. |
| T3 | `bash scripts/test-stage10-runner.sh`; `bash scripts/test-check-trailers.sh`; `bash scripts/test-check-docs.sh`; `make lint docs` | Recorded focused gates exited 0; actual published block executed; governance regressions preserve strict review/history rules. |
| D | `bash scripts/check-docs.sh`; `git diff --check` | Parent reported exit 0 for the `f1bebc0` documentation corrections; writer/finalizer verified the actual commit diff. |
| V1 | `bash scripts/test-audit.sh && shellcheck scripts/audit.sh scripts/test-audit.sh && bash scripts/check-docs.sh` | Passed on the exact five-file repair, independently rerun by parent and committed unchanged as `a2fcf73`. |
| F1 | `make validate` | Parent exit 0 on `33e5f0b`, log `final-make-validate.log`; hosted CI and actionlint also succeeded there, before V1. |
| F2 | `make validate` | Parent exit 0 on `f1bebc0` plus the exact V1 diff, now `a2fcf73`; log `v1-full-validate.log`. No code changed during the run; writer/finalizer verified final GREEN and observer entries. |
| R | `bash scripts/test-release-index.sh && make docs` | Version preparation passed at `33e5f0b`; four current metadata/example files use 0.5.1. Not publication evidence. |

Writer directly ran `bash scripts/loop.sh --help` (exit 0), plus missing-ref and
`HEAD^{tree}` doc-sync probes under `--warn` (both exit 2, ERROR and no GREEN).
**N — actual native-report controls:** the original October RED report exited 0, structure valid;
both August growth finals exited 1, missing Dissent. All three input hashes stayed unchanged.
Structural acceptance did not change the original qualitative RED verdict.

Parent's clean Git-archive packaging preflight at **`33e5f0b`**, not V1, passed release-record
validation, both checksums, eight canonical audit-resource byte comparisons, private-state
exclusion and extracted-tree native checking. Its artifacts were cleaned. This was not
published-release download verification.

### A7/V1 — contrary evidence and verified resolution

The independent holdout observer found Git 2.34.1 opening/reading excluded **tracked synthetic
canaries despite pathspecs**. Earlier source reviews and green checks missed this; the affected
step scored 67 and blocked closure. V1 rebuilds a filtered copy of the caller index per snapshot;
metadata filtering precedes worktree inspection, overrides are command-local and errors abort.

- Independent spec **PASS / RUGGED at 11:16:09Z** is bound to the exact repair in
  `.wgm/rugged/audit-remediation-V1.md`; independent quality subsequently returned **PASS**.
- The original calibrated inotify/strace observer reproduced **four opens/four reads with old
  code**, then **zero accesses and zero traced opens/reads** with V1, including alternate-index
  and subdirectory dispatch and tracked ignore-file canaries.
- Index bytes, mtime, inode, size, staging separation and reviewer environments were preserved.
  Durable/index-only mutations stopped terminally without reversion/retry; corrupt indexes refused
  dispatch. A precise private-only enumeration-failure probe stopped before reviewers or worktree
  inspection, without access or filing.
- Observer-tested `scripts/audit.sh` SHA-256:
  `cdc2760e4f1eb32084a24a0667fb4619d6d373d4afbc373fff510fe52408965a`;
  finalization independently matched it to committed `a2fcf73`.
- No actual private holdout data reached any agent. The ten core steps and subsequently judged
  report-dependent step all score 100; completed tier/overall results are recorded below.

### Rejected findings — mitigated, not erased

No original numbered defect is retroactively declared false. These observations were rejected
only as *remaining* findings after correction.

| Observation | Raised by | Verification / disposition |
|---|---|---|
| First-build continuation still missing | Junior | Actual `f1bebc0` diff and independent confirmation: real AMBER at `33e5f0b`, resolved by explicit `/wgm build`. |
| Consent aside still treats all `.wgm` as local/ignored | Principal | Actual `f1bebc0` diff and independent confirmation: real minor residue, resolved by explaining Triage discovery without changing placement. |

### Dissent

There was no initial unanimity. The junior AMBER and principal observation retain their actual
resolutions; no additional substantive persona disagreement was recorded. Differing coverage
does not establish agreement or contradiction.

| Subject | Preserved observation | Disposition |
|---|---|---|
| Junior continuation gap | Initial AMBER despite other bounded GREEN reports | Agent action A1: resolved and independently confirmed, not averaged away. |
| Principal consent aside | Minor GREEN observation absent from other lenses | Agent action A5: resolved and independently confirmed. |
| V1 permanent-test phase isolation | Generic enumeration failure can stop at initial caller-index validation | Nonblocking Agent action A7 reservation: a dedicated permanent private-only case would strengthen coverage. Independent precise failure probes passed; that does not erase the reservation. |
| August historical dissent | **Not recorded / unknown** | Preserve originals. Missing records prove neither unanimity nor absence of reviews. |

## Filing and remaining delivery gates

The actual native report check and `bash scripts/check-docs.sh` both exited **0** before
indexing; `git diff --check` also passed. The report is now indexed newest-first. Filing command:

```bash
bash scripts/audit.sh --check-report docs/audit/2026-10-18T0648Z_audit-remediation.md
```

The existing independent validator completed the actual report step at **100/100**:
all **11 steps**, each of **tiers 1, 2 and 3**, and **overall satisfaction** score **100/100**
against threshold 95. The append-only `.wgm/scores.md` retains prior failed/pending observations.
Judgment covered report blob `c87555acc61788fd4805fb5a4ad8b7c9cc9282a8` before this factual
score update, verified all fourteen dispositions, the actual index and unchanged historical reports.
No core probes were rerun. Satisfaction is not Ship or release authorization.

Finalization must run the exact T4 gate (`make validate`,
the report check above and `bash scripts/check-docs.sh`), audit all introduced commit trailers
and require final PR checks and non-author approval before merge.
Main CI, an unused `v0.5.1` tag on verified merged source, the existing Release workflow and
downloaded asset/checksum/metadata/resource verification remain later gates. Their results belong
to the [PR delivery record](https://github.com/agent-frontier/wgm/pull/116) and local plan,
not retrospective claims in this dated audit. **0.5.1 is prepared, not published at filing.**

## Verdict history and historical integrity

- The [original October report](2026-10-18T0618Z_docs-self-meta-review.md) remains
  **RED: five RED and nine AMBER findings**. This is subsequent correction, not a rewritten verdict.
- August capability baseline/final remain RED/AMBER; both growth finals remain AMBER.
  Their dissent is **not recorded / unknown**, not reconstructed agreement.
- Writer verified all four August reports unchanged against `c7b0317`; finalization verified
  every existing audit report unchanged against `0cfcb6c`. Only this report and its index are added.

## Telemetry and limits

- Baseline **06:48:02Z → initial ready-for-validation `33e5f0b` at 09:52:43Z: 3h04m41s**.
  Later documentation/V1 corrections occurred afterward; this is not total delivery wall time.
  Lane, active/parked-agent, concurrency, critical-path and timed/missing coverage telemetry
  were not instrumented and are unavailable, not estimated.
- Before/after guards cannot detect an exact within-turn revert; mutation origin remains unknown.
  Large-tree/index cost and non-Linux observer behavior are not qualified.
- Writer/finalizer checks are targeted verification, not additional persona audits. Actual holdouts
  belong only to the independent validator; fixture behavior does not certify live model quality,
  provider qualification or Windows-origin field behavior.
- `.github/wgm-hive.yml` retains `consent: false` and `auto_report: false`; no upstream lessons,
  third-party knowledge publication or real-operator-HOME installation is authorized.
