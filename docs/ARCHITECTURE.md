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
| `AgenthesiaUI` | SwiftUI and AppKit views. | `ACP`, `Persistence`, `AgenthesiaCore`, `Rendering` |
| `acp-cli` | Headless debug driver: `chat`, `sessions` and `login` against any ACP agent from a terminal. | `ACP`, `AgentRuntime`, `Workspace` |
| `MockAgent` | ACP agent over stdio: the echo agent, or a JSON scenario with `--scenario`. | `ACPTesting` |
| `rendering-bench` | Release-build timings of Markdown rendering and highlighting (`just bench`). | `Rendering` |
| `persistence-bench` | Release-build append throughput and latency (`just bench-persistence`). | `Persistence` |
| `session-bench` | Release-build transcript reduction and snapshot publication (`just bench-session`). | `AgenthesiaCore` |

## Live app integration

The main window uses a window-bound `LiveSession` in Core to own the agent process and
`SessionController` ([ADR-0014](adr/0014-window-bound-live-sessions.md)). `SessionLibrary.shared` opens
one app database away from the main actor and provides project, install, and saved-session discovery.
The owner resolves the login-shell environment, checks that the agent executable exists (so a typo
leaves no worktree behind), prepares the workspace, creates metadata, and starts
the ACP v1 adapter with filesystem, terminal, terminal-auth, and elicitation capabilities disabled.
Agents must already be authenticated; authentication failures are displayed.

`Workspace.SessionWorkspace` invokes the Git CLI on a Dispatch queue, outside the cooperative pool, and
reads its errors from stderr only. Git checkouts get a new branch and worktree from HEAD under
`~/.agenthesia/worktrees/<repo>/<uuid>`; a selected subdirectory maps to the same path in the worktree.
After resolving symlinks, that path must be a directory inside the new worktree. Dirty and untracked files are not copied.
Non-Git directories are used directly; bare, broken, or unborn repositories fail explicitly. Worktrees
are retained after close or failed startup. Review, merge, discard, and richer worktree metadata remain
part of the worktree milestone.

`AgenthesiaUI` owns presentation and window integration. Its shared `TranscriptTableController` uses
`NSTableView`, with TextKit 2 for streaming messages. `LiveTranscriptSource` lazily renders requested
rows, caches attributed text, and handles updates to earlier rows as well as appended messages.
`SessionFrameDriver` publishes committed transcript snapshots from the display link. Saved transcripts
use the same table in read-only mode. The demo remains available as a test fixture; the original
Rendering Lab prototypes retain their implementations, with an additional production-table variant.

The composer accepts text prompts while idle and keeps drafts editable during a turn. Queueing and
steering remain #65. Tool rows are cards: a native header (kind symbol, kind, status, disclosure) and a
Markdown body with the title, reported locations and text content, so selection and copying work as
for messages. Missing fields are shown as not reported; diff, terminal and unsupported content appear
as placeholders until #20 and #31. Bodies beyond 12 lines or 2,000 characters are collapsed; expansion
is keyed by row identity and survives streamed updates. Header-only updates preserve the body and its
text selection. Truncated code blocks retain their fence delimiter when closed before the truncation note.
Permission requests are rejected pending #21; cards state only the recorded outcome (cancelled or the
selected option identifier), never an inferred approval or decline. Non-text content is identified
with attachment placeholders rather than silently dropped.
The session's bounded stderr log and environment diagnostics are visible in the window.

A window-close notification starts asynchronous owner shutdown. An AppKit application delegate retains
a registry solely for pending window cleanup and uses `terminateLater` to await shutdown on app quit.
The owner closes ACP and drains controller writes, terminates the process group, and waits for startup
if it was in flight. Unexpected process exit and observable controller failure also trigger cleanup.
Closing a transcript view only detaches its display driver; selecting history does not terminate the
window's live session. Starting another session requires ending the current one (or a startup failure).

## Persistence implementation

`PersistenceStore` owns a GRDB `DatabaseQueue` with async reads and transactional writes. Database
opening and migrations are synchronous and must run away from the main actor. The caller supplies
a file URL with an existing parent directory. One shared store serializes access for now; long reads
can delay writes, so replay uses bounded pages (500 events by default, at most 10,000). Revisit a
`DatabasePool` if concurrent session reads need to proceed during writes.

The initial `v1` migration creates four tables:

