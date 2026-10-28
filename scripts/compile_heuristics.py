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
08814293f98655ec25e7ca4fef17087cb9ee40c59a712f46dfbf68efd499c136
09a45eb3509bf8090b9f8db26b384453002a3216ed5cc76c79c2a0c13b86ccbd
0ce48dc82e4ee51d4b0388c58f7312c457b033aab16184140542de2ba1237061
10a51b97ae787974292a5c9ab7b707ea4be3dbebc6d803801a30d522ece8555c
10da44d1129e7465ca6e51b25f822072537e1aab11e3902b00ee89a2baf9f0af
14f37182e7e34a8859de5305b348ff5340229d08b1026632a4b1534638fc965f
159a7ec73fd956a3bacd326604d7314415496cf8952273713f6d2e4096ea0372
190c0f910429d30d39ec9ee0f7c47a38ebdca833e57b254d72e8216a89b4a198
1bd4116057c000c4c5ecccdc63245c13a34ae5f0c16c8aa67b92742c3a4e9467
1c9764eb6dfb76fd655579a7b2d9604f72ca5a74fb4c6d8c5e3fd79bc89d3c3b
1f9eafdb98f7791459b94b2faed3059f26d28e1144e77c9b47893560c3331b17
280ca99a99217ede2dc2db64fe8315002d405d3e3de03ecc7ee57d55142d3757
294d690fbcd40af7a037892186f2883d6f5f0b689867c25c151b6ad5eaf8e693
40a381639574feb9b4960f511f00ad3a12514a8990b46d0b4e70d521f08c73d7
41b679878069bc4fd4f7f4b3da9e0f11e1e04a2973d45fdf2a6c3d7aa0ecf7f3
420910f55a1c0c8b048803e6b4c99a802891c73219169540caa0bb60640b30c9
4a255f1664b74c45c2054621a6f20cb737319bb7eac1cf4693d6b7d591719660
4b6b4511a0ab8117c2c7ee6bb697c77a13fabbc10c9e67b000f5e48fe64b9eda
4b9076b317c099f8c3b4a67bc0a09964308b1669d767e8ef60cfca3675b10034
5093a101c76a5724842c563810523a0257c5321e2ad00e0d836f24c0a693dc49
52c51939179023676ece5fea53d2fc39149b1a7c738689d4c97167f4a4315676
538cecec6f68c4df6a5954f27c20a66be3293eb0ed3a4f430085ff6075a691c5
583921a583965317b2804f8857c47fdf602cbe3addf3d64e9cd6fb40d063adb8
60fea0988e25123dd951e67eceeeff87f8394853fb65cfe6886aa57ad2f8e976
6791eebdef1392588194f8e66dea5dffc922fba40330f41477421317e60ebe2b
67cc5b64560bfe848cfbc3a737d32c6927d526e45dbd0b0c6273bfdda7eb61e4
6b6db8b49a589be6d32fcd9f01355c5ffb52e5f8e90588c28a5cd2cc3db0d1a0
6c9806eaef3ba6935983ea9ce890ddc5f34d781d8117dd87cc9519317258b18f
6f74efdd9a48d3c72a2a00b15c955f25bf4f045000872da2f3a58c73fde1e353
713915cb6348f695be50f5818b194f1e7a4acb0f0f53890fb38ee66c476ef377
71f061206ec13eff8ec020f896a7a0f2408aa8fdca0fd1765591c898b31c40b7
724464a1a7d70a352b43a76f20e54887f45e1e762b24e332bffca2cfe7568534
762ddddbb478d8d42b11bfcb21dc5d6f4886c4f5ef28dd7e0d6d1bcbd9d80d9a
78977844124cacbc63c2b63ed6b034dd7c9c762a887e78230af8b1c9efeed169
7c944f6f9414316853d12c11506b5716ba333b4058b6eb292e7c366910b12921
7cb47a723f3459caeea07c5c7386708adc561932e6c85209ea3e826162d78e50
7e366c073dc0cc2b66b81676b0f91b3da33d600a09ad4fdae4f82b09cebe0475
801424e5190abdbd354823ce80680b9df2385a197053fdb13caeb3ad61556320
8099545fe42aa2dac058fe588e74ba65daba43c627e14d49ad06d7a4adc78ea7
85a9cc842fe9038d3a483ba5b04fb7cbb827bc929efb117006ce1ba7cbd8c21d
88a95914241d90b5a4318d69d7e4ab8f9bde529434a0d79c4e0f9f366654cbe6
8a84da2ffa3195bc2eb22add50ce34cd0b600912a3dd87e5ea03d2902f3534a6
8b16d5d07ad69bae78441468f66382da49411e7c84c324f00c0ef99b248f536a
906e7de2f454722df17a2e44e116c0d231322cab334a655ac118f0ed5cf0e2d1
93324e68cd307614bf44460b732aedba57475217956dcc22b08a061328e78603
949a8dfcae61645da387639fb9d3e41c2737d00865904c6d4281c96a5dbe0f54
99ea04dc43b8aadba98ebb1193795b66cd04097ff54ceced12a92b92163c0903
9b8900013418ac735d3d41d38fdac8b3e98b840d872365904223b3e57abdfa98
a05260dce20b06f392764f0f569c0396a8295150f1c24f0f21b5d11384f8f6b9
a594e2d175cf802852db1e20ab98851a9c441cab8a3ed2d23e373d16db7d1e4b
a70f5aeec1ef81866343d428f175ce6d72eee9a7e2c3696d437436459c835c69
a7b64f1fdb8d34ba10eba0ad08465790abcf21f5e697d44ceb9c8ce9b1b6f3da
ada6d920e176f8366662be9e0ed9f9e3001f50d480100eaf440ef44c8c8832c4
ae39503c4d9a33e5968cad67d5394363dc9eae80c56cf807443ab04225cd1595
b038ab8529ecf0890cad4f8cc00745dbe4f5e64903836545d82c40fd0f751b8d
b2ba198acce88620375fe9c7abef7d80b46a9ea8e7d8e51fd2d414ba87af2293
b2c85c67857546e12fe02a5ea8d97db42d575d081826d6ec6f0ac4d7e5e855e9
baf1fd1916bb73918a8123c545e095e18c11baea6e402bf2164df56184348fdc
bd24715141e2a6623d26d86f7fbed0783187cf22001d1c1ebd43473a3599ad0f
c08cb10cefc5bd6ba6be69c09483cb3e7f414013ab6c74007c7cc9d3152b8eb2
c48185c2f3d1b8915e9e14793dc39c8023f4d9444f0dc289b89727831abf6890
c73d527b283c0c0153c73e35c241a1fb6286af64e2debec8fa68a25cf0a4f0fe
c8d34fb197decb18edfa57ace979873d49325dca8b0a91e7318a084851324a41
d2860355790074dca4da19e1a7c55735c8e3e6e4ee5dfbd8a968ac3fab827f8d
d41050178010aa02b124221a3d1df61ef7b4f852755ed78e360e88ba2fabcca0
d69de61ac990fb19e6882bd4e5a1f5bf12470170d22cdae3157ed6cfe2281388
da6f317c65d1eb5debfc3a549ddeb781e8ec747de6ad7f2fc2c69f0ae5eba720
dbba27a3f773f5d7327d174562d68c070f844274dff67ea253b635c8c8b6f390
dc66dd2901b0f429103cfba40ac2be75a3db7bf19c3e940a11204eca873186e1
e05703c98610d9271e565441d28bbf7e993a62fa218866ad0b71a757b06db029
e2bcdabd92f4141325e4fbc0b918e782da5f6f58bbb76f367e6a548a43e91d3e
e3012cbc130bd44d1b63ead9be9e21229c447f21ccfa4bca799ed484723d56d8
e5fccdae2e5334eb917817a8ab5a3151d81409b834ccaa7486a28c0ea7ce9146
e6760e23a9af92a7e4e2fc9c981e672885ceb378af6bf9da59e60886283beb33
e96726d317efc39f07e761c1a6ece99824b8487b4f0e0402748a9aaf474c2bd5
eeb17601319b36c5ff0ac5111d641d66611cde052905df1a37f8da3e256287db
f46aa0c8b7cbe59eaab6d5eae3a1d671ff5ae7266ce01254705735e7ec5bbf7f
f6f52f9e43b737e2605d976b7d385958a237de77c61e8284ed44334239b1280a
faf3965f6ad95085df4b36609eb2d0735d997bfaadc56631cb6a079327f08fba
ff642de2e674abdfeb134033937af0117ce5dba5c5dca76762dc451a139da424
""".split())


def digest(body):
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


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
    stale = len(LEGACY_UNPINNED - {digest(body) for _, body in unpinned})
    return frags, errors, len(unpinned), stale


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
    frags, errors, unpinned, stale = lint(args.root, sections)
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    summary = f"{len(frags)} fragments, {len(frags) - unpinned} pinned, {unpinned} older entries without a pin"
    if args.lint:
        print(f"ok:   heuristics fragments valid: {summary}")
        if stale:
            print(f"info: {stale} frozen digests match no unpinned entry; delete them from LEGACY_UNPINNED")
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
