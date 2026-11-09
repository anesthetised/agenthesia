# Menu bar

The menu bar item is always there, even with no window open: it shows which sessions need the user and what the others
are doing, and answers a permission request without bringing the window forward
([ADR-0046](../adr/0046-session-board-and-menu-bar.md)). The user can remove it with ⌘-drag, as with any item of the
system; the app has no setting for it.

## The item

- The icon is a template symbol (`sparkles`), so the system tints it for the menu bar.
- A count follows the icon only while the Needs You section is not empty. It is the number of Needs You sessions (waiting
  for sign-in, a permission or a form, failed, or finished and unseen), the number the menu lists under Needs You.
- The accessibility label is `Agenthesia`, or `Agenthesia, 2 need you` with a count.

## The menu

- **Needs You** — one item per session, `title · reason`, where the reason is the sidebar's (`Allow? swift test`,
  `Question`, `Failed`, `Finished`, …). A session with a pending permission request has a submenu instead of a plain
  item: **Open** first, then the agent's options in the agent's order, for the oldest pending request. A plain item
  opens the session.
- **Working** — one item per session, `title · step`, where the step is the plan entry in progress, or else
  `title · Working 1m 12s`, the sidebar's shelf time, so the menu agrees with the sidebar. A starting session with
  neither shows its title only. An item opens the session. A section with no sessions is left out.
- **New Session** opens a window with the draft.
- **Open Agenthesia** opens a window with the draft and brings the app forward; it is shown only while no window is
  open, because the app keeps running after its last window closes.
- A session that has no record yet (starting) has a disabled item: there is nothing to open.

## Opening and answering

- An item opens its session the way a notification does ([ADR-0030](../adr/0030-notification-activation-and-identity.md)):
  `agenthesia://session/<id>`, so the window that shows the session comes forward or one opens.
- Choosing an option answers the request in place and does not open a window. Open comes first in the submenu even for
  a request without a diff, because the submenu replaces the item that would open the session; the [board](board.md) offers Open
  first only for a request with a diff (`PermissionChoice.choices`).
- A request answered elsewhere meanwhile is gone: a stale choice does nothing.

## Changes

- 2026-11-09, #228: the menu bar item, its menu and the count.