| Table | Stored data |
|---|---|
| `project` | Local UUID, name, unique root path and creation time. |
| `agent_install` | Local UUID, name, executable, argument array and creation time. Agents are configured manually; registry installation metadata belongs to the installer milestone. |
| `session` | Local UUID, project and agent references, optional agent session ID, protocol version, title, working directory and creation time. |
| `event` | Session-local sequence, kind, payload format version, timestamp and the original JSON bytes. |

The event log uses an ordinary rowid table with a unique composite primary-key index. This keeps
larger JSON payloads in table leaf pages instead of hitting the early overflow-page threshold of
`WITHOUT ROWID` index records. The composite index still serves session/sequence lookup and ordering.

Foreign keys reject missing parents and prevent deleting referenced metadata. Local session identity
is separate from the agent's session ID. The store currently creates and reads metadata; editing,
deletion and live observation are deferred until their callers need them. UUID columns use uppercase
`uuidString` TEXT, not GRDB's default UUID BLOB binding. Dates use REAL seconds since Foundation's
reference date (2001-01-01); avoiding epoch conversion preserves their exact `Double` precision.
Project root uniqueness compares exact strings. The caller must canonicalize directory identity,
including symlink and case aliases; this layer does not access the filesystem to resolve paths.

An append commits a whole batch or none of it. Sequences start at one per session and are assigned
inside the transaction. Concurrent batches receive distinct sequences, but the session controller
must await appends in ACP arrival order; task scheduling does not establish that order. Replay orders
by sequence, not wall-clock timestamps. Cancellation follows GRDB's transaction rollback behavior.

Append rejects raw NUL bytes and invalid UTF-8 before SQLite validates JSON syntax; SQLite alone
accepts both malformed byte sequences. Payloads are retained byte-for-byte in a BLOB. Unknown event kinds,
format versions and JSON fields remain readable. `Persistence` does not depend on ACP and does not
decode its wire models. The session integration must supply the original payload, not re-encode a
typed update that may have discarded unknown fields. Event interpretation and transcript reduction
belong to `AgenthesiaCore`.

SQLite triggers reject event updates, deletes and replacement inserts. Every store connection enables
recursive triggers so an `INSERT OR REPLACE` collision on the hidden rowid also fires the delete guard.
Log compaction or history deletion will require an explicit migration and policy. Migrations never
erase data on schema changes; opening a database with unknown migration identifiers fails rather than
writing through a newer schema. The app uses this store; the CLI remains independent.

## Session domain implementation

`SessionController` is `@MainActor @Observable`. Its caller creates the project and agent-install
records, supplies a draft `SessionRecord`, constructs an `AgentConnection` with the controller as
its delegate, and calls `start(connection:client:)`. Start initializes the connection, creates the
remote session, persists its local metadata, then records the initial config options. Notifications
arriving before `session/new` returns are buffered (at most 16 MiB) and committed after the baseline;
updates for other remote session IDs are ignored. Initialization/authentication failures close the
connection; authentication UI remains separate work.

The controller owns one prompt task. `send` records the prompt before sending it to the agent;
cancelling a task waiting on `send` does not cancel that owned turn. `stop` records the intent and sends
`session/cancel`, retaining updates until the prompt response. A new prompt is not allowed until a pending cancel has been sent.
A stop while the initial prompt write
is pending prevents sending that prompt. Busy sends are rejected until #65 supplies queue/steering.
Turn errors are recorded and close the session; deliberate close records cancellation instead.
Closing during startup also throws `CancellationError`; an earlier failure or a failed persistence write takes precedence.
The first failure is retained so a subsequent connection-closed error cannot hide its cause.
A storage failure closes the connection and reports an
observable error without showing uncommitted text. The caller owns `AgentProcess` and must terminate it
when the session fails or closes; closing ACP alone is not process containment.

All writes and reductions share an explicit task chain. `@MainActor` alone cannot preserve this order
across an async SQLite write. Incoming notification handlers await their commit and reduction before
JSON-RPC dispatches the next message. This also makes tool updates available before a permission request.
Until #21 provides approval UI, permission requests select and record `reject_once` when available;
otherwise they return `cancelled`. Requests during cancellation also return `cancelled`. A stop racing
with the decision write records a superseding cancellation before responding. Permissions are never granted. Structured input uses the delegate's default decline behavior.

The event format is version 1:

