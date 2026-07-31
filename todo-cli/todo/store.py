from __future__ import annotations

import json
import os
import tempfile
import unicodedata
from pathlib import Path
from typing import TypedDict


class Todo(TypedDict):
    id: int
    text: str
    completed: bool


class TodoData(TypedDict):
    next_id: int
    todos: list[Todo]


class StoreError(Exception):
    """Raised when persisted todo data cannot be safely used."""


class _DuplicateKeyError(ValueError):
    pass


def data_path(platform: str | None = None) -> Path:
    override = os.environ.get("TODO_FILE")
    if override:
        return Path(override).expanduser()

    if (platform or os.name) == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home()))
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "todo-cli" / "todos.json"


def _empty_data() -> TodoData:
    return {"next_id": 1, "todos": []}


def _contains_unsafe_characters(text: str) -> bool:
    return any(
        unicodedata.category(character) in {"Cc", "Cf", "Cs", "Zl", "Zp"}
        for character in text
    )


def _has_exact_keys(value: dict[object, object], keys: set[str]) -> bool:
    return set(value) == keys


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKeyError(key)
        result[key] = value
    return result


def load(path: Path | None = None) -> TodoData:
    target = path or data_path()
    if not target.exists():
        return _empty_data()

    try:
        raw = json.loads(
            target.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except _DuplicateKeyError as error:
        raise StoreError(
            f"invalid todo data in {target}: duplicate key {error.args[0]!r}"
        ) from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise StoreError(f"cannot read todo data from {target}: {error}") from error

    if not isinstance(raw, dict) or not _has_exact_keys(raw, {"next_id", "todos"}):
        raise StoreError(f"invalid todo data in {target}: expected an object")
    next_id = raw.get("next_id")
    todos = raw.get("todos")
    if not isinstance(next_id, int) or isinstance(next_id, bool) or next_id < 1:
        raise StoreError(f"invalid todo data in {target}: next_id must be a positive integer")
    if not isinstance(todos, list):
        raise StoreError(f"invalid todo data in {target}: todos must be a list")

    validated: list[Todo] = []
    seen_ids: set[int] = set()
    for item in todos:
        if not isinstance(item, dict) or not _has_exact_keys(
            item, {"id", "text", "completed"}
        ):
            raise StoreError(f"invalid todo data in {target}: each todo must be an object")
        todo_id = item.get("id")
        text = item.get("text")
        completed = item.get("completed")
        if (
            not isinstance(todo_id, int)
            or isinstance(todo_id, bool)
            or todo_id < 1
            or todo_id in seen_ids
            or not isinstance(text, str)
            or not text
            or text != text.strip()
            or _contains_unsafe_characters(text)
            or not isinstance(completed, bool)
        ):
            raise StoreError(f"invalid todo data in {target}: malformed or duplicate todo")
        seen_ids.add(todo_id)
        validated.append({"id": todo_id, "text": text, "completed": completed})

    if seen_ids and next_id <= max(seen_ids):
        raise StoreError(f"invalid todo data in {target}: next_id must exceed existing IDs")
    return {"next_id": next_id, "todos": validated}


def save(data: TodoData, path: Path | None = None) -> None:
    target = path or data_path()
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=target.parent, prefix=f".{target.name}.", suffix=".tmp"
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
                json.dump(data, temporary, indent=2)
                temporary.write("\n")
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temporary_name, target)
        finally:
            Path(temporary_name).unlink(missing_ok=True)
    except OSError as error:
        raise StoreError(f"cannot write todo data to {target}: {error}") from error


def add(text: str, path: Path | None = None) -> Todo:
    if _contains_unsafe_characters(text):
        raise ValueError(
            "todo text must not contain Unicode control, format, surrogate, "
            "line-separator, or paragraph-separator characters"
        )
    normalized = text.strip()
    if not normalized:
        raise ValueError("todo text must not be blank")

    data = load(path)
    todo: Todo = {"id": data["next_id"], "text": normalized, "completed": False}
    data["todos"].append(todo)
    data["next_id"] += 1
    save(data, path)
    return todo


def list_todos(include_completed: bool = False, path: Path | None = None) -> list[Todo]:
    todos = load(path)["todos"]
    return sorted(
        (todo for todo in todos if include_completed or not todo["completed"]),
        key=lambda todo: todo["id"],
    )


def complete(todo_id: int, path: Path | None = None) -> Todo:
    if todo_id < 1:
        raise ValueError("todo ID must be a positive integer")

    data = load(path)
    for todo in data["todos"]:
        if todo["id"] != todo_id:
            continue
        if todo["completed"]:
            raise ValueError(f"todo #{todo_id} is already completed")
        todo["completed"] = True
        save(data, path)
        return todo
    raise ValueError(f"todo #{todo_id} does not exist")
