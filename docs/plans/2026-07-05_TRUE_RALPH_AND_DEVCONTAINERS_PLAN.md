# Prefer true Ralph + a disk-conscious local devcontainer sandbox

**Date:** 2026-07-05 · **Status:** shipping via PR to `main`.

## Problem

Two related gaps, both raised directly by the maintainer while dogfooding wgm on itself:

1. **wgm under-used its own strongest mode.** Geoffrey Huntley's original definition is blunt:
   *"Ralph is a technique. In its purest form, Ralph is a Bash loop."* Yet wgm's own Triage default
   (`SKILL.md`, `references/ralph-loop.md`) reserved Ralph-full (`scripts/loop.sh`, genuinely fresh
   context per iteration) for "large or ambiguous builds" and defaulted to Ralph-lite (in-session)
   otherwise — quietly settling for the weaker, compromise form of the technique even when a headless
   agent invocation was one subprocess call away.
2. **No way to run the loop sandboxed locally without disk bloat.** wgm already had an OCI container
   story, but only for validating the *app under test* (`references/validation-env.md`,
   `docs/operator/containers.md`) — nothing sandboxed the *agent loop itself*. The maintainer
   explicitly wanted local devcontainers, but "in a manageable way that doesn't inflate a user's disk
   like crazy" — the naive per-project `devcontainer.json` `"build"` pattern costs a new multi-GB
   image per project.

## What shipped

### Workstream A — bias toward Ralph-full
- `SKILL.md` (Phase 0, "Decide loop mode"), `references/ralph-loop.md` ("Ralph-lite vs Ralph-full"),
  and `docs/operator/running-the-loop.md` now all lead with **Ralph-full as the preferred default**
  whenever a non-interactive agent invocation is available (`$WGM_AGENT`, or a known CLI — `copilot`,
  `claude`, `codex`, `aider` — on `PATH` with a print/non-interactive mode) — not only for
  large/ambiguous builds. Ralph-lite is now framed as the fallback: interactive-only hosts, or the
  Quick track where a whole subprocess loop is overkill for one short prompt.
- A new `references/heuristics.md` entry (Loop discipline) records this with Huntley's original
  definition as provenance (`ghuntley/how-to-ralph-wiggum`, ghuntley.com/loop) — an **external
  research** finding landed directly per `references/self-improvement.md`'s Cross-pollinate
  mechanism (found while already working in `agent-frontier/wgm`).

### Workstream B — `scripts/devcontainer.sh`: a disk-conscious local sandbox
New, additive, **opt-in** capability — never a hard dependency of using wgm:

- **`scripts/devcontainer.sh`** — `init` (scaffold `.devcontainer/devcontainer.json` referencing the
  shared image, refuses to clobber an existing file) · `build-base` (idempotent — skips an
  unnecessary rebuild unless `--force`) · `run -- CMD` (bind-mount the project + execute sandboxed,
  auto-builds the base image on first use) · `prune` (report `system df`, remove only wgm-labeled
  stopped containers / dangling images). Podman-first, Docker fallback — talks to the engine
  directly, no dependency on the separate `@devcontainers/cli`.
- **`assets/devcontainer/Containerfile.template`** — the ONE shared base image (Debian slim + bash/
  git/curl/jq/node, non-root `wgm` user, `LABEL wgm.devcontainer=1`). Deliberately generic: no
  project toolchain, no vendor-specific agent CLI baked in.
- **`assets/devcontainer/devcontainer.json.template`** — references `"image"` (never `"build"`), so
  `scripts/devcontainer.sh init` never scaffolds a per-project image build.
- **`scripts/loop.sh --devcontainer`** — a thin re-exec shim: delegates the entire invocation (same
  argv minus the flag) to `devcontainer.sh run`, bind-mounting the wgm skill itself read-only at
  `/opt/wgm-skill` so the re-invoked `loop.sh` finds its sibling files; `$WGM_AGENT` /
  `$WGM_FRUGAL_AGENT` / `$WGM_PROMPT_STDIN` forward automatically when set. A no-op with `--dry-run`.
- **`scripts/test-devcontainer.sh`** — 16 cases, mirroring `test-swarm.sh`'s style. Real (non-dry-run)
  cases against podman/docker (not just dry-run assertions): building the shared image, executing a
  sandboxed command with the bind-mount proven readable/writable, exit-code propagation, and prune's
  removal *and* its label-scoping safety boundary. Gracefully skips the real-engine cases when
  neither podman nor docker is installed.
