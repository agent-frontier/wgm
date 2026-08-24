# Requirements

What must be present before you install wgm, and what is optional.

## Executive overview

- **For:** anyone about to install wgm, or diagnosing why part of it will not run.
- **The short version:** you need a skills-compatible agent client. Everything else is optional.
- **Watch out:** the *skill* needs almost nothing; the *optional scripts* need bash and git. "Skills-compatible" is not the same as "wgm has been run here" — see the evidence tiers below.
- **Next:** [Get started](README.md) to install and run your first build.

## Required

wgm itself is a portable `SKILL.md` folder. To use it you need exactly one thing:

| Requirement | Why |
|---|---|
| A skills-compatible agent client | To load and follow the skill. Any client that scans a skills directory works. |

Which clients, and how well, is a matter of recorded evidence rather than a blanket claim. wgm keeps
that record in [`compatibility/harnesses.json`](../../compatibility/harnesses.json), checked by
`scripts/check-harnesses.sh` and explained in
[harness portability](../../references/harness-portability.md):

| Status | Means | Clients |
|---|---|---|
| `Verified` | wgm has been run here end to end, with the evidence recorded | Copilot CLI |
| `Expected` | The vendor documents skill discovery and a non-interactive mode; wgm has not been run here | Claude Code, OpenAI Codex CLI, Gemini CLI, Cursor CLI, OpenCode |
| `Degraded` | Runs, but a named capability is missing and wgm falls back | Pi (no subagent primitive), Aider (no skill discovery — pass `--read` the skill path) |
| `Unknown` | No reliable evidence either way | Windsurf |

Skills directories the installers write into:

| Client | Skills directory |
|---|---|
| Copilot CLI | `~/.copilot/skills/` |
| Claude Code | `~/.claude/skills/` |
| VS Code agent mode, and other `.agents` clients | `~/.agents/skills/` |

**Note:** The installers detect which of these exist and install into each. You do not have to
choose. `~/.agents/skills/` is also a documented discovery path for Codex CLI, Gemini CLI, Cursor,
OpenCode, and Pi, so one install usually covers more clients than it targets.

## Required for the optional scripts

The Ralph loop, the swarm, and the local gates are shell scripts. If you want them:

| Requirement | Used by |
|---|---|
| `bash` 4 or later | Every `scripts/*.sh` |
| `git` | `loop.sh --commit`, `swarm.sh`, `check-trailers.sh`, `check-doc-sync.sh` |
| A non-interactive agent CLI | `loop.sh`, `swarm.sh` — see [Choosing the agent](../reference/cli-loop.md#choosing-the-agent) |

Agents known to work non-interactively:

```bash
export WGM_AGENT='copilot -p --allow-all-tools'
export WGM_AGENT='claude --dangerously-skip-permissions -p'
export WGM_AGENT='codex exec'
```

The first is `Verified`; the rest are the vendors' documented non-interactive contracts, which wgm
has not executed. Other harnesses publish one too — `gemini -p`, `agent -p` (Cursor),
`opencode run`, `pi -p`, `aider --message` — with the same caveat and their sources recorded in
[harness portability](../../references/harness-portability.md). Check the flags against your
installed version before letting a loop run unattended.

## Optional

Nothing here blocks normal use. Each unlocks one capability.

| Software | Unlocks | Without it |
|---|---|---|
| Podman or Docker | Containerized scenario validation (`loop.sh --container`), and the local devcontainer sandbox | Scenarios needing a live service cannot be judged; run the app yourself |
| `jq` | `scripts/check-evals.sh`, `scripts/check-harnesses.sh` | Those two gates exit `2` and report the dependency |
| `shellcheck` | `make lint` | You cannot run the shell lint locally; CI still does |
| `gh`, authenticated | Filing an anonymized lesson upstream (`harvest-hive.sh`) | The courier stays local-only; nothing breaks |
| `pwsh` | Running the PowerShell installer harness locally | CI still runs it |

## Supported platforms

| Platform | Installer | Notes |
|---|---|---|
| Linux | `scripts/install.sh` | — |
| macOS | `scripts/install.sh` | — |
| WSL | `scripts/install.sh` | Also mirrors into your Windows home so native-Windows agents see it. Disable with `--no-windows`. |
| Windows (native) | `scripts/install.ps1` | With a WSL distro present, a user-scope run delegates to the bash installer inside WSL on purpose. Pass `-NoWsl` to force native. |

**Caution:** WSL and Windows have **separate home directories**. A skill installed in one is not
visible to an agent running in the other. This is the single most common install surprise, and it is
why the WSL installer mirrors by default.

## Contributor prerequisites

Only needed if you are changing wgm itself:

| Software | Used for |
|---|---|
| `bash`, `shellcheck` | `make lint` |
| `jq` | `make docs` |
| `actionlint` | Workflow linting (CI also runs it) |
| `pwsh` | The PowerShell installer harness |
| `python3` with `pip` | `skills-ref` skill validation |

Verify your setup with:

```bash
make validate
```

See [Contributing](../../CONTRIBUTING.md) and the [gates reference](../reference/gates.md).

## What to do next

- [Get started](README.md) — install, then run your first build end to end.
- [Installers reference](../reference/cli-install.md) — every installer flag.
- [Harness portability](../../references/harness-portability.md) — what each status above is based on, and what wgm does when a client is missing a capability.
