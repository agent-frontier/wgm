# Heuristics ledger fragments

Each file here is one ledger entry. `python3 scripts/compile_heuristics.py` compiles them, newest
first, into the sections of [`../heuristics.md`](../heuristics.md). Between releases these files are
the authoritative ledger; the compiled file is rebuilt when a release is prepared.

## Add a lesson

1. Land the rule's text once, in the reference the agent reads when the rule applies (see "Promote
   & retain" in [`../self-improvement.md`](../self-improvement.md)).
2. Add `references/heuristics/<name>.md`, named after the rule in lowercase kebab-case, for example
   `review-one-immutable-commit.md`:

   ```text
   ---
   section: Review
   order: 137
   pin: references/subagents.md :: **Review one immutable commit.**
   ---
   - **Heuristic:** give every reviewer one immutable commit and pause the writer until the
     verdict is in.
     **Why:** a review of a live worktree cannot be tied to the code that ships.
     **Provenance:** `[learn]` issue #137. **Landed in:** `references/subagents.md`.
   ```

   - `section` is one of the ledger's section headings.
   - `order` sorts the section newest first. Use the lesson's `[learn]` issue number; if it has
     none, use the number of the PR that adds it.
   - `pin` names the file where the rule landed and an exact phrase of 12 or more characters that
     must stay in it. Add one pin per landing file.
   - The entry holds the four ledger fields, with continuation lines indented two spaces.
3. Run `python3 scripts/compile_heuristics.py --lint`. `scripts/check-docs.sh` runs it too, and fails
   if a fragment is malformed or a pinned phrase disappears. Do not edit `heuristics.md`: a PR that
   only adds fragments never conflicts with another one.

## Pins

Every fragment needs a pin, except the older entries that predate pins. `compile_heuristics.py`
knows those by the text they had when the ledger moved to fragments, so a new or reworded entry
always needs a pin, while renaming a file changes nothing. That frozen set only shrinks: once an
older entry gets a pin, delete its digest from the tool.

## Fold-ins

The rule's text still edits a shared reference. Keep each fold-in to a few lines at its own anchor,
and when two open PRs change the same section of a reference, land them one at a time.

## Releases

Before tagging, run `python3 scripts/compile_heuristics.py` and commit the rebuilt ledger. The
release workflow runs `--check` and refuses a ledger that is behind its fragments.
