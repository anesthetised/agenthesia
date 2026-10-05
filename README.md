# Agenthesia

A native, opinionated macOS client for coding agents.

Agenthesia speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP), so it works with
any ACP-compatible agent — Claude, Codex, Gemini CLI and many more. It does not ship its own agent:
it is the place where you start agents, watch them work, answer their questions, review their changes
and accept the result.

> **Status:** early development. Nothing to install yet.

## Highlights (planned for 1.0)

- **Any agent, one interface.** One-click install from the ACP Registry; agents are interchangeable.
- **Parallel sessions.** Run several agents side by side, each in its own process.
- **Isolated by default.** Every session in a git repository gets its own worktree; review the diff,
  then squash-merge or discard.
- **Built for review.** Diffs, files and Markdown with syntax highlighting; Quick Open for everything else.
- **Truly native.** SwiftUI and AppKit, keyboard-first, actionable notifications, no web views.

See [docs/VISION.md](docs/VISION.md) for the principles behind the product and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is built.

## Requirements

- macOS 26 or later, Apple silicon.
- Building from source: Xcode 27 (Xcode 26.x works for now).

## Building

Tasks are defined in the [`justfile`](justfile) (`brew install just`):

```sh
just build   # build the core package
just test    # run package tests
just lint    # check formatting
just app     # build the app with xcodebuild
just run     # build and launch the app
```

## License

[GPL-3.0](LICENSE)
