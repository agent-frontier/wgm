---
section: Local sandboxing (devcontainers)
order: 8
---
- **Heuristic:** keep three build clocks distinct — **wall**, **allocated lane time** (capacity
  upper bound), and **active agent time** (measured lower bound, summed per *turn*) — and never call
  parked-lane lifetime "agent-hours." **Why:** a lane alive between turns still burns lifetime, so
  summing lifetimes and dividing by wall time reports a flattering number that is not work done;
  static per-lane utilization also understates elastically-expanded swarms badly. Report missing
  telemetry as counts and a stated lower bound rather than estimating it, and label every ratio an
  operational heuristic — not billing data, not a causal speedup claim. **Provenance:** `[learn]`
  issues #70, #72, #74, #84, #85. **Landed in:** `references/telemetry.md` · `scripts/swarm.sh`
  (the `== swarm telemetry ==` block) · `scripts/loop.sh` (per-turn ledger) · `SKILL.md` Phase 4.
