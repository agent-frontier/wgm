# Local devcontainer sandbox — disk-conscious (Podman-first)

Some Ralph-full runs (`scripts/loop.sh`, `references/ralph-loop.md`) benefit from running the loop
itself sandboxed — isolating an autonomous agent from the host filesystem beyond the one project
it's mounted into. This is **not** the scenario-validation container
(`references/validation-env.md`, which runs the app *under test*); this runs the **agent loop**.
Optional: reach for it only when you want that isolation: `scripts/loop.sh --devcontainer`.

## The one design constraint: don't inflate disk per project
The naive approach — a `"build"` devcontainer.json per project — costs one multi-GB image per
project. wgm's approach costs **one image, total**:
- `scripts/devcontainer.sh init` scaffolds a `devcontainer.json` that references a **shared,
  prebuilt `"image"`** (`localhost/wgm-devcontainer-base:latest`), never a per-project `"build"`.
- The project directory is **bind-mounted**, never `COPY`'d into the image, so the image stays
  generic and tiny (~400MB) regardless of repo size or project count.
- `build-base` is **idempotent** — it no-ops (skip, don't rebuild) once the tag already exists
  locally, unless `--force`. Rebuilding a shared image on every run would defeat the point.
- `prune` reports `system df` and removes only **wgm-labeled** stopped containers / dangling
  images — never the shared tag itself, never anything without the label.

## Podman-first, Docker fallback
Same convention as `loop.sh --container`. `scripts/devcontainer.sh` talks to `podman`/`docker`
directly (no dependency on the separate `@devcontainers/cli`) — the scaffolded `devcontainer.json`
is still a standards-compliant [containers.dev](https://containers.dev) artifact any devcontainer
CLI or VS Code can also open for interactive work.

## Subcommands
`init` (scaffold) · `build-base` (build once, idempotent) · `run -- <cmd...>` (execute sandboxed,
auto-builds on first use) · `prune` (disk hygiene). See `docs/operator/devcontainers.md` for the
full flag reference and examples.

## Permission parity (the load-bearing gotcha)
`run` executes as the **calling host user's UID:GID**, not the image's baked UID, and adds
Podman's `--userns=keep-id` (rootless Podman otherwise remaps the caller to a different apparent
UID inside its user namespace; Docker needs no such flag). Without this, a bind-mounted project
directory that isn't world-readable (a `mktemp -d`-style `0700` dir is the common trap) is
unreadable/unwritable inside the sandbox even though the mount itself "succeeds."

## Bringing your own agent CLI
The shared image is deliberately generic — it does not bake in any one vendor's coding-agent CLI.
`run` best-effort mounts the host's `npm config get prefix` directory read-only at the same path
and prepends its `bin/` to `PATH`, so an already-installed CLI (`copilot`, `claude`, `codex`, …)
resolves inside the sandbox unchanged. Native addons in that CLI could still misbehave across a
different base distro — a convenience, not a guarantee.

## Auth/config beyond the CLI binary itself
Some agent CLIs need more than their binary — a token or config file under the host's `$HOME`
(`~/.copilot`, `~/.claude`, `~/.config/gh`, …). `run --mount HOST[:CONTAINER]` (repeatable) opts
a specific directory in explicitly. **Never** mount the whole `$HOME` by default — that would
quietly turn "sandboxed loop" into "loop with full access to your dotfiles, SSH keys, and every
other project," defeating the isolation this exists to provide.

## `scripts/loop.sh --devcontainer`
A thin re-exec shim: it delegates the *entire* invocation (same argv, minus `--devcontainer`) to
`scripts/devcontainer.sh run`, bind-mounting both the project (`/workspace`) and the wgm skill
itself (`/opt/wgm-skill`, read-only) so the re-invoked `loop.sh` can find its sibling files inside
the sandbox. `WGM_IN_DEVCONTAINER=1` is set on every container `devcontainer.sh run` launches
(not just this path) as a recursion guard. `$WGM_AGENT` / `$WGM_FRUGAL_AGENT` / `$WGM_PROMPT_STDIN`
are forwarded automatically when set; `--agent`/`-- argv` forms are forwarded as literal argv. A
no-op with `--dry-run` (annotates the preview instead of launching a container).

## When NOT to use it
If the loop is already running somewhere sufficiently isolated (CI, a disposable VM, a Codespace),
or the project's own toolchain isn't present inside the shared minimal image and mounting it in is
more friction than it's worth, just run `loop.sh` directly on the host. This is optional, additive
isolation — never a hard dependency of using wgm.

## Cross-links
`references/ralph-loop.md` (Ralph-lite vs Ralph-full) · `references/validation-env.md` (the
*other* container use case — validating the app under test) · `docs/operator/devcontainers.md` ·
`docs/operator/running-the-loop.md`.
