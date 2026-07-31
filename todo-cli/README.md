# Todo CLI

A dependency-free command-line app for capturing, listing, and completing local todos.

## Requirements

- Python 3.10 or newer

No installation is required. From the repository root, enter this directory first:

```sh
cd todo-cli
python3 -m todo add "buy milk"
python3 -m todo list
python3 -m todo complete 1
python3 -m todo list --all
```

On Windows, replace `python3` with `py`.

For a safe, repeatable demo, isolate the data instead of using your real todo file:

```sh
# Linux/macOS
tmp=$(mktemp -d)
export TODO_FILE="$tmp/todos.json"
python3 -m todo add "buy milk"
python3 -m todo list
python3 -m todo complete 1
python3 -m todo list --all
rm "$TODO_FILE"
unset TODO_FILE
rmdir "$tmp"
```

```powershell
# Windows PowerShell
$env:TODO_FILE = Join-Path ([System.IO.Path]::GetTempPath()) "todo-demo-$PID.json"
py -m todo add "buy milk"
py -m todo list
py -m todo complete 1
py -m todo list --all
Remove-Item $env:TODO_FILE
Remove-Item Env:TODO_FILE
```

Example output:

```text
Added #1: buy milk
[ ] 1  buy milk
Completed #1: buy milk
[x] 1  buy milk
```

`list` shows pending todos. Use `list --all` to include completed todos. IDs are positive,
monotonically increasing integers and are not reused. Todo text is trimmed and cannot contain
Unicode control, format, surrogate, line-separator, or paragraph-separator characters.

## Storage

Todos are stored as JSON in:

- Linux and macOS: `$XDG_DATA_HOME/todo-cli/todos.json`, or
  `~/.local/share/todo-cli/todos.json` when `XDG_DATA_HOME` is unset
- Windows: `%LOCALAPPDATA%\todo-cli\todos.json`

Set `TODO_FILE` to use a specific file:

```sh
TODO_FILE=/tmp/my-todos.json python3 -m todo list
```

In PowerShell:

```powershell
$env:TODO_FILE = "$env:TEMP\my-todos.json"
py -m todo list
```

Writes replace the data file atomically. If stored data is malformed, the command reports an
error without overwriting it.

## Limitations

- Use one writer at a time. Atomic file replacement prevents partial files, but simultaneous
  commands can overwrite each other's changes.
- Editing, deleting, priorities, due dates, synchronization, and multi-user use are not supported.
- Back up a malformed data file before repairing it manually; the CLI intentionally leaves it
  untouched.

## Project documentation

- [`AGENTS.md`](AGENTS.md) — contributor workflow and code map
- [`specs/todo-cli.md`](specs/todo-cli.md) — behavior and acceptance criteria
- [`specs/CONSTITUTION.md`](specs/CONSTITUTION.md) — project quality constraints
- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — build and validation record

## Validate

```sh
python3 -m unittest discover -s tests -v
```
