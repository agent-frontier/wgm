---
section: Backpressure
order: 137
pin: references/hard-to-test-domains.md :: Build differential oracle harnesses for ports and replacements.
---
- **Heuristic:** when validating native apps, CLIs, or desktop launchers, isolate `HOME`,
  `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, and app-specific data/update directories into a disposable
  `mktemp -d` scratch home, and use differential oracle harnesses (reference vs. candidate on
  identical inputs) for ports and rewrites.
  **Why:** unisolated app launches corrupt the operator's real `~/.local/share` or `~/.config`, and
  differential oracles catch subtle behavioral drift across hundreds of cases that hand-written
  assertions miss. **Provenance:** external research, `horizon-rust/horizon`'s `AGENTS.md`.
  **Landed in:** `references/hard-to-test-domains.md` (Build the harness first).
