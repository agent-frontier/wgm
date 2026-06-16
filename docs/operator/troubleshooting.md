# Troubleshooting (operator)

## Executive overview

- **For:** anyone hitting a snag installing or running wgm.
- **How it's organized:** by stage — Install · Running the loop · Validation · Artifacts.
- **First move:** every wgm gate prints a `Gate check:` block naming the failed item — start there.
- **Most common fixes:** skill not listed (wrong dir name, or restart the session); `build` refuses
  to run (no `IMPLEMENTATION_PLAN.md` yet); the loop never stops (pass a max, or drop a `STOP` file).
- **Next:** back to [installation.md](installation.md) or [running-the-loop.md](running-the-loop.md).

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

**The Windows side didn't get wgm after a WSL install.**
- The mirror runs for **user-scope** installs only (not `--project` or `--dir`) and is skipped by
  `--no-windows`. Check the installer's note line: if it says it "could not resolve your Windows
  home", pass `--windows-home PATH` (e.g. `--windows-home /mnt/c/Users/you`).
- The mirror is a real copy under `/mnt/c/Users/you/.agents/skills/wgm`; confirm your Windows agent
  scans `%USERPROFILE%\.agents\skills\wgm`.

**`install.ps1` unexpectedly ran inside WSL.**
- On Windows with a WSL distro present, a user-scope `install.ps1` delegates to the bash installer in
  WSL on purpose (so both homes are covered). Pass `-NoWsl` for a native-Windows install, or
  `-WslDistro NAME` to pick a distro.

**How do I update an existing install?**
- Just re-run the installer (same one-liner). wgm refreshes a directory it recognizes as its own in
  place — no `--force` — and adds the Windows mirror if it was missing.

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
- `build` defaults to unlimited iterations. Pass a max (`build 20`), cap it with
  `--max-runtime-seconds` / `--idle-timeout`, create a `STOP` / `.wgm/STOP` sentinel, or `Ctrl+C`.
  The agent should drop the sentinel itself when no must-have task remains.

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
