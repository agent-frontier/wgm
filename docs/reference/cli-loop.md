# wgm CLI reference: loop.sh

`scripts/loop.sh` runs the **Ralph outer loop**: it invokes your coding agent once per iteration,
each time with a fresh context and a short prompt telling it to follow the wgm protocol in a given
mode and advance exactly one task. `IMPLEMENTATION_PLAN.md` is the shared state between otherwise
disposable iterations.

**Note:** The loop is optional. wgm is a portable `SKILL.md` and works in-session without any
script. Reach for `loop.sh` when you want genuinely fresh context per iteration — see
[Choose a loop mode](../operator/running-the-loop.md).

## Syntax

```
scripts/loop.sh [MODE] [MAX_ITERATIONS|only] [FLAGS] [-- AGENT_ARGV...]
```

By default the loop is **sandboxed**: agent and gate commands run in a throwaway Podman/Docker
container while the loop itself runs on the host; see [Sandbox](#sandbox-default). Run it **from your
project's root**, using the path to your installed copy:

```bash
~/.agents/skills/wgm/scripts/loop.sh build --agent 'copilot -p --allow-all-tools'
```

## Positional arguments

| Argument | Values | Default | Description |
|---|---|---|---|
| `MODE` | `grill`, `analyze`, `plan`, `preflight`, `build`, `loop`, `review`, `extract` | `build` | Which phase to run. `loop` is an alias of `build`. |
| `MAX_ITERATIONS` | Integer; `0` = unlimited | `0` for `build`, `1` for single-phase modes | Iteration cap. |
| `only` | Literal keyword | — | Run a single iteration or phase, then stop. Equivalent to `MAX_ITERATIONS` of `1`. |

## Choosing the agent

The script does not know your agent's CLI. Supply it one of three ways, listed in order of
increasing safety:

| Method | Example | Notes |
|---|---|---|
| `$WGM_AGENT` | `export WGM_AGENT='copilot -p --allow-all-tools'` | Shell-evaluated. Set only to a command you trust; the permission flag is required for unattended tool use. |
| `--agent "CMD"` | `--agent 'claude --dangerously-skip-permissions -p'` | Shell-evaluated. Overrides `$WGM_AGENT`. |
| `--` passthrough | `-- claude -p` | **Safest.** Everything after `--` is argv, invoked without `eval`. |

The prompt is appended as the final argument. If your agent reads its prompt from stdin instead,
set `WGM_PROMPT_STDIN=1`.

**Caution:** `$WGM_AGENT` and `--agent` are evaluated by the shell. Never point them at a
command string assembled from untrusted input.

## Flags

### Agent and scope

| Flag | Default | Description |
|---|---|---|
| `--agent "CMD"` | `$WGM_AGENT` | Agent command, shell-evaluated. |
| `--frugal-agent "CMD"` | `$WGM_FRUGAL_AGENT` | Cheaper agent for routine iterations; escalates to `--agent` on a stall. Requires `--agent` for escalation to engage. |
| `--request "TXT"` | none | Request or scope injected into the prompt. Most useful with `plan` and `build`. |
| `--plan FILE` | auto | Explicit plan path. Without it, `.wgm/IMPLEMENTATION_PLAN.md` wins when both root and `.wgm/` plans exist. |
| `--source DIR` | none | Exemplar codebase for `extract` (gene transfusion). |

### Scenario validation

| Flag | Default | Description |
|---|---|---|
| `--threshold N` | `95` | Satisfaction target (0–100) the build converges to. |
| `--scenarios DIR` | `scenarios/` or `.wgm/scenarios/` | Where holdout scenarios live. |
| `--stratified` | off | Validate scenarios by ascending tier (1 → 2 → 3), so easy passes cannot mask a broken tier 3. |
| `--container ENGINE` | `auto` | Selects available `podman`, then `docker`; explicit unavailable engines fail clearly. |

### Stopping the loop

| Flag | Default | Description |
|---|---|---|
| `--max-runtime-seconds N` | `0` (unlimited) | Elapsed-runtime limit checked between iterations; once reached, no next iteration starts. Active work can overrun it. |
| `--idle-timeout N` | `0` (disabled) | Stop if the plan makes no progress for N seconds. |
| `--agent-timeout-seconds N` | `0` (disabled) | Terminate the active agent process group after N seconds with GNU `timeout`/`gtimeout`; otherwise report the cooperative fallback. |
| `--max-no-progress-iterations N` | `3` | Fail after N successful build iterations leave the plan unchanged; `0` disables this guard. With frugal/main escalation, the default leaves one iteration for escalation before the circuit breaker. |
| `--max-consecutive-failures N` | `3` | Circuit breaker: stop after N iterations that fail every retry. `0` never trips. |
| `--max-cost N` | `0` (unlimited) | Stop once cumulative cost from `--cost-cmd` reaches N. Requires `--cost-cmd`. |

**Tip:** For fail-fast on the first error, combine `--max-retries 0 --max-consecutive-failures 1`.

### Resilience

| Flag | Default | Description |
|---|---|---|
| `--max-retries N` | `2` | Retry a failed agent invocation N times per iteration, with exponential backoff and full jitter. `0` disables retry. |
| `--retry-base-delay N` | `5` | Base seconds for the backoff. `0` waits not at all. |
| `--retry-max-delay N` | `60` | Cap for any single backoff wait, in seconds. |
| `--escalate-after N` | `2` | Consecutive no-progress iterations before escalating to the main agent. |
| `--downgrade-after N` | `5` | Consecutive progressing iterations before dropping back to the frugal agent. |

### Telemetry and cost

| Flag | Default | Description |
|---|---|---|
| `--metrics FILE` | `.wgm/metrics.tsv` | Per-iteration TSV ledger. Pass `--metrics off` to disable. |
| `--cost-cmd "CMD"` | none | Run after each iteration to print a token or cost figure for the `cost` column. Best-effort; its failure never breaks the loop. |

The ledger's columns are `start_timestamp`, `end_timestamp`, `iter`, `mode`, `agent`, `duration_s`,
`plan_changed`, `result` (`ok`, `fail`, or `stall`), `cost`, `parent`, `sandbox` (`container:<ENGINE>`,
`off:<REASON>`, or `inside`). An existing file whose header lacks `sandbox` gets `\tsandbox` appended to the header in place; older
rows stay shorter, so read a missing value as unknown. `$WGM_PARENT_TASK` populates `parent`, which
`swarm.sh` sets per lane. See [Telemetry](../../references/telemetry.md) for what the numbers mean
and, importantly, what they do not.

### Project gates

| Flag | Default | Description |
|---|---|---|
| `--gates FILE` | auto-detect `wgm.yml` or `.wgm/gates.yml` | A YAML file with a `gates:` list of commands executed after each build iteration — inside the sandbox when it is on, on the host with `--no-devcontainer`. |

The gate file accepts a block list (`gates:` followed by `- command`) or a simple inline list
(`gates: [command-a, command-b]`). Use the block form when a command contains a comma or needs
shell quoting; commands are trusted shell text and execute in the target project directory. Each gate is handed to the sandbox separately (never joined with `&&`) and runs as `bash -c "$gate"`; only one quote pair wrapping the whole entry is stripped. Host-side temp files live in a run-private `0700` directory outside every mount (under `$TMPDIR`, or `/tmp` when `$TMPDIR` is inside the project). When a
gate file is configured and the sandbox is on, preflight runs the gates once inside the container
before iteration 1 (the toolchain smoke); a failure is worked through with you interactively (proceed
anyway, recording nothing — every iteration's own gate still runs and fails that iteration) and exits 2 headless.

### Execution

| Flag | Default | Description |
|---|---|---|
| `--commit` | off | Commit after each build iteration. Requires a clean baseline, exclusive worktree ownership, and an iteration path manifest. |
| `--checkpoint-interval N` | `0` (off) | Commit every N build iterations, independent of `--commit`. |
| `--devcontainer` | (sandbox is on by default) | *Force* the sandbox: no working engine → exit 2, a recorded decline never turns it off. Keeps its name but means the agent/gate boundary, not the old whole-loop re-exec. |
| `--no-devcontainer` | off | Explicit opt-out: run agent and gates on the host, labelled `sandbox: OFF — unsandboxed (operator-flag)`. Contradicting `--devcontainer` → exit 2. |
| `--devcontainer-image TAG` | record `image:`, else the shared base image | Image for the sandbox; see [project image](../operator/devcontainers.md#decision-order-first-match-wins). `$WGM_DEVCONTAINER_IMAGE` is the env form. |
| `--devcontainer-mount HOST[:CONTAINER]` | none | Repeatable extra bind mount. **Read-only regular files/dirs only** (`rw`, sockets, devices, FIFOs refused with exit 2); policy-checked like every mount. Never use it for credentials — those are copied per agent. |
| `--notify "CMD"` | none | Run CMD on lifecycle events with `$WGM_EVENT` (`start`, `complete`, `error`, `retry`) and `$WGM_ITER` set. Best-effort. |
| `--dry-run` | off | Print the prompt, the command that would run, and the sandbox decision (or the unresolved prerequisite). **Non-mutating:** no prompt, no record or exclusion write, no smoke, no readiness probe, no container launch, no capability probe. |
| `-h`, `--help` | — | Show usage. |

Commit checkpoints use the same clean-baseline and ownership-manifest rules as `--commit`; a
missing manifest or undeclared path fails closed instead of being swept into the checkpoint.

## Environment variables

| Variable | Used by | Description |
|---|---|---|
| `WGM_AGENT` | `loop.sh`, `swarm.sh` | Default agent command (shell-evaluated). |
| `WGM_FRUGAL_AGENT` | `loop.sh` | Default frugal agent command. |
| `WGM_PROMPT_STDIN` | `loop.sh` | Set to `1` if the agent reads its prompt from stdin. |
| `WGM_PARENT_TASK` | `loop.sh` | Populates the ledger's `parent` column. Set per lane by `swarm.sh`. |
| `WGM_CAPABILITY_PROBE_FILE` | agent during probe | Unique disposable path the agent must create; unset outside the probe. The probe is mandatory for non-dry-run `build` and `plan`. |
| `WGM_CAPABILITY_PROBE_CONTENT` | agent during probe | Exact marker content expected in the probe file. |
| `WGM_OWNERSHIP_MANIFEST` | agent in commit mode | Path where the agent declares intentionally changed repository-relative files, one per line. |
| `WGM_EVENT`, `WGM_ITER` | `--notify` CMD | Lifecycle event name and current iteration number. |
| `WGM_DEVCONTAINER` | `loop.sh`, `swarm.sh` | `0` = opt out (`operator-env`), `1` = force the sandbox. Contradicting a flag → exit 2. |
| `WGM_DEVCONTAINER_IMAGE` | `loop.sh`, `swarm.sh` | Sandbox image tag (below `--devcontainer-image`, above the record). |
| `WGM_SANDBOX_DECISION` | `loop.sh` | Path to a swarm-written decision file (`0600`, outside every mount); used verbatim, no preflight or prompt. Set by `swarm.sh`; not for manual use. |
| `WGM_IN_DEVCONTAINER` | `devcontainer.sh` | Set inside the sandbox; the recursion guard (a run already inside reports `sandbox=inside`). |

In sandbox mode the host environment is cleaned in-process to an allowlist (and the runner re-executes with a plain exec carrying no `NAME=value` arguments): `PATH`, `HOME`,
locale, `TMPDIR`, `XDG_*`, engine selection, every `WGM_*` and each approved credential env name); other
names are dropped and reported as `sandbox: host env: dropped <NAME>`. See [host environment](../operator/devcontainers.md#host-environment).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | The loop finished: iterations exhausted, a stop condition fired, or the stop sentinel appeared. |
| `1` | A capability probe, phase-artifact, project-gate, timeout, no-progress, ownership, single-phase, or circuit-breaker check failed; or `build`/`review`/`preflight` ran with no `IMPLEMENTATION_PLAN.md`. |
| `2` | Misconfiguration or a **sandbox fail-closed** at preflight (no iteration started): unknown flag, non-numeric knob value, malformed/unreadable gate file, unavailable explicit container engine, missing `--gates` file, no agent configured, conflicting sandbox choices, no engine and no recorded decision when headless, unapproved/stale/unreachable credentials, agent CLI not executable inside, refused mount, failed headless smoke. Also returned **during** a run, after an agent iteration, when the loop stops before any further host action: agent-written symlink, or git metadata/configuration changed by the agent. |
| `2` (container unconfirmed) | After a contained command (e.g. an agent timeout followed by a failed engine removal) wgm could not confirm the container is gone: it stops at once — no verify, inspect, continue or retry — and prints `retained container <NAME>`. Recover with `podman rm -f -t 0 <NAME>` / `docker rm -f <NAME>`, confirm with `podman ps -a --filter name=<NAME>`, rerun. |
| `130` / `143` | Interrupted by SIGINT / SIGTERM; the loop removed its live container by name, or printed `retained container <NAME>` if it could not confirm. |

## Sandbox (default)

`loop.sh` runs `scripts/sandbox.sh preflight` once at start. **On** → every agent invocation (the `--`
argv agent, `--agent`/`$WGM_AGENT`, the frugal agent, the capability probe), every gate, `--notify` and
`--cost-cmd` string runs in a container; the loop, guards, git bookkeeping and metrics stay on the host.
**Off** → host, with the startup line `sandbox: OFF — unsandboxed (<REASON>)` in the log and `off:<REASON>`
in the metrics. A preflight exit 2 happens before any iteration. No engine: interactive runs get one
notice with install commands and one question; headless runs exit 2 unless a decline is recorded.
Credentials are per-agent throwaway copies; the approval is stored outside the repository. Guarantee,
residual risk (the sandbox does not protect this repository's history), mounts, record format and
recovery: [Devcontainer sandbox](../operator/devcontainers.md) and
[troubleshooting](../operator/troubleshooting.md#sandbox-default-devcontainer). Field-validated on Linux/Podman;
macOS and WSL rely on the readiness probe to fail closed.

## Stopping a run

To stop a running loop, use whichever is convenient:

- Press **Ctrl+C**.
- Create the stop sentinel: `touch .wgm/STOP` (or `./STOP` when there is no `.wgm/` directory).
  The loop ends after the current iteration finishes.

**Note:** In `build` mode the agent is instructed to create that sentinel itself once no must-have
task remains, so a healthy loop self-terminates without your intervention.

## Safety

- The host commits only with `--commit` or `--checkpoint-interval`; swarm lanes use `--commit`.
  The runner does not push.
- The agent still edits files during a non-dry run. Run this only in a workspace you are willing to
  let an agent operate in autonomously. The default sandbox keeps it away from your home directory,
  credentials and other projects — **not** from this repository's content and history, which it can
  change (lanes commit); review before merging. `--no-devcontainer` removes even that containment.
- With `--commit` or `--checkpoint-interval`, do not edit the worktree while the loop runs. Use another worktree for concurrent
  human edits; undeclared paths make the commit fail closed. Tracked `.wgm` files are project data:
  they must be clean at baseline and explicitly declared to be committed. Only untracked `.wgm`
  runtime scratch is excluded from that check.
- `build`, `review`, and `preflight` refuse to start without an `IMPLEMENTATION_PLAN.md` in the
  project root or `.wgm/`.

## What to do next

- [Run the loop](../operator/running-the-loop.md) — the task-shaped operator guide.
- [swarm.sh reference](cli-swarm.md) — fan the loop out across parallel worktrees.
- [Telemetry](../../references/telemetry.md) — reading the ledger honestly.
