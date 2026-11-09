# Architecture

This document describes how Agenthesia is built. Decisions and their rationale live in
[ADRs](adr/); this is the map. How the UI behaves for the user (wording, shortcuts, states) is in
[docs/behavior/](behavior/); this document names the code behind it.

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
| `MCP` | The Model Context Protocol subset of the built-in `agenthesia` server ([ADR-0049](adr/0049-built-in-agenthesia-mcp-server.md)): hand-written wire types for `initialize`, `notifications/initialized`, `ping`, `tools/list` and `tools/call` with text and image content, and `MCP.server(info:instructions:tools:)`, a `Router` that serves `ServedTool`s (bad arguments and thrown errors become `isError` results, an unknown tool `-32602`). A client is a `Connection` with the typed methods. Knows nothing about sessions. | `JSONRPC` |
| `ACP` | Hand-written `Codable` wire types: shared types in `ACP`, v1-only envelopes and capabilities in `ACP.V1`. Typed v1 client and delegate for agent→client requests. The version-agnostic `AgentConnection` protocol and the v1 adapter that implements it. | `JSONRPC` |
| `ACPTesting` | Test support: scenario engine (`ScenarioAgent`), reactive `EchoAgent`, JSON subset matching. Used by tests and `MockAgent` only. | `ACP` |
| `AgentRuntime` | Login-shell environment resolution, agent process lifecycle, PTY processes for terminal commands and sign-in ([ADR-0015](adr/0015-agent-terminals.md), [ADR-0033](adr/0033-agent-sign-in.md)), ACP Registry metadata and ETag cache, user-provided Node/npm checks and private versioned binary/npm installations ([ADR-0034](adr/0034-agent-installs-with-user-runtimes.md), [ADR-0035](adr/0035-installer-storage-and-script-policy.md)), and the table of known local ACP commands found on `PATH` without running them ([ADR-0037](adr/0037-local-agents.md)). | `ACP`, system `CLibArchive` |
| `Workspace` | Git (CLI wrapper), worktrees, scoped file access, file index for Quick Open, FSEvents watcher. | — |
| `Persistence` | SQLite via GRDB: projects, agent installs, sessions and the append-only event log. | — |
| `Rendering` | Text rendering shared by the transcript, diffs and the file viewer: tree-sitter highlighting, incremental Markdown, `SourceView` (STTextView, TextKit 2), `UnifiedDiff` (unified hunks from `CollectionDifference`, highlighted in ```` ```diff ```` blocks with changed words marked), `DiffLine` (its output parsed into lines with old and new numbers) ([ADR-0007](adr/0007-transcript-rendering.md)). Source highlighting updates only color attributes ([ADR-0013](adr/0013-source-highlight-attributes.md)). | — |
| `AgenthesiaCore` | Domain: sessions, transcript reducer, permission queue, fs path policy, session manager, worktree lifecycle, the agent catalog of registry installs and their session leases ([ADR-0036](adr/0036-agent-settings-and-installed-sessions.md)), local agents and the ACP initialize probe ([ADR-0037](adr/0037-local-agents.md)), the `agenthesia-mcp` socket and session tokens ([ADR-0049](adr/0049-built-in-agenthesia-mcp-server.md)). | all of the above except `Rendering` |
| `AgenthesiaUI` | SwiftUI and AppKit views. | `ACP`, `AgentRuntime`, `Persistence`, `AgenthesiaCore`, `Rendering` |
| `acp-cli` | Headless debug driver: `chat`, `sessions` and `login` against any ACP agent from a terminal. | `ACP`, `AgentRuntime`, `Workspace` |
| `MockAgent` | ACP agent over stdio: the echo agent, which announces its verbs as slash commands, or a JSON scenario with `--scenario`. `--reopen` resumes sessions of earlier processes; `--no-resume` and `--no-load` remove those capabilities. | `ACPTesting` |
| `agenthesia-mcp` | The stdio end of the built-in MCP server, copied into `Contents/Helpers`: connects to the app's socket, sends the session's token and relays bytes both ways ([ADR-0049](adr/0049-built-in-agenthesia-mcp-server.md)). System frameworks only. | — |
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
the ACP v1 adapter with filesystem access, form elicitation and terminal auth enabled; the `terminal`
capability remains disabled.

Sign-in follows [ADR-0033](adr/0033-agent-sign-in.md). When `session/new`, `session/load` or
`session/resume` answers `-32000`, `SessionController` returns to `ready` without writing anything,
keeping the connection and profile, and throws `authenticationRequired`. `LiveSession` then publishes
`signIn` with the agent's methods; the session counts as *Needs input*, posts a notice, and the manager
treats it as starting, so it cannot be discarded or merged. An agent method calls `authenticate` on the
open connection and then `SessionController.retry`, which repeats only the session request. A terminal
method closes the connection, stops the agent, and runs the agent's command with the method's `args` and
`env` (plus `TERM=xterm-256color`) as a `TerminalProcess` in the session's working directory, exposed to the
UI as `SignInTerminal`; status 0 launches the agent again and starts or reopens the session on the new
connection. Another `-32000` returns to the method list with a message. Cancel stops the attempt (the
terminal's process group, or the agent for an agent method, which the next attempt launches again);
closing the session also stops the terminal and waits for it. The window replaces the composer with
`SignInPanel` and shows the terminal in a sheet hosting SwiftTerm's `TerminalView`, which feeds the
command's output stream and sends typing and size changes back.

Settings sign-in follows [ADR-0038](adr/0038-pre-session-sign-in.md). `AgentSignIn` owns a separate
process in an empty temporary directory, initializes with terminal authentication enabled, and runs
the selected agent or terminal method without creating a session or worktree. The installed version's
lease is held through all processes and cleanup. Initialization has a 20-second timeout; interactive
sign-in remains cancellable. Terminal success reconnects and initializes, then every successful flow
stops its processes before reporting completion. A failed terminal retains its output in memory until
dismissed. Retry fetches a fresh method list. Cancellation waits even for a pending acquisition or
launch, then removes the temporary directory and releases the lease. Completion is not persisted as
an account status: a future session may still require authentication on its own connection.
`AgentCatalog` retains one active sign-in for the Settings sheet. Closing the native Settings window or
dismissing the sheet awaits its cleanup; a stale dismissal cannot clear a newer flow. The application
delegate also waits for this owner before quitting, even if no session exists, and the catalog refuses
new sign-ins once quitting begins. Both sign-in surfaces share the method rows and terminal view.
Sign-in sheets allow modal application termination so AppKit reaches that cleanup delegate instead of
blocking Quit before consulting it.

`Workspace.SessionWorkspace` invokes the Git CLI on a Dispatch queue, outside the cooperative pool, and
reads its errors from stderr only. Git checkouts get a new branch and worktree from HEAD under
`~/.agenthesia/worktrees/<repo>/<uuid>`; a selected subdirectory maps to the same path in the worktree.
The branch has a readable name ([ADR-0039](adr/0039-t3-style-window-layout.md), amendment *the inspector leads with the
work*): `SessionWorkspace.branchName` gives `agenthesia/<words>-<first 8 hex digits of the session id>`, for example
`agenthesia/fix-note-parser-baaeedd5`. `LiveSession` passes the first line of the initial prompt
(`SessionTitle.fromPrompt`) as the topic; ICU's `Any-Latin; Latin-ASCII; Lower` transform turns it into Latin, and the
words are the runs of `[a-z0-9]`, joined with `-` and cut at a word boundary to at most 40 characters (a longer first
word is cut at 40), or `session` without any. When a branch of that name already exists, `prepare` uses the legacy name
`agenthesia/<session id>` instead and never touches the existing branch. The name is stored in the session's nullable
`branch` column and never renamed; sessions created before it have none and keep the derived legacy name.
After resolving symlinks, that path must be a directory inside the new worktree. Dirty and untracked files are not copied.
When the checked-out branch has an upstream (`git for-each-ref` reads its remote, remote branch and tracking ref, so a
never-fetched upstream still counts), `prepare` first runs `git fetch --quiet <remote> <branch>` with the login shell's
environment (`LiveSession` passes the agent command's, resolved once per launch; `GIT_TERMINAL_PROMPT=0`) and a 20-second
limit, then creates the worktree from the tracking ref instead of `HEAD`
([ADR-0047](adr/0047-worktrees-from-the-fetched-upstream.md)). Without an upstream it starts from `HEAD`; when the fetch
fails or is stopped, it starts from `HEAD` and stores the upstream's name in the session's nullable `fallbackUpstream`
column (migration `v7-session-fallback-upstream`), which the inspector shows. The draft's Checkout label names the
upstream (`SessionWorkspace.worktreeBase`). The new worktree's actual initial HEAD is retained as the session's
`baseRevision` before launching the agent. The branch checked out in the selected checkout at that moment is retained
as `baseBranch` (ADR-0032), even when the worktree started from its upstream; a detached `HEAD` records none, and such
a session cannot be merged, only discarded. Non-Git directories are used directly; bare, broken (including a dangling `.git` link), or
unborn repositories fail explicitly. Worktrees
are retained after close or failed startup until the session is merged or discarded, except one whose session never
got a history record.

Folder sessions run in a folder rather than a worktree of their own, and come in three kinds: a **non-Git folder**
(`prepare` on a directory without a `.git` entry: no base revision), a **Git project folder**
([ADR-0043](adr/0043-sessions-in-the-project-folder.md)) and **scratch**, a session without a project (below). For the
second the draft's Checkout chip is a menu (`SessionWindowModel.draftInProjectFolder`, per draft: Send, another project
and New Session in Project clear it, a failed start returns it), passed as `inProjectFolder` through
`SessionManager.start` and `LiveSession` to `prepare`. That form keeps the bare and broken repository checks, then
returns the repository root as project directory, the selected directory as working directory, `HEAD` as
`baseRevision` and the checked-out branch, or nil when detached, as `baseBranch`, with no branch, no worktree and no
fetch; an unborn `HEAD` fails. No column marks it: `SessionManager.worksInProjectFolder` reads a session with a base
revision whose working directory lies outside the worktrees root, a location `SessionWorkspace.Worktree` never matches,
so merge, discard, push, Open Pull Request… and Delete Session's file removal all refuse or skip it; deleting one
deletes only its history. Non-Git and scratch sessions have no base revision, so the test never reads them as such.
`SessionWindowModel.displaysProjectFolderSession` gives Merge and Discard Worktree… the help text `This session works
in the project folder` (inspector, review footer, Session menu), titles Changes `Changes since the session started`, and
opens `SessionReview` with `inProjectFolder`, which drops the base branch so the review compares with `baseRevision`:
the merge base with the checked-out branch would be the checkout itself.

Sessions without a project ([ADR-0048](adr/0048-sessions-without-a-project.md)) start with a nil directory:
`SessionManager.start(directory: nil, …)` passes its `scratchRoot` (default `SessionWorkspace.defaultScratchRoot`,
`~/.agenthesia/scratch`, injectable like the worktrees root) to `LiveSession`, whose `create` calls
`SessionWorkspace.prepareScratch` instead of `prepare`. It creates the root, canonicalizes it with
`ScopedFileAccess.canonicalURL` (so the file pane's `isCanonical` check holds), and creates
`<root>/<words>-<8 hex digits>` (`readableName`, the session branch without its `agenthesia/` prefix) without
intermediate directories, so an existing folder fails the start. The result is a non-Git workspace: the canonical root
as project directory, the folder as working directory, no base revision or branch. The working directory stays the
only filesystem root of `SessionFileSystem`; the project root is never added. `SessionLibrary.project(directory:name:)`
creates the project row once, named `ProjectRecord.scratchName` (`No project`). No column marks it: the project is
recognised by its well-known root, `ProjectRecord.isScratch(scratchPath:)` against `SessionManager.scratchPath`
(`SessionWorkspace.scratchProjectPath`), so no migration was needed. `ProjectRecord.recent` skips it, so the draft's
project menu and default never offer it; `SessionWindowModel.isScratch` drives `ProjectBadge.mark` (`.dashed`, drawn as
`square.dashed`), hides Discard Worktree… and Review, and the inspector's Changes text. Merge and Discard are refused
anyway, since such a session has no base revision and no `Worktree`. The draft's switch is
`SessionWindowModel.draftWithoutProject`; Send clears it, and a failed start brings it back with the picks.
`LiveSession.removeUnstartedWorktree` also removes the folder of a start that failed before its record existed, through
`SessionWorkspace.removeEmptyScratch`, and only while the folder is empty.

New sessions start from the draft ([ADR-0040](adr/0040-composer-first-session-start.md)), which replaced the
launch form. A window without a session (and New Session, ⇧⌘N) shows `SessionDraftView`: the heading "What should
we build in <project>?" (`DraftHeading`, the project a menu; a second line through `ViewThatFits` when narrow) over
the centered composer card, whose chips pick the agent and name the checkout, with the agent's cached mode, model and
effort as pills beside Attach. Send runs inside `withAnimation`, and `RootView` removes the draft with
`DraftSendTransition`, which sets the `draftLeaving` environment value so the card moves to the bottom edge as it
fades. The draft's state lives in `SessionWindowModel` (`draft`, `draftDirectory`, `draftAgent`, `draftError`). The
project menu lists `ProjectRecord.recent` (by each project's newest session), marked by `isDraftProject`, and Choose
Folder…; with nothing picked, the project of the newest session is used, named by `draftProjectName`. While
`draftNeedsAgent` (no agent choice and no custom command), the card shows `Add Agent…` (`ManageAgentsButton`) in place
of the text field. The Agent chip lists `AgentCatalog.choices` (the newest installed version of each
agent, then local agents), Custom Command… (`CustomCommandSheet`, parsed by `RootView.launchCommand`) and Manage
Agents…; with nothing picked it uses `AgentCatalog.defaultChoice`, the agent remembered by `remember` under the
`lastAgent` defaults key while it is still offered, else the first choice. The Checkout label is `DraftCheckout`:
`SessionWorkspace.worktreeBase` names the checked-out branch, or the short commit of a detached `HEAD`; outside
Git it is "Project folder". Send with a nonempty `PromptDraft` calls `SessionManager.start(…, initialPrompt:)`,
clears the draft; the agent is remembered once the initial prompt is submitted. `LiveSession.initialPrompt` holds it in memory (not in the queue,
which belongs to a session record) until the session is idle for the first time: `connected`, after `session/new`
or after sign-in, submits it with intent `whenReady` like a typed prompt, and a failed submission fails startup.
If startup fails or is cancelled (Cancel Startup, End Session at sign-in), the owner is no longer live and still
holds its prompt; `SessionWindowModel.abandonedStart` reports it, and `RootView` calls `returnToDraft`, which puts
the prompt back into the draft with the owner's error and ends the owner, so the sidebar does not list it.
A session row's context menu offers New Session in Project (`SessionWindowModel.newSession(in:)`), which opens the
draft with the row's project selected and keeps the typed message and agent; a starting session has no project yet
and offers nothing. A live row also offers Settle Session (`SessionWindowModel.settle(_:)`, #275): End Session for
that row's own owner, available while `SessionRow.canSettle(owner.activity)` holds (idle, done, failed); on hover the
row shows the same action as a button.

Mode, model and effort hints (ADR-0040's amendment) are applied at start. `AgentCatalog.configHints` keeps, per
`AgentCatalog.Choice`, the select options with category `mode`, `model` or `thought_level` (effort) from the agent's
last confirmed list, as one JSON value per agent in a `configHints` defaults dictionary keyed by the choice's JSON; an
undecodable entry is ignored. `SessionController.onConfigOptions` reports each confirmed list once it is recorded (`started`, `reopened`,
`configOptions`, including the agent's own notifications), and `LiveSession` passes it to
`AgentCatalog.rememberHints(_:for:)` with its `AgentInstallRecord`, which maps an installed version to its agent and a
command to its local agent, else to a custom command; `SessionManager.catalog` is set by the app delegate.
`SessionWindowModel.draftHints` is what Send passes as `configHints`: the cached model and effort options, with any
value picked in `draftConfig`, and a mode only when one was picked there; changing the agent and Send clear
`draftConfig`.
`SessionController.createRemote` applies them after `session/new` and before the record exists: an equal value sends
nothing, others go through `setConfigOption` one at a time in the agent's order, each response replaces the list the
next hint is checked against, and config notifications buffered before a response are dropped, because the response
supersedes them; the `started` event holds the final list. A hint whose option or value the agent no longer offers, or
an error response, throws `HintRejected` (`The agent does not offer “Large” any more.`), after reporting the agent's
list to the catalog; the start fails as any other, so the worktree is removed, nothing is recorded and the draft
returns with the error.

The draft shows the cached options as pills (#212). `SessionWindowModel.draftPills` is the selected agent's
`configHints` entry and `draftValue(of:)` the value of each: the one picked in `draftConfig`, if the agent offered it
(else the pick is ignored), or the cached model or effort; a mode nobody picked has none and its pill reads `Default mode`.
`draftHints` is built from `draftValue(of:)`, so a pill always shows what Send applies. `SessionDraftView` draws them
in the composer's bottom row after Attach with `ConfigControlRow`, the control row `SessionConfigControls` also uses,
as secondary, with the tooltip and accessibility note `Last used with this agent; confirmed when the session starts`;
a pick sets `draftConfig`, and a change of agent clears it. An agent without a cache entry shows no pills.

While the session starts, the detail column shows the held prompt instead of an empty view
([ADR-0040's amendment of 2026-11-07](adr/0040-composer-first-session-start.md)). `SessionWindowModel.heldPrompt` is
`LiveSession.initialPrompt` while the displayed session has no transcript item yet (also at sign-in). `HeldPromptSource`
is a one-item `TranscriptSource` that renders the prompt with `LiveTranscriptSource.render` and the markdown of
`LiveSession.content`, so `HeldTranscript` (a `TranscriptTableController`) lays it out as the session's own first prompt;
`RootView.startingColumn` shows it with the `Starting…` card before the controller exists, and `panes` swaps
`LiveTranscript` for it after. `LiveSession.startLine` is the line above the card: `fetching` is set from
`SessionWorkspace.prepare(onFetch:)` while ADR-0047's fetch runs, and `startPlace` (`newWorktree`, `projectFolder` or
`newFolder`, ADR-0048) once the checkout is known, before the install check.

The Checkout chip is `DraftCheckout`: for a Git project a menu of `New worktree from <upstream>` (the default) and
`Project folder` ([ADR-0043](adr/0043-sessions-in-the-project-folder.md)), outside Git the label `Project folder`;
`SessionWorkspace.worktreeBase` names both the worktree's base and what is checked out, for the folder's help text.


A start that fails or is closed before its record exists (Cancel Startup or End Session at sign-in, an agent that
exits during `initialize`) removes the worktree and branch its `LiveSession` made (#176). The record is written
when the agent accepts `session/new`, so `LiveSession.removeUnstartedWorktree` asks the store and does nothing when a
record exists; only a worktree created by that owner in that start is ever considered, never a saved or continued
session's or a non-Git project's folder. `SessionWorkspace.removeUntouched` then reuses the discard code: it
removes the worktree and branch only when `discardSummary` finds no uncommitted or untracked path and no commit
since `baseRevision`, and otherwise leaves both on disk. Any Git or store error also leaves them, and never fails
the flow. It runs from `fail` and at the end of `close` off the main actor, so Quit (which waits for `close`)
finishes it. A failure inside `SessionWorkspace.prepare` itself, after `git worktree add`, is not covered.

Discard (ADR-0032) goes through `SessionManager.discard`. It refuses while the session is starting or
being continued, coalesces concurrent calls and makes Continue unavailable while it runs. It ends the
session's owners, then `SessionWorkspace.remove` runs `git worktree remove --force` (or `git worktree prune`
for a directory deleted by hand) and `git branch -D <session branch>` in the project checkout; once the
directory is gone, a missing branch is not an error, so a failed attempt can be retried.
`SessionWorkspace.Worktree` only matches a working directory at or inside
`<worktrees root>/<project directory name>/<session id>` with a branch that belongs to the session
(`isSessionBranch`): the stored name only with the prefix `agenthesia/` and this session's `-<8 hex digits>` suffix,
or, without a stored name, exactly `agenthesia/<session id>`. Any other stored name makes the session not removable,
so discard and merge never delete it. Non-Git
sessions and legacy sessions in the user's own checkout never lose files, and a directory at that path
which Git does not list as a worktree is left in place. An existing worktree must still be on the exact
session branch; another branch, detached HEAD or a failed branch check prevents removal. Only after
Git succeeds is `SessionEvent.worktreeRemoved(.discarded)` appended; replay sets `TranscriptState.worktreeOutcome`, adds
a notice, and `LiveSession` refuses to continue such a session. Nothing is appended to a session after
its outcome, so `SessionLibrary.worktreeOutcomes` reads each session's last event
(`PersistenceStore.lastEvents`, one index lookup per session) for the sidebar and menus without replaying
history. The confirmation counts uncommitted paths (`git status --porcelain -uall`) and commits on the
session branch since `baseRevision`.

Merge (ADR-0032) goes through `SessionManager.merge` and squashes the session into `baseBranch` in the
project checkout. `SessionWorkspace.mergeCheck` reports blockers without writing: no base branch, a
missing base branch, a base branch that does not contain `baseRevision` yet (`git merge-base --is-ancestor`, a session
started from a fetched upstream the user has not pulled; ADR-0047), a checkout on another branch, with tracked changes or with a merge, cherry-pick,
revert or rebase in progress, a worktree that is missing, off its branch or has unresolved conflicts, and
nothing to merge; otherwise it counts files changed from the merge base and the session's commits.
`SessionWorkspace.merge` repeats the check, commits uncommitted work in the worktree (no hooks at all,
unsigned, squashed away), runs `git merge --squash` and `git commit -F` in the checkout, and returns the new
commit. The final commit gets the login shell's environment
(`ShellEnvironment`, as for agents), so hooks and signing find their tools when the app was opened from the
Dock. A conflict, a refused squash, a rejecting hook or an empty squash runs `git reset --merge`, which
restores the checkout and removes `SQUASH_MSG`; if that reset fails as well, the failure says so.

While a merge runs, the manager refuses Continue, discard and a second merge, and `SessionController`
holds turns (`beginMerge`/`endMerge`): dispatches are refused and the composer is disabled. A merge
starts only when the live owner, if any, is idle with no queued send pending; a saved session merges
without starting its agent. The agent stays attached until the commit exists, so it can resolve a
conflict. Then the owners end first, because closing may still record events and the outcome must stay
the last one, `worktreeRemoved(.merged(commit:into:))` is appended, and the worktree and branch are
removed. A failed history write after the commit is reported with the commit and keeps the worktree. A
failed removal is reported after the sheets close, the merge stays recorded, and *Discard Worktree…*
finishes the removal without replacing the outcome; its confirmation says that nothing of it is lost. Quit waits for a running merge. The sheet's default message is the
agent's session title, or the first line of the first prompt.

`AgenthesiaUI` owns presentation and window integration. Its shared `TranscriptTableController` uses
`NSTableView`, with TextKit 2 for streaming messages. `LiveTranscriptSource` lazily renders requested
rows, caches attributed text, and handles updates to earlier rows as well as appended messages.
`SessionFrameDriver` publishes committed transcript snapshots from the display link. Saved transcripts
use the same table in read-only mode. The demo remains available as a test fixture; the original
Rendering Lab prototypes retain their implementations, with an additional production-table variant.
While a turn runs, `SessionController.turnStartedAt` (in memory; set on entering `running`, kept while
`stopping`, cleared otherwise) drives a "Working for 1m 12s" line (`WorkingTimeLine`,
`WorkingDuration.format`) directly above the composer card, ticking once a second. With a plan it adds
`PlanProgress.summary` (`· 3 of 7 · Writing tests`, `· 3 of 7 done`).

Transcript rows lay out in the `TranscriptColumn` that the composer card shares: centered, at most 720 pt wide,
with at least 24 pt on each side (`TranscriptColumn.width(inRowOfWidth:)` also gives the text wrap width). A row's
Copy button is shown only while the pointer is over the row (`NSTrackingArea`, `.activeInKeyWindow`,
`.inVisibleRect`); the row also offers Copy as an accessibility custom action.

`TranscriptMessage.kind` says how a row shows its role: a user message is a `BubbleCell` at the column's trailing edge
(`NSColor.quaternarySystemFill`, radius 14, padding 10 × 14) that hugs its text and stops at 80 % of the column
(`TranscriptColumn.bubbleWidth(forTextWidth:inColumnOfWidth:)`); its `caption` (`not sent`, `sent together`) is a
right-aligned label under the bubble. Agent messages have no role label. Tool, permission and input rows keep their
headers. `role` stays in the model, and Copy returns a row's
Markdown without it.

The table's rows are not the transcript's items: `TranscriptSource.rows` lists `TranscriptRow`s, and
`TranscriptRow.fold` folds two or more consecutive tool calls into one `.group` row. Any other item, including a
permission request or an input form, ends a group, and one call stays a plain card. `ToolGroupSummary` words the row
from the ACP tool kinds (`Ran 3 commands, made 2 edits`, `· 1 failed` in the failure color); while the session runs
and the group's last call is pending or in progress, it shows that call's title instead (`just test…`). A group
is a header without a body, collapsed by default and expanded by its disclosure into the existing cards, which follow
it as rows; `LiveTranscriptSource` keys that by the group's first item, separately from each card's own expansion.
`TranscriptTableController` diffs the rows by identity (`CollectionDifference`) and inserts and removes only those that
changed, so the others keep their views, selected text and table selection. A row that folds away loses its selection.
A group has no Markdown of its own: its `copyText` builds its cards' Markdown only when asked, which also keeps
streaming from rendering cards nobody sees. A table selection skips an expanded group's summary, so that its cards are
copied once.

Thoughts are collapsed ([ADR-0039's amendment](adr/0039-t3-style-window-layout.md)): `TranscriptRow.fold` folds every
run of one or more consecutive thoughts into a `.thoughts(first:)` row. Collapsed, the row is a header without a body,
as a group is; expanded (`LiveTranscriptSource` keys it by the run's first item, in the same set as a card's own
expansion), it adds the thoughts' Markdown below the header, dimmed, in the same row, so expanding inserts no rows and
goes through the row's own height (`rowContentHugging`). `ThoughtSummary` words the header: `Thinking… <last line>`
while the run ends the running turn's transcript (`Thinking…` alone when expanded, so streamed text does not rebuild the
header), `Thought for 12s` after. The times come from `TranscriptState`: the reducer sets a thought's `thoughtStart` at
its first chunk and moves `thoughtEnd` to each event's timestamp while the thought is the last item of a running turn,
so the next item or the turn's end closes it, in live and saved transcripts alike; a run's time is the sum of its
thoughts' `thoughtDuration`. Copy returns the run's Markdown through `copyText`, built when asked; Find matches each
thought item and `reveal(item:)` expands the run that holds it. The Rendering Lab's S10 streams two folding thoughts
before the S1 answer.

Session notices (continued, ended, merged, discarded, interrupted) render as a centered caption between two
hairlines, without role label or Copy. A failed prompt (`TranscriptState.Item.isFailure`) shows the `message` of
its stored `RPCError(...)` description (`PromptFailure.summary`, applied when displayed, so saved history
benefits and stored events do not change) and a Details disclosure with the full stored text.

The composer is a floating card ([ADR-0039](adr/0039-t3-style-window-layout.md)) in the transcript column
(`TranscriptColumn`: at most 720 pt, 16 pt side and 12 pt bottom margins, `.bar` material with a hairline border).
Inside it come the queue, the editing hint, attachments, the text and a bottom row: attach, the control row, the Send
options menu and a round button whose role `ComposerPrimaryAction` picks (Send,
Queue, Save, or Stop for an empty draft while a turn runs or stops; Queue and Save show their name beside the arrow, and while a turn runs the Send options menu names Send Now as interrupting it and lists Stop Turn next to ⌘. in the Session menu). The control row
(`ConfigControlRow`), shared by a session's `SessionConfigControls` and the draft's hints, draws select options as
borderless `ConfigSelectMenu` pills that show the value only (the option name is in the tooltip and the accessibility
label; the mode opens `ModeChoices` in a popover) and booleans as toggle pills; a `ViewThatFits` over every split of
`ConfigControlRow.split(_:overflowing:)` shows the first that fits, the rest in a `…` menu (other options leave
first, then mode, model and effort). `ContextRing` follows the control row in a fixed slot before the Send options
menu, so its width comes out of the pills' room and it never overflows: `ContextUsage` (Core, pure) turns the last
`usage_update` into the ring's state (hidden below 70 %, attention from 90 %, the percentage rounded down) and the
inspector's *Context* and *Cost* rows (`84k of 200k · 42 %`, the cost formatted by the system in the agent's
currency). While a turn runs, `WorkingTimeLine` directly above the
composer card reads `Working for …`, or `Waiting for you` while a permission or form waits; the docked permission card shows
its ⌥⌘ shortcuts, and the queue header says that the queue is paused. A session that cannot take a prompt (saved, ended, failed, starting, merging or with a merge/discard outcome)
shows `ContinueCard` instead of the card: a symbol and the state (`ContinueCard.State`, a pure mapping of status,
merge flag and outcome) and, when `SessionWindowModel.canContinue` and there is no outcome, a prominent Continue
button.

The oldest pending permission request is docked above the composer card (`PermissionDock`,
[ADR-0039's amendment](adr/0039-t3-style-window-layout.md)), above the errors and `Waiting for you` in the status line,
so it stays on screen whatever the scroll position. `DockedPermission` builds it from
`SessionController.pendingPermissions`, which carry the tool call as known when the agent asked: the kind and the
paths (locations, then the diffs' files), the title as secondary text, the first diff with `+n more files` that
expands in place, and `1 of 3` while several are pending. The card is at most 40 % of the column's height and its diff
scrolls inside it. The buttons follow the agent's order and names, show ⌥⌘1…⌥⌘9 for the first nine options and wrap
(`WrappingLayout`) instead of truncating; none is the default, and Return and Escape stay with the composer. The card
never takes focus. Each request gets a new card identity, so `PermissionArming` ignores clicks and shortcuts for
400 ms after a request appears, including the next one after an answer, and the buttons look disabled meanwhile.
VoiceOver announces each new request. The card shrinks the table's clip view; the table relayouts and follows the end,
which a hosted test covers. [ADR-0042](adr/0042-allow-edits-in-this-worktree.md) (deferred) would add a pill while
edits are allowed.

Composer errors show as a `FailureBanner` above the card, with its actions and a Details disclosure.

The composer ([ADR-0018](adr/0018-composer-attachments.md)) is an `NSTextView` that grows from two to six
lines; Return submits when ready, ⇧Return and ⌥Return insert a line break, and drafts stay editable during a
turn. Each session keeps its own unsent text, attachments and queue edit (`ComposerDraft`, in
`SessionWindowModel.composerDrafts`) for as long as the window lives, so looking at another session loses nothing; they
do not survive a relaunch, and two windows on one session have separate drafts. Dropped, pasted and chosen files (⇧⌘A) are shown as removable chips and sent after the text as
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
sequence per transcript row. Each `QueuedPrompt` carries its `Origin` ([ADR-0049](adr/0049-built-in-agenthesia-mcp-server.md)):
`user`, or `session(id, turnID)`, `delegation(taskID)`, `delivery(taskID)` and `task(taskID)` for turns that the app's
tools start; `user` is left out of the stored JSON and is the default when the field is absent, so older logs decode
unchanged. `Origin.wrapped` (pure) marks the content of any other origin as another agent session's before it goes to
the agent, without naming that session; `Origin.label` names the source in the transcript (a labelled card row instead
of the user's bubble) and in the sidebar's reason, resolved by `SessionManager.originLabel` from the sessions open in
this launch. Up in an empty composer recalls the last entry for text editing without
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
Each permission request is its own record row, even when several refer to one tool call, and the row has no
buttons: they live on the docked card, where ⌥⌘1…⌥⌘9 choose an option of the oldest pending request. Return and
Escape choose nothing. The record is one line, like a folded group (`kind == .group`, a header without a body):
the recorded outcome, then what was asked (`Allowed once · Edit · Write note.txt`; `Waiting for you · …` while
pending), with a Details disclosure that unfolds the tool call as known when the agent asked and the outcome in
words. The header is `LiveTranscriptSource.permissionCard`'s `ToolCardHeader` with `record` set: the status leads, the
summary (the kind and the first line of the title) truncates at the tail. Details are keyed by row identity like any
card's expansion, Copy returns them whether or not the row is folded, and Find reads them. A tool row whose call has
a pending request leaves its diff out (`toolCard(hidingDiffs:)`, from `LiveTranscriptSource.pending`) and shows it
again once the request is answered; the row's height changes then, and follow-bottom or the reader's scroll origin
handles it as for any row change. Agent-provided “always” options are returned verbatim and labeled as remembered by
the agent; the app keeps no policy of its own. Answered records state only the recorded response (the option's name
and kind, or cancellation), never an inferred approval or decline. Requests without a recorded response after a
restart show that none was recorded. Non-text content is identified with attachment placeholders rather than silently
dropped.

> **Accepted, not yet implemented:** "the app keeps no policy of its own" would no longer hold for an explicitly
> enabled session ([ADR-0042](adr/0042-allow-edits-in-this-worktree.md), deferred).

The session's bounded stderr log and environment diagnostics are visible in the window.

Find in the transcript (`TranscriptFindBar`, `TranscriptFindState`, `TranscriptSearch`) reads each item's full text, so it
also finds what a folded group or collapsed card does not show. Matches are items, not occurrences. Typing only counts
and marks the text in visible rows, 150 ms after the last key; Return and ⌘G step to a match, and only a step expands
the group and card that hide it, scrolls to the row and selects it. Streaming rows are not marked until they finish, and
a streamed answer is counted again at the next edit or step, not on every chunk. Copy returns a tool card's whole
output whether or not it is collapsed, and an expanded summary selected alone copies its cards.

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
in the background. The sidebar (`SessionSidebar` in Core, `SessionSidebarList` and `SidebarShelves` in the UI,
[ADR-0039](adr/0039-t3-style-window-layout.md)) is grouped by status, in this order: *Needs You* (live
sessions whose activity is needs input, failed or done, in start order), *Working* (the other live sessions,
including owners that have no project yet, in start order) and *Settled* (saved sessions that are not live,
by last activity, newest first); empty sections are omitted. Each row carries its project (`nil` while unknown).
A row (`SessionRow`) shows a project badge (`ProjectBadge.initials`; the tint is a 64-bit FNV-1a hash of the name, since `hashValue` changes per launch), the title, the project and a reason, the status symbol and `RelativeTime.short` of the session's last activity. The second line is `project · reason` ([ADR-0039's amendment](adr/0039-t3-style-window-layout.md)). `SidebarReason` (Core, pure) derives the reason from `LiveSession.Activity`, so it never contradicts the symbol: `Sign in`, `Allow? <tool title>` (the oldest pending request, `+n` for more) or `Permission` without a title, `Question`, `Failed`, `Starting`, `Stopping`, the label of a running turn the user did not send (`TranscriptState.turnOrigin`, see below), else the plan entry in progress (`PlanProgress.current`), `Merging`, `Finished`, `Refused`, `Hit a limit`, `Prompt failed` (the last prompt was rejected: `TranscriptState.lastTurnFailed`) and `Queue paused` (a paused, nonempty queue); a running turn the user sent or a plain idle session has none, a saved one only `Archived` (found by a search, see below) or its `Merged` or `Discarded` outcome. A permission request that names its call only by id takes the title the agent reported earlier (`PendingPermission.callTitle`). The title is reduced to its first line and 120 characters. The line never wraps: `SubtitleLayout` shrinks the project first, to 40 % of the line, then cuts the reason at its tail. The tooltip and the accessibility label (`title, project, reason, last active 3m`; the status when there is no reason) hold the whole row. The time is the last activity: `SessionController.lastActivity` for a live session (the minute of the last stored event, set at most once a minute and seeded when history loads), `PersistenceStore.lastEvents()` for a saved one (`SessionLibrary.lastEvents()` returns it with the worktree outcomes, in one query), else `createdAt`. Settled sorts by it; Needs You and Working keep start order.
Needs You scrolls in the sidebar list (`SessionSidebarList`), which shows `Nothing needs you` as an overlay when it has no rows. Working and Settled are shelves pinned to the bottom edge, Working above (`SidebarShelves`, one `safeAreaInset`), each hidden while its section has no rows. A shelf's header (a chevron, the section name and the count, a disclosure button labelled “Working, N sessions, expanded/collapsed”) is always visible. Working is expanded by default and Settled collapsed; each keeps its state in `SessionWindowModel.workingShelfExpanded` / `settledShelfExpanded` (`RootView` remembers them in `@SceneStorage`, like the inspector). The chevron collapses a shelf even while one of its rows is selected; only a search opens it regardless (`SidebarShelves.isOpen`), and Previous/Next Session expand the shelf they move into (`SessionWindowModel.revealShelf`). Expanding and collapsing animate with a 0.25 s spring, none under Reduce Motion (`SidebarShelves.animation`). Expanded, a shelf grows upward with its own `List`, sized by a row-height estimate because a `List` does not report its content height: `SidebarShelves.listHeights` caps Working at 35 % of the sidebar's height and Settled at 45 %, less when the list above would keep under `topRoom`. A Working shelf row ends with `SessionSidebar.shelfTime` in place of the last-activity time: `Working 1m 12s` from `SessionController.turnStartedAt` (`WorkingDuration`, a one-second `TimelineView` only on running shelf rows; a `List` builds only the rows on screen), or `Idle 20m` from the last activity. History refreshes on its own, so the toolbar has no Refresh button.
The sidebar has a native search field (`SessionSidebarColumn`, `.searchable` with the sidebar placement; the text is `SessionWindowModel.sidebarQuery`, not persisted). `SessionSidebar(query:)` is the pure filter: rows whose title or project name `localizedStandardContains` the trimmed query (a starting or untitled session matches as “New Session”), empty sections omitted, `isFiltered` set. The list, the shelves (open while a query is entered, their counts are the numbers of matches), Previous/Next Session and Next Session Needing Input all read the filtered sidebar, so navigation only visits visible rows. With no match the list shows `ContentUnavailableView.search`. ⌥⌘F (Session → Search Sessions) focuses the field through `searchFocused`.

**Archive Session** ([ADR-0044](adr/0044-delete-and-archive-sessions.md)) hides a saved session from Settled without touching its log. The nullable `session.archivedAt` column (migration `v6-session-archived-at`, `SessionRecord.archivedAt`) holds when; `PersistenceStore.setArchived(_:of:)` sets it, or clears it with `nil`. `SessionSidebar` leaves archived sessions out of Settled (so out of its header count, and out of the section altogether when nothing else is saved) unless a query is entered: a search lists them in Settled order, the header then counts the matches, and the row's reason is `Archived` (`SidebarReason.saved`, which wins over `Merged` and `Discarded`). Previous and Next Session skip archived rows even while a search shows them. *Archive Session* / *Unarchive Session* (the title follows `archivedAt`) is in the row's context menu of a saved row and in the Session menu; neither asks for confirmation. The Session menu item is disabled unless the displayed session is saved, with the help text `End the session first` for a live one (`SessionWindowModel.canArchive`, `archiveHelp`); live rows have no context-menu item. **Continue** clears `archivedAt` (`SessionWindowModel.continueRestored`): a session the user talks to again is not archived. Every write refreshes the window's history; other windows pick it up at their next refresh.

**Delete Session…** ([ADR-0044](adr/0044-delete-and-archive-sessions.md)) removes a saved session for good. Events are
append-only in the schema itself (`event_no_delete`); migration `v8-session-deletion` lets the guard pass only the
events of a session listed in `session_deletion`, which `PersistenceStore.deleteSession` fills and empties inside its
one transaction (mark, delete the events, which hold the queue too, delete the record, unmark). `event` is the only
table that references a session, and a test lists the foreign keys so a new one cannot be forgotten.
`SessionManager.delete` refuses a live or starting session (`DeleteError.live`) and one being merged, discarded or
deleted (`busy`); it removes the files first and deletes nothing when that fails: a worktree Agenthesia created goes
through `SessionWorkspace.remove` (ADR-0032's checks; skipped when it is already gone after a discard or merge, or
when neither it nor the project exists), and the folder of a session without a project goes to the Trash
(`SessionManager.trash`, a test seam), only when the stored path lies directly in the scratch root with no `.` or `..`
component. `deleteSummary` words the confirmation's state (`DeleteSummary`: merged, discarded, the worktree's
`DiscardSummary`, the folder's name and file count, failed to start when the session stored no event, or history
only). `SessionManager.deletingIDs` is part of `RootView`'s history key, so every window refreshes when a deletion
ends, and `SessionWindowModel.refresh` sends a window whose displayed saved session vanished to the session board,
dropping its review and viewed marks. The item is on saved rows' context menus and in the Session menu
(`canDelete`, with Archive's help text); `SessionAlerts` holds the confirmations of Discard and Delete.

The session board ([ADR-0046](adr/0046-session-board-and-menu-bar.md), [behavior](behavior/board.md)) is a state of
the window, not a scene: `SessionWindowModel.showingBoard` sits beside `showingSetup` (set together, since neither shows
a session; any assignment to `showingSetup` leaves the board), `showBoard()` (⌘0, the sidebar's Overview row tagged
`SessionWindowModel.overviewID`, a deleted session) drops the displayed owner, and `WindowTarget.board` restores it.
`SessionBoard` builds `SessionCard.Content` for each live row of an unfiltered `SessionSidebar`: the row's title,
project and reason (`SessionWindowModel.reason(of:)`, shared with the row), `SessionSidebar.shelfTime`, the agent's last
line (`TranscriptState.agentLastLine`, Core, pure) and the oldest pending permission with `PermissionChoice.choices`
under the plain rule. A card's options reuse `DockedPermission`'s operation line, `PermissionArming` and
`WrappingLayout`, and answer through `SessionController.answerPermission`; its context menu is `SessionRowMenu`, the
rows' own.

`LiveSession.activity` is the status, in priority order: needs input, failed, working, done, idle. *Done*
means `SessionController.completedTurns` (turns that ended on their own, not by Stop) exceeds what the user
has seen. It clears when the end of the finished turn was on screen
([ADR-0026's amendment](adr/0026-app-wide-session-manager.md)), not when the window is key: a turn that ends on its own
records the transcript's last item (`SessionController.lastResultItem`), and `LiveSession.unseenResult` gives it while
the turn is unseen. `SessionWindowModel.unseenResult(appearsActive:)` passes it to `LiveTranscript` only while the
window appears active and shows the live session. The table resolves the item to its row, or to the summary of the
folded group that holds it (`TranscriptRow.row(showing:in:)`, the row identity find uses), and checks the pure
`TranscriptTableController.showsEnd(of:in:)`: the row's bottom edge is in the visible rect, with `followsBottom`'s
24 pt tolerance. The check is coalesced to one per main-queue turn and runs after an update, a table layout, a scroll or
a clip-view resize (the docked card and the panes resize it); the clip view is observed only while a target is set, and
without one nothing is scheduled. Once the end was shown, the table reports the item once and stops watching;
`markSeen(reaching:)` marks every turn seen only when the item is still the latest result. A reader following the end
clears the mark as the turn ends.

`New response below` and Jump to Latest (ADR-0026's amendment): the table keeps `followingBottom`'s intent and, when it
turns false, remembers `TranscriptState.End` (the last item's identity and how much text it holds: its content blocks,
the last block's length, a command's output bytes). An update checks `session.end` against it only while the reader is
not following, so the streaming path pays nothing while the reader follows the end; coming back to the end forgets it.
`TranscriptTableController.position` is `following`, `scrolledUp` (the end is as the reader left it) or `newBelow`;
it is reported to `LiveTranscript.onPositionChange` on a later main-queue turn and only when it changed
(`SessionWindowModel.endPosition`). `RootView` overlays `NewResponseButton`, a capsule centered at the transcript's
bottom edge above the status line, while the position is `newBelow`; scrolling up alone does not show it. Its click
and Session → Jump to Latest (⌥⌘↓, disabled while following, `canJumpToLatest`) call `jumpToLatest()`, which counts a
request (`jumpRequests`, as ⌘L counts `composerFocusRequests`); `LiveTranscript` answers it with
`TranscriptTableController.scrollToEnd()`, without animation, which resumes following and, through the viewport
check, clears a waiting Done. ⌘↓ stays with the composer's text view. A live session is failed
only when it is no longer connected and has an error, so one rejected prompt does not mark it. End Session (or Cancel Startup)
closes an owner and removes it, after which its session is listed as saved history; an owner whose
startup, process or controller failed stays listed with its error until it is ended or continued, except a
new session whose startup failed before its first prompt was submitted, which returns to the draft (ADR-0040).
The Session menu routes actions through the focused window's `SessionWindowModel`. New Session is
⇧⌘N, End Session (or Cancel Startup) is ⇧⌘E, Stop keeps ⌘., Continue is ⇧⌘C, and Resume Queue keeps
⇧⌘R. Previous/Next Session use ⌥⌘[ / ⌥⌘], wrapping in the visible sidebar order (Needs You, Working, Settled); from the draft they select the last/first row. Next Session Needing Input
uses ⇧⌥⌘] (⌥⌘I toggles the inspector), skipping saved history and other statuses. Search Sessions is ⌥⌘F. Focus Composer is ⌘L from any pane (`composerFocusRequests` moves first responder to the text view, as ⌥⌘F does for the sidebar field). Find in Transcript is ⌘F, with Find Next ⌘G, Find Previous ⇧⌘G and Next Failed Tool Call ⌥⌘G, and Jump to Latest ⌥⌘↓. The review pane's commands are Review Changes ⌃⌘R, Mark Viewed and Go to Next ⌥⌘V and
Ask Agent ⌥⌘A. Permission answers keep ⌥⌘1…⌥⌘9. ⌘1…⌘9 (Session → Switch to Session, ADR-0046) select the first nine rows of Needs You and Working in the filtered sidebar, in the order on screen; Settled is not numbered. `SessionSidebar.numberedRows` is the pure mapping, `SessionWindowModel.numberedSessions` pads it to nine items (a number without a row is disabled, titled “No Session”) and the menu lists each row's title. Commands are
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
removes it otherwise. The app icon itself is the layered
`App/AppIcon.icon`, which the system composes for each icon style.
The menu bar item ([ADR-0046](adr/0046-session-board-and-menu-bar.md), [behavior](behavior/menu-bar.md)) is a
`MenuBarExtra` scene in `App/` holding two UI views, `SessionMenuBarLabel` and `SessionMenuBarContent`, which read
`SessionManager` and rebuild when it changes. `SessionMenu` derives the entries from `SessionSidebar`'s Needs You and
Working sections (`LiveSession.reason`; `PlanProgress.current` or `SessionSidebar.shelfTime`), a session opens through
its `WindowTarget` URL as a notification does, and an option answers through `SessionController.answerPermission`.
`PermissionChoice` (Core, pure) is the Open-first rule: a request that edits files offers Open before the agent's
options; the session board reuses it without `openAlways`. `WindowPresence` counts the visible main-capable windows from AppKit's
window notifications, so that Open Agenthesia shows only when none is open. Hosted views cannot test a `MenuBarExtra`:
the views are tested by their size and the entries as data, and the item itself in the running app.
Windows report the session they show while their scene appears active. A tap opens
`agenthesia://session/<id>` (declared in `App/Info.plist`), which `RootView` handles with `onOpenURL`.

Closing a window only detaches it and stops its file observation; closing a transcript view only
detaches its display driver. On quit the delegate asks for confirmation only if owners are working or
need input, naming their count. Cancel leaves every owner running. After confirmation (or immediately
for idle/failed owners), the delegate uses `terminateLater` and closes every owner concurrently: each
closes ACP and drains controller writes, terminates the process group, and waits for startup if it was
in flight. Unexpected process exit and observable controller failure also
trigger cleanup.

## The agenthesia MCP socket

[ADR-0049](adr/0049-built-in-agenthesia-mcp-server.md) serves Agenthesia's tools to every agent as a stdio MCP server,
`agenthesia-mcp`, which the app target copies from the package into `Contents/Helpers` and signs (an *Embed Helpers*
copy phase with *Code Sign On Copy*). The helper reads `AGENTHESIA_MCP_SOCKET` and `AGENTHESIA_MCP_TOKEN`, connects,
writes the token and a newline as its hello, then copies bytes between its stdio and the socket on two threads without
parsing them; either side reaching end of file ends the process (status 0; a missing variable or a failed connection
exits 1).

`SessionApplicationDelegate` opens one `MCPSocket` per app instance at launch (only in an app bundle, so package tests
never do) at `MCPSocket.path(dataFolder: AppSupport.directory)`: `$TMPDIR/agenthesia-<16 hex digits>.sock`, the digits
the start of a SHA-256 of the data folder, so the installed app, the `.dev` build and a run under `CFFIXED_USER_HOME`
each get their own, and the path stays under `sun_path`'s 104 bytes. `init` first connects to the path: when another
instance with the same data folder answers (two `.dev` builds from different worktrees), it throws `EADDRINUSE` and the
second app runs without the server, logged; otherwise it unlinks whatever is there (a stale socket of an instance that
did not close it), binds, sets mode `0600` before `listen` and accepts on a Dispatch source.
Each connection's hello is read a byte at a time on a global queue (at most 256 bytes and 5 seconds), so nothing after
it is consumed. `SessionManager.mcpTokens` (`MCPTokens`) maps tokens, 256 bits from `SystemRandomNumberGenerator` as 64
hex digits, to session ids; `revoke` drops every token of a session. A known token hands the connection, as a
`FileHandleTransport` over the socket, with its session id to the socket's `serve` closure, and the connection closes
when `serve` returns; any other hello closes it. Until #71 the app's `serve` returns at once and no session issues a
token: #71 issues one per live session for `session/new`, `load` and `resume`, revokes it when the session ends, and
serves the `MCP` module's server on the transport.

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
different roots. The draft supplies only the working directory. Additional roots are
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
replay ([ADR-0023](adr/0023-session-files.md)). Quick Open and the changed-file list of the inspector open one file in a
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
tracking requires Git. Renames include both paths. `SessionFiles.changeStats` (`SessionWorkspace.changeStats`,
`git diff --numstat` against the same base plus the lines of untracked text files) counts added and removed
lines of the net change, refreshed with the paths; binary files have no counts and stay out of the totals,
and a path restored to its base has no entry. Browsing stops when the displayed session changes or
its window closes, rather than when the agent process ends; Continue keeps the same session's files
across its startup.

*Review Changes* ([ADR-0041](adr/0041-review-pane.md)) is a pane of the detail column: ⌃⌘R in the Session menu
(*Hide Review* while it is shown) and Review in the inspector toggle it, and Escape closes it while it has focus and no
text is selected. It takes the file pane's slot in `DetailPanes`: `SessionWindowModel.showingReview` decides which of
the two the slot holds, opening a file hides the review, and hiding the review brings back the file the user had open.
The hidden one keeps its state. The slot keeps the file pane's rules (240 pt minimum, hidden below a 480 pt column, the
inspector gives way first) with its own remembered width, `reviewWidth`, 560 pt by default. The transcript and the
composer stay live beside it. The pane shows what is compared (`Changes against <base>`, with `WatchErrorNotice` when
watching failed), the native file list (at most a third of the pane's height; `ReviewFileRow`: path, status, rename
source, line counts and a viewed mark), the selected file's diff and a footer with Merge… and the viewed count
(`2 of 5 viewed`). `SessionWorkspace.review` compares the current working tree with
`merge-base refs/heads/<baseBranch> HEAD` ([ADR-0032](adr/0032-worktree-merge-and-discard.md)), including staged,
unstaged and nonignored untracked files. It retains rename sources and reports a missing base branch explicitly.
Without `baseBranch`, or while `baseBranch` does not contain `baseRevision` (ADR-0047), it compares with
`baseRevision`, or HEAD for legacy sessions with neither. Paths are relative to
the selected working directory.

