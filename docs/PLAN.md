# Work plan

The near-term order of work, for agents and humans picking up the next task. Milestones and issues on
GitHub stay the source of truth for scope; this file records order, dependencies, and the pitfalls known
so far. Update it when a step lands or the order changes. Finished milestones are in
[plan-archive.md](plan-archive.md).

Every step follows [AGENTS.md](../AGENTS.md): issue → branch → tests and docs → pull request after the
owner's approval. Architectural choices are presented to the owner as options with a recommendation
before implementation.

## State (2026-11-10)

**On `main`.**

- **Sessions.** Live sessions end to end: tool call cards, permission requests, a scoped file system and
  agent-reported command output ([ADR-0014](adr/0014-window-bound-live-sessions.md),
  [ADR-0016](adr/0016-agent-reported-command-output.md)). History opens read-only and Continue reattaches it
  ([ADR-0017](adr/0017-continue-saved-sessions.md)). A durable prompt queue with editing, ordering and steering
  ([ADR-0010](adr/0010-prompt-queue-and-steering.md), [ADR-0021](adr/0021-prompt-queue-lifecycle.md)), native
  elicitation forms ([ADR-0020](adr/0020-native-elicitation-forms.md)) and session config controls
  ([ADR-0019](adr/0019-session-config-controls.md)).
- **Files and review.** Quick Open, the file pane, changed files against the session base, transcript paths and Open
  in Editor ([ADR-0023](adr/0023-session-files.md), [ADR-0024](adr/0024-changed-files-session-base.md),
  [ADR-0025](adr/0025-transcript-paths-and-editor-handoff.md)); the review pane with Ask Agent
  ([ADR-0041](adr/0041-review-pane.md)); squash merge, discard, push and pull requests
  ([ADR-0032](adr/0032-worktree-merge-and-discard.md), [ADR-0045](adr/0045-push-and-pull-requests.md)).
- **Several sessions.** The app-wide session manager ([ADR-0026](adr/0026-app-wide-session-manager.md)), worktrees
  from the fetched upstream, sessions in the project folder and without a project
  ([ADR-0047](adr/0047-worktrees-from-the-fetched-upstream.md), [ADR-0043](adr/0043-sessions-in-the-project-folder.md),
  [ADR-0048](adr/0048-sessions-without-a-project.md)), the sidebar with its shelves, the session board and the menu
  bar item ([ADR-0046](adr/0046-session-board-and-menu-bar.md)), notifications and the Dock badge, delete and archive
  ([ADR-0044](adr/0044-delete-and-archive-sessions.md)).
- **Agents.** The registry, installs with the user's runtimes, local agents and sign-in
  ([ADR-0034](adr/0034-agent-installs-with-user-runtimes.md) to [ADR-0038](adr/0038-pre-session-sign-in.md),
  [ADR-0033](adr/0033-agent-sign-in.md)).
- **The window.** The layout after T3 Code and the composer-first start
  ([ADR-0039](adr/0039-t3-style-window-layout.md), [ADR-0040](adr/0040-composer-first-session-start.md)); how it
  behaves now is in [docs/behavior/](behavior/).

**Milestones.**

