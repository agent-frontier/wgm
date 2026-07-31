# Todo CLI

A dependency-free command-line app for capturing, listing, and completing local todos.

**Status:** Complete for local use. Linux, macOS, and Windows behavior is exercised in CI.

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
(
  set -e
  tmp=$(mktemp -d)
  export TODO_FILE="$tmp/todos.json"
  python3 -m todo add "buy milk"
  python3 -m todo list
  python3 -m todo complete 1
  python3 -m todo list --all
  rm "$TODO_FILE"
  rmdir "$tmp"
)
```

```powershell
# Windows PowerShell
$previousTodoFile = $env:TODO_FILE
try {
    $env:TODO_FILE = Join-Path ([System.IO.Path]::GetTempPath()) "todo-demo-$PID.json"
    py -m todo add "buy milk"
    py -m todo list
    py -m todo complete 1
    py -m todo list --all
} finally {
    Remove-Item $env:TODO_FILE -ErrorAction SilentlyContinue
    if ($null -eq $previousTodoFile) {
        Remove-Item Env:TODO_FILE -ErrorAction SilentlyContinue
    } else {
        $env:TODO_FILE = $previousTodoFile
    }
}
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
- Windows: `%LOCALAPPDATA%\todo-cli\todos.json`, or
  `%USERPROFILE%\todo-cli\todos.json` when `LOCALAPPDATA` is unset

Set `TODO_FILE` to use a specific file:

```sh
TODO_FILE=/tmp/my-todos.json python3 -m todo list
```

In PowerShell:

```powershell
$env:TODO_FILE = "$env:TEMP\my-todos.json"
py -m todo list
```

Writes replace the data file atomically. The closed JSON schema contains only `next_id` and
`todos`; each todo contains only `id`, `text`, and `completed`:

```json
{
  "next_id": 2,
  "todos": [
    {"id": 1, "text": "buy milk", "completed": false}
  ]
}
```

`next_id` and each `id` are positive integers, `next_id` exceeds every existing ID, IDs are unique,
`text` follows the rules above, and `completed` is Boolean. Unknown or duplicate fields are rejected
to prevent silent data loss. If the file is malformed, the command reports an error without
overwriting it. Back it up, correct it to this schema, or move it aside to let the CLI start a new
store.

## Limitations

- Use one writer at a time. Atomic file replacement prevents partial files, but simultaneous
  commands can overwrite each other's changes.
- Editing, deleting, priorities, due dates, synchronization, and multi-user use are not supported.
- There is no automatic migration for malformed or foreign JSON; the CLI leaves it untouched.

## Project documentation

- [`AGENTS.md`](AGENTS.md) — contributor workflow and code map
- [`specs/todo-cli.md`](specs/todo-cli.md) — behavior and acceptance criteria
- [`specs/CONSTITUTION.md`](specs/CONSTITUTION.md) — project quality constraints
- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — build and validation record

## Validate

```sh
python3 -m unittest discover -s tests -v
```
