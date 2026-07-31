# Todo CLI agent guide

## Runtime
- Python 3.10+; standard library only.
- From the repository root, run `cd todo-cli` before app or test commands.
- Run with `python3 -m todo` (POSIX) or `py -m todo` (Windows).
- Override persistence with `TODO_FILE=/path/to/todos.json`.

## Code map
- `todo/__main__.py` owns argument parsing, output, and exit codes.
- `todo/store.py` owns validation and atomic JSON persistence.
- `tests/test_cli.py` exercises commands as separate processes and covers storage boundaries.
- `specs/` defines behavior and quality constraints; `scenarios/` contains holdout journeys.

## Invariants
- IDs are positive, monotonic, and never reused.
- Text is trimmed, non-empty, single-line, and free of Unicode control, format, surrogate,
  and line-separator characters.
- Persisted data is validated before mutation.
- The store supports one writer at a time; do not imply concurrent-write safety.

## Validation
```sh
python3 -m unittest discover -s tests -v
```

Keep CLI integration tests isolated with a temporary `TODO_FILE`. Never read or write the user's real todo file in tests.
Add command behavior to `todo/__main__.py`, persistence behavior to `todo/store.py`, and prove
both through `tests/test_cli.py`.
