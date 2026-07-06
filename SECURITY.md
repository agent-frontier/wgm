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