- **Docs:** `references/devcontainers.md` (mechanics) + `docs/operator/devcontainers.md` (operator
  guide, Mermaid flow, disk-hygiene golden rules), cross-linked from `running-the-loop.md`,
  `containers.md`, and `docs/README.md`'s Map; added to `scripts/check-docs.sh`'s required files and
  Executive-overview check.
- **`references/heuristics.md`** — a second new entry (Local sandboxing) for the shared-image +
  labeled-prune pattern (external research: the containers.dev spec + standard Docker/Podman
  disk-hygiene practice).

## Decisions

- **Podman/docker directly, not `@devcontainers/cli`.** The scaffolded `devcontainer.json` is still a
  standards-compliant artifact any devcontainer CLI or VS Code can open for interactive work, but
  wgm's own automation avoids the extra dependency, matching how `loop.sh --container` already talks
  to the engine directly.
- **The permission-parity fix (found via real testing, not assumed).** `run` executes as the calling
  host user's UID:GID plus Podman's `--userns=keep-id` (Docker needs no such flag). This was not a
  design guess — the test harness's `mktemp -d` temp dir (mode `0700`) caught a genuine "Permission
  denied" that an earlier ad hoc `mkdir`-based manual smoke test (mode `0755`) had masked. Confirmed
  fixed end-to-end via `loop.sh --devcontainer` writing into a `chmod 700` project directory.
- **`--mount HOST[:CONTAINER]` instead of mounting all of `$HOME`.** An agent CLI's auth/config
  sometimes lives outside its npm-installed binary. Mounting the operator's entire home directory
  would "just work" for every CLI but would gut the sandbox's actual isolation value (SSH keys, other
  projects, browser data, all exposed). `--mount` is explicit, opt-in, and repeatable instead.
  `--skill-dir` (used internally by `loop.sh --devcontainer`) and the npm-prefix auto-mount for the
  agent binary itself follow the same "narrow and explicit" principle.
  Considered: not the same container use case as `--container`. wgm already had a container flag for
  scenario *validation* — that runs the app under test, not the loop; both are documented side by
  side to prevent confusion (`docs/operator/devcontainers.md`'s "Two different container use cases").
- **Prune's label-scoping caveat.** Every container spawned from the shared image inherits its
  `LABEL wgm.devcontainer=1` (an OCI image label populates its containers' own labels), so `prune`
  will sweep *any* container derived from that image — including ones launched outside
  `devcontainer.sh` entirely. That is intentional (it's still wgm's own image), and is distinct from
  the real safety boundary the test harness checks: prune must never touch a container from an
  *unrelated* image.

## Validation

`bash -n` + `shellcheck` (all scripts, clean) · `bash scripts/check-docs.sh` (58 files, 34 mermaid
diagrams, GREEN) · `bash scripts/check-evals.sh` (GREEN) · `make validate` (lint + docs + install/
loop/swarm/**devcontainer** harnesses, all GREEN) · `( cd .. && skills-ref validate wgm )` → "Valid
skill: wgm" · `actionlint .github/workflows/*.yml` (clean) · `pwsh -File scripts/test-install.ps1`
(6/6 GREEN).

**Demo validation (the real proof, not just unit assertions):**
- `scripts/devcontainer.sh run -- sh -c 'whoami; cat /workspace/proof.txt'` — proved the non-root
  sandboxed user, the bind-mounted file, exit-code propagation, and (after the permission fix) actual
  read/write access to a `mktemp -d`-style restrictive directory.
- `copilot --version` resolved and ran correctly *inside* the sandbox via the auto-mounted npm
  prefix, on a different base distro than the host — proving "bring your own agent CLI" works
  end-to-end, not just in theory.
- `scripts/loop.sh grill --devcontainer -- sh -c '...'` — the full `--devcontainer` re-exec path,
  auto-building the shared base image on first use, mounting the skill at `/opt/wgm-skill`, and
  completing a real (stubbed-agent) loop iteration inside the sandbox, exit 0.

## Follow-ups (recorded, not required here)

- An `evals/evals.json` entry for the Ralph-full-preferred trigger, if the eval fixture ever gets a
  "loop-mode selection" category.
- Per-stream devcontainer sandboxing for `scripts/swarm.sh` (each worktree stream in its own
  sandboxed container).
