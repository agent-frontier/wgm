# Local / small-context models — a token-input budget playbook

Hosted frontier models routinely offer 100k–1M+ tokens of input context. A locally-hosted model
(Ollama, llama.cpp, LM Studio, vLLM, etc.) often has far less — commonly **~65k tokens or fewer**.
wgm's defaults (context-rotation thresholds, memory budgets, track ceremony) are calibrated against
the larger end of that range. This file tightens each lever for a small, hard input-token ceiling.
It extends `references/ralph-loop.md`'s "Context rotation" section — read that first.

## Why it matters (measured, not guessed)
In this repo alone, tokenized with `tiktoken` (`cl100k_base`) rather than a word-count guess —
markdown prose with backticks/identifiers/punctuation tokenizes 25–40% denser than a naive
words-to-tokens conversion: `SKILL.md` is **~7,000 tokens**, and all of `references/*.md` combined is
**~51,600 tokens** — reading both wholesale is **~90% of a 65k budget**, before ever opening the
plan, spec, or actual code. A realistic single-iteration read set — `SKILL.md` plus 1–2 relevant
references — lands at roughly **12–13k tokens (≈20%)**, which is the actual target below. The single
biggest lever for a small-context run is which files get read at all, not just how they're written.
**These figures are a point-in-time measurement** (as of commit `96ee54a`, 2026-07-09) that will
drift upward as `SKILL.md`/`references/*.md` grow — a prior revision of this file cited figures that
were already ~3% stale by the very next PR. **Measure your own footprint the same way** (see "Measure
it, don't guess" below) rather than trusting either this snapshot or a word-count estimate — both
undercount over time.

## Read narrow, not wide (Analyze discipline)
`ralph-loop.md` already says "read only what you need" — on a 65k model, make that a hard budget,
not a vibe:
- **Budget ~15–20% of the window for skill + reference material** (≈10–13k tokens on 65k). That's
  roughly `SKILL.md` plus the **1–2 references actually relevant to this iteration's phase or task**
  — not a sweep of the whole `references/` directory.
- Pick references by task, not by curiosity: a `build`-mode iteration on a normal task needs
  `ralph-loop.md` at most; it does not need `PLUGIN_PROTOCOL.md`, `gene-transfusion.md`, or
  `docs-audit.md` unless the task actually touches those concerns.
- Prefer `grep`/targeted `view_range` reads over opening a whole file — the same discipline this CLI
  already asks of large files applies doubly to a small-context model, and to code files as much as
  to wgm's own docs.

## Prefer Ralph-full even more strongly
`ralph-loop.md` already prefers Ralph-full (`scripts/loop.sh`, a fresh subprocess per iteration) over
Ralph-lite (one long in-session run) whenever a headless agent invocation exists. On a 65k model this
preference is closer to load-bearing than optional: a long-lived interactive session accumulates
transcript (every prior tool call, every prior file read) turn over turn, and a 65k window fills in a
fraction of the turns a 200k+ one would tolerate. Ralph-full's fresh-process-per-iteration resets that
accumulation to zero every time, so the fixed "skill + plan + spec" overhead stays the *only* thing
paid repeatedly, not the whole history.

## Default to Quick/Standard track
The Triage track table (`SKILL.md`) already scales ceremony to the work. On a small-context model,
treat that scaling as a token-budget decision too, not just an effort one:
- **Full track's extra ceremony — holdout scenarios, stratified scoring, containerized validation, a
  baseline docs-audit pass — means more files an iteration may need to open** (scenario YAML,
  container logs, docs-audit persona reports). Reserve Full for builds that truly need it.
- Quick/Standard, with their leaner artifact set and deferred/optional docs-audit swarm, keep the
  per-iteration file surface smaller by construction.

## Rotate earlier than the generic default
`ralph-loop.md`'s "Context rotation" section picks "~50% of the window" as a practical default
threshold. On a small window, that default under-rotates: the fixed overhead (skill + plan + spec +
memories) is a *larger proportion* of a 65k budget than of a 200k one, so there's less room left for
the actual task before quality degrades ("lost in the middle" effects bite sooner in a crowded small
window, not just a full one).
- **Concrete number:** for a ~65k-token model, rotate at **~35–40% of the window (≈23–26k tokens)**,
  not ~50%. Treat crossing it as a hard stop, exactly as `ralph-loop.md` already prescribes.
- Ralph-full rotates every iteration by construction, which already satisfies this for most builds;
  the tighter number chiefly matters for Ralph-lite runs or single long iterations (a big Analyze
  pass, a large refactor) on a small-context model.

## Tighter memory and state budgets
- **Shrink `.wgm/memories.md`'s budget.** `ralph-loop.md`'s flat-log default targets ~2000 tokens —
  reasonable against a large window, but ~3% of a 65k one is still real weight paid every iteration.
  Target **~600–800 tokens** instead, trimming the oldest lessons more aggressively.
  `references/memory-patterns.md`'s structured alternatives (Beads-style, layered memory) exist for
  *long* builds outgrowing the flat log — don't reach for them here; they add files to read, which
  works against a small budget. Keep the flat log, just make it leaner.
- **Use TOON encoding for agent-only state** (`references/artifacts.md`) wherever it applies — single-
  token-key serialization for `.wgm/` files (memories, scores, plugin state) is a direct token-count
  win, and matters more on a small window than a large one.

## Smaller task granularity
Scope `IMPLEMENTATION_PLAN.md` tasks to touch as few files/areas as practical. A task's Analyze step
only needs to read the files *that task* names — a task scoped to 1–2 files costs far less context
than one spanning ten, independent of how well-written the docs are. On a 65k model, prefer splitting
a broad task into two narrower sequential ones over accepting one iteration that must read broadly.

## Keep project-wide gates short
`wgm.yml` (or `.wgm/gates.yml`) gate commands are inlined **verbatim, in full, into every build
prompt** by `scripts/loop.sh` — they are paid every single iteration, not once. Prefer one aggregate
command (e.g. a `make check` that itself runs typecheck+test+lint) over listing five separate ones;
the gate list's token cost is otherwise multiplied by every iteration of the whole build.

## Repurpose frugal/main as a context-size tier, not just a cost tier
`scripts/loop.sh --frugal-agent`/`--agent` (`docs/operator/running-the-loop.md`) and
`stall-recovery.md`'s model escalation are framed around cost (cheap vs. powerful). The same
mechanic doubles as a **context-size** tier:
- Set the **local, small-context (~65k) model as `--frugal-agent`** (or the sole `--agent`, if no
  escalation path exists) for routine, narrowly-scoped iterations — most of the loop.
- Reserve a **larger-context hosted model as the escalation `--agent`** for a stall, or for a task
  that is genuinely wide (a repo-wide rename, a cross-cutting refactor touching many files) and
  cannot be shrunk to fit the local model's window without losing the point of doing it in one pass.
- This is the same `--escalate-after`/`--downgrade-after` wiring already in `loop.sh` — no new flags
  needed, only a different reason to reach for them.

## Tool-output hygiene
Verbose command output competes with everything else for the same small window:
- Pipe build/test/lint output through `grep`/`head`/`tail`; pass quiet/silent flags where available.
- Prefer `grep` with a glob, or a targeted `view_range`, over opening a whole large file — this
  applies to source and log files being inspected mid-iteration, not just wgm's own docs.
- Avoid running a project-wide formatter or verbose diff mid-iteration (`ralph-loop.md`'s "format
  only what you touched" already says this; it's doubly true when every line of output is budget).

## Measure it, don't guess
A word-count estimate of a file's token cost is unreliable — markdown-dense prose (backticks, code
identifiers, punctuation) tokenizes 25–40% denser than plain words (see the corrected numbers above:
an earlier word-count pass under-estimated this repo's own footprint by roughly that margin). Two
concrete ways to get a real number instead of a guess:
- **One-off:** tokenize any file with a real tokenizer before trusting a budget claim about it —
  first `pip install tiktoken`, then for example
  `python3 -c "import tiktoken; print(len(tiktoken.get_encoding('cl100k_base').encode(open('FILE').read())))"`.
  It's a proxy (your local model's own tokenizer will differ somewhat), but it's far closer than a
  word count, and it's what produced every number in this file.
- **Per-iteration, ongoing:** wire `scripts/loop.sh --cost-cmd` to your local server's own reported
  prompt-token count so the ~65k ceiling is tracked empirically across the whole build, not assumed
  once and forgotten. Most local servers already report it:
  - **Ollama** (`/api/generate`, `/api/chat`): the final JSON response includes `prompt_eval_count`
    — the exact number of input tokens it just evaluated.
  - **llama.cpp server** (`/completion`): the response includes `tokens_evaluated` (and
    `timings.prompt_n`) for the same thing.
  Point `--cost-cmd` at a small script that greps the last response for that field, pass
  `--metrics FILE` to log it every iteration, and optionally `--max-cost` as a hard ceiling once you
  know the real per-iteration number (`docs/operator/running-the-loop.md`, "Pattern: a token/cost
  TUI"). This closes the loop between *this file's* guidance and *your* actual build.

## Structure prompts for KV-cache reuse
Beyond the raw input-token count, local inference servers (Ollama, llama.cpp) cache the model's
internal state for a prompt **prefix** and can reuse it on the next call if that prefix is
byte-identical — skipping re-computation for everything before the first changed token. This doesn't
shrink the nominal token count, but it shrinks the *compute* actually paid per iteration, which
matters as much as the budget on constrained local hardware:
- **Keep the fixed part of the prompt first, and byte-identical, across iterations** — the skill
  instructions, `specs/CONSTITUTION.md`, `AGENTS.md` — so the cache hits.
- **Put the varying part last** — the current task, the plan's diff, this iteration's specific
  files — so only the genuinely new tail has to be (re-)evaluated.
- Avoid needlessly reformatting or reordering the fixed prefix between iterations (e.g. rewriting
  `AGENTS.md`'s wording without a real content change) — it invalidates the cache for no benefit.
- `scripts/loop.sh` already constructs one prompt template per run and only substitutes small pieces
  per iteration (mode, task, plan reference) — the substituted pieces are near the *end* of the
  template, which is already cache-friendly; don't undo this by hand-editing the flow to front-load
  variable content.

## Swarm concurrency on a single local backend
`scripts/swarm.sh` fans out parallel streams (worktrees + branches) assuming each stream gets its own
real compute. Against **one** locally-hosted model server, concurrent streams usually queue for the
same backend rather than truly parallelizing, and each stream still owes its own full ~65k-budget
prompt — so a wide swarm can cost more wall-clock time than sequential `loop.sh` runs, not less.
Prefer `swarm.sh -n 1`–`2` (or plain sequential `loop.sh` calls) against a single local model; reserve
a wider swarm for when you actually have multiple independent backends (several local model
processes, or a mix of local + hosted agents) to spread the streams across.

## Known limitation: SKILL.md's fixed load cost
Track selection (Quick/Standard/Full) governs what an iteration reads *afterward*, not what loading
the skill itself costs — `SKILL.md`'s full ~6.8k tokens load on every invocation regardless of mode
or track, including a one-line Quick-track fix. This is a property of how the skill is loaded, not
something a task or a `wgm.yml` can opt out of — budget for it as a fixed, unavoidable cost rather
than expecting it to shrink with a smaller task.

## Cross-links
`references/ralph-loop.md` (Context rotation, Standing guardrails) ·
`references/memory-patterns.md` (memory budget alternatives) ·
`references/artifacts.md` (TOON encoding) ·
`references/stall-recovery.md` (frugal/main escalation) ·
`references/subagents.md` (Model selection — the same frugal/main flag pair, along the cost axis
rather than this file's context-size axis) ·
`docs/operator/running-the-loop.md` (`--frugal-agent`/`--agent` flags, `--cost-cmd`/`--metrics`,
the swarm).
