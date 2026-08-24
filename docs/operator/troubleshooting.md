# Troubleshooting (operator)

## Executive overview

- **For:** anyone hitting a snag installing or running wgm.
- **First move:** every wgm gate prints a `Gate check:` block naming the failed item. Read that
  before anything else — it usually names the fix.
- **How this page is organized:** by stage — Install · Companions · Loop · Validation · Artifacts ·
  Contributing. Each entry is symptom, cause, resolution.
- **Most common three:** the skill is not listed (wrong directory name, or the session needs a
  restart); `build` refuses to start (no `IMPLEMENTATION_PLAN.md` yet); the loop never stops (pass a
  max, or drop a `STOP` sentinel).
- **Next:** [Installation](installation.md) · [Run the loop](running-the-loop.md) ·
  [Reference](../reference/README.md).

## Before you troubleshoot

Three checks resolve most reports:

1. **Read the gate output.** wgm prints `Gate check:` with a PASS or FAIL per item at every phase
   boundary. The failing item names the problem.
2. **Restart the agent session.** Skills are scanned at session start, so a freshly installed skill
   is invisible to an already-running session.
3. **Confirm the directory name.** The skill folder must be named exactly `wgm`, matching the `name:`
   field in its `SKILL.md` frontmatter. The same rule applies to `teach-me`, `quiz-me`, and `rugged`.

## Install

### The agent does not list wgm

| | |
|---|---|
| **Symptom** | The install reports success, but the client does not offer `/wgm`. |
| **Cause** | The folder is not where the client scans, the directory name does not match the skill name, or the session has not re-scanned. |
| **Resolution** | Confirm the path against the table in [Installation](installation.md). Ensure the directory is named exactly `wgm`. Restart the agent session. For project scope, start the agent from that project's root. |

### The curl one-liner does nothing, or prints 404

| | |
|---|---|
| **Symptom** | The piped installer exits silently or reports a 404. |
| **Cause** | The repository must be public for the unauthenticated one-liner to fetch. `curl -f` also exits silently on a 404, so a failed install can look like a no-op. |
| **Resolution** | Install from a clone instead: `git clone … && ./scripts/install.sh`. To see the real status, re-run the raw URL without `-f`. |

### "Failed to fetch wgm (…)"

| | |
|---|---|
| **Symptom** | The installer reports a fetch failure. |
| **Cause** | When piped with no local checkout, the installers self-fetch. This message means both the tarball download and the `git clone` fallback failed. |
| **Resolution** | Check connectivity, the `--ref` you passed, and `WGM_REPO` / `WGM_REF`. Or install from a clone. See [Installers reference](../reference/cli-install.md). |

### The Windows side did not get wgm after a WSL install

| | |
|---|---|
| **Symptom** | wgm works in WSL but a native-Windows agent cannot see it. |
| **Cause** | The mirror runs for **user-scope** installs only — not `--project` or `--dir` — and is skipped by `--no-windows`. It may also have failed to resolve your Windows home. |
| **Resolution** | Read the installer's note line. If it says it could not resolve your Windows home, pass `--windows-home /mnt/c/Users/you`. Confirm your Windows agent scans `%USERPROFILE%\.agents\skills\wgm`. |

### install.ps1 unexpectedly ran inside WSL

| | |
|---|---|
| **Symptom** | A PowerShell install produced a Linux-side install. |
| **Cause** | On Windows with a WSL distro present, a user-scope `install.ps1` delegates to the bash installer in WSL on purpose, so both homes are covered. |
| **Resolution** | Pass `-NoWsl` for a native-Windows install, or `-WslDistro NAME` to pick a distro. |

### PowerShell symlink or junction fails

| | |
|---|---|
| **Symptom** | A warning about junction creation during install. |
| **Cause** | Creating a junction can require elevated privileges. |
| **Resolution** | None needed — `install.ps1` falls back to a copy automatically and warns. Pass `-Method copy` to skip the attempt entirely. |

### How do I update an existing install?

Re-run the same installer. wgm refreshes a directory it recognizes as its own **in place**, with no
`--force` needed, and adds the Windows mirror if it was missing. From a clone, `make update` pulls
and reinstalls in one step.

## Companion skills

### teach-me, quiz-me, or rugged is missing

