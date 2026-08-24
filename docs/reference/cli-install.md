# wgm CLI reference: installers

wgm ships two installers with matching behavior: `scripts/install.sh` for Linux, macOS, and WSL, and
`scripts/install.ps1` for native Windows PowerShell.

Both place the skill folder where a skills-compatible agent scans for it, and both install the
**companion skills** (`teach-me`, `quiz-me`, `rugged`) alongside it as sibling skill directories.
When you select a host client, they also install that host's **role-agent adapters** into the
directory the host really scans — see [Role-agent adapters](#role-agent-adapters).

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
| `--dir PATH` | `-Dir PATH` | — | Install into `PATH/wgm` explicitly. Overrides scope and client. Skill only: a bare path names no host, so no agent directory is guessed. |
| `--method M` | `-Method M` | `copy` | `copy` or `symlink`. |
| `--dry-run` | `-DryRun` | off | Print what would happen; change nothing. |
| `--uninstall` | `-Uninstall` | off | Remove wgm and its companions from the resolved targets. |
| `--force` | `-Force` | off | Overwrite or replace an existing install. |
| `--no-companions` | `-NoCompanions` | off | Install wgm alone, without `teach-me`, `quiz-me`, and `rugged`. |
| `--no-agents` | `-NoAgents` | off | Do not install the role-agent adapters. The portable skill and its inline fallback still install. |
| `--no-windows` | — | off | WSL only: do not mirror into your Windows home. |
| `--windows-home P` | — | auto-detect | WSL only: mirror into Windows home `P`. |
| — | `-NoWsl` | off | Windows only: force a native install instead of delegating to WSL. |
| — | `-WslDistro NAME` | — | Windows only: pick which WSL distro to delegate to. |
| `--ref REF` | `-Ref REF` | `main` | Ref to self-fetch when piped: a branch, tag, sha, or `latest` for the newest release. |
| `-h`, `--help` | `-?` | — | Show usage. |

## Install targets

The resolved skill target is always `SKILLS_DIR/wgm`, with companions as siblings:

| Scope and client | Path |
|---|---|
| User, `agents` | `~/.agents/skills/wgm` |
| User, `claude` | `~/.claude/skills/wgm` |
| User, `copilot` | `~/.copilot/skills/wgm` |
| Project | `./.agents/skills/wgm` and `./.claude/skills/wgm` |
| Companions | `SKILLS_DIR/teach-me`, `SKILLS_DIR/quiz-me`, `SKILLS_DIR/rugged` |

**Note:** The directory name must be exactly `wgm`, because it has to match the `name:` field in
`SKILL.md` frontmatter. The same rule applies to each companion.

## Role-agent adapters

wgm's twelve role subagents (the swarm in [subagents](../../references/subagents.md)) are authored
once in the Copilot custom-agent format under `.github/agents/*.agent.md` and derived per host by
`scripts/sync-agent-adapters.sh`. The canonical-to-host mapping is recorded in
[`compatibility/agent-adapters.json`](../../compatibility/agent-adapters.json).

Skills and subagents are **different loading mechanisms**, so they go to different places. A role
file inside the installed skill folder is invisible to every host; these are the directories hosts
actually scan:

<!-- wgm: complete-table -->

| Host client | Scope | Directory | Format |
|---|---|---|---|
| `copilot` | user | `~/.copilot/agents` | `wgm-*.agent.md`, `name: WGM …` |
| `copilot` | project | `.github/agents` | `wgm-*.agent.md`, `name: WGM …` |
| `claude` | user | `~/.claude/agents` | `wgm-*.md`, `name: wgm-…` |
| `claude` | project | `.claude/agents` | `wgm-*.md`, `name: wgm-…` |
| `agents` | either | none — no adapter exists | The Agent Skills standard defines skills, not subagents |

Three rules keep this honest:

- **Evidence, not optimism.** The Copilot adapter is shipped and dispatched; the Claude adapter is
  `Expected` — written to Claude Code's documented subagent format and never dispatched from a live
  Claude Code run. Each Claude file says so in its own header comment. See
  [harness portability](../../references/harness-portability.md) for the evidence tiers.
- **No adapter is a named fallback, not a failure.** A generic `.agents` client, Pi, and any host
  with no subagent primitive get the portable skill and run the docs-audit swarm through
  `scripts/audit.sh`, or the two review passes inline and sequentially with dissent recorded.
- **`--dir` guesses nothing.** It names a path, not a host, so it installs the skill only and says
  so. Pass `--user` or `--project` with `--client copilot|claude|all` to get adapters.

Opt out entirely with `--no-agents` / `-NoAgents`.

### Ownership: what the installer will and will not touch

A host agent directory is shared property — your own agents live there too, and one of them may
already carry a wgm role name. So a matching name is never treated as proof of ownership. Every file
wgm writes ends with a marker comment:

```html
<!-- wgm-role-agent-adapter host=copilot source=.github/agents/wgm-implementer.agent.md version=1 … -->
```

- Only a file carrying that marker is refreshed, pruned, or removed. Delete the comment and wgm
  disowns the file for good.
- A file wgm did not write is skipped, and the installer says `exists and is not wgm's` — including
  a file that merely shares one of wgm's role names. It is never listed in the receipt. Pass
  `--force` / `-Force` to replace it deliberately; the replacement is then stamped and recorded.
- `--uninstall` removes marked files only, and never the directory itself. Unrelated agents survive,
  and so does a wgm-named file whose marker you removed.
- Re-running from a source that dropped a role prunes that role's file, again only when the marker
  is still there.
- The per-directory `.wgm-adapters` receipt is an index of the last install, written temp-then-rename
  so it is never half a list, and parsed leniently (CRLF tolerated, basenames only, host suffix
  enforced). It narrows where wgm looks; the marker is what authorises a delete. A receipt lost to an
  interrupted install therefore costs nothing: uninstall still finds wgm's own files by their marker,
  and still cannot touch yours.
- Running a project install from inside wgm's own checkout is refused for the Copilot target,
  because `.github/agents` there *is* the canonical source.

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
`skills/` directory therefore cannot be uninstalled automatically; remove it by hand. Role adapters
are removed by their ownership marker, not by path pattern, and only from a directory ending in
`agents`.

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

5. If you selected a host client, confirm its role agents landed too:

   ```bash
   ls ~/.copilot/agents/wgm-*.agent.md    # Copilot
   ls ~/.claude/agents/wgm-*.md           # Claude Code
   ```

## Release channel and integrity

wgm has no marketplace, no update service, and no account to hold. **GitHub Releases is the source of
truth.** Every release is addressed by a per-tag URL that is meant never to change, and the release
record points only at those URLs — so an install resolves to one named version rather than to
whatever `main` holds today. Trading a hosted registry for a static, release-backed contract removes
the whole class of "the server changed its mind" problems, at the cost of doing version discovery by
reading one file.

That is stability *of reference*, not a cryptographic guarantee about bytes. GitHub does not freeze a
published release: a maintainer — or anyone who compromises the account — can delete or re-upload an
asset, move a tag, or delete a release outright. What the record and `SHA256SUMS` add is
**detection**: pin a version, keep the SHA-256 you verified, and re-verify every download. If a hash
you have verified before stops matching, do not install it — see
[SECURITY.md](../../SECURITY.md#release-integrity-what-is-and-is-not-proven).

Every tagged release on the `stable` channel publishes four assets:

<!-- wgm: complete-table -->

| Asset | What it is |
|---|---|
| `wgm-vX.Y.tar.gz` | The complete skill tree for that version: `SKILL.md`, `references/`, `scripts/`, and all three companion skills. The release fails if the archive is missing the root `SKILL.md`, the `references/` tree, or any companion. |
| `wgm.tar.gz` | A byte-identical copy under a stable name, so `…/releases/latest/download/wgm.tar.gz` always resolves. |
| `SHA256SUMS` | SHA-256 of both archives in `sha256sum -c` format. |
| `release.json` | The machine-readable release record described below. |

Two URL shapes exist, and they are not interchangeable:

<!-- wgm: complete-table -->

| URL | Moves? | Used by |
|---|---|---|
| `https://github.com/agent-frontier/wgm/releases/download/vX.Y/wgm-vX.Y.tar.gz` | By design, no: it names one tag and one version. | `--ref vX.Y` / `WGM_REF=vX.Y`, and every URL inside `release.json`. |
| `https://github.com/agent-frontier/wgm/releases/latest/download/wgm.tar.gz` | Yes, by design: it follows the newest release. | `--ref latest` / `WGM_REF=latest`, as a convenience alias. |

The `latest` alias is a fetch convenience only, and it keeps working exactly as before. It never
appears inside a release record: the record always names per-tag URLs, and the release workflow fails
closed if it does not. The stable channel therefore can never resolve to a moving `main`. The asset
behind a per-tag URL can still be replaced by whoever controls the repository, which is why the
checksum step below is the part that actually protects you.

`wgm.tar.gz` is published as a byte-identical copy of `wgm-vX.Y.tar.gz`, and the release record must
state the same hash and size for both — otherwise `--ref latest` and `--ref vX.Y` could install
different code from one release while each checksum verified on its own.

### Verifying a download

Download the archive and the checksum manifest into the same directory:

```bash
tag=v0.3
base="https://github.com/agent-frontier/wgm/releases/download/${tag}"
curl -fsSLO "${base}/wgm-${tag}.tar.gz"
curl -fsSLO "${base}/SHA256SUMS"
```

Then check it. This recipe is the portable one — it feeds the manifest line for the file you actually
downloaded to the checker on stdin, so it works with GNU coreutils and with the `shasum` that ships
on macOS, and it exits non-zero on a mismatch:

```bash
# macOS, and anywhere shasum exists
grep "wgm-${tag}.tar.gz" SHA256SUMS | shasum -a 256 -c -

# Linux (GNU coreutils) — same shape
grep "wgm-${tag}.tar.gz" SHA256SUMS | sha256sum -c -
```

Both print `wgm-vX.Y.tar.gz: OK` and exit 0 when the bytes match. Piping one line in keeps the check
from failing over the *other* archive you did not download; GNU coreutils can do the same across the
whole manifest with `sha256sum --ignore-missing -c SHA256SUMS`, but `--ignore-missing` is a GNU
extension and is absent from the `shasum` on older macOS.

```powershell
# Windows PowerShell
$tag = 'v0.3'
(Get-FileHash "wgm-$tag.tar.gz" -Algorithm SHA256).Hash.ToLower()
Select-String -Path SHA256SUMS -Pattern "wgm-$tag.tar.gz"
```

On Windows compare the two strings yourself: they must be identical, character for character.

`SHA256SUMS` itself is covered by `release.json`, and the release workflow refuses to publish a
manifest whose lines disagree with the record or the archives — so a manifest that verifies the wrong
bytes cannot be released.

SHA-256 proves the bytes you got are the bytes `SHA256SUMS` names. It is a checksum, not a
signature: it says nothing about *who* built them, and if the release itself were rewritten the
checksums would be rewritten with it. Its real strength is comparison over time — a hash you recorded
at install time, or one an independent copy of the release record carries.

**If the check does not say `OK` (or the tool exits non-zero):** stop — do not extract, install, or
run the archive. Keep the downloaded
file and the `SHA256SUMS` you fetched, confirm you compared the same tag and the same file name, and
re-download once to rule out a truncated transfer. If it still differs, report it through the private
channel in [SECURITY.md](../../SECURITY.md) and do not install from that copy. A mismatch is either a
corrupted download or a replaced asset, and both are worth a report.

### The release record (`release.json`)

`release.json` is a schema-versioned JSON object generated and validated by
`scripts/build-release-index.sh`. It carries:

<!-- wgm: complete-table -->

| Field | Meaning |
|---|---|
| `schema_version` | Shape of this record. Bumped whenever fields change, so an old reader refuses rather than guesses. |
| `channel` | `stable` today. `edge` is reserved and must be set explicitly if it is ever used. |
| `version` / `tag` | The skill version (`0.3`) and its tag (`v0.3`). The workflow fails if they disagree with `SKILL.md`. |
| `commit` | The full 40-character commit sha the tag points at — the content-addressed anchor of the release. |
| `published_at` / `generated_at` | RFC 3339 UTC timestamps for publication and record generation. |
| `minimum_updater_schema` | The lowest updater implementation able to read this record. |
| `assets[]` | Each asset's `name`, `role`, `sha256`, `size_bytes`, and per-tag download `url`. |
| `contents` | The skill manifest and companion set the archive must carry. The validator additionally requires a root `SKILL.md` and a non-empty `references/` tree inside the archive itself. |
| `provenance` | Honest labelling of the integrity evidence: checksums, attestation state, signature state. |

`assets[]` lists three entries — the versioned archive, the stable archive, and `SHA256SUMS`.
`release.json` is the fourth published asset but deliberately does **not** appear in its own
`assets[]`: a record cannot contain its own hash. Verify it by the release it came from, and compare
the archive hashes it names against `SHA256SUMS`, which it does cover.

Fetch the newest record with
`https://github.com/agent-frontier/wgm/releases/latest/download/release.json`, or a specific one with
`https://github.com/agent-frontier/wgm/releases/download/vX.Y/release.json`.

**How the updater will use it.** A self-update command reads the stable record, compares `version`
against the installed `SKILL.md` version, downloads the `versioned-archive` asset by its per-tag
`url`, re-hashes it against the recorded `sha256` and `size_bytes`, and installs only on a match —
refusing outright if `schema_version` exceeds what it understands. That is the entire protocol: one static file, no
service, no credentials. Until then, `--ref latest` remains the supported way to update.

To reproduce a release's metadata locally, build the archives first — the generator reads them, and
fails if they are not there (exit 2 when `--dist` does not exist at all, exit 1 when it exists but
holds no archives):

```bash
tag=v0.3
git checkout "${tag}"          # generate from the tagged tree, not from your working branch
mkdir -p dist
tar --exclude-vcs --exclude=./dist -czf "dist/wgm-${tag}.tar.gz" .
cp "dist/wgm-${tag}.tar.gz" dist/wgm.tar.gz

bash scripts/build-release-index.sh --tag "${tag}" --commit "$(git rev-parse "${tag}^{commit}")" --dist dist
bash scripts/build-release-index.sh --validate dist/release.json --assets-dir dist --expect-tag "${tag}"
```

`dist/` is gitignored. Compression is not byte-reproducible across tar/gzip versions, so a locally
built archive may hash differently from the published one; what this reproduces is the record's
*shape and self-consistency*, not the published hashes. To check those, download the release assets
and run the validator with `--assets-dir` pointed at them.

## What to do next

- [Requirements](../get-started/requirements.md) — what must be present before you install.
- [Get started](../get-started/README.md) — the end-to-end first run.
- [Troubleshooting](../operator/troubleshooting.md) — if the skill does not appear.
- [Security policy](../../SECURITY.md) — the release-integrity contract and what it does not claim.
