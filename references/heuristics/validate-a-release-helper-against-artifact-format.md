---
section: Backpressure
order: 177
pin: references/ralph-loop.md :: **Validate a release helper against the artifact format of the tool version it installs.**
---
- **Heuristic:** validate a release/installer helper against the artifact format of the tool
  version it installs, not only the configured version string: inspect canonical asset names and
  the signature verification path, pin a compatible helper revision, never bypass signature
  checks, preserve the failed release, and require a real workflow rerun; source-only approval is
  not release proof.
  **Why:** an older installer can request a detached-signature asset a modern tool no longer
  publishes while source tests and ordinary CI stay green.
  **Provenance:** `[learn]` issue #177. **Landed in:** `references/ralph-loop.md`.
