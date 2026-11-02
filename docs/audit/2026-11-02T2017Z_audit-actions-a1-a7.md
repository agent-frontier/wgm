# Docs Audit Report — PR #163 — consolidation of A1–A7 follow-ups

> Four independent persona reports consolidated by `wgm-docs-writer`. Source verification is distinguished from executable verification throughout. Completion of this report is not qualitative approval.

- **Scope:** Post-merge audit of PR #163, merge `eda6bbe` as supplied by the dispatcher. Changed surface only: the scoring worked example; canonical and Claude validator Integration; `authored-severity-regression-pause` and its pins; prerequisite-copy and repository-snapshot procedures; the every-Validate environment link; benchmark attribution terminology, implementation, tests, and gate rows; and the #145/#147/#150/#151 fragments.
- **Trigger:** Post-merge follow-up to the #152 docs audit.
- **Track:** Not specified in the supplied scope.
- **Run:** `audit-run-pU5hen`. Filing timestamp belongs to the dispatcher.
- **Overall verdict:** **RED**, retaining the senior’s source-supported snapshot finding. The PM rates the same underlying issue **AMBER**; that disagreement remains explicit below.
- **Disposition:** Seven deduplicated **Agent actions** and one **Operator action**. No finding rejected in full.
- **Delivery:** Printed to STDOUT because this host exposes no file-writing tool. Dispatcher capture target: `/home/lafiamafia/wgm/.wgm/lanes/ws/audit-163/.wgm/audit-run-pU5hen/wgm-docs-writer.md`.
- **Evidence boundary:** Verification used file reads, searches, and directory inventory. No shell command, published example, harness, or report checker was executed. No project files were edited or committed. No holdout contents were inspected.

## Persona findings

These sections retain the four reports’ observations, original severities, and recommended actions in normalized wording. They are not four additional action lists.

### wgm-docs-junior — clarity & onboarding

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/validation-env.md`; `references/ralph-loop.md` | HOME isolation is mandatory for every gate, but the procedures do not create an isolated HOME or invoke the gate with it. `copy_prereq` accepts an arbitrary destination; the snapshot example leaves HOME inherited. | AMBER | Supply a bounded end-to-end recipe preserving source paths, creating temporary HOME outside the checkout, restoring copies beneath it, explicitly setting HOME for affected checks and the full gate, and cleaning up only owned temporary directories. |
| `references/scoring.md`; canonical and Claude validator Integration | Regression is distinguished from a blocker, but the worked example does not explain when the diagnostic pause ends or what permits convergence with S4 unchanged at 70. | AMBER | Describe the post-diagnosis evidence and recorded disposition permitting convergence, and discoveries requiring remediation or establishing a substantiated blocker. |

**Execution limitation:** The junior had read/search tools only. Published examples and degraded paths were not executed.

### wgm-docs-senior — correctness, completeness, maintainability

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/validation-env.md:150–194` | `repo_snapshot` claims repository-wide coverage but never enters computed `$top`. Subdirectory invocation can omit existing untracked/ignored sibling files from content hashing, allowing their overwrites to escape comparison. | RED | Inspect from the worktree root and add a subdirectory-invocation regression covering existing ignored and untracked files elsewhere. |
| `references/validation-env.md:108–116,158` | Expected nonzero statuses use `command; rc=$?`. In inherited strict-shell execution, no-match credential scans and detached-HEAD detection can terminate before status handling. | AMBER | Capture expected nonzero statuses in conditionals and exercise the published blocks under `bash -e`, including clean sources and detached HEAD. |
| `scripts/test-grade-evals.sh:515–516`; `docs/reference/gates.md` | T7 compares jq’s numeric rendering with literal `0.5000`. jq versions rendering it as `0.5`, including jq 1.6, can cause a false non-root cleanup failure. Root skips the assertion; jq has no documented minimum version. | AMBER | Compare the JSON value numerically and exercise T7 as non-root with supported jq versions. |

**Execution limitation:** These were source-inspection findings, not runtime-confirmed failures.

