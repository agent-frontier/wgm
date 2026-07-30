# Reference

Lookup material: exact flags, defaults, file paths, and exit codes. These pages answer *"what
exactly does this accept?"* — for *"how do I do X?"*, start with the
[operator guide](../operator/README.md).

## Command line

| Page | Covers |
|---|---|
| [loop.sh](cli-loop.md) | The Ralph outer loop: modes, every flag, environment variables, exit codes, stop conditions |
| [swarm.sh](cli-swarm.md) | Parallel worktree streams: flags, partitioning rules, lane safety, telemetry output |
| [Installers](cli-install.md) | `install.sh` and `install.ps1`: flags, targets, environment variables, verification |

## Validation and files

| Page | Covers |
|---|---|
| [Gates](gates.md) | Every check and harness this repository ships, what each proves, and when it runs |
| [Artifacts](artifacts.md) | Every file wgm reads and writes, where it puts them, and what to gitignore |

## Quick answers

| Question | Answer |
|---|---|
| How do I validate a change to this repo? | `make validate` |
| How do I stop a running loop? | Ctrl+C, or `touch .wgm/STOP` |
| Where does telemetry land? | `.wgm/metrics.tsv`, and `.wgm/metrics/` for swarm lanes |
| Why won't `build` start? | It requires an `IMPLEMENTATION_PLAN.md` in the root or `.wgm/` |
| Which agent does the loop call? | `$WGM_AGENT`, `--agent "CMD"`, or argv after `--` |
| How do I skip the companion skills? | `--no-companions` (bash) or `-NoCompanions` (PowerShell) |
| Where do I turn off upstream reporting? | `.github/wgm-hive.yml` — set `consent: false` |

## Deeper protocol references

The `references/` directory holds the terse, load-every-iteration rules the agent itself reads.
They are denser than these pages and written for the agent, not the operator:

[grilling](../../references/grilling.md) ·
[ralph-loop](../../references/ralph-loop.md) ·
[telemetry](../../references/telemetry.md) ·
[scenarios](../../references/scenarios.md) ·
[scoring](../../references/scoring.md) ·
[subagents](../../references/subagents.md) ·
[artifacts](../../references/artifacts.md) ·
[stall-recovery](../../references/stall-recovery.md) ·
[hard-to-test-domains](../../references/hard-to-test-domains.md) ·
[validation-env](../../references/validation-env.md) ·
[self-improvement](../../references/self-improvement.md) ·
[heuristics](../../references/heuristics.md)
