#!/usr/bin/env python3
"""Compile the heuristics ledger from one fragment file per lesson.

Every ledger entry lives in its own fragment, references/heuristics/<slug>.md: a short front
matter (section, order, pins) and then the entry itself. Harvest PRs add fragments only, so two
PRs never edit the same lines of the ledger. This tool rebuilds the generated part of
references/heuristics.md, from the first "## " section heading to the end of the file; the
hand-written header above it is kept as it is.

Usage:
  python3 scripts/compile_heuristics.py [--root DIR]          lint, then rewrite the ledger
  python3 scripts/compile_heuristics.py --lint [--root DIR]   validate fragments and pins only
  python3 scripts/compile_heuristics.py --check [--root DIR]  exit 1 if the ledger is stale
"""

import argparse
import pathlib
import re
import sys

KEYS = ("section", "order", "pin")
NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
FIELDS = ("**Why:**", "**Provenance:**", "**Landed in:**")
MIN_PIN = 12


def load_ledger(path):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.startswith("## "):
            sections = [l[3:].rstrip("\n") for l in lines[i:] if l.startswith("## ")]
            return text, "".join(lines[:i]), sections
    sys.exit(f"FAIL: {path}: no '## ' section heading")


def parse(path, errors):
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    if not lines or lines[0] != "---\n" or "---\n" not in lines[1:]:
        errors.append(f"{path.name}: must open and close its front matter with '---' lines")
        return None
    end = lines.index("---\n", 1)
    meta = {"pin": []}
    for line in lines[1:end]:
        m = re.match(r"^([a-z]+): (.+)$", line.rstrip("\n"))
        if not m or m.group(1) not in KEYS:
            errors.append(f"{path.name}: unknown front matter line {line.strip()!r}")
        elif m.group(1) == "pin":
            meta["pin"].append(m.group(2))
        elif m.group(1) in meta:
            errors.append(f"{path.name}: '{m.group(1)}' is set twice")
        else:
            meta[m.group(1)] = m.group(2)
    return meta, "".join(lines[end + 1:])


def check_pin(root, name, pin, errors):
    target, sep, phrase = pin.partition(" :: ")
    parts = pathlib.PurePosixPath(target).parts
    if not sep or len(phrase) < MIN_PIN or target.startswith("/") or ".." in parts:
        errors.append(f"{name}: pin must be '<repo file> :: <phrase of {MIN_PIN}+ characters>'")
    elif not (root / target).is_file():
        errors.append(f"{name}: pinned file {target} does not exist")
    elif phrase not in (root / target).read_text(encoding="utf-8"):
        errors.append(f"{name}: pinned phrase is missing from {target}: {phrase!r}")


def lint(root, sections):
    frag_dir = root / "references" / "heuristics"
    errors, frags, bodies = [], [], set()
    for path in sorted(frag_dir.glob("*.md")):
        if path.name == "README.md":
            continue
        if not NAME.match(path.name):
            errors.append(f"{path.name}: use a lowercase kebab-case name, like 'review-one-commit.md'")
        parsed = parse(path, errors)
        if parsed is None:
            continue
        meta, body = parsed
        if meta.get("section") not in sections:
            errors.append(f"{path.name}: section {meta.get('section')!r} is not a '## ' heading in the ledger")
        if not meta.get("order", "").isdigit():
            errors.append(f"{path.name}: order must be a whole number")
        lines = body.splitlines()
        if not lines or not lines[0].startswith("- **Heuristic:** ") or not body.endswith("\n"):
            errors.append(f"{path.name}: the entry must start with '- **Heuristic:** ' and end with a newline")
        if any(not line.startswith("  ") for line in lines[1:]):
            errors.append(f"{path.name}: indent continuation lines two spaces, with no blank lines")
        joined = " ".join(line.strip() for line in lines)
        missing = [field for field in FIELDS if field not in joined]
        if missing:
            errors.append(f"{path.name}: the entry is missing {', '.join(missing)}")
        if body in bodies:
            errors.append(f"{path.name}: the same entry already exists in another fragment")
        bodies.add(body)
        for pin in meta["pin"]:
            check_pin(root, path.name, pin, errors)
        frags.append((meta, body, path.name))
    unpinned = sum(1 for meta, _, _ in frags if not meta["pin"])
    try:
        ceiling = int((frag_dir / "UNPINNED_CEILING").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        errors.append("UNPINNED_CEILING: missing, or not a whole number")
        ceiling = unpinned
    if unpinned > ceiling:
        errors.append(f"{unpinned} fragments have no pin, above the ceiling of {ceiling}: add a pin to each new fragment")
    return frags, errors, unpinned, ceiling


def render(header, sections, frags):
    blocks = []
    for name in sections:
        entries = sorted((f for f in frags if f[0]["section"] == name), key=lambda f: (-int(f[0]["order"]), f[2]))
        blocks.append(f"## {name}\n" + "".join(body for _, body, _ in entries))
    return header + "\n".join(blocks)


def main():
    ap = argparse.ArgumentParser(description="Compile references/heuristics.md from its fragments.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--lint", action="store_true", help="validate fragments and pins only")
    mode.add_argument("--check", action="store_true", help="exit 1 if references/heuristics.md is stale")
    ap.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    args = ap.parse_args()

    ledger = args.root / "references" / "heuristics.md"
    text, header, sections = load_ledger(ledger)
    frags, errors, unpinned, ceiling = lint(args.root, sections)
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    summary = f"{len(frags)} fragments, {len(frags) - unpinned} pinned, {unpinned} unpinned (ceiling {ceiling})"
    if args.lint:
        print(f"ok:   heuristics fragments valid: {summary}")
        if unpinned < ceiling:
            print(f"info: lower references/heuristics/UNPINNED_CEILING to {unpinned}")
        return 0
    compiled = render(header, sections, frags)
    if args.check:
        if compiled != text:
            print("STALE: references/heuristics.md does not match its fragments; "
                  "run python3 scripts/compile_heuristics.py", file=sys.stderr)
            return 1
        print(f"ok:   references/heuristics.md matches its fragments ({summary})")
        return 0
    with open(ledger, "w", encoding="utf-8", newline="\n") as out:
        out.write(compiled)
    print(f"ok:   compiled {summary} into references/heuristics.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
