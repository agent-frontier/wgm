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
import hashlib
import pathlib
import re
import sys

KEYS = ("section", "order", "pin")
NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
FIELDS = ("**Why:**", "**Provenance:**", "**Landed in:**")
MIN_PIN = 12

# Entries that predate pins, frozen by the sha256 of their text when the ledger moved to fragments.
# Only these may go without a pin, so a new or reworded entry always needs one. Never add to this
# set; delete a digest once its entry gets a pin.
LEGACY_UNPINNED = frozenset("""
08814293f98655ec 09a45eb3509bf809 0ce48dc82e4ee51d 10a51b97ae787974 10da44d1129e7465 14f37182e7e34a88
159a7ec73fd956a3 190c0f910429d30d 1bd4116057c000c4 1c9764eb6dfb76fd 1f9eafdb98f77914 280ca99a99217ede
294d690fbcd40af7 40a381639574feb9 41b679878069bc4f 420910f55a1c0c8b 4a255f1664b74c45 4b6b4511a0ab8117
4b9076b317c099f8 5093a101c76a5724 52c5193917902367 538cecec6f68c4df 583921a583965317 60fea0988e25123d
6791eebdef139258 67cc5b64560bfe84 6b6db8b49a589be6 6c9806eaef3ba693 6f74efdd9a48d3c7 713915cb6348f695
71f061206ec13eff 724464a1a7d70a35 762ddddbb478d8d4 78977844124cacbc 7c944f6f94143168 7cb47a723f3459ca
7e366c073dc0cc2b 801424e5190abdbd 8099545fe42aa2da 85a9cc842fe9038d 88a95914241d90b5 8a84da2ffa3195bc
8b16d5d07ad69bae 906e7de2f454722d 93324e68cd307614 949a8dfcae61645d 99ea04dc43b8aadb 9b8900013418ac73
a05260dce20b06f3 a594e2d175cf8028 a70f5aeec1ef8186 a7b64f1fdb8d34ba ada6d920e176f836 ae39503c4d9a33e5
b038ab8529ecf089 b2ba198acce88620 b2c85c67857546e1 baf1fd1916bb7391 bd24715141e2a662 c08cb10cefc5bd6b
c48185c2f3d1b891 c73d527b283c0c01 c8d34fb197decb18 d2860355790074dc d41050178010aa02 d69de61ac990fb19
da6f317c65d1eb5d dbba27a3f773f5d7 dc66dd2901b0f429 e05703c98610d927 e2bcdabd92f41413 e3012cbc130bd44d
e5fccdae2e5334eb e6760e23a9af92a7 e96726d317efc39f eeb17601319b36c5 f46aa0c8b7cbe59e f6f52f9e43b737e2
faf3965f6ad95085 ff642de2e674abdf
""".split())


def digest(body):
    return hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]


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
    if not frag_dir.is_dir():
        return frags, ["references/heuristics/ is missing"], 0
    for path in sorted(frag_dir.iterdir()):
        if path.name == "README.md" and path.is_file():
            continue
        if not path.is_file() or path.suffix != ".md":
            errors.append(f"{path.name}: unexpected file; this directory holds only .md fragments")
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

    # Only entries whose text predates pins may go without one; renaming a file does not matter.
    unpinned = [(name, body) for meta, body, name in frags if not meta["pin"]]
    for name, body in unpinned:
        if digest(body) not in LEGACY_UNPINNED:
            errors.append(f"{name}: add a pin; only the entries that predate pins may go without one")
    return frags, errors, len(unpinned)


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
    frags, errors, unpinned = lint(args.root, sections)
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    summary = f"{len(frags)} fragments, {len(frags) - unpinned} pinned, {unpinned} older entries without a pin"
    if args.lint:
        print(f"ok:   heuristics fragments valid: {summary}")
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
