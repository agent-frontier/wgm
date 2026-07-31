from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class AddCommandTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