Core's window-owned `SessionReview` retains selection while that path still differs. The pane refreshes from
`SessionFiles.indexRevision`, sharing filesystem, Git metadata, ACP and manual invalidation with the file list. Only
the selected file is loaded: its immutable base blob is size-checked before reading, and the current side uses
`SessionFileDocument`. Both sides require UTF-8 without NUL bytes and the same 2 MiB limit; unsupported files show a
notice. Captured canonical roots cannot broaden through a symlink. A refresh reads the selected file before replacing
anything: an equal `Document` changes nothing, so neither the selection nor the scroll position moves. While the diff
view has text selected (`SessionReview.hasSelection`; the view owns the selection itself), a changed or vanished file
is held (`isHolding`) and the pane shows `File changed · Show latest`; Show latest or clearing the selection applies
it, and the list keeps updating meanwhile. Selecting another file replaces the diff despite a selection.

The diff is `DiffTextView` (`ReviewDiff.swift`), a read-only, selectable TextKit 1 `NSTextView` with contiguous layout,
so line positions are exact. `RenderedDiff.make` runs `UnifiedDiff.make`, `UnifiedDiff.highlight` (line tints and
changed words) and `UnifiedDiff.parse` off the main actor; text line `i` is `DiffLine` `i`, and the view keeps each
line's start offset, so a selection maps to lines (for Ask agent, #215). A `DiffGutter` ruler draws each line's old and
new number. A new document replaces the text in place once it is rendered, keeps the nearest line at the top and ends
the selection; the view's identity depends only on the pane, so transcript frames do not touch it. A 5,000-line file
rewritten (10,001 diff lines) renders off the main actor in 0.2–0.4 s and shows and draws in 30–50 ms; the first
scroll to its end lays out the rest in 0.15–0.3 s (`ReviewDiffTests`, on a loaded machine). Session replacement or window
closure ends the review.

