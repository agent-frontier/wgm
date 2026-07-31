from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from todo import store
from todo.__main__ import main


class CliTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.todo_file = Path(self.temporary_directory.name) / "todos.json"

    def run_todo(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["TODO_FILE"] = str(self.todo_file)
        return subprocess.run(
            [sys.executable, "-m", "todo", *arguments],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )


class AddCommandTests(CliTestCase):
    def test_add_persists_trimmed_text_with_monotonic_ids(self) -> None:
        # Proves separate invocations share durable state without reusing IDs.
        first = self.run_todo("add", "  buy milk  ")
        second = self.run_todo("add", "call dentist")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, "Added #1: buy milk\n")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, "Added #2: call dentist\n")
        self.assertEqual(
            json.loads(self.todo_file.read_text(encoding="utf-8")),
            {
                "next_id": 3,
                "todos": [
                    {"id": 1, "text": "buy milk", "completed": False},
                    {"id": 2, "text": "call dentist", "completed": False},
                ],
            },
        )

    def test_add_rejects_blank_text_without_creating_storage(self) -> None:
        # Proves invalid input cannot create misleading empty tasks.
        result = self.run_todo("add", "   ")

        self.assertEqual(result.returncode, 1)
        self.assertIn("todo text must not be blank", result.stderr)
        self.assertFalse(self.todo_file.exists())

    def test_add_rejects_control_characters(self) -> None:
        # Proves todo text cannot forge extra rows or terminal output.
        for unsafe_text in (
            "real todo\n[x] 999  forged",
            "\nreal todo",
            "real todo\n",
            "real todo\u2028[x] 999  forged",
            "\u2028real todo",
            "hidden\u200btext",
        ):
            with self.subTest(unsafe_text=unsafe_text):
                result = self.run_todo("add", unsafe_text)

                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    "must not contain Unicode control, format, surrogate, "
                    "line-separator, or paragraph-separator characters",
                    result.stderr,
                )
                self.assertFalse(self.todo_file.exists())

    def test_add_rejects_corrupt_storage_without_overwriting_it(self) -> None:
        # Proves malformed user data is surfaced and preserved for recovery.
        original = "{not valid json"
        self.todo_file.write_text(original, encoding="utf-8")

        result = self.run_todo("add", "buy milk")

        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read todo data", result.stderr)
        self.assertEqual(self.todo_file.read_text(encoding="utf-8"), original)


