# AGENTS.md

## Build & run

This repository is a portable Agent Skill; it has no application server to start. Work from the repository root.

```bash
make validate
```

## Validate (backpressure)

```bash
make validate
```

For focused work, run the named harness directly, then rerun `make validate` before handoff. The devcontainer harness prefers Podman and uses a disposable test tag; it may visibly skip real-engine cases only when neither Podman nor Docker is installed.

## Operational notes

- `CONTRIBUTING.md` is the canonical local-development SOP.
- `scripts/wgm_plugin_registry.py` is a proposed/unwired host-adapter helper. The portable `scripts/loop.sh` does not invoke plugin hooks.
- Use temporary `HOME` fixtures for plugin-registry tests; never depend on or mutate the operator's real `~/.copilot/skills`.
- WSL boundary harnesses may report simulated/unverified results. Do not call them Windows-origin field evidence unless a real Windows process ran the probe.

## Codebase patterns

- Shell behavior checks live in `scripts/test-*.sh`, use `ok:`/`FAIL:` output, and exit nonzero on any failed assertion.
- Test comments explain the behavior each assertion protects.
- Prefer existing Podman-first/Docker-fallback helpers and standard-library Python; avoid new runtime dependencies.
- Documentation changes must keep `docs/README.md`, `CONTRIBUTING.md`, and `docs/reference/gates.md` aligned.