Viewed marks and line counts (#214). `ViewedMarks` (Core) holds a mark per path with a `Fingerprint` of what was
viewed: status, and size and modification time from `lstat` of the working file. `SessionReview.refresh` reads the
fingerprints of the marked files off the main actor and `keep(matching:)` drops every mark whose fingerprint differs or
whose file left the list (`ViewedMarks.surviving`, a pure function); a `touch` clears a mark too. The row's button
(`SessionReview.toggleViewed`) and ⌥⌘V (*Mark Viewed and Go to Next* in the Session menu, enabled while the pane is
shown and a file is selected; `SessionReview.markSelectedViewedAndAdvance`) set marks, and ⌥⌘V then selects the next
unviewed file after the selected one, wrapping round. `SessionWindowModel` owns one `ViewedMarks` per session, so marks
survive closing the pane and reviewing another session in the window; closing the window, a merge or relaunching ends
them, and they never reach the append-only log. Marks do not affect Merge. The list's counts are
`SessionWorkspace.changeStats(in:baseRevision:)` with the review snapshot's own merge base, read on each refresh; a
failure to count leaves the list without counts and does not fail the review.

Ask agent (#215). With lines selected in the diff, *Ask Agent* in the footer, at the top of the diff's context menu
and in the Session menu (⌥⌘A, free among every key equivalent in the app) calls `SessionWindowModel.askAgent()`. Only
the diff view knows its selection, so `ReviewDiffView` hands the model its `DiffTextView` (`reviewDiff`, weak).
`DiffTextView.lines(in:lineStarts:)`, a pure function, grows the selection to whole text lines (one that ends at a
line's start leaves that line out), and `quote(stale:)` passes those lines to `DiffQuote.make`, which drops hunk
headers and lists one range per hunk. The quote is marked `(from an earlier version; lines may have moved)` while the
diff is held (`SessionReview.isHolding`). The model stores it as a `ComposerInsertion` (an id and the text) and asks
for composer focus; `ComposerTextView` inserts each new insertion once with `FileTextView.insertBlock`, at the end of
the composer's selection so that selected text stays, on lines of its own, as an undoable edit that writes the draft
binding. A queued message being edited is the composer's text, so the quote goes there. Nothing is sent. Ask agent is
disabled, with the reason in its help text, while the displayed session cannot take a prompt
(`promptUnavailableReason`: the composer card is replaced by the Continue card, as for saved history or an ended
session, or is not shown), and without a selection. *Merge…* in the pane and *Merge into <base>…* in the Session menu open the merge sheet, which
`RootView` presents.

**Push after merge** ([ADR-0045](adr/0045-push-and-pull-requests.md)). `SessionManager.mergeCheck` adds the base
branch's remote to `.ready` (`SessionWorkspace.pushRemote`, from ADR-0047's `upstream(of:in:)`; nil without an upstream
or for a local one), and `MergeSheet` shows `Push <base> to <remote>` for it, bound to `@AppStorage("pushAfterMerge")`
(off by default, the last choice for every project). `SessionManager.merge(_:message:push:)` pushes after the outcome
is recorded and before the worktree goes: `SessionWorkspace.push` runs `git push <remote>
refs/heads/<base>:<upstream branch>` with the login-shell environment and `GIT_TERMINAL_PROMPT=0`, its output in a file
(an ssh child could hold a pipe open), and stops it after 2 minutes. It never pulls, rebases or forces. A failure is
thrown last as `MergeError.notPushed(commit:base:output:)`, which the window treats like the other committed errors:
the sheet closes and an alert `Merged, but Not Pushed` shows Git's output. Tests use a local bare remote: a pushed
merge, a remote that moved (rejected, nothing undone), no or a local upstream, and a transport that hangs.

**Pull requests** ([ADR-0045](adr/0045-push-and-pull-requests.md)). `SessionManager.pullRequestTarget` decides whether
*Open Pull Request…* is shown: a removable worktree without an outcome, a base branch with a remote upstream
(`SessionWorkspace.remoteUpstream`, from ADR-0047's `upstream(of:in:)`) and `gh auth status` succeeding through
`/usr/bin/env gh` with the login-shell environment (`gitHubCLIIsSignedIn`, a positive answer kept for the launch).
`openPullRequest` refuses a busy session (`canBeginMerge`), marks it in `pushingIDs` (merge and discard refuse it
meanwhile), commits the uncommitted changes (`commitUncommittedChanges`, `--no-verify`), pushes with `pushBranch`
(`git push -u`, sharing the base push's output file, `GIT_TERMINAL_PROMPT=0` and 2-minute stop) and runs `gh pr create`
(`GH_PROMPT_DISABLED`), reading the number from the URL it prints. The result is appended as its own event kind,
`session.pullRequestOpened` with `PullRequest(url, number)`, through the live controller (`SessionController.record`)
or the library; builds that do not know the kind skip it, which a new `SessionEvent` case would not allow.
`TranscriptState.pullRequest` replays it with a notice. `PullRequestFlow` (UI) hosts the sheet and rechecks the target
or, with a pull request, `hasUnpushedWork` for Push, keyed on the session, the file index, the status and the pull
request. The discard summary names the branch's remote upstream. Tests use a local bare remote and a fake `gh`.

Sessions in a Git project's own folder ([ADR-0043](adr/0043-sessions-in-the-project-folder.md), see *folder
sessions* above) have no worktree, so `removableWorktree` fails for them and neither Push nor Open Pull Request… is
offered.

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

The session inspector (`SessionInspector`, [ADR-0039](adr/0039-t3-style-window-layout.md)) is the rightmost
pane of the detail column, after the transcript and the file pane, toggled by a toolbar button and ⌥⌘I.
`SessionWindowModel.showingInspector` is the working state and a `@SceneStorage` value remembers it per window
(default shown); the inspector exists only beside a displayed session, so the draft has none. Neither the
native `.inspector` nor `HSplitView` is used: the first crashed AppKit beside the split view, and the split view
kept stale divider positions when a pane appeared or the window shrank (ADR-0039, amendments). `RootView` measures
the column with a `GeometryReader` and lays the panes out in an `HStack` with explicit widths from `DetailPanes`.
Visibility: the transcript (at least 240 pt) always stays, the file pane the user opened (at least 240 pt; the
review pane shares its slot) needs 480 pt, and the inspector (220–360 pt) needs 220 pt on top of what is shown, so it
is the first to give way and at the 740 pt minimum it is hidden while a file is open. A hidden pane keeps its state
and returns when the window widens. Widths: the file pane (default 420 pt) and the inspector (default 260 pt) keep the width the user last
dragged them to (`PaneDivider` on each pane's leading edge, also adjustable with VoiceOver; stored in
`SessionWindowModel`); when the column is too narrow the transcript gives way first, then the file pane shrinks
to its minimum, then the inspector, and the three widths always add up to the column. It reads the window's
`SessionWindowModel` and leads with the work ([ADR-0039](adr/0039-t3-style-window-layout.md), amendment). *Plan*
(`PlanSection`, while the displayed transcript has a plan) comes first: one `PlanRow` per entry, the header
`Plan · completed of total`, open while `turnStartedAt` is set and collapsed after the turn (`Section(isExpanded:)`; a
toggle by hand holds until the turn starts or ends). `PlanProgress` (Core, pure) counts the completed entries and picks
the first in progress, reduced to one line like a sidebar reason; the working line and the Working row's reason read
it. `TranscriptState` clears `plan` when a turn starts, so the plan is always the current or the last turn's. Then three
sections: *Changes* (`+added −removed · N files` from `SessionFiles.changeStats`, then Review and Merge into
`<base>`…, then the changed-file list with per-file counts that opens the file pane; Review is the prominent button
while there are changes, and the two share a row only when the pane is wide enough); *Workspace* (one block: the
session branch (the stored name, or `agenthesia/<session id>` for older sessions) with `from <base>`, only for
sessions in an Agenthesia worktree, and the working directory, as
selectable text that wraps; Show in Finder and Open in Editor, through `EditorHandoff` with an empty path, are icon
buttons with tooltips in its header; Discard Worktree… is a plain borderless button at its end); and *Agent* (agent
name, Context and Cost from `ContextUsage` once the agent reported usage, and the Agent Log toggle, live sessions
only). Merge is disabled with the help text `No changes to merge` when
`SessionFiles.hasNoChanges` (the list is current, without an error, and empty), also in the Session menu and the
review pane; while the list loads or failed, the merge sheet decides, as before. Refresh Files shows only with
`SessionFiles.watchError` (`WatchErrorNotice`, beside its message in the inspector and in the review pane's footer).
The path bar under the composer and the sidebar's changed files are gone.

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
| `agent_install` | Local UUID, name, executable, argument array and creation time. Migration `v4-agent-install-installation` adds the optional AgentRuntime installation ID: one row per installed version, `NULL` for a manual command ([ADR-0036](adr/0036-agent-settings-and-installed-sessions.md)). Versioned installation metadata lives in AgentRuntime. |
| `session` | Local UUID, project and agent references, optional agent session ID, protocol version, title, working directory and creation time. Migration `v2-session-base-revision` adds the optional initial Git revision, `v3-session-base-branch` the optional branch the session started from, `v5-session-branch` the optional session branch as created, and `v6-session-archived-at` the optional time the user archived the session (it is the one session column that changes after creation besides the title; the log stays append-only). |
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
updates for other remote session IDs are ignored. Initialization failures close the connection; a
`-32000` answer to the session request leaves the controller ready for `retry` or a new connection
(ADR-0033).

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

A new session is created without a title. After each durable append `SessionController` stores one
([ADR-0039](adr/0039-t3-style-window-layout.md)): the agent's `session_info_update` title when there is one, otherwise,
for a session that has none, `SessionTitle.fromPrompt` of the first user message (the first non-blank line, at most
80 characters). `PersistenceStore.updateTitle` writes it to the `session` row so the sidebar needs no replay; later
prompts never retitle, and sessions created before keep their stored titles. Places that need a string show
"New Session" for an untitled session; the window title is the session title and its subtitle the project name.

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

`ShellEnvironment` caches the login-shell environment per resolver instance; the application uses the
shared instance. `refresh()` captures it again for Check Again. Concurrent refreshes share a capture,
while a refresh supersedes an older ordinary capture. Flight identities prevent the older result from
overwriting the fresh cache or clearing its flight. Previously returned snapshots remain unchanged. The resolver runs the shell
with `-l -i -c` in a new session using `posix_spawn`, so interactive shells cannot stop while trying to
acquire the CLI's controlling terminal. It extracts NUL-separated environment entries between unique
markers and bounds both the captured output (1 MiB) and the wait (5 seconds, plus bounded process
cleanup). Failed resolution returns a fallback environment and a diagnostic without exposing
environment values. The CLI passes the resulting environment explicitly to the agent
and reuses it for terminal authentication; constructing `AgentProcess` does not implicitly run a shell.
A complete, valid snapshot and successful shell exit suffice even when a descendant retains stdout;
the resolver still cleans up the remaining process group.

`NodeRuntime` discovers executable Node/npm from absolute entries in that environment's PATH. It probes
Node in the user's home directory and resolves the actual executable using
[`process.execPath`](https://nodejs.org/api/process.html#processexecpath), bypassing a version-manager
shim for subsequent operations. npm must resolve to the standard `bin/npm-cli.js` entry, either through
its PATH symlink or beside the resolved Node; an opaque wrapper with neither reports an actionable
unsupported prerequisite. It validates npm's package identity and Node engine range, runs `--version`
with the selected Node, and checks supplied package `engines.node` / `engines.npm` ranges using that
npm installation's own [semver dependency](https://github.com/npm/node-semver). No package is downloaded
or added to the app. The installer obtains these requirements from the exact package metadata;
the ACP catalog alone does not supply them.

A Codable `Toolchain` records canonical Node/npm paths and versions, without environment values.
`prepare` rechecks these saved tools before each later operation and reports removed, changed or
incompatible installations instead of switching silently. `Prepared` supplies commands for npm and
JavaScript agent entrypoints, invoking the canonical Node directly and placing its directory first in
PATH for child commands. It retains a value snapshot of the environment and the shell fallback
diagnostic. Empty/relative PATH entries, NODE_OPTIONS and NODE_PATH are excluded from these managed npm
commands so a project directory cannot introduce a different runtime or a relative preload hook.
Manual agent commands keep their existing environment behavior. Arbitrary scripts can still explicitly
launch another interpreter; this is runtime selection, not containment.

`CommandOutput`, extracted from the shell collector, runs bounded prerequisite probes off the Swift
executor with stdin closed, stdout capped at 64 KiB and stderr drained without retaining potentially
sensitive output. Each probe has a 5-second deadline and process-group cleanup; cancellation is checked
before and after the bounded probe. Missing/broken tools, timeouts, invalid metadata/ranges, incompatible
versions and changed saved paths/versions have typed, actionable diagnostics. Runtime checks do not
install, upgrade or remove anything. The API is ready for #35/#36; the current manual-session flow and
running sessions are unchanged.

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

`TerminalProcess` runs an agent terminal's command ([ADR-0015](adr/0015-agent-terminals.md)) or a sign-in
method ([ADR-0033](adr/0033-agent-sign-in.md)). It is spawned with `posix_spawn` as the leader of a new
session; the pseudo-terminal's slave side is opened in the child after the session is created, so it
becomes the controlling terminal, with an 80×24 window unless the caller gives another size.
A bare command is resolved through the command environment's `PATH` and a relative one against its
working directory; a missing executable fails creation with `ENOENT`. Agent terminals write nothing to
the terminal; sign-in writes typing in order on a private queue (dropping what a command has not read
within a second) and sets the window size, both refused once the master side is closed. Output observers
receive the retained bytes, then each chunk as it is read, until the end of output. The master side is read continuously, because a terminal's last close waits for its output
to be read; raw bytes are retained up to the output limit (1 MiB by default), dropping the oldest in
batches so that noisy commands append in amortized constant time. The read source runs on a private
serial queue; the process source that reaps the command has its own, because its blocking `waitpid` can wait for
the command's last close of the terminal, which waits for the reader (#178). The initial sizing slave remains open until the
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

`AgentRegistry.Catalog` reads the stable v1 registry, retains metadata and unsupported distribution
kinds, and selects the exact macOS architecture's binary before npm. Python-only agents have an
explicit unsupported result. Unknown fields are ignored; invalid known metadata, duplicate IDs and
unsupported schema majors reject the response. Package references are metadata, not shell commands;
the installer pins an unversioned package to the entry's version.

`AgentRegistry.Client` refreshes the official HTTPS index with a 1 MiB response limit and bounded
request/resource timeouts. Concurrent refreshes share one request per client; cancelling a waiter does
not cancel shared work, and that waiter throws after the bounded refresh completes. Use one client per
cache directory. Raw catalog data, ETag and last validation time are stored in one atomically replaced
`registry-v1.json` file on a Dispatch queue. A 304 reuses only a validated cache whose ETag was sent.
Refresh failures return a valid old catalog with an explicit warning and its original validation time;
without a valid cache they throw. Cancellation throws rather than returning stale data. Cache write
failure leaves fetched metadata usable with a warning, but cannot guarantee offline availability.
The client uses an ephemeral URLSession without shared caches, cookies or credentials, and follows
redirects only within the registry's HTTPS origin. It does not download icons, install or start agents,
and is not wired into the app yet (#36).

The app displays the bounded stderr tail in its Agent Log panel ([#15](https://github.com/anesthetised/agenthesia/issues/15)).
`AgentInstaller` owns `Application Support/Agenthesia/Agents/<agent-id>/<version>` under
[ADR-0035](adr/0035-installer-storage-and-script-policy.md). Each version contains a payload, an ownership
marker, a lease file and `installation.json` with format version 1, a unique installation ID, registry
identity, command, declared environment, source, timestamp and (for npm) the checked toolchain and engine
requirements. It never persists the captured login-shell environment. This store is separate from
Persistence's manual command records; windows and history adopt installations in #36.
`AppSupport.directory` (AgentRuntime) is the app's folder in `Application Support`: `Agenthesia` for the original
bundle identifier and when there is none (tests, the CLI), `Agenthesia-<suffix>` for `….Agenthesia.<suffix>`. `just app`
builds the `.dev` identifier, so a development build keeps its history, installs and registry cache apart from the
installed app's. `AgentInstaller`, `AgentCatalog` and `SessionLibrary` all take their paths from it; worktrees stay in
`~/.agenthesia/worktrees`, and the folders of sessions without a project in `~/.agenthesia/scratch`.

Operations stage beneath the owned root and publish by an exclusive, same-volume rename after validation.
Cancellation or failure removes that operation's staging files and preserves existing versions. Updates
are explicit installs of another version; an existing version is never overwritten. A root advisory lock
serializes the synchronous steps of operations (listing, lease validation, publication, removal) across
installer actors and app instances, and overlapping steps report busy. It is never held across a download,
an npm run or a shell capture, so installing one agent does not block launches (ADR-0036).
Every launch must acquire and retain a shared version lease for the entire authentication/session
lifetime, including terminal sign-in. Release it only after all owned processes exit; copying its
`AgentCommand` does not retain the lease. Removal requires an exclusive lease and validated ownership.
These are cooperating-client locks, not a sandbox against another process running as the owner.

Binary downloads use credential-free HTTPS, including CDN redirects, with a 256 MiB limit and bounded
timeouts. Declared SHA-256 checksums are verified before extraction. `CLibArchive` links the macOS system
library; a small header declares the stable ABI because the SDK omits libarchive headers. The reader
accepts tar/zip and built-in none/gzip/bzip2/xz filters; it never enables an external decompressor.
It copies at most 10,000 entries and 1 GiB of regular file data into a fresh private directory, rejects
links, special/encrypted files and escaping paths, and preserves only whether a file is executable.
The selected command must be a regular executable inside the payload.

npm installs an exact package version into a private prefix with lifecycle scripts, audit and funding
requests disabled. Configuration and cache are isolated from the user's npm files. Package metadata,
engines, the JavaScript entrypoint and the generated lockfile are validated; the manifest and lockfile
remain beside `node_modules`. Launch uses the pinned Node executable and installed script directly,
without npx or network resolution, after revalidating the saved runtime. Missing entrypoints explain
the disabled-script policy. Some script-dependent packages fail only when launched: #36's bounded ACP
readiness probe must report that failure without enabling scripts. Cancellation of npm/probes terminates
the captured process group before cleanup.

`AgentCatalog` (AgenthesiaCore) backs Settings → Agents and the draft's Agent chip: the registry snapshot,
installed versions newest first, the Node.js check with Check Again, and install, update, cancel and
removal through the installer. `LiveSession` acquires an installed version's lease before creating a
worktree, runs chat and terminal sign-in with the leased command, and releases the lease once the agent's
processes have exited and the session has ended or failed. The catalog also keeps local agents
(ADR-0037): `LocalAgentDiscovery` looks up a built-in table of known ACP commands, and ordinary `claude` and
`codex` CLIs that need a registry adapter, on the login shell's `PATH` without running them. The user adds
found or custom commands; the list is a Codable array in `UserDefaults`, and a session with a local agent
records a manual `agent_install` row as before. `AgentProbe` launches a command in an empty temporary
directory, sends ACP `initialize` under a timeout, then closes the connection and terminates the process
group; it creates no session and does not prove sign-in. Pre-session sign-in remains in #36. Runtime
validation and explicit shell refresh are implemented. The shell/probe
`posix_spawn` implementation addresses a terminal interaction found while reviewing
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
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (1.99.1+; with swift-png and h, Apache-2.0, linked on other platforms only) | MIT | `AgenthesiaUI` |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) (with swift-cmark, BSD-2-Clause) | Apache-2.0 | `Rendering` |
| [STTextView](https://github.com/krzyzanowskim/STTextView) (with STTextKitPlus, BSD-3-Clause, and CoreTextSwift, MIT) | GPL-3.0 or commercial; used under GPL-3.0 | `Rendering` |
| [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) (with tree-sitter, MIT) | BSD-3-Clause | `Rendering` |
| tree-sitter grammars: Swift, TypeScript/TSX, JavaScript, Python, JSON, Markdown, Bash, Rust, Go, YAML | MIT | `Rendering` |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | `acp-cli` |
| [Sparkle](https://sparkle-project.org) (later) | MIT | App |

Dependencies are added when the milestone that needs them starts, not up front.

### Pinning notes

- **SwiftTerm** builds with a build tool plugin, so `xcodebuild` runs with `-skipPackagePluginValidation`
  (`just app`) and Xcode asks once to *Trust & Enable* it.
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

Live sessions advertise form elicitation and answer matching session-scoped requests in the composer (#326).
`SessionWindowModel.dockedInput(_:)` builds a `DockedInput` for the oldest of `SessionController.pendingInputs`,
keeping its `InputDraft` (values, text and the current step) per session until another form docks; `InputDock` shows
it at the top of the composer card. `InputStep.steps(_:)`, a pure function of the schema, groups the fields into steps:
a choice followed by an optional plain string is one step, any other field its own, in the order of the names with
numbers compared by value, since the decoded schema keeps no order. While a form docks, `RootView` binds the
composer's text to the step's text field instead of `ComposerDraft`, which is left untouched and so comes back
afterwards; `ComposerInput.keyAction(answering:)` and `choiceIndex` route Return (advance), Escape (decline), ↑ ↓ and
1–9 (pick), and `ComposerPrimaryAction` reads `next` or `answer`, so Return never queues behind the turn that waits
for the answer. The transcript shows a waiting form as a compact row (`LiveTranscriptSource.waitingInput`) and an
answered or cancelled one as `InputForm`'s record. Requests and final responses are committed before display and
delivery; drafts remain temporary UI state. Stop, withdrawal, failure, turn completion and close cancel pending forms.
Saved forms have no active controls; Continue records cancellation of interrupted requests.
Agent-provided regular expressions share a 20 ms budget of thread CPU time spent matching. Other
field validation and time spent descheduled do not consume it; regex compilation is outside this budget.

Request-scoped elicitation is explicitly declined, including requests made before a durable session
exists. Supporting those requests needs a separate startup interaction and persistence design
([#111](https://github.com/anesthetised/agenthesia/issues/111)). URL
elicitation remains unadvertised.