class WorkflowCommandTests(CliTestCase):
    def test_list_shows_pending_in_id_order_and_all_shows_state(self) -> None:
        # Proves default filtering and completed-state presentation remain unambiguous.
        self.run_todo("add", "first")
        self.run_todo("add", "second")
        completed = self.run_todo("complete", "1")

        pending = self.run_todo("list")
        all_todos = self.run_todo("list", "--all")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "Completed #1: first\n")
        self.assertEqual(pending.returncode, 0, pending.stderr)
        self.assertEqual(pending.stdout, "[ ] 2  second\n")
        self.assertEqual(all_todos.returncode, 0, all_todos.stderr)
        self.assertEqual(all_todos.stdout, "[x] 1  first\n[ ] 2  second\n")

    def test_list_sorts_persisted_todos_by_id(self) -> None:
        # Proves display order is deterministic even when valid storage is reordered.
        self.todo_file.write_text(
            json.dumps(
                {
                    "next_id": 4,
                    "todos": [
                        {"id": 3, "text": "third", "completed": False},
                        {"id": 1, "text": "first", "completed": False},
                        {"id": 2, "text": "second", "completed": False},
                    ],
                }
            ),
            encoding="utf-8",
        )

        result = self.run_todo("list")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout, "[ ] 1  first\n[ ] 2  second\n[ ] 3  third\n"
        )

    def test_complete_persists_across_invocations(self) -> None:
        # Proves completion mutates durable state rather than only current output.
        self.run_todo("add", "buy milk")

        result = self.run_todo("complete", "1")
        pending = self.run_todo("list")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(pending.returncode, 0, pending.stderr)
        self.assertEqual(pending.stdout, "No pending todos.\n")
        stored = json.loads(self.todo_file.read_text(encoding="utf-8"))
        self.assertTrue(stored["todos"][0]["completed"])

    def test_complete_rejects_unknown_and_already_completed_ids(self) -> None:
        # Proves bad lifecycle transitions fail clearly without changing persisted data.
        self.run_todo("add", "buy milk")
        unknown = self.run_todo("complete", "2")
        first_completion = self.run_todo("complete", "1")
        snapshot = self.todo_file.read_text(encoding="utf-8")
        repeated = self.run_todo("complete", "1")

        self.assertEqual(unknown.returncode, 1)
        self.assertIn("todo #2 does not exist", unknown.stderr)
        self.assertEqual(first_completion.returncode, 0, first_completion.stderr)
        self.assertEqual(repeated.returncode, 1)
        self.assertIn("todo #1 is already completed", repeated.stderr)
        self.assertEqual(self.todo_file.read_text(encoding="utf-8"), snapshot)

    def test_complete_rejects_non_positive_id(self) -> None:
        # Proves the documented positive-ID boundary is enforced.
        result = self.run_todo("complete", "0")

        self.assertEqual(result.returncode, 1)
        self.assertIn("todo ID must be a positive integer", result.stderr)
        self.assertFalse(self.todo_file.exists())

    def test_empty_lists_have_explicit_messages(self) -> None:
        # Proves an empty result is distinguishable from missing output or a crash.
        pending = self.run_todo("list")
        all_todos = self.run_todo("list", "--all")

        self.assertEqual(pending.returncode, 0, pending.stderr)
        self.assertEqual(pending.stdout, "No pending todos.\n")
        self.assertEqual(all_todos.returncode, 0, all_todos.stderr)
        self.assertEqual(all_todos.stdout, "No todos.\n")

    def test_commands_report_parser_errors(self) -> None:
        # Proves missing commands, invalid IDs, and unknown flags return useful failures.
        missing = self.run_todo()
        invalid_id = self.run_todo("complete", "abc")
        unknown_flag = self.run_todo("list", "--unknown")

        for result in (missing, invalid_id, unknown_flag):
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage:", result.stderr)
            self.assertIn("error:", result.stderr)

    def test_list_rejects_malformed_persisted_text(self) -> None:
        # Proves blank or control-bearing stored text cannot bypass add validation.
        for text in (
            "   ",
            "real\n[x] 999  forged",
            "real\u2028[x] 999  forged",
            "invalid\ud800text",
        ):
            with self.subTest(text=text):
                self.todo_file.write_text(
                    json.dumps(
                        {
                            "next_id": 2,
                            "todos": [
                                {"id": 1, "text": text, "completed": False}
                            ],
                        }
                    ),
                    encoding="utf-8",
                )

                result = self.run_todo("list")

                self.assertEqual(result.returncode, 1)
                self.assertIn("malformed or duplicate todo", result.stderr)

    def test_mutations_reject_unknown_persisted_fields_without_data_loss(self) -> None:
        # Proves the closed JSON schema cannot silently discard newer or foreign data.
        original = json.dumps(
            {
                "next_id": 2,
                "todos": [
                    {
                        "id": 1,
                        "text": "buy milk",
                        "completed": False,
                        "priority": "high",
                    }
                ],
            }
        )
        self.todo_file.write_text(original, encoding="utf-8")

        result = self.run_todo("complete", "1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("each todo must be an object", result.stderr)
        self.assertEqual(self.todo_file.read_text(encoding="utf-8"), original)

    def test_mutations_reject_duplicate_json_keys_without_data_loss(self) -> None:
        # Proves duplicate JSON fields cannot be collapsed during a later mutation.
        for original in (
            '{"next_id": 2, "todos": [], "todos": []}',
            '{"next_id": 2, "todos": [{"id": 1, "text": "first", '
            '"text": "second", "completed": false}]}',
        ):
            with self.subTest(original=original):
                self.todo_file.write_text(original, encoding="utf-8")

                result = self.run_todo("add", "buy milk")

                self.assertEqual(result.returncode, 1)
                self.assertIn("duplicate key", result.stderr)
                self.assertEqual(self.todo_file.read_text(encoding="utf-8"), original)

    def test_add_reports_write_failure_without_leaving_temp_data(self) -> None:
        # Proves storage failures reach users and incomplete files are cleaned up.
        error_output = StringIO()
        with (
            patch.dict(os.environ, {"TODO_FILE": str(self.todo_file)}),
            patch("todo.store.os.replace", side_effect=OSError("disk full")),
            redirect_stderr(error_output),
        ):
            return_code = main(["add", "buy milk"])

        self.assertEqual(return_code, 1)
        self.assertIn("cannot write todo data", error_output.getvalue())
        self.assertFalse(self.todo_file.exists())
        self.assertEqual(list(self.todo_file.parent.glob("*.tmp")), [])


class StorageBoundaryTests(unittest.TestCase):
    def test_platform_default_paths_and_override(self) -> None:
        # Proves documented POSIX, Windows, and explicit storage paths stay accurate.
        with patch.dict(
            os.environ, {"XDG_DATA_HOME": "/tmp/example-data"}, clear=True
        ):
            self.assertEqual(
                store.data_path(platform="posix"),
                Path("/tmp/example-data/todo-cli/todos.json"),
            )
        with patch.dict(
            os.environ, {"LOCALAPPDATA": "C:/Users/example/AppData/Local"}, clear=True
        ):
            self.assertEqual(
                store.data_path(platform="nt").as_posix(),
                "C:/Users/example/AppData/Local/todo-cli/todos.json",
            )
        with (
            patch.dict(os.environ, {}, clear=True),
            patch("todo.store.Path.home", return_value=Path("C:/Users/example")),
        ):
            self.assertEqual(
                store.data_path(platform="nt").as_posix(),
                "C:/Users/example/todo-cli/todos.json",
            )
        with patch.dict(os.environ, {"TODO_FILE": "/tmp/custom.json"}, clear=True):
            self.assertEqual(store.data_path(), Path("/tmp/custom.json"))

    def test_listing_ten_thousand_todos_completes_within_five_seconds(self) -> None:
        # Guards the constitution's local 10,000-item responsiveness boundary.
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "todos.json"
            data: store.TodoData = {
                "next_id": 10_001,
                "todos": [
                    {"id": todo_id, "text": f"todo {todo_id}", "completed": False}
                    for todo_id in range(1, 10_001)
                ],
            }
            store.save(data, path)

            started = time.monotonic()
            todos = store.list_todos(path=path)
            elapsed = time.monotonic() - started

        self.assertEqual(len(todos), 10_000)
        self.assertLess(elapsed, 5.0)


if __name__ == "__main__":
    unittest.main()
