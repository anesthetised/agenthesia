# Architecture

This document describes how Agenthesia is built. Decisions and their rationale live in
[ADRs](adr/); this is the map.

## Repository layout

```
agenthesia/
├── App/                        # App target: @main, assets, Info.plist, entitlements
├── Agenthesia.xcodeproj        # Thin: one app target + the local package
├── Packages/AgenthesiaKit/     # All logic and UI, as a Swift package
│   ├── Sources/<Module>/
│   ├── Tests/<Module>Tests/
│   └── Resources/acp-schema/   # Pinned ACP schema (reference + conformance tests)
└── docs/                       # Vision, architecture, ADRs
```

The Xcode project only exists for what SwiftPM cannot do: the app bundle, signing, entitlements and
assets. Everything else is in `AgenthesiaKit`, which builds and tests with plain `swift build` /
`swift test`.

## Modules

Listed bottom-up. A module may only depend on modules above it in this list.

| Module | Responsibility | Depends on |
|---|---|---|
| `JSONRPC` | JSON-RPC 2.0 over newline-delimited streams. `Connection` actor: request/response correlation, in-order dispatch of incoming requests and notifications, `$/cancel_request`, `-32601` for unknown methods. `Router` for typed handlers; file-handle and in-memory transports. Knows nothing about ACP. | — |
| `ACP` | Hand-written `Codable` wire types: shared types in `ACP`, v1-only envelopes and capabilities in `ACP.V1`. Typed v1 client and delegate for agent→client requests. The version-agnostic `AgentConnection` protocol and the v1 adapter that implements it. | `JSONRPC` |
| `ACPTesting` | Test support: scenario engine (`ScenarioAgent`), reactive `EchoAgent`, JSON subset matching. Used by tests and `MockAgent` only. | `ACP` |
| `AgentRuntime` | Login-shell environment resolution, agent process lifecycle, ACP Registry client, installers (binary, npm), managed Node runtime. | `ACP` |
| `Workspace` | Git (CLI wrapper), worktrees, PTYs, `TerminalHost` (ACP `terminal/*`, including long-lived background processes), file index for Quick Open, FSEvents watcher. | — |
| `Persistence` | SQLite via GRDB: projects, agent installs, sessions and the append-only event log. | — |
| `Rendering` | Text rendering shared by the transcript, diffs and the file viewer: tree-sitter highlighting, incremental Markdown, `SourceView` (STTextView, TextKit 2), `DiffView` ([ADR-0007](adr/0007-transcript-rendering.md)). Source highlighting updates only color attributes ([ADR-0013](adr/0013-source-highlight-attributes.md)). | — |
| `AgenthesiaCore` | Domain: sessions, transcript reducer, permission queue, fs path policy, session manager, worktree lifecycle. | all of the above except `Rendering` |
| `AgenthesiaUI` | SwiftUI and AppKit views. | `AgenthesiaCore`, `Rendering` |
| `acp-cli` | Headless debug driver: `chat`, `sessions` and `login` against any ACP agent from a terminal. | `ACP`, `AgentRuntime`, `Workspace` |
| `MockAgent` | ACP agent over stdio: the echo agent, or a JSON scenario with `--scenario`. | `ACPTesting` |
| `rendering-bench` | Release-build timings of Markdown rendering and highlighting (`just bench`). | `Rendering` |

## Current interface preview

`AgenthesiaUI` contains a temporary demo session model and a native session screen. The screen uses
an `NSTableView` transcript with a TextKit 2 streaming row, following ADR-0007, and the existing
`Rendering` module. The debug Rendering Lab remains independent so its recorded workloads are not
changed by the interface preview.

The demo does not launch agents, modify a workspace, or persist sessions. It disables sending while
streaming; it does not implement or supersede ADR-0010's production queue and steering behavior.
`AgenthesiaCore` and `Persistence` are still placeholders. The data flow below describes the intended
live-session architecture, not functionality supplied by the demo.

## Data flow

