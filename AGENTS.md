# Agent guidelines

Guidelines for AI agents (and humans) working in this repository.

## Project

Agenthesia is a native, opinionated macOS client for coding agents built on the Agent Client Protocol
(ACP). Before making design decisions, read:

- [docs/VISION.md](docs/VISION.md) — product principles; they decide what goes in.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — modules, data flow, concurrency.
- [docs/adr/](docs/adr/) — accepted decisions. Do not contradict an ADR silently: propose a new one
  that supersedes it.
- [docs/PLAN.md](docs/PLAN.md) — the order of upcoming work and known pitfalls; update it when a step
  lands.

Consult the user before implementing architectural decisions. Present alternatives and their trade-offs,
recommend an approach, and challenge proposals when there are concrete reasons to disagree. Agents with
a structured question tool (e.g. `AskUserQuestion`) use it for these consultations, batching the open
decisions into one call with the recommended option first.
Recommend when to switch reasoning effort and which level to use for the upcoming work.
When recommending agents or planning work, respect the model tiers. Codex agents use Sol (**light**) and
Astra (**strong**); Claude agents use Sonnet (**light**) and Opus (**strong**). Both tiers run at High effort.
Use available skills when appropriate, especially `ponytail` for keeping coding solutions simple and
avoiding unnecessary complexity. When writing or changing SwiftUI or AppKit views, also run `swiftui-pro`
over them before committing.

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

Documentation, test coverage and benchmarks are important. Keep documentation aligned with changes.
For performance-sensitive changes, run the relevant benchmarks before and after the change and report
the results; add a benchmark when the changed path is not covered by an existing one.
Obtain the user's approval before running benchmarks; agree on the workload and resource cost first.

To try the protocol layer by hand: `just cli chat -- <agent command>`, or `just mock-chat` for the bundled
`MockAgent`.

### Testing the running app

Automated tests cover logic and hosted views; what only the real app shows (system prompts, banners, the
Dock, menus, window opening and restoration) is checked in the built app, with the bundled `MockAgent` as
the agent so no real agent or tokens are involved.

- **Prefer computer use.** When the session has computer-use tools, drive `just run`'s app with them and
  save screenshots as evidence. Request access for Agenthesia and any system surface involved, such as
  Notification Center or System Settings.
- **Without computer use**, script the app and say so. `osascript` with System Events reads the
  accessibility tree and sets field values; a small CGEvent tool posts clicks (a right-click does not
  show in the tree, so check `CGWindowListCopyWindowInfo`); `screencapture -x` takes screenshots. Run the
  action and the screenshot in one command, because other apps take focus between commands. Keys and
  clicks go to whichever app is frontmost, so activate Agenthesia first and verify it before sending input.
- **Ask the owner to leave the machine alone** while a scripted or computer-use check runs, and state
  when it ends. Never type into the owner's apps, and never touch their real data: use a temporary
  directory and, for history, a copy or a clearly marked temporary row removed afterwards.
- Windows restore after relaunch only with System Settings → Desktop & Dock → *Close windows when quitting
  an application* turned off; tell the owner when the setting can be restored.
- Record what was checked, what was not (VoiceOver, system prompts) and how in PLAN.md.

## Git

- Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `chore:`,
  `refactor:`, `test:`, `ci:`, `perf:`, `build:`. An optional scope is the module name, e.g.
  `feat(acp): …`.
- When a commit or pull request closes an issue, include `Closes #<n>` in its message or description;
  use `Refs #<n>` when it only contributes to one.
- Add a co-author trailer for the agent, e.g. `Co-Authored-By: <Agent Name> <email>`.
- Committing is fine at any time. **Never push** unless explicitly asked to.
- Track substantial changes in issues and implement them on separate branches. Obtain the user's
  approval before opening a pull request; pushing still requires an explicit request.
- Keep issues accurate: apply labels and a milestone, tick checkboxes as their items land, and link
  commits and pull requests with `Closes`/`Refs`.
- When planning work, label each issue with its model tier (`agent:light` or `agent:strong`).

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
