---
section: Local sandboxing (devcontainers)
order: 11
---
- **Heuristic:** a deterministic gate is not proven by writing it — prove it goes **RED** on the
  class it claims to catch, or it is indistinguishable from no gate. **Why:** the mojibake sweep
  added for `[learn]` #67 shipped matching nothing at all: PCRE reads `\xNN` as a *character* in a
  UTF-8 locale and as a *byte* only under `LC_ALL=C`, so it reported GREEN forever over corrupt
  input. A one-line probe caught it before merge. The same class covers allow-lists that never
  reject and doc checks that never fire. **Provenance:** wgm dogfood — found while implementing
  `[learn]` issues #67 and #86 in the same pass. **Landed in:** `scripts/test-check-docs.sh` ·
  `scripts/test-check-evals.sh` · `scripts/check-docs.sh` (check 9's `LC_ALL=C` pin).
