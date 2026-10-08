# Agenthesia

[![CI](https://github.com/anesthetised/agenthesia/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/anesthetised/agenthesia/actions/workflows/ci.yml)
[![Coverage](https://raw.githubusercontent.com/anesthetised/agenthesia/badges/coverage.svg)](https://github.com/anesthetised/agenthesia/actions/workflows/ci.yml)

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

Cross-agent memory is deferred until after the MVP ([ADR-0012](docs/adr/0012-defer-cross-agent-memory.md)).

See [docs/VISION.md](docs/VISION.md) for the principles behind the product and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is built.
Rendering workloads, metrics and repeatable measurements are described in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Live sessions

The app opens a native session screen. Choose a project directory and an installed ACP agent command;
enter literal arguments one per line (blank lines are ignored; spaces are preserved). Project and
executable paths accept `~` for your home directory. Agents must already be authenticated. Git projects receive a fresh
`agenthesia/<uuid>` branch and worktree under `~/.agenthesia/worktrees`; only committed HEAD content is
copied. Non-Git directories are used directly. Worktrees remain on disk after closing, including failed
startup, so changes are not discarded.

Enter or Command-Return sends a text prompt while idle; Shift-Return inserts a newline and Command-period
stops the turn. You can draft the next message while the agent works; queueing and steering are still
planned. The Agent Log button shows bounded stderr output. End Session, window close, and app quit
close ACP, finish pending event writes, and terminate the agent process group.

Sessions are stored in `~/Library/Application Support/Agenthesia/history.sqlite`. The sidebar opens
saved transcripts read-only after a restart. Agent reconnection, interactive permission cards, client
filesystem/terminal tools, and attachments are not yet connected. Permission requests are rejected;
only implemented client capabilities are advertised. Tool calls currently show their title and status.
Worktree review, merge, and discard controls remain separate work.

For a local smoke test, build with `just test`, then point the app at the package's built `MockAgent`
executable (the build directory depends on the Swift toolchain). Try `hello`, `slow`, `think`, or `fail`.
The ACP command-line client remains available via `just cli` and `just mock-chat`.

## Requirements

- macOS 26 or later, Apple silicon.
- Building from source: Xcode 27 (Xcode 26.x works for now).

## Building

Tasks are defined in the [`justfile`](justfile) (`brew install just`):

```sh
just build   # build the core package
just test    # run package tests
just coverage  # run tests with coverage thresholds
just lint    # check formatting
just app     # build the app with xcodebuild
just run     # build and launch the app
just cli chat -- <agent>  # talk to any ACP agent from the terminal
just mock-chat            # try it with the bundled mock agent
```

The CLI resolves the login-shell environment once and passes it to the agent and terminal
authentication. If resolution fails or times out, it warns and uses a fallback environment. Add
`--agent-log` before `--` to stream the agent's stderr; up to the last ten retained lines are also included
when an agent exits before initialization. Process shutdown cleans up its process group, including
descendants that outlive the agent.

Coverage measures Swift sources in the package, including product UI. The badge and product total
exclude test support (`ACPTesting`, `MockAgent`) and the debug-only `AgenthesiaUI/Lab/` directory;
these are still reported separately, with the latter labeled `RenderingLab`. Per-module thresholds
remain enforced by `just coverage`.

## License

[GPL-3.0](LICENSE)
