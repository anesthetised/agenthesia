# 0026. App-wide session manager

- Status: Proposed
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
  owner; ending it (End Session, startup failure, process exit, controller failure) removes it after
  cleanup. There is no limit on the number of sessions.
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
