# Docs Audit Report — 2026-07-31T0155Z — todo-cli-build

> Generated from the four wgm docs-audit persona reports and consolidated by
> `wgm-docs-writer`. Structural checks remain separate from this qualitative audit.
>
> **Unanimous outcome after remediation:** no release blocker remains. Differences about who
> should choose the performance and concurrency boundaries are preserved under Dissent.

- **Scope:** `todo-cli/README.md`, `AGENTS.md`, `IMPLEMENTATION_PLAN.md`,
  `specs/CONSTITUTION.md`, `specs/todo-cli.md`, `scenarios/core-workflow.yaml`, implementation,
  tests, and commits `600cd92` through `25bde20`
- **Track:** Standard
- **Trigger:** Ship/Handoff
- **Remediation reviewed:** `25bde20` (`fix: harden todo text and docs`)
- **Overall verdict:** **GREEN** — all RED and AMBER release findings are resolved; one optional
  GREEN glossary decision remains open and non-blocking

## Persona findings

### Junior developer — clarity & onboarding

| Doc(s) | Observation | Severity | Status | Evidence | Owner classification | Recommended action |
|---|---|---|---|---|---|---|
| `README.md` | The original demo was not isolated and could complete a real todo with ID 1. | RED | **Resolved** | Commit `25bde20` adds POSIX and PowerShell demos using temporary `TODO_FILE` paths. The POSIX sequence was executed successfully during consolidation. | Agent action | Keep examples isolated from user data. |
| `README.md`, `AGENTS.md` | Commands did not consistently say which directory to run from. | AMBER | **Resolved** | Both files now explicitly say to enter `todo-cli`; README commands were executed from that directory. | Agent action | State the working directory before commands. |
| `README.md`, `AGENTS.md` | Windows command examples were absent. | AMBER | **Resolved** | README now provides `py -m todo`, PowerShell environment setup and cleanup, and a Windows `TODO_FILE` example; the path-selection test covers `LOCALAPPDATA`. | Agent action | Add Windows equivalents and document the platform override. |
| `specs/todo-cli.md` | Success criteria named a nonexistent installed `todo` executable. | AMBER | **Resolved** | Criteria now use `<python> -m todo`; README and AGENTS give the concrete POSIX and Windows launchers. | Agent action | Describe the actual module invocation. |
| `README.md`, `AGENTS.md` | Project and code maps were missing. | AMBER | **Resolved** | README indexes all four pre-audit Markdown project docs; AGENTS maps CLI, store, tests, specs, and scenarios. | Agent action | Maintain the documentation and code maps. |
| `specs/todo-cli.md`, `IMPLEMENTATION_PLAN.md` | Workflow terms such as JTBD, EARS, backpressure, and holdout are not defined locally. | GREEN | **Open, non-blocking** | The terms remain in contributor/build artifacts; they do not affect the copy-pasteable end-user workflow. | Operator action | Optionally decide whether contributor onboarding warrants a short glossary or links. |

### Senior developer — correctness, completeness, maintainability

| Doc(s) | Observation | Severity | Status | Evidence | Owner classification | Recommended action |
|---|---|---|---|---|---|---|
| `specs/CONSTITUTION.md`, `IMPLEMENTATION_PLAN.md`, `tests/test_cli.py` | “Every user-facing error” overclaimed coverage while the plan reported done. | RED | **Resolved** | The constitution now names error classes rather than every message; tests cover parser, input, read, persisted validation, write, and lifecycle failures. All 15 tests pass. | Agent action | Keep the narrower claim aligned with named tests. |
| `specs/CONSTITUTION.md`, `tests/test_cli.py` | “Responsive for 10,000” was undefined and unvalidated. | AMBER | **Resolved** | The requirement is now loading and sorting 10,000 valid todos in under five seconds; `StorageBoundaryTests.test_listing_ten_thousand_todos_completes_within_five_seconds` passes. | Operator action | Retain or revise the selected conservative threshold as product expectations evolve. |
| `README.md`, `AGENTS.md`, `tests/test_cli.py` | Windows was a stated deployment target but usage and path behavior did not match that claim. | AMBER | **Resolved** | PowerShell usage is documented, `py` is named, and `test_platform_default_paths_and_override` verifies the Windows default-path branch and override. | Agent action | Keep platform docs and the path contract synchronized. |
| `README.md`, `AGENTS.md` | No documentation/code map made maintenance paths discoverable. | AMBER | **Resolved** | README’s Project documentation section and AGENTS’ Code map are present at `25bde20`. | Agent action | Keep maps current when files move. |

### Principal developer — architecture, strategic fit, consistency

