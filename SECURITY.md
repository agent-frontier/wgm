# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use GitHub's private
vulnerability reporting:

1. Go to the repository's **Security** tab → **Report a vulnerability**
   (<https://github.com/agent-frontier/wgm/security/advisories/new>).
2. Describe the issue, the impact, and steps to reproduce.

We'll acknowledge the report, investigate, and coordinate a fix and disclosure with you. Thanks for
helping keep users safe.

## Reporting a conduct issue

For Code of Conduct or moderation concerns, use the same private reporting channel above for now.
Please include enough context for us to investigate, and avoid posting the issue publicly so the
report stays confidential.

## Supported versions

wgm is distributed as an Agent Skill and is rolling-released from `main`. Security fixes land on
`main`; re-running the installer updates an existing install in place.

Tagged releases are cut from `main` and published to GitHub Releases on the `stable` channel. A tag
is the only immutable thing in this distribution, so `stable` is always pinned to a tag and a full
commit sha — never to a moving branch.

## Release integrity (what is and is not proven)

There is no wgm marketplace, registry, or update service. GitHub Releases is the source of truth, and
every release publishes its own integrity evidence as static assets:

- `SHA256SUMS` — SHA-256 of `wgm-vX.Y.tar.gz` and `wgm.tar.gz`, in `sha256sum -c` format.
- `release.json` — a schema-versioned release record naming the channel, version, tag, commit sha,
  publication time, and each asset's immutable URL, size, and SHA-256. Its full field list is in
  [docs/reference/cli-install.md](docs/reference/cli-install.md).

Verify a download before trusting it:

```bash
tag=v0.3
base="https://github.com/agent-frontier/wgm/releases/download/${tag}"
curl -fsSLO "${base}/wgm-${tag}.tar.gz"
curl -fsSLO "${base}/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS
```

**What this proves.** That the archive you hold is byte-for-byte the archive that release published,
and that it is the release the record claims: right version, right tag, right commit, complete skill
tree including all three companion skills.

**What this does not prove.** SHA-256 is a checksum, not a signature. It carries no cryptographic
proof of *who* produced the bytes, and an attacker who could rewrite the release could rewrite the
checksums with it. wgm publishes **no cryptographic signatures** today, and **no build attestation**
is configured — `release.json` says so explicitly (`provenance.signatures: "none"`,
`provenance.attestation: "unavailable"`). The release workflow rejects any record that claims
otherwise, so the field cannot quietly start overstating what exists. If signing or GitHub artifact
attestation is added later, the record will name it and the validator will require the evidence to
back it.

The release workflow fails closed before anything is published: malformed metadata, a missing asset,
a checksum mismatch, a tag that disagrees with `SKILL.md`'s version, a stable record pinned to a
moving ref, or an archive missing `SKILL.md` or a companion all stop the release. The same checks run
offline via `scripts/build-release-index.sh --validate` and `scripts/test-release-index.sh`, so you
can reproduce them without credentials.

## Safety model (please read before running)

wgm ships three capabilities that execute on your machine or reach outside it. All are designed to
be safe, but they put control in your hands:

- **`curl … | bash` / `irm … | iex` installers.** These convenience one-liners fetch and run code
  from this repo. If you'd rather inspect first, clone the repo and run `scripts/install.sh` /
  `scripts/install.ps1` directly — every flag is documented in `--help`. Pin a specific ref with
  `WGM_REF` / `--ref` to avoid trusting a moving `main`.
- **The autonomous loop (`scripts/loop.sh`).** This invokes your coding agent repeatedly and lets it
  edit files **without per-step approval** by design. Run it **only** in a sandbox or disposable
  workspace you are comfortable letting an agent operate in autonomously. It never commits or pushes
  unless you pass `--commit`. Stop it any time with `Ctrl+C` or by creating a `STOP` / `.wgm/STOP`
  sentinel file.
- **The Hive Growth Loop (`scripts/harvest-hive.sh`, dispatched as the `wgm-hermes` subagent).** This
  is the one wgm capability that can, on its own, send data to a public third-party GitHub repo
  (`agent-frontier/wgm`). It is **off by default**: wgm asks a one-time consent question (the first
  thing it does in Triage on a project without `.github/wgm-hive.yml` yet) and only ever reports
  automatically after that file records `consent: true`. Every report is anonymized first — a
  first-pass deterministic scrub for paths, URLs, hostnames, repo/org names, and credential-shaped
  strings — but this is **not a redaction guarantee**; review `.github/wgm-hive.yml` and, if in
  doubt, keep `consent: false` (the shipped default) or inspect a report with `scripts/harvest-hive.sh
  --dry-run` before ever enabling it on a project with sensitive context. It never opens or merges a
  pull request — only files or comments on an issue. See `references/self-improvement.md`.

The installers and loop avoid `eval` on untrusted input. The loop does send prompts and selected repo
context to whichever agent provider you configure, so do not include secrets or private data unless
that provider is approved for the workflow. If you find a case where that isn't true, report it as
above.
