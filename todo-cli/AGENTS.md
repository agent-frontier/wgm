# Todo CLI agent guide

## Runtime
- Python 3.10+; standard library only.
- Run from this directory with `python3 -m todo`.
- Override persistence with `TODO_FILE=/path/to/todos.json`.

## Validation
```sh
python3 -m unittest discover -s tests -v
```

Keep CLI integration tests isolated with a temporary `TODO_FILE`. Never read or write the user's real todo file in tests.