| | |
|---|---|
| **Symptom** | `/wgm` works but `/teach-me`, `/quiz-me`, or `/rugged` is not offered. |
| **Cause** | The install used `--no-companions` or `-NoCompanions`, or it ran from a source tree predating that companion, or the client has not re-scanned. |
| **Resolution** | Re-run the installer without the opt-out flag and restart the session. Confirm `SKILLS_DIR/teach-me/SKILL.md`, `SKILLS_DIR/quiz-me/SKILL.md`, and `SKILLS_DIR/rugged/SKILL.md` exist — they must be **siblings** of `wgm`, not nested inside it. |

### The installer says "companion not in this source, skipping"

| | |
|---|---|
| **Symptom** | That line appears during install. |
| **Cause** | The source tree or tarball has no `companions/` directory — an older release. |
| **Resolution** | Install from a newer ref: `--ref main`, or `--ref latest` for the newest published release. |

## Role agents (the swarm)

### The wgm roles do not appear in my host's agent list

| | |
|---|---|
| **Symptom** | `/wgm` works, but the host offers no `wgm-implementer`, `wgm-spec-reviewer`, or docs-audit personas. |
| **Cause** | Role subagents load from the host's own agent directory, never from inside the skill folder. Either no host client was selected, `--no-agents` / `-NoAgents` was passed, the host has no subagent primitive at all, or the session has not re-scanned. |
| **Resolution** | Re-run with a host selected — `--client copilot`, `--client claude`, or `--client all` — then restart the session. Confirm the files: `ls ~/.copilot/agents/wgm-*.agent.md` or `ls ~/.claude/agents/wgm-*.md` for a user install; `.github/agents/` or `.claude/agents/` for a project install. If your host has no subagent mechanism, that is expected: see the next entry. |

### My host has no agent directory at all

| | |
|---|---|
| **Symptom** | The installer prints that the `.agents` client gets no role adapters, or the host is Pi and nothing was written. |
| **Cause** | Not a failure. The Agent Skills standard defines skills, not subagents, and Pi ships without a subagent primitive by design, so wgm refuses to invent a directory no host reads. |
| **Resolution** | Use the named fallback: run the docs-audit swarm with `bash scripts/audit.sh`, and run the two review passes inline and sequentially in one context, recording that independence was weaker. The deterministic gate is unchanged. Which host supports what is recorded in `compatibility/harnesses.json`. |

### The installer says "exists and is not wgm's"

| | |
|---|---|
| **Symptom** | One or more role files were skipped during install. |
| **Cause** | A file of that name already exists in the agent directory and does not end with wgm's `wgm-role-agent-adapter` marker for *this* host and file — usually one of your own agents that shares a wgm role name, a wgm file whose marker you deleted or pushed out of last place by appending text, or a marker copied from another host or role. wgm never overwrites a file it cannot prove it wrote. |
| **Resolution** | Rename your file, or pass `--force` / `-Force` to replace it deliberately. |

### Uninstall left wgm role files behind

| | |
|---|---|
| **Symptom** | After `--uninstall`, `wgm-*.agent.md` or `wgm-*.md` files remain in an agent directory, and the installer said "no wgm adapter receipt entries or marked adapter files". |
| **Cause** | Those files do not end with this host's `wgm-role-agent-adapter` marker, so wgm has no evidence it wrote them — they were placed there by hand, copied from elsewhere (including from the other host's directory), had the marker edited out, or gained text below it. Removal is by marker, not by name. |
| **Resolution** | Remove them by hand, or re-run the installer once with `--force` (which rewrites and stamps them) and then uninstall. |

## Running the loop

### "No agent configured."

