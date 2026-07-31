# Spec: Todo CLI core workflow

> Conforms to `specs/CONSTITUTION.md`.

## JTBD (job to be done)
A terminal user needs to quickly capture, inspect, and finish personal tasks without opening another app.

## User-visible success criteria
- `todo add <text>` creates a durable todo and prints its numeric ID.
- `todo list` shows pending todos in ID order; `todo list --all` also shows completed todos.
- `todo complete <id>` marks an existing pending todo complete and confirms it.
- Invalid input, unknown IDs, and corrupt storage produce useful errors and non-zero exits.

## Magic moment
- **The whoa:** A todo added in one process appears in another and disappears from the default list immediately after completion.
- **Demo path:** Add “buy milk”; list it; complete its ID; verify the default list is empty and `list --all` marks it complete.
- **Smallest end-to-end slice:** One add/list/complete cycle using an isolated data file.
- **Merely functional vs magical:** Silent mutations or ambiguous list state would make the workflow feel unsafe.

## Acceptance criteria → backpressure

| Criterion (EARS) | How it's verified (command/check) |
|---|---|
| When a user adds non-blank text, the CLI shall persist it with the next positive integer ID and print confirmation. | `cd todo-cli && python3 -m unittest discover -s tests -v` |
| When a user lists todos, the CLI shall display pending todos in ascending ID order. | `cd todo-cli && python3 -m unittest discover -s tests -v` |
| Where `--all` is supplied, the CLI shall include completed todos and visually distinguish their state. | `cd todo-cli && python3 -m unittest discover -s tests -v` |
| When a user completes a pending ID, the CLI shall persist the completed state and print confirmation. | `cd todo-cli && python3 -m unittest discover -s tests -v` |
| If input, an ID, or persisted data is invalid, then the CLI shall explain the error on stderr and exit non-zero without overwriting data. | `cd todo-cli && python3 -m unittest discover -s tests -v` |

## Holdout scenarios
- **Files:** `scenarios/core-workflow.yaml`
- **Holdout rule:** The Implement step must not read the scenario; Validate/Review may judge it.

## Assumptions
- Python 3.10+ is available.
- Data defaults to the platform user data directory and can be overridden by `TODO_FILE` for automation.
- Todo text is trimmed, must be non-empty, and has no arbitrary length limit.
- IDs are never reused after completion.

## Out of scope (this pass)
- Editing, deleting, priorities, due dates, synchronization, and multi-user support.