| Doc(s) | Observation | Severity | Status | Evidence | Owner classification | Recommended action |
|---|---|---|---|---|---|---|
| `todo/store.py`, `README.md`, `AGENTS.md`, `specs/todo-cli.md` | Newline and Unicode control/format characters could inject forged terminal rows. | RED | **Resolved** | `_contains_unsafe_characters` rejects Unicode categories `Cc`, `Cf`, `Cs`, `Zl`, and `Zp`; add-input and persisted-data tests pass; the restriction is documented. | Agent action | Preserve validation at both input and load boundaries. |
| `todo/store.py`, `tests/test_cli.py` | Persisted blank or surrounding-whitespace text bypassed add-time normalization. | RED | **Resolved** | `load()` rejects empty or non-trimmed persisted text; `test_list_rejects_malformed_persisted_text` covers blank and unsafe stored values. | Agent action | Continue validating persisted records before use or mutation. |
| `specs/CONSTITUTION.md`, `IMPLEMENTATION_PLAN.md`, `tests/test_cli.py` | Error coverage was incomplete despite done status. | RED | **Resolved** | The claim was narrowed and the suite expanded from 9 to 15 passing tests, including parser, malformed stored text, and write-failure paths. Spec and quality reviewers passed the remediated slice. | Agent action | Keep plan status tied to named backpressure. |
| `README.md`, `specs/CONSTITUTION.md`, `specs/todo-cli.md`, `AGENTS.md` | Atomic replacement wording could imply safe concurrent writers although operations were unlocked. | AMBER | **Resolved** | The product boundary is now explicitly single-writer: simultaneous commands may overwrite changes, concurrent mutation is unsupported, and locking was not claimed or added. | Operator action | Revisit only if concurrent-write support enters scope. |
| `README.md`, `AGENTS.md`, `tests/test_cli.py` | Windows documentation and proof were incomplete. | AMBER | **Resolved** | PowerShell commands, storage override, launcher guidance, and a Windows path-selection test were added. | Agent action | Validate on native Windows when release policy requires platform certification. |
| `specs/CONSTITUTION.md`, `tests/test_cli.py` | The 10,000-item boundary was not measurable and required a product threshold decision. | AMBER | **Resolved** | A conservative five-second local threshold was selected, documented, and tested. | Operator action | Treat future threshold changes as product decisions, then update deterministic tests. |

### Project manager — status, risk, traceability

| Doc(s) | Observation | Severity | Status | Evidence | Owner classification | Recommended action |
|---|---|---|---|---|---|---|
| `README.md` | The release demo could mutate real user data. | RED | **Resolved** | Both published demo variants isolate `TODO_FILE`; the POSIX variant passed during consolidation. | Agent action | Keep the isolated demo as the release path. |
| `README.md`, `specs/CONSTITUTION.md`, `IMPLEMENTATION_PLAN.md` | Release claims ran ahead of performance, platform, and error-coverage evidence. | AMBER | **Resolved** | Commit `25bde20` narrows claims, exposes limitations, adds platform/performance/error tests, records 15 passing tests, and records both reviewers’ PASS. | Agent action | Continue requiring evidence before marking plan work done. |
| `README.md`, `tests/test_cli.py` | Windows support was claimed but unproven and undocumented. | AMBER | **Resolved for documented contract** | Windows commands and the platform-path branch are covered. No native-Windows execution claim is made in this report. | Agent action | Keep claims limited to the evidence available. |
| `specs/todo-cli.md`, `tests/test_cli.py` | Acceptance criteria pointed only to the whole suite, weakening traceability. | AMBER | **Resolved** | Each criterion now names focused test methods or test groups. | Agent action | Preserve criterion-to-test names. |
| `README.md`, `specs/todo-cli.md` | README hid unsupported scope and the concurrent-write limitation. | AMBER | **Resolved** | README now lists single-writer behavior and unsupported editing, deletion, priority, due-date, sync, and multi-user features; the spec also declares concurrency and feature scope. | Operator action | The accepted scope is explicit; change it only through a product decision. |
| `README.md`, `tests/test_cli.py` | The isolated core add/list/complete workflow works. | GREEN | **Resolved / verified** | The exact POSIX flow produced add, pending, complete, empty-pending, and completed-all output; all 15 tests pass. | Agent action | No further action. |

## Consolidated report

### README index check

The project uses `README.md`’s **Project documentation** section as its map and `AGENTS.md`’s
**Code map** for implementation navigation. At commit `25bde20`, the README indexes every Markdown
document that existed in `todo-cli` before this generated paper trail: `AGENTS.md`,
`specs/todo-cli.md`, `specs/CONSTITUTION.md`, and `IMPLEMENTATION_PLAN.md`. Each target exists.
AGENTS maps both Python modules, the test module, specs, and scenarios. There is no separate
`docs/README.md` in the pre-audit tree. This audit directory is indexed by the adjacent
[`README.md`](README.md).

