---
section: Local sandboxing (devcontainers)
order: 12
---
- **Heuristic:** when a sandboxed container bind-mounts a host directory, run it as the calling
  host user's UID:GID, and add Podman's `--userns=keep-id` specifically for Podman (Docker needs no
  such flag). **Why:** the image's own baked UID (even a numerically identical `1000`) is not the
  same UID as the host caller once rootless Podman's default user namespace remaps it — a
  bind-mounted directory that isn't world-readable (a `mktemp -d`-style `0700` dir is the common
  case) is silently unreadable/unwritable inside the sandbox even though the mount itself
  "succeeds," and this is easy to miss if the smoke test happens to use a world-readable directory.
  **Provenance:** wgm dogfood — discovered live while building and testing this session's
  `--devcontainer` sandbox (`scripts/test-devcontainer.sh`'s real, non-dry-run cases caught it: a
  bind-mounted file was readable in an ad hoc `/tmp` test dir but not through the harness's
  `mktemp -d` temp dir, isolating the permission mismatch). **Landed in:** `scripts/devcontainer.sh`
  (`cmd_run`'s `--user`/`--userns=keep-id`) · `references/devcontainers.md`.
