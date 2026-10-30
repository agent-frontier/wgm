---
section: Backpressure
order: 142
pin: references/validation-env.md :: **Make the container own its lifetime.**
---
- **Heuristic:** make a validation container own its own lifetime (`--rm` plus an inner or engine
  timeout, self-written log/exit status in a mounted results dir, dual `--cidfile` + stdout ID
  capture, signal-shielded `EXIT` job join, and post-exit absence proof) instead of relying on
  shell-trap cleanup alone.
  **Why:** shell traps cannot survive `SIGKILL`, pre-registration signals, or `--rm` racing `--cidfile`
  reads, and treating a container-runtime probe error as "container absent" hides leaked containers;
  field-testing with mid-run `SIGKILL` proves self-cleanup. **Provenance:** `[learn]` issue #142.
  **Landed in:** `references/validation-env.md` (Safety & footguns).
