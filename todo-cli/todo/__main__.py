from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from . import store


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="todo", description="Capture and complete todos from the terminal."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    add_parser = subparsers.add_parser("add", help="add a new todo")
    add_parser.add_argument("text", help="todo text")

    list_parser = subparsers.add_parser("list", help="list todos")
    list_parser.add_argument(
        "--all", action="store_true", help="include completed todos"
    )

    complete_parser = subparsers.add_parser("complete", help="complete a todo")
    complete_parser.add_argument("id", type=int, help="todo ID")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "add":
            todo = store.add(args.text)
            print(f"Added #{todo['id']}: {todo['text']}")
            return 0
        if args.command == "list":
            todos = store.list_todos(include_completed=args.all)
            if not todos:
                print("No todos." if args.all else "No pending todos.")
                return 0
            for todo in todos:
                marker = "x" if todo["completed"] else " "
                print(f"[{marker}] {todo['id']}  {todo['text']}")
            return 0
        if args.command == "complete":
            todo = store.complete(args.id)
            print(f"Completed #{todo['id']}: {todo['text']}")
            return 0
    except (store.StoreError, ValueError) as error:
        print(f"todo: error: {error}", file=sys.stderr)
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
