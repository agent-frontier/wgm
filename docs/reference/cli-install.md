# wgm CLI reference: installers

wgm ships two installers with matching behavior: `scripts/install.sh` for Linux, macOS, and WSL, and
`scripts/install.ps1` for native Windows PowerShell.

Both place the skill folder where a skills-compatible agent scans for it, and both install the
**companion skills** (`teach-me`, `quiz-me`, `rugged`) alongside it as sibling skill directories.

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
| `--no-companions` | `-NoCompanions` | off | Install wgm alone, without `teach-me`, `quiz-me`, and `rugged`. |
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
| Companions | `SKILLS_DIR/teach-me`, `SKILLS_DIR/quiz-me`, `SKILLS_DIR/rugged` |

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

**Caution:** `--uninstall` only removes paths ending in `skills/wgm`, `skills/teach-me`,
`skills/quiz-me`, or `skills/rugged`. It refuses any other path. A `--dir` install outside a
`skills/` directory therefore cannot be uninstalled automatically; remove it by hand.

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
   `wgm`, `teach-me`, `quiz-me`, and `rugged` all appear.

## Release channel and integrity

wgm has no marketplace, no update service, and no account to hold. **GitHub Releases is the source
of truth.** A tag and its assets are immutable once published, and nothing sits between you and the
bytes that could later start serving something else. Trading a hosted registry for a static,
release-backed contract removes the whole class of "the server changed its mind" problems, at the
cost of doing version discovery by reading one file.

Every tagged release on the `stable` channel publishes four assets:

<!-- wgm: complete-table -->

| Asset | What it is |
|---|---|
| `wgm-vX.Y.tar.gz` | The complete skill tree for that version: `SKILL.md`, `references/`, `scripts/`, and all three companion skills. |
| `wgm.tar.gz` | A byte-identical copy under a stable name, so `…/releases/latest/download/wgm.tar.gz` always resolves. |
| `SHA256SUMS` | SHA-256 of both archives in `sha256sum -c` format. |
| `release.json` | The machine-readable release record described below. |

Two URL shapes exist, and they are not interchangeable:

<!-- wgm: complete-table -->

| URL | Moves? | Used by |
|---|---|---|
| `https://github.com/agent-frontier/wgm/releases/download/vX.Y/wgm-vX.Y.tar.gz` | Never. Pinned to one tag. | `--ref vX.Y` / `WGM_REF=vX.Y`, and every URL inside `release.json`. |
| `https://github.com/agent-frontier/wgm/releases/latest/download/wgm.tar.gz` | Yes. Follows the newest release. | `--ref latest` / `WGM_REF=latest`, as a convenience alias. |

The `latest` alias is a fetch convenience only. It never appears inside a release record: the record
always names immutable per-tag URLs, and the release workflow fails closed if it does not. The stable
channel therefore can never resolve to a moving `main`.

### Verifying a download

```bash
tag=v0.3
base="https://github.com/agent-frontier/wgm/releases/download/${tag}"
curl -fsSLO "${base}/wgm-${tag}.tar.gz"
curl -fsSLO "${base}/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS
```

SHA-256 proves the bytes you got are the bytes that release published. It is a checksum, not a
signature: it says nothing about *who* built them. See [SECURITY.md](../../SECURITY.md) for what the
`provenance` block does and does not claim.

### The release record (`release.json`)

`release.json` is a schema-versioned JSON object generated and validated by
`scripts/build-release-index.sh`. It carries:

<!-- wgm: complete-table -->

| Field | Meaning |
|---|---|
| `schema_version` | Shape of this record. Bumped whenever fields change, so an old reader refuses rather than guesses. |
| `channel` | `stable` today. `edge` is reserved and must be set explicitly if it is ever used. |
| `version` / `tag` | The skill version (`0.3`) and its tag (`v0.3`). The workflow fails if they disagree with `SKILL.md`. |
| `commit` | The full 40-character commit sha the tag points at — the immutable anchor of the release. |
| `published_at` / `generated_at` | RFC 3339 UTC timestamps for publication and record generation. |
| `minimum_updater_schema` | The lowest updater implementation able to read this record. |
| `assets[]` | Each asset's `name`, `role`, `sha256`, `size_bytes`, and immutable download `url`. |
| `contents` | What the archive must contain: `SKILL.md` plus every companion skill. |
| `provenance` | Honest labelling of the integrity evidence: checksums, attestation state, signature state. |

Fetch the newest record with
`https://github.com/agent-frontier/wgm/releases/latest/download/release.json`, or a specific one with
`https://github.com/agent-frontier/wgm/releases/download/vX.Y/release.json`.

**How the updater will use it.** A self-update command reads the stable record, compares `version`
against the installed `SKILL.md` version, downloads the `versioned-archive` asset by its immutable
`url`, re-hashes it against the recorded `sha256`, and installs only on a match — refusing outright
if `schema_version` exceeds what it understands. That is the entire protocol: one static file, no
service, no credentials. Until then, `--ref latest` remains the supported way to update.

To reproduce the metadata for a tag locally:

```bash
bash scripts/build-release-index.sh --tag vX.Y --commit "$(git rev-parse vX.Y^{commit})" --dist dist
bash scripts/build-release-index.sh --validate dist/release.json --assets-dir dist --expect-tag vX.Y
```

## What to do next

- [Requirements](../get-started/requirements.md) — what must be present before you install.
- [Get started](../get-started/README.md) — the end-to-end first run.
- [Troubleshooting](../operator/troubleshooting.md) — if the skill does not appear.
- [Security policy](../../SECURITY.md) — the release-integrity contract and what it does not claim.
