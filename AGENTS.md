# Agent guidelines

Guidelines for AI agents (and humans) working in this repository.

## Project

Agenthesia is a native, opinionated macOS client for coding agents built on the Agent Client Protocol
(ACP). Before making design decisions, read:

- [docs/VISION.md](docs/VISION.md) — product principles; they decide what goes in.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — modules, data flow, concurrency.
- [docs/adr/](docs/adr/) — accepted decisions. Do not contradict an ADR silently: propose a new one
  that supersedes it.

## Language

Everything in the repository and on GitHub is written in English: code, comments, documentation,
commit messages, issues and pull requests.

## Commands

All tasks go through the [`justfile`](justfile). Run `just` to list recipes.

- `just build` — build the package.
- `just test` — run package tests.
- `just coverage` — run tests with coverage and enforce per-module thresholds (what CI runs).
- `just lint` — check formatting (`swift format lint --strict`).
- `just format` — format the code in place.
- `just app` — build the app with `xcodebuild`.
- `just run` — build and launch the app.
- `just bench` — time Markdown rendering and highlighting in a release build (not run in CI).

Before committing, make sure `just lint` and `just test` pass. New code comes with tests; keep coverage
above the thresholds in the `justfile`.

To try the protocol layer by hand: `just cli chat -- <agent command>`, or `just mock-chat` for the bundled
`MockAgent`.

## Git

- Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `chore:`,
  `refactor:`, `test:`, `ci:`, `perf:`, `build:`. An optional scope is the module name, e.g.
  `feat(acp): …`.
- When a commit or pull request closes an issue, include `Closes #<n>` in its message or description.
- Add a co-author trailer for the agent, e.g. `Co-Authored-By: <Agent Name> <email>`.
- Committing is fine at any time. **Never push** unless explicitly asked to.

## Code

- Swift 6 language mode, complete strict concurrency. No `@unchecked Sendable` or
  `nonisolated(unsafe)` without a comment explaining why it is safe.
- Logic lives in `Packages/AgenthesiaKit`; the app target in `App/` stays thin.
- Respect module dependency direction as listed in ARCHITECTURE.md.
- Format with `swift format` (configuration in `.swift-format`).
- New behavior comes with tests (Swift Testing).
- Match the surrounding code: naming, comment density, idioms.

## Dependencies

- Third-party code must be under a GPLv3-compatible license (MIT, BSD, Apache-2.0, ISC, zlib, LGPL,
  GPL-3.0). GPLv2-only and proprietary libraries are not allowed; Apple system frameworks are fine.
- Add a dependency only when the milestone that needs it starts, and list it in ARCHITECTURE.md.
