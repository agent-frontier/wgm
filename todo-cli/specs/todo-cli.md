# Spec: Todo CLI core workflow

> Conforms to `specs/CONSTITUTION.md`.

## JTBD (job to be done)
A terminal user needs to quickly capture, inspect, and finish personal tasks without opening another app.

## User-visible success criteria
- `<python>` means `python3` on POSIX systems and `py` on Windows.
- `<python> -m todo add <text>` creates a durable todo and prints its numeric ID.
- `<python> -m todo list` shows pending todos in ID order; `list --all` also shows completed todos.
- `<python> -m todo complete <id>` marks an existing pending todo complete and confirms it.
- Invalid input, unknown IDs, and corrupt storage produce useful errors and non-zero exits.

## Magic moment
- **The whoa:** A todo added in one process appears in another and disappears from the default list immediately after completion.
- **Demo path:** Add “buy milk”; list it; complete its ID; verify the default list is empty and `list --all` marks it complete.
- **Smallest end-to-end slice:** One add/list/complete cycle using an isolated data file.
- **Merely functional vs magical:** Silent mutations or ambiguous list state would make the workflow feel unsafe.

## Acceptance criteria → backpressure

| Criterion (EARS) | How it's verified (command/check) |
|---|---|
| When a user adds valid single-line text, the CLI shall persist it with the next positive integer ID and print confirmation. | `tests/test_cli.py::AddCommandTests.test_add_persists_trimmed_text_with_monotonic_ids` |
| When a user lists todos, the CLI shall display pending todos in ascending ID order. | `tests/test_cli.py::WorkflowCommandTests.test_list_sorts_persisted_todos_by_id` |
| Where `--all` is supplied, the CLI shall include completed todos and visually distinguish their state. | `tests/test_cli.py::WorkflowCommandTests.test_list_shows_pending_in_id_order_and_all_shows_state` |
| When a user completes a pending ID, the CLI shall persist the completed state and print confirmation. | `tests/test_cli.py::WorkflowCommandTests.test_complete_persists_across_invocations` |
| If input, an ID, or persisted data is invalid, then the CLI shall explain the error on stderr and exit non-zero without overwriting data. | `tests/test_cli.py::AddCommandTests.test_add_rejects_blank_text_without_creating_storage`, `test_add_rejects_control_characters`, `test_add_rejects_corrupt_storage_without_overwriting_it`; `WorkflowCommandTests.test_commands_report_parser_errors`, `test_list_rejects_malformed_persisted_text`, `test_mutations_reject_unknown_persisted_fields_without_data_loss`, and `test_add_reports_write_failure_without_leaving_temp_data` |

## Holdout scenarios
- **Files:** `scenarios/core-workflow.yaml`
- **Holdout rule:** The Implement step must not read the scenario; Validate/Review may judge it.

## Assumptions
- Python 3.10+ is available.
- Data defaults to the platform user data directory and can be overridden by `TODO_FILE` for automation.
- Todo text is trimmed, must be non-empty, and has no application-defined length limit.
- Todo text cannot contain Unicode control, format, surrogate, line-separator, or paragraph-separator characters.
- IDs are never reused after completion.
- Persisted JSON uses the closed schema documented in `README.md`; unknown fields are rejected.
- The local JSON file supports one writer at a time; concurrent writes are out of scope.

## Out of scope (this pass)
- Editing, deleting, priorities, due dates, synchronization, and multi-user support.
