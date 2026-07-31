# Implementation plan

## Convergence
- **Satisfaction threshold:** 95
- **Stratified order:** tier 1
- **Scenarios:** `scenarios/`

## Now (next up)

### T4 — Resolve release-blocking documentation audit findings
- **objective:** Enforce unambiguous text, strengthen error/performance coverage, and make usage, platform, and single-writer boundaries accurate.
- **files/areas:** `todo/store.py`, `tests/test_cli.py`, `README.md`, `AGENTS.md`, `specs/CONSTITUTION.md`, `specs/todo-cli.md`
- **validation:** `cd todo-cli && python3 -m unittest discover -s tests -v`
- **acceptance:** Control text and malformed persisted text fail safely; parser/data-safety/performance boundaries are tested; demos are isolated; POSIX/Windows and single-writer limitations are documented.
- **scenarios/tier:** `core-workflow` / tier 1
- **status:** done
- **notes:** Resolved audit blockers with safe text validation, explicit single-writer/platform boundaries, isolated demos, and 15 passing tests. Spec and quality reviews passed after narrowing Unicode rejection to Cc/Cf/Cs/Zl/Zp.

### T1 — Build durable add workflow and its validation signal
- **objective:** Create the package, atomic JSON storage, `add` command, and focused tests.
- **files/areas:** `todo/__init__.py`, `todo/__main__.py`, `todo/store.py`, `tests/test_cli.py`
- **validation:** `cd todo-cli && python3 -m unittest tests.test_cli.AddCommandTests -v`
- **acceptance:** Adding trimmed non-empty text persists a todo with a monotonic positive ID; blank input and corrupt storage fail safely.
- **scenarios/tier:** `core-workflow` / tier 1
- **status:** done
- **notes:** Added atomic JSON persistence and the `add` command. Exact validation passed 3 tests on 2026-07-31.

### T2 — Add list and complete workflows
- **objective:** Implement pending/all listing and durable completion with useful errors.
- **files/areas:** `todo/__main__.py`, `todo/store.py`, `tests/test_cli.py`
- **validation:** `cd todo-cli && python3 -m unittest discover -s tests -v`
- **acceptance:** Pending items list in ID order, `--all` distinguishes completed items, completion persists, and unknown IDs fail.
- **scenarios/tier:** `core-workflow` / tier 1
- **status:** done
- **notes:** Implemented sorted pending/all views and durable completion. Exact validation passed 9 tests; quality review requested and received explicit out-of-order coverage before passing.

### T3 — Document and run the end-to-end demo
- **objective:** Add usage documentation and execute the exact isolated add/list/complete demo path.
- **files/areas:** `todo-cli/README.md`, `todo-cli/.gitignore`, CLI entry point
- **validation:** `cd todo-cli && tmp=$(mktemp -d) && export TODO_FILE="$tmp/todos.json" && python3 -m todo add "buy milk" | grep -F "Added #1: buy milk" && python3 -m todo list | grep -F "[ ] 1  buy milk" && python3 -m todo complete 1 | grep -F "Completed #1: buy milk" && test "$(python3 -m todo list)" = "No pending todos." && python3 -m todo list --all | grep -F "[x] 1  buy milk"`
- **acceptance:** README documents install/run/storage behavior and the spec demo path passes end-to-end.
- **scenarios/tier:** `core-workflow` / tier 1
- **status:** done
- **notes:** Documented commands and storage, added generated-file exclusions, and ran the exact isolated demo successfully. Holdout satisfaction: 100/100.

## Later (backlog)
- None.

## Done
- T1 — `python3 -m unittest tests.test_cli.AddCommandTests -v` passed 3 tests.
- T2 — `python3 -m unittest discover -s tests -v` passed 9 tests; spec and quality reviews passed.
- T3 — Exact add/list/complete demo passed; tier-1 holdout scored 100/100 and final spec review passed.
- T4 — `python3 -m unittest discover -s tests -v` passed 15 tests; all Agent-action audit findings were resolved.
- Ship gate — Tier-1 holdout revalidated at 100/100 after T4; docs audit GREEN and deterministic release checks passed.
