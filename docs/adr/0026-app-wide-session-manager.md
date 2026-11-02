# 0026. App-wide session manager

- Status: Accepted
- Date: 2026-10-17
- Decider: Project owner
- Scope: M7 (#37–#40); supersedes the window-bound ownership of ADR-0014 and the live-session claim of
  ADR-0017

## Context

ADR-0014 binds one `LiveSession` to one window: starting another session ends the current one, and
closing the window ends the agent. It named an app-wide manager as the alternative to revisit with
parallel sessions. M7 needs several agents running at once, a sidebar with their statuses (#37),
notifications and a Dock badge for sessions that wait for the user (#38), keyboard navigation between
sessions (#39), and several windows restored after relaunch (#40). Each of these needs one view of
every live session, independent of any window.

## Decision

- **Ownership.** A `SessionManager` in Core, on the main actor and `@Observable`, owns every
  `LiveSession`. The app creates one instance and passes it to every window. Starting a session adds an
  owner; End Session removes it after cleanup. A session whose startup, process or controller failed
  stays with its error until it is ended or continued. There is no limit on the number of sessions.
- **Windows.** A window holds a selection (a live or saved session, or the launch form) and per-window
  view state: a read-only history controller, the file pane (`SessionFiles`), the composer draft and
  Quick Open. Several windows may show the same live session; each has its own file pane and draft,
  and they share the controller and transcript. Closing a window detaches it and never ends a session.
- **Continue.** `SessionManager` replaces the `SessionLibrary` live claim. Continue on a saved session
  that is already live selects the live session instead of failing; otherwise it adds a new owner as
  in ADR-0017.
- **Quit.** Closing the last window keeps the app and its agents running; the Dock icon and
  notifications lead back to them. Quitting asks for confirmation only when a session is working or
  needs input, naming how many. After confirmation, every owner shuts down as ADR-0014 describes, and
  the app terminates once cleanup finishes.
- **Status.** Core derives one status per live session, in priority order:
  - *needs input*: a pending permission request or elicitation form;
  - *failed*: the controller failed, or startup failed;
  - *working*: starting, running or stopping;
  - *done*: a turn ended since the session was last shown in a key window;
  - *idle*: otherwise.
  The *done* mark is in memory only; showing the session in a key window clears it. An ended session
  leaves the manager and appears as saved history.
- **Sidebar.** One section per project, ordered by its most recent session. Within a project, live
  sessions come first in start order with a status symbol and an accessibility label, then saved
  sessions newest first. The launch form chooses the project and agent as today.
- **Notifications and the Dock badge.** The Dock badge counts sessions that need input, so it is empty
  when nothing waits. A notification is posted only when the session is not shown in the key window
  of the active app: for a permission request, with an Allow once and a Reject action when the agent
  offered `allow_once` and `reject_once` options (other kinds open the session); for an elicitation
  form, a failure, or a finished turn, without actions. Activating a notification selects the session
  in a window. Notification permission is requested on the first session start, not at launch.
- **Keyboard.** A Session menu holds the session commands (New Session, End Session, Stop, Continue,
  Resume Queue) and navigation: previous and next session in sidebar order, and the next session that
  needs input. Existing shortcuts keep their meaning; new ones are chosen in the implementation and
  listed in ARCHITECTURE.md.
- **Restoration.** Windows use SwiftUI's value-based `WindowGroup`, keyed by the selected session's
  identifier, so macOS restores windows and their selections. Agents do not survive quitting: after
  relaunch, a restored selection shows the saved session read-only with Continue available, and no
  agent is started automatically. File pane state and drafts are not restored.

## Alternatives

- **Several live sessions per window.** Smaller change, but closing a window ends its agents, the
  badge and notifications must aggregate across windows, and one session cannot appear in two windows.
- **One window per session with native tabs.** Keeps ADR-0014 nearly unchanged, but there is no single
  sidebar with every agent's status, which is the point of #37.
- **Quit without confirmation.** Calmer, but one ⌘Q silently ends turns in progress.
- **Done as plain idle.** Simpler, but every idle session looks the same and nothing marks new results.
- **Continue agents after relaunch.** Restores more, but starts processes and spends tokens without
  the user asking.

## Consequences

ADR-0014's ownership, window-close shutdown and one-session-per-window rule no longer apply; its
process cleanup, startup cancellation and workspace preparation remain. The window registry used for
termination moves into `SessionManager`. `SessionWindowModel` shrinks to selection and view state, and
the `SessionLibrary` live claim is removed. Several agent processes may run at once; memory grows with
each live transcript, while rendering cost stays bounded by the displayed rows. Notification
permission, the Dock badge and the quit confirmation are new system integrations tested through
injected seams; the actual system prompts are checked by hand.

## Amendment (2026-11-02, proposed): Done means the result was on screen

- Status: Proposed (#195). Until the owner accepts it, the *done* mark above stands.
- Related: [0039](0039-t3-style-window-layout.md), [0007](0007-transcript-rendering.md)

### Context

"Showing the session in a key window clears it" is what the code does: `viewingUnseenResult` needs only an active
window, a displayed session and a finished turn (`RootView.swift:125-127,197-199`). Someone who scrolled up to read an
earlier message while the agent works loses the mark the moment the turn ends, with the result out of view: nothing
says that a response arrived below, and the sidebar row leaves Needs You. Table state already knows the difference:
`followingBottom` keeps the reader's intent and `followsBottom` measures it with a 24 pt tolerance
(`TranscriptTable.swift:27,81-83`). Both are private to the table, and nothing above it asks.

### Decision

**The mark clears when the result is on screen.** All of these must hold: the window appears active, the session is
displayed live (the existing conditions), and the end of the finished turn has been in the viewport. A key window
alone no longer counts. There is no dwell time.

**`New response below`.** A capsule at the bottom edge of the transcript, centered in the column, above the status
line. It shows while the reader is not following the end and the transcript's end changed since they left it: a new
last item, or more text in the last one. It is not shown merely for being scrolled up. A click or **⌥⌘↓** (Session →
Jump to Latest, disabled at the end) scrolls to the end and resumes following, without animation; that also satisfies
the rule above if a result was waiting. ⌘↓ is not used because the composer's text view needs it, and a menu shortcut
would take it from the composer. VoiceOver reads the capsule as a button; its appearance is not announced during
streaming, to stay calm (principle 7).

**Notifications stay quiet.** The rule for posting is unchanged: only when the session is not shown in the key window
of the active app. A reader scrolled up in that window gets the capsule and the sidebar reason, no banner. So a Done
mark can now exist with no notification, which is correct: the user is here, just not looking at that row. The Dock
badge still counts only sessions that need input.

### Viewport bookkeeping

- **Target.** When a turn completes, Core records the identity of the transcript's last item (an event-sequence `Int64`,
  as `Item.id`), not a row index: rows are renumbered whenever a group folds, expands or grows. The mark stays a count
  (`completedTurns` against `seenTurns`), and reaching the latest target marks every turn seen, as `markSeen` does now.
- **Geometry.** A pure function, in the manner of `followsBottom`: the target's row is on screen when its bottom edge
  is within the visible rect, with the same 24 pt tolerance. A message taller than the viewport therefore counts only
  once its end was reached; the top of a long answer is not the result yet.
- **Watching only when needed.** The view is told the target only while `hasUnseenResult` is true. With no target there
  is nothing to compute, so ordinary streaming pays nothing for this. Scrolling, an update and a layout each recheck,
  coalesced to one check per run-loop turn, and only a change is reported to SwiftUI.
- **Clip changes count as well.** The check also runs when the clip view changes size, because the docked permission
  card (ADR-0039) and the panes (ADR-0041) change the viewport without any scrolling.

**Follow-bottom.** A reader following the end is on screen by definition, so the common case clears the mark as soon
as the turn ends, as today. Nothing here changes when following stops or resumes, except the jump above.

**Folded groups.** If the target is inside a collapsed group (ADR-0039), the group's summary row is the result: seeing
"Edited 3 files" is enough, and nothing has to be expanded. The identity resolves to the summary, or to the item's own
row when the group is expanded. A group that grows while the reader is away counts as a change at the end. Expanding
a group above the viewport keeps the reader's origin, as now.

**Session switches.** `LiveTranscript` is rebuilt per session (`.id(session.session.id)`, `RootView.swift:243`) and starts
at the end, so selecting a finished session shows its result and clears its mark, as today. A scroll position per
session is not added.

### Alternatives

- **Keep the key-window rule.** No work at all, but the mark then means "the window was in front", and it clears at
  the moment it is most needed.
- **Row visible at all, by its top edge.** Clears sooner and needs less geometry, but it reports "seen" for a long
  answer of which one line showed.
- **A dwell time (visible for one second).** Closer to reading, but timers on the scroll path, and tests that wait,
  for a difference nobody asked for.
- **A notification while scrolled up.** More noticeable, and contrary to principle 7: the user is in this window.

### Consequences and risks

- `LiveSession.markSeen` gets a new caller, and the view and Core exchange a target, on the path that scrolling takes.
  It is performance-sensitive by location, though idle in the common case: Rendering Lab S1, S7 and S9 are rerun before
  and after, with the owner's approval.
- A session left scrolled up keeps its row in Needs You, with `Finished`, until the user looks. That is the point, but
  it may feel sticky; the jump is one key away.
- Reading the result in a second window clears the mark for all windows, because the owner is shared.
- Sending a prompt while scrolled up does not resume following, as today; the capsule then appears for the agent's
  answer.

### Not decided

Whether sending a prompt jumps to the end, a scroll position restored per session, marking a position in the
transcript (an "unread" line), and the keys of #194's find.
