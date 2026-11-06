# 0046. A session board, a menu bar item, and numbered sessions

- Status: Proposed (2026-11-07), for the owner's acceptance
- Date: 2026-11-07
- Decider: Project owner
- Related: [0026](0026-app-wide-session-manager.md), [0030](0030-notification-activation-and-identity.md),
  [0031](0031-app-icon-and-dock-tile.md), [0039](0039-t3-style-window-layout.md), [0040](0040-composer-first-session-start.md)

## Context

The vision is written for "several at once": run N agents in isolated worktrees, keep an eye on them, approve what
needs approval. The window gives that job to the sidebar alone. A row says who needs you and why (ADR-0039's
amendment), but reading what each agent is doing means selecting each session in turn, and answering a request means
opening it. Away from the window there is the Dock badge, a count, and notifications, which pass. T3 Code has no
overview either; this departs from the reference for the reason the vision gives (principle 5, every agent action is
visible), as the vision allows when the reason is recorded.

Three gaps, from largest to smallest:

- No place shows all live sessions with what they are doing.
- When the window is behind another app, nothing but the Dock badge says that an agent waits, and nothing answers it.
- Switching between a handful of sessions takes ⌥⌘[ and ⌥⌘] in order, or the mouse; ⌘1…⌘9 are free.

## Decision

### The board

**A row above the sections.** The sidebar gets a fixed first row, **Overview**, above Needs You, selected with **⌘0**
(Session → Overview). A window whose selection is nothing shows it; so does a window whose session was deleted
(ADR-0044). The draft of ADR-0040 is unchanged: a blank window still opens with the draft, and New Session still
opens it; the board is where a window lands when it is not looking at a session or writing a draft. The
`Start a session` placeholder goes.

**Cards.** One card per live session, Needs You first, then Working, in sidebar order, in a grid that wraps to the
detail column's width (at most three columns, 280 pt minimum each). A card shows:

- the project badge and the title;
- the status symbol and the reason of ADR-0039's amendment, or the current plan step while working (ADR-0039's
  transcript amendment);
- the last line of the agent: the first line of its last message, or the title of the running tool call;
- the last activity as relative time, and the elapsed time of a running turn.

A click selects the session in this window; **Open in New Window** is in the card's context menu, with the row's other
actions. The card is one accessibility element with the row's label, and a button.

**Answering from a card.** A card whose session has a pending permission request shows the request's operation line
(kind and paths or the command, as the docked card of ADR-0039 does) and the agent's options as a row of buttons in
the agent's order, without the diff and without shortcuts: with no session displayed, ⌥⌘1…⌥⌘9 answer nothing, and the
board is for deciding what to look at, not for approving edits unseen. A request with a diff therefore has **Open** as
its first button, the options after it; a request without one (a command, a fetch) can be answered in place. The
400 ms arming of the docked card applies, because cards move when a session changes section. `answerPermission` stays
the only way to answer, so a card and a window on the same request are safe. Input forms are not answered on the
board; their card says `Question` and opens the session.

**An empty board** says `No agents running` with a New Session button; saved sessions are not on the board, they are
in Settled.

### The menu bar item

A `MenuBarExtra`, always present (principle 6: the system lets the user remove it with ⌘-drag, and the app does not
add a switch). Its icon is a template symbol; a count follows it only while a session needs you, like the Dock badge
(ADR-0031). The menu:

- **Needs You**: one item per session, `title · reason`; an item with a pending permission has a submenu with the
  agent's options, under the same rule as the board (a request with a diff offers Open first), and the plain item
  opens the session;
- **Working**: one item per session, `title · step or elapsed`, which opens it;
- New Session, and Open Agenthesia when no window is open, since the app keeps running after its last window closes
  (ADR-0026).

Items open sessions the way notifications do: the `WindowTarget` URL of ADR-0030, so the window that shows the session
comes forward or one opens. The menu reads `SessionManager` and rebuilds when it changes; nothing is stored.

### Numbered sessions

**⌘1…⌘9** select the first nine rows of the visible sidebar, Needs You then Working, in the order on screen, including
a search filter. Settled is not numbered: its rows are not where the work is, and the footer opens and closes. The
rows do not show numbers; the Session menu lists them under **Switch to Session** with their titles, so the mapping can
be read. A number without a row does nothing.

## Alternatives

- **A separate Sessions window.** Room for a second monitor, but one more window to restore and keep consistent with
  the sidebar, and ⌘0 in a window already answers "show me everything".
- **The board replaces the draft as the blank window's content.** One rule, but it puts a step between opening the app
  and typing the first message, which ADR-0040 removed on purpose.
- **Cards without answers.** Simpler and safer; the owner chose answers for requests that do not need a diff, which
  is where the board saves a round trip.
- **Shortcuts on the board.** ⌥⌘1…⌥⌘9 for the first card's request would be fast, but the same keys mean "the
  displayed session's oldest request" everywhere else, and the first card changes under the hand.
- **A menu bar item behind a setting.** Common in menu bar apps, but a setting is a decision not made; the user who
  objects has the system's own removal.
- **⌘1…⌘9 for all visible rows including Settled.** Reaches history, but the numbers jump when the footer folds.

## Consequences and risks

- `WindowTarget` gains `.board`; restoration and `onOpenURL` keep working, since a URL selects a session.
- The board reads the same per-session values as the sidebar row and adds "the last line of the agent", which Core
  derives from the transcript (last assistant message or running tool title); the sidebar reason gains the plan step.
- `SystemAttention` grows a third sink beside notifications and the Dock tile; the menu's permission submenu reuses
  `answerPermission` and the operation line of the docked card. Hosted views cannot test a `MenuBarExtra`; its content
  view is tested as a view, and the item itself in the running app.
- Nine more menu items with shortcuts in the Session menu; their titles change with the sidebar, which SwiftUI commands
  handle through `FocusedValue` as the others do.
- Answering from a card means answering without reading the transcript. The rule above (a diff means Open first) is the
  safeguard; the owner accepts the rest.