| Milestone | State |
|---|---|
| M1–M4, M6–M8, M15, M18 | Closed. How they were built and verified is in [plan-archive.md](plan-archive.md) |
| M16 Multi-agent workflow | Everything landed except #234 (verification in the running app) and its tracker #220. #234 runs now, before M20's sidebar and attention changes, and closes M16; the README screenshots moved to #400, after those changes |
| M13 Agenthesia tools | Wave 0 and part of wave 1 landed (#308, #309, #56, #311). The review of 2026-11-10 amended ADR-0049: ADR-0051 is to be written (#354), and a session core wave comes before wave 3 |
| M19 Performance | Planned on 2026-11-10 |
| M20 Review findings | Planned on 2026-11-10. [ADR-0050](adr/0050-settled-is-the-users-decision.md) is accepted and not implemented (#353) |
| M10 Release | After M13 |
| M5 Terminals | #61 and #67 wait for an agent that calls `terminal/create` (#104); #131 is open |
| M9, M11, M12, M14, M17 | Not scheduled |

Kept on record and not scheduled: the issues labelled `discussion` (#344–#350), which hold what the owner did not take
from the review.

Known CI problems: #133 (main-actor saturation in the package test run) and #126 (an intermittent AppKit crash while
rendering Markdown attributes). The records of their investigations are in the archive.

## Next steps

Decided by the owner on 2026-11-10: fixes and measurement first; three lanes in parallel, one agent each in its own
worktree; M16's verification after M20; M10 after M13.

A lane is a sequence. Take its first open issue whose dependencies are closed; an arrow means "after", a comma "in any
order". Tiers are on the issues.

| Lane | Sequence |
|---|---|
| Core (M13) | #373 → #354 → #71 → #355 → #356 → #357 → #358 → #359 → #360 → #361 → #310 → #362 → #312 → #313 → wave 2 (#57, #59, #58, #314, #315, #316) → #60 → #317 → #318 → #319 → #320 → #363 → #364 → #365 → #366 → #321 |
| Performance (M19) | #396 → #97 → #372 → #367 → #370 → #398 → #368 → #369 → #371 → #77, #78, #83 |
| Interface (M20) | #234, #374, #351, #375, #395, #390, #397 → #352 → #353 → #376 → #391, #393 → #392 → #394 → #377 → #379 → #381 → #383 → #385 → #387 → #399 → #378, #380, #382, #384, #386 → #400 |
| Test stability (M10) | #134 → #133, before #355 |
| Any time | #388 (documents and the tracker), #73 (CI with Xcode 27) |

The first step is the head of each lane: #373 and #354; #396, then #97 and #372; #234, #374, #351, #375, #395, #390 and
#397; #134.

#134 and #133 come before the session core: #355–#357 change the queue and the turn paths that the unstable tests
cover, and on 2026-11-10 two full local runs of `just test` failed in `AgenthesiaUITests` and a third passed, so the
instability is not specific to CI.

**#134 (the CI test log).** `coverage.py` ran `swift test` with the inherited standard output, a pipe on CI, so the test
process block-buffered it: the log came in bursts, and what was still buffered at the 120-second kill was lost. A local
check reproduced it: 358 lines of an `AgentRuntimeTests` run arrived at two timestamps. `run_test_process` now runs the
tests on a pseudo-terminal and relays their output line by line, which makes them line-buffered (the output has no
colour codes). At the process timeout it first prints the tests that started and did not finish, then takes the stack
sample. Tests: `scripts/test_coverage.py`, including a check that a pipe reader sees a line while the child still runs.
Open: look at a CI log, where each `started`, `passed` and `failed` line should carry its own time, and the list after a
timeout should name the stuck tests.

Dependencies across lanes: #353 needs #373; #371 needs #355 and #97; #376 needs #368; #363 needs #60 and #352; #366
needs #357 and #60.

**Where the lanes meet.** These files are changed by more than one lane; the order below avoids rebasing large changes.

| Files | Order |
|---|---|
| `SessionController.swift` and the queue | #373, then #390 and #397, then #355–#359; #371 after #355. Nothing else changes the controller while #355–#357 are open |
| `LiveSession.swift`, `MCPSocket.swift` | #71, then #356, then #360 |
| `TranscriptTable.swift`, `LiveTranscript.swift` | #351, then #396 (scrolling), then #367, then #369, then #312 (the typed row model) |
| `SessionController.transcript` and its readers (`RootView`, `SessionInspector`, the sidebar row, the menu bar) | #368 while the interface lane works on the sidebar (#352, #353); #376 after it |
| `SessionSidebar.swift` and the sidebar's views | #352, #353, #381, #385, then #363 and #364 |
| `PromptQueue.swift` and the composer | #390, #391, #393, #392, #394, then #366 |
| Migrations of the session table | #353 (`settledAt`) and #60 (parent, task, agent name) take their numbers in merge order; each has a test on the previous schema file |

Rules that hold for every lane:

- Benchmarks (#97, and the before and after runs of #367–#371) need the owner's approval of the workload, and nothing
  is built on the machine while one runs.
- A check in the running app asks the owner to leave the machine alone (AGENTS.md). The full passes are #234 (M16,
  before the sidebar changes) and #321 (M13); #400 regenerates the README screenshots at the end.
- An issue that says "options for the owner first" stops for that consultation before any view is written.
- A pull request that changes the session core, persistence, permissions or the transcript table, or adds more than
  about 1,000 lines, gets an independent review recorded on it before it is merged (AGENTS.md, *Git*).

After the lanes: M10 (Release) once M13's wave 3 has landed: #45, #46, #47, #48, #49, #66, with #126.
The milestones that are not scheduled follow by the owner's choice.

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

**Session core, before wave 3 (2026-11-10).** The owner's review of 2026-11-10 changed several decisions of ADR-0049's
*Turns started by agents*; ADR-0051 (#354) records them. `session_send` works only inside a delegation tree and can
ask for a reply, delivered like a delegated result; the user's Stop is sticky, with Stop Tree and Stop All Agents;
chains get a counter per tree, no limit and no pause; the queue takes several authors. Not taken and kept on record:
#344 (a pause), #345 (sending beyond the tree), #346 (a queue cap), #347 (`session_read` limited to the tree).

| Order | Issue | Tier | Depends on |
|---|---|---|---|
| 2.5 | #354 ADR-0051: turns between sessions | `agent:strong` | — |
| 2.5 | #355 Session log: one writer per session | `agent:strong` | — |
| 2.5 | #356 Turn router: turn-ended events, Stop through the manager, one end path for a live session | `agent:strong` | #355 |
| 2.5 | #357 Prompt queue for several authors | `agent:strong` | #354, #355 |
| 2.5 | #358 Sticky Stop and Stop All Agents | `agent:strong` | #356, #357 |
| 2.5 | #359 Remove the legacy `send` path and the unreachable inject steering | `agent:strong` | #356 |
| 2.5 | #360 Harden the MCP socket | `agent:strong` | #71 |
| 2.5 | #361 `MCP` module: a tool-call context, cancellation, safe reads | `agent:light` | before #312 |
| 2.5 | #362 Message wrapper: a named source and a delimiter per message | `agent:light` | #354 |
| 3 | #363 Session trees in the sidebar and on the board | `agent:strong` | #60, #352 |
| 3 | #364 A child's permission request on its root | `agent:strong` | #363 |
| 3 | #365 Agent turns and cost per tree | `agent:light` | #60 |
| 3 | #366 Origins in the queue and after a relaunch | `agent:light` | #357, #60 |

Wave 3 now also depends on the core: #60 on #356, #317 on #355–#357, #318 on #317, #356 and #357.

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

## M19: Performance (2026-11-10)

From the performance pass of the same review. Measuring comes first: the Rendering Lab drives the table from a synthetic
source, without `TranscriptState`, SwiftUI observation, SQLite or ACP, no scenario has more than one session, and launch
and peak memory are not measured. Every benchmark run needs the owner's approval of the workload.

| Order | Issue | Tier | Depends on |
|---|---|---|---|
| 1 | #396 fix: scrolling a transcript drops frames (reported by the owner from a Release build; profile first, then row reuse, cached heights, Markdown prepared off the main actor) | `agent:strong` | — |
| 1 | #97 End-to-end streaming bench: the real controller, store and table with 1, 4 and 8 sessions | `agent:strong` | — |
| 1 | #372 Count-based performance invariants in `just test` | `agent:light` | — |
| 2 | #398 Permission card: compute the diff once, off the main actor, and show its first lines | `agent:light` | — |
| 1 | #367 Update the transcript table only on change | `agent:strong` | — |
| 1 | #370 Load highlight grammars off the main actor | `agent:light` | — |
| 2 | #368 Session summary fields, apart from the per-frame transcript | `agent:strong` | — |
| 2 | #369 Cache tool cards by their last event | `agent:strong` | — |
| 2 | #371 Group commit for the event log | `agent:strong` | #355, #97 |
| — | #77, #78, #83 (open research, moved here) | `agent:strong` | — |

Not taken and kept on record: #348 (copies of the item array, repeated decoding, replay on the main actor), #349
(workspace scans, unbounded memory, queries that grow with the number of sessions), #350 (WAL).

## M20: Review findings (2026-11-10)

The owner reviewed the codebase, the issues, the UI and performance on 2026-11-10 (with Claude Fable) and compared the
sidebar with T3 Code again. What was taken is in three places: the session core of M13 (above), M19 (below) and this
milestone, which holds the UI/UX findings, the fixes and the documentation. M10 (Release) follows M13; #45 and #46 got
the first-run, text-size and VoiceOver items.

| Order | Issue | Tier | Depends on |
|---|---|---|---|
| 1 | #373 fix: store `fallbackUpstream` with the session record | `agent:light` | — |
| 1 | #374 fix: the menu bar answers the request it lists | `agent:light` | — |
| 1 | #351 fix: the `Run interrupted` divider is not drawn across the column (against `docs/behavior/transcript.md`) | `agent:light` | — |
| 1 | #375 fix: a command's permission request does not show the command (composer card, board, transcript row) | `agent:light` | — |
| 1 | #395 fix: an agent cannot read files outside the session's folders (reads anywhere, writes inside the roots; a short ADR) | `agent:strong` | — |
| 1 | #352 The list holds the open sessions, the Working shelf only the running ones (UI only) | `agent:strong` | — |
| 1 | #388 docs: reconcile the documents and the tracker with the code | `agent:light` | — |
| 2 | #353 Settled is the user's decision ([ADR-0050](adr/0050-settled-is-the-users-decision.md)) | `agent:strong` | #352, #373 |
| 2 | #376 One attention level for every surface | `agent:strong` | #368 |
| 2 | #377 Keyboard: the gaps that need the mouse today | `agent:light` | — |
| 2 | #379 Review: revert a file | `agent:light` | — |
| 2 | #381 Sidebar: the agent on a row and a card | `agent:light` | #352 |
| 2 | #383 Composer: paste images as attachments | `agent:light` | — |
| 3 | #399 Composer: keep drafts across a relaunch (an ADR first: ADR-0026 says drafts are not restored) | `agent:strong` | — |
| 3 | #400 Refresh the README screenshots after the sidebar and attention changes | `agent:light` | #352, #353, #376 |
| 2 | #385 Rename a session; date headers in Settled | `agent:light` | #353 |
| 2 | #387 Transcript: move between prompts | `agent:light` | — |
| 2 | #390 fix: a queued message can be sent while it is being edited (an open edit holds the queue) | `agent:strong` | — |
| 2 | #397 Session settings during a turn: the mode at once, model and reasoning level from the next turn (an amendment of ADR-0019) | `agent:strong` | — |
| 2 | #391 Queue: change attachments while editing a queued message | `agent:light` | — |
| 2 | #393 Queue: reorder by dragging; two buttons on a row | `agent:light` | — |
| 3 | #392 Queue: step through queued messages, move and delete them from the keyboard | `agent:light` | #390 |
| 3 | #394 Queue: undo for delete, move and edit | `agent:light` | #390 |
| 3 | #378 Command registry, a ⌘K palette and a shortcut sheet | `agent:strong` | #377 |
| 3 | #380 ADR: checkpoints per turn and Rewind | `agent:strong` | #379 |
| 3 | #382 Review: open at the file, move by hunk, ask about a hunk | `agent:strong` | — |
| 3 | #384 Composer: @file completion | `agent:strong` | — |
| 3 | #386 Full-text search over session history | `agent:strong` | — |

The issues of this milestone touch views, not the session core, so they run beside M13's waves.

Pitfalls known so far:

- #352 changes which rows ⌘1…⌘9, Previous and Next Session and the board visit; `SessionSidebar` is the one place that
  orders them, and the menu bar, the Dock badge and `Next Session Needing Input` must keep reading "the rows that need
  the user", not a section.
- #353 adds `session.settledAt` and fills it for every existing session, so the sidebar looks the same after the
  update; the migration gets a test on the previous schema file, as #231 did. `SessionController.createRemote` rebuilds
  the record field by field and already loses `fallbackUpstream`: fix that first, or `settledAt` is lost the same way.
- Unsettle appends an event to the log of a session that is not live. Until M13's single log writer lands, it is
  refused while a Continue of the same session is starting.
- Session trees in the sidebar (M13) build on #352's sections; a delegated session settles with its parent.

## M16: Multi-agent workflow (2026-11-07)

Tracking issue #220. After M15, the owner reviewed the codebase and the open issues (with Claude Fable, 2026-11-07)
and chose a second set of UI/UX changes, several of them against accepted ADRs. The owner accepted all of them on
2026-11-07; the documentation landed in #235.

**Open (2026-11-10).** #234, the verification in the running app, and the tracker #220. #234 runs now, before M20's
sidebar (#352, #353) and attention (#376) changes build on what it checks; the README screenshots are #400, after
them. The board and the menu bar item have not been checked in the running app; the review of 2026-11-10 found from
the code that they show stale text for sessions that no window displays (#368) and that the menu bar can answer a
request it did not list (#374).

| Decision | Where | Status |
|---|---|---|
| Plan in the inspector and the working line; context usage and cost; collapsed thoughts | [ADR-0039](adr/0039-t3-style-window-layout.md), amendment of 2026-11-07 | Accepted (user messages as left-aligned blocks dropped on 2026-11-09, #224) |
| The first message shows at once while the session starts | [ADR-0040](adr/0040-composer-first-session-start.md), amendment of 2026-11-07 | Accepted |
| Sessions in the project folder of a Git repository (a checkout menu in the draft, per draft, worktree by default) | [ADR-0043](adr/0043-sessions-in-the-project-folder.md) | Accepted; landed in #229 |
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

- M16 wave-1 running-app check (2026-11-09; issue #334). Scripted (no computer use) on a test copy with bundle
  identifier `io.github.anesthetised.Agenthesia.m16test`, an isolated `CFFIXED_USER_HOME`, `MockAgent` with a combined
  demo (`scripts/app-check/demos/plan.json` + `usage.json` + one written file) and a throwaway repository with a local
  bare remote; main at 4d1085d plus #331 (push) and #330 (held message). **Checked, light:** draft → Send shows the held
  message, `Starting demo-agent in a new worktree…` and the `Starting…` card, and the message keeps its position when
  the transcript arrives; the Plan section is open during the turn with checkmark, dot and circle rows, `Working for 1s
  · 1 of 4 · Write the failing test` and the Working row's reason `agh-… · Write th…`; the ring at 75 % (secondary) and
  92 % (orange) with the accessibility label `Context 184k of 200k · 92 %, cost 1,23 US$`; the Plan collapses to `Plan
  · 4 of 4` after the turn; Merge into main… shows `Push main to origin` off the first time, ticking it and merging
  pushed the commit to the bare remote (local and remote at the same commit) and the choice was remembered; Delete
  Session… on the merged session said `This session was merged. Its history will be deleted. This cannot be undone.`,
  deleted it (0 sessions, 0 events) and returned the window to the draft. **Checked, dark:** a session without a
  project: `Starting demo-agent in a new folder…`, the inspector's Context `184k of 200k · 92 %` and Cost `1,23 US$`
  (system currency format), Delete Session… disabled while live and enabled after End Session, the confirmation named
  the folder and `1 file … moved to the Trash`, the folder went to the Trash and the history was deleted. **Findings,
  fixed in #334's pull request:** (1) a window that ended a session and then deleted it kept showing the transcript
  with `Session ended`, because `refresh()` only compared the restored or selected session with history; now
  `SessionManager.deletedIDs` lets the window leave the session it displays, which also drops the ended owner (a
  starting session, not in history yet, is never bounced); (2) while a session without a project was starting the
  inspector showed `Change tracking requires Git.`, Review, Merge… and Discard Worktree…;
  `displaysSessionWithoutProject` now knows the project from `LiveSession.startPlace == .newFolder` before the history
  has it. Both have tests. **Not checked:** a failed push's alert in the app (covered by tests), deleting a session
  with a live worktree with changes, VoiceOver, Reduce Motion, sign-in during start. For the next check script: the
  merge sheet and alerts are separate windows (`wintool winid`), so `sheet 1 of window 1` does not reach them; moving
  to the Trash ignores `CFFIXED_USER_HOME` and uses the real `~/.Trash`, and the `UserDefaults` of the test bundle
  identifier land in the real preferences (`defaults delete <bundle id>` afterwards).
- `RootView.swift` and `TranscriptTable.swift` are the collision points with M18, which is done. In `RootView`,
  `DraftSendTransition` moves the draft's card to the bottom at Send; #225 (landed) kept it and #230 (the landing place
  after a delete) may adapt it. In `TranscriptTable`, the quiet row selection (#269) and the row height (since #302 row stacks hold their
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
- #341 (finished turns fold into `Worked for …`) landed: `TranscriptState.finishedTurns` holds each turn that ended on
  its own with its time from event timestamps (none for a stopped, steered or failed turn); `TranscriptRow.turnFolds`
  finds each finished turn's work (after its prompts, up to the next prompt or other item) and keeps the answer (the
  last agent message) and answered questions outside; `TranscriptRow.fold` adds a `.turn(first:)` row with only the
  kept items after it while collapsed. `LiveTranscriptSource` keys expansion by turn and `reveal(item:)` expands a turn
  that hides the item; the row is `TranscriptMessageRow.showTurn` (a borderless button with a trailing chevron over a
  separator, no Copy). Stored data and the protocol are unchanged. Tested: the reduction (a turn of prompts sent
  together, Stop, steer, failure); the fold as pure functions (answer, questions, no answer, prompts together, running
  turns, expanded turns, `row(showing:)`); the source (label `Worked for 1m 3s`, expansion surviving a streamed and
  then finished next turn, stopped and failed turns unfolded); hosted `OffscreenWindow` tests of the table folding a
  turn in place with the answer's view kept, the chevron and its accessibility, Find expanding, Copy skipping the row,
  and every row's height after folding, expanding, resizing and collapsing (it fails without `rowContentHugging`).
  Rendering Lab **S11** (new): a 10,000-item history of finished turns, then a new turn with S7's tool updates, S10's
  thoughts and the S1 answer, which folds at the end (`foldsTurns`, `startTurn()`, `finishTurn()` in
  `AppTranscriptPrototype`; `scripts/bench.py` accepts `S11:App`). First benchmark run (2026-11-10, `just lab-run
  S1:App,S7:App,S9:App,S10:App,S11:App --runs 1`, three interleaved rounds, before = `f089e49` with S11 patched in,
  [results](benchmarks/2026-11-10/turn-fold/README.md)): S1, S7 and S10 within noise, **S11 regressed** (94–153
  hitches per run before, 176–227 after, apply p95 up 3–4 ms) and S9 drifted, because every update folded the whole
  history again and scanned it once more for the turns. Fixed: `TranscriptFolder` keeps everything before the last
  turn's first prompt and folds only the last turn per update; tests check it against a full fold after every item and
  that a chunk's folded items do not grow with the number of finished turns. **Do not merge before the second run**
  (S1, S9 and S11, with the owner's approval, recorded in the same README). **Running-app check deferred** (MockAgent `--demo`
  turns with tools and thoughts, isolated home, light and dark): (1) while a turn runs every row stays open; when it
  ends, its calls, groups, thoughts and permission records fold into `Worked for <time>` with a chevron and a hairline
  below the prompt, and the answer stays open below it, with no jump of the following-bottom position; (2) clicking the
  label or chevron expands and collapses it, its expansion holds while the next turn streams; (3) a turn stopped with
  Stop keeps its rows and the red divider, a steered turn keeps its rows and its hairline, `fail` keeps its rows and
  the error; (4) an answered question (`ask`) stays visible outside the folded turn; (5) Find on a word in a folded
  tool call expands the turn and selects the row; (6) ⌘C on the selected fold row and the answer pastes only the
  answer, and inner rows copy as before when expanded; (7) a reopened saved session shows its turns folded with their
  times; (8) VoiceOver reads `Worked for …` as a collapsed or expanded disclosure triangle; (9) the chevron and label
  are legible in light, dark and Increase Contrast.
- #340 (answered questions, interruptions and errors as T3 Code shows them) landed: `InputAnswer` pairs the
  composer's `InputStep.steps` with the stored response (question = description, else title, else name; a choice by
  its title; the step's text replaces the pick; multiple picks joined with `, `; `Declined`, `Cancelled`, `Recording
  answer…`) and replaces `InputCard`/`InputForm`; the answered form is a `.question` row (header only while collapsed,
  an attributed list while expanded). `TranscriptState` appends an `interruption` item when a turn with
  `stopRequested` finishes `cancelled` (the `interrupted` event no longer adds the `Interrupted` notice, and marks the
  turn `.steered` instead of `.stopped`): the red `Run interrupted · Stopped by user` divider after Stop, a plain
  hairline after steering, whose prompt (`Message.isSteer`) shows `↪ Steer` above its bubble; failures are `.failure` rows with a red `Error` label. Stored data and the protocol are
  unchanged. Tested: the answer summary as pure functions (pairing, custom text, multi-select, toggle, missing titles,
  declined, cancelled, recording), the reduction (Stop, a turn that ends anyway, close), the source's rows and Copy,
  the composer-to-row path against MockAgent's `ask`, hosted `OffscreenWindow` tests of the three rows in light and
  dark (labels, colors, accessibility elements and actions), and their heights after a resize and after expanding and
  collapsing the question row. **Running-app check deferred** (MockAgent, isolated home, light and dark): (1) `ask`,
  answer both steps with a typed note on step 1: the row reads the two questions in secondary text and `<note> ·
  <picks>` in primary text, truncating in a narrow window; the disclosure lists each question with its answer indented,
  ⌘C and the hover Copy return the same as text; Skip on a second `ask` reads `Declined`; (2) `slow`, then Stop (and
  ⌘.) during the turn: the red `Run interrupted · Stopped by user` divider with its X ends the turn; Send Now
  (⌘Return) while `slow` runs ends it with a plain hairline instead, and the new bubble has `↪ Steer` right-aligned
  above it (VoiceOver: `Steer, <text>`); (3) `fail`: the red alert symbol, bold red `Error` and the message below, wrapping; Details
  where the stored text says more; (4) VoiceOver reads the divider and the error as one element with their full text
  and offers Copy (and Details); (5) Increase Contrast.
- #223 (collapsed thoughts) landed: `TranscriptRow.thoughts(first:)` folds every run of thoughts into one row,
  `ThoughtSummary` words its header (`Thinking… <last line>`, `Thinking…` when expanded, `Thought for 12s`),
  `LiveTranscriptSource` builds it header-only when collapsed and with the run's Markdown, dimmed, when expanded (keyed
  by the run's first item), and `TranscriptState` records `thoughtStart`/`thoughtEnd` from event timestamps (the next
  item or the end of the turn closes a thought), so history shows the time. The table settles an expanded streaming
  row into a finished field when only its header changed. Tested: the times in Core (chunks, non-item updates, the next
  item, the turn's end, nothing after it); the fold and `row(showing:)`; the header words; hosted: one row for
  consecutive thoughts with the summed time live and in history, expansion surviving streamed chunks and a new
  thought, the finished field, Find expanding and marking, Copy once from the selection and the Copy action, and the
  row height on expand, collapse and resize. Rendering Lab **S10** streams two folding thoughts and the S1 answer on the
  200-item history (`didAppendThought()` in `AppTranscriptPrototype`, `scripts/bench.py` accepts `S10:App`).
  First benchmark run (2026-11-09, `just lab-run S1:App,S7:App,S9:App,S10:App --runs 1`, three interleaved rounds,
  [results](benchmarks/2026-11-09/collapsed-thoughts/README.md)): S1, S7 and S9 within noise, **S10 regressed** (7–14
  hitches per run before, 64–197 after, also at the lowest load) because the table rebuilt a collapsed thought's
  header and measured its row on every chunk. Fixed: a header whose text alone changes (`retitle`) keeps its views and
  height. **Do not merge before the second run**, S1 and S10 with the owner's approval, recorded in the same README. **Running-app
  check deferred** (`MockAgent`'s `think` verb or a `--demo` file with thought chunks, isolated home, light and dark):
  (1) a streaming thought reads `Thinking… <last line>` and its line changes as chunks arrive, truncated at the column
  edge; (2) when the answer starts it reads `Thought for Ns`, and two consecutive thoughts are one row with the summed
  time; (3) the disclosure expands the text dimmed below the header, the row keeps its expansion while thoughts
  stream, collapse restores the one-line height with no empty band, also after resizing the window; (4) hover Copy
  and ⌘C on the selected row paste the full text once; (5) Find (⌘F) on a word inside a collapsed thought expands,
  selects and marks it; (6) a reopened saved session shows `Thought for Ns`; (7) follow-bottom keeps the end in view
  while a collapsed thought streams; (8) VoiceOver reads the header and `Show all`/`Show less`.
- #326 (questions answered from the composer) landed: `InputStep.steps` groups a form into steps from the schema
  alone; `DockedInput` (`SessionWindowModel.dockedInput`) and `InputDock` dock the oldest pending form at the top of the
  composer card, and the composer's text is the step's text answer while `ComposerDraft` waits untouched. Return reads
  `Next`/`Answer` and never queues; `Back` (button only, from the second step) returns to the previous step with every
  step's answers kept in the draft; Escape and Skip decline; 1–9 and ↑ ↓ pick in an empty composer; ⌘Return and
  ⇧⌘Return do nothing; ⌘. stops. The transcript row of a waiting form reads `Asked 2 questions · answer below`;
  `InputForm` kept only the resolved record (replaced by #340's question row), and `InputField` only the toggle and the unsupported note. `MockAgent`'s
  `ask` sends a two-question form shaped like `claude-agent-acp` 0.101.0's AskUserQuestion (`question_<n>` choice,
  `question_<n>_custom` text) and echoes the response as JSON. Tested: the grouping, the docked form (progress, picks,
  text, validation, answer, decline, Back keeping both steps' answers), the key routing and the primary action as pure functions; the draft set aside
  and restored, the agent's answer and the oldest of two forms docking against MockAgent; a hosted test (dock shows,
  the composer types the answer, 2 then Return, 1, Back restores step 1's pick and text, a changed pick, Return twice
  and the agent gets the changed answer; fails without the dock; Back is called through its action, since the dock's
  SwiftUI buttons are no AppKit views a hosted test can click) and Return on a read-only
  composer. Stored data and the protocol are unchanged. **Running-app check deferred** (MockAgent `ask`, isolated home,
  light and dark): (1) with a draft and an attachment in the composer, `ask` docks `Library` with `1 of 2`, `Skip`, the
  question, two choices with descriptions and the transcript row `Asked 2 questions · answer below`; the chips and
  Attach are gone and the placeholder is the `Other` description; (2) 2 picks SwiftDate, typing a note keeps the pick,
  ↑ ↓ move the pick in an empty composer, the round button reads `Next` and Return shows `2 of 2` with checkboxes and
  an empty composer; 1 and 3 toggle; a click on `Back` (absent on step 1) shows the SwiftDate pick and the note again,
  and Return brings back step 2's checks; Return (`Answer`) sends; the agent echoes the JSON and the draft and its
  attachment come back; (3) Escape and Skip decline (`declined`), ⌘. stops and cancels; (4) a click on a choice and on
  Skip leaves focus in the composer; (5) the dock and the picked row's tint in light and dark, Increase Contrast;
  (6) VoiceOver reads `Question 1 of 2 Library: …`, `Back, previous question`, each choice with its description and selected state, and announces
  the second step.
- #227 (session board) landed: `WindowTarget.board`, `SessionWindowModel.showingBoard`/`showBoard()`, the sidebar's
  fixed Overview row (`overviewID`) and Session → Overview (⌘0); a window whose displayed session was deleted goes to
  the board (`leaveDeletedSession`), and the `Start a session` placeholder became the board. `SessionBoard` and
  `SessionCard` (a grid of one to three 280 pt columns, `columnCount(width:)`), `TranscriptState.agentLastLine` in Core,
  `SessionRowMenu` (the row's context menu, shared) and `SessionWindowModel.reason(of:)`. A card answers a request
  without a diff in place and offers Open first for one with a diff (`PermissionChoice.choices`, plain rule), armed
  after 400 ms. Tested: the last line in Core; the model (board, selection, New Session, restore, activation, delete)
  and the cards against MockAgent (content, shelf time, the Open-first rule, answering); the card by its measured
  size; a hosted test tabs through the key view loop and reaches every card (it fails without `.focusable()`). A
  notification tapped while the only window shows the board fills that window (it is not a draft).
  #335's case, a window that ended its session and then deleted it, lands on the board too.
  **Running-app check deferred** (MockAgent, isolated home, light and dark): (1) the Overview row sits above Needs You,
  stays during a search and is selected while the board shows; ⌘0 and Session → Overview show it from a session and
  from the draft; (2) `No agents running` with New Session on an empty board, and New Session opens the draft with the
  typed text; (3) two and more sessions: the grid wraps to one, two and three columns as the window widens, cards align
  at the top, the grid scrolls; (4) a card shows the badge, title, status symbol, `project · reason` (the plan step with
  `MockAgent --demo plan.json`), the agent's last line (a running tool's title, then the message) and the time
  (`Working 1m 12s` ticking each second, `Idle 20m`, `5m` for a Needs You card); (5) a command permission's card
  answers in place, an edit's card offers Open first and Open selects the session; the buttons stay disabled for
  400 ms after the request appears; a request answered in the window meanwhile leaves the card; (6) an input form's
  card reads `Question` and opens the session; (7) a click selects the session, the context menu matches the row's
  (Settle Session, Open in New Window, Discard Worktree…); (8) deleting the displayed saved session lands on the
  board, and a window quit on the board restores to it; (9) Tab reaches every card with keyboard navigation off
  and on (no card is a double stop with it on), its focus ring shows, Space and Return open the session; VoiceOver reads a card as one button with the row's label and the last line.
- #229 (sessions in the project folder) landed: the draft's Checkout chip is a menu for Git projects
  (`DraftCheckout`, `SessionWindowModel.draftInProjectFolder`, per draft: Send, another project and New Session in
  Project clear it, a failed start returns it); `SessionWorkspace.prepare(inProjectFolder:)` returns the repository
  root, the selected directory, `HEAD` and the checked-out branch, never fetching; `SessionManager.worksInProjectFolder`
  is the location test (a base revision, outside the worktrees root), no new column. Changes and Review compare with
  `baseRevision` (`SessionReview(inProjectFolder:)` drops the base branch) under `Changes since the session started`;
  Merge and Discard Worktree… are disabled with `This session works in the project folder`; Push and Open Pull
  Request… never show. Real-repository tests (temporary repositories only): the root, an untracked subdirectory, a
  detached `HEAD`, a dirty checkout with a commit after the start, no fetch against a local bare remote, the bare,
  broken and unborn checks; through `SessionManager`, discard, merge, the pull request target and delete refuse or
  skip the checkout (delete removes only the history; files, branches, worktrees and `HEAD` unchanged), a failed start
  leaves the folder, and scratch, non-Git and worktree sessions are never read as in the project folder. Hosted tests
  of the chip (light and dark) and the inspector. **Running-app check deferred** (`MockAgent`, isolated home, a
  throwaway repository `agh-project-folder-check` with a commit, light and dark): (1) the chip reads `New worktree from
  main` with a menu of both items, the checkmark and each item's tooltip, and a non-Git folder shows the plain
  `Project folder` label, a draft without a project none; (2) choose `Project folder`, Send: the start line reads
  `Starting MockAgent in the project folder…`, no `Fetching…` even with an upstream, no worktree in
  `~/.agenthesia/worktrees`, no new branch; (3) the inspector shows `In main, project folder` and the path, `Changes
  since the session started`, and after an edit in the checkout (and a commit made there) both files; (4) Merge in the
  inspector, the review footer and the Session menu, and Discard Worktree… in the inspector, the Session menu and the
  row's context menu are disabled, with the help text where macOS shows it; no Open Pull Request… with a fake `gh`;
  (5) Review's header reads `Changes since the session started`; (6) the next draft and New Session in Project start
  with the worktree again; (7) Delete Session… on the ended session leaves the checkout's files and branches as they
  were; (8) VoiceOver reads `Checkout: <item>`. Not checked: a detached `HEAD` in the running app.
- #225 (first message at once) landed: `LiveSession.startLine` (`Fetching origin/main…` from
  `SessionWorkspace.prepare(onFetch:)`, then `Starting <agent> in a new worktree…` / `… in the project folder…` / `… in
  a new folder…` from `startPlace`), `HeldPromptSource` (a one-item `TranscriptSource`) in `HeldTranscript`, and
  `SessionWindowModel.heldPrompt`, which also covers the gap between the controller and the submitted prompt and the
  sign-in panel. Tested: the held row and the session's own first row have equal markdown and equal frames in a hosted
  table (with and without an attachment), the model through start, sign-in and a failed start, a hosted `RootView`
  with a gated startup, and the fetch callback against a local bare remote. The draft's `DraftSendTransition` is
  unchanged: the card still moves to the bottom and fades while the starting column fades in (owner's choice: no
  morph of the text field into the bubble). The inspector is absent until the controller exists. **Running-app check
  deferred** (`MockAgent`, isolated home, light and dark, owner away from the machine): (1) a Git project with an
  upstream and a stalled fetch (an unreachable remote) shows `Fetching origin/main…`, then `Starting MockAgent in a new
  worktree…`; (2) a project outside Git shows `… in the project folder…`; (3) `or start without a project` shows `… in
  a new folder…`; (4) with attachments, the bubble and its attachment placeholders appear at once and stay put when
  the session's own transcript replaces them (compare screenshots before and after); (5) `MockAgent --auth` shows the
  sign-in panel under the message; (6) `Cancel Startup` and a missing executable return the draft; (7) Send's motion
  with and without Reduce Motion; (8) VoiceOver reads the line and the card. Not checked: the narrow window with the
  inspector open.
- #226 ⌘1…⌘9 (ADR-0046): Session → Switch to Session lists the first nine rows of Needs You and Working in the filtered
  sidebar (`SessionSidebar.numberedRows`, `SessionWindowModel.numberedSessions`); ⌘1…⌘9 were free (only ⌥⌘1…⌥⌘9 answer
  permissions). Tested in Core and on the window model; the menu items themselves have no hosted test. Running app
  (scripted, MockAgent, isolated home, dark): with two sessions the submenu listed both titles with ⌘1 and ⌘2 and seven
  disabled `No Session` items; ⌘1 and ⌘2 switched the window, also from the composer; a sidebar search for one title
  left only it under ⌘1, and clearing the search brought both back. Not checked: Settled rows (none were live), light
  mode, VoiceOver.
- #228 (menu bar item) landed: a `MenuBarExtra` scene (`App/`) with `SessionMenuBarLabel` (template symbol `sparkles`,
  the Needs You count while above zero) and `SessionMenuBarContent` (Needs You as `title · reason` with a permission
  submenu, Working as `title · plan step` or `Working 1m 12s`, New Session, Open Agenthesia while no window is open),
  `SessionMenu` (entries derived from `SessionSidebar`), `WindowPresence`, and `PermissionChoice` in Core, the pure
  Open-first rule #227 reuses. Tested: the Core rule, the entries against MockAgent (a permission request answered from
  an entry, the shelf time, the plan step, a failed start) and the two views by their measured size; a hosted view
  exposes no accessibility tree without an assistive client, so labels are not asserted. **Not checked in the running
  app (the owner was using the machine); the check must cover**, with MockAgent in light and dark: the item is in the
  menu bar, template-tinted in both appearances, and the count appears beside it with a permission pending and goes with
  the answer; the Needs You and Working items read as the sidebar rows do and the Working text ticks to a new time when
  the menu reopens; the submenu of a pending permission lists Open and the agent's options, an option answers without
  a window coming forward and Open selects the session; an item opens its session in the window that shows it, or in a
  new one with every window closed; Open Agenthesia appears after the last window closes and disappears once one opens
  (`WindowPresence` is driven by window notifications, so check minimizing too); New Session opens the draft; ⌘-drag
  removes the item; VoiceOver reads the label with and without a count. Also unverified: whether the label's HStack
  keeps the count visible in the status item.
- #233 (pull request with `gh`) landed: `SessionManager.pullRequestTarget`/`openPullRequest`/`push`, the
  `session.pullRequestOpened` event kind (its own kind, so older builds skip it), `PullRequestSheet` with its three
  steps, the inspector's `Pull request #12` link and Push, Merge hidden once a pull request is open, and Discard's
  confirmation naming the pushed branch. Tests with a local bare remote and a fake `gh` script: success, a failing
  `gh` (branch pushed, nothing recorded), a rejected push (`gh` never runs), replay, a live session staying live, and
  the window model. Running-app check deferred (the owner was using the machine); it must cover, in light and dark,
  with MockAgent, a throwaway repository whose `main` tracks a local bare remote and a fake `gh` first on the login
  shell's `PATH` (`auth status` exits 0, `pr create` prints a URL; a second variant fails it): the action absent
  without the fake `gh` and for a session without a project; the button in the inspector, the review footer and the
  Session menu; the sheet's layout, its steps while running and a failure with long output; the link opening the
  browser; Push appearing after an edit and disappearing after it; Merge hidden; the Discard confirmation's extra
  sentence; VoiceOver on the steps.
- #232 (push after merge) landed: `SessionWorkspace.pushRemote`/`push` (2-minute timeout, no prompts, never forces),
  the merge sheet's `Push <base> to <remote>` remembered in `UserDefaults`, `MergeError.notPushed` after the merge is
  recorded and the worktree removed. Tests with a local bare remote: pushed, rejected after the remote moved, no or a
  local upstream, a hanging `ext::` transport stopped by the timeout. Running-app check deferred with wave 1 (needs a
  test repository with a bare remote).
- #230 (delete) landed: migration `v8-session-deletion` keeps the append-only guard and lets `deleteSession` remove
  one session's events in its transaction; `SessionManager.delete` removes a worktree (ADR-0032's checks) or moves a
  scratch folder to the Trash (owner's choice) first and deletes nothing when that fails. Real-repository tests cover
  a worktree with commits and changes, a locked worktree that refuses removal, discarded and merged sessions, a
  session in the user's checkout, the scratch folder and planted paths outside the scratch root. Windows showing the
  session return to the draft. AGENTS.md now asks to delete test sessions. Running-app check deferred with wave 1.
- #222 (context usage) landed: `ContextUsage` (Core) gives the inspector's Agent rows `Context 84k of 200k · 42 %` and
  `Cost` (system currency format) and the composer's `ContextRing`, a fixed slot before Send options that takes no room
  below 70 %, orange from 90 %, the percentage rounded down so a threshold is never claimed early.
  `scripts/app-check/demos/usage.json` rises to 42 %, 75 % and 92 % with a cost. Running-app check deferred with
  #221's.
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

## Open research

Not scheduled, pick up when they block something: #98 (raw-notification contract), #91 (`posix_spawn` lifecycle), #94
(agent-created subagents), #104 (ACP v1 `terminal/*` provider), #111 (request-scoped elicitation before a session
exists). The transcript and highlighting hitches (#77, #78, #83) and streaming performance (#97) are in M19.
