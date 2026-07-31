# Todo CLI

A dependency-free command-line app for capturing, listing, and completing local todos.

## Requirements

- Python 3.10 or newer

No installation is required. Run commands from this directory:

```sh
python3 -m todo add "buy milk"
python3 -m todo list
python3 -m todo complete 1
python3 -m todo list --all
```

Example output:

```text
Added #1: buy milk
[ ] 1  buy milk
Completed #1: buy milk
[x] 1  buy milk
```

`list` shows pending todos. Use `list --all` to include completed todos. IDs are positive,
monotonically increasing integers and are not reused.

## Storage

Todos are stored as JSON in:

- Linux and macOS: `$XDG_DATA_HOME/todo-cli/todos.json`, or
  `~/.local/share/todo-cli/todos.json` when `XDG_DATA_HOME` is unset
- Windows: `%LOCALAPPDATA%\todo-cli\todos.json`

Set `TODO_FILE` to use a specific file:

```sh
TODO_FILE=/tmp/my-todos.json python3 -m todo list
```

Writes replace the data file atomically. If stored data is malformed, the command reports an
error without overwriting it.

## Validate

```sh
python3 -m unittest discover -s tests -v
```
