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

A local container or offline proxy is still only local evidence. It can prove your client/protocol
path, but it is not proof of a live managed service or a public release; if acceptance says "live"
or "shipped," require that exact evidence or leave it blocked/unverified (`[learn]` issue #104).

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
- **Isolating HOME must keep path-sandbox prerequisites.** A credential-isolated `HOME` can drop
  legitimate HOME-relative companion checkouts that directory-sandbox integration checks expect, so
  status and authorization cases fail before reaching their logic. During preflight, **inventory
  HOME-relative companion repositories as validation prerequisites**; inside the isolation, restore
  verified **read-only copies** of the ones that already exist. Never weaken the sandbox or its
  assertions, and **never copy credentials or user runtime state** into the isolated HOME (hermetic
  unit cases should own their fixtures instead). After a fix, re-run the affected cases first, then
  the original full gate; keep the failure trace and distinguish cached from newly executed
  evidence (`[learn]` issue #145).
- **A whole-repo gate must not mutate the tree or the real HOME.** Formatters and vetters in the gate
  (e.g. `go fmt`/`go vet`) can rewrite tracked dependency manifests such as `go.mod` when a module
  is only an *indirect* dependency and the code newly uses it directly. Prefer the standard library
  (stdlib) over a direct use of an indirect-only dependency so the gate leaves manifests untouched.
  Run the gate with an isolated `HOME` so tool tests cannot read operator credentials or leave
  untracked artifacts. When a HOME-relative sandbox needs a prerequisite, point the expected path
  (a **symlink** is fine) only at the verified, credential-free, read-only copy the rule above
  restores inside the isolation — never at the operator's own checkout or real HOME, which a test
  could read or mutate (`[learn]` issue #150).
- **Make the container own its lifetime.** Container validation wrappers should not rely on shell
  `trap` cleanup alone — a signal before the job or container ID is recorded, a second signal during
  finalization, `--rm` deleting the cidfile before it is read, or `SIGKILL` can all leak a container.
  Run the container with `--rm` under an inner or engine timeout (`--timeout`) so it terminates and
  removes itself even if the wrapper dies; have the container write its own log and exit status into
  the mounted results directory; capture the container ID from both `--cidfile` and `run` stdout;
  ignore catchable terminating signals and join every background job first in the `EXIT` finalizer;
  and still prove container absence afterward, treating a runtime probe error as unproven rather
  than absent (residual: a container created but never started is not covered by `--rm`). Field-test
  by `SIGKILL`ing the wrapper mid-run and polling until the container is gone (`[learn]` issue #142).

## Cross-links
`references/scenarios.md` · `references/scoring.md` · `scripts/loop.sh`
