from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
