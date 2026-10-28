---
section: Local sandboxing (devcontainers)
order: 1
---
- **Heuristic:** a probe that is supposed to make a gate fail must be **verified to have applied**
  before its result is believed. **Why:** three probes in one session were silently inert — a `sed`
  whose `||` broke the `s|…|…|` delimiter and edited nothing, and a canary test naming an eval id
  absent from the harness fixture, so the run aborted on "unknown eval id" and the assertion passed
  without ever exercising the code. Each looked like proof the gate worked. Assert the edit changed
  the file, or the probe tests nothing but your own optimism. **Provenance:** wgm dogfood.
  **Landed in:** `scripts/test-grade-evals.sh` · this ledger.
