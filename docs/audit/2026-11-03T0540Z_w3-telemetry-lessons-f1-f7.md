# Docs Audit Report — PRs #174–#176 — consolidation

> Four persona reports consolidated by `wgm-docs-writer`. Findings below were checked against the actual source artifacts using read/search tools. No commands, published examples, harnesses, or signal tests were executed in this consolidation.

- **Scope:** Post-merge audit of PR #174 (`7672a757`, resolution of #163 findings F1–F7), PR #175 (`df6264d1`, efficiency telemetry and 17 promoted lessons), and PR #176 (`974d29d0`, lesson #173). Limited to the changed validation recipes, scoring/validator rules, grading harness, telemetry documentation/implementation/harness/wiring, and specified lesson fold-ins and 18 fragments.
- **Track:** Standard, consolidated post-merge pass.
- **Trigger:** Batched Ship/Handoff documentation audit.
- **Overall verdict:** **RED** — senior-raised RED telemetry findings remain supported by source inspection. Other personas’ differing severities are preserved below, not averaged.
- **Disposition:** 12 **Agent action** items and 2 **Operator action** items. No source files edited.
- **Delivery:** STDOUT for dispatcher capture into `.wgm/audit-run-oGAD0H/wgm-docs-writer.md`; this host exposes no file-writing tool.
- **Evidence boundary:** Source verification supports the findings, but does not constitute reproduced runtime evidence or executable closure.

## Persona findings

These sections retain all observations and original severities, with normalized wording and explicit links to their consolidated dispositions. Persona reports remain the original record.

### wgm-docs-junior — clarity & onboarding

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/telemetry.md` | No runnable recording walkthrough; run attribution for non-run events and the milestone `name` key are not discoverable from the schema. | AMBER | Add a minimal start → unit → verified → report walkthrough, explicit attribution, and expected completeness/wall basis. **A8**, with ownership enforcement in **A1**. |
| `references/validation-env.md` | `isolated_gate` requires exactly one prerequisite; zero- and multiple-prerequisite invocations are absent. | AMBER | Document runnable zero-, one-, and multiple-prerequisite paths restoring copies into the same isolated HOME. **A9**. |
| Scoped examples and `references/docs-audit.md` | Read/search-only tools prevented execution; no runtime pass is claimed. | GREEN | Obtain authorized execution evidence against the actual named artifacts and degraded paths. **O1**. |

### wgm-docs-senior — correctness, completeness, maintainability

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/telemetry.md`; `scripts/telemetry.py` | Events without `run` enter every selected run, allowing run-specific completion, units, candidates, and estimates to leak across runs. | RED | Specify ownership, require run IDs for run-specific events, distinguish intentional globals, and add two-run isolation controls. **A1**. |
| Same | Required ledger fields are not validated; missing unit IDs, span IDs, and candidate SHAs can enter figures without missing-field warnings. | RED | Validate fields/types before aggregation, count/exclude invalid evidence, and add malformed-event controls. **A2**. |
| Same | Sessions use the full run window while the wall denominator may stop earlier at ready/verified. | AMBER | Align accounting cutoffs or explicitly separate full-window totals from gate-bounded figures. **A3**. |
| Same | Negative session intervals and negative duration/usage values are accepted despite the documented exclusion guarantee. | AMBER | Validate intervals and finite, non-negative measurements; add reversed-timestamp and negative-value controls, or narrow the guarantee. **A4**. |
| Same | Baseline `comparable` ignores instrumentation coverage and applies one flag to wall, active-time, and cost factors. | AMBER | Provide metric-specific comparability requirements/refusals and asymmetric-coverage controls. **A5**. |
| `references/validation-env.md` | Cleanup sends KILL but does not confirm group disappearance before removing HOME. | AMBER | Observe termination after KILL; retain/report HOME if disappearance cannot be established. **A6**. |
| `references/ralph-loop.md`; ShellCheck lesson fragment | “CI runner’s pinned ShellCheck” has no corresponding pin or retrieval procedure in this repository. | AMBER | Distinguish observed runner-version matching from a genuine pin, and supply a reproduction path. **A7**. |
| Audit execution coverage | Published procedures and harnesses were inspected, not executed. | AMBER | Complete an authorized execution pass with exact fences and degraded paths. **O1**. |

