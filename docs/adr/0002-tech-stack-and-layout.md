# 0002. Tech stack and project layout

- Status: Accepted
- Date: 2026-10-05

## Context

The product's main differentiator is a native, polished macOS interface. It is built by a single
developer, so tooling must stay simple.

## Decision

- **UI:** SwiftUI, with AppKit wherever SwiftUI falls short (transcript, text views, terminal).
- **Language:** Swift 6 language mode with complete strict concurrency checking.
- **Platform:** macOS 26 or later, Apple silicon only. Built with the current Xcode (27); availability
  checks for anything newer than macOS 26.
- **Layout:** all code in the local Swift package `Packages/AgenthesiaKit`. A thin `Agenthesia.xcodeproj`
  holds only the app target, using file-system-synchronized folders. No project generators (Tuist,
  XcodeGen).
- **Distribution:** Developer ID signing, Hardened Runtime and notarization; Sparkle for updates;
  Homebrew cask. **No App Sandbox**: a sandboxed app cannot launch agents that run arbitrary tools,
  which rules out the Mac App Store.
- **Formatting and linting:** the toolchain's built-in `swift format`. No other linters.
- **Task runner:** a `justfile` at the repository root is the single entry point for build, test, lint
  and run, for humans, agents and CI alike.

## Consequences

- Packages build and test without Xcode (`swift build`, `swift test`), which keeps CI and agents simple.
- Dropping Intel and macOS < 26 removes compatibility work and lets us use current APIs freely.
- Without the sandbox, the app carries more responsibility for what agents can touch; see the path
  policy in [0009](0009-tools-and-mcp.md).
