# Validation environment — OCI containers (Podman-first)

Some scenarios (`references/scenarios.md`) need the software actually **running** — an HTTP API, a
CLI, or a TUI. A container gives a clean, reproducible, isolated place to run it so the judge
(`references/scoring.md`) grades real behavior instead of a mock. Containers are **optional**: use one
only when a scenario needs a live service.

## Podman-first, Docker fallback
Prefer **Podman** with **OCI** images (rootless by default); **Docker** is a drop-in fallback — the
same OCI image and argument-compatible commands work under either. Prefer a **`Containerfile`** (the
OCI name); fall back to `Dockerfile`. The skill picks `podman` if present, else `docker`;
`scripts/loop.sh` exposes `--container podman|docker` to force one.

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

## Cross-links
`references/scenarios.md` · `references/scoring.md` · `scripts/loop.sh`
