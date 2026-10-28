---
section: Triage & Grill
order: 2
---
- **Heuristic:** when a Quick-track task is genuinely a single task — one fix, one validation
  command, no multi-step demo path — let that task's own validation command double as the
  demo-validation task, and allow a single short paragraph in place of a formal plan/spec file.
  **Why:** two independent real dogfood runs in the same session, on unrelated codebases (a 3-file
  Java/Quarkus fix and a 2-file .NET fix), converged on the same friction without prompting: a
  formal plan artifact and a *separate* demo-validation task both felt like ceremony when the fix
  task and the demo path were already the same thing. **Provenance:** wgm dogfood, `[learn]` issue
  #56 (`SchwartzKamel/floci-az` Event Hubs `tls-cert` fix + `SchwartzKamel/blogster` `PostsController`
  compile-blocker fix). **Landed in:** `SKILL.md` (Plan-exit gate).