```
agent process ──stdout──▶ JSONRPC.Connection ──▶ ACP v1 adapter ──▶ AgentConnection events
     ▲                                                                        │
     └──stdin── requests (prompt, cancel, …)                                  ▼
                                                   SessionController (MainActor, @Observable)
                                                    ├─ appends events to Persistence (event log)
                                                    ├─ reduces events into TranscriptState
                                                    └─ answers agent requests (permissions, fs,
                                                       terminals, elicitation) via the UI
                                                                              │
                                                                              ▼
                                                                     AgenthesiaUI views
```

- One agent process per session ([ADR-0004](adr/0004-agent-runtime.md)).
- The event log is the source of truth for what is displayed; raw ACP updates are stored so old
  sessions can be re-rendered when the renderer improves ([ADR-0005](adr/0005-event-log.md)).
- Streaming chunks are coalesced once per frame before they reach the UI.
- **Ordering invariant:** `Connection` processes incoming messages strictly in arrival order. A
  notification handler finishes before the next message is looked at, so anything a request refers to
  (for example the `tool_call` a `session/request_permission` is about) has been handled when the request
  handler starts. Request handlers then run concurrently.

## Concurrency

- Swift 6 language mode with complete strict concurrency checking.
- I/O lives in actors (`JSONRPC.Connection`, process and PTY wrappers).
- Everything the UI observes is `@MainActor @Observable`. Actors publish to it through `AsyncStream`s.
- No `@unchecked Sendable` without a comment explaining why it is safe.

## Protocol version strategy

Only ACP v1 is implemented. v2 is an unstable draft that drops client-side `fs/*`, `terminal/*`,
`session/load`, modes and `authenticate`. Core therefore talks to a version-agnostic `AgentConnection`
built on the methods v1 and v2 share. Everything v1-only is contained in the v1 adapter
([ADR-0003](adr/0003-own-acp-implementation.md)).

## Dependencies

All third-party code must be under a GPLv3-compatible license. GPLv2-only and proprietary libraries are
not allowed (Apple system frameworks are fine).

| Dependency | License | Used by |
|---|---|---|
| [GRDB](https://github.com/groue/GRDB.swift) | MIT | `Persistence` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | `AgenthesiaUI` |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) (with swift-cmark, BSD-2-Clause) | Apache-2.0 | `Rendering` |
| [STTextView](https://github.com/krzyzanowskim/STTextView) (with STTextKitPlus, BSD-3-Clause, and CoreTextSwift, MIT) | GPL-3.0 or commercial; used under GPL-3.0 | `Rendering` |
| [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) (with tree-sitter, MIT) | BSD-3-Clause | `Rendering` |
| tree-sitter grammars: Swift, TypeScript/TSX, JavaScript, Python, JSON, Markdown, Bash, Rust, Go, YAML | MIT | `Rendering` |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | `acp-cli` |
| [Sparkle](https://sparkle-project.org) (later) | MIT | App |

Dependencies are added when the milestone that needs them starts, not up front.

### Pinning notes

- **Grammars** are pinned to exact versions: grammar releases change node names, which breaks highlight
  queries.
- **JavaScript, Python and YAML grammars come from forks** (`anesthetised/tree-sitter-{javascript,python,yaml}`,
  branch `swift-scanner`, pinned by revision). Each is the upstream release tag plus one manifest change:
  `src/scanner.c` is always in `sources`. Upstream manifests check for the scanner with a relative
  `fileExists`, which fails under Xcode 27 and drops the scanner from the build. Upstream PRs
  (tree-sitter-javascript#383, tree-sitter-yaml#46) are open; tree-sitter-python waits for manifests
  regenerated with tree-sitter 0.27, whose template is fixed. **Switch each grammar back to upstream once a
  release includes the fix, then delete the fork**; the forks must stay public until then.
- **SwiftTreeSitter moved** from ChimeHQ/SwiftTreeSitter to tree-sitter/swift-tree-sitter, and grammars
  refer to both URLs. The package depends on the old URL and `.swiftpm/configuration/mirrors.json` (with a
  copy for Xcode in the workspace's `xcshareddata/swiftpm/configuration/`) maps the new one to it, so
  SwiftPM sees one package.