### Agent actions

> These actions are directly executable and deterministic. Resolved items remain here to preserve
> the paper trail.

| # | Finding | Raised by | Severity | Status | Evidence | Action |
|---|---|---|---|---|---|---|
| A1 | Unsafe, cwd-ambiguous, POSIX-only usage and a nonexistent `todo` executable | Junior, PM; Windows aspect also Senior and Principal | RED (worst) | **Resolved** | Isolated POSIX/PowerShell demos, explicit `cd`, `python3`/`py`, `<python> -m todo`, and platform-path tests in `25bde20` | Maintain runnable, isolated, platform-specific examples. |
| A2 | Missing project documentation and code maps | Junior, Senior | AMBER | **Resolved** | README Project documentation and AGENTS Code map/invariants sections | Keep both maps synchronized with the tree. |
| A3 | Overclaimed and incomplete error coverage despite done status | Senior, Principal, PM | RED | **Resolved** | Constitution names six error classes; suite grew from 9 to 15 and covers parser/input/read/validation/write/lifecycle; plan records reviewer PASS | Keep claims and plan status tied to named tests. |
| A4 | Newline/control injection and invalid persisted text | Principal | RED | **Resolved** | `Cc`/`Cf`/`Cs`/`Zl`/`Zp`, blank, and non-trimmed persisted text are rejected; focused tests pass | Preserve input and load-time validation. |
| A5 | Weak acceptance-to-test traceability | PM | AMBER | **Resolved** | `specs/todo-cli.md` names focused tests for every criterion | Update test names in the spec if tests are renamed. |
| A6 | Isolated core workflow required verification | PM | GREEN | **Resolved / verified** | Exact POSIX demo passed; 15/15 unit/integration tests passed during consolidation | No further action. |

### Operator actions

> These are product/scope decisions rather than mechanical edits. Resolved decisions remain recorded.

| # | Finding | Raised by | Severity | Status | Evidence | Why it needs a human |
|---|---|---|---|---|---|---|
| O1 | Define the 10,000-item responsiveness boundary | Senior, Principal, PM | AMBER | **Resolved** | A conservative default of loading/sorting 10,000 valid todos in under five seconds was accepted in the constitution and passes its focused test | Choosing or changing a user-facing performance budget is a product decision; testing it afterward is mechanical. |
| O2 | Decide whether to support concurrent writers or declare single-writer scope | Principal, PM | AMBER | **Resolved** | README, constitution, spec, and AGENTS consistently declare single-writer semantics and explain atomic replacement without claiming locking | Concurrency support changes product scope and architecture; the accepted decision is single-writer for this release. |
| O3 | Decide whether workflow jargon warrants a contributor glossary | Junior | GREEN | **Open, optional, non-blocking** | JTBD, EARS, backpressure, and holdout remain in contributor/build docs, while end-user instructions require none of them | The value of additional onboarding prose depends on the intended contributor audience; no correctness or release gap remains. |

### Dissent

| Finding | Persona A view | Persona B view | Preserved as |
|---|---|---|---|
| Undefined 10,000-item performance claim | Senior: AMBER documentation/validation gap that can be fixed once measurable | Principal: AMBER and specifically an **Operator decision** because the threshold is a product policy choice | **Resolved Operator action O1.** The five-second conservative default was selected and then deterministically tested; the policy/mechanism distinction remains explicit. |
| Unlocked writers behind “atomic” wording | PM: AMBER visibility/scope gap in README | Principal: AMBER **Operator decision** whether to add locking or narrow scope | **Resolved Operator action O2.** Single-writer scope was chosen; the agent then documented it consistently. Atomic replacement is retained only as a partial-file guarantee. |
| Workflow jargon | Junior: a glossary would improve onboarding | Other personas: did not identify it as release-impacting | **Open Operator action O3, GREEN and non-blocking.** It is not promoted to a blocker merely to force consensus. |

## Validation record

- `cd todo-cli && python3 -m unittest discover -s tests -v` — **PASS, 15 tests**
- Exact isolated POSIX README demo — **PASS**
- Commit `25bde20` inspected against its parent and current tree
- Spec reviewer after remediation — **PASS** (recorded in `IMPLEMENTATION_PLAN.md`)
- Quality reviewer after remediation — **PASS** (recorded in `IMPLEMENTATION_PLAN.md`)

## Verdict history

- First audit report for `todo-cli`; no previous entry to compare.
