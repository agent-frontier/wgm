# Backpressure for hard-to-test domains (native, games, GUIs, engines)

The loop dies without a deterministic pass/fail signal. In web/CLI/library work the signal is
obvious (a test, a type-check, an HTTP probe). In **native apps, games, engines, emulators, GUIs,
firmware** the magic moment is *on-screen / interactive* and there is no natural unit test — so the
first job is to **build the harness that becomes the backpressure.** Treat the harness as the
product's first feature, not an afterthought.

## Build the harness first (it IS the backpressure)
- **Headless, automated entry.** Add env-gated automation: scripted input, auto-advance past splash/
  menus, and a **fixed step/frame limit** so every run *terminates on its own*. A run that needs a
  human to close it is not a signal.
- **Capture the real output and look at it — at full fidelity.** Dump the framebuffer / render to an
  image or text file and **view it**. Do not trust a downscaled or blurry glance: crop and zoom the
  region in question before concluding. (Misreading a shrunk capture sends you debugging a bug that
  isn't there.)
- **Probe internal state from a sidecar.** Have the program publish a *stable* address/state map
  (no-ASLR build, or a known offset table) and read it from a second process to assert invariants
  (HP, entity positions, "flag captured") **without** driving the UI. This turns "looks right" into
  `assert`.
- **Soak tests for crash classes.** Many faults appear only after *N* steps and only *under load*
  (more simulation per frame). Run long, with stress (sustained input, many entities), and assert a
  **"no crash marker"** in the log. Short happy-path runs prove almost nothing about stability.

## Make the signal deterministic
- **Drive time by step count, not the wall clock.** If gameplay/sim tics come from `SDL_GetTicks()`
  / real time, the same run does different work under parallel/CPU load — flaky tests that hide real
  failures. Advance the sim per *rendered step* so a fixed step-limit yields a fixed amount of work.
- **A test that passes solo but fails under parallel load is signal, not noise.** Under contention
  more sim-steps elapse per frame, so the run reaches deeper states. Reproduce it, don't retry-until-
  green.

## Crash backpressure for compiled code
- **In-process crash handler.** Install a handler that prints a **symbolized backtrace** (module +
  RVA per frame; `file:line` when a debug-info / PDB build sits beside the binary). This converts an
  opaque exit code into an actionable stack.
- **Beware Heisenbugs.** Optimized (Release) and debug (RelWithDebInfo) builds have **different
  memory layouts**, so a layout-dependent over-read can crash one and not the other. Reproduce on
  the build that actually faults; symbolize with a **Release + symbols** build (matching layout),
  not a plain debug build.
- **No symbols? Disassemble around the faulting RVA.** The faulting instruction plus the array
  stride (`<<5` = a 32-byte struct, etc.) usually identifies the over-indexed structure and the bad
  index's source.

## Native gotchas that masquerade as logic bugs
- **Integer width.** `long` is **32-bit on MSVC/Windows-x64** but 64-bit on most Unix LP64 targets.
  Storing a 64-bit pointer in `long` (or a `long[]`) **truncates** it. Audit every pointer-holding
  storage when porting.
- **The partial-migration trap.** If you migrate a type's *consumers* (locals, helper signatures)
  to the wide type but leave its *storage* narrow, every read silently truncates — and it
  *half-works*, which masks the bug. Migrate the storage and the consumers together.
- **Defensive bounds-guards are cheap, behaviour-preserving backpressure.** `if ((unsigned)i >=
  (unsigned)n)` rejects both `i < 0` and `i >= n` in one compare. Guard array indexing at function
  entry; on a bad index return the function's safe "no-op / no-hit" result. Valid input is
  unaffected; a corruption-driven over-read becomes a survivable miss.

## Vendored-engine / submodule workflow
- Commit the engine/library change **in the submodule first**, push it, **then** bump the parent's
  submodule pointer in a separate commit. Re-stage / rebuild the shipped artifact so the binary the
  user runs matches the source.
- **Revert tool-regenerated files before committing** (scanner reports, generated headers, coverage
  dumps) so diffs stay legible and reviewable.

## When the right fix destabilizes
A correct fix can *expose* a deeper latent fault (e.g. enabling real behaviour reaches code paths
that were previously dead). Do not paper over it and do not ship a red suite — see
[`stall-recovery.md`](stall-recovery.md) ("Destabilizing fix while unattended"): preserve the fix on
a branch, revert to green, and hand off with a precise repro. A separate **low-risk hardening track**
(defensive guards), validated by the *same* acceptance soak, often de-risks or unblocks the risky fix.

## Cross-links
[`ralph-loop.md`](ralph-loop.md) (backpressure in depth) · [`scoring.md`](scoring.md) (holdout
satisfaction when no deterministic check fits) · [`validation-env.md`](validation-env.md)
(containerized runs) · [`stall-recovery.md`](stall-recovery.md)