### wgm-docs-principal — architecture, strategic fit, consistency

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/telemetry.md`; `scripts/telemetry.py`; telemetry harness | Missing required fields are not validated; a gate end without `rc` enters gate totals without being counted as failed or unknown. | AMBER | Validate per-kind fields/types, disclose unknown gate outcomes, and add malformed-event controls. **A2**. |
| Same | Mixed-class rows divide whole-run active time, cost, and tokens by each class’s units, but disclose only shared wall. | AMBER | Attribute usage with evidence or label all affected numerators as shared, non-attributed run-wide usage. **A11**. |
| `references/validation-env.md`; `references/hard-to-test-domains.md` | HOME-only isolation inherits absolute XDG/application paths despite the native-validation requirement to redirect them. | AMBER | Establish scratch data/config/cache paths and preflight application overrides, or explicitly narrow the helper’s guarantee. **A10**. |
| Validation recipe; inspection tri-state lesson | Post-KILL cleanup lacks observation of absence, overstating the empty-group invariant. | AMBER | Add bounded observation and retain/report unresolved cleanup evidence. **A6**. |
| Audit evidence and constitution conformance | Runtime execution was unavailable; `specs/CONSTITUTION.md` is absent and a shipped template is not a ratified constitution. | AMBER | Complete authorized execution (**O1**) and supply the applicable constitution or explicitly record its absence (**O2**). |

### wgm-docs-pm — status, risk, traceability

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/telemetry.md`; `scripts/telemetry.py` | Missing unit IDs can change denominators, and missing expected-publication IDs are silently omitted, without missing-field disclosure. | AMBER | Validate/count/exclude invalid records and add controls that cannot silently improve completion or denominators. **A2**. |
| Same | Post-gate work can enter session numerators after the reported wall clock stops. | AMBER | Align cutoffs or label both boundaries and separate post-gate work. **A3**. |
| Same | Mixed-class usage is run-wide rather than class-attributed, while the warning names only shared wall. | AMBER | Label all shared numerators and non-additivity, or implement evidenced attribution. **A11**. |
| Same | “Pre-registered” depends only on supplied timestamps; a retrospectively appended, backdated estimate receives the label. | AMBER | Disclose timestamp-only evidence or require verifiable prior registration, with a late-append regression. **A12**. |
| Scoped procedures and harnesses | No execution, degraded-path errors, process cleanup, or verbatim-recipe execution was verified. | AMBER | Preserve the limitation and obtain authorized command/exit/log evidence before executable closure. **O1**. |

## Consolidated report

All 21 persona rows are accounted for above and below. Duplicate observations are consolidated by underlying issue; the principal’s combined evidence/constitution row has two distinct follow-ups because execution access and governing-policy confirmation require different evidence.

The scaffold follows `README.md` and `docs/README.md`: **Reference / deeper protocol**, **Operator guide / validation**, and **Local development / contributor gates**.

### README index check

**Checks performed:** `read README.md`, `read docs/README.md`, `read docs/reference/README.md`, `read references/heuristics/README.md`, `read docs/audit/README.md`; `find(pattern="**/*.md", path="docs")`; `ls references`; `ls references/heuristics`; and inspection of fragment discovery in `scripts/compile_heuristics.py`.

- **Reference / deeper protocol:** Telemetry, Ralph loop, scoring, subagents, hard-to-test domains, and validation environment are reachable through `docs/reference/README.md`. Docs-audit is linked from `docs/README.md`. The root README also maps these protocol resources.
- **Operator guide / validation:** The indexed operator containers page exists; deeper validation instructions are reachable through the reference index.
- **Local development / contributor gates:** `CONTRIBUTING.md` and `docs/reference/gates.md` are indexed. Telemetry’s harness is listed in both and invoked by the Makefile and CI workflow.
- **Lesson fragments:** `references/heuristics/README.md` explains directory-wide discovery and release-time compilation. `scripts/compile_heuristics.py` iterates the fragment directory, excluding its README. Fragment discovery is not dependent on individual README links, and a compiled ledger that lags between releases is explicitly documented.
- **Missing index targets / unindexed scoped docs:** None identified in the checked navigation paths. No persona reported an index defect. This is a bounded navigation check, not a new whole-corpus qualitative audit or a claim that the structural docs gate ran.

### Reference / deeper protocol — telemetry

The source checks below were performed with `functions.read`, not command execution:

- `read("references/telemetry.md", offset=1, limit=2000)`
- `read("scripts/telemetry.py", offset=1, limit=2000)`
- `read("scripts/test-telemetry.sh", offset=1, limit=2000)`

