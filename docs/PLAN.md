# Work plan

The near-term order of work, for agents and humans picking up the next task. Milestones and issues on
GitHub stay the source of truth for scope; this file records order, dependencies, and the pitfalls known
so far. Update it when a step lands or the order changes.

Every step follows [AGENTS.md](../AGENTS.md): issue → branch → tests and docs → pull request after the
owner's approval. Architectural choices are presented to the owner as options with a recommendation
before implementation.

## State (2026-10-17)

- Live sessions run end-to-end ([ADR-0014](adr/0014-window-bound-live-sessions.md)): tool call
  cards, permission requests, scoped filesystem, agent-reported command output
  ([ADR-0016](adr/0016-agent-reported-command-output.md)).
- Saved history opens read-only; Continue reattaches it to its agent
  ([ADR-0017](adr/0017-continue-saved-sessions.md)).
- Tool call diffs render as unified diffs with word-level highlights (#20); side-by-side is not scheduled.
- The composer attaches files as `resource_link` and lists the agent's slash commands
  ([ADR-0018](adr/0018-composer-attachments.md), #18).
  Command rows retain their names inside the Commands accessibility group and use command names for
  identity and scrolling. Attachment chips retain their file icons across draft edits.
- Session config controls show confirmed settings between turns (#23,
  [ADR-0019](adr/0019-session-config-controls.md)); responses are committed before later notifications.
- The durable prompt queue supports editing, ordering, grouped sends and steering (#65,
  [ADR-0010](adr/0010-prompt-queue-and-steering.md), [ADR-0021](adr/0021-prompt-queue-lifecycle.md)). Stop
  pauses it; continued sessions require explicit queue resume. Ended sessions remain available to Continue.
- Native session-scoped elicitation forms appear in the transcript (#24,
  [ADR-0020](adr/0020-native-elicitation-forms.md), [ADR-0022](adr/0022-session-scoped-elicitation.md)).
- Client-side `terminal/*` is deferred (#104), so the rest of M5 waits.
- Quick Open, the side file viewer and changed-file tracking (#26–#28) are merged (#113)
  under [ADR-0023](adr/0023-session-files.md). New Git sessions retain their initial revision; legacy
  sessions show working changes only. Changed Files compares with the session base rather than the
  merge base (#114, #115, [ADR-0024](adr/0024-changed-files-session-base.md)). Transcript paths open
  the file pane at a line, and Open in Editor hands off to the chosen editor (#29, #116,
  [ADR-0025](adr/0025-transcript-paths-and-editor-handoff.md)). M4 is complete.
- M7 slices 1–2 are merged in PR [#118](https://github.com/anesthetised/agenthesia/pull/118)
  (#37, [ADR-0026](adr/0026-app-wide-session-manager.md)): app-wide ownership supports parallel
  sessions, closing a window detaches it, and the sidebar groups sessions by project with live statuses.
  Local `just lint`, `just test` and `just app` pass; coverage is enforced by CI.

## Previous batch: session interactions (merged)

| # | Issue | Depends on | Model and effort |
|---|-------|------------|------------------|
| 1 | #23 Config options picker | Approved ADR-0019 | Sol, medium |
| 2 | #65 Prompt queue and steering | Approved ADR-0021 and ADR-0010 | Sol, high |
| 3 | #24 Native elicitation forms | Approved ADR-0020 | Sol, medium |

The owner approved these decisions on 2026-10-16. All three landed in main through #112 and their
issues are closed. They were developed in isolated worktrees and integrated in the order above.

### 1–2. Config options, prompt queue (#23, #65)

- Both extend the composer from #18 (`ComposerInput` in `AgenthesiaUI/Composer.swift`). Its key
  handling is the pure `ComposerInput.keyAction`; Command-Return sends now even while the editor is
  first responder. Queue edits retain non-text attachment blocks.
- The behavior of #65 is fixed by [ADR-0010](adr/0010-prompt-queue-and-steering.md); queue entries are
  persisted in the event log. Queued prompts must keep their attachments.
- [ADR-0019](adr/0019-session-config-controls.md): native config controls, idle-only changes and
  agent-confirmed values committed before display; legacy modes stay in the adapter.
- [ADR-0021](adr/0021-prompt-queue-lifecycle.md): Stop pauses the queue; restored entries require Continue
  and explicit resume. Command-Return sends a nonempty draft only; with no draft it sends the queue
  ([ADR-0028](adr/0028-empty-draft-sends-queue.md)). Command-Shift-Return sends queued entries
  plus the nonempty draft last.
- `AgentProfile.steering` already reports whether the agent supports injection.

### 3. Elicitation forms (#24)

- `LiveSession` enables form elicitation; the controller validates and owns session-scoped requests.
  See [ADR-0009](adr/0009-tools-and-mcp.md).
- [ADR-0020](adr/0020-native-elicitation-forms.md): native transcript forms, durable requests and final
  answers, temporary drafts, cancellation on lifecycle termination. URL elicitation is separate work.
- [ADR-0022](adr/0022-session-scoped-elicitation.md): #24 supports established session scopes only;
  request-scoped forms are explicitly declined. Pre-session presentation, persistence and request
  lifetimes are deferred to [#111](https://github.com/anesthetised/agenthesia/issues/111).

### Integration and verification

- The shared base is `fee57ab`, containing the composer and approved decisions. This batch retains
  the composer dependency if it has not landed on main.
- Shared integration points are `SessionController`, `SessionEvent`, `TranscriptState`, `LiveSession`
  and `RootView`. Keep config confirmation, queue admission and form cancellation on the existing
  ordered event path. Queue draining waits for accepted config changes rather than losing its retry.
- Stop must supersede earlier pending steering/resume operations. Injection preparation retains
  recoverable content until acknowledgement; a pre-wire cancelled prompt is requeued and marked not
  sent. A wire turn ending during preparation falls back to a new turn without losing the draft.
- Close drains admitted config, queue and form work. Reopening cancels unfinished forms and leaves
  restored queued entries paused; a failed process reaching `closed` must still offer Continue.
- Use Sol high for lifecycle changes and integration. Medium is sufficient for bounded view work.
  Review changed SwiftUI/AppKit views with `swiftui-pro`. Serialize full builds/tests across worktrees;
  use `just lint`, `just test`, `just coverage` and `just app` for the integrated batch. Benchmarks,
  push and PR creation retain the approvals in `AGENTS.md`.

### Acceptance

| Issue | Acceptance criteria and focused verification |
|---|---|
| #23 | Select/grouped/boolean controls and legacy modes; confirmed settings replay correctly; rejected changes retain confirmed values; prompt submission cannot overtake a config change. |
| #65 | Queue editing/reordering/deletion preserve attachments across replay; combined sends retain message identity; shortcuts, pause/resume and steering obey ADR-0010/0021 under turn-end/cancellation races. |
| #24 | Supported fields validate required values and constraints; optional text can be omitted after editing; concurrent requests resolve once; stop/close/cancellation and recovery leave no pending callers or active historical forms; responses persist before delivery. |

The integration regressions cover config change → send → enqueue → form request → steering/Stop →
close → restore/Continue, checking ordered events, retained attachments and explicit queue resume.
Native hosted-view tests cover form sizing at narrow widths and draft identity across transcript
updates. Integrated `just lint`, `just test`, `just coverage` and `just app` pass; Core line coverage is
97.8%, above its 90% gate. Native app smoke checks cover form submission, attachment-preserving queue
edits, steering shortcuts, Stop, End Session, Continue and explicit queue resume. Keyboard actions and
accessibility labels were inspected; a spoken VoiceOver pass remains manual. Config response ordering
and model selection are covered by protocol tests; native popup selection was not completed by UI
automation.

CI pins Xcode 26.6 and runs package coverage and the app build in parallel with separate incremental
build caches. The aggregate `Lint, test, build` status requires both jobs to pass; cache hits still run
all checks. Badge publication runs only after both succeed on main.

## Next steps

M4 (Files) is merged: #26–#28, #114 and #29 below. M7 slices 1–2 merged in #118, closing
#37 and replacing window-bound ownership with the app-wide manager
([ADR-0026](adr/0026-app-wide-session-manager.md)). #39 and #117 were developed concurrently in
isolated worktrees from `706dbf8` and are integrated on `feat/session-controls-and-recovery`.
The owner accepted [ADR-0027](adr/0027-recoverable-prompt-errors.md) before #117 implementation.

The combined branch passes `just lint`, `just test` (587 Swift tests and 15 script tests),
`just coverage` (all module gates; Core 98.1%) and `just app`.

This batch ends at #39 and #117. #40 and #38 have not started. When that work resumes, #40 owns
window opening, selection and restoration; #38 connects notifications to that mechanism and adds the
Dock badge. M8 (Worktrees) follows M7 and also decides whether to pin the base with a ref.
Use Sol medium for bounded UI work and Sol high for lifecycle changes such as #117.
Small independent chores such as #73 (CI with Xcode 27) fit Sol at medium effort.

### M7 slices (2026-10-17)

The owner accepted ADR-0026. Slices 1–2 are merged; slice 3 (#39) is implemented in this batch.
Implement slice 5 (#40) before slice 4 (#38), so notification activation reuses window opening and
selection.

| # | Slice | Acceptance and verification | Model and effort |
|---|---|---|---|
| 1 | `SessionManager` in Core owns every `LiveSession`; windows select one; closing a window detaches; quit closes all owners; the `SessionLibrary` live claim moves into the manager | Several sessions run at once; Continue on a live session selects it; a failed session stays until ended or continued; quit waits for every owner, including one still starting | Opus, high; merged in #118 |
| 2 | Sidebar: projects → sessions with derived statuses and the in-memory *done* mark | Status priority (needs input, failed, working, done, idle) is a pure tested function; showing a session in a key window clears *done*; accessibility labels | Sol, medium; merged in #118 |
| 3 | Quit confirmation and the Session menu (#39) | Confirmation only when a session works or needs input; previous, next and next-needing-input navigation in sidebar order | Sol, medium; implemented, verification below |
| 5 | Multiple windows and restoration (#40) | Window opening and selection are shared with later notification activation; value-based `WindowGroup` restores selections read-only with Continue; no agent starts on relaunch | Sol, medium; not started |
| 4 | Notifications with actions and the Dock badge (#38), after #40 | Posted only when the session is not in the key window of the active app; Allow once and Reject only for `allow_once`/`reject_once`; badge counts sessions needing input; system seams injected | Sol, high; not started |

#39 adds focused-window Session commands, wraparound sidebar navigation (including saved history and
Starting), next-needing-input navigation, and a count-based quit confirmation before awaited shutdown.
New regression tests cover command eligibility, independent window selections, navigation, cancellation
and retry, idle/failed shutdown without confirmation, and resuming a paused empty queue to restore
normal Return behavior. The isolated #39 branch passed `just lint`, `just test` (579 Swift tests and
15 script tests), `just coverage` and `just app`; every module met its coverage gate (Core 98.1%).
`swiftui-pro` review found no blocking issues. Native menu focus/shortcuts and the actual quit alert
remain manual smoke checks; automated tests exercise selection, eligibility and injected confirmation.

Manual acceptance of the combined #39/#117 PR confirmed new-session/navigation and permission
shortcuts. Follow-up feedback adds empty-draft Command-Return to send the complete queue
([ADR-0028](adr/0028-empty-draft-sends-queue.md)), and native sidebar selection synchronized with
mouse and keyboard navigation. Regressions first reproduced the rejected empty send and the missing
native selection. Remaining native checks: queue shortcuts and selection, recoverable `fail` with the
rebuilt client, fatal `exit`/Continue, selected-session End, and quit confirmation/cancellation.
The follow-up passed `just lint`, `just test` (590 Swift tests and 15 script tests), `just coverage`
(all gates; Core 98.3%), and `just app`. Queue and native sidebar regressions were verified RED then
GREEN; the native selection check also fails when the binding is removed. `swiftui-pro` and code review found no blockers.

Pitfalls: parallel starts with one agent raced in `SessionLibrary.install` (a duplicate insert failed the
second start); installs are now serialized. The window model keeps its own selection token for history loads; a window may display an
owner the manager already removed, which then reads as ended. Run `swiftui-pro` over changed views.
CI exposed a process-readiness polling race: a task can resume after its deadline with the child PID
already recorded. Check readiness before the deadline; regression tests cover both a ready PID and a
missing PID after expiry.
Issues close with the slice that completes them: #37 with slice 2, #39 with slice 3, #38 with slice 4,
#40 with slice 5.

### Prompt error recovery (#117)

[ADR-0027](adr/0027-recoverable-prompt-errors.md) is accepted and implemented on
`fix/prompt-error-recovery`. A JSON-RPC error response ends the turn, retains the live connection and
process, and pauses the queue without retrying it. Transport loss, invalid responses, process exit,
failed event writes and failed cancellation delivery remain fatal. MockAgent's `fail` and `exit`
exercise these paths separately, including agents without resume/load support.

Regressions cover error-response codes, a successful next prompt on the same session, replay,
attachment-preserving queues, explicit send/resume, pending permissions and forms, steering,
injection preparation, Stop, close and write failures. Register permission requests before awaiting
their initial event write, so turn completion can cancel them during that write. The regression
blocks the cancellation write and verifies that the session stays busy until it commits.
`just lint`, `just test` (582 Swift tests plus 15 script tests), `just coverage` and `just app` pass; Core line
coverage is 98.1%, above its 90% gate. The error-response and permission-admission regressions each
reproduced their failure before the fix; inverting the recovery condition also made the regression
fail. Filesystem tests separately cover retained access after a prompt error and revoked access after
transport loss.

### #29 slices (2026-10-17, merged in #116)

The owner accepted ADR-0025. One branch, `feat/clickable-paths`, one commit or more per slice, in order:

| # | Slice | Acceptance and verification | Model and effort |
|---|---|---|---|
| 1 | Core: path candidate parsing and resolution; editor table and URL construction | Suffixes `:line`, `:line:col`, `#Lline`; `./` dropped; absolute inside root → relative; outside root, `..`, symlinked escape → nil; percent-encoding of spaces, `#`, `?` and non-ASCII in editor URLs; table without a line template | Sol, medium; done |
| 2 | `SourceView` line navigation | Scroll a line into view and select it; clamp past the end; works before and after highlighting finishes; hosted-view test | Sol, medium; done |
| 3 | Structural links and the file pane: tool locations and diff paths, `agenthesia-path` interception, Open in Editor (⌥⌘O), Markdown switches to Source for a line | Click opens the pane at the line for the displayed session only; links never reach `NSWorkspace`; stale clicks after session switch are ignored | Sol, medium; done |
| 4 | Settings scene with the editor picker | Installed editors only, "System default" first, choice persists; missing editor falls back to the default app | Sol, medium; done |
| 5 | Inline code links with index-driven restyling | `Rendering` marks inline code generically; restyle on every index publication, bounded by cached rows; streaming rows keep their text; benchmark before/after | Opus, high; done, [benchmark](benchmarks/2026-10-17/transcript-links/README.md) |

Pitfalls: `Rendering` must not import Core; resolution reuses `ScopedFileAccess` canonical roots;
`SessionFiles.open` already guards the session identity. Run `swiftui-pro` over changed views before
committing slices 3–5. The owner approved slice 5's benchmark (200 rows with 20 inline spans each
against a 10,001-path index, three Release runs). Manual checks by the owner: mouse clicks on tool and inline links, VS Code, Cursor and Zed line jumps,
Settings and VoiceOver labels pass; Xcode's scheme ignores the line, so Xcode opens files at the start.
The pane button's ⌥⌘O did not fire, so Open in Editor is a File menu command; its shortcut, the
changed-file list after an ACP write and the unavailable-file layout were checked again.
Push and the pull request keep their separate approvals; save `just coverage` output to a log file.

### M4 parallel batch (2026-10-16)

The owner approved [ADR-0023](adr/0023-session-files.md): a side file pane and an initial Git revision
saved for new sessions. Existing sessions explicitly show working changes only; non-Git folders
support browsing and explain that change tracking requires Git.

| Issue | Owner and files | Acceptance and verification | Model and effort |
|---|---|---|---|
| #26 Quick Open | Index/search and palette, isolated worktree | Tracked/untracked/ignored paths, non-Git traversal, unusual names, deterministic bounded search, keyboard/focus/accessibility tests | GPT-6.1-Sol, medium |
| #27 File viewer | Bounded reads, Core document loader, source/Markdown views, isolated worktree | Scoped regular UTF-8 reads, 2 MiB boundary, binary/missing/errors, source/preview selection and hosted resizing tests | GPT-6.1-Sol, medium |
| #28 Changed files | Git changed paths, FSEvents bridge and successful ACP write invalidation, isolated worktree | Committed plus working changes, metadata-only events, selected-folder scope, external edits, cancellation/lifetime tests | GPT-6.1-Sol, high |
| Integration | Initial revision migration/capture, Core file state and RootView | Preserve base across start/replay/Continue; stale work cannot overwrite new selections; switching sessions and closing windows stop observation | GPT-6.1-Sol, high |

All file navigation uses the displayed session's working directory. RootView and shared presentation
state have one integration owner. The streams were integrated from separate worktrees, with Swift
build/test commands serialized. The owner approved the initial-revision migration and benchmark
workload before implementation and execution. Push and PR creation retain their separate approvals.

### File batch verification

The integrated suite has 523 Swift tests and 15 script tests. Regressions cover initial-revision
migration and start/replay/Continue preservation, committed and working paths, linked-worktree Git
metadata, ACP/external write invalidation, stale searches/selections, cancelled attachment/read tasks,
root symlink replacement during a scan, and watcher closure. The scan regression checks transient
publication, rather than only the final list after an FSEvents retry.
Review fixes keep search results and selection through background refreshes without progress flicker,
limit sustained rescans to one per second, exclude Git object/reflog events, report watcher failures
without clearing the index, skip non-UTF-8 names and unreadable subdirectories, and keep files across
Continue. `just lint`, `just test`, `just coverage` and `just app` pass after the review fixes. Coverage remains above every module gate: Core 97.9%, Workspace 97.5%, Persistence 100%, Rendering 97.5%, ACP 99.0%, JSONRPC 98.7%, AgentRuntime
92.6% and CLI 88.7%.

Hosted native tests switch Markdown Preview/Source at 740, 900 and 1000 pt widths and bound a long
source line to its viewport. Native app checks cover Command-P, arrow/Return selection, changed-file
navigation including committed paths, external updates and Reload, binary-file errors, Preview/Source,
divider resizing and closing the pane. Source views accept the proposed viewport size to prevent
native constraint-update recursion; the detail container accepts its available width to avoid clipping
the whole split view. Keyboard access and accessibility labels were inspected; spoken VoiceOver
verification remains manual.

The approved three-run Release benchmark passed every count/content validation. Medians are 101.552 ms
for indexing 10,001 files, 192.190 ms for all 20 fuzzy queries, 87.378 ms for 100 changed paths and
0.712 ms for a bounded 2 MiB read. These are initial API timings, not an improvement or UI-latency claim;
see [raw results and limitations](benchmarks/2026-10-16/files/README.md).

## Open research

Not scheduled, pick up when they block something: #77, #78, #83 (transcript and highlighting hitches),
#97 (streaming performance), #98 (raw-notification contract), #91 (`posix_spawn` lifecycle).
