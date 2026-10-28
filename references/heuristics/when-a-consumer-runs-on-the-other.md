---
section: Backpressure
order: 19
---
- **Heuristic:** when a consumer runs on the other side of a virtualization boundary (a Windows
  process calling a service inside WSL, a host tool calling a VM guest), prove reachability with a
  probe that *runs on the consumer's OS* and declares the platform it ran on — and keep `localhost`
  as the default only for same-side probes.
  **Why:** a guest-side `curl` never crosses the boundary, so it reports green while the real
  consumer cannot connect; a loopback-only publish is invisible from the other side, and only an
  origin-declaring probe stops a same-side run from being relabeled as cross-boundary evidence.
  **Provenance:** `[learn]` issue #101 (a service on WSL loopback unreachable through the Windows
  interop path, reachable at the WSL IPv4 address once published on all interfaces). **Landed in:**
  `scripts/test-wsl-windows-boundary.sh` · `scripts/test-wsl-reachability.ps1` ·
  `references/hard-to-test-domains.md` (Cross-OS boundary reachability) ·
  `references/validation-env.md` · `docs/operator/containers.md` · `evals/evals.json` ·
  `scripts/test-check-evals.sh`.