| Finding | Verification against the actual artifact | Disposition |
|---|---|---|
| **A1 — Run ownership** | `build()` selects `e.get("run") in (run, None)`. Completion, units, candidates, and estimates aggregate from that selection. The reference lists `run` under run events but does not establish ownership for every other kind. The harness excludes an explicitly differently tagged unit, but does not test untagged run-specific evidence across two selected runs. | Survives. Senior **RED**; junior’s related schema-discoverability concern remains **AMBER** under A8. |
| **A2 — Required ledger fields** | `read_ledger()` checks the envelope and timestamp, not per-kind required fields. `match_edges()` obtains identifiers with `.get()`. Completed units add `e.get("id")`; candidate selection checks decision, not SHA; expected publications retain only string publication fields; gate failures exclude `rc=None`. `missing_fields` increments inside session parsing, not ledger validation. | Survives. Senior **RED**; principal and PM **AMBER**. These are one validation-boundary issue, not separate actions for each missing field. |
| **A3 — Accounting boundaries** | Wall selection uses ready/verified endpoints, but sessions receive `win=(t0,t1)`, where `t1` is run end or last event. Their totals feed per-class figures and compression. The reference describes the run-window filter and wall basis separately, but does not clearly label the resulting numerator/denominator mismatch. | Survives. Senior and PM **AMBER**. This does not reject the explicitly documented distinction between ready and verified wall clocks. |
| **A4 — Negative evidence** | `parse_session()` retains a turn’s last timestamp without checking it is at least the user timestamp. `agg()` directly sums `end-start`. `num()` accepts numeric values without finite/non-negative validation. The negative-interval counter is applied to ledger edge pairing, not these session inputs. | Survives. Senior **AMBER**. |
| **A5 — Baseline coverage** | `comparable` depends on completeness, shared-class/wall state, and wall basis. It does not compare agent availability, untimed turns, usage coverage, or orchestrator inclusion. One flag accompanies all three factors. The harness asserts `comparable=true` even when its zero-cost control produces a null cost factor. | Survives. Senior **AMBER**. The implemented predicate matches the documented predicate; the finding concerns that predicate’s insufficient measurement boundaries, not undocumented behavior. |
| **A8 — First-use walkthrough** | The efficiency section contains a report synopsis and says `record` appends an event, but supplies no recording sequence. Milestone values appear without identifying `name`; the implementation reads `e.get("name")`. Runnable recording examples exist in the harness, not this first-use documentation. | Survives. Junior **AMBER**. |
| **A11 — Shared class usage** | Each class divides total agent active time and total available agent/orchestrator cost/tokens by its own unit count. Metadata exposes `shared_wall`; Markdown warns only `SHARED WALL`. “Session usage; available sources only” does not establish class attribution. The mixed-class harness checks shared wall/comparability without supplying session usage. | Survives. Principal and PM **AMBER**. |
| **A12 — Registration evidence** | Estimate classification checks `e["_t"] <= t0` after timestamp sorting. No append-position test establishes prior recording. `record()` accepts caller-supplied `ts`. The reference explicitly describes timestamp eligibility, but the emitted “pre-registered” label does not disclose that this is not proof of prior registration. | Survives, narrowly as an evidence-label issue. PM **AMBER**. |

### Operator guide / validation — isolated gate

**Checks performed:** `read("references/validation-env.md", offset=1, limit=2000)`, `read("references/hard-to-test-domains.md", offset=1, limit=100)`, and `grep` of inspection tri-state guidance in `references/ralph-loop.md`.

