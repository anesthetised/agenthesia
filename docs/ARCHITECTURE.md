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
| `AgentRuntime` | Login-shell environment resolution, agent process lifecycle, PTY processes for terminal commands ([ADR-0015](adr/0015-agent-terminals.md)), ACP Registry client, installers (binary, npm), managed Node runtime. | `ACP` |
| `Workspace` | Git (CLI wrapper), worktrees, scoped file access, file index for Quick Open, FSEvents watcher. | — |
| `Persistence` | SQLite via GRDB: projects, agent installs, sessions and the append-only event log. | — |
| `Rendering` | Text rendering shared by the transcript, diffs and the file viewer: tree-sitter highlighting, incremental Markdown, `SourceView` (STTextView, TextKit 2), `UnifiedDiff` (unified hunks from `CollectionDifference`, highlighted in ```` ```diff ```` blocks with changed words marked) ([ADR-0007](adr/0007-transcript-rendering.md)). Source highlighting updates only color attributes ([ADR-0013](adr/0013-source-highlight-attributes.md)). | — |
| `AgenthesiaCore` | Domain: sessions, transcript reducer, permission queue, fs path policy, session manager, worktree lifecycle. | all of the above except `Rendering` |
| `AgenthesiaUI` | SwiftUI and AppKit views. | `ACP`, `AgentRuntime`, `Persistence`, `AgenthesiaCore`, `Rendering` |
| `acp-cli` | Headless debug driver: `chat`, `sessions` and `login` against any ACP agent from a terminal. | `ACP`, `AgentRuntime`, `Workspace` |
| `MockAgent` | ACP agent over stdio: the echo agent, which announces its verbs as slash commands, or a JSON scenario with `--scenario`. `--reopen` resumes sessions of earlier processes; `--no-resume` and `--no-load` remove those capabilities. | `ACPTesting` |
| `rendering-bench` | Release-build timings of Markdown rendering, highlighting and diffs (`just bench`). | `Rendering` |
| `persistence-bench` | Release-build append throughput and latency (`just bench-persistence`). | `Persistence` |
| `session-bench` | Release-build transcript reduction and snapshot publication (`just bench-session`). | `AgenthesiaCore` |
| `workspace-bench` | Release-build file indexing, fuzzy search, changed paths and bounded-read timings (`just bench-files`). | `Workspace` |
| `transcript-bench` | Release-build linking of transcript inline code paths against a file index (`just bench-transcript-links`). | `AgenthesiaUI`, `Rendering` |

## Live app integration

A `LiveSession` in Core owns one agent process and its `SessionController`
([ADR-0014](adr/0014-window-bound-live-sessions.md)). The app-wide `SessionManager` owns every
`LiveSession` ([ADR-0026](adr/0026-app-wide-session-manager.md)); windows select one and never end it.
`SessionLibrary.shared` opens
one app database away from the main actor and provides project, install, and saved-session discovery.
The owner resolves the login-shell environment, checks that the agent executable exists (so a typo
leaves no worktree behind), prepares the workspace, creates metadata, and starts
the ACP v1 adapter with filesystem access and form elicitation enabled; terminal and terminal-auth
capabilities remain disabled.
Agents must already be authenticated; authentication failures are displayed.

`Workspace.SessionWorkspace` invokes the Git CLI on a Dispatch queue, outside the cooperative pool, and
reads its errors from stderr only. Git checkouts get a new branch and worktree from HEAD under
`~/.agenthesia/worktrees/<repo>/<uuid>`; a selected subdirectory maps to the same path in the worktree.
After resolving symlinks, that path must be a directory inside the new worktree. Dirty and untracked files are not copied.
The new worktree's actual initial HEAD is retained as the session's `baseRevision` before launching
the agent. Non-Git directories are used directly; bare, broken (including a dangling `.git` link), or
unborn repositories fail explicitly. Worktrees
are retained after close or failed startup. Review, merge, discard, and richer worktree metadata remain
part of the worktree milestone.

`AgenthesiaUI` owns presentation and window integration. Its shared `TranscriptTableController` uses
`NSTableView`, with TextKit 2 for streaming messages. `LiveTranscriptSource` lazily renders requested
rows, caches attributed text, and handles updates to earlier rows as well as appended messages.
`SessionFrameDriver` publishes committed transcript snapshots from the display link. Saved transcripts
use the same table in read-only mode. The demo remains available as a test fixture; the original
Rendering Lab prototypes retain their implementations, with an additional production-table variant.

The composer ([ADR-0018](adr/0018-composer-attachments.md)) is an `NSTextView` that grows from two to six
lines; Return submits when ready, ⇧Return and ⌥Return insert a line break, and drafts stay editable during a
turn. Dropped, pasted and chosen files (⇧⌘A) are shown as removable chips and sent after the text as
`resource_link` blocks built by `ResourceLink.file` in Core. For a session in a linked worktree,
`SessionWorkspace.linkedCheckout` supplies the main checkout, and links to checkout paths that exist in
the worktree point there. A draft that is a bare `/word` lists the matching commands from
`available_commands_update`; choosing one inserts `/name ` as text. The transcript names link
attachments. `SessionController.submit(_:intent:)` owns the per-session prompt queue
([ADR-0010](adr/0010-prompt-queue-and-steering.md), [ADR-0021](adr/0021-prompt-queue-lifecycle.md)).
Return sends when idle with an empty queue, clearing a retained empty pause; otherwise it queues the
draft. A completed turn drains the queue as one prompt. Queue snapshots record text, attachments, editing, removal and
order in the existing event log. Dequeue and one `promptMessage` event per message commit atomically;
the messages retain their UUIDs, share a turn ID and display “sent together”, with a unique event
sequence per transcript row. Up in an empty composer recalls the last entry for text editing without
rebuilding its attachments. Stop, refusal and errors pause the queue; ⇧⌘R explicitly resumes it.
Saved entries remain paused after Continue; an empty queue resumes normal sending
([ADR-0029](adr/0029-empty-queue-recovery.md)). Explicitly sending the last queued entry also clears
the pause. An ended or failed established session also offers Continue, which creates a new connection; failed connections stay closed. Continue requires a persisted session
with an agent session ID. Startup failures cannot continue, and ended sessions remain selectable in
saved history. A dispatch stopped before invoking the wire prompt returns its composed
messages to the queue by UUID and marks the original transcript rows “not sent”. Queue snapshots are
built only after preceding lifecycle writes settle, so this compensation cannot overwrite later edits.

An error response to `session/prompt` ends only that turn ([ADR-0027](adr/0027-recoverable-prompt-errors.md)).
Core records the failed turn and queue pause before returning to idle, retaining the same process,
connection and agent session. Pending permissions and forms are cancelled durably. The error stays
in the transcript without requiring Continue or automatically retrying the prompt. Return queues while
retained entries are paused; an explicit send or queue resume is needed for that work. An empty queue
accepts a fresh Return immediately. Transport loss, process exit, malformed responses
and event-log failures still end the session. Saved history always opens read-only, including after
a recoverable error.

⌘Return sends a nonempty draft now and leaves the queue in place; with an empty or whitespace-only
draft, it sends the whole queue ([ADR-0028](adr/0028-empty-draft-sends-queue.md)). Attachments count as
a nonempty draft. ⇧⌘Return sends the queue with the nonempty draft last. Steering uses
`AgentProfile.steering`: v1 interrupts, waits for the owned turn and cancel tasks to settle, and then starts the next turn; injection-capable connections implement
`AgentConnection.inject(_:in:)` without ending the active turn. The default injection implementation
fails explicitly and no current v1 adapter advertises it. Injection first records complete composed
content as pending queue entries; only successful wire acknowledgement atomically dequeues it and
adds transcript rows. A Stop during preparation retains those entries. If the original wire turn
ends during preparation, the controller sends a new turn instead. A crash or failure between wire
insertion and acknowledgement conservatively retains the content for explicit recovery; ACP offers
no exactly-once guarantee. Manual Stop supersedes a pending interrupt
and never causes an automatic drain. Composer drafts clear only after durable acceptance.

Tool rows are cards: a native header (kind symbol, kind, status, disclosure) and a
Markdown body with the title, reported locations and text content, so selection and copying work as
for messages. Missing fields are shown as not reported; unsupported content appears
as a placeholder. A diff shows its path and unified hunks with three lines of context in a ```` ```diff ```` block;
`MarkdownRenderer` tints added and removed lines and the words that changed between adjacent runs (runs over
200 lines skip word comparison). Edits with over 1,000 unmatched lines show as a whole replacement, and a
diff is computed once per edit, not on every row update. Side-by-side diffs remain open. A command's output replaces the terminal placeholder: `TerminalText` derives
escape-free text at render time, shown in a code block with the exit status; collapsed, it keeps the last lines. Bodies beyond 12 lines or 2,000 characters are collapsed; expansion
is keyed by row identity and survives streamed updates. Header-only updates preserve the body and its
text selection. Truncated code blocks retain their fence delimiter when closed before the truncation note.
Each permission request is its own card, even when several refer to one tool call. It shows the tool
call as known when the agent asked and, while pending, a vertical list of native buttons in the
agent's option order, keeping choices visible in narrow transcripts. ⌥⌘1…⌥⌘9 choose an option of the
oldest pending request; the composer status shows that shortcut range. Return and Escape choose nothing.
Agent-provided “always” options are returned verbatim
and labeled as remembered by the agent; the app keeps no policy of its own. Answered cards state only
the recorded response (the option's name and kind, or cancellation), never an inferred approval or
decline. Requests without a recorded response after a restart show that none was recorded and have no
controls. Non-text content is identified with attachment placeholders rather than silently dropped.
The session's bounded stderr log and environment diagnostics are visible in the window.

Saved history opens read-only. Its Continue action selects a new owner that reattaches the saved
session ([ADR-0017](adr/0017-continue-saved-sessions.md)): `LiveSession.resume` looks up the session's
agent install, checks the executable and the working directory, and launches the agent there without
creating a workspace. `SessionManager.resume` returns the owner that already has the session live, and
otherwise closes earlier failed owners of the session before the new one launches, so one owner writes
to a session's log at a time. Selecting a live session from history shows its owner.
`SessionController.history(id:store:)` replays the log into a controller that `reopen` attaches through
`AgentConnection.reopenSession`. Only when the agent accepts does the controller append `failed` for a
turn without an outcome, `permissionResolved(.cancelled)` for requests without a response, and
`reopened` with the session's settings and the method used; the transcript shows the last as a
“Continued” divider. Any failure leaves the log unchanged and the history readable.

The AppKit application delegate owns the `SessionManager` and passes it to every window. Owners start
in the background. The sidebar (`SessionSidebar` in Core, `SessionSidebarList` in the UI) has one section
per project, ordered by its newest session; live sessions come first in start order with a status icon,
then saved sessions newest first, and owners that have no project yet are listed under Starting.
`LiveSession.activity` is the status, in priority order: needs input, failed, working, done, idle. *Done*
means `SessionController.completedTurns` (turns that ended on their own, not by Stop) exceeds what the user
has seen; a window marks the displayed session seen while it is the key window. A live session is failed
only when it is no longer connected and has an error, so one rejected prompt does not mark it. End Session (or Cancel Startup)
closes an owner and removes it, after which its session is listed as saved history; an owner whose
startup, process or controller failed stays listed with its error until it is ended or continued.
The Session menu routes actions through the focused window's `SessionWindowModel`. New Session is
⇧⌘N, End Session (or Cancel Startup) is ⇧⌘E, Stop keeps ⌘., Continue is ⇧⌘C, and Resume Queue keeps
⇧⌘R. Previous/Next Session use ⌥⌘[ / ⌥⌘], wrapping in sidebar order (Starting, then each project's
live and saved rows); from the launch form they select the last/first row. Next Session Needing Input
uses ⌥⌘I, skipping saved history and other statuses. Permission answers keep ⌥⌘1…⌥⌘9. Commands are
disabled without an eligible selection in the focused window. Resume Queue also enables an empty
paused queue, though a fresh Return now clears that pause automatically. The sidebar uses native single selection,
sharing the same row identity with keyboard navigation; the new-session form has no selected row.
History refresh follows completed startup, after the session record is persisted; an early session ID
alone must not leave Continue disabled after a later process exit. Opening/restoring windows remains #40.

Notifications and the Dock badge follow [ADR-0030](adr/0030-notification-activation-and-identity.md).
`SessionAttention` (Core) derives `AttentionNotice`s from the manager's owners and
`SessionManager.shownSessionIDs`, diffs them with what it posted, and drives an `AttentionSink`; the
delegate creates it with `SystemAttention` (UI, `UserNotifications` and the Dock tile) inside an app bundle.
The Dock tile follows [ADR-0031](adr/0031-app-icon-and-dock-tile.md): `AttentionSink.setDock(badge:live:)`
reaches `SystemAttention`, which draws `AppIcon` (UI) into the tile while sessions are live, one star each, and
removes it otherwise. `just icon` renders the asset catalog's PNGs from the same drawing.
Windows report the session they show while their scene appears active. A tap opens
`agenthesia://session/<id>` (declared in `App/Info.plist`), which `RootView` handles with `onOpenURL`.

Closing a window only detaches it and stops its file observation; closing a transcript view only
detaches its display driver. On quit the delegate asks for confirmation only if owners are working or
need input, naming their count. Cancel leaves every owner running. After confirmation (or immediately
for idle/failed owners), the delegate uses `terminateLater` and closes every owner concurrently: each
closes ACP and drains controller writes, terminates the process group, and waits for startup if it was
in flight. Unexpected process exit and observable controller failure also
trigger cleanup.

## Session filesystem

`LiveSession` creates a `SessionFileSystem` in Core and injects it into the ACP v1 adapter, which
advertises both [filesystem methods](https://agentclientprotocol.com/protocol/v1/file-system).
`SessionController` owns its lifetime. Keeping the provider separate leaves blocking file I/O and
wire error mapping out of the transcript controller; `Workspace.ScopedFileAccess` remains independent
of ACP. No new external dependency is needed.

The provider accepts requests only for the controller's remote session ID while idle or running.
Startup, stopping, failure, close, and read-only history do not admit requests. Admission and pending
operation accounting run on MainActor; path resolution, validation of root directories, and file I/O
run on Dispatch queues. Accepted operations are serialized per session. Closing or failing the
controller stops admission synchronously and waits for accepted operations to finish. Cancellation
before admission does no I/O; cancellation after admission does not roll back or abandon an accepted
operation. Thus a completed close cannot be followed by an outstanding filesystem write.
Stop also prevents admission while the turn is stopping, even if its tool permission was granted
earlier; the ACP file request must already have been accepted to finish. The controller continues
recording agent updates until the prompt response arrives, then permits file requests again when idle.

Roots are the actual session working directory (the worktree directory for Git projects), plus explicit
`additionalDirectories`. The launch API accepts additional directories and passes the same list to
`session/new`; an agent that does not advertise support fails startup rather than silently receiving
different roots. The current launch form supplies only the working directory. Additional roots are
launch parameters, not restored permissions; reopening history enables no provider. A continued session
does not store or restore additional roots, so its only root is its working directory.

`ScopedFileAccess` canonicalizes roots and requested paths, including macOS aliases such as `/var`,
then enforces directory-component boundaries. Internal symlinks may resolve inside any allowed root;
outside targets are refused. Reads open the canonical path with `O_NOFOLLOW_ANY`, then require a
regular file; `O_NONBLOCK` avoids hanging on a substituted FIFO. Writes open the root and walk parent
directories without following symlinks, create missing directories, and atomically rename a temporary
file relative to the retained parent descriptor. Existing ordinary permission bits are preserved.
Replacing a final symlink after validation cannot redirect the write, and replacing a hard link does
not overwrite its other names. Temporary files are removed on handled failures, but a process crash
can leave a `.agenthesia-<UUID>` file in the worktree. NUL paths are rejected and line range arithmetic
cannot overflow. Reads currently load the whole file even for a line range; incremental reads and
resource limits remain follow-up work for large files.

These checks prevent symlink substitution from redirecting an operation. They are not an OS sandbox:
an agent's own tools remain outside this provider, reads can see existing hard-linked files, and an
open directory descriptor keeps referring to that directory if another process renames it. File
changes remain in the worktree; tool call diffs are rendered in cards and the session file list observes
current disk changes. The CLI also benefits from the hardened `ScopedFileAccess` implementation.

## Session file browsing

The displayed session has a window-owned `SessionFiles` model, independent of ACP admission and event
replay ([ADR-0023](adr/0023-session-files.md)). Quick Open and the changed-file list open one file in a
resizable pane beside the transcript. These views read current disk contents, including for saved
sessions, and are scoped to the selected session's working directory. Markdown uses the existing native
renderer with Preview/Source selection; other text uses `SourceView`. `SessionFileDocument` reads
regular UTF-8 files off the main actor, capped at 2 MiB, through `ScopedFileAccess`.

Workspace's immutable `FileIndex` uses Git tracked/nonignored untracked paths, or a directory walk
outside Git, and deterministic fuzzy matching limited to 100 results. Non-UTF-8 names and unreadable
subdirectories are skipped rather than failing the index. `DirectoryWatcher` uses FSEvents only as an
invalidation signal. `SessionFileChanges` bridges it to Core, watching the selected directory and
external Git metadata, excluding object and reflog writes. A watcher that cannot start is reported and
retried without affecting the index; manual and ACP-triggered refreshes still work. Successful ACP
writes also invalidate through `SessionController.fileRevision`. The model coalesces scans and, under
sustained events such as a build writing ignored output, rescans at most once per second. It resolves
the repository once per scan; background refreshes keep visible results and show no progress until
refreshed ones replace them. It cancels obsolete searches/reads and rejects late results after
selection or window replacement. Canonical
roots are captured once and cannot broaden after symlink substitution.

Git changed paths combine `git diff base HEAD` ([ADR-0024](adr/0024-changed-files-session-base.md)),
staged, unstaged and nonignored untracked changes. Legacy
sessions without a base explicitly show working changes only; non-Git folders explain that change
tracking requires Git. Renames include both paths. Full worktree review remains #42. Browsing stops when the displayed session changes or its window closes, rather
than when the agent process ends; Continue keeps the same session's files across its startup.

### Transcript paths and Open in Editor

[ADR-0025](adr/0025-transcript-paths-and-editor-handoff.md). Core's `PathReference` parses a path
candidate (`:line`, `:line:column`, `#Lline`, leading `./` dropped) and resolves it against the session's
canonical root through `ScopedFileAccess`; paths outside the root, with `..` components or through a
symlink that leaves the root do not resolve. `ExternalEditor` is the table of editors by bundle
identifier; VS Code, Cursor and Zed have a `scheme://file/<path>:<line>` URL (percent-encoded), Xcode
opens without a line. Core builds URLs only; `NSWorkspace` is called from AgenthesiaUI.

Tool call locations and diff paths that resolve become `.link` ranges with a private `agenthesia-path`
URL (relative path and optional line). `LiveTranscriptSource` applies them to the cached attributed text
when a row's text changes, so Copy still returns the Markdown without links. The transcript's text field
and streaming text view consume the scheme before AppKit can open it; `RootView` opens the file only if
the transcript's session is still displayed. `SessionFiles.selectedLine` carries the line to the viewer:
`SourceView.showLine` selects it and scrolls by the laid-out fragment (TextKit 2 estimates heights), and
follows the layout correction when highlighting finishes. Markdown opened with a line shows Source.

The file pane's Open in Editor (⌥⌘O) uses the editor chosen in the Settings scene (`SettingsView`, stored
as `editorBundleIdentifier` in `UserDefaults`): the line URL when the editor has one, otherwise the file
in that app; with no choice, or an editor that is not installed, the system's default app.

Inline code in agent messages and thoughts links when it names a file in the displayed session's index.
`Rendering` marks inline code with the generic `.inlineCode` attribute. `SessionFiles` publishes
`indexedPaths` with an `indexRevision`; `RootView` passes them as a `TranscriptPathIndex`, and
`PathReference.indexedPath` matches relative paths, or absolute ones under the canonical root or the
working directory, without the file system. `LiveTranscriptSource` keeps each row's unlinked text and
relinks it once per index revision when the row is requested; a row is rebuilt only when its link
signature changes, so a rescan that links nothing new keeps its selection. Streaming rows and user
prompts are not linked. `just bench-transcript-links` measures the cost
([2026-10-17](benchmarks/2026-10-17/transcript-links/README.md)).

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
| `session` | Local UUID, project and agent references, optional agent session ID, protocol version, title, working directory and creation time. Migration `v2-session-base-revision` adds the optional initial Git revision. |
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
is pending prevents sending that prompt. Low-level `send` rejects busy calls; the app uses `submit`
to queue or steer them. The queue coordinator settles lifecycle writes before building snapshots and
checks the Stop generation captured at public operation entry, so an earlier send-now or resume
waiting behind an edit cannot supersede a later Stop.
Turn errors are recorded and close the session; deliberate close records cancellation instead.
Closing during startup also throws `CancellationError`; an earlier failure or a failed persistence write takes precedence.
The first failure is retained so a subsequent connection-closed error cannot hide its cause.
A storage failure closes the connection and reports an
observable error without showing uncommitted text. The caller owns `AgentProcess` and must terminate it
when the session fails or closes; closing ACP alone is not process containment.

Session settings use `setConfigOption(_:to:)` only while idle ([ADR-0019](adr/0019-session-config-controls.md)).
The controller owns the config task and exposes `isChangingConfig`; another config change or immediate
turn dispatch is rejected until the returned options have been committed and published. Queue draining
waits for that confirmation before dispatching. The agent's full
response is authoritative. Request errors preserve confirmed settings and leave the session usable;
storage errors fail the session. Close waits for accepted config work, and responses arriving after
close are discarded. Native composer menus preserve choice groups; checkboxes show boolean settings.
Unknown option types are hidden, and saved settings remain visible read-only. Legacy modes enter the
same controls through adapter normalization.

Config responses use a JSON-RPC ordered result consumer: decoding, adapter normalization and the Core
commit finish before the reader dispatches the next incoming message. This preserves both orderings:
a response supersedes earlier config notifications, and later notifications supersede that response.
The original config API still returns the normalized snapshot for its response. Cancellation before
response admission withdraws the request; once its consumer starts, it completes even if its waiter is
cancelled or the connection closes. The pending continuation is removed before consumption, so a
failed durable commit can close the connection without completing it twice. Consumers may close the
connection but must not await another wire response on it.

All writes and reductions share an explicit task chain. `@MainActor` alone cannot preserve this order
across an async SQLite write. Incoming notification handlers await their commit and reduction before
JSON-RPC dispatches the next message. This also makes tool updates available before a permission request.
`SessionController` owns pending permission requests and their responses; views only submit a request
identifier and an offered option identifier through `answerPermission`, which rejects stale, repeated
and unknown answers. A request is committed before it is shown, and its response is committed before
it is returned to the agent. Stop, `$/cancel_request`, the end of the turn, close and failure settle
pending requests with `cancelled`. Each resolution is enqueued synchronously, so close drains it with
the other writes. If a cancellation arrives while a decision is being committed, a superseding
cancellation is recorded and returned instead. A storage failure fails the session and returns
`cancelled`, never an approval. Requests for another session, or arriving outside a turn, are answered
with `cancelled` without being recorded. Structured input uses the delegate's default decline behavior.

The event format is version 1:

- `acp.session/update`: the **entire original JSON-RPC notification**, without its line terminator.
  JSONRPC → ACP → controller forwards these bytes alongside the typed update; the traffic logger is
  not used as a second event channel. Whitespace, unknown fields and numeric lexemes survive unchanged. Valid envelopes with updates that
  do not match the typed schema are forwarded as opaque updates and still recorded; envelope failures
  that prevent identifying the session are logged without the payload. The strict wire models remain unchanged.
- `session.event`: a Codable `SessionEvent` containing initial/normalized config options, user prompt
  and turn UUID, stop intent, turn completion/error, or a permission request and its resolution. A request
  stores a local UUID, the tool call update and the offered options; a resolution stores the UUID and the
  returned outcome, and the last resolution wins. The earlier single decision event (tool call update and
  outcome, without options) is still read and shown with the option identifier only. When an adapter normalizes
  an update (e.g. legacy modes), its config-options event is appended in the same transaction immediately
  after the raw notification. Replay therefore reproduces live state without discarding original data.

`TranscriptState.apply` is the pure reduction of those stored events. Rows use their first contributing
sequence as a stable identity. It combines contiguous content chunks, respects explicit message IDs,
preserves non-text content, patches tool calls (absent fields stay unchanged, including when updates
arrive before the full call, whose untitled placeholder has an empty title), accumulates the command output
an agent reports in a tool call's `_meta` (`terminal_output_delta`, `terminal_output`, `terminal_exit`; the newest
1 MiB, outside the call's `meta`; [ADR-0016](adr/0016-agent-reported-command-output.md)), and tracks plans,
commands, settings, title, usage, stop reason and unfinished turns. Unknown kinds/versions and undecodable ACP update bodies remain stored
and advance the cursor with an unsupported-event count. Malformed local event payloads, invalid ACP
envelopes or sequence gaps fail replay explicitly.

The reduced state is private and unobserved. `publishTranscript()` assigns one snapshot only when the
sequence changes. `AgenthesiaUI.SessionFrameDriver` calls it from the view's display link, so streaming
chunks cause at most one transcript publication per frame, with a forced flush at startup, turn end,
permission response, failure and close. The view owns and stops the driver; it flushes on attach/detach
and uses a weak session reference. No display timer or rendering dependency is added to Core.

`restore(id:store:)` replays bounded pages into a read-only controller without contacting an agent.
An unfinished turn remains visible as unfinished; it is not automatically resubmitted. Continuing a
saved session closes it as interrupted (see above). The controller must be explicitly closed by its owner; that releases the connection/delegate
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

`TerminalProcess` runs an agent terminal's command ([ADR-0015](adr/0015-agent-terminals.md)). It is
spawned with `posix_spawn` as the leader of a new session; the pseudo-terminal's slave side is opened
in the child after the session is created, so it becomes the controlling terminal, with an 80×24 window.
A bare command is resolved through the command environment's `PATH` and a relative one against its
working directory; a missing executable fails creation with `ENOENT`. Nothing is written to the
terminal. The master side is read continuously, because a terminal's last close waits for its output
to be read; raw bytes are retained up to the output limit (1 MiB by default), dropping the oldest in
batches so that noisy commands append in amortized constant time. A process source reaps the
command. Both sources run on a private serial queue. The initial sizing slave remains open until the
read source is registered and has drained a bounded snapshot of buffered bytes, preventing a quick
command's output from being discarded while the reader queue starts. Later output must still be read
promptly because the kernel can discard unread bytes on terminal close or revocation. Exit waits for the end of output, which arrives promptly because the kernel revokes the
terminal when the session leader exits; the wait is still bounded at 500 ms. Group cleanup is the
same `ProcessGroupTermination` that `AgentProcess` uses, started on natural exit or explicit
termination.

`TerminalText` derives the text an agent reads from a terminal's raw bytes: escape sequences (CSI, OSC,
DCS and other string or short sequences) and control characters other than tab are removed, CRLF
becomes LF, and a carriage return inside a line keeps only the text after it. The result is cut from
the start at a character boundary to the byte limit. An incomplete trailing escape sequence or
character of a running command is withheld. Cursor movement is not interpreted.

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
                                                    ├─ answers permission requests via the UI
                                                    └─ owns SessionFileSystem (ACP fs → Workspace)
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

### Native elicitation forms

Live sessions advertise form elicitation and render matching session-scoped requests as native
transcript cards. Requests and final responses are committed before display and delivery; drafts
remain temporary UI state. Stop, withdrawal, failure, turn completion and close cancel pending forms.
Saved forms have no active controls; Continue records cancellation of interrupted requests.
Agent-provided regular expressions share a 20 ms budget of thread CPU time spent matching. Other
field validation and time spent descheduled do not consume it; regex compilation is outside this budget.

Request-scoped elicitation is explicitly declined, including requests made before a durable session
exists. Supporting those requests needs a separate startup interaction and persistence design
([#111](https://github.com/anesthetised/agenthesia/issues/111)). URL
elicitation remains unadvertised.
