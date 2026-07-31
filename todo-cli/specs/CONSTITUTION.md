# Constitution: Todo CLI

## Principles
1. **Code quality** — Keep command parsing, persistence, and presentation small, explicit, and typed.
2. **Testing** — Every command and each user-facing error class (parser, input, read, validation, write, lifecycle) must have automated coverage.
3. **Security & privacy** — Store only todo text and state; reject malformed persisted data rather than guessing.
4. **UX & consistency** — Commands produce concise output, errors go to stderr, and failures return non-zero.
5. **Performance** — Loading and sorting 10,000 valid local todos must complete within five seconds.

## Non-negotiables
- Existing todos must survive separate CLI invocations.
- The app must have no third-party runtime dependencies.
- The JSON store has single-writer semantics; concurrent mutation is unsupported and documented.

## Tech constraints
- **Must use:** Python 3.10+ standard library.
- **Must avoid:** Network services and external databases.
- **Deployment target:** macOS, Linux, and Windows terminals.

## Recording deviations

| Date | Principle | Why we deviated | Scope |
|---|---|---|---|

**Version**: 1.0 | **Ratified**: 2026-07-31 | **Last Amended**: 2026-07-31
