# Troubleshooting (operator)

Common issues when installing or running wgm, and how to fix them.

## Install

**The agent doesn't list wgm after install.**
- Confirm the folder landed where your client scans: check the table in
  [installation.md](installation.md). The directory must be named exactly `wgm` (it has to match the
  `name:` in `SKILL.md`).
- Restart the agent session so it re-scans skills.
- For project scope, make sure you started the agent from that project's root.

**The `curl … | bash` one-liner does nothing, or prints a 404.**
- The repo must be **public** for the unauthenticated one-liner to fetch. Until then, install from a
  clone instead (`git clone … && ./scripts/install.sh`).
- `curl -f` exits silently on a 404, so a piped install can look like a no-op. Re-run the raw URL
  without `-f` to see the HTTP status.

**"Failed to fetch wgm (…)" from the installer.**
- When piped (no local checkout) the installers self-fetch the repo. This message means both the
  tarball download and the `git clone` fallback failed — check connectivity, the `--ref` you passed,
  and `WGM_REPO`/`WGM_REF`. Or install from a clone. See [installation.md](installation.md).

**WSL vs Windows confusion.**
- They have separate homes. Install in each environment where you run an agent. The bash installer
  prints a note when it detects WSL.

**PowerShell symlink/junction fails.**
- Creating a junction can need privileges. `install.ps1` falls back to a copy automatically and warns
  — or pass `-Method copy` to skip the attempt.

## Running the loop

**"No agent configured."**
- Set `WGM_AGENT`, pass `--agent "CMD"`, or append `-- copilot -p` (your agent argv). See
  [running-the-loop.md](running-the-loop.md).

**"Refusing to run 'build': no IMPLEMENTATION_PLAN.md found."**
- Run a `plan` pass first (`./scripts/loop.sh plan --request "…"`), or `/wgm plan`. `build`,
  `review`, and `preflight` need a plan on disk.

**The loop never stops.**
- `build` defaults to unlimited iterations. Pass a max (`build 20`), create a `STOP` / `.wgm/STOP`
  sentinel, or `Ctrl+C`. The agent should drop the sentinel itself when no must-have task remains.

**Model escalation isn't kicking in.**
- It only engages when **both** `--frugal-agent` and a main `--agent` are set. Check
  `--escalate-after` (default 2). See [stall-recovery.md](../agent/stall-recovery.md).

## Validation

**Satisfaction score never reaches the threshold.**
- Inspect the weakest scenario recorded in `IMPLEMENTATION_PLAN.md`. Often the scenario expectation
  is ambiguous or the demo path isn't actually wired up. See
  [scenarios-and-scoring.md](../agent/scenarios-and-scoring.md).
- Consider lowering `--threshold` for a rough prototype, or splitting the task smaller.

**Container scenarios fail to start.**
- Confirm the engine is installed (`podman` or `docker`) or pass `--container` explicitly. Check the
  readiness/healthcheck wait and that the published port is free. See [containers.md](containers.md).

**The build loop edits the wrong files / drifts.**
- Add a "sign": tighten the spec, add a note to `AGENTS.md`, or split the task. wgm steers on
  patterns + backpressure — when it drifts, add a sign rather than hand-holding each step.

## Artifacts

**wgm wrote files under `.wgm/` instead of the repo root.**
- That's the safety rule: when the repo already has `AGENTS.md`, `IMPLEMENTATION_PLAN.md`, or
  `specs/`, wgm writes its own copies under `.wgm/` so it never clobbers yours. See
  [`references/artifacts.md`](../../references/artifacts.md).

Still stuck? Re-read the protocol in [`SKILL.md`](../../SKILL.md) — every gate prints a `Gate check:`
block telling you exactly which item failed.
