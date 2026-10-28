---
section: Comparative & hard-to-test scoring
order: 2
---
- **Heuristic:** when "better X" is the goal but X is unobservable in CI (live SEO/Google rank,
  "beats the incumbent"), pin it to a deterministic proxy and score it head-to-head against a served
  incumbent, not just an absolute threshold. **Why:** an absolute pass is blind to "worse than the
  thing you're replacing"; a live baseline also blocks gaming and surfaces the incumbent's own
  failures as the proof. **Provenance:** wgm dogfood, `[learn]` issues #32, #33.
  **Landed in:** `references/hard-to-test-domains.md` (Web SEO / ranking) ·
  `references/scoring.md` (Relative-to-incumbent scoring).
