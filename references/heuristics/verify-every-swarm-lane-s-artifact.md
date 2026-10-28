---
section: Swarm & parallelism
order: 1
---
- **Heuristic:** verify every swarm lane's artifact after it exits; `status=ok, commits=0` is a hard
  failure, not a successful lane.
  **Why:** a constrained or misconfigured agent can reason for minutes, exit zero, and produce no
  commit; duration and status are not evidence of work. **Provenance:** `[learn]` issue #92. **Landed
  in:** `scripts/swarm.sh`, `scripts/test-swarm.sh`, and `docs/reference/cli-swarm.md`.
