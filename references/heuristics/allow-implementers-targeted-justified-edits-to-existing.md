---
section: Loop discipline
order: 18
---
- **Heuristic:** allow implementers targeted, justified edits to existing tests; treat test-only
  branches in production code as a review finding.
  **Why:** a blanket ban on test edits pushed an implementer to add a production shim that existed
  only to keep an obsolete assertion green. **Provenance:** `[learn]` issue #132. **Landed in:**
  `references/subagents.md` (Dispatch points).
