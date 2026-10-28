---
section: Swarm & parallelism
order: 2
---
- **Heuristic:** bless a feasibility-spike as a first-class parallel swarm stream whose deliverable
  is a go/no-go verdict, and treat a well-supported NO-GO as a PASS, not a stall. **Why:** a spike
  that reshapes the backlog (drops a now-duplicate task, promotes a patchable sub-win, records a
  settled question) is one of the highest-value outcomes a run can produce — misreading it as a
  failure would suppress exactly the signal that saves the most wasted work. **Provenance:** wgm
  dogfood, `[learn]` issue #30. **Landed in:** `docs/operator/running-the-loop.md` (Swarm — Planning
  a swarm well) · `references/stall-recovery.md` (Detecting a stall).
