<!-- Thanks for contributing to wgm! Keep edits surgical and scoped (see CONTRIBUTING.md). -->

## Summary

<!-- What does this change and why? Link any related issue (e.g. "Closes #123"). -->

## Type of change

- [ ] Lifecycle / protocol (`SKILL.md`, `references/`)
- [ ] Ralph loop (`scripts/loop.sh`)
- [ ] Installer (`scripts/install.sh` / `install.ps1`)
- [ ] Docs (`docs/`, `README.md`)
- [ ] Repo / CI / governance

## Backpressure checks

These are the project's deterministic pass/fail signal — all must be green (see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)). Check what you ran:

- [ ] `shellcheck scripts/*.sh`
- [ ] `for s in scripts/*.sh; do bash -n "$s"; done`
- [ ] `( cd .. && skills-ref validate wgm )`
- [ ] `bash scripts/check-docs.sh`
- [ ] `bash scripts/test-install.sh`
- [ ] `pwsh -File scripts/test-install.ps1`

## Notes for reviewers

<!-- Anything reviewers should focus on, trade-offs, or follow-ups. -->
