# Validation environment — OCI containers (Podman-first)

Some scenarios (`references/scenarios.md`) need the software actually **running** — an HTTP API, a
CLI, or a TUI. A container gives a clean, reproducible, isolated place to run it so the judge
(`references/scoring.md`) grades real behavior instead of a mock. Containers are **optional**: use one
only when a scenario needs a live service.

## Podman-first, Docker fallback
Prefer **Podman** with **OCI** images (rootless by default); **Docker** is a drop-in fallback — the
same OCI image and argument-compatible commands work under either. Prefer a **`Containerfile`** (the
OCI name); fall back to `Dockerfile`. `scripts/loop.sh` resolves `--container auto` to available
Podman, then Docker, and reports `unavailable` when neither exists. `--container podman|docker`
forces one and fails clearly if that engine is absent. The runner selects and reports the engine; a
host adapter or agent owns the actual build/run/readiness/scenario execution flow below.

| Action | Podman | Docker |
|---|---|---|
| Build | `podman build -t wgm-app -f Containerfile .` | `docker build -t wgm-app -f Dockerfile .` |
| Run | `podman run --rm -d -p 8080:8080 --name wgm-app wgm-app` | `docker run --rm -d -p 8080:8080 --name wgm-app wgm-app` |
| Exec | `podman exec wgm-app <cmd>` | `docker exec wgm-app <cmd>` |
| Logs | `podman logs wgm-app` | `docker logs wgm-app` |
| Stop/rm | `podman rm -f wgm-app` | `docker rm -f wgm-app` |

## Validation flow
1. **Build** an image from the implementation.
2. **Run** the container — publish a port (HTTP), `exec` in (CLI), or attach a PTY (TUI).
3. **Wait for readiness** — poll a healthcheck/endpoint; don't grade before the service is up.
4. **Drive scenarios** — for each step, perform the action (HTTP probe / CLI exec / PTY keystrokes)
   and capture the observed output.
5. **Judge** — score satisfaction per step (`references/scoring.md`).
6. **Clean up** — remove the container (and image if ephemeral).

## When NOT to containerize
If a fast local deterministic check suffices — a unit test, a type-check, a local HTTP probe — skip
the container. Don't make Podman/Docker a hard dependency of wgm; reach for a container only when a
running service is the only way to observe the behavior a scenario describes.

## Safety & footguns
- Rootless Podman by default; run as a non-root user inside the image.
- Bind to **localhost**; pick a free port (and parameterize it) to avoid collisions across iterations.
- **Never** bake secrets into the image or mount credential files; pass throwaway test config only.
- Always clean up (`--rm`, remove dangling images) so iterations don't leak containers.
- **`localhost` is the right default only for a *same-side* consumer.** Bind/publish on loopback
  when the thing that calls the service runs on the same OS instance. When the consumer lives across
  a virtualization boundary — a **Windows process calling a service inside WSL**, a browser on the
  host calling a VM guest — loopback inside the guest is invisible to it: the guest's `127.0.0.1` is
  not the host's. Publish on all interfaces (or forward the port) and have the consumer use the
  guest's routable address (for WSL, the distro's IPv4) — noting that an all-interfaces bind is
  **LAN-reachable while it runs**, so keep such a service disposable, short-lived, and free of real
  data. **Verify it from the consumer's own OS**: a
  guest-side `curl` cannot observe that boundary at all, because it never crosses it. Run
  `bash scripts/test-wsl-windows-boundary.sh` on a Windows+WSL host to contrast both binds with a
  real Windows-origin probe (`[learn]` issue `agent-frontier/wgm#101`).
- **An isolated verifier must own its target directory.** A validation chain that inherits a
  globally shared build-target override (a `*_TARGET_DIR`-style env var, a shared cache path, a
  user-level tool config) can emit artifacts *outside* the stage-local path its verifier then
  checks — and the resulting "missing artifact" error looks exactly like a product defect while
  being a harness misconfiguration. Before an isolated staged build, **clear or scope ambient target
  overrides**, or set an explicit stage-local target directory the verifier and the build agree on.
  When a clean rerun in the gate-owned environment then passes, record that outcome **separately
  from product failures** — folding an environment fault into the product's failure count corrupts
  the signal the loop steers by (`[learn]` issue #83).

## Cross-links
`references/scenarios.md` · `references/scoring.md` · `scripts/loop.sh`
