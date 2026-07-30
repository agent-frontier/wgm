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

Run it **from your project's root**, using the path to your installed copy:

```bash
~/.agents/skills/wgm/scripts/loop.sh build --agent 'copilot -p'
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
| `$WGM_AGENT` | `export WGM_AGENT='copilot -p'` | Shell-evaluated. Set only to a command you trust. |
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
| `--source DIR` | none | Exemplar codebase for `extract` (gene transfusion). |

### Scenario validation

| Flag | Default | Description |
|---|---|---|
| `--threshold N` | `95` | Satisfaction target (0–100) the build converges to. |
| `--scenarios DIR` | `scenarios/` or `.wgm/scenarios/` | Where holdout scenarios live. |
| `--stratified` | off | Validate scenarios by ascending tier (1 → 2 → 3), so easy passes cannot mask a broken tier 3. |
| `--container ENGINE` | `podman` | `podman` or `docker`, for scenarios needing a live service. |

### Stopping the loop

| Flag | Default | Description |
|---|---|---|
| `--max-runtime-seconds N` | `0` (unlimited) | Hard wall-clock cap for the whole loop. |
| `--idle-timeout N` | `0` (disabled) | Stop if the plan makes no progress for N seconds. |
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
`plan_changed`, `result`, `cost`, `parent`. `$WGM_PARENT_TASK` populates `parent`, which
`swarm.sh` sets per lane. See [Telemetry](../../references/telemetry.md) for what the numbers mean
and, importantly, what they do not.

### Project gates

| Flag | Default | Description |
|---|---|---|
| `--gates FILE` | auto-detect `wgm.yml` or `.wgm/gates.yml` | A YAML file with a `gates:` list of commands, injected as mandatory checks into every build iteration. |

### Execution

| Flag | Default | Description |
|---|---|---|
| `--commit` | off | `git add -A && git commit` after each build iteration. |
| `--checkpoint-interval N` | `0` (off) | Commit every N build iterations, independent of `--commit`. |
| `--devcontainer` | off | Run the entire invocation inside wgm's shared local sandbox. A no-op with `--dry-run`. |
| `--notify "CMD"` | none | Run CMD on lifecycle events with `$WGM_EVENT` (`start`, `complete`, `error`, `retry`) and `$WGM_ITER` set. Best-effort. |
| `--dry-run` | off | Print the prompt and the command that would run; invoke nothing. |
| `-h`, `--help` | — | Show usage. |

## Environment variables

| Variable | Used by | Description |
|---|---|---|
| `WGM_AGENT` | `loop.sh`, `swarm.sh` | Default agent command (shell-evaluated). |
| `WGM_FRUGAL_AGENT` | `loop.sh` | Default frugal agent command. |
| `WGM_PROMPT_STDIN` | `loop.sh` | Set to `1` if the agent reads its prompt from stdin. |
| `WGM_PARENT_TASK` | `loop.sh` | Populates the ledger's `parent` column. Set per lane by `swarm.sh`. |
| `WGM_EVENT`, `WGM_ITER` | `--notify` CMD | Lifecycle event name and current iteration number. |
| `WGM_IN_DEVCONTAINER` | `devcontainer.sh` | Set inside the sandbox; prevents recursive re-exec. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | The loop finished: iterations exhausted, a stop condition fired, or the stop sentinel appeared. |
| `1` | A single-phase mode failed, the circuit breaker tripped, or `build`/`review`/`preflight` ran with no `IMPLEMENTATION_PLAN.md`. |
| `2` | Misconfiguration: unknown flag, non-numeric knob value, missing `--gates` file, or no agent configured. |

## Stopping a run

To stop a running loop, use whichever is convenient:

- Press **Ctrl+C**.
- Create the stop sentinel: `touch .wgm/STOP` (or `./STOP` when there is no `.wgm/` directory).
  The loop ends after the current iteration finishes.

**Note:** In `build` mode the agent is instructed to create that sentinel itself once no must-have
task remains, so a healthy loop self-terminates without your intervention.

## Safety

- Non-destructive by default: no commits and no pushes unless you pass `--commit`.
- The agent still edits files during a non-dry run. Run this only in a workspace you are willing to
  let an agent operate in autonomously.
- `build`, `review`, and `preflight` refuse to start without an `IMPLEMENTATION_PLAN.md` in the
  project root or `.wgm/`.

## What to do next

- [Run the loop](../operator/running-the-loop.md) — the task-shaped operator guide.
- [swarm.sh reference](cli-swarm.md) — fan the loop out across parallel worktrees.
- [Telemetry](../../references/telemetry.md) — reading the ledger honestly.