| | |
|---|---|
| **Symptom** | `loop.sh` or `swarm.sh` exits `2` immediately. |
| **Cause** | No agent command was supplied. |
| **Resolution** | Set `WGM_AGENT`, pass `--agent "CMD"`, or append `-- copilot -p --allow-all-tools`. See [Choosing the agent](../reference/cli-loop.md#choosing-the-agent). |

### "Refusing to run 'build': no IMPLEMENTATION_PLAN.md found."

| | |
|---|---|
| **Symptom** | `build`, `review`, or `preflight` exits `1` before doing anything. |
| **Cause** | Those modes need a plan on disk; they are not allowed to invent one. |
| **Resolution** | Run a plan pass first: `./scripts/loop.sh plan --request "…"`, or `/wgm plan`. |

### The loop never stops

| | |
|---|---|
| **Symptom** | `build` keeps iterating indefinitely. |
| **Cause** | `build` defaults to unlimited iterations. |
| **Resolution** | Pass a max (`build 20`), cap it with `--max-runtime-seconds` or `--idle-timeout`, create a `.wgm/STOP` sentinel, or press Ctrl+C. In a healthy run the agent drops the sentinel itself when no must-have task remains. |

### Model escalation is not kicking in

| | |
|---|---|
| **Symptom** | A stall never escalates to the stronger model. |
| **Cause** | Escalation engages only when **both** `--frugal-agent` and a main `--agent` are set. |
| **Resolution** | Set both, and check `--escalate-after` (default `2`). See [Stall recovery](../agent/stall-recovery.md). |

### "Capability probe failed"

| | |
|---|---|
| **Symptom** | The loop exits before iteration 1 with a message that the agent did not create the disposable marker. |
| **Cause** | The headless agent can read the workspace but cannot write to it, or the invocation used a constrained/no-tools mode. |
| **Resolution** | Grant the invocation write access or use a full-shell agent, then rerun. `--dry-run` does not test this; a real `build` or `plan` always probes before spending the first iteration. |

### "No progress: plan unchanged"

| | |
|---|---|
| **Symptom** | A build exits non-zero after successful agent invocations that leave `IMPLEMENTATION_PLAN.md` unchanged. |
| **Cause** | Exit status alone is not evidence of useful work; the agent may have produced prose without an artifact or stopped without recording progress. |
| **Resolution** | Inspect the agent log and plan, fix the task or permission problem, then rerun. Increase `--max-no-progress-iterations` only when a plan-preserving iteration is intentional and documented. |

### "Agent timed out"

| | |
|---|---|
| **Symptom** | The loop reports `Agent timed out after Ns` and records a failed iteration. |
| **Cause** | `--agent-timeout-seconds N` reached its limit. On hosts without GNU `timeout` or `gtimeout`, the loop states that it is using the cooperative fallback instead of pretending to terminate the process. |
| **Resolution** | Inspect the agent output, lower the task scope, or increase the explicit timeout. Use a host with GNU `timeout`/`gtimeout` when hard process-group termination is required. |

### A `plan` or `extract` phase exits without its artifact

| | |
|---|---|
| **Symptom** | A single phase exits non-zero with `Phase artifact missing`. |
| **Cause** | The agent process returned zero without creating the plan or genes artifact promised by the phase. |
| **Resolution** | Inspect the agent's write/tool permissions and rerun with a full-shell invocation. Do not treat a prose handoff as a substitute for the named file. |

### "`--commit` requires a clean worktree" or "undeclared paths"

| | |
|---|---|
| **Symptom** | A commit-mode loop refuses to start or refuses to stage a path. |
| **Cause** | `--commit` takes exclusive ownership and will not sweep pre-existing or undeclared edits into an iteration commit. |
| **Resolution** | Move human edits to another worktree or commit them before starting. The agent must declare each intentional repository-relative file in the iteration ownership manifest; never bypass the refusal with `git add -A`. |

### The build loop edits the wrong files, or drifts

| | |
|---|---|
| **Symptom** | Changes land outside the task's stated scope. |
| **Cause** | The task's spec or plan entry is too loose to steer on. |
| **Resolution** | Add a **sign** rather than hand-holding each step: tighten the spec, add a note to `AGENTS.md`, or split the task smaller. wgm steers on patterns plus backpressure. |

### A swarm lane failed with "lane guard: expected worktree …"

| | |
|---|---|
| **Symptom** | A lane exits immediately with a guard message. |
| **Cause** | The lane was not in its assigned worktree and branch. The guard refuses to let it mutate the wrong tree. |
| **Resolution** | This is working as intended. Check for a leftover worktree or branch from a prior run — `make clean-worktrees` clears both. |

### A swarm lane says `ok` but has zero commits

| | |
|---|---|
| **Symptom** | The swarm summary marks a lane as failed even though the lane process exited zero. |
| **Cause** | `swarm.sh` verifies the artifact after waiting; a task lane with no reachable commit is a silent no-op, not a success. |
| **Resolution** | Read `.wgm/swarm-logs/*.log`, confirm the agent invocation has tool/write permission, and rerun the lane. Do not merge or report a zero-commit lane as completed. |

## Validation

### The satisfaction score never reaches the threshold

| | |
|---|---|
| **Symptom** | The loop keeps iterating without converging. |
| **Cause** | Usually an ambiguous scenario expectation, or a demo path that is not actually wired up. |
| **Resolution** | Inspect the weakest scenario recorded in `IMPLEMENTATION_PLAN.md`. Sharpen the expectation, or split the task. For a rough prototype, lower `--threshold`. See [Scenarios and scoring](../agent/scenarios-and-scoring.md). |

### Container scenarios fail to start

| | |
|---|---|
| **Symptom** | Scenario validation cannot reach the service. |
| **Cause** | No container engine, or a port or readiness problem. |
| **Resolution** | Confirm `podman` or `docker` is installed, or pass `--container` explicitly. Check the readiness wait and that the published port is free. See [Containers](containers.md). |

### A service running in WSL is unreachable from Windows

| | |
|---|---|
| **Symptom** | The service answers `curl` inside WSL, but a Windows browser, editor, or CLI cannot connect (and a WebSocket never opens). |
| **Cause** | It is published on **WSL loopback**. The guest's `127.0.0.1` is not the Windows host's, so a loopback-only bind is invisible across the interop boundary. A Linux-side probe cannot see this at all — it never crosses the boundary. |
| **Resolution** | Publish on **all interfaces** (`0.0.0.0` / `-p`) and connect from Windows to the distro's **WSL IPv4** (`ip -4 -o addr show scope global`). Keep `localhost` for same-side probes only. Confirm it from Windows, not from WSL: on a Windows+WSL host run `bash scripts/test-wsl-windows-boundary.sh`, which contrasts both binds with a real Windows-origin probe. On any other host it exits 3 with the reason. See [Containers](containers.md#reaching-a-service-across-an-os-boundary) and `[learn]` issue [agent-frontier/wgm#101](https://github.com/agent-frontier/wgm/issues/101). |

### A test passes alone but fails in the suite

| | |
|---|---|
| **Symptom** | An isolated re-run is green; the full gate is red. |
| **Cause** | The difference between the two runs *is* the bug — commonly a teardown race where buffered output is discarded before a consumer reads it. |
| **Resolution** | **Do not treat the isolated pass as the answer.** Inspect lifecycle ordering, synchronize producer teardown to consumer acknowledgement, stress the exact test repeatedly, then rerun the complete gate. Only a green full suite clears it. |

### A gate reports missing artifacts that clearly exist

| | |
|---|---|
| **Symptom** | An isolated staged build reports a missing artifact. |
| **Cause** | A globally shared build-target override was inherited, so the build emitted outside the stage-local path the verifier checks. This is a harness misconfiguration, not a product defect. |
| **Resolution** | Clear or scope ambient target overrides before the build, or set an explicit stage-local target directory. Record the clean rerun **separately** from product failures. |

## Artifacts

### wgm wrote files under .wgm/ instead of the repository root

| | |
|---|---|
| **Symptom** | Artifacts appear in `.wgm/` rather than where you expected. |
| **Cause** | The safety rule: when the root already has `AGENTS.md`, `IMPLEMENTATION_PLAN.md`, or `specs/`, wgm writes its own copies under `.wgm/` so it never clobbers yours. |
| **Resolution** | Working as intended. See [Artifacts](../reference/artifacts.md). |

### wgm asked about reporting lessons upstream

| | |
|---|---|
| **Symptom** | A consent question appears before anything else on a new project. |
| **Cause** | `.github/wgm-hive.yml` does not exist yet. Its absence is what defines "a new project" for consent. |
| **Resolution** | Answer once. The file is written either way and never asked about again. `consent: false` keeps every lesson local. See [the consent file](../reference/artifacts.md). |

## Contributing

### make validate fails on a fresh clone

| | |
|---|---|
| **Symptom** | `make validate` is red before you changed anything. |
| **Cause** | Usually a missing development dependency. |
| **Resolution** | Check the contributor prerequisites in [Requirements](../get-started/requirements.md). `shellcheck` is needed for `lint`, `jq` for `docs`. |

### check-evals.sh exits 2

| | |
|---|---|
| **Symptom** | The evals gate exits `2` rather than `0` or `1`. |
| **Cause** | `jq` is not on `PATH`. Exit `2` means misconfigured, distinct from `1` for a real failure. |
| **Resolution** | Install `jq`. |

### The docs check reports a broken link that looks fine

| | |
|---|---|
| **Symptom** | `check-docs.sh` flags a link you can follow in your editor. |
| **Cause** | Links are resolved **relative to the file containing them**. A path that works from the repository root often does not work from a nested page. |
| **Resolution** | Count the `../` hops from the linking file. From `docs/reference/`, the repository root is two levels up. |

## Still stuck?

- Re-read the protocol in [`SKILL.md`](../../SKILL.md). Every gate prints a `Gate check:` block
  naming exactly which item failed.
- Look up the exact flag in the [reference](../reference/README.md).
- Open an issue. If wgm behaved *plausibly but wrongly*, use the heuristic report template — that
  kind of report is how its heuristics improve.
