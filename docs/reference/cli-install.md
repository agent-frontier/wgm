# wgm CLI reference: installers

wgm ships two installers with matching behavior: `scripts/install.sh` for Linux, macOS, and WSL, and
`scripts/install.ps1` for native Windows PowerShell.

Both place the skill folder where a skills-compatible agent scans for it, and both install the
**companion skills** (`teach-me`, `quiz-me`) alongside it as sibling skill directories.

## Syntax

```bash
# Linux, macOS, WSL
scripts/install.sh [FLAGS]

# Windows PowerShell
scripts/install.ps1 [PARAMETERS]
```

## Flags and parameters

| bash | PowerShell | Default | Description |
|---|---|---|---|
| `--user` | `-User` (implied) | **default** | Install into your home directory, available in every project. |
| `--project` | `-Project` | — | Install into the current project only. |
| `--client NAME` | `-Client NAME` | `auto` | `agents`, `claude`, `copilot`, `all`, or `auto`. `auto` = `agents` plus any client whose home directory exists. |
| `--dir PATH` | `-Dir PATH` | — | Install into `PATH/wgm` explicitly. Overrides scope and client. |
| `--method M` | `-Method M` | `copy` | `copy` or `symlink`. |
| `--dry-run` | `-DryRun` | off | Print what would happen; change nothing. |
| `--uninstall` | `-Uninstall` | off | Remove wgm and its companions from the resolved targets. |
| `--force` | `-Force` | off | Overwrite or replace an existing install. |
| `--no-companions` | `-NoCompanions` | off | Install wgm alone, without `teach-me` and `quiz-me`. |
| `--no-windows` | — | off | WSL only: do not mirror into your Windows home. |
| `--windows-home P` | — | auto-detect | WSL only: mirror into Windows home `P`. |
| — | `-NoWsl` | off | Windows only: force a native install instead of delegating to WSL. |
| — | `-WslDistro NAME` | — | Windows only: pick which WSL distro to delegate to. |
| `--ref REF` | `-Ref REF` | `main` | Ref to self-fetch when piped: a branch, tag, sha, or `latest` for the newest release. |
| `-h`, `--help` | `-?` | — | Show usage. |

## Install targets

The resolved target is always `SKILLS_DIR/wgm`, with companions as siblings:

| Scope and client | Path |
|---|---|
| User, `agents` | `~/.agents/skills/wgm` |
| User, `claude` | `~/.claude/skills/wgm` |
| User, `copilot` | `~/.copilot/skills/wgm` |
| Project | `./.agents/skills/wgm` and `./.claude/skills/wgm` |
| Companions | `SKILLS_DIR/teach-me`, `SKILLS_DIR/quiz-me` |

**Note:** The directory name must be exactly `wgm`, because it has to match the `name:` field in
`SKILL.md` frontmatter. The same rule applies to each companion.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `WGM_REPO` | `agent-frontier/wgm` | Owner/name to fetch when self-fetching. |
| `WGM_REF` | `main` | Branch, tag, sha, or `latest`. Same as `--ref`. |
| `WGM_TARBALL_URL` | — | Explicit `.tar.gz` URL. Advanced or offline use, including `file://`. |
| `WGM_WINDOWS_HOME` | auto-detect | WSL: Windows home to mirror into. Same as `--windows-home`. |
| `WGM_FORCE_WSL` | auto-detect | Testing override for WSL detection. |
| `WGM_WIN_AUTODETECT` | `1` | Testing override for Windows-home autodetect. |

## Behavior worth knowing

**Re-running updates in place.** If the target already holds a recognized wgm install (its
`SKILL.md` frontmatter says `name: wgm`), a re-run updates it without needing `--force`. An
unrecognized directory is left intact and skipped.

**WSL installs bridge to Windows.** Inside WSL, a user-scope install also mirrors the skill into
your Windows home so native-Windows agents see it too. Disable with `--no-windows`.

**PowerShell delegates to WSL.** On Windows with a WSL distro present, a user-scope `install.ps1`
delegates to the bash installer inside WSL on purpose, so both homes are covered. Pass `-NoWsl` for
a native-Windows install.

**Self-fetch when piped.** Run via `curl … | bash` with no local checkout and the script downloads
the repo itself.

**Caution:** `--uninstall` only removes paths ending in `skills/wgm`, `skills/teach-me`, or
`skills/quiz-me`. It refuses any other path. A `--dir` install outside a `skills/` directory
therefore cannot be uninstalled automatically; remove it by hand.

## Verifying an install

To confirm the skill is visible:

1. List the target directory and check for `SKILL.md`:

   ```bash
   ls ~/.agents/skills/wgm/SKILL.md
   ```

2. Confirm the frontmatter name matches the directory name:

   ```bash
   head -3 ~/.agents/skills/wgm/SKILL.md
   ```

3. Restart your agent session so it re-scans skills.

4. Ask your client to list skills (for example `/skills` in VS Code or Copilot CLI), and confirm
   `wgm`, `teach-me`, and `quiz-me` all appear.

## What to do next

- [Requirements](../get-started/requirements.md) — what must be present before you install.
- [Get started](../get-started/README.md) — the end-to-end first run.
- [Troubleshooting](../operator/troubleshooting.md) — if the skill does not appear.
