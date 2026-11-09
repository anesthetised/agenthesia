# Board

The session board fills the detail column with one card per live session, so the user sees what every agent is doing
and answers a command's permission request without opening the session
([ADR-0046](../adr/0046-session-board-and-menu-bar.md)). It is the sidebar's Overview row, not a separate window.

## Showing the board

- **Overview**, the first row of the sidebar above Needs You (`square.grid.2x2`), and Session → `Overview` (⌘0) show
  the board in the current window. The row is selected while the board shows. Search does not hide it.
- A window whose displayed session was deleted ([ADR-0044](../adr/0044-delete-and-archive-sessions.md)) shows the board.
- A window that shows no session and is not starting one (for example after a session started from Continue failed)
  shows the board in place of the old `Start a session` placeholder.
- New and restored windows still show the draft ([session-start.md](session-start.md)); New Session (⇧⌘N, `+`) leaves
  the board for the draft with what was typed in it. A window that showed the board when the app quit shows it again
  after relaunch.
- The window title reads `Overview`, with no subtitle.
- Selecting a row in the sidebar, or Previous and Next Session (from the board, Next selects the first row), leaves the
  board.
- A notification tapped while the only window shows the board shows its session in that window, as a blank draft
  would.

## Cards

- One card per live session, Needs You first, then Working, in the sidebar's order; the sidebar's search does not
  filter the board. Saved sessions are not on the board; they are in Settled.
- The cards fill a grid that wraps to the column's width: as many columns of at least 280 pt as fit, one to three.
  Cards in a row align at the top; the grid scrolls when it is taller than the window.
- A card shows, top to bottom:
  - the project badge, the title (one line), the status symbol and the time, as on the session's row: `Working 1m
    12s` while a turn runs, counting seconds; `Idle 20m` for an idle session; otherwise the time of the last activity
    (`5m`), updated every minute (`SessionSidebar.shelfTime`);
  - `project · reason`, the row's second line, with the plan entry in progress as the reason while the agent works
    ([sidebar.md](sidebar.md#reasons));
  - the agent's last line, at most two lines: the title of the latest tool call that still runs, or the first line of
    the latest assistant message, whichever came last; nothing until the agent has said something.
- Clicking a card selects its session in this window. The card's context menu is the row's: `New Session in Project`,
  `Open in New Window`, `Settle Session`, `Discard Worktree…` ([sidebar.md](sidebar.md#row-actions)).
- The card's summary is one accessibility element, a button, labelled like the row (`title, project, reason, last
  active 3m`, or the shelf time) followed by the agent's last line. With keyboard navigation on, Tab reaches every
  card and its buttons; Space opens the session.
- An empty board reads `No agents running` with a `New Session` button, which opens the draft.

## Answering from a card

- A card whose session has a pending permission request shows the oldest request's operation line (its kind's symbol,
  the kind and the paths or the command, as on the docked card) and the agent's options as buttons in the agent's
  order, without the diff and without shortcuts.
- A request with a diff offers **Open** first (prominent), which selects the session to read the diff; a request
  without one (a command, a fetch) is answered in place (`PermissionChoice.choices`).
- The buttons are disabled for 400 ms after the request appears, as on the docked card, because cards move when a
  session changes section. An answer goes through `answerPermission`, so a card and a window on the same request are
  safe: a stale answer does nothing.
- An input form is not answered on the board: its card reads `Question` and opens the session.

## Changes

- 2026-11-09, #227: the board, the Overview row and ⌘0; a deleted session's window goes to the board.
