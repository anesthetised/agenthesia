# Sidebar

The left column of every window lists the sessions by what they ask of the user: *Needs You* scrolls under a search
field, and *Working* and *Settled* are shelves pinned to the bottom edge, Working above Settled. Selecting a row shows
that session in the window; the draft (new session) has no selected row. The search text and the selection belong to
the window.

## Sections

- **Needs You** — live sessions whose status is *needs input* (waits for sign-in, a permission or an input form),
  *failed* (startup or the connection failed), or *done* (a turn finished and its end has not been on screen yet,
  [ADR-0026's amendment](../adr/0026-app-wide-session-manager.md)). In start order.
- **Working** — every other live session: starting (also before it has a project), running, stopping, or idle. In
  start order, on the Working shelf.
- **Settled** — saved sessions that are not live and not archived, by last activity, newest first.
- Empty sections are hidden. The scrolling list holds Needs You alone; without Needs You rows it reads `Nothing needs
  you` in secondary text, centered. A session moves between sections as its status changes; ending a session moves it
  to Settled, Continue moves it back up. `Prompt failed` and `Queue paused` do not put a row in Needs You.
- A *done* row leaves Needs You once the end of the finished turn has been on screen in an active window (scrolled up
  away from the end, it stays).

*Why start order:* Needs You and Working do not re-sort by activity, so rows do not jump while the user aims at them.
Settled sorts by last activity because a list whose visible times are out of order reads as a bug.

## Shelves

Working and Settled are footers pinned to the bottom edge, Working above Settled (`SidebarShelves`).

- Each has a header row, always visible while its section has rows: a chevron, `Working` or `Settled`, and the row
  count on the trailing edge. VoiceOver reads it as a button, `Settled, 3 sessions, collapsed` (`expanded` when open).
- Working is expanded by default, Settled collapsed; clicking a header toggles its shelf. Each window remembers both
  states, also across relaunch.
- Expanded, a shelf grows upward with its own list, sized to its rows; beyond its cap it scrolls. Working takes at most
  35 % of the sidebar's height, Settled at most 45 %, less on a short window so that the headers and about two rows of
  the list above keep their room.
- The chevron collapses a shelf whenever asked, also while one of its rows is selected: the selection and the session
  in the detail column stay, the row just is not on screen. Previous and Next Session expand a collapsed shelf when
  they move the selection into one of its rows. A search opens both shelves while a query is entered; the header cannot
  collapse a shelf then.
- Expanding and collapsing a shelf animates: a light spring of about 0.25 s on the height of its list and the
  chevron's rotation. Under Reduce Motion the shelf changes at once.
- History refreshes on its own; there is no Refresh button.

*Why a Working shelf:* Working held idle sessions with nothing on the row to tell them apart from running ones; the
shelf's rows say which, and for how long (after T3 Code's shelf).

## Rows

Each row is one line of title over one line of detail, with the status and time on the trailing edge
(`SessionRow`):

- **Project badge** — the project's initials on a tinted rounded square: the first letters of the first two words of
  the name (words split on space, `-`, `_`, `.`), or the first two letters of a single word, uppercased. The tint is
  one of eight colors chosen by a stable hash of the name, the same in every launch. A row without a project shows an
  empty grey square.
- **Title** — the session title (the agent's title, else the first line of the first prompt), or `New Session`
  without one. One line, cut at its tail.
- **Second line** — `project · reason`; the project alone without a reason, the reason alone without a project. It
  never wraps: when it does not fit, the project shrinks first, down to 40 % of the line, then the reason is cut at its
  tail.
- **Status symbol** (live rows only): a small spinner for working, an orange `exclamationmark.bubble.fill` for needs
  input, a red `exclamationmark.triangle.fill` for failed, a blue dot for done, nothing for idle. Saved rows have none.
- **Time** of the last activity: `now`, `5m`, `3h`, `2d`, `3w`, then a short date such as `12 Oct` from four weeks on.
  It updates every minute. Last activity is the minute of the session's last logged event, or its start without one;
  a starting session with no record yet shows no time.
- **On the Working shelf**, the state and its time instead: `Working 1m 12s` while a turn runs (stopping included),
  counted from the turn's start, `Working 45s` below a minute and `Working 1h 2m` from an hour, updated every second
  while the row is on screen; `Idle 20m` otherwise, since the last activity in the format above (`Idle now` within a
  minute). A starting session shows no time: its spinner and `Starting` say it.
- The tooltip holds the full title and second line. The accessibility label is `title, project, reason, last active
  3m`; without a reason it names the status instead (`Working`, `Done`, …; nothing for idle or saved). On the Working
  shelf it ends with the shelf time instead, which names the state: `title, project, Working 1m 12s`.

### Reasons

The reason follows the status, so it never contradicts the symbol (`SidebarReason`):

| Session | Reason |
|---|---|
| Waits for sign-in | `Sign in` |
| Pending permission | `Allow? <tool title>`, `Allow? <tool title> +2` with two more; `Permission` without a title |
| Pending input form, no permission | `Question` |
| Failed | `Failed` |
| Starting / stopping | `Starting` / `Stopping` |
| Running | none |
| Done, turn ended with `refusal` | `Refused` |
| Done, turn ended with `max_tokens` or `max_turn_requests` | `Hit a limit` |
| Done, any other end | `Finished` |
| Idle while merging | `Merging` |
| Idle after the agent rejected the last prompt | `Prompt failed` |
| Idle with a paused, nonempty queue | `Queue paused` |
| Live, none of the above, worktree merged or discarded | `Merged` / `Discarded` |
| Saved and archived (shown only by a search) | `Archived` |
| Saved, worktree merged or discarded ([ADR-0032](../adr/0032-worktree-merge-and-discard.md)) | `Merged` / `Discarded` |
| Otherwise | none |

`Allow?` names the oldest pending request, the one the permission shortcuts answer. Its tool title is agent-authored:
it is reduced to its first non-empty line, whitespace collapsed, at most 120 characters with `…`. A request that names
its call only by id takes the title the agent reported for that call.

## Search

- A native search field at the top of the sidebar, prompt `Search`; ⌥⌘F (Session → `Search Sessions`) focuses it. The
  text is per window and not kept across relaunch.
- A row matches when its title or project name contains the trimmed text, ignoring case and diacritics. An untitled
  session matches as `New Session`. A blank query filters nothing.
- Empty sections are hidden; with no match at all the list shows the system's *No Results* view for the query.
- Both shelves open while a query is entered, and their headers count the matches.
- Archived sessions appear only in search results, in Settled order with the reason `Archived`
  ([ADR-0044](../adr/0044-delete-and-archive-sessions.md)).
- Navigation and ⌘1…⌘9 use the filtered rows, so they only visit what is on screen.

## Navigation

All in the Session menu, acting on the focused window:

- `Previous Session` ⌥⌘[ and `Next Session` ⌥⌘] step through the visible rows in order — Needs You, Working,
  Settled — and wrap. Archived rows are skipped even when a search shows them. From the draft, or when the selected row
  is not visible, Next selects the first row and Previous the last. Disabled when there is no row.
- `Next Session Needing Input` ⇧⌥⌘] goes to the next live row whose status is *needs input* (sign-in, permission or
  form), in the same order with wrap; failed and done rows in Needs You are skipped. Disabled when none waits.
- `Switch to Session` lists nine items, ⌘1…⌘9, for the first nine rows of Needs You then Working, in the order on
  screen and after the search filter. Each item shows its row's title; a number without a row reads `No Session` and
  is disabled. Settled is not numbered, and rows do not show their numbers.

*Why Settled is not numbered:* it is collapsed by default and holds finished work; the numbers go to the sessions in
progress ([ADR-0046](../adr/0046-session-board-and-menu-bar.md)).

## Row actions

Right-click on a row:

| Item | Live row | Saved row |
|---|---|---|
| `New Session in Project` | yes | yes |
| `Open in New Window` | yes | yes |
| `Settle Session` | yes | — |
| `Archive Session` / `Unarchive Session` | — | yes |
| `Discard Worktree…` | yes | yes |

- `New Session in Project` opens the draft with the row's project selected; the typed message and the agent stay.
  Absent while the row has no project.
- `Open in New Window` shows the session in its own window, or brings forward the window that already shows it.
  Absent for a starting session that has no identity yet.
- `Settle Session` is End Session for the row's own session, whichever session the window shows: the agent stops, the
  session is saved and moves to Settled, and Continue brings it back. Enabled for an idle, done or failed session;
  disabled while a turn runs (starting, running, stopping) or a permission or form waits. On hover a live row shows a
  small borderless `✓ Settle` button in place of its time (the shelf time on Working), faded in over 0.12 s (at once
  under Reduce Motion); the same action is an accessibility action of the row. End Session in the Session menu keeps
  its own rules.
- `Archive Session` hides a saved session from Settled (and its count) without touching its log; `Unarchive Session`
  (the title when it is archived) brings it back. Neither asks for confirmation. Live rows have no such item: a session
  is ended before it can be archived. Continue on an archived session unarchives it. Storage and the reasons are in
  [ADR-0044](../adr/0044-delete-and-archive-sessions.md). A failed write shows `Cannot Archive the Session` /
  `Cannot Unarchive the Session`.
- `Discard Worktree…` is enabled when the session has a worktree Agenthesia created and no outcome yet (or a merge left
  its worktree behind), and it is not starting, merging or being discarded. It asks first: `Discard the worktree of
  “<title>”?` with what will be lost (`2 uncommitted files and 1 commit on <branch> will be deleted. This cannot be
  undone.`), and `Discard` / `Cancel`. A live session is ended before its worktree is removed; the row then reads
  `Discarded` ([ADR-0032](../adr/0032-worktree-merge-and-discard.md)).

The Session menu has the same `Archive Session` / `Unarchive Session` and `Discard Worktree…` for the displayed session,
without shortcuts. Archive is disabled unless the displayed session is saved; for a live one its help text is `End the
session first`. Each change refreshes the window's history; other windows pick it up at their next refresh.

## Planned (M18)

Accepted by the owner on 2026-11-08 (first-use feedback); not implemented yet. The pull request that implements an item
moves it into the text above and deletes it here.

- **Sessions without a project** ([ADR-0048](../adr/0048-sessions-without-a-project.md)) show a dashed square instead
  of initials and `No project` as the project name.

## Changes

- 2026-11-08, #275: a live row settles (ends) from a hover button and `Settle Session` in its context menu.
- 2026-11-08, #274: shelves collapse whenever asked, also with a selected row; Previous and Next Session expand the
  shelf they move into; expanding and collapsing animate (none under Reduce Motion).
- 2026-11-08, #268: Working moved from the scrolling list to a shelf above Settled; its rows show `Working 1m 12s` or
  `Idle 20m`; the list reads `Nothing needs you` without Needs You rows.
- 2026-11-08, M18: planned changes added from the owner's first-use feedback.
- 2026-11-08, #261: summarised from ADR-0026 (the Done-mark amendment), ADR-0039 (the Sidebar decision and its
  2026-10-30 and 2026-11-02 amendments), ADR-0044 (Archive) and ADR-0046 (⌘1…⌘9), checked against main at c65b8a1.