- `acp.session/update`: the **entire original JSON-RPC notification**, without its line terminator.
  JSONRPC → ACP → controller forwards these bytes alongside the typed update; the traffic logger is
  not used as a second event channel. Whitespace, unknown fields and numeric lexemes survive unchanged. Valid envelopes with updates that
  do not match the typed schema are forwarded as opaque updates and still recorded; envelope failures
  that prevent identifying the session are logged without the payload. The strict wire models remain unchanged.
- `session.event`: a Codable `SessionEvent` containing initial/normalized config options, user prompt
  and turn UUID, stop intent, turn completion/error, or a permission decision. When an adapter normalizes
  an update (e.g. legacy modes), its config-options event is appended in the same transaction immediately
  after the raw notification. Replay therefore reproduces live state without discarding original data.

`TranscriptState.apply` is the pure reduction of those stored events. Rows use their first contributing
sequence as a stable identity. It combines contiguous content chunks, respects explicit message IDs,
preserves non-text content, patches tool calls (absent fields stay unchanged, including when updates
arrive before the full call, whose untitled placeholder has an empty title), and tracks plans,
commands, settings, title, usage, stop reason and unfinished turns. Unknown kinds/versions and undecodable ACP update bodies remain stored
and advance the cursor with an unsupported-event count. Malformed local event payloads, invalid ACP
envelopes or sequence gaps fail replay explicitly.

The reduced state is private and unobserved. `publishTranscript()` assigns one snapshot only when the
sequence changes. `AgenthesiaUI.SessionFrameDriver` calls it from the view's display link, so streaming
chunks cause at most one transcript publication per frame, with a forced flush at startup, turn end,
permission response, failure and close. The view owns and stops the driver; it flushes on attach/detach
and uses a weak session reference. No display timer or rendering dependency is added to Core.

`restore(id:store:)` replays bounded pages into a read-only controller without contacting an agent.
An unfinished turn remains visible as unfinished; it is not automatically resubmitted. Reattach/resume
is #25. The controller must be explicitly closed by its owner; that releases the connection/delegate
cycle and waits for the active turn and pending writes.

## Runtime implementation

`ShellEnvironment` resolves the login-shell environment once per resolver instance. Concurrent callers
share the same resolution, and the application uses the shared instance. The resolver runs the shell
with `-l -i -c` in a new session using `posix_spawn`, so interactive shells cannot stop while trying to
acquire the CLI's controlling terminal. It extracts NUL-separated environment entries between unique
markers and bounds both the captured output (1 MiB) and the wait (5 seconds, plus bounded process
cleanup). Failed resolution returns a fallback environment and a diagnostic without exposing
environment values. The CLI passes the resulting environment explicitly to the agent
and reuses it for terminal authentication; constructing `AgentProcess` does not implicitly run a shell.
A complete, valid snapshot and successful shell exit suffice even when a descendant retains stdout;
the resolver still cleans up the remaining process group.

`AgentProcess` retains Foundation's `Process` and verifies process-group isolation before using group
signals. Shutdown is shared by concurrent callers: SIGTERM targets the group, followed by SIGKILL
after the grace period if necessary, including when descendants outlive the group leader. This covers
processes that remain in the group; it is not containment for processes that deliberately detach.
Natural leader exit also starts group cleanup without closing the ACP transport before its final
messages are read. Its default grace period applies only when cleanup has not started; leader exit
preserves an explicit termination deadline. A later explicit termination can shorten the cleanup
deadline, but never extend it.
The retained stderr tail (64 KiB), pending line (16 KiB), and live notification stream (64 lines) all
have bounded storage; truncation of retained output is marked.
Process exit and stderr completion are separate events. Waiting for stderr first awaits leader exit,
then allows up to 500 ms for the final drain, so calling it while the agent runs cannot close its pipe.
CLI initialization errors display at most the last ten retained lines.

The app displays the bounded stderr tail in its Agent Log panel ([#15](https://github.com/anesthetised/agenthesia/issues/15)).
Registry installation and the managed Node runtime are also still planned. The shell-only
`posix_spawn` adoption addresses a terminal interaction found while reviewing
[#14](https://github.com/anesthetised/agenthesia/issues/14). A possible transition of `AgentProcess`
remains a separate investigation in [#91](https://github.com/anesthetised/agenthesia/issues/91).

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
| [GRDB](https://github.com/groue/GRDB.swift) (7.11.1+) | MIT | `Persistence` |
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