### wgm-docs-principal — architecture, strategic fit, consistency

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/validation-env.md:155–173`; `references/ralph-loop.md:92` | Universal gate guidance points to unrestricted status/diffs and untracked/ignored hashing, crossing the holdout read boundary established in `references/subagents.md` and `references/docs-audit.md`. | AMBER | Define a holdout-safe snapshot for non-validator runs, excluding both holdout roots before content inspection and index refresh. Document the coverage exception and add tracked/ignored no-read regressions. |
| `references/validation-env.md:88–139` | “Never copy dotfiles” exceeds the helper’s enforcement. It clones the tracked tip after a narrower pattern scan; tracked `.gitconfig`, `.bash_history`, and other unlisted dotfiles are not categorically rejected. The configuration check examines clone-local Git configuration, not all copied files. | AMBER | Align helper and prose with an explicit exclusion or reviewed allow-list contract. Add negative coverage for tracked Git configuration and shell history. |

**Evidence limitations:** No command execution was available. The principal also reported that `specs/CONSTITUTION.md` was absent at the skill root; constitution conformance was not verified. That caveat is not a request to create a constitution.

### wgm-docs-pm — status, risk, traceability

| Doc | Observation | Severity | Recommended action |
|---|---|---|---|
| `references/validation-env.md`, repository-snapshot procedure | Repository-wide assurance depends on an unstated root-directory prerequisite. The example computes `top` without entering it; subdirectory-relative listings can miss content changes elsewhere. | AMBER | Enter the root before snapshots or enforce/document a root precondition; add an ignored-file overwrite regression outside the invocation subtree. |
| `references/validation-env.md`; `references/evals.md`; scoped harnesses | This pass obtained no execution evidence. Reading procedures, fixture pins, attribution implementation/tests, gate rows, and fragments does not certify A2/A3/A6 executability. This is an evidence limitation, not an observed runtime failure. | AMBER | Obtain execution-capable, read-only verification against real artifacts, including focused eval harnesses, attribution/ledger evidence, exact commands and exits, and an actual degraded-path diagnostic. |

## Consolidated report

Eight underlying issues remain after deduplication: seven source-supported remediation items and one access-dependent execution-evidence handoff. The senior and PM snapshot observations become one entry, preserving both severities.

All paths below resolve from `/home/lafiamafia/wgm/.wgm/lanes/ws/audit-163`. Verification identifiers refer to actual source checks performed, not shell commands claimed to have run.

### README index check

The scaffold follows `README.md` and `docs/README.md`: **Operator guide**, **Concepts: how wgm thinks**, and **Reference**, supplemented by the root README’s **Repository layout**.

Checks performed:

- Full reads of `README.md`, `docs/README.md`, and `docs/reference/README.md`.
- `find(pattern="*", path="docs", limit=1000)` returned the documentation inventory without truncation.
- Direct reads confirmed the scoped references, validator brief and adapter, eval case/pins, grading implementation/test sections, gate page, four fragments, fragment README, and previous audit report.

| Indexed surface | Evidence / disposition |
|---|---|
| Scoring, Ralph loop, validation environment | Root README names them; `docs/reference/README.md` links their deeper protocol pages. All three targets exist. |
| Evals and gates | `docs/README.md` links `references/evals.md` and `docs/reference/gates.md`; both exist. Evals links its fixture and scripts, which were inspected. |
| Validator and Claude adapter | Root Repository layout identifies canonical roles and adapters; `references/subagents.md` supplies the role table and generated-adapter mapping. Both validator files exist. |
| Four heuristic fragments | Discoverable through the documented `references/heuristics/` directory convention. The fragment README states that fragments are authoritative between releases; each scoped fragment exists with provenance and landing pins. |
| Missing indexed documentation targets | **None found** among the root/docs README documentation targets compared with the inventory and the scoped direct reads. This is not a successful structural-gate execution. |
| Docs indexed nowhere | **No disconnected scoped document found.** Individual fragments are not enumerated as individual README links, but are directory-discovered under the explicit fragment convention, rather than unindexed standalone guidance. |

No unrelated documentation-content audit was undertaken.

### Operator guide — validation environment

| Evidence | Exact source check performed | Result |
|---|---|---|
| V1 — snapshot directory | `read(path="references/validation-env.md", offset=1, limit=2000)`, especially the complete `repo_snapshot` definition and invocation block | `$top` is used for the evidence-directory containment check, but no `cd "$top"` or equivalent root-scoped inspection occurs. Untracked/ignored `git ls-files` results feed relative-path hashing. The published block therefore lacks the root normalization needed by its repository-wide assurance. Supports F1; no runtime reproduction obtained. |
| V2 — strict-shell status capture | Same full read; inspect `bad=$(...grep...); rc=$?`, `cfg=$(...); rc=$?`, and `b=$(git symbolic-ref -q HEAD); rc=$?` | Expected no-match/detached statuses are handled only after unguarded assignments. `set -o pipefail` does not disable inherited errexit. Supports F2’s strict-shell trigger; this is not a claim that the default non-errexit shell always fails. |
| V3 — holdout boundary | Full reads of `references/validation-env.md`, `references/subagents.md`, and `references/docs-audit.md`; read of `references/ralph-loop.md` lines 1–180 | The universal Validate link exists. The snapshot contains unrestricted Git inspection and file hashing, with no holdout exclusions or filtered-index preparation. Surrounding protocol requires exclusion before inspection and reserves holdout opening to the validator. Supports F3. No holdout files were opened to verify this conflict. |
| V4 — copy contract | Full read of `references/validation-env.md`, comparing prerequisite steps 2–3, `path_re`, content patterns, clone/checkout, and local-config check | The prose prohibits dotfiles and runtime state. Path patterns do not categorically exclude `.gitconfig` or `.bash_history`; content patterns do not reject arbitrary content in them. Checkout copies the tracked tree, while `git config --local` checks repository-local configuration, not these tracked files. Supports F4’s contract mismatch. The documented pattern-based disclaimer does not implement the categorical dotfile prohibition. |
| V5 — HOME setup | Full read of `references/validation-env.md`; read of the every-Validate rule in `references/ralph-loop.md`; full reads of #145/#150 fragments | HOME isolation is explicitly required, but neither published procedure creates isolated HOME or sets HOME on the gate invocation. copy_prereq "&lt;src&gt;" "&lt;dst&gt;" leaves placement to the reader. Supports F5’s missing end-to-end procedure. |

The #145 and #150 fragments reiterate the same isolation obligations; they do not supply the missing setup or repair the snapshot boundary.

### Concepts: how wgm thinks — scoring and convergence

| Evidence | Exact source check performed | Result |
|---|---|---|
| V6 — diagnostic pause completion | Full reads of `references/scoring.md`, `.github/agents/wgm-validator.agent.md`, `adapters/claude/agents/wgm-validator.md`, and the #151 fragment; `grep` of the real `authored-severity-regression-pause` case with context; full read of `scripts/test-check-evals.sh` | The example now orders blockers, regression diagnosis, and convergence, and identifies recording locations. Integration mirrors the distinction. The real eval and pins cover naming the regression, preserving scores, not inventing blockers, and retaining correctness/deterministic blocks. None specifies the post-diagnosis disposition that ends the pause. Supports F6, narrowly: not a claim that regression is still declared an unconditional blocker. |

### Reference — grading and execution evidence

| Evidence | Exact source check performed | Result |
|---|---|---|
| V7 — numeric assertion | `read(path="scripts/test-grade-evals.sh", offset=440, limit=160)`; `grep(pattern="attribution\|pass_rate\|TMPDIR\|ledger\|setsid", path="scripts/grade-evals.sh", context=2, limit=90)`; reads of `CONTRIBUTING.md` prerequisites and `docs/reference/gates.md` | T7 literally requires jq output equal to `0.5000`, while the value is stored as a JSON number. Root takes a separate visible-skip branch. jq is listed without a minimum version. This supports F7’s numeric-format portability defect; jq 1.6 behavior was not independently executed here. |
| V8 — verification availability | All four supplied reports read in full; inspected actual available tool interfaces; full read of `references/evals.md`, scoped gate rows, and the previous audit/index | Every persona reports no command execution, and this consolidation likewise has no execution tool. The inspected material supplies no executed result for these newly published procedures. Supports O1 as an evidence limitation, not proof the implementation fails. |

Attribution terminology and runner responsibilities are now explicitly documented, including private TMPDIR, channels, unavailable/error states, process groups, signal exits, and ledger records. These source-level additions do not substitute for the PM’s requested execution evidence.

### Agent actions

These are deterministic documentation, implementation, and regression-test changes under existing requirements. They are classified by action kind, not persona.

| # | Finding / severity | Raised by | Doc(s) | Action |
|---|---|---|---|---|
| F1 | Snapshot can miss existing ignored/untracked sibling-file overwrites when invoked from a subdirectory. **Senior: RED; PM: AMBER.** Verified V1; runtime unverified. | Senior, PM | `references/validation-env.md` | Root-normalize snapshot inspection. Add a regression invoking the published procedure from a subdirectory and changing existing ignored and untracked files elsewhere. Preserve baseline/concurrent-change handling. |
| F2 | Expected nonzero statuses are unsafe under inherited errexit. **AMBER.** Verified V2. | Senior | `references/validation-env.md` | Use conditional status capture for expected nonzero results. Test the actual published blocks under `bash -e`, including credential-free sources and detached HEAD. |
| F3 | Universal snapshot guidance crosses the non-validator holdout read boundary. **AMBER.** Verified V3. | Principal | `references/validation-env.md`; `references/ralph-loop.md` | Exclude both holdout roots before content inspection and index refresh for non-validator snapshots, document the coverage exception, and add tracked/ignored no-read regressions. |
| F4 | Copy helper does not enforce the categorical dotfile/runtime-state prohibition. **AMBER.** Verified V4. | Principal | `references/validation-env.md` | Make helper and prose express and enforce one explicit contract, retaining credential/runtime-state protections. Add negative coverage for tracked Git configuration and shell history. |
| F5 | Procedures lack runnable HOME-isolation setup and explicit isolated gate invocation. **AMBER.** Verified V5. | Junior | `references/validation-env.md`; discovery link in `references/ralph-loop.md` | Add a bounded end-to-end recipe: preserve prerequisite source paths, create temporary HOME outside the checkout, restore verified copies at expected relative paths, run affected checks then the full gate with HOME explicitly set, and clean up only owned temporary directories. |
| F6 | Regression pause has no explicit post-diagnosis completion disposition. **AMBER.** Verified V6. | Junior | `references/scoring.md`; canonical validator Integration and generated Claude adapter | Complete the example with the evidence and recorded disposition permitting convergence with the unchanged gap, versus discoveries requiring remediation or substantiating a blocker. Keep scores and existing hard gates unchanged; regenerate the adapter from the canonical brief. |
| F7 | T7 asserts decimal spelling rather than numerical equality. **AMBER.** Verified V7. | Senior | `scripts/test-grade-evals.sh`; gate description as published context | Compare the JSON number numerically. Verify the non-root cleanup case on supported jq versions; retain the visible root-skip distinction. |

F1 and F3 concern different properties of the same procedure: repository coverage versus authorized inspection boundaries. They remain separate findings, but remediation must preserve both.

### Operator actions

| # | Finding / severity | Raised by | Relevant artifacts | Required handoff |
|---|---|---|---|---|
| O1 | Executability of the changed procedures and harnesses remains unverified in this audit. **AMBER evidence limitation**, not an observed runtime failure. Verified V8. | PM explicitly; all four report the tool limitation | `references/validation-env.md`; eval procedures and focused harnesses | Provide an execution-capable, appropriately isolated read-only audit environment or access unavailable to this host. Have the verification pass execute the published procedures against real artifacts, retain commands/exits, attribution and ledger evidence, and an actual degraded-path diagnostic. Do not certify A2/A3/A6 execution closure from these source-only passes. |

The access provision is the Operator action; deterministic execution can be delegated to an agent once that capability exists. This does not authorize paid grading or provider calls. The documented fake-agent harness is distinct from live `grade-evals.sh` execution.

### Rejected findings

**None.** No underlying finding in the four reports was disproved or already mitigated in full by the checks above.

| Finding checked | Raised by | Exact verification performed | Evidence / disposition |
|---|---|---|---|
| No rejected finding | All four reports consolidated | V1–V8 source checks, including surrounding protocol, actual eval/pins, documented prerequisites, and previous audit/index | All underlying observations survive in F1–F7 or O1. Snapshot severity dissent is retained rather than resolved by rejection. Execution limitations remain limitations, not invented runtime failures. |

The prior audit index says its earlier O1 was covered by a SHA-bound gate run on the identical prior tree. That historical statement does not establish executable coverage for the new PR #163 procedures; it does not reject the present O1.

### Dissent

**Severity dissent is recorded; unanimity is not claimed.** Silence from a persona is not endorsement or opposition.

| Finding | Recorded views | Preserved disposition |
|---|---|---|
| F1 — subdirectory snapshot coverage | Senior: **RED**, repository-wide assurance can miss sibling-file overwrites. PM: **AMBER**, assurance depends on an unstated invocation prerequisite. Both recommend root-scoped inspection and regression coverage. | One deduplicated **Agent action**, retaining both severities. Overall RED reflects the highest surviving reported severity, not an averaged or unanimous rating. Runtime reproduction remains outstanding. |
| F2–F7 | Each has one originating persona and **AMBER** severity. No other report records an opposing recommendation. | Retained as separate **Agent actions**. No four-persona consensus is inferred. |
| O1 — execution evidence | PM explicitly rates the evidence gap **AMBER**. Junior, Senior, and Principal record execution limitations without separate severity ratings. | **Operator action** for unavailable access. No severity is invented for the other three personas. |

No conflicting recommended remediation is recorded beyond the F1 severity difference. The principal’s constitution caveat is preserved in its persona section as an unverified boundary, not promoted into an unrelated policy or document-creation action.

### Structural checker and filing status

**Not executed:** this host has no command-execution tool. No checker exit `0` is claimed, and no index was edited.

After capturing the complete report, the dispatcher must run:

```bash
bash /home/lafiamafia/wgm/.wgm/lanes/ws/audit-163/scripts/audit.sh \
  --check-report \
  /home/lafiamafia/wgm/.wgm/lanes/ws/audit-163/.wgm/audit-run-pU5hen/wgm-docs-writer.md
```

Record the actual result before filing. A structural pass establishes report completeness, not a qualitative GREEN verdict.

## Verdict history

The previous indexed report is `docs/audit/2026-11-01T0935Z_learn-145-151-promotion.md`, covering PR #152 and recording **AMBER** with actions A1–A7.

This follow-up records **RED** because the senior identifies a source-supported repository-snapshot assurance defect; the PM rates that same defect AMBER. The earlier AMBER → current RED verdict change must not be read as unanimous evidence of broader regression: the scope is the changed follow-up surface, and executable verification remains outstanding.