| Finding | Verification against the actual artifact | Disposition |
|---|---|---|
| **A6 — Post-KILL absence** | After TERM polling, the helper sends KILL, then advances without another group-disappearance check. It subsequently clears `grp` and starts HOME removal. This is weaker than “owned until empty” and “only then” removed. | Survives. Senior and principal **AMBER**. Signal delivery is established in source; completed termination is not. |
| **A9 — Prerequisite cardinality** | The function binds `src=$1 rel=$2`, shifts two arguments, and always runs the copy stage. Its sole invocation takes one source/path pair. No zero-prerequisite or same-HOME multiple-copy route is documented. | Survives. Junior **AMBER**. |
| **A10 — User-state isolation** | The gate subshell exports only `HOME`. The native-validation protocol explicitly requires redirecting `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, and app-specific data/cache/self-update paths. An inherited absolute override is not replaced by changing HOME. | Survives. Principal **AMBER**. This does not deny the helper’s HOME override; it limits the broader isolation claim. |

### Local development / contributor gates — ShellCheck and execution evidence

**Checks performed:** `read(".github/workflows/ci.yml", offset=1, limit=2000)`; `read("references/heuristics/lint-with-the-ci-runner-s-shellcheck-version.md", offset=1, limit=2000)`; and `grep` for ShellCheck/telemetry in `references/ralph-loop.md`, `Makefile`, `CONTRIBUTING.md`, and `docs/reference/gates.md`.

- **A7 survives, senior AMBER:** CI uses `ubuntu-latest` and ambient `shellcheck scripts/*.sh`; the Makefile also invokes ambient ShellCheck. The lesson says to fetch the runner’s pinned release without naming a pin or discovery/reproduction path. The workflow’s explicit jj pin is not a ShellCheck pin.
- **O1 survives:** All four reports explicitly disclose non-execution. This consolidation has the same read/search-only tool boundary. Static harness wiring is confirmed, but is not a harness pass.
- **O2 survives as a conformance limitation:** `ls(".")` shows no root `specs/`; `ls(".wgm")` shows only audit scratch/lock entries; `find(pattern="**/CONSTITUTION.md", path=".")` returns no files. The template is not evidence of ratification. No constitution-conformance verdict is claimed.

### Agent actions

Each row is classified **Agent action** because its scoped correction and regression controls can be implemented deterministically. Alternatives below preserve the personas’ recommendations; no new policy decision is prescribed.

| # | Finding / severity | Raised by | Doc(s) / artifact(s) | Action |
|---|---|---|---|---|
| A1 | Cross-run leakage from unowned events — **RED** | Senior | `references/telemetry.md`; `scripts/telemetry.py`; telemetry harness | Specify ownership for every event kind; require run IDs on run-specific events, explicitly distinguish any intentional globals, and test two-run isolation for completion, units, candidates, and estimates. |
| A2 | Missing ledger fields can produce success-shaped figures — **RED senior; AMBER principal/PM** | Senior, principal, PM | Same | Validate required per-kind fields/types before aggregation; count/exclude invalid evidence and distinguish unknown gate results. Add missing-ID/span/SHA/publication/`rc` and invalid-edge controls. |
| A3 | Session numerators extend beyond selected wall boundary — **AMBER** | Senior, PM | Same | Align cutoffs or separately label full-window and gate-bounded figures, including affected ratios/per-unit figures. Test a timed turn entirely after the selected wall endpoint. |
| A4 | Negative or invalid session measurements accepted — **AMBER** | Senior | Same | Validate session ordering and finite, non-negative duration/usage evidence, with explicit rejection counts and controls; alternatively narrow the documented exclusion guarantee to its actual scope. |
| A5 | Baseline comparability is not metric-specific — **AMBER** | Senior | Same | Separate wall, active-time, and usage comparability; disclose coverage requirements and refusals. Add asymmetric-coverage controls. |
| A6 | HOME removal precedes confirmed group disappearance — **AMBER** | Senior, principal | `references/validation-env.md`; related inspection guidance | Add bounded post-KILL observation. If absence cannot be established, retain/report HOME and unresolved cleanup evidence rather than claiming the empty-group invariant. Test a TERM-ignoring descendant and post-KILL inspection. |
| A7 | Undiscoverable “pinned ShellCheck” instruction — **AMBER** | Senior | `references/ralph-loop.md`; ShellCheck lesson fragment; CI/toolchain references | Correct the distinction between observed runner version and an explicit pin; provide version discovery/reproduction instructions, or establish a shared explicit pin before calling it pinned. |
| A8 | Telemetry first-use sequence absent — **AMBER** | Junior | `references/telemetry.md` | Add a copy-pasteable recording/reporting walkthrough with declared paths, run attribution, `name=verified`, and expected completeness/wall basis. Make fields discoverable separately from interpretation. |
| A9 | Only one-prerequisite isolation route documented — **AMBER** | Junior | `references/validation-env.md` | Provide runnable zero-, one-, and multiple-prerequisite routes, restoring verified copies into the same HOME while preserving refusal, cleanup, and signal behavior. |
| A10 | HOME-only helper leaves inherited user-state paths — **AMBER** | Principal | `references/validation-env.md`; `references/hard-to-test-domains.md` | Establish scratch XDG/data/config/cache paths and preflight app-specific overrides, or narrow the helper’s guarantee and require the extra isolation step before native-app gates. |
| A11 | Mixed-class usage lacks attribution disclosure — **AMBER** | Principal, PM | Telemetry reference, implementation, and harness | Label all affected class figures as whole-run usage normalized by that class’s unit count, explicitly non-attributed/non-additive, or implement evidenced attribution. Extend mixed-class controls to usage labels. |
| A12 | “Pre-registered” overstates timestamp-only evidence — **AMBER** | PM | Same | State that classification is timestamp-based, not proof of prior registration. If retaining a stronger claim, require verifiable pre-run evidence and reject late append positions; add a backdated-late-append control. |

