---
section: Loop discipline
order: 12
---
- **Heuristic:** probe the selected headless agent's write capability before the first paid
  iteration, and fail a build after repeated successful no-progress iterations.
  **Why:** a read-only sandbox can return exit 0 while producing no artifact, burning the full loop
  budget; `plan_changed=0` is already measured and must be a stall signal, not passive telemetry.
  **Provenance:** `[learn]` issue #94. **Landed in:** `scripts/loop.sh`, `scripts/test-loop.sh`,
  `docs/reference/cli-loop.md`.
