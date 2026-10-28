---
section: Token economy
order: 2
---
- **Heuristic:** single-token compaction is model-specific — verify keys against the target
  tokenizer; short ASCII keys are the portable default. **Why:** a CJK glyph is 1 token in OpenAI
  o200k but 2–3 in cl100k, so "kanji == 1 token" is false in general.
  **Provenance:** tiktoken measurement during the token-economy pass. **Landed in:**
  `references/artifacts.md` (Token economy) · `assets/state.template.toon`.
