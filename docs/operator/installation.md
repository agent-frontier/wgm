# Installation (operator)

## Executive overview

- **For:** anyone setting up wgm for the first time on Linux, macOS, Windows, or WSL.
- **You'll get:** wgm placed where your agent scans for skills — user-level (global) by default.
- **Fastest path:** the one-line installer (`curl … | bash`, or `irm … | iex` on Windows).
- **Mental model:** a skill is just a `wgm/` folder containing `SKILL.md`; "installing" only copies
  that folder into a skills directory your client reads.
- **Watch out:** WSL and Windows have separate homes (install in each); the piped one-liner needs the
  repo to be public.
- **Next:** [running-the-loop.md](running-the-loop.md) to drive it ·
  [troubleshooting.md](troubleshooting.md) if it doesn't appear.

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
  For Copilot, the project install still lands in the shared `.agents/skills` tree; there is no
  separate `./.copilot` project mirror.

## One-line install

```bash
# Linux / macOS / WSL
curl -fsSL https://raw.githubusercontent.com/agent-frontier/wgm/main/scripts/install.sh | bash
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/agent-frontier/wgm/main/scripts/install.ps1 | iex
```

The one-liner needs the repo to be **public** (it's an unauthenticated fetch). The piped script has
no local checkout, so it **self-fetches**: it downloads the repo into a temp dir, installs from
there, then cleans up. No `git` needed — it uses the same `curl`/tarball the one-liner already
implies (Windows uses `Invoke-WebRequest` + `Expand-Archive`), falling back to a shallow `git clone`.

**WSL is bridged both ways.** Run the one-liner inside WSL and it installs into your Linux home **and**
mirrors into your Windows home so native-Windows agents see wgm too. Run the PowerShell one-liner on
Windows and, if a WSL distro is present, it hands the install to the bash installer inside WSL (the
same bridge). See [A note on WSL](#a-note-on-wsl).

```mermaid
flowchart TD
  S[install.sh / install.ps1 starts] --> Q{SKILL.md next to the script?}
  Q -- yes --> C[Clone mode: install from disk]
  Q -- no --> F["Bootstrap: download repo archive (curl+tar / IWR+Expand-Archive)"]
  F -- ok --> T[extract to temp dir]
  F -- fails --> G["git clone --depth 1 (fallback)"]
  G --> T
  T --> I[install into your skills dirs]
  I --> X[remove temp dir on exit]
```

Pin a branch, tag, or commit with `--ref` / `-Ref` (or `WGM_REF`); point at a fork with `WGM_REPO`:

```bash
curl -fsSL https://raw.githubusercontent.com/agent-frontier/wgm/main/scripts/install.sh \
  | WGM_REF=v1.0 bash
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

After installing, restart or reload your agent client before checking `/skills`; many clients only
rescan skills on startup or workspace reload.

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
| `--ref REF` / `-Ref REF` | Git ref (branch/tag/sha) to self-fetch when piped (default `main`). |
| `--no-windows` / — | (WSL) skip mirroring into your Windows home. |
| `--windows-home PATH` / — | (WSL) mirror into the Windows home `PATH` (default: auto-detect via `/mnt`). |
| — / `-NoWsl` | (Windows) do not delegate to WSL; install natively. |
| — / `-WslDistro NAME` | (Windows) delegate to a specific WSL distro (default: your default distro). |

`auto` always includes the cross-client `.agents/skills` location and adds `~/.claude` or
`~/.copilot` when those client homes already exist.

**Self-fetch overrides** (for piped installs): `WGM_REF` (branch/tag/sha, same as `--ref`/`-Ref`),
`WGM_REPO` (`owner/name` of a fork), and `WGM_TARBALL_URL` (an explicit `.zip`/`.tar.gz` URL, e.g. a
`file://` path for offline installs).

**WSL overrides:** `WGM_WINDOWS_HOME` sets the Windows home to mirror into (same as `--windows-home`).
Advanced/testing knobs: `WGM_FORCE_WSL=0|1` forces the WSL-detection result and `WGM_WIN_AUTODETECT=0|1`
toggles Windows-home auto-detection.

## Where it lands

| Scope | Cross-client (default) | Claude | Copilot CLI |
|---|---|---|---|
| **User** (`~` / `%USERPROFILE%`) | `~/.agents/skills/wgm` | `~/.claude/skills/wgm` | `~/.copilot/skills/wgm` |
| **Project** (`./`) | `./.agents/skills/wgm` | `./.claude/skills/wgm` | via `.agents/skills` |

The `.agents/skills/` path is the cross-client convention: skills installed there are visible to any
compliant client, so it is the safest default.

**In WSL**, a user-scope install also lands a copy under your Windows home — e.g.
`/mnt/c/Users/you/.agents/skills/wgm` (shown on Windows as `%USERPROFILE%\.agents\skills\wgm`) — for
each client detected there. `--uninstall` removes both copies.

## A note on WSL

WSL and Windows have separate home directories, but wgm bridges them so a single install reaches both
sides:

- **Run the bash installer inside WSL** (user scope) and it installs into your Linux home **and**
  mirrors a copy into your Windows home (auto-detected via `/mnt`, or set `--windows-home PATH`). Skip
  the mirror with `--no-windows`. If the Windows home can't be resolved it warns and installs the
  Linux side only — nothing fails.
- **Run the PowerShell installer on Windows** and, if a WSL distro is present, it hands a user-scope
  install to the bash installer inside WSL (the same bridge). Force a native-Windows install with
  `-NoWsl`, or target a specific distro with `-WslDistro NAME`.

```mermaid
flowchart TD
  A[install.sh in WSL] --> B[Linux home: ~/.agents/skills/wgm]
  A --> C[Windows home: /mnt/c/Users/you/.agents/skills/wgm]
  D[install.ps1 on Windows] --> E{WSL distro present?}
  E -- yes, and not -NoWsl --> A
  E -- no, or -NoWsl --> F[Native Windows: %USERPROFILE% .agents/skills/wgm]
  C --> G[Windows agent sees wgm]
  B --> H[WSL agent sees wgm]
```

**Updating:** just re-run the installer. A directory wgm recognizes as its own (its `SKILL.md` says
`name: wgm`) is refreshed in place — no `--force` — and a missing Windows mirror is added. Unrelated
directories are left untouched unless you pass `--force`.

## Verify & uninstall

After installing, open your agent and confirm wgm is listed (e.g. `/skills` in VS Code or Copilot
CLI), then invoke `/wgm`. To remove it, re-run the installer with `--uninstall` / `-Uninstall` and
the same scope/client flags you installed with. In WSL, `--uninstall` also removes the Windows mirror.

**Run the loop from any project:** the installer also places `scripts/loop.sh` inside each target
above; run that copy from your project's root to drive a fresh-context build there (see
[running-the-loop.md](running-the-loop.md)).

See also: [running-the-loop.md](running-the-loop.md) · [troubleshooting.md](troubleshooting.md).
