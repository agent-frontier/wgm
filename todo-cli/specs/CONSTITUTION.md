# Constitution: Todo CLI

## Principles
1. **Code quality** — Keep command parsing, persistence, and presentation small, explicit, and typed.
2. **Testing** — Every command and user-facing error must have automated integration coverage.
3. **Security & privacy** — Store only todo text and state; reject malformed persisted data rather than guessing.
4. **UX & consistency** — Commands produce concise output, errors go to stderr, and failures return non-zero.
5. **Performance** — Operations must remain responsive for at least 10,000 local todos.

## Non-negotiables
- Existing todos must survive separate CLI invocations.
- The app must have no third-party runtime dependencies.

## Tech constraints
- **Must use:** Python 3.10+ standard library.
- **Must avoid:** Network services and external databases.
- **Deployment target:** macOS, Linux, and Windows terminals.

## Recording deviations

| Date | Principle | Why we deviated | Scope |
|---|---|---|---|

**Version**: 1.0 | **Ratified**: 2026-07-31 | **Last Amended**: 2026-07-31
