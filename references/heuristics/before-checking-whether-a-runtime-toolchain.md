---
section: Backpressure
order: 3
---
- **Heuristic:** before checking whether a runtime/toolchain is *newer* than a tool's tested
  baseline, first do a trivial presence check (`which <tool>` / a version probe) that it is
  installed **at all** — a distinct, cheaper, more basic failure mode than a version mismatch.
  **Why:** a real dogfood run's very first validation attempt failed immediately because the
  sandbox had no `java`/`JAVA_HOME` installed, forcing a mid-task detour to fetch a repo-local JDK
  before any real work could start — a one-line presence check at T1 is strictly cheaper than
  proving full end-to-end runtime compatibility and catches this more basic failure mode first.
  **Provenance:** wgm dogfood, `[learn]` issue #57 (`SchwartzKamel/floci-az`,
  Java/Quarkus). **Landed in:** `references/ralph-loop.md` (Backpressure in depth).
