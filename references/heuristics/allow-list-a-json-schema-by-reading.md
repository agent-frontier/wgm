---
section: Local sandboxing (devcontainers)
order: 10
---
- **Heuristic:** allow-list a JSON schema by reading its **key set structurally** (`jq keys`), never
  by scanning for identifier-shaped names. **Why:** an identifier regex silently skips exactly the
  keys drift produces — `expected_output2`, `x-note` — so a renamed or typo'd field passes the gate
  it was written to stop. Required-field checks alone are also insufficient: they prove what is
  present, never that nothing unexpected is. **Provenance:** `[learn]` issue #86.
  **Landed in:** `scripts/check-evals.sh` · `scripts/test-check-evals.sh`.
