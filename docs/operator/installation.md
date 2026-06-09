# Installation (operator)

wgm is an [Agent Skill](https://agentskills.io): a folder containing `SKILL.md` that a
skills-compatible agent loads on demand. "Installing" it just means placing the `wgm/` folder into a
skills directory your client scans. The bundled installers do this for you — **user-level (global)
by default**, on Linux, macOS, Windows, and WSL.

## Pick a scope

```mermaid
flowchart TD
  Q{Who should see wgm?} -->|Just me, everywhere| U[User / global install]
  Q -->|This repo / my team| P[Project install]
  U --> UA["~/.agents/skills/wgm  (+ ~/.claude, ~/.copilot if present)"]
  P --> PA[".agents/skills/wgm in the project  (+ ./.claude)"]
```

- **User (default):** available in every project you open. Best for personal use.
- **Project:** committed with a repo so collaborators share it. Use `--project`.

## One-line install

```bash
# Linux / macOS / WSL
curl -fsSL https://raw.githubusercontent.com/agent-frontier/wgm/main/scripts/install.sh | bash
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/agent-frontier/wgm/main/scripts/install.ps1 | iex
```

## From a clone (full control)

```bash
git clone https://github.com/agent-frontier/wgm && cd wgm
./scripts/install.sh                    # user scope, auto-detect clients (default)
./scripts/install.sh --project          # into ./.agents/skills (+ ./.claude)
./scripts/install.sh --client all       # agents + claude + copilot
./scripts/install.sh --method symlink    # symlink instead of copy (dev-friendly)
./scripts/install.sh --dry-run          # preview only
./scripts/install.sh --uninstall        # remove again
```

On native Windows use the PowerShell script with the same options:

```powershell
pwsh scripts/install.ps1 -Client all
powershell -File scripts\install.ps1 -Project
pwsh scripts/install.ps1 -Uninstall
```

## Flags

| Flag (sh / ps1) | Meaning |
|---|---|
| `--user` / `-User` | Install into your home dir (default). |
| `--project` / `-Project` | Install into the current working directory. |
| `--client NAME` / `-Client NAME` | `agents`, `claude`, `copilot`, `all`, or `auto` (default). |
| `--dir PATH` / `-Dir PATH` | Install into `PATH/wgm` explicitly. |
| `--method copy\|symlink` / `-Method` | Copy (default) or symlink/junction. |
| `--dry-run` / `-DryRun` | Print actions; change nothing. |
| `--uninstall` / `-Uninstall` | Remove the installed skill. |
| `--force` / `-Force` | Overwrite an existing install. |

`auto` always includes the cross-client `.agents/skills` location and adds `~/.claude` or
`~/.copilot` when those client homes already exist.

## Where it lands

| Scope | Cross-client (default) | Claude | Copilot CLI |
|---|---|---|---|
| **User** (`~` / `%USERPROFILE%`) | `~/.agents/skills/wgm` | `~/.claude/skills/wgm` | `~/.copilot/skills/wgm` |
| **Project** (`./`) | `./.agents/skills/wgm` | `./.claude/skills/wgm` | via `.agents/skills` |

The `.agents/skills/` path is the cross-client convention: skills installed there are visible to any
compliant client, so it is the safest default.

## A note on WSL

WSL and Windows have **separate home directories and separate client installs**. Run the bash
installer inside WSL and the PowerShell installer on Windows if you use agents in both. The bash
installer prints a reminder when it detects WSL.

## Verify & uninstall

After installing, open your agent and confirm wgm is listed (e.g. `/skills` in VS Code or Copilot
CLI), then invoke `/wgm`. To remove it, re-run the installer with `--uninstall` / `-Uninstall` and
the same scope/client flags you installed with.

See also: [running-the-loop.md](running-the-loop.md) · [troubleshooting.md](troubleshooting.md).
