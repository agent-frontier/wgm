---
section: Local sandboxing (devcontainers)
order: 13
---
- **Heuristic:** when sandboxing the loop itself in a local devcontainer, reference ONE shared,
  prebuilt image (`"image"`, never a per-project `"build"`), bind-mount the project instead of
  copying it in, make the build idempotent (skip an unnecessary rebuild), and label every created
  resource so cleanup can be scoped to exactly what the tool created.
  **Why:** a per-project `"build"` devcontainer.json costs a new multi-GB image per project — the
  literal disk-bloat failure mode a "manageable" local sandbox exists to avoid; an unlabeled prune
  either does nothing useful or risks touching a container/image it didn't create. **Provenance:**
  external research, `containers.dev`'s prebuilt-image reuse
  guidance + standard Docker/Podman disk-hygiene practice (`system df`, scoped `prune`).
  **Landed in:** `scripts/devcontainer.sh` · `references/devcontainers.md` ·
  `docs/operator/devcontainers.md`.
