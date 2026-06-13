# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use GitHub's private
vulnerability reporting:

1. Go to the repository's **Security** tab → **Report a vulnerability**
   (<https://github.com/agent-frontier/wgm/security/advisories/new>).
2. Describe the issue, the impact, and steps to reproduce.

We'll acknowledge the report, investigate, and coordinate a fix and disclosure with you. Thanks for
helping keep users safe.

## Supported versions

wgm is distributed as an Agent Skill and is rolling-released from `main`. Security fixes land on
`main`; re-running the installer updates an existing install in place.

## Safety model (please read before running)

wgm ships two capabilities that execute on your machine. Both are designed to be safe, but they put
control in your hands:

- **`curl … | bash` / `irm … | iex` installers.** These convenience one-liners fetch and run code
  from this repo. If you'd rather inspect first, clone the repo and run `scripts/install.sh` /
  `scripts/install.ps1` directly — every flag is documented in `--help`. Pin a specific ref with
  `WGM_REF` / `--ref` to avoid trusting a moving `main`.
- **The autonomous loop (`scripts/loop.sh`).** This invokes your coding agent repeatedly and lets it
  edit files **without per-step approval** by design. Run it **only** in a sandbox or disposable
  workspace you are comfortable letting an agent operate in autonomously. It never commits or pushes
  unless you pass `--commit`. Stop it any time with `Ctrl+C` or by creating a `STOP` / `.wgm/STOP`
  sentinel file.

The installers and loop avoid `eval` on untrusted input and never transmit your code to third
parties. If you find a case where that's not true, report it as above.
