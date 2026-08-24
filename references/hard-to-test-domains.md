# Backpressure for hard-to-test domains (native, games, GUIs, engines)

The loop dies without a deterministic pass/fail signal. In web/CLI/library work the signal is
usually obvious (a test, a type-check, an HTTP probe) — but some claims (like "ranks better on SEO")
have no CI-observable signal at all; see **Web SEO / ranking** below. In **native apps, games,
engines, emulators, GUIs, firmware** the magic moment is *on-screen / interactive* and there is no
natural unit test — so the first job is to **build the harness that becomes the backpressure.**
Treat the harness as the product's first feature, not an afterthought.

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
- **Native workflow control flow.** When CI/release workflow correctness depends on a native command's nonzero exit (e.g., an expected "not found" before publishing), **require a runtime probe under the target shell version** in addition to static structure checks. Static evidence should never override observed runtime semantics — the target shell may escalate that expected exit code into a terminating error, aborting the workflow. Add this to your workflow review guidance and include it as a tier-3 holdout for native CI/release automation.

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

## Headless layout budgets (GUI frameworks)
A DPI-aware screenshot smoke produces images a human must judge, so it can never *fail a build* on a
clipped card. Most GUI frameworks — retained- or immediate-mode — expose a headless layout/measure
pass plus a CPU rasterizer, and that pair turns "does it clip at the small size?" into a red/green
gate with no window and no GPU:

- **Build the widget tree with the software/CPU renderer** instead of the GPU one. Under the CPU
  feature the renderer type the view expects is typically identical, so no production code changes.
- **Lay out at a chosen viewport** with the framework's headless build/measure entry point.
- **Tag the containers under test with stable ids**, then run a recording pass over the laid-out
  tree that captures each tagged container's bounds and any scroll container's content bounds.
- **Assert invariants at the worst case** — maximum content, minimum window size: every card has
  positive, non-collapsed bounds; each card that should scroll actually records scrollable content;
  a growing list's scroll content height grows with item count.

Prefer an **in-crate/in-module test** (a `#[cfg(test)] mod` child of the binary, or the framework's
equivalent) over an external integration test: it sees private items and can reuse the real app
constructor, so you avoid widening visibility purely for tests. Put the renderer/runtime crates in
dev-dependencies, pinned to the versions already in the lockfile.

**Provenance:** `[learn]` issue #76 (an immediate-mode Rust/iced GUI whose only visual gate was a
screenshot smoke; a windowless layout test closed the card-overflow / zero-collapse / clipping gap).

## Web SEO / ranking (and other live, CI-unobservable claims)
Some web acceptance criteria — "ranks better on SEO," "beats the incumbent," any claim whose true
value lives on a live third-party service — have **no CI-observable signal at all**: live Google rank
cannot be queried from a test. Manufacture a deterministic **proxy** instead of shrugging:

- **Pin the proxy.** For "better SEO," assert what *is* observable: full content present in
  view-source (proves pre-render, not client-only hydration), Lighthouse SEO = 100, and valid
  JSON-LD / sitemap / robots.txt / canonical / OpenGraph on every route.
- **Score it head-to-head against the incumbent**, not just against an absolute number — see
  *Relative-to-incumbent scoring* in `references/scoring.md`. An absolute pass is blind to "worse
  than the thing you're replacing"; a served baseline also blocks gaming.
- **Treat ad/analytics/third-party scripts as a performance constraint, not a feature.** Monetization
  and telemetry are the classic way a content site accidentally destroys the Core Web Vitals it
  depends on (layout shift from late ad iframes, main-thread blocking, LCP regressions). Ship ad
  slots inside fixed-height reserved-space wrappers (no layout shift on insert), defer/lazy-load the
  scripts, and **gate them in the exact same audit that gates the content** — CLS/LCP must hold with
  ads on, not just with them off.
- This generalizes past web/SEO: any "is this actually better / faster / ranked-higher" claim that
  lives outside CI benefits from a deterministic proxy scored against a live, served baseline.

**Provenance:** `[learn]` issues #32 (SEO/ranking proxy) and #35 (ads/CWV as a perf constraint).

## Cross-OS boundary reachability (WSL ↔ Windows, guest ↔ host)
"The service is up" and "the consumer can reach the service" are different claims whenever the
consumer runs on the *other side* of a virtualization boundary. A guest-side probe cannot observe
that boundary — it never crosses it — so a green `curl` inside WSL is not evidence that a Windows
browser, editor, or CLI can connect.

- **Run the probe as a process on the consumer's OS.** For WSL that means a real Windows PowerShell
  reached through interop, not `curl` in the distro. Make the probe *print the platform it ran on*
  and have the orchestrator refuse any result that does not report the expected origin — otherwise a
  same-side run silently gets relabeled as cross-boundary evidence.
- **Contrast both binds in one run.** Publish the same disposable service on guest **loopback** and
  then on **all interfaces**, and report the observed result per *endpoint* (host loopback vs. the
  guest's routable IPv4). One endpoint alone cannot distinguish "wrong bind" from "no route".
- **Exercise what the consumer actually does.** Fetch the generated client assets and open the
  WebSocket, not just `/health`: an upgrade can fail where a plain GET succeeds. Where the WebSocket
  client type is unavailable, report that check as **unsupported** rather than folding it into a
  pass.
- **Judge the whole consumer path, not the index page.** Require the page, the generated client
  assets and the requested WebSocket to succeed on the configuration you claim works; a 200 on `/`
  hides a broken asset route or a refused upgrade. Distinguish *required* legs (the documented
  working configuration) from *observational* ones (the bind whose failure IS the boundary), and
  report a missing observation as **unknown** rather than as a confirmed boundary.
- **Normalize and bound the cross-OS subprocess.** Windows processes emit CRLF, so strip it once
  before parsing or a real `Win32NT\r` gets rejected as a non-Windows origin; and wrap each interop
  invocation in a wall-clock timeout (falling back to the probe's own per-operation bound) so a
  wedged interop path cannot hang the run.
- **Fail loudly on an unsupported host.** If the environment cannot host the real boundary (no WSL,
  no interop, no Windows PowerShell on a Windows mount), exit nonzero with the reason. A synthetic
  `wsl.exe`/`powershell.exe` shim on the guest filesystem is a test double for the harness's own
  failure paths — never field evidence.
- **CI caveat.** GitHub-hosted Linux runners have no Windows interop and Windows runners have no WSL
  distro, so this check cannot be a hosted CI gate. Keep the portable half
  (`scripts/test-wsl-boundary-harness.sh`) in CI and run the real boundary check manually, or on a
  self-hosted Windows+WSL runner. Do not mark the boundary "verified" from a Linux-only run.

**Provenance:** `[learn]` issue `agent-frontier/wgm#101` — a service published on WSL loopback was
not reachable through the host's Windows interop path, while the same disposable service published
on all interfaces was reachable at the WSL IPv4 address. **Landed in:**
`scripts/test-wsl-windows-boundary.sh`, `scripts/test-wsl-reachability.ps1`,
`scripts/test-wsl-boundary-harness.sh`. **Open validation requirement:** the harness's own failure
paths are covered on any host, but the Windows-origin leg is still awaiting a run on a Windows+WSL
machine — until an operator records that run, treat the boundary result as unverified here.

## Cross-links
[`ralph-loop.md`](ralph-loop.md) (backpressure in depth) · [`scoring.md`](scoring.md) (holdout
satisfaction when no deterministic check fits) · [`validation-env.md`](validation-env.md)
(containerized runs) · [`stall-recovery.md`](stall-recovery.md)