### Operator actions

These require execution capability or governing-policy confirmation unavailable to this host, not merely an edit.

| # | Finding / severity | Raised by | Artifact(s) | Why it needs an operator / required disposition |
|---|---|---|---|---|
| O1 | Executability evidence unavailable — **GREEN junior; AMBER senior/principal/PM** | All four | Scoped published recipes, telemetry/grading procedures and harnesses; `references/docs-audit.md` | Arrange an authorized command-capable context. Execute exact published blocks against their named artifacts with only declared substitutions; retain commands, exits, logs, invalid-path errors, success controls, injection markers, and degraded-path evidence. Include process/signal cleanup and accounting controls. Do not treat source inspection or fixture wiring as execution. |
| O2 | Applicable ratified constitution unavailable — **AMBER** | Principal | Governing constitution; shipped template | Confirm the applicable ratified constitution, or explicitly record its absence before claiming conformance. The consolidator cannot ratify policy or substitute the template. |

### Rejected findings

**None rejected or already mitigated.** Every persona observation remains supported within the source-inspection boundaries above.

The following existing mitigations were checked but do **not** close the corresponding findings:

- Explicitly tagged other-run exclusion does not close **A1**’s untagged-event leakage.
- Envelope validation and session missing-field counters do not close **A2**’s per-kind ledger-validation gap.
- Wall-basis disclosure does not close **A3**’s session-accounting boundary mismatch.
- “Lower bound” and “session usage” labels do not establish class attribution for **A11**.
- Timestamp eligibility documentation does not establish prior registration for **A12**.
- Harness presence and CI wiring do not close **O1**.

These are retained findings, not rejected claims; no rejected-finding evidence is fabricated.

### Dissent

**Dissent is recorded.** The reports agree on the relevant observed mechanisms where they overlap, but differ on severity. A persona’s silence on another finding is not agreement or opposition.

| Finding | Persona views | Preserved disposition |
|---|---|---|
| A2 — Required ledger-field validation | Senior: **RED**, citing malformed evidence entering measured figures. Principal and PM: **AMBER**, citing unknown gate outcomes, denominators, and completion disclosure. | One **Agent action**, retaining both severity positions. Overall RED reflects the surviving senior finding; no severity averaging occurred. |
| O1 — Missing execution evidence | Junior: **GREEN**, disclosed limitation requiring follow-up. Senior, principal, PM: **AMBER**, incomplete executable audit evidence. | One **Operator action**, retaining the disagreement. No report claims execution occurred. |
| A1 / A8 — Run attribution | Senior: **RED** for cross-run aggregation. Junior: **AMBER** for first-use/schema discoverability. | Related but distinct actions: ownership enforcement **A1**, onboarding sequence **A8**. The junior report is not represented as endorsing the senior’s RED severity. |

No conflicting recommended remedy was recorded for the jointly raised cleanup, accounting-boundary, or mixed-class usage findings. That limited agreement is not four-persona unanimity.

## Structural validation and filing

The report checker was **not run**: this host has no command-execution tool. No exit `0` is claimed, and no audit index was modified.

After capturing this report, the dispatcher must apply:

```bash
bash /home/lafiamafia/wgm/.wgm/lanes/ws/audit-174-176/scripts/audit.sh \
  --check-report \
  /home/lafiamafia/wgm/.wgm/lanes/ws/audit-174-176/.wgm/audit-run-oGAD0H/wgm-docs-writer.md
```

Record the actual result before filing. Structural validity, if obtained, does not change this report’s **RED** qualitative verdict.

## Verdict history

Previous indexed entry: [`docs/audit/2026-11-02T2017Z_audit-actions-a1-a7.md`](2026-11-02T2017Z_audit-actions-a1-a7.md), recorded **RED** for the post-merge #163 audit.

This run **holds RED at the aggregate verdict level**, with a different bounded scope covering #174–#176. It does not independently establish closure of every historical F1–F7 finding, nor claim that the same historical defects remain. The outstanding execution-evidence limitation remains explicit.
