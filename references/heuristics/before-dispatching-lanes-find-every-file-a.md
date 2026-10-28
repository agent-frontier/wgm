---
section: Swarm & parallelism
order: 6
---
- **Heuristic:** before dispatching lanes, find every file a shared-type change breaks (exhaustive
  matches, struct literals, trait impls) and put it in the file set of the lane that owns the
  change, or sequence the lanes. **Why:** a file set drawn around the feature alone leaves the
  owning lane unable to finish without editing another lane's files. **Provenance:** `[learn]`
  issue #134. **Landed in:** `references/subagents.md` (Worktree swarm dispatch).
