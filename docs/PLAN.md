# Work plan

The near-term order of work, for agents and humans picking up the next task. Milestones and issues on
GitHub stay the source of truth for scope; this file records order, dependencies, and the pitfalls known
so far. Update it when a step lands or the order changes.

Every step follows [AGENTS.md](../AGENTS.md): issue → branch → tests and docs → pull request after the
owner's approval. Architectural choices are presented to the owner as options with a recommendation
before implementation.

## State (2026-10-29)

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
  pauses it; continued sessions with retained entries require explicit queue resume. Ended sessions remain available to Continue.
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
- M7 is complete: session controls and prompt error recovery (#119), window restoration (#120),
  notifications and the Dock badge (#121). The app icon and the Dock tile (#122) deliver the icon half of
  #45; its first-run flow remains open.
- M8 (Worktrees) is complete under [ADR-0032](adr/0032-worktree-merge-and-discard.md): the base branch (#123),
  discard (#124), review (#125) and squash merge (#127).
- Agent sign-in (#32, [ADR-0033](adr/0033-agent-sign-in.md)) is merged in #128.
- `ScenarioAgent` tolerates a saturated main actor in CI (#129); the saturation itself remains.
- M6: the registry client (#33), Node/npm checks (#34) and installers (#35) are merged; #36 is split into
  three slices under [ADR-0036](adr/0036-agent-settings-and-installed-sessions.md). Slice 1 (Settings →
  Agents, the agent picker and session leases) is merged in #141; slice 2 (local agents and the initialize
  probe, [ADR-0037](adr/0037-local-agents.md)) is merged in #142; slice 3
  (pre-session sign-in) is in progress under the owner-approved [ADR-0038](adr/0038-pre-session-sign-in.md).
- M15 (UI/UX redesign, #144) is planned under [ADR-0039](adr/0039-t3-style-window-layout.md) and
  [ADR-0040](adr/0040-composer-first-session-start.md); see the M15 section below.
- M15 follow-ups are accepted as ADR amendments and ADR-0041 (#195, 2026-11-06); ADR-0042 is deferred. #190, #192,
  #193 and most of #191 landed (#199–#202); the implementation issues are #203–#215, at the end of the M15 section.

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
all checks. Coverage builds once, then runs the remaining core tests, AgentRuntime tests and hosted
UI/Rendering tests in three sequential invocations before merging their profiles (#133). Each group
retains parallel tests; no test or coverage threshold is omitted. Badge publication runs only after both
jobs succeed on main.

### Coverage test isolation (#133, 2026-10-27)

[Main run 40511015178](https://github.com/anesthetised/agenthesia/actions/runs/40511015178), on `5365bb0`,
failed only the 60-second limits of `toolCallsUpdateInPlaceAndReplayIdentically`,
`continueFailuresKeepTheHistory` and `mergeCommitsTheSessionEndsItAndRecordsTheOutcome` (63.5–64.0 s).
The combined 715-test run took 85.7 s; many unrelated successful tests also took 50–60 s. App build and
lint passed. This is consistent with #133's cross-target main-actor contention, not a Registry failure.
Local Xcode 27 runs separate test-target processes by default, so its green run did not reproduce the
CI runner's combined bundle.

The owner chose to separate hosted `AgenthesiaUITests`/`RenderingTests` from their complement rather
than serialize every test. `coverage.py` builds once, then runs the two groups sequentially using the
same regex for `--skip` and `--filter`. Tests within each group retain parallelism. Each invocation
keeps its 120-second process timeout; test time limits and coverage thresholds are unchanged. Both
groups run even if the first fails, and either failure fails the command. Group-specific profile names
prevent replacement on PID reuse; reporting still merges every profile and enforces all module gates.

Regression tests first failed against the single invocation. A deliberate selector mutation duplicated
the hosted group and omitted other tests; the partition test failed before the mutation was restored.
Local `just test-scripts` passes 18 tests, `just test` passes 735 Swift tests, and split `just coverage`
passes 550 non-hosted plus 185 hosted tests and every coverage gate (AgentRuntime 92.9%). The two
instrumented invocations took 43.7 s and 22.6 s locally, including runner overhead; these are validation
run times, not a benchmark or a CI speedup claim. Three corrupt raw profiles were excluded through the
existing merge policy. The same selectors were also verified with instrumented `just test
--build-system native`, which retains the combined test bundle: 550 non-hosted tests passed in 15.1 s,
including all three original failures, and 185 hosted tests passed in 16.4 s. These are bundle-reported
times excluding build/driver overhead. `just lint` and `git diff --check` pass.

The main-actor profiling, audit of machine-dependent waits and consecutive green CI runs in #133 remain
open. The failing GitHub run cannot validate unpublished changes. No benchmark or native-app UI check
was run for this test-runner change.

PR #137's [first run](https://github.com/anesthetised/agenthesia/actions/runs/40518505904) stopped at
lint before exercising the split: Xcode 26.6's `NeverUseForceTry` rule rejected two JSON fixture
encodings that the local Xcode 27 formatter had accepted. The fixture now records encoding errors as
test issues instead of using force try. The lint rule remains enabled. `just lint` and full `just test` pass for this follow-up (735 Swift tests
and 18 script tests). PR #137 subsequently passed its required checks and merged into main.

### CI Markdown attribute crash (#126, 2026-10-25)

The [original failed run](https://github.com/anesthetised/agenthesia/actions/runs/40134242723/attempts/1)
used macOS 26.6.2 (25G83), Xcode 26.6 and Swift 6.3.3. It aborted during the first quarter-second of
the test run in `NSAttributeDictionary.mutableCopyWithZone`, called by `MarkdownRenderer.inlineCode`.
This is a copy of the string's existing font/color attributes; the stack does not identify the new
background color or inline-code marker as the nil value. The string is local and has not been published,
and paragraph styles are applied later. Inspection found no mutation of shared attributes on this path.
Cold AppKit initialization remains a hypothesis, not a diagnosis.

On macOS 27.0.1 / Xcode 27.1, all 71 Rendering tests passed. Six fresh-process runs combining
`marksInlineCodeForCallers`, `hostedSettingsKeepTheStoredChoice` and
`previewIsSelectableReadOnlyAndAccessible` passed, as did an isolated inline-code control. These runs
used `just test --build-system native -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping`
with the test-name filter, to retain CI's single test bundle and instrumentation. They do not prove
safety on the failing OS/toolchain.

Thread Sanitizer reported no races in the 73-test Rendering/hosting diagnostic run, but
`SourceViewTests.highlightsALargeFile` exhausted its existing highlighting wait under the sanitizer,
so that run failed. The three-test cold-initialization scenario passed separately under Thread Sanitizer.
These are correctness diagnostics, not benchmarks; no performance conclusion is drawn from their timings.

The failed CI run retained no full crash report, so the other threads and framework image versions are
unavailable. After a coverage failure, CI allows 30 seconds for macOS to write test-runner `.ips`
reports, then attempts to upload them from both DiagnosticReports directories. Missing reports produce
a warning, and the failed check stays failed.
The artifact is named `test-crashes-<attempt>` and retained for 14 days. Inspect it on the next recurrence
before choosing a fix. No renderer change or reproducing regression has been justified; #126 stays open.

Validation: `just lint`, full `just test` (674 Swift tests and 15 script tests), `just coverage` (all gates;
Rendering 97.9%), `just app` and `actionlint .github/workflows/ci.yml` pass. Coverage discarded one corrupt raw profile
through its existing merge policy. Review found and addressed the asynchronous report-writing gap;
the wait recipe also resolves correctly with `just --dry-run wait-for-test-crash-reports`. Uploading a real
report on macOS 26 remains unverified until CI runs the change and a crash recurs. Native-app, VoiceOver
and system-prompt checks were not performed for this CI-only change.

## M15: UI/UX redesign (2026-10-29)

Tracking issue #144. The owner compared the running app with T3 Code and approved a status sidebar, a
T3-style transcript, a composer-first session start and a right inspector:
[ADR-0039](adr/0039-t3-style-window-layout.md) and [ADR-0040](adr/0040-composer-first-session-start.md).
The issues are small enough for the light tier except #155 and #158.

| Wave | Issues | Notes |
|------|--------|-------|
| 1 | #145 titles, #146 sidebar model, #149 line counts, #151 transcript column, #153 notices and errors, #154 working time, #156 composer card | Independent |
| 2 | #147 sidebar rows, #148 search, #150 inspector, #152 bubbles, #157 Continue card | After their wave 1 dependency |
| 3 | #155 tool folding (strong), #158 composer-first start (strong) | #155 after #151 and #152; #158 after #156 |
| 4 | #159 New Session in Project, #160 verification and screenshots | Last |

Pitfalls known so far:

- `RootView.swift` (#147, #150, #156, #157, #158) and `TranscriptTable.swift` (#151, #152, #155) are shared;
  merge in table order and rebase.
- Transcript changes are performance-sensitive: #151 and #155 rerun Rendering Lab scenarios after the
  owner agrees on the workload.
- ACP config options and slash commands exist only after `session/new`, so the draft of #158 cannot offer
  model or mode; ADR-0040 accepts that.
- The research run could not drive the launch form through accessibility, so it created no test session;
  tool cards were reviewed from the code. #160 checks the finished design with `MockAgent`.

Wave 1 landed (2026-10-29), one pull request per issue, each with `just lint`, `just test` and `just app`:

- #149 (#162): `SessionWorkspace.changeStats` and `SessionFiles.changeStats` count added and removed lines
  against the session base; no UI yet (#150).
- #154 (#163): `SessionController.turnStartedAt` and the `Working for …` line above the composer.
- #153 (#164): session notices are centered captions; failed prompts show `PromptFailure.summary` with a
  Details disclosure.
- #145 (#165): sessions start untitled and are named by the agent or the first prompt; the window shows the
  project as its subtitle.
- #146 (#166): the sidebar is grouped into Needs You, Working and Settled; rows carry their project.
- #156 (#167): the composer is a floating card with a round Send/Stop button and pill config menus.
- #151: the transcript column is centered (`TranscriptColumn`) and Copy shows on hover. Rendering Lab S1:App and
  S2:App were run with the owner's approval ([results](benchmarks/2026-10-29/transcript-column/README.md)):
  scrolling is unchanged within noise, streaming shows a few more single-frame hitches.
- #147: sidebar rows show a project badge (`ProjectBadge` initials, FNV-1a tint), the project and any Merged/Discarded
  outcome on a second line, the status symbol and a `RelativeTime.short` age (`now`, `5m`, `3h`, `2d`, `3w`, then
  `12 Oct`). Settled is collapsed by default with its count in the header (`@SceneStorage`; it stays open while one
  of its rows is selected); Refresh History is gone. Covered by unit and hosted-view tests only.

- #144 (Refs): Settled is pinned to the bottom of the sidebar as a footer (`SettledFooter`) instead of a section of the
  list ([ADR-0039](adr/0039-t3-style-window-layout.md), Amendment 2026-10-30): always-visible `Settled · N` header,
  growing upward to at most 45 % of the sidebar when expanded, hidden without saved sessions. Hosted-view tests
  measure the lists' geometry; the header's accessibility label is unit-tested only (the hosted accessibility tree
  is empty), and the footer was not seen in the running app.
- #150: `SessionInspector` is the rightmost pane of the detail column (toolbar button and ⌥⌘I,
  `@SceneStorage`, only beside a displayed session) with Workspace, Branch, Changes and Agent sections;
  `SessionChangedFiles`, the path bar and the toolbar's Agent Log button are removed. ⌥⌘I was Next Session
  Needing Input, which moved to ⇧⌥⌘]. The first version used the native `.inspector`, which crashed the app
  (`EXC_BREAKPOINT` in `-[NSWindow _postWindowNeedsUpdateConstraints]`) whenever the pane count of the
  `HSplitView` changed or a session started; see the amendment in ADR-0039. `DetailPanes` hides the inspector,
  then the file pane, when the detail column is too narrow. A real-app check then found three `HSplitView` layout
  faults (a pane off the right edge after opening the file pane or after shrinking, and the split view 19–40 pt
  short of the edge at 740 pt), so the panes are laid out with explicit widths from `DetailPanes` and drag handles
  instead of an `HSplitView` (ADR-0039, amendment 2). Hosted-view tests run `RootView` at 740, 1000 and
  1400 pt through every inspector and file-pane combination and through resizes; hidden-pane behavior in the real
  window is for #160.
- #157: `ContinueCard` replaces the composer card for saved, ended, failed, starting and merging sessions and those
  with a merge or discard outcome: a symbol and the state (`Saved session`, `Session ended`, `Connection failed`,
  `Merged · read-only`, `Discarded · read-only`, `Merging…`) and a prominent Continue button when
  `model.outcome(of:) == nil` and `canContinue`. The composer's status text and `RootView.statusText` are gone.
  Covered by unit tests of `ContinueCard.State` and hosted-view tests (the card in isolation and a saved session in
  `RootView`); not seen in the running app (#160).
- #148: the sidebar has a native search field (`.searchable(placement: .sidebar)`, ⌥⌘F focuses it through
  `searchFocused`, Session → Search Sessions). `SessionSidebar(query:)` keeps the rows whose title or project name
  `localizedStandardContains` the trimmed query (case and diacritics ignored) and drops empty sections, so the list,
  the Settled footer (forced open while a query is entered, its count shows the matches) and Previous/Next Session
  all see the same visible rows; with no match the sidebar shows `ContentUnavailableView.search`. Deviation from the
  issue text: Previous/Next Session follow the filter rather than ignoring it. Covered by unit tests, a navigation
  test and a hosted-view test; the field itself and ⌥⌘F were not seen in the running app.

Wave 2:

- #152: user messages are right-aligned bubbles (`BubbleCell`, `quaternarySystemFill`, radius 14, padding 10 × 14, at
  most 80 % of the column, `TranscriptColumn.bubbleWidth`); `not sent` and `sent together` are a caption under the
  bubble. Agent rows lost their role label; thoughts keep `Thinking` and are dimmed. Covered by hosted-view tests
  (bubble width at three table widths, row height, resize, caption refresh); not seen in the running app (#160
  checks the design). Rendering Lab S1:App and S2:App were run with the owner's approval
  ([results](benchmarks/2026-10-30/user-bubbles/README.md)): streaming is unchanged. A quiet,
  interleaved rerun of S2:App (five runs per side) shows scrolling slightly smoother: p95 30.5 against 36.0 ms,
  p99 32.8 against 44.4 ms, about 3% fewer missed frames. The hitch count rises only because more frames are
  delivered; at this scroll speed nearly every frame misses the 120 Hz budget on both sides.
- #158: the launch form is replaced by the draft (`SessionDraftView`, ADR-0040): Project, Agent and Checkout above
  the composer text; Send starts the session and `LiveSession.initialPrompt` is submitted at the first idle state,
  after sign-in when needed; a failed or cancelled start returns the draft with its error and removes the owner. The
  last agent is kept in `UserDefaults` (`lastAgent`); the default project is the one of the newest session, derived
  from history. A detached `HEAD` shows its short commit ("New worktree from 1a2b3c4"). Tested: Core tests with
  MockAgent for submission with an attachment, sign-in then submission, a failed start and a start cancelled while
  waiting for the login shell; catalog choices, names and the remembered agent across a reopened catalog;
  `ProjectRecord.recent`; `worktreeBase` on a branch, an unborn branch and a detached `HEAD`; window-model tests for
  the defaults, an empty draft, Send, a failed start and Cancel Startup at sign-in; one hosted `RootView` test that
  a failed start shows the draft again. Checked in the running app by script (separate bundle identifier, isolated
  home, MockAgent, window-only screenshots): the draft in light and dark, the Project and Agent menus, Choose
  Folder…, an empty Send, Send with MockAgent, a missing executable, `--auth` then cancel at sign-in, and the
  defaults after relaunch. That check found three problems, now fixed: failed starts replaced the remembered agent
  (it is now remembered once the initial prompt is submitted), a stale error stayed after picking another agent, and
  the Custom Command sheet cut off long paths. It also found #176: a start cancelled at sign-in leaves its worktree
  and branch, as the launch form did. Not checked: VoiceOver, Manage Agents…, a detached `HEAD` and a non-Git project
  in the app, attachments in the draft, the dark Send flow, and the Custom Command sheet after its fix (#160).

- #176: a start that never got a history record removes its worktree and branch (`LiveSession.removeUnstartedWorktree`
  from `fail` and `close`, `SessionWorkspace.removeUntouched`): it asks the store for the record, and keeps both when
  the tree has uncommitted or untracked paths or the branch has commits, or on any error. Tested with real temporary
  repositories and MockAgent: cancel at sign-in, an agent that exits after the worktree was prepared, a started session
  that keeps its worktree after End Session, a stray file, a commit on the branch and a non-Git folder; breaking the
  removal (and, separately, the record check) made those tests fail. Not tested: a failure after the record was written
  (only the started-session case covers the record check), a failure inside `SessionWorkspace.prepare` after
  `git worktree add`, quitting the app during removal, and the removal in the running app.
- #155: consecutive tool calls fold into a summary row (`TranscriptRow.fold`, `ToolGroupSummary`), and the table
  inserts and removes only changed rows. Covered by unit tests of the folding and every wording, and by hosted-view
  tests of expanding and collapsing, in-place streaming updates (row views, selected text and table selection
  survive), Copy as Markdown, follow-bottom, a kept scroll position and resizing. Rendering Lab S7:App now folds and the
  new S8:App toggles the group while streaming. New S9:App repeats S7 on a 10,000-item history. A running call shows its
  bare title (`just test…`): agents' titles are often verbs, so the issue's `Running just test…` would read
  `Running Run tests…`. Rendering Lab, 3 interleaved rounds, load 3–8, 70–72% free memory
  ([results](benchmarks/2026-11-02/tool-groups/README.md)): S9 shows no cost from folding a long history; S1 and S7 hit
  somewhat more often, which 3 runs could not tell from noise. A quiet rerun (5 interleaved rounds, load 1.4–3.2, 85%
  free memory, clean `527cb3c` against `e0b1a66`) settled it: S1 is unchanged, and S7 is slightly worse (median 20
  hitches against 17, worst frame 22 ms against 17 ms), the cost of rebuilding the summary row on every tool update.
  Accepted for now.
  Running app, MockAgent, isolated home, light and dark: folding, expansion, a single card, follow-bottom, a kept scroll
  position, Copy and a group that keeps growing. Not checked: a permission request ending a group (MockAgent cannot
  produce one; covered by a hosted test), the bare title with a verb title, the status color fix on a selected row (seen
  red before the fix; covered by a hosted test) and VoiceOver. Known limits: a selected card loses its selection when
  it folds, ⌘C with only an expanded summary selected copies nothing, collapsed cards copy truncated text, and an older
  group whose last call never finished keeps showing its title while the session runs.
- #159: the context menu of a sidebar row (live or saved) offers New Session in Project when the row has a project:
  `SessionWindowModel.newSession(in:)` sets `draftDirectory` and shows the draft, keeping the typed message and agent.
  Tested: a window-model test that the draft opens with the older session's project over the newest default and keeps
  its text. The menu item itself is not reachable in hosted views. Running app, MockAgent, isolated home, light and
  dark: the item on live and saved rows opens the draft with the row's project, keeps the typed text and starts nothing.
  Not checked: VoiceOver and a row without a project. The draft's toolbar title still shows the session that was open
  before.
- #183: in a pane wider than 768 pt the transcript column sat off center, because its fill constraint (priority 750)
  outranked AppKit's width for the cell (500) and the cell shrank. The fill constraint now sits just below it. A hosted
  test covers user, agent, tool, group and streaming rows at 500, 864 and 1364 pt and fails without the fix. Not yet seen in the running app (#160).
- #185: the draft's toolbar title and subtitle named the session still displayed behind it, because the draft only hides
  the session. `SessionWindowModel.windowTitle` and `windowSubtitle` now give `New Session` and no subtitle in the draft;
  a window-model test covers both states. The earlier note that a failed Continue's error carries into a new draft was
  not reproduced: the draft reads only `draftError`, which a resumed session never sets, and the error seen was the one
  under the saved session's composer. Not yet seen in the running app (#160).
- #178, probe timing: `AgentProbeTests.aSilentCommandTimesOutAndIsTerminated` took 5.03 s and then 5.88 s against its
  5 s bound on slow CI runners (a 300 ms timeout and a 1 s grace period), twice in one day, with the whole core group
  twice as slow as on main. The bound is now 15 s, still under the 20 s default. The two failures in #178's title are
  not fixed by this; the issue stays open.
- #189: text typed in the composer was lost when the window showed another session, because one `prompt` state served
  the whole window and was reset on every switch. Each session now keeps its text, attachments and queue edit in
  `SessionWindowModel.composerDrafts` while the window lives. A queue edit whose message was sent meanwhile returns the
  saved draft. Tests: window-model tests of both, and a hosted test that types into the real text view, switches and
  sends with Return; it fails when the switch resets the draft. Not yet seen in the running app (#160). Not checked: ⌘Z
  right after a switch, which keeps using the same text view and undo stack as before.
- #194: ⌘F finds in the transcript, including what folded groups and collapsed cards hide; a step expands them, scrolls
  to the row and selects it, and ⌥⌘G jumps to the next failed tool call. Copy now returns a tool card's whole output, and
  an expanded summary selected alone copies its cards. Tests: search, reveal, marking, copying and stepping in hosted
  views, and the bar selecting a match in a hosted `RootView`. Not measured: the search on a long session, and Rendering
  Lab, because the streaming path gains nothing while find is closed; only the check that it is closed. Not seen in the
  running app, including whether ⌘F reaches the menu from the composer and whether Escape closes the bar (#160).
- #190: status lines no longer contradict the state. `WorkingTimeLine` reads `Waiting for you`, with the sidebar's
  orange icon instead of the spinner, while a permission request or an input form is pending, instead of a running
  `Working for 1s`. A pending permission card's `Waiting for your answer` is orange (a new `attention` tone), as the
  sidebar's Needs input already was; it was the running accent blue. The empty state drops `Choose a project and an
  installed ACP agent.` while a session starts. Tests: the line's text in both states, and the card's tone per phase.
  Not tested: the empty state, which needs a session in the middle of starting. Running app (scripted, MockAgent, isolated
  home, light and dark): the line and the card while a permission waits, and the line after it is answered. Not checked:
  an input form (MockAgent has none without a scenario), the empty state while starting, and VoiceOver.
- #192: session errors show a short sentence with Details (the raw text) and the action that fits, in the transcript
  column, instead of `RPCError(code: -32002, message: "Unknown session", data: nil)` across the detail column.
  `SessionFailure` classifies the stored text, like `PromptFailure`: an unknown session offers New Session; an exited
  agent or closed connection, Agent Log; other agent errors, Agent Log; a missing or removed agent, Manage Agents. There
  is no Retry: the Continue card under the transcript already reconnects. The draft also offers Manage Agents when no
  agent is installed and none is chosen. Tests: the wording and actions of each case against real
  `RPCError`/`ConnectionError` descriptions, the offered actions, and a hosted banner that stays inside the 720 pt column
  in a wider window (it fails without the width bound). Not tested by a hosted `RootView`: which actions each place
  offers, and the button clicks. Running app (scripted, MockAgent, isolated home, light and dark): a missing executable,
  an agent that exited, and Continue of a saved session that the agent no longer knows. That check removed Retry, which
  repeated the Continue button above it, and the no-agent line, which showed beside a chosen custom command and doubled
  the banner's Manage Agents. Not checked: VoiceOver, the config error and the `-32000` case.
- #193: Queue and Save show their name beside the arrow in a capsule button, Send and Stop stay round; the Send options
  menu says "(Interrupts Turn)" on Send Now while a turn runs and lists Stop Turn; Session → Focus Composer (⌘L) moves
  keyboard focus to the composer's text from the transcript, the sidebar and the inspector. The claim that Stop is
  missing from the menu while a draft exists did not hold: Session → Stop and ⌘. only depend on a running turn. Tests:
  the action's labels, the window model's request counter and a hosted `RootView` that takes focus away and gets it
  back. Running app (scripted, MockAgent, isolated home, light and dark): the Queue capsule while a permission waits, the
  Send options items during a turn, and ⌘L from the sidebar and the transcript. Not checked: Save while editing a queued
  message, ⌘L from the inspector or a text field in the file pane, ⌘. with a draft, and VoiceOver.
- #191: polish from the UI/UX review. The Send options menu hides its second chevron; Review Changes has its own symbol
  (`text.badge.checkmark`) and stays disabled while the sign-in panel shows; the Branch and Agent inspector rows are
  labeled `Name` instead of repeating their section title; a tool card without details keeps an invisible, disabled
  disclosure, so the icon column does not shift; the sign-in panel uses the composer's card style and 720 pt column.
  A group says `made 2 edits` instead of `edited 2 files`, because it counts calls, not distinct paths (`read N files`
  has the same problem and is left as is). ADR-0040 now says ⇧⌘N. Tests: every `ToolGroupSummary` wording, the icon
  position of a card with and without a disclosure, and `canReview` through a sign-in. The branch-name item moves to the
  readable branch names issue under ADR-0039's amendment (#196). Running app (scripted, MockAgent, isolated home, light
  and dark): one chevron on Send options, the Review symbol and `Name` rows in the inspector, aligned icons in an
  expanded group with and without a disclosure, `made 1 edit` in a group summary, and the sign-in panel in the column
  with Review disabled until signed in. Not checked: the Agent row's label and VoiceOver.
- #205: the diff line model and the quote builder for the review pane (ADR-0041), without UI. `UnifiedDiff.parse`
  (`Rendering`) turns `make`'s output into `DiffLine`s, one per text line, with the old and new number and, for a removed
  line, the new line that follows it. `DiffQuote.make` (`AgenthesiaUI`, next to `LiveTranscriptSource.fenced`) builds the
  Ask agent quote: new-file ranges (`7-13, 25-29`), `42 (removed)` for lines with nothing kept beside them, the lines in
  a `diff` fence, and the `(from an earlier version…)` note. Hunk headers stay out of the quote. Tests: every line
  kind, several hunks, a new and a deleted file, a missing final newline, and quotes within a hunk, across hunks and of
  removed lines only. Not wired to any view yet (#213, #215).
- #203: a sidebar row says `project · reason` and shows its last activity. `SidebarReason` (Core) derives the reason from
  `LiveSession.Activity` and the controller (`Sign in`, `Allow? <title> +n`, `Question`, `Failed`, `Starting`,
  `Stopping`, `Merging`, `Finished`, `Refused`, `Hit a limit`, `Prompt failed`, `Queue paused`; a merged or discarded
  worktree keeps its label); `TranscriptState.lastTurnFailed` marks a rejected prompt. A permission request that names
  its call only by id takes the title from the log (`PendingPermission.callTitle`); `toolTitle` and the notification
  text are unchanged. The time is `SessionController.lastActivity` (the minute of the last stored event, seeded when
  history loads) or, for saved sessions, `PersistenceStore.lastEvents()` through `SessionLibrary.lastEvents()`, which
  also supplies the outcomes, so no query was added. Settled sorts by it; Needs You and Working keep start order. The
  project truncates first, to 40 % of the line, then the reason (`SubtitleLayout`); a tool title is cut to its first
  line and 120 characters; the tooltip and the accessibility label hold the whole row. Tests: a case per reason, title
  cutting, live reasons against `MockAgent`, last activity of live and saved sessions, the Settled order, the width
  rule and a hosted row that stays one line high. Not tested: the `Question` and `Merging` reasons against a real
  agent and merge (the pure function only), and the sidebar's refresh after a session ends. Running app (scripted,
  MockAgent, isolated home, dark): `Finished` with the unseen dot, `Allow? Write note.txt`, `Prompt failed` staying in
  Working, `Failed`, `Sign in`, last-activity times, the accessibility labels, and Settled after a relaunch (its order
  there matched start order too, so the sort is shown by tests only). The check found a gap after a cut project, as the
  next text followed the project's share instead of its width, and a label that kept `last active now` while the time
  moved on; both are fixed, the gap with a hosted test that fails without the fix. At the default 240 pt sidebar a
  permission reason is cut to `Allow? Writ…`, as the rule says. Not checked: light mode, VoiceOver itself.
- #204: the inspector leads with the work. Order is Changes, then one Workspace block (branch with `from <base>`, path;
  selectable, wrapping, no repeated labels; Show in Finder and Open in Editor are icon buttons with tooltips in its
  header; Discard Worktree… is a borderless button at its end), then Agent. In Changes the summary is followed by
  Review (prominent while there are changes) and Merge into `<base>`…, then the file list, so the actions stay in view.
  Merge is disabled with `No changes to merge` when `SessionFiles.hasNoChanges`, in the inspector, the Session menu and
  the review pane; Refresh Files shows only with `watchError`, beside its message (inspector and review footer). The
  branch name is unchanged (readable names are #208). Tests: `hasNoChanges` with Git, without Git, attached and
  edited; Merge's state, help text and sheet without and with changes and with an unknown list; the notice with and
  without a watch error and its refresh clearing it; the existing hosted `RootView` and section-height tests. Running
  app (scripted, MockAgent, isolated home, dark): the order, Merge disabled with `No changes to merge`, Review prominent
  and Merge enabled once a file changed in the worktree, the Workspace block with its header icons and their help texts,
  and Discard at its end. Not checked: a watch error (MockAgent cannot cause one; covered by a hosted test), light
  mode, the stacked buttons at the inspector's minimum width, and VoiceOver.
- #206: the oldest pending permission is docked above the composer (`PermissionDock`). `DockedPermission` shows the kind
  and paths, the title, the first diff with `+n more files`, `1 of n` while several are pending, and a wrapping row of
  the agent's options with ⌥⌘1…⌥⌘9 shown beside the names; the hidden shortcut buttons on the composer card are gone,
  as the card's buttons carry them. `PendingPermission.toolCall` keeps the call as known when the agent asked, so the
  card does not read the transcript. `PermissionArming` ignores input for 400 ms per request, the card never takes
  focus, and VoiceOver announces each request. The transcript's permission card and its buttons are unchanged until
  #207, so the diff is still shown in the transcript too. MockAgent's `writes <n> <text>` raises n requests at once
  (`note1.txt` …). The clip-view risk needed no fix: the table's own `layout()` follows the end when the clip view
  shrinks, and a table test that fails without that hook covers it; the hosted `RootView` test passes even without the
  hook, because later transcript updates also follow the end. Tests: the card's state for one and several requests,
  shortcuts, arming with an injected instant, answers reaching only the oldest request, wrapping, the MockAgent
  command, and a hosted `RootView` that keeps following the end and the composer's focus while the card appears and
  goes. Running app (scripted, MockAgent, isolated home, dark): one card for `writes 3 hello` with `1 of 3`, the shortcuts
  shown on the buttons, a double ⌥⌘1 answering one request only (arming), ⌥⌘1 and ⌥⌘2 answering while text is typed
  in the composer, which keeps the text and focus, and the card leaving after the last answer. The check found the
  card stretched to the 40 % bound with blank space around a one-line diff, because its flexible frame took the height
  it was offered; it now hugs its content and the diff scrolls only past the bound, with a hosted check that fails
  without the fix. Not checked: VoiceOver's announcement, Full Keyboard Access, a narrow window, light mode.
- #208: new sessions get a readable, stored branch name. `SessionWorkspace.branchName` gives
  `agenthesia/<words>-<first 8 hex digits of the session id>`: the words come from the first line of the initial prompt,
  transliterated with ICU's `Any-Latin; Latin-ASCII; Lower`, reduced to runs of `[a-z0-9]` joined with `-` and cut at a
  word boundary to at most 40 characters; `session` without a prompt or usable characters. A name that already exists
  falls back to the legacy `agenthesia/<session id>`, and the existing branch is untouched. The worktree directory stays
  the session id. Migration `v5-session-branch` adds a nullable `session.branch`; older sessions keep the derived legacy
  name, in removal and in the inspector. `Worktree` takes the stored name and accepts it only under `agenthesia/` with
  this session's `-<8 hex>` suffix, or the exact legacy name; otherwise discard and merge refuse with `notRemovable` and
  delete nothing. Tests: naming (Latin, Cyrillic, Chinese, accents, emoji, long text) with `git check-ref-format` for
  each, the removal check, the migration on a database file made by the v4 schema with a session and an event, and real
  temporary repositories for creating, the collision fallback, merging and discarding with a stored name, an untouched
  worktree removed after a cancelled start, an old session without a stored name (discard and merge), and stored names
  that fail the check (another session's, `feature/x`, no suffix, outside the prefix), which keep their worktree and
  branch. Running app (scripted, MockAgent, isolated home, dark): `Fix the note parser` made
  `agenthesia/fix-the-note-parser-a0fbe75f`, shown in the Workspace block and in `git branch`, with the worktree directory
  still named by the session id; `Исправь парсер заметок` made `agenthesia/isprav-parser-zametok-2b8dc91e`; Discard
  named the readable branch in its confirmation and removed the branch and the worktree. Not checked: merge with a
  readable branch in the app (covered by repository tests), a session made before the change, light mode.
- #207: a permission request is a one-line record in the transcript (`Allowed once · Edit · Write note.txt`,
  `Waiting for you · …` while pending) with a Details disclosure for the call and the outcome; it reuses the folded
  group's header-only row, so no new row layout was built. The permission buttons and `choosePermission` left
  `TranscriptTable` and `TranscriptSource`. A tool row whose call has a pending request omits its diff
  (`toolCard(hidingDiffs:)`) and shows it again after the answer. Row heights change only there. Tests: the
  record for allowed, rejected and cancelled requests, Details unfolding and folding, `Waiting for you` becoming the
  answer, no push buttons in any permission row, Copy of a folded and an unfolded record, the tool row hiding and
  restoring its diff, and follow-bottom and a kept scroll origin across that change. Running app (scripted, MockAgent,
  isolated home, dark): `writes 3 hello` gave three `Waiting for you · Edit · Write noteN.txt` records without buttons,
  which turned into green `Allowed once` and red `Rejected once` at ⌥⌘1 and ⌥⌘2, and Details showed the call, its diff
  and the returned answer. The check found a double gap between the status and `· Edit`; the record's header now keeps
  them as one phrase, with a hosted test that fails without it. Not checked: the hidden diff inside an expanded group
  in the app (hosted tests cover it), light mode, VoiceOver, a Rendering Lab run (no new row layout).
- #213: review is a pane of the detail column (ADR-0041). ⌃⌘R and Review in the inspector toggle it in the file pane's
  slot (`SessionWindowModel.showingReview`, own width `reviewWidth`, 560 pt); opening a file hides it, hiding it brings
  the file back, and Escape closes it without a selection. `SessionReview` reads the selected file before replacing
  anything: an equal document changes nothing, and while the diff has text selected a change is held with
  `File changed · Show latest`. The diff is `DiffTextView`, a TextKit 1 text view on `UnifiedDiff.parse` with a ruler of
  old and new numbers, replacing `MarkdownPreview` in review; the merge sheet moved to `RootView`. Contiguous layout,
  because non-contiguous layout and TextKit 2 put far lines at estimated positions, which broke the ruler and the kept
  top line. Large diff (`ReviewDiffTests`, measured, no benchmark run, load average 28–37 from other runs): a
  5,000-line file rewritten (10,001 diff lines) renders in 0.16–0.4 s off the main actor, shows and draws in 30–50 ms,
  and lays out to its end in 0.15–0.27 s on the first scroll there; the old path diffed and rendered the same diff as Markdown in about 0.17 s, also off the main
  actor, so no benchmark was added. Tests: the toggle and the slot in every pane combination at 740, 1000 and
  1400 pt, the hold, Show latest, an unchanged file and streaming leaving the text view, selection and scroll position
  alone, Escape, the merge sheet from `RootView`, the diff's lines and numbers, and the hold logic in Core. Viewed marks
  and line counts are #214, Ask agent #215. Running app (scripted, MockAgent, isolated home, dark): ⌃⌘R opened and
  closed the pane, the list and the numbered diff showed two changed files, and a file changed while text was selected
  held the diff under `File changed · Show latest`, which then showed the new line. The check found the gutter's edge
  line drawn through the pane's header and the toolbar, the whole height of the window: the ruler drew past its bounds,
  which views no longer clip by default. It now clips, with a bitmap test that fails without it. Not checked: light
  mode, Escape and Merge… from the pane in the app, VoiceOver; the ruler's numbers are not exposed to it.
- #211: the draft's hints are applied at start (ADR-0040's amendment), without pills yet (#212).
  `AgentCatalog.configHints` caches each agent's mode and model options from every confirmed list
  (`SessionController.onConfigOptions`, through `LiveSession` and `SessionManager.catalog`), in a `configHints` defaults
  dictionary. Send passes `SessionWindowModel.draftHints`: the cached model, and a mode only when picked in
  `draftConfig`. `createRemote` sets them after `session/new` and before the record, in the agent's order, and drops
  the config notifications each response supersedes, so the `started` event holds the final list; a value the agent no
  longer offers or refuses throws `HintRejected`, so the draft returns with no history row and no worktree. MockAgent
  gained `--no-config` and `--reject-config`. Tests with MockAgent: an applied model, a picked mode applied with the
  model (which fails without dropping the superseded notification), an unpicked mode left alone, an equal value that
  sends nothing, a refused and a no-longer-offered hint (no row, no worktree, branch gone, cache updated), an agent
  without config options, a change in the session updating the cache, and the cache across a reopened catalog
  (installed, local and custom agents, undecodable entries). Running app (scripted, MockAgent, isolated home, dark):
  after Large was picked in one session, the next session from the draft started on `Model: Large` with the mode left
  at Ask. Not checked: a rejection in the app (a `--reject-config` command is a different agent with no cached hints;
  tests cover it), light mode.
- #209: *Done* clears when the end of the finished turn was on screen, not when the window is key (ADR-0026's
  amendment). `SessionController.lastResultItem` records the transcript's last item when a turn ends on its own;
  `LiveSession.unseenResult` gives it while the turn is unseen, and `markSeen(reaching:)` sees every turn only for the
  latest one. `SessionWindowModel.unseenResult(appearsActive:)` passes it to `LiveTranscript` only while the window
  appears active and shows the live session. The table resolves it to a row (`TranscriptRow.row(showing:in:)`: a folded
  group's summary, or the item's own row) and checks the pure `TranscriptTableController.showsEnd(of:in:)` (bottom edge
  in the visible rect, 24 pt tolerance), coalesced to one check per main-queue turn after an update, a table layout, a
  scroll or a clip-view resize; it observes the clip view only while a target is set. With no target, the per-update
  path only tests it for `nil`. For #210: `followsEnd` and `scrollToEnd()`. Tests: the pure check (visible, partly
  visible, scrolled away, within the tolerance, a shrunk and a grown clip), the folded and expanded row, Done staying
  off screen and clearing when scrolled in or after the jump, a growing clip, an item not yet displayed, a window that
  is not active, the latest turn's end against an earlier one, and no check running without a target (a counter).
  Breaking the nil guard, the update hook or the bottom-edge rule made a test fail; in hosted tables the table's own
  layout already runs on every scroll and clip resize, so no test fails without the clip-view observers, which stay
  as the ADR's explicit watch. Rendering Lab S1, S7 and S9, five interleaved rounds with the owner's approval, load 6–9
  after a first round at 11–18 ([results](benchmarks/2026-11-07/done-on-screen/README.md)): no cost visible; frame
  percentiles and apply latency are the same on both sides. Running app (scripted, MockAgent, isolated home, dark): a
  result scrolled away kept the row in Needs You with `Finished` while the window was key, and scrolling to its end
  cleared it. A second check with #210, dark and light (`-NSRequiresAquaSystemAppearance YES`), showed `Finished` for
  a slow reply that ended below the viewport and cleared it after Jump to Latest. Not checked: a window that is not
  key, a folded group as the last row, VoiceOver.
- #212: the draft shows the cached mode and model as pills (ADR-0040's amendment). `SessionConfigControls`' select menu
  became `ConfigSelectMenu`, shared with `SessionDraftView`, which draws the pills after Attach as secondary with the
  tooltip and accessibility note `Last used with this agent; confirmed when the session starts`. `draftValue(of:)` is
  the one rule for a pill's value, and `draftHints` is built from it, so a pill equals what Send applies: the picked
  value if the agent offered it (a stale pick is dropped), else the cached model; a mode reads `Default mode` until
  picked. Changing the agent clears the picks. Tests: pills from the cache and none without, picked values equal the
  hints, a stale pick, reset on agent change, a hosted `RootView` showing the pill titles (before and after the cache,
  a pick, an agent change) and the pill's accessibility text. Running app (scripted, MockAgent, isolated home, dark
  and light, the light pass with `-NSRequiresAquaSystemAppearance YES`): after one session the draft showed `Default
  mode` and `Small` dimmer than the project and agent menus, in both appearances and after a relaunch; the first build
  drew them in full colour, because a borderless menu ignores `.foregroundStyle`, so they use `.opacity`. The tooltip
  and the accessibility label carry the note. Not checked: the reset on an agent change (only MockAgent was set up;
  tests cover it), VoiceOver.
- #210: `New response below` and Session → Jump to Latest (⌥⌘↓), ADR-0026's amendment. ⌥⌘↓ was free among every key
  equivalent in `SessionCommands`, `RootView`, `FileCommands`, `SessionDraftView`, the sheets, the Debug menu and the
  composer's own handler (none uses an arrow key). `TranscriptState.End` (last item, content blocks, last block's length,
  command output bytes) is what the table remembers when `followingBottom` turns false and compares in `update` only
  while not following, so a following reader's per-update path is unchanged; `EndPosition` (`following`, `scrolledUp`,
  `newBelow`) is reported to `SessionWindowModel.endPosition` on a later main-queue turn and only on change.
  `NewResponseButton` is overlaid at the transcript's bottom edge in `RootView`; its click and the menu item call
  `jumpToLatest()`, answered by `scrollToEnd()`. Tests: the end's identity for a new item and more text, the capsule
  for a new item and for more text in the last one while scrolled up (and again after returning), not for scrolling
  alone or an update that leaves the end, not while following, the jump resuming following and clearing a waiting
  Done, the menu state at the end, scrolled up and in the draft, and a hosted `RootView` with `MockAgent` where a reply
  while scrolled up reaches `newBelow` and `jumpToLatest()` follows the end. Breaking the end comparison or the jump's
  `scrollToEnd()` made tests fail. No Rendering Lab run: the following path only gained an `if` on `followingBottom`'s
  else-branch. Running app (scripted, MockAgent, isolated home, dark and light, the light pass with
  `-NSRequiresAquaSystemAppearance YES`): with the transcript scrolled up, a slow reply showed the capsule while it
  streamed and after it ended; ⌥⌘↓ with the composer focused and a click on the capsule, also while the reply streamed,
  scrolled to the end and removed it. Session → Jump to Latest is listed with ⌥⌘↓. A click sent while the `Working`
  line disappeared missed, probably because the capsule moved down with it. Not checked: VoiceOver.
- #214: viewed marks and line counts in the review pane (ADR-0041). `ViewedMarks` keeps a mark per file with a
  `stat` fingerprint (status, size, modification time); a refresh drops the marks whose file changed or left the list
  (`ViewedMarks.surviving`, pure and tested), and a `touch` clears one too. The row's button and ⌥⌘V (*Mark Viewed and
  Go to Next*, free among every key equivalent in the app) set marks, ⌥⌘V then selects the next unviewed file;
  `SessionWindowModel` keeps the marks per session, so they survive closing the pane and reviewing another session, not
  closing the window. Rows show `SessionWorkspace.changeStats` counts against the review's own merge base, the footer
  `2 of 5 viewed`. Tests: marking, unmarking, ⌥⌘V advancing and wrapping, a mark clearing on a changed file and staying
  on an unchanged one, a file leaving and returning, the counts in real temporary repositories, the footer summary, and
  the marks outliving the review in `SessionWindowModel`. Running app (scripted, MockAgent, isolated home, dark and
  light, the light pass with `-NSRequiresAquaSystemAppearance YES`): three changed files showed `+2 −1`, `+3 −0` and
  `+2 −0` in the list and `0 of 3 viewed`; ⌥⌘V marked the selected file and moved to the next unviewed one, wrapping to
  the first; a click on a row's circle marked it; rewriting a viewed file cleared its mark and updated its counts; the
  footer reached `3 of 3 viewed`. Session → Mark Viewed and Go to Next is listed. Not checked: VoiceOver; the hosted
  SwiftUI list exposes no accessibility tree to tests, so the row's button and counts are not asserted there. A renamed file shows counts as a deletion plus an addition (`changeStats` uses
  `--no-renames`), not as the net edit.
- #215: Ask agent in the review pane (ADR-0041). The footer, the diff's context menu and Session → Ask Agent (⌥⌘A,
  free among every key equivalent in the app) call `SessionWindowModel.askAgent()`, which quotes the selected diff lines
  (`DiffTextView.lines(in:lineStarts:)`, pure, then `DiffQuote.make`) at the composer's caret and focuses the composer;
  nothing is sent. A quote from a held diff carries the earlier-version note. It is disabled, with the reason in its
  help text, when the session cannot take a prompt. Tests: a selection growing to whole lines, hunk headers left out
  and a selection across two hunks; insertion at the caret and after selected text, keeping the draft; the hosted
  window's composer receiving the quote at its caret and first responder; the stale note through the context menu;
  disabled with help text once the session ended. The footer button and the menu command call the same
  `askAgent()`, but SwiftUI buttons and menu commands cannot be pressed in a package test, so only the context menu's
  item is pressed there. Running app (scripted, MockAgent, isolated home, dark and light): ⌥⌘A with the caret inside a
  draft put `notes.txt:3` and its fence there, keeping the text on both sides, and moved focus to the composer; the
  footer button quoted a selection across two hunks as `notes.txt:6, 22-23` without the hunk header; the context menu
  lists Ask Agent first and quoted at the caret; with the diff held after a file change the quote carried the
  earlier-version note; nothing was sent. Without a selection the footer button is disabled with “Select lines in the
  diff…”, and after End Session it and Session → Ask Agent are disabled with “Session ended: the session cannot take a
  prompt”. The same check found the review file list cut its last row at the divider; its height estimate now
  includes the list's insets, checked with one and three files. Not checked: VoiceOver, Undo of an insertion.
- #178, follow-up check (2026-11-07, Xcode 27 under load, eight CPU burners): neither failure recurred on CI since
  #180 (about 60 runs). Lost terminal output: with the exit source back on the reader's queue, 19 of 19 runs of
  `keepsTheOutputOfManyConcurrentQuickCommands` and the issue's test failed; with #180's fix 23 of 23 passed.
  `htmlIsShownAsCode` crash: the CI report shows the stored `.font` value was a null object (`x0` = 0, cast from
  `AnyObject`) while another thread ran `+[NSFont systemFontOfSize:weight:]`, which fits #126's `insert nil object` in
  a copied attribute dictionary. Not reproduced: 40,000 racing cold font creations and 3.2 million attribute-dictionary
  round trips on 16 threads (standalone, no nil), and, without the `@MainActor` mitigation, 23 Rendering runs and 3
  instrumented hosted-group runs. With the mitigation, `htmlIsShownAsCode` passed 11 of 11 Rendering runs, but
  `SourceViewTests.highlightsALargeFile` timed out in 3 of them, against none of the 23 without it; the main-actor
  suites probably delay its highlighting. The crash's cause stays unproven; no product change was made for it.
- #253, `SourceViewTests.highlightsALargeFile` timeouts (2026-11-07, Xcode 27, the Rendering tests under 24 CPU
  burners on a machine already at load 40–60): the main-actor suites were not the cause. The test polled 200 times
  at 10 ms, a count and not a time; one pass took 17–73 ms under load, so the window was 3.5–15 s, while
  highlighting 10,000 lines in the background took 4–8 s (1.9–3 s with eight burners). Applying the colors on the
  main actor took 62–95 ms in all 48 instrumented runs, with or without `@MainActor` on the suites, so nothing
  queued there. The mitigation even lengthened the window: a busy main actor stretches each pass. Without it 11 of
  12 runs needed more than 200 passes, with it 3 of 12. Before the fix the real test failed 11 of 12 runs without the
  mitigation and 7 of 12 with it; after, 12 of 12 passed with it. `SourceView.highlightTask` now holds the latest
  highlight and the tests await it (`renderedColor` and `replacedTextIsNotHighlightedLate`, whose 300 ms sleep could
  also pass too early). The mitigation stays unchanged, so the #126 exposure is the same.
- #251, hosted test windows (2026-11-07, Xcode 27): `OffscreenWindow` replaces the hand-made `NSWindow`s of the UI
  tests (`[.titled]` or `[.titled, .resizable]` and no `.fullSizeContentView`), which showed on screen during
  `just test` and drew `RootView`'s toolbar as an opaque band over the top of the detail column and the inspector.
  The helper uses the style mask of the `WindowGroup` window and sits at (-30000, -30000). A `RootView` screenshot with
  the old window and with the helper shows the band gone and the toolbar split per column as in the app. Tests that
  measured a bare view under the title bar now take its safe area into account (`ContinueCardTests`,
  `SessionInspectorTests.refreshShowsOnlyWithAWatchError`, `ReviewDiffTests`, `TranscriptResultTests`). Not checked:
  `screencapture -l` returns "could not create image from window" for a window that overlaps no display, so the
  proof window was moved to a 2 pt sliver at the screen edge. A view's display link does not tick in an off-screen
  window, so `SessionFrameDriver` published no streamed frames: `theReviewDiffKeepsItsSelectionAcrossRefreshesAndStreaming`
  failed every run and `aReplyWhileScrolledUpShowsTheCapsuleAndTheJumpFollowsTheEndAgain` once. Those two, and the
  `SessionPaneLayoutTests` fixture they share, pass `drivesDisplayLink: true`: a transparent window on the screen that
  ignores the mouse. The Rendering tests keep their `NSWindow`s: that target cannot see the helper, and the windows are
  never shown. The app was not launched.
- #256, core tests hitting the time limit on CI (2026-11-07, Xcode 27, the coverage job's core group in one process
  with `--build-system native` and instrumentation): no single stall. Swift Testing starts all ~600 tests at once and
  a test's 60-second limit counts from that start, so the whole group shared one 60-second budget. On CI the slowest
  passing core test was always about as long as the run (32–90 s over 24 runs); the suites finish in the same order as
  locally, about six times slower. One core run launches about 2,400 `git` processes through the `/usr/bin/git` shim,
  which takes twice the CPU of the real `git`. CPU burners alone did not reproduce it (10 or 30: slowest test 9–12 s);
  ten concurrent copies of the group did (load average 19–21 before each batch, 87 right after the previous one; 50–71%
  RAM free): all ten failed with 16–39 time-limit issues each, tests "passed after 60–65 s" as on CI, and one hung until
  the watchdog on the loop at `SessionActivityTests.swift:124` that CI's 120-second sample showed. `coverage.py` now sets
  `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` to four tests per core (12 on CI); a waiting test's limit has not
  started yet, and its "passed after" includes the wait. Same ten copies: 0 of 10 failed at widths 4, 8 and 20 (wall
  86, 88 and 76 s against 95 s unlimited; at 20 the probe and sign-in tests with their own timeouts still failed 8
  times). Alone, the core group takes 20.5 s unlimited, 20.5 s at width 20 and 27.7 s at 6; the hosted group 60 s at 12
  against 62 s. Fifteen loops that wait for an agent to exit (`while … != .closed { await Task.yield() }`) also stop
  once the test is cancelled: with a condition that never holds, the test ended at its limit (64 s) and was still
  running after 101 s without the check. The `SessionReviewTests` and `LiveSessionTests` expectations in the issue
  failed only after the limit had cancelled their tests. `ReviewDiffTests.aNewDiffKeepsTheTopLineAndEndsTheSelection`
  failed before #251 and did not recur in 100 repetitions or in a hosted run under 10 burners, so it is unchanged.
  Not verified on CI yet. Also seen under the heaviest load, not addressed: `AgentProbeTests`,
  `AgentSignInTests.initializeTimeoutCleansUp`, `EndToEndTests` and `ShellTerminalTests` timing, and once, in a plain
  run at load 50, `UnstartedWorktreeTests` and `ConfigHintTests` found the worktree still there after `close()`.
  2026-11-09: `ReviewDiffTests.aNewDiffKeepsTheTopLineAndEndsTheSelection` failed once more on `main` (3aa01e7: top
  line 149 for 150) after five clean runs, and passed 300 repetitions under ten burners locally. `DiffTextView.topLine`
  probed the very top edge of the visible rect, and a clip view snapped to whole pixels on CI's 1x display sits half a
  point above the line, inside the line before; it now probes 1 pt below the edge, and the test shifts the clip view by
  half a point (it fails without the fix).
  Result: the coverage job then passed six times in a row on `main` (342b1dc, 39555ee, 3b23f5b and three attempts
  of eb2978d, 2026-11-08/09); #256 is closed.

Unless an entry says otherwise, these were not seen in the running app: only automated and hosted-view tests ran, no
screenshots were taken and VoiceOver was not checked. #160 checks the finished design with `MockAgent`.

#178, two intermittent CI failures (2026-11-01):

- **`TerminalProcess` lost output: a product bug, fixed.** The process-exit source ran on the reader's serial queue
  and its handler called a blocking `waitpid`. The exit event can arrive while the command is still closing the
  terminal, and that close waits until the master has been read, but the master is read on the same queue. Both
  waited for each other until the kernel gave up on the unread output; the command still exited with 0, so
  `waitForExit()` returned `.exited(0)` with empty output. Every caller that reads `output` after `waitForExit()`
  (agent terminals, sign-in) was exposed. The exit source now has its own queue. Verified by reproduction: 2,560
  `/bin/pwd` terminals started 64 at a time with ten CPU burners running lost 6–10 outputs per run (25 of 7,680
  in three runs) before the change and none in 7,680 after it. The new regression test
  `keepsTheOutputOfManyConcurrentQuickCommands` failed 10 of 10 runs without the fix and passed 15 of 15 with it;
  the issue's test passed 60 of 60 runs (four parallel streams under load) and the whole suite 18 of 18.
  Launching 32 terminals at once also made `posix_openpt` fail about once in 3,000 launches, which is why the
  regression test starts four at a time; that failure is reported to the caller, not silent, and is not
  investigated further.
- **`MarkdownRendererTests.htmlIsShownAsCode` crash: cause not proven; a mitigation is in place.** A local
  `just coverage` run on Xcode 27 (load average about 20) produced the same crash as CI (`swiftpm-testing-helper`,
  SIGSEGV at 0x0 in `swift_getObjectType` under `swift_dynamicCast`, `MarkdownRendererTests.swift:106`), and the
  report shows the other threads. Nine cooperative threads were creating attributed strings and fonts at once
  (`MarkdownRenderer`, `StreamingMarkdown`, `UnifiedDiff` tests), three of them waiting on the same UIFoundation
  lock (`NSAttributeDictionary newWithDictionary:` / `newWithKey:object:`, `NSFont fontWithDescriptor:size:`), while
  the main thread was creating its first `NSWindow` inside `+[NSApplication initialize]`. A null object in an
  attribute value fits a race in that shared attribute-dictionary cache, as in #126 (`NSAttributeDictionary`
  again). Ruled out: shared state in `Theme` or the renderer (a `Sendable` struct, fonts and colors are created
  on each access, no caches), and the test helper. Not reproduced: 32 concurrent renderers on 32 tasks (3 runs),
  100 fresh processes racing `NSFont`/`NSColor` creation against a first `NSWindow` (no nil), 20 runs of the
  Rendering tests and 36 runs of the hosted group under load. The mitigation runs the Rendering suites that build
  attributed strings (`MarkdownRendererTests`, `StreamingMarkdownTests`, `UnifiedDiffTests`, `HighlighterTests`)
  on the main actor, so the tests no longer create them on several threads at once. 24 hosted-group runs under load
  then showed no crash, which proves little, as the crash was rare to begin with. The renderer does run off the
  main thread in production (`MarkdownPreview`), so a real exposure is not excluded; #126 and #178 stay open for
  the next report. Also seen, unrelated to the crash and not changed: `SourceViewTests.highlightsALargeFile`
  failed in 2 of 60 loaded hosted runs because its highlighting wait ran out.

Wave 1 status (2026-10-29):

- #149 implemented: `SessionWorkspace.changeStats` and `SessionFiles.changeStats` count added and removed lines
  against the session base; covered by temporary-repository tests, no UI yet (#150).

### M15 follow-ups: accepted decisions (#195, 2026-11-02)

Two UI/UX reviews after M15 proposed follow-ups that the owner accepted. The owner accepted the amendments and ADR-0041
on 2026-11-06; ADR-0042 stays `Proposed`, deferred. The issues are #203–#215, in the milestone `M15 — UI/UX redesign`
with the tier shown.

| Decision | Where |
|---|---|
| Sidebar row: `project · reason`, last activity | [ADR-0039](adr/0039-t3-style-window-layout.md), amendment |
| Inspector: Changes first, compact Workspace, readable branch | [ADR-0039](adr/0039-t3-style-window-layout.md), amendment |
| Pending permission docked above the composer | [ADR-0039](adr/0039-t3-style-window-layout.md), amendment |
| Done cleared when on screen, `New response below` | [ADR-0026](adr/0026-app-wide-session-manager.md), amendment |
| Mode and model hints in the draft | [ADR-0040](adr/0040-composer-first-session-start.md), amendment |
| Review as a pane, viewed marks, Ask agent | [ADR-0041](adr/0041-review-pane.md) |
| Allow edits in this worktree (deferred by the owner, not in M15) | [ADR-0042](adr/0042-allow-edits-in-this-worktree.md) |

Implementation issues, in order. Within a wave the issues are independent, apart from the listed dependencies.

| Order | Issue | Decision | Tier | Depends on |
|---|---|---|---|---|
| 1 | #203 Sidebar reason and last activity: pure `reason` in Core with a test per state, `lastEvents()` timestamps, Settled sort, truncation, accessibility label | Sidebar row | `agent:light` | — |
| 1 | #204 Inspector layout: order, compact block, Merge disabled with no changes, Discard secondary, Refresh only when watching failed. Takes over #191's repeated-label item | Inspector | `agent:light` | — |
| 1 | #205 Pure diff line model: parse `UnifiedDiff` output into lines with old and new numbers; quote builder with ranges, removed lines, fences | Review | `agent:light` | — |
| 2 | #206 Docked permission card: card, row of buttons, visible shortcuts, `1 of 3`, focus rules, arming, clip-view follow-bottom, VoiceOver announcement | Permission | `agent:strong` | #190 |
| 2 | #207 Compact permission record: one-line row with Details, tool row hides its diff while pending, buttons leave `TranscriptTable` | Permission | `agent:light` | #206 |
| 2 | #208 Readable branch names: migration, naming, removal check with real repositories, inspector display. Takes over #191's branch item | Inspector | `agent:strong` | #204 |
| 3 | #209 Viewport bookkeeping and Done: target item, pure on-screen check, watching only while unseen, clip changes, folded groups. Rendering Lab S1, S7, S9 with the owner's approval | Done | `agent:strong` | #206 (shared geometry) |
| 3 | #210 `New response below` and ⌥⌘↓ Jump to Latest | Done | `agent:light` | #209 |
| 3 | #211 Apply hints at session start: in `createRemote` before the record, the model by default and a mode only when picked in the draft, rejection returns the draft, no history row or worktree left, cache in `AgentCatalog` | Hints | `agent:strong` | — |
| 3 | #212 Draft pills from the cache: shared rendering with `SessionConfigControls`, tooltip, reset on agent change | Hints | `agent:light` | #211 (a pill must never promise what is not applied) |
| 4 | #213 Review pane: slot in `DetailPanes`, ⌃⌘R toggle, no-flicker refresh, hold on selection with `Show latest`, new diff text view, merge sheet in `RootView` | Review | `agent:strong` | #205 |
| 4 | #214 Viewed marks and line counts | Review | `agent:light` | #213 |
| 4 | #215 Ask agent: selection to lines, insertion at the caret, ⌥⌘A, stale-quote note | Review | `agent:light` | #213, #189, #193 |

ADR-0042 has no issues while it is deferred. If it is taken up, it starts with counting edit requests in real sessions
(read-only, with the owner's approval), then a pure edit rule with a mock agent that reports chosen kinds and locations,
then the switch itself, last of all and after the docked card.

#189, #190, #192, #193 and #194 have landed. #194 (transcript find) shares row identity with the viewport work (#209),
which rebases on it. #191's repeated-label item landed in #202; its branch item moved to #208, and #191 closes with it.

Pitfalls known so far:

- `RootView.swift` and `TranscriptTable.swift` are shared by the docked card, the viewport work, the review pane and #194:
  merge in table order and rebase.
- The owner decided on 2026-11-02: branch names become real and stored, which reverses a line of ADR-0032 and touches
  the removal check; a mode is applied only when chosen in the draft; ADR-0042 is deferred.
- ADR-0041 replaces `MarkdownPreview` in review with its own diff view, so large diffs need a look, and a benchmark if
  they turn out slower.
- MockAgent needs commands for several pending requests and for chosen tool kinds and locations; otherwise those paths
  can be checked only in hosted views.
- PLAN's earlier note that the draft cannot offer model or mode, and ARCHITECTURE.md's notes marked `Accepted, not yet implemented`, are
  replaced when the implementation lands.

## M18: First-use feedback (2026-11-08)

The owner installed the app from main (c65b8a1, `/Applications`, the original bundle identifier) on 2026-11-07, used
it against T3 Code and listed what to change; the decisions were taken the next day. M18 comes **before** M16: it
reworks the sidebar, the composer and the draft, which M16's transcript and board work builds on. #160 moves to the
end of M18. First, #261 moved UI behavior out of ADRs into [docs/behavior/](behavior/); the UI decisions below are
recorded there as *Planned (M18)*.

| Decision | Where | Status |
|---|---|---|
| Working as a shelf above Settled with `Working 1m 12s` / `Idle 20m`; Settled always collapsible; `✓ Settle` = End Session from the row | [sidebar.md](behavior/sidebar.md) | Planned |
| One composer control row: mode popover with the agent's descriptions, toggle pills, `…` overflow, the working line on the card | [composer.md](behavior/composer.md) | Planned |
| Draft heading `What should we build in <project ▾>?` with a centered composer; effort as a hint applied like the model | [session-start.md](behavior/session-start.md) | Planned |
| `Sign In…` in the agent row's menu, a button only after the agent asked | [agents-settings.md](behavior/agents-settings.md) | Planned |
| A quiet transcript row selection: a rounded `.quaternary` background of the column's width, no system band | written to `transcript.md` by its issue | Planned |
| Worktrees from the fetched upstream (fallback `HEAD`); merge blocked while the local base is behind | [ADR-0047](adr/0047-worktrees-from-the-fetched-upstream.md) | Done (#277) |
| Sessions without a project, one `~/.agenthesia/scratch/<words>-<id>` folder each | [ADR-0048](adr/0048-sessions-without-a-project.md) | Implemented (#279) |

Not adopted: T3 Code's fixed access levels with icons (principle 8), settled state that keeps the agent running,
snoozing and pins, automatic removal of merged or inactive worktrees, a worktree folder or branch prefix setting
(principle 6).

**Reconciled with M18 (2026-11-09).** M18 landed between the M16 decisions and their implementation, so the owner and a
review of the open issues against the code settled four things:

1. **#224 is dropped.** The owner compared the transcript with T3 Code in M18 and kept the right-aligned bubbles; a
   tinted block would also clash with the quiet row selection of #269. ADR-0039's amendment carries a note. #225 and
   #223 no longer depend on it.
2. **#222:** the context ring gets a fixed slot before the Send options chevron in the composer's control row. Its width
   comes out of the pill budget and it never moves into the `…` overflow (since #276 overflowing pills go there, and
   [composer.md](behavior/composer.md) says no pill is cut by the card's edge).
3. **#225:** the start line names the fetch: `Fetching origin/<branch>…` while ADR-0047's fetch runs (up to 20 s), then
   `Starting <agent> in …`, and `Starting <agent> in a new folder…` for a session without a project (ADR-0048). Since
   #278 Send moves the card to the bottom (`DraftSendTransition`), so the held first message appears in the first-row
   position the card leaves. The pull request replaces `Starting session…` in
   [session-start.md](behavior/session-start.md).
4. **New order** in four waves, below.

Other conflicts the issues now carry: #229 conflicts with the Checkout label of
[session-start.md](behavior/session-start.md) ("Not a menu"; the menu item reads `New worktree from <upstream>`, the
project-folder form never fetches, and the item is hidden for sessions without a project), and its pull request
replaces that section. #227's "a window with no selection shows the board" clashes with the same file (new and restored
windows show the draft): the board is shown on ⌘0 and the Overview row, and when the displayed session is deleted;
blank windows keep the draft. #206 and #208 are closed and are no longer dependencies.

Issues, in order. Within a wave the issues are independent apart from the listed dependencies.

| Order | Issue | Decision | Tier | Depends on |
|---|---|---|---|---|
| 1 | #221 Plan: inspector section, `PlanProgress` in Core, working line text, Working-row reason, MockAgent demo | Transcript | `agent:light` | — |
| 1 | #222 Context usage and cost: Agent section rows, composer ring in a fixed slot from 70 %, MockAgent demo | Transcript | `agent:light` | — |
| 1 | #230 Delete a saved session: `deleteSession`, worktree or scratch folder removal first, confirmation, windows | Workflow | `agent:strong` | — (lands on the draft; #227 changes that later) |
| 1 | #232 Push after merge: upstream detection, checkbox, remembered choice, failure after a successful merge | Workflow | `agent:strong` | — |
| 2 | #225 First message shows at once: one-item transcript source, `Fetching` / `Starting <agent> in …` line | Draft | `agent:light` | — |
| 2 | #223 Collapsed thoughts: disclosure row, fold of consecutive thoughts, Rendering Lab rerun with the owner's approval | Transcript | `agent:strong` | — |
| 2 | #229 Sessions in the project folder: checkout menu, in-place `prepare`, Changes since start, Merge and Discard disabled | Workflow | `agent:strong` | — |
| 2 | #233 Pull request with `gh`: availability, sheet, push and `gh pr create`, `pullRequestOpened`, inspector link and Push | Workflow | `agent:strong` | #232 |
| 3 | #227 Session board: `WindowTarget.board`, Overview row, cards, answers with the Open-first rule, arming | Board | `agent:strong` | #221 |
| 3 | #228 Menu bar item: `MenuBarExtra`, count, sessions, permission submenu | Board | `agent:light` | — (the Open-first rule goes into a pure Core function that #227 or #228 adds, whichever lands first) |
| 4 | #234 Verify in the running app and refresh screenshots | — | `agent:light` | all |
| — | #224 User messages as left-aligned blocks | Transcript | — | Dropped (2026-11-09) |
| — | #226 ⌘1…⌘9 (done) · #231 Archive (done) | Keyboard, Workflow | `agent:light` | — |

Pitfalls known so far:

- `SessionDraftView` is also changed by #225 (M16, the held first message); whichever lands second adapts the
  transition of the card to the held message. Since #278 Send's motion is `DraftSendTransition`, the draft's removal
  transition in `RootView`; #225 replaces it if the held message keeps the card on screen.
- The upstream start is a safety path in `prepare` and the merge: real-repository tests with a local bare remote,
  never against this repository.
- The development bundle identifier must not share `~/Library/Application Support/Agenthesia` with the installed app:
  `SessionLibrary` and `AgentInstaller` hard-code that path today, so two apps would write one history.
- Each implementing pull request moves its item from *Planned (M18)* into the behavior document's text and adds a line
  to its `Changes` log.
- #264 (Manage Agents… opens the Agents tab) landed: `SettingsView`'s tab is `@AppStorage("settingsTab")` and
  `ManageAgentsButton` stores `agents` before `openSettings()`. Running app (scripted, copy with its own bundle
  identifier, isolated home, dark then light): ⌘, opened General; `Manage Agents…` in the draft's hint opened Settings
  on Agents; with Settings open on General, the hint and the agent chip's menu item switched the same window to Agents;
  after a relaunch ⌘, opened the last tab (Agents, then General). Not checked: the failure banner's button (same view),
  VoiceOver. Pitfall: `axlabels` reports an element's top-left corner, so click its center.
- #274 (landed): neither shelf is held open by a selected row any more; `SidebarShelves.isOpen` is the stored state or a
  search, and Previous/Next Session expand the shelf they move into (`SessionWindowModel.revealShelf`).
- #279 keeps each session without a project in its own folder under `~/.agenthesia/scratch`; nothing removes it yet.
  #230 (delete a saved session) must remove that folder too, after the confirmation names it and its file count
  (ADR-0048), and only a folder directly under the scratch root that the session record names. Archiving keeps it.
- #160, the M18 verification (2026-11-08, main 342b1dc; scripted, a copy with its own bundle identifier, isolated
  home, MockAgent; dark and light). Checked: the draft without an agent (`Add Agent…`, the chip offering only Custom
  Command…), the heading with the project menu and `or start without a project`, Send moving the card to the bottom
  (`Starting…`, then the session); a turn with tools, a plan and a write; the docked permission answered with ⌥⌘1;
  review (⌃⌘R) with Ask Agent and Merge…; the merge sheet; Quick Open and the file pane's Markdown preview; the
  Session menu's items; a session without a project (its `scratch/` folder, dashed badge, `No project`, untracked
  Changes, no Review or Discard); Settings → Agents installing Claude Agent 0.101.0 from the registry, then Remove
  asking `Remove Claude Agent 0.101.0?` with `No saved sessions use this version.`, Cancel keeping it and Remove
  removing it; the Working shelf, `✓ Settle` on hover and the queue and shelves in the two earlier batch checks.
  Accessibility labels were read from the tree (`axlabels`). Findings are in #301 (the Agent chip described as `CPU
  chip`, Quick Open's Return from the search field, the hover Copy staying on rows the pointer left, a narrow
  transcript with review and inspector open, the Remove menu's look). Not checked: VoiceOver itself, the `1 saved
  session` wording of Remove (it needs a session with a real agent), two installed versions, a fetch failure of
  #277, Increase Contrast. `scripts/app-check/lib.sh`'s project and agent menu paths follow the new draft heading.
  The README screenshots are now generated: `just screenshots` runs `scripts/readme-screenshot/readme-screenshot.sh`,
  which plays a canned turn (`MockAgent --demo`) in a test copy of the app under a temporary home and captures the
  window with its shadow in light and dark; README picks one with `prefers-color-scheme`, as for the logo. Making them
  showed transcript rows keeping the height they were measured at when the column widened (opening the file pane or
  resizing the window): the extra height stretched the row's Copy strip into an empty band. The rows' stacks now hold
  their own height above AppKit's row height, and a test resizes from 500 to 1364 pt.

## M16: Multi-agent workflow (2026-11-07)

Tracking issue #220. After M15, the owner reviewed the codebase and the open issues (with Claude Fable, 2026-11-07)
and chose a second set of UI/UX changes, several of them against accepted ADRs. The owner accepted all of them on
2026-11-07; the documentation landed in #235.

| Decision | Where | Status |
|---|---|---|
| Plan in the inspector and the working line; context usage and cost; collapsed thoughts | [ADR-0039](adr/0039-t3-style-window-layout.md), amendment of 2026-11-07 | Accepted (user messages as left-aligned blocks dropped on 2026-11-09, #224) |
| The first message shows at once while the session starts | [ADR-0040](adr/0040-composer-first-session-start.md), amendment of 2026-11-07 | Accepted |
| Sessions in the project folder of a Git repository (a checkout menu in the draft, per draft, worktree by default) | [ADR-0043](adr/0043-sessions-in-the-project-folder.md) | Accepted |
| Delete and archive saved sessions | [ADR-0044](adr/0044-delete-and-archive-sessions.md) | Accepted |
| Push after merge; pull requests with `gh`, the session stays live | [ADR-0045](adr/0045-push-and-pull-requests.md) | Accepted |
| Session board on an Overview row (⌘0), a menu bar item, ⌘1…⌘9 | [ADR-0046](adr/0046-session-board-and-menu-bar.md) | Accepted |

Not adopted: an inline first-run flow in the draft (stays with #45). ADR-0042 stays deferred.

Issues, in order. Within a wave the issues are independent apart from the listed dependencies.

| Order | Issue | Decision | Tier | Depends on |
|---|---|---|---|---|
| 1 | #221 Plan: inspector section, `PlanProgress` in Core, working line text, Working-row reason, MockAgent scenario | Transcript | `agent:light` | — |
| 1 | #222 Context usage and cost: Agent section rows, composer ring from 70 %, MockAgent scenario | Transcript | `agent:light` | — |
| 1 | #224 User messages as left-aligned blocks; `bubbleWidth` goes | Transcript | `agent:light` | — |
| 1 | #225 First message shows at once: one-item transcript source, `Starting <agent> in …` line | Draft | `agent:light` | #224 |
| 1 | #226 ⌘1…⌘9: Switch to Session submenu over the filtered sidebar | Keyboard | `agent:light` | — |
| 1 | #223 Collapsed thoughts: disclosure row, fold of consecutive thoughts, Rendering Lab rerun with the owner's approval | Transcript | `agent:strong` | #224 |
| 2 | #227 Session board: `WindowTarget.board`, Overview row, cards, answers with the Open-first rule, arming | Board | `agent:strong` | #221, #206 (operation line, arming) |
| 2 | #228 Menu bar item: `MenuBarExtra`, count, sessions, permission submenu | Board | `agent:light` | #227 |
| 3 | #229 Sessions in the project folder: checkout menu, in-place `prepare`, Changes since start, Merge and Discard disabled | Workflow | `agent:strong` | — |
| 3 | #230 Delete a saved session: `deleteSession`, worktree removal first, confirmation, windows | Workflow | `agent:strong` | #227 (landing place; the draft until then) |
| 3 | #231 Archive: `archivedAt`, Settled filter, search reason, Continue reset | Workflow | `agent:light` | — |
| 3 | #232 Push after merge: upstream detection, checkbox, remembered choice, failure after a successful merge | Workflow | `agent:strong` | — |
| 3 | #233 Pull request with `gh`: availability, sheet, push and `gh pr create`, `pullRequestOpened`, inspector link and Push | Workflow | `agent:strong` | #208, #232 |
| 4 | #234 Verify in the running app and refresh screenshots | — | `agent:light` | all |

Pitfalls known so far:

- `RootView.swift` and `TranscriptTable.swift` are the collision points with M18, which is done. In `RootView`,
  `DraftSendTransition` moves the draft's card to the bottom at Send; #225 and #230 (the landing place after a delete)
  adapt it. In `TranscriptTable`, the quiet row selection (#269) and the row height (since #302 row stacks hold their
  own height above AppKit's `rowContentHugging`) matter for #223's expand and collapse, which must go through that path
  and get a resize test. Within M16, merge in table order.
- #223 changes the row model again after #155 and #209; the streaming benchmarks are the gate, and the owner approves
  the workload before a run.
- #229 and #232/#233 touch safety paths (`prepare`, the removal check, the merge). Real-repository tests, a local bare
  remote for pushes, and a fake `gh` on PATH; never run these checks against this repository.
- #230 is the first operation that removes events; the store needs cascade or explicit deletes for every table that
  references a session, and a test that lists the tables so a new one cannot be forgotten.
  A session without a project (#279, ADR-0048) also loses its `~/.agenthesia/scratch/<words>-<id>` folder.
- A `MenuBarExtra` has no hosted-view test; #228 tests its content view and records the running-app check in this file.
- #234 creates test sessions; with #230 landed they are deleted before the pull request, which replaces AGENTS.md's
  warning that they stay forever.
- #226 ⌘1…⌘9 (ADR-0046): Session → Switch to Session lists the first nine rows of Needs You and Working in the filtered
  sidebar (`SessionSidebar.numberedRows`, `SessionWindowModel.numberedSessions`); ⌘1…⌘9 were free (only ⌥⌘1…⌥⌘9 answer
  permissions). Tested in Core and on the window model; the menu items themselves have no hosted test. Running app
  (scripted, MockAgent, isolated home, dark): with two sessions the submenu listed both titles with ⌘1 and ⌘2 and seven
  disabled `No Session` items; ⌘1 and ⌘2 switched the window, also from the composer; a sidebar search for one title
  left only it under ⌘1, and clearing the search brought both back. Not checked: Settled rows (none were live), light
  mode, VoiceOver.
- #221 (plan) landed: `PlanProgress` (Core) feeds the working line (`· 3 of 7 · Writing tests`), the Working row's
  reason (a turn's ADR-0049 origin outranks it, owner's choice) and the inspector's `PlanSection`, open while the turn
  runs and collapsed to `Plan · 3 of 7` after it (a hosted test checks that `Section(isExpanded:)` collapses in the
  grouped form). `TranscriptState` clears the plan when a turn starts (owner's choice: the plan is always this turn's).
  `scripts/app-check/demos/plan.json` (`MockAgent --demo`) advances a four-step plan. Running-app check deferred to
  the end of wave 1, while the owner uses the machine.
- #231 (archive) landed: migration `v6-session-archived-at`, `PersistenceStore.setArchived`, the Settled filter and
  the `Archived` search reason, Previous/Next skipping archived rows, the Archive/Unarchive menu items and the Continue
  reset, with Swift Testing tests (a migration test on a v5 database file, the model, the sidebar). Running app
  (scripted, MockAgent, isolated home, dark): Session → Archive Session on an ended session took it out of Settled, a
  sidebar search found it with the reason `Archived`, the item turned into Unarchive Session, and unarchiving brought it
  back to Settled. Not checked: the context-menu items, Continue on an archived session, light mode, VoiceOver.

## M13: Agenthesia tools (2026-11-09)

Tracking issue #307. The owner compared T3 Code's MCP tools (`apps/server/src/mcp/toolkits` in the T3 Code source) with
#56–#60 and #71 and chose what to port and how; the decisions are [ADR-0049](adr/0049-built-in-agenthesia-mcp-server.md).
#56 and #71 moved here from M9, whose memory stays deferred.

Issues, in order. Within a wave the issues are independent apart from the listed dependencies.

| Order | Issue | Tier | Depends on |
|---|---|---|---|
| 0 | #308 Spike with Claude, Codex and Gemini: instructions, tool-call reports, sandbox, working-directory change, subagents, timeouts, images, start latency | `agent:strong` | the owner's consent |
| 1 | #309 `MCP` module: wire types, server dispatch, minimal client | `agent:light` | — |
| 1 | #56 `agenthesia-mcp` helper, the app socket, session tokens | `agent:strong` | — |
| 1 | #71 The server in every `session/new`, `load` and `resume`; the running-turn gate; MockAgent's `mcp` verb | `agent:light` | #56, #309 |
| 1 | #310 Instructions and `environment` | `agent:light` | #71 |
| 1 | #311 Turn origins in the event log, labels in the transcript and sidebar | `agent:strong` | — |
| 1 | #312 Cards for tool calls; creates `docs/behavior/tools.md` | `agent:strong` | #71, #308 |
| 1 | #313 Prompt prefix for agents that do not read instructions | `agent:light` | #308, #310 |
| 2 | #57 `show` | `agent:light` | #312 |
| 2 | #59 `ready_for_review` | `agent:light` | #312 |
| 2 | #58 `screenshot` of Simulators | `agent:light` | #312 |
| 2 | #314 `screenshot` of windows (owner decides on an in-app confirmation first) | `agent:strong` | #58 |
| 2 | #315 `html_render` | `agent:strong` | #312 |
| 2 | #316 `request_secret` | `agent:strong` | #312 |
| 3 | #60 `delegate`, `delegate_status`, `delegate_cancel`; parent link on sessions | `agent:strong` | #310, #311, #312 |
| 3 | #317 Delivery, `wait`, Stop depth first, restarts | `agent:strong` | #60 |
| 3 | #318 `session_list`, `session_read`, `session_send` | `agent:strong` | #311, #312 |
| 3 | #319 `worktree_handoff` | `agent:strong` | #308, #312 |
| 3 | #320 `task_run`, `task_output`, `task_stop` | `agent:strong` | #311, #317 |
| 4 | #321 Verify in the running app | `agent:light` | all |

Progress:

- #311 (turn origins): `QueuedPrompt.Origin` in the event log, the labelled transcript row, the sidebar reason and the
  wrapper the agent receives, covered by Swift Testing and a hosted row test. No tool produces another origin yet, so
  the running-app check in light and dark waits for #321, together with `docs/behavior/tools.md` (#312). A source
  session that is not open in this launch is labelled `From another session`; naming saved sources needs agent names
  kept with history.

Pitfalls known so far:

- The spike (#308) ran on 2026-11-09 with `claude-agent-acp` 0.101.0 (Claude Haiku 5.5) and `codex-acp` 2.5.0
  (`codex` 0.165.0), six prompts each, through `acp-cli` on a throwaway branch; Gemini was not installed. The answers
  are in #308 and in ADR-0049's *Spike* section. For the issues: the prefix goes to Codex and Gemini, not Claude
  (#313); rows match cards by the `toolCallId` in `tools/call`'s `_meta`, and a Codex subagent's calls have no row
  (#312); `session/resume` takes the worktree as the new working directory (#319); `wait` stops at 240 s (#317); a
  token may open several connections, one per Codex subagent (#56, #71). Neither agent asked permission for our tools
  in its auto mode, so the shape of that request is still unseen; #321 checks it with a supervised mode.
- MockAgent's `mcp` verb (#71) is what lets every tool be tested without a real agent; land it before the tools.
- #56 landed the helper, `MCPSocket` and `MCPTokens` without issuing any token: #71 issues one in `LiveSession.create`
  (the session id exists there, before `session/new`) and for `load`/`resume`, revokes it when the owner closes, and
  replaces the app delegate's empty `serve` with the `MCP` server. The hello is the bare token and a newline; the socket
  reads it a byte at a time so the first JSON-RPC line is never consumed with it.
- The app target embeds the helper through an *Embed Helpers* copy phase (`Contents/Helpers`, *Code Sign On Copy*) that
  references the package product, plus a target dependency on it; the copy is signed with the app's identity.
- #56, running app (2026-11-09, scripted without UI input, Debug `.dev` build, `CFFIXED_USER_HOME` in a temporary
  folder): the app made `$TMPDIR/agenthesia-<hash>.sock` with mode `srw-------`; the bundled helper with an unknown token
  was disconnected and exited in 0.05 s with its stdin still open; a second instance with the same data folder logged
  `Cannot listen for agenthesia-mcp: … Address already in use` and the first kept answering; after SIGTERM the socket
  file stayed, and the next launch replaced it and listened. `codesign --verify --deep --strict` passed, and the helper
  links only system libraries. Not checked: a quit through the menu (the socket is not closed on quit either, which is
  harmless since the next launch replaces it), and a connection with a live token, which needs #71.
- The socket path must stay under `sun_path`'s 104 bytes, also under `CFFIXED_USER_HOME` in a `mktemp -d` folder; and
  the `.dev` build, the installed app and a check build must never share a socket.
- Calls that start work (`delegate`, `session_send`, `task_run`) are refused without a running turn in the caller; with
  no limit on chains (ADR-0049), Stop is the only brake, so #317 tests Stop depth first carefully.
- New event kinds and a migration of the sessions table (#60); older builds skip unknown kinds, and the migration gets a
  test on the previous schema file, as #231 did.
- `html_render` (#315) must not put a web view in the transcript table; the streaming benchmarks are the gate, run with
  the owner's approval of the workload.
- Screen Recording (#314) and the secret card (#316) are checked with a fresh bundle identifier (AGENTS.md).
- #309: the `MCP` module serves tools through `MCP.server(info:instructions:tools:)`, a `JSONRPC.Router`. There is no
  separate client type: a `Connection` with the `MCP.Method` types is the client, which is what MockAgent's `mcp` verb
  (#71) uses. Tests cover the module fully.

## Next steps

The rest of M5 (#61, #67) waits for an agent that calls `terminal/create` (#104). Then #126 (the CI
rendering crash, strong tier) and M6 (Registry), whose installation scope is accepted in
[ADR-0034](adr/0034-agent-installs-with-user-runtimes.md). Small independent chores such as #73
(CI with Xcode 27) fit the light tier. The sections after this one record how M8, M7 and M4 were built
and verified.

### M6: Registry and local agents (2026-10-27)

Use user-provided Node/npm, isolated binary/npm installations and local ACP command discovery. Do not
download or update runtimes; defer `uvx` installation and standalone adapter packaging. ADR-0034
supersedes only the managed Node and installation decisions of ADR-0004; its historical text stays intact.

Implementation order (#33 merged in #136; #34 merged in #137; #35 merged in #140; #36 remains open):

1. **#33 — Registry client with ETag cache. Sol, High (`agent:light`). Merged.** Parse and cache registry
   metadata, conditional requests and platform distribution selection; retain unsupported entries
   for an explanation instead of silently hiding them.
2. **#34 — User runtime discovery and prerequisite checks. Astra, High (`agent:strong`). Merged.** Replace the
   old managed-Node scope with Node/npm checks and fresh login-shell capture for Check Again. Keep
   installation and launch on a consistent runtime, detect removed/incompatible runtimes, and keep
   running sessions unaffected. This can be developed independently of #33.
3. **#35 — Binary and npm installers. Astra, High (`agent:strong`). Merged.** After #33 and #34: private
   versioned installs, exact packages with retained lockfiles, binary verification, cancellation and
   failure cleanup, explicit updates with retained working versions, and removal only of owned files
   that are not in use. Authentication and chat use the same installation and runtime.
4. **#36 — Agent browser, local discovery and updates. Astra, High (`agent:strong`).** After #35:
   discover known local ACP commands without spawning them, retain manual setup, show prerequisites
   and Check Again, validate selected commands through bounded ACP initialization, and expose install,
   update and removal. A discovered ordinary CLI may still need an adapter and a compatibility check.
   Pre-session sign-in remains part of this issue as recorded by ADR-0033. The owner split it into three
   pull requests ([ADR-0036](adr/0036-agent-settings-and-installed-sessions.md)): 1) Settings → Agents,
   the agent picker and session leases; 2) local discovery from a built-in command table and the
   initialize probe; 3) pre-session sign-in.

Each implementation has its own branch and tests. Do not equate a successful initialize handshake
with successful sign-in. Verify first-run prerequisite recovery, discovery, updates and failures in the
built app with temporary fixtures/MockAgent; check VoiceOver and system prompts separately and record
what was actually exercised. No real-agent prompt or benchmark is needed for this documentation change.

ADR preparation checked upstream source and release metadata only; standalone adapter builds, real
agent sessions, native-app UI, VoiceOver and system prompts have not been tested for M6. The decision
and issue scope were recorded before implementation; implementation results follow below.
Documentation validation: `just lint`, full `just test` (695 Swift tests and 15 script tests),
`git diff --check` and local Markdown link checks pass.

#33 implemented (2026-10-27): `AgentRegistry` parses stable registry metadata and selects the exact
macOS platform binary before npm, retaining uvx and unknown kinds for unsupported explanations.
The client has an atomic body/ETag cache, conditional requests, bounded HTTPS fetching, explicit stale
cache warnings, cancellation and concurrent-request sharing. The owner selected stale cache with a
warning on refresh failure. No installer, runtime discovery or browser UI is included; #34 is next.
Tests use registry fixtures and URLProtocol rather than live agent processes. The red tests first
failed for missing models/client; an added redirect-port regression failed before the origin check
was corrected. A reproduced cancellation/network-failure race now gives cancellation precedence;
deliberately disabling binary selection made its regression fail, and the mutation was restored.
`just lint`, full `just test` before the cancellation follow-up, all 20 registry tests afterwards,
and full `just coverage` pass (715 Swift tests; AgentRuntime 92.6%, all module gates pass). The
`just test` recipe also passed its 15 script tests. Local documentation links and `git diff --check`
pass. Coverage skipped five corrupt raw profiles through the existing merge policy. Native-app UI,
VoiceOver, system prompts, live registry HTTP requests and real-agent sessions
were not exercised for this metadata-only change.

#34 merged in #137 (2026-10-27): `ShellEnvironment.refresh()` shares concurrent captures and
protects the cache from stale completion; running sessions retain their environment snapshot.
`NodeRuntime` discovers executable Node/npm, resolves the actual Node behind shims and a standard npm
CLI, checks both npm's own Node requirement and supplied package engine ranges with npm's semver, and
prepares commands using explicit tool paths. A persisted toolchain stores paths and versions only.
Revalidation refuses removed or changed tools and gives actionable diagnostics. The bounded shell
collector now also serves runtime probes; it still cleans up the process group. No runtime is installed
or changed. #35 supplies exact-package requirements and stores the descriptor; #36 owns Check Again
and recovery UI. Unresolvable npm wrappers are reported, not launched opportunistically.

Fixture tests cover shared refreshes and both stale completion orders,
prerequisite failures, recovery, version-manager shims, removed/changed tools, cancellation and paths
with spaces. The optional installed-Node/npm integration runs when both tools are available, without
installing anything: it exercises real semver ranges and launches a temporary JavaScript entrypoint
whose working directory contains misleading node/npm commands. It ran locally and caught a percent-
encoded filesystem path bug before the fix. No real agent, native-app UI, VoiceOver, system prompt or
benchmark was exercised. Local integration used Node 26.12.1 and npm 11.20.0, with a temporary npm
fixture reusing the installed semver dependency to verify prerelease handling. Missing package engine
ranges impose no extra constraint; an explicitly declared `*` retains npm's prerelease semantics.
A cancellation-during-shell-capture regression reproduced a missing-tool error taking precedence over
cancellation; both discovery and saved-toolchain preparation now give cancellation precedence. A
runtime-version mutation failed its regression before restoration. A colon in the Node directory is
rejected because it cannot be pinned as a single PATH entry. `just lint`, full `just test` before the cancellation/prerelease follow-ups, targeted regressions after
the fixes, and final full `just coverage` pass (735 Swift tests, AgentRuntime 92.9%, all module gates).
The test recipe also passed its 15 script tests. Coverage excluded three corrupt raw profiles through the
existing merge policy. Documentation links and `git diff --check` pass.

#35 implemented in [PR #140](https://github.com/anesthetised/agenthesia/pull/140) (2026-10-27), under the owner-approved
[ADR-0035](adr/0035-installer-storage-and-script-policy.md): `AgentInstaller` keeps versioned metadata and
payloads in AgentRuntime. Binary installs verify declared SHA-256 checksums and use system libarchive
with built-in filters only; extraction rejects links, special files, escaping paths and excessive expansion.
npm installs exact packages with isolated configuration/cache and lifecycle scripts disabled, retains
the manifest/lockfile, and launches the installed entrypoint through the saved, revalidated Node.
Updates retain old versions. Owned staging directories are cleaned on cancellation/failure; publication
is an exclusive rename. Shared launch leases prevent removal across cooperating installer instances.
The caller must retain a lease through sign-in/chat and release it after all owned processes exit.
Windows, history, readiness checks and recovery messages remain #36; no Persistence migration is needed.

Tests cover archive formats and hostile entries, HTTPS limits/redirects, checksums, failure/cancellation,
version retention, ownership, executable containment, runtime changes, npm flags and lease conflicts.
A local HTTP registry served a temporary fixture to real npm: installation and direct Node launch worked,
postinstall did not execute, user npm state was untouched, and the retained lockfile includes integrity.
This caught npm's sensitivity to `/var` versus the physical `/private/var` prefix: staging now uses
POSIX `realpath`. Other regressions caught Foundation directory URL normalization, a substituted payload
symlink, and process capture cancellation. The system libarchive's zstd registration requested an external
helper, so that filter is deliberately unsupported. Explicit lease unlock avoids retaining a lock through
a descriptor briefly inherited by a concurrent fork before exec.

Validation: `just lint`, full `just test` (758 Swift tests and 18 script tests), final `just coverage`
(all module gates; AgentRuntime 91.6%) and `just app` pass. A deliberately inverted SHA-256 comparison
failed the checksum/update regression before restoration; the truncated-archive test also checks a valid
header with an incomplete payload in a fresh destination. The coverage merge excluded 7 corrupt raw
profiles through the existing policy. Local documentation links and `git diff --check` pass.
No real agent, native-app UI, VoiceOver, system prompt or benchmark was exercised for this API-only slice.
Use Astra, High for #36's shared session/authentication lifecycle integration; Sol, High suits subsequent
isolated UI polish.

#36 slice 1 merged in [PR #141](https://github.com/anesthetised/agenthesia/pull/141) (2026-10-27), under the
owner-approved ADR-0036: Settings
gains an Agents tab (installed versions with Update and Remove, the Node.js/npm check with Check Again,
the ACP Registry with search, distribution, source and license confirmed before installation). The launch
form picks the newest installed version of an agent or a custom command. Migration
`v4-agent-install-installation` links one `agent_install` row to each installed version, so saved sessions
keep their version; Continue of a removed version names the agent and points to Settings. `LiveSession`
leases the version before creating a worktree, runs chat and terminal sign-in with the leased command and
releases the lease after its processes exit.

Pitfall found and fixed: #35's installer held its exclusive operation lock across the download, the npm
run and the shell capture of `acquire`, so starting a session while another agent installed, or two
parallel starts with one installed agent, failed with "Another installation or removal is in progress".
The lock now covers synchronous steps only. Both cases had red regressions before the fix. Disabling the
lease release made all three installed-session tests fail before restoration (a first mutation that only
skipped `release()` survived because dropping the lease object also unlocks it).

Validation: `just lint`, full `just test` (772 Swift tests and 18 script tests), `just coverage` (all
module gates; AgentRuntime 93.4%, AgenthesiaCore 97.7%; six corrupt raw profiles excluded by the
existing merge policy) and `just app` pass. Views were reviewed with `swiftui-pro`; `confirmationDialog(_:item:)`
was not adopted because it needs Xcode 27 and CI builds with 26.6. Tests use local registry stubs and
archive fixtures with MockAgent.

Built-app check (2026-10-27, Debug build of this branch, scripted with `osascript`/System Events and
`screencapture` because computer use was unavailable in the session): the live registry loaded, and search
narrowed it to OpenCode. The install confirmation named the source repository, the MIT license, the archive
URL and checksum verification. Cancelling during the download left no staging directory and no error.
A full install of OpenCode 2.2.0 (100 MB zip, SHA-256 verified) published the version in about 2.5
minutes. Check Again showed Checking… and then Node.js 26.12.1/npm 11.20.0 again. The launch form listed
OpenCode 2.2.0, hid the custom command fields, and started a session in a test repository whose agent ran
from the private payload. Removal was refused while the session ran. After End Session, Continue relaunched
the same version. After removing it, Continue showed the "no longer installed" message. The check found an
empty agent directory left after removing the last version; removal now deletes it (red regression first).
Not exercised: a real update (the registry offers one version per agent; covered by `AgentCatalogTests`),
npm installs from the browser, a prompt to the real agent, VoiceOver and system prompts. Form buttons in
the launch form and Agents tab expose no accessibility titles to System Events; the same is true of the
existing Choose… and Start Session buttons, so this needs a separate VoiceOver pass rather than a fix here.
Leftovers only the owner can remove: one test session, "OpenCode · agh-agents-check", in history.

#36 slice 2 merged in [PR #142](https://github.com/anesthetised/agenthesia/pull/142) (2026-10-28), under the owner-approved ADR-0037: Settings →
Agents gains On This Mac. A built-in table of 18 known ACP commands and two ordinary CLIs (`claude`,
`codex`) is looked up on the login shell's `PATH` without running anything; found commands show their path
and ACP arguments and are added explicitly, Add Custom… adds any command, and the list lives in
`UserDefaults`. Local agents follow the installed versions in the launch form's picker. Check runs
`AgentProbe`: the command starts in an empty temporary directory with the login shell's environment, gets
ACP `initialize` under a 20-second timeout, and its process group is terminated; the result names the agent,
the protocol version and the number of sign-in methods, or why the command failed (it could not start, did
not answer, exited with its last stderr line, spoke another protocol version, or answered with an error).
`claude` and `codex` are shown with the registry adapter they need and an Install button.

Tests cover discovery (relative `PATH` entries, plain files, directories, first match, links not resolved),
the probe against MockAgent and shell fixtures (timeout with termination, early exit with stderr,
unsupported protocol, error response, missing executable) and the catalog (adding, de-duplication,
persistence across instances, removal, suggestions, per-command check results). Replacing the probe's
process termination with a constant status made the timeout and exit-status tests fail before restoration.
Validation: `just lint`, full `just coverage` (784 Swift tests; all module gates; AgentRuntime 93.5%,
AgenthesiaCore 97.4%). After the picker fix, `just lint`, full `just test` (784 Swift tests and 18 script
tests), and `just app` passed again. Views were reviewed with `swiftui-pro`.

Built-app check (2026-10-28, Debug build with the bundle identifier
`io.github.anesthetised.Agenthesia.localagentstest` so the list did not touch the owner's defaults, scripted
with System Events clicks at measured coordinates because walking the Agents tab's accessibility tree with
the full registry list took minutes): On This Mac listed `kimi` and `opencode` with Check and Add, and
Claude Code and Codex CLI with Install Claude Agent… and Install Codex…. Check on
`/opt/homebrew/bin/opencode acp` showed "Speaks ACP v1 · OpenCode 2.2.0 · 1 sign-in method", left no
`opencode acp` process and no probe directory. Add moved OpenCode to the top with Remove and wrote the
defaults key; Add Custom… with
MockAgent's path added "Mock Agent", whose Check showed Echo Agent 1.0.0. The picker listed both, and
choosing OpenCode hid the custom command fields. Removing both emptied the defaults list, and OpenCode
returned to Add with its check result kept. The check found that removing the agent selected in an open
launch form left the picker blank (also possible for an installed version since slice 1); the picker now
falls back to Custom Command, confirmed in a rebuilt app. Not exercised: Check on `kimi` (on this machine
it is Moonshot's Kimi Code, not the registry's Kimi CLI, and its reaction to `acp` is unknown), a session
started with a local agent (it uses the existing manual-command path; skipped to keep history clean),
Install from a suggestion, Look Again, VoiceOver and system prompts. The first scripted run raised a macOS
prompt for T3 Code to control the computer, which the owner resolved.

#36 slice 3 is implemented locally on `feat/agent-pre-session-sign-in` (2026-10-29), under the owner-approved
[ADR-0038](adr/0038-pre-session-sign-in.md). Settings → Agents offers Sign In… for the newest installed
version and for added local agents. A separate `AgentSignIn` initializes in an empty temporary directory,
offers the advertised agent/terminal methods, and never creates a session, worktree or history row.
Installed versions stay leased through process cleanup. Terminal success reconnects and initializes;
completion is reported after cleanup without a persistent account-status badge. Session-time sign-in
remains necessary when an agent does not retain credentials across connections.

Core tests cover request/capability boundaries, success and errors, empty/unknown methods, timeout,
terminal results and reinitialization, cancellation during authentication, acquisition and process
launch, and an agent exiting while methods are displayed. The idle-exit regression failed before an
exit observer was added. Deliberately inverting the terminal exit-code condition failed all three result
cases; the original condition was restored. Catalog tests check version pinning across an update,
lease release, the login-shell environment, and stale dismissal. Hosted native-window tests check
Settings closure and quitting with a sign-in but no session. `just lint`, `just test` (801 Swift tests
and 18 script tests), `just coverage` and `just app` pass. All coverage gates pass, including
AgenthesiaCore at 97.7% and AgentRuntime at 93.6% on the final run; one corrupt subprocess profile was
excluded by the existing coverage reporter.

Native-app checks on 2026-10-29 used Accessibility scripting (computer-use tools were unavailable), a
separate bundle identifier and an isolated Foundation home, verified against the process environment
and open history database. With MockAgent, agent-method and terminal-method sign-in completed and
stopped their processes; terminal failure retained output, Retry fetched methods again, and Cancel
closed the sheet and stopped the terminal. Session, event and project tables remained empty. Screenshots
are under `.build/verification/pre-session-sign-in/`. A focus guard rejected input while the test app
was not frontmost. Native Quit exposed an AppKit gate before the delegate: modal sign-in sheets blocked
termination. Hosted-window regressions failed for both sheet types before explicitly allowing modal
termination. After the fix, Quit worked with the method list open and with a running terminal;
terminal Quit was repeated using the app menu after Cancel, closing Settings and reopening it. Each
quit stopped both processes and removed the sign-in directory. The final lint, tests, coverage and app
build passed. The test app, its defaults and isolated data were removed; screenshots and check logs
remain in the ignored verification directory.
VoiceOver, real-agent credentials, installed-agent UI, system prompts and window restoration were not
checked; installation leases and native Settings closure were covered by automated tests.

### Pre-session sign-in CI readiness (#36, PR #143)

[Run 40772123350](https://github.com/anesthetised/agenthesia/actions/runs/40772123350), on `b477afe`,
passed lint, the app build, runtime tests and hosted tests. Two of the 482 core tests failed while
polling sign-in fixture readiness: the missing-executable and pending-launch tests reached the shared
ten-second deadline before their preparation tasks entered the test gate. Other main-actor tests took
30–40 seconds in the same run. Delaying preparation by eleven seconds reproduced the missing-executable
failure locally after ten seconds, before the executable was attempted.

The gate now signals entry through continuations, following the existing test-gate pattern. The
pending-launch test captures the actual process and launch directory instead of waiting for shell
marker files; it still checks that close stops the process and removes the directory. Both affected
tests passed with the eleven-second preparation delay, which was then removed. Remaining polling
failures report the caller's source location. The one-minute suite limit, CI process timeout and
production timeouts are unchanged. `just lint`, `just test` (801 Swift tests and 18 script tests) and
`just coverage` pass. All module gates pass, including AgenthesiaCore at 97.6% and AgentRuntime at 93.6%;
the reporter excluded one corrupt subprocess profile.

### Installer cancellation test readiness (#35, PR #140)

[Run 40548357958](https://github.com/anesthetised/agenthesia/actions/runs/40548357958), on `12dd3df`,
passed lint and the app build. Its only failure among 573 non-hosted tests was
`cancellationStopsTheProcessGroupBeforeTheCaptureDeadline`: the three-second `waitForChildPID` deadline
expired before the PID was available, before the test requested cancellation. The log does not establish
whether the delay occurred in task scheduling, the utility queue or process startup. A fixture delaying
startup by four seconds reproduced the same timeout locally against the old test.

The test now races child readiness against capture completion in a structured task group. An early
capture exit reports its actual outcome; the capture's existing 30-second deadline and the suite's
one-minute limit bound the test. Group cancellation joins cleanup before removing temporary files.
Once ready, both immediate and delayed fixtures still require a cancelled result, return within ten
seconds of cancellation, and an inactive child. Temporarily disabling cancellation polling made both
cases fail the ten-second assertion; production code was restored. Other callers retain the PID helper's
existing default deadline. This addresses this test's startup assumption, not the broader #133 audit.

Local `just lint` and full `just test` pass (758 Swift tests and 18 script tests). Instrumented
`just test --build-system native` with CI's non-hosted selector passes 573 tests in one combined bundle,
including both readiness cases. This follows the CI bundle structure on the local toolchain; it does
not reproduce the runner's exact scheduling load. CI confirmation awaits the follow-up push.
Production code and coverage thresholds are unchanged; the app build already passed on the failing run.

### Runtime process-test isolation and observation races (#133, PR #140)

[Run 40551715264](https://github.com/anesthetised/agenthesia/actions/runs/40551715264), on `e372241`,
passed the repaired capture cancellation test, lint and the app build. Its non-hosted group took 81.5 s
and reported seven issues in five existing process tests. Two observed a descendant only after natural
leader-exit cleanup had killed it; the stderr test also assumed its drain could not already be finished.
The other failures involved graceful-exit expectations and a ten-second bound under concurrent load.
These results do not establish a production termination defect, and no signal/grace policy is changed.

Delaying observation by four seconds reproduced the descendant-group and already-finished-drain
failures locally. Both integration fixtures now wait for an explicit release before the leader exits,
so their process-group assertions run while the leader is still alive. A separate stderr-reader test
keeps the writer open and checks the drain's own deadline without natural process cleanup or EOF.
`StderrCapture` is internal for this focused test; its implementation and public APIs are unchanged.

Coverage now separates AgentRuntime from Core as well as hosted views, extending the existing process
isolation. It builds once and runs three sequential groups: 451 remaining core tests, 123 runtime tests
and 185 hosted tests. A complement selector includes future targets automatically. Every group retains
its existing 120-second process timeout and parallel tests; any failure fails the run, all groups still
execute, and separate profile prefixes preserve merged coverage. Tests cover the partition, near-matching
target names, unique profiles and failure propagation from each group. A deliberate duplicated-runtime
selector failed those tests before restoration. This adds one test-driver invocation; no CI speedup is claimed.

Update (2026-10-30): after #171 the hosted group took 115–119 s on CI and then ran into the timeout on main.
Nothing hung. `SessionPaneLayoutTests` waited a fixed 400 ms after every step; it now waits until the panes the
model asks for are on screen and still (400 ms at most) and checks 740 and 1400 pt, not 1000 pt as well. That
cut the suite from 39 s to 8.5 s locally and the hosted group from 50 s to 25 s. The hosted group's
process timeout is now 240 s; core and runtime keep 120 s.

Local `just lint`, 18 script tests and all 759 Swift tests pass. The three selectors were exercised
sequentially with instrumented `just test --build-system native`, preserving CI's combined-bundle layout,
and then through full `just coverage`: every module gate passes (AgentRuntime 91.9%). `just app` passes.
The delayed-observation regressions first failed before the fixture changes. CI confirmation awaits
the follow-up push; the broader scheduling/wait audit and consecutive CI verification in #133 remain
open. No benchmark or native-app UI check was run.

### Flaky `SessionControllerTests` in CI (#129, 2026-10-25)

The CI runner is not frozen during these failures; its main actor is saturated. In the failed run on
`0fcb77a`, tests that take a fraction of a second locally (in-memory `EchoAgent` sessions, hosted views)
each took 40–43 seconds and finished in one burst, as a shared serial queue does when it drains: hundreds
of `@MainActor` tests (`SessionController`, hosted AppKit and SwiftUI views) share one main thread on a
3-core runner. `ScenarioAgent` runs off the main actor, and its 5-second wait for the next client message
expired while the controller was still queued, so it reported a mismatch and closed the transport. That
yields every symptom in the issue: `start` throwing `.closed`, a prompt error read as transport loss
(`.failed`, then `.invalidState`), a non-`nil` mismatch, and a test waiting for a notification that never
comes until its time limit. The stack sample taken at the 120-second process timeout showed every thread
idle, so no test was spinning or blocking a thread at that point.

The default wait is now 50 seconds (`ScenarioAgent.defaultTimeout`): playback still ends, and closes the
transport so the test's awaits fail with its step, before a suite's one-minute time limit. A regression
test answers after 6 seconds and fails with `.closed` on the old default. A temporary experiment (not
committed) blocked the main actor for 6 seconds during `SessionController.start` against a scenario: it
failed with `.closed` at 5 seconds and passed at 50. `just lint` and `just test` pass.

Not addressed: the saturation itself (#133); other waits tuned to a quiet machine can fail the same way.
The test process's output also reaches the CI log in buffered bursts, so its timestamps do not show when a
test ran, and output still buffered when the process is killed is lost (#134).

### Agent sign-in (#32, 2026-10-25)

The owner accepted [ADR-0033](adr/0033-agent-sign-in.md): sign-in is offered when the session request gets
`-32000`, in the same session and worktree; agent methods use `authenticate` on the open connection, and
terminal methods run in a SwiftTerm sheet before the agent is launched again. Checking the adapters'
sources showed why both kinds are needed: `claude-agent-acp` offers only terminal methods, and only to a
client declaring `auth.terminal`; `codex-acp` offers only agent methods.

Slices, one commit each on `feat/sign-in`: `TerminalProcess` input, resizing and output observers; a
retryable `SessionController` (`authenticationRequired`, `retry`); `LiveSession` sign-in with the notice
and MockAgent's terminal login (`--auth`, `--auth-file`, `--login`); the panel, the terminal sheet and the
SwiftTerm dependency. A session waiting for sign-in counts as starting for discard and merge, because a new
one has no history yet.

Tests: terminal input, window size and observers; a start and a reopen that wait without writing, retry
on the same connection, a new connection after a terminal sign-in, close while waiting; against the real
MockAgent process, agent and terminal sign-in, a failed and an ineffective terminal sign-in, Cancel, close
during the terminal, and Continue; the notice and the badge; discard refused while waiting; the method rows,
the panel at 480 pt, the window model's sheet binding, and SwiftTerm showing output and sending typing.
Turning off `auth.terminal`, the discard guard, or the terminal's output feed each makes a test fail.
`just lint`, `just coverage` (694 Swift tests; Core 97.9%, AgentRuntime 92.9%) and `just app` pass.
`swiftui-pro` asked to put each type in its own file (applied). Pitfall: MockAgent's stdio transport read
standard input as soon as it was created, so `--login` creates it only in the agent modes.

Built app, checked by script (no computer use in the session) with MockAgent `--auth` in a temporary Git
repository, a temporary `CFFIXED_USER_HOME` and a fresh bundle identifier: the panel with both methods, the
*Needs input* mark in the sidebar and the Dock badge; the terminal sheet showing the prompt; a wrong answer
leaving the output and "Sign-in exited with status 1." until Close; the right answer closing the sheet and
opening the composer in the same worktree; Cancel killing the login process; the agent method opening the
composer. Not checked: VoiceOver, the system notification banner of the sign-in notice, a real
`claude-agent-acp` or `codex-acp`.

### M8 slices (2026-10-24)

The owner accepted [ADR-0032](adr/0032-worktree-merge-and-discard.md) after comparing T3 Code: the base
branch is recorded at start, the base is not pinned, merge is a local squash in the project checkout, and a
merged or discarded session is read-only. Each issue is written to be picked up by an agent of its tier
without this conversation; tiers follow AGENTS.md (light: Sonnet or Sol; strong: Opus or Astra; both at High).

| # | Issue | Depends on | Tier | Acceptance in short |
|---|---|---|---|---|
| 1 | #41 Record the base branch | — | light | `baseBranch` stored at start; nil for detached `HEAD`, non-Git and legacy sessions. Merged in #123 |
| 2 | #44 Discard and the worktree outcome | #41 | strong | `worktreeRemoved` event, safe removal of Agenthesia's worktrees only, Continue disabled, confirmation. Merged in #124 |
| 3 | #42 Review view | #41 | light | `baseBranch...HEAD` plus uncommitted, file by file; ADR-0024 fallback without a base branch. Merged in #125 |
| 4 | #43 Squash merge | #44, #42 | strong | Preconditions, intermediate commit, squash and final commit with hooks, rollback on failure. Implemented on `feat/worktree-merge`; verification below |

#42 and #44 can run in parallel in separate worktrees after #41; #43 reuses the removal and the event of
#44 and opens from the review view of #42. Each slice is its own branch and pull request, and closes its
issue. Pitfalls: the removal must never touch a directory outside the worktrees root (sessions of non-Git
folders run in the user's own directory); `git` commands run in the project checkout for merge and branch
deletion, and in the worktree for the intermediate commit.

#41 verified: `just lint` and `just test` pass. New tests cover a named branch, a branch with a slash, a
detached `HEAD`, a subdirectory selection and a non-Git folder; a round trip, a v1 and a v2 database upgrade
that leave `baseBranch` nil; and the branch surviving start, history and Continue. The first run failed to
compile against the missing property (RED). `just coverage` passes all gates (Workspace 97.4%, Persistence
100%, Core 98.3%) and `just app` builds. No UI changed.

#44 implemented: the outcome event and its replay, `SessionWorkspace.Worktree`/`remove`/`discardSummary`,
`SessionManager.discard`, *Discard Worktree…* in the Session menu and the sidebar context menu, the
confirmation and error alerts, and the outcome under saved sessions in the sidebar. `SessionManager.resume`
now returns nil while the session's worktree is being discarded. Workspace tests cover clean, dirty,
untracked and committed worktrees, a directory deleted by hand, a missing branch, an unregistered directory
at the expected path, refusal for a wrong id, the user's checkout, a path outside the root, a sibling with the
same prefix and a non-Git session, and the summary counts; breaking the path check makes the refusal test
fail. Core tests cover the event coding and replay, discarding a live and a saved session, a failed removal
(a locked worktree) that appends nothing followed by a successful retry, coalesced discards with Continue
refused meanwhile, refusal while continuing, and non-Git sessions; removing the replay guard in
`LiveSession` makes the Continue test fail. UI tests cover `canContinue`, menu eligibility, the alert text,
and a second window learning the outcome. `just lint`, `just test`, `just coverage` (Core 98.3%, Workspace 97.7%, Persistence 100%) and `just app` pass; `swiftui-pro` asked for model
bindings instead of `Binding(get:set:)` (applied; `alert(_:item:)` needs Xcode 27, which CI lacks).

#44 follow-up (2026-10-24): fixed two reproduced defects. The alert now passes its captured confirmation
to `confirmDiscard` because SwiftUI clears the presentation state before the button's task runs. Removal
checks the exact session branch immediately before `git worktree remove`; a different branch or detached
HEAD leaves the worktree and branches intact. Missing-directory/missing-branch retries still succeed.
Regressions failed before the fixes and pass afterward; inverting the branch guard also fails the new
preservation test. `just lint`, full `just test`, `just coverage` (Workspace 97.7%, Core 98.3%, Persistence
100%) and `just app` pass. The changed alert was reviewed with `swiftui-pro`.

Computer-use checks in the built app with MockAgent and temporary Git repositories pass: Session menu and
sidebar context menu, live and saved discard, confirmation counts, Cancel, and the error alert when the
branch changes after confirmation opens. The rejected removal preserves the dirty files; restoring the
session branch allows a retry. Successful removal deletes the session worktree and branch, preserves the
project checkout and other branch, retains the transcript, shows Discarded, and disables Continue and
repeated discard. After Quit/relaunch, selecting both sessions from history preserves those outcomes without
starting an agent. Screenshots were captured. VoiceOver, system permission prompts and automatic window
restoration were not checked.

#42 implemented (2026-10-25): `SessionWorkspace.review` resolves the base branch's merge base and
returns net working-tree changes, statuses and rename sources, plus nonignored untracked files.
Without a base branch it uses `baseRevision`, or HEAD for legacy working changes; a missing base branch
is an explicit error. `reviewContents` size-checks an immutable blob before loading it. Core's
`SessionReview` loads the selected file only, applies `SessionFileDocument`'s UTF-8/NUL and 2 MiB limits
to both sides, rejects outside symlinks and replaced roots, and retains a still-differing selection.
The native review sheet opens from the Session menu (⌃⌘R; ⇧⌘R remains Resume Queue) and Changed Files.
It shares `SessionFiles` invalidation, shows status and rename source, and renders through `UnifiedDiff`
and the native Markdown preview off the main actor. Merge remains #43.

The UI reference was T3's Changes entry point and
[DiffPanel](https://github.com/pingdotgg/t3code/blob/main/apps/web/src/components/DiffPanel.tsx).
A system sheet with a native selectable list and one unified diff follows VISION principles 2–3 and
keeps the existing 740 pt main-window minimum; layout and base-selection settings are omitted under
principle 6 and ADR-0032.

Focused tests pass: committed/staged/unstaged/untracked changes, a base advanced independently,
renames, deletion, subdirectory scope, base-revision and HEAD fallback, missing branch, bounded
historical reads, binary and invalid UTF-8 contents, outside symlinks and root substitution. Replacing
the merge-base calculation with the base branch tip makes the divergence test fail (then restored).
Hosted native-view tests pass in Aqua and Dark Aqua at 640 and 900 pt, covering the file list, Down-arrow
navigation, two-way selection, selectable read-only diff text, watcher-driven updates with selection
retained, binary notices and command eligibility. `swiftui-pro` review found no blocking issues.
`just lint`, full `just test` (650 Swift tests and 15 script tests) and `just coverage` pass all gates
(Workspace 98.0%, Core 98.4%, Persistence 100%); `just app` builds.

Computer-use checks in the built app with one MockAgent session and a temporary Git repository pass:
⌃⌘R and the Changed Files action open review; committed, staged, unstaged, added, deleted, renamed and
untracked files show correctly, while an unrelated base-branch commit is omitted. Tab into the list
and Up/Down change the selected diff. An external edit refreshes its contents without moving selection.
Binary and oversized files show their notices. Renaming the base branch produces an error naming it;
restoring it reloads review. End Session and Quit/relaunch preserve review for read-only saved history
without starting an agent. Light and dark screenshots were captured; the light pass used a process-only
`NSRequiresAquaSystemAppearance` argument, without changing System Settings. The test app was quit and
temporary repository/worktree files removed. No code fix was needed. VoiceOver, system permission
prompts and automatic window restoration were not checked.

#43 implemented (2026-10-25): `SessionWorkspace.mergeCheck` and `merge`, `SessionManager.merge` with the
turn hold in `SessionController`, the `merged(commit:into:)` outcome, and the merge sheet from review and the
Session menu. The owner settled four questions the ADR left open: the final commit runs in the login shell's
environment, the default message is the agent's session title or else the first prompt line, a saved
session merges without starting its agent, and a hanging hook has no Cancel (quit waits for the merge).
The owners end before the outcome is appended, rather than after as the issue listed, because closing
can still record events and the outcome must stay last. No `merged` event had been written before, so
the payload gained the base branch without a migration.

Workspace tests with temporary repositories cover committed, uncommitted, untracked and deleted changes
squashed into one commit with the session's exact tree and message; a base advanced independently; a
conflict, a rejecting `pre-commit` hook, an untracked file the merge would overwrite and changes already on
the base, each restoring the checkout without `SQUASH_MSG`; hooks found only on the given `PATH`
(`commit-msg` and `pre-commit`); and every blocker (dirty checkout, other branch, detached checkout, missing
base, no base, nothing to merge, worktree off its branch or missing, unresolved worktree conflicts) leaving
refs, the checkout and the worktree untouched. Core tests cover a live and a saved merge, refusal during a
turn, prompts, Continue, discard and a second merge refused while merging, quit waiting for a merge, a
conflict that keeps the agent usable, a failed removal that keeps the merge and lets Discard finish it,
and a session without a base branch. UI tests cover command eligibility and title, the default message,
blocker and conflict states kept in the sheet, and the read-only result. Removing the hold from
`dispatch`, any of the three `git reset --merge` calls, or the outcome guard in discard makes a test fail.
`just lint`, full `just test`, `just coverage` (Core 98.0%, Workspace 97.9%, Persistence 100%) and
`just app` pass. `swiftui-pro` asked to split the sheet's types into files and not to rely on colour
alone for failures (applied); a vertical `TextField` was rejected because Return would press Merge.

Checks in the built app (2026-10-25), scripted because the session had no computer-use tools (see
AGENTS.md): a copy with its own bundle identifier ran with `CFFIXED_USER_HOME` pointing at a temporary
directory, so its history, worktrees and Git identity never touched the owner's. MockAgent worked in a
temporary repository with a `commit-msg` hook that appends a line, and wrote `notes.txt` through a real
permission request. With a turn waiting for permission, *Merge into main…* explains that the session is
busy and offers no Merge button. A dirty project checkout shows its blocker, and Git is left untouched.
With the base branch advanced on the same file, Merge reports `file.txt`, leaves the base branch and the
checkout as they were (no `SQUASH_MSG`) and the agent usable; the worktree only gains the intermediate commit.
After the base was reset, the same sheet merged: one commit on `main` with the edited multi-line message and
the hook's line (so the hook ran in the app's environment), the tree of the session including its
untracked files, the worktree and branch gone, the session read-only with “Merged into main as a21ca50.”,
“Merged” in the sidebar, and Continue, Discard, Review and Merge disabled. After Quit and relaunch the
session opens from history read-only without starting an agent. The check found two defects, both fixed
and re-checked in a rebuilt copy: the failure text in the sheet was cut off to one line, and the commit
message field stayed visible beside a blocker. MockAgent's `write` needs an absolute path. Screenshots were
captured; the test app was quit, the clipboard restored and temporary files removed. The owner can remove
the notification entry of `io.github.anesthetised.Agenthesia.mergetest` in System Settings → Notifications
(its first-run prompt appeared). Not verified: VoiceOver, commit signing (needs the owner's key and
pinentry), and a hook that hangs.

#43 review follow-up (2026-10-25): a `/code-review` pass found ten issues; nine are fixed. A history write
failing after the commit and a failing `git reset --merge` no longer read as "the checkout was left as it
was"; the alert about a kept worktree appears after the sheets close; the intermediate commit runs no hooks
(`--no-verify` still ran `prepare-commit-msg` and `post-commit`); a merge, cherry-pick, revert or rebase in
progress in the checkout blocks the merge instead of being aborted by the reset; discarding a merged
session's leftover worktree says nothing is lost; leftovers are found at history refresh, not per sidebar
render; ADR-0032 gained notes for the refinements; and duplicated text and code were shared. The message
file is now written before anything changes. Not fixed: a removal that deletes the directory but fails to
delete the branch leaves `agenthesia/<id>` for the user to delete, because the app cannot see it without
running Git per row. New tests cover the hooks, the in-progress operation, a failed restore (a held
`index.lock`), the failed history write, and the kept worktree through the window model; removing the
hooks override, the operation check or the restore classification makes a test fail.

CI on #127 (2026-10-25) stalled the whole test process for about 43 seconds and ran into its 120-second
limit; main had finished its 650 tests in 34 seconds. Every suite that starts Git or an agent was slow at
once, and the stack of the stalled process stood in a test's `while controller.status != .running { await
Task.yield() }`: after the 60-second limit cancelled the test, the loop kept spinning on the main actor
shared by every other test. Waits in the merge tests now poll with `Task.sleep` under a deadline and fail
instead of spinning, and the three merge suites run one test at a time (`.serialized`), because eleven
Workspace tests started Git processes at once. The Workspace fixture writes its Git configuration in one
write instead of four processes. The first cause of the stall (a thundering herd of Git processes, or the
spin after the first timeout) was not reproduced locally, where the suites take 4–13 seconds.

### M7 slices (2026-10-17)

The owner accepted ADR-0026. Slices 1–2 are merged; slice 3 (#39) is implemented in this batch.
Implement slice 5 (#40) before slice 4 (#38), so notification activation reuses window opening and
selection.

| # | Slice | Acceptance and verification | Model and effort |
|---|---|---|---|
| 1 | `SessionManager` in Core owns every `LiveSession`; windows select one; closing a window detaches; quit closes all owners; the `SessionLibrary` live claim moves into the manager | Several sessions run at once; Continue on a live session selects it; a failed session stays until ended or continued; quit waits for every owner, including one still starting | Opus, high; merged in #118 |
| 2 | Sidebar: projects → sessions with derived statuses and the in-memory *done* mark | Status priority (needs input, failed, working, done, idle) is a pure tested function; showing a session in a key window clears *done*; accessibility labels | Sol, medium; merged in #118 |
| 3 | Quit confirmation and the Session menu (#39) | Confirmation only when a session works or needs input; previous, next and next-needing-input navigation in sidebar order | Sol, medium; implemented, verification below |
| 5 | Multiple windows and restoration (#40) | Window opening and selection are shared with later notification activation; value-based `WindowGroup` restores selections read-only with Continue; no agent starts on relaunch | Sol, medium; merged in #120, see below |
| 4 | Notifications with actions and the Dock badge (#38), after #40 | Posted only when the session is not in the key window of the active app; Allow once and Reject only for `allow_once`/`reject_once`; badge counts sessions needing input; system seams injected | Sol, high; implemented on `feat/notifications-dock-badge`, see below |

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
native selection. The owner subsequently passed queue shortcuts, recoverable `fail`, selected-session
End, and quit confirmation/cancellation. Native selection is visible in the supplied screenshot.
The fatal `exit` check exposed disabled Continue: history refreshed on the controller's early ID, before
its database insert, and was not refreshed when startup completed. Refreshing after startup settles
preserves the saved-session eligibility guard and makes Continue available after process cleanup.
A hosted RootView regression blocks the initial insert, then verifies automatic history refresh and
`exit` → Continue → idle on the same session. Fresh Return after Continue is also covered by the
ADR-0029 follow-up below.
The combined follow-ups passed `just lint`, `just test` (591 Swift tests and 15 script tests), `just coverage`
(all gates; Core 98.2%), and `just app`. Queue, native sidebar and startup-persistence/Continue regressions were verified RED then
GREEN; the native selection check also fails when the binding is removed. `swiftui-pro` and code review
found no blockers. The first full run hit an existing shell-descendant timeout test before its PID file
was created; the isolated retry and subsequent full run passed without changes to that test.

Further acceptance exposed a pause that survived Continue and repeated explicit sends. The owner
accepted [ADR-0029](adr/0029-empty-queue-recovery.md): idle Return sends into an empty queue;
Continue clears only an empty queue's pause, and explicitly sending the last queued entry durably
restores ordinary sending. Retained entries stay paused; a newer Stop wins over a pending send.
Queue fixtures now create retained entries during a real running turn before Stop, rather than using
an empty paused queue to force new drafts into it. Regressions reproduced repeated fresh-draft
queueing after error/Continue and sticky pause after explicit flush before the fix.
The final follow-up passed `just lint`, `just test` (594 Swift tests and 15 script tests),
`just coverage` (all gates; Core 98.2%), and `just app`. The new Stop/injection regression fails if the generation
guard is removed. The atomic-dequeue failure test covers paused sends and verifies that a failed
batch commits neither the unpause nor the dequeue. `swiftui-pro` and code review found no blockers.
The owner passed the remaining native checks: repeated Return after `fail`, Return after
`exit`/Continue, and Return after explicitly draining retained paused entries. The supplied screenshot
shows separate fresh prompts receiving replies with an empty composer and Idle status. The agreed
manual acceptance checklist for #39/#117 is complete; retained work still requires explicit dispatch.

Pitfalls: parallel starts with one agent raced in `SessionLibrary.install` (a duplicate insert failed the
second start); installs are now serialized. The window model keeps its own selection token for history loads; a window may display an
owner the manager already removed, which then reads as ended. Run `swiftui-pro` over changed views.
CI exposed a process-readiness polling race: a task can resume after its deadline with the child PID
already recorded. Check readiness before the deadline; regression tests cover both a ready PID and a
missing PID after expiry.
Issues close with the slice that completes them: #37 with slice 2, #39 with slice 3, #38 with slice 4,
#40 with slice 5.

#### Notifications and the Dock badge (#38)

[ADR-0030](adr/0030-notification-activation-and-identity.md) is accepted. `SessionAttention` (Core) derives
notices from the manager and the sessions the windows report as shown, and drives an `AttentionSink`;
`SystemAttention` (UI) posts them through `UserNotifications` and sets the Dock badge. A tap opens
`agenthesia://session/<id>`; `RootView` handles it with `onOpenURL`, filling a lone blank launch form in
place or opening the session's window with `openWindow(value:)`. Tests cover derivation, identity and
removal, shown-window suppression, the badge, one-time authorization, `canDecide`, the payload and button
routing, URL parsing and window activation; removing the shown-session filter fails the suppression test.
Checks of the built app, scripted because the session had no computer-use tools (see AGENTS.md): with a
blank window, several windows, no window and a cold start the URL shows the session once and leaves no stray
launch window. With a MockAgent session and Finder in front: the system permission prompt appears at the
first session start; a permission request posts a banner with Allow once and Reject, and both buttons
record `allow` and `reject`, clear the banner and the Dock badge, and leave the app in the background; a
turn that ends while the session is not shown posts the finished banner, and one that ends while it is shown
does not. The check found that the badge never appeared because authorization omitted `.badge`; with it the
Dock shows `1` while a request waits and clears on any answer. A copy built with another bundle identifier
gave a fresh authorization to prove that. Tapping the finished banner (a System Events click; synthetic
CGEvent clicks and `AXPress` did not reach the app) brings the app forward and shows the session in its own
window. The blank *New Session* window seen at first came from a second process: Notification Center routes
a tap by bundle identifier, and with several copies registered (worktrees, derived data) it launched another
checkout's build next to the running one. A build with its own bundle identifier taps into the running
process, with no second process and no extra window.
Not verified: VoiceOver and the first-run prompt text.

Pitfall: `handlesExternalEvents(preferring: [], allowing: ["*"])` is what stops the system opening a new
window beside the one that handles the URL; without it every tap added a blank window.

#### Window restoration (#40)

Windows use `WindowGroup(for: WindowTarget.self)` (`.launch` or `.session(id)`). `RootView` publishes the
displayed target through the group's binding, which the system persists, and `SessionWindowModel.restore`
shows a saved session read-only (Continue available) or falls back to the launch form when the record is
gone. The sidebar context menu's Open in New Window calls `openWindow(value:)`, which raises the window that
already shows the session. Notification activation (#38) reuses the same call.

Hosted tests cover restoring, publishing and falling back. The owner's relaunch check needs System Settings →
Desktop & Dock → *Close windows when quitting an application* turned off: with it on, nothing is restored,
whatever the app does. With it off, three windows (launch form plus two saved sessions) came back after
Quit and relaunch with no agent started, and File → New Window twice opened two separate launch forms.
The context menu itself is a manual check (the accessibility tree did not expose it to scripting).

#### App icon and Dock tile (#45)

The icon half of #45; its first-run flow is separate work. [ADR-0031](adr/0031-app-icon-and-dock-tile.md) is
accepted. The app icon is the layered `App/AppIcon.icon` (sky fill, moon and stars as SVG layers with night
variants), so macOS 26 can build the Default, Dark and Tinted renditions; an `appiconset` cannot, because `actool`
drops its dark entries. `AppIcon` (UI) draws a sleepy moon with up to five stars for the Dock tile, README shows
the static `docs/images/logo-light.svg` and `logo-dark.svg`, and the three are kept in step by hand.
`AttentionSink.setDock(badge:live:)` replaces `setBadge`, and `SystemAttention` draws the tile while sessions
are live: one star per session that has not failed, open eyes while one needs input, and the icon from
`AppIcon.icon` back when none runs. The tile is always the light sky: the Dark, Clear and Tinted icon styles are
the system's, and the app has no public way to read them (see the ADR). The version that followed the app's
appearance is kept at the tag `app-icon-dark-mode-tile`.

Tests cover the stars' clamping, the eyes, the transparent margin and the live count the sink receives (a failed session stops counting). Rendering is stable to the eye but
not to the byte: the same icon drawn after a few others differs in rounding, so tests compare pixels with a
tolerance. Checked in a built process, not in the app: a scratch executable put `NSHostingView<AppIcon>` into
`NSApp.dockTile.contentView`, and a screenshot of the Dock showed the tile at the size of its neighbours, asleep
with three stars and then awake with one star and the badge `1`. The `.icon` compiles with `actool`, and the
built catalog holds Aqua, DarkAqua and Tintable stacks with the night layers and a separate dark gradient; the
default rendition, viewed as the compiled `AppIcon.icns`, matches the design. After adding the first icon, Launch
Services kept the Dock's generic icon for an already registered build path until `lsregister -f` re-registered
the bundle.
Not verified: the whole path with a real session in the running app (it would add a session to the owner's
history, which cannot be deleted), how the Dark, Clear and Tinted renditions look in the system (the Icon Composer
file was written by hand and only compiled, and switching the owner's icon style was not done) and VoiceOver.

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
