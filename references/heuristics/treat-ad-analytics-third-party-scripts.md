---
section: Comparative & hard-to-test scoring
order: 1
---
- **Heuristic:** treat ad/analytics/third-party scripts as a Core Web Vitals constraint gated in the
  same audit as the content, never bolted on. **Why:** monetization/telemetry is the classic way a
  content site destroys the performance it depends on (layout shift, main-thread blocking, LCP
  regressions) — reserved-space wrappers + deferred scripts + a shared CLS/LCP gate turn "the ad
  shows up" into "the ad shows up *and* CWV stays in budget." **Provenance:** wgm dogfood, `[learn]`
  issue #35. **Landed in:** `references/hard-to-test-domains.md` (Web SEO / ranking).
