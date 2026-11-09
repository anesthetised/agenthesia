# 0044. Delete and archive sessions

- Status: Accepted (2026-11-07, #220)
- Date: 2026-11-07
- Decider: Project owner
- Supersedes: "manual settling is not adopted" in [0039](0039-t3-style-window-layout.md), for saved sessions only
- Related: [0005](0005-event-log.md), [0026](0026-app-wide-session-manager.md),
  [0032](0032-worktree-merge-and-discard.md), [0030](0030-notification-activation-and-identity.md)

## Context

History is append-only (ADR-0005) and nothing removes a session: not a start that failed before the agent spoke, not
a test run, not a question answered in one turn. AGENTS.md has to warn that "test sessions can never be deleted and
stay in the owner's sidebar". The Settled footer (ADR-0039) holds every saved session forever, at most 45 % of the
sidebar high, so after a few weeks the list is scrolled more than read, and search is the only way to a session that
is not recent. ADR-0039 declined T3 Code's pins, snoozing and manual settling as "settings-like state without a
demonstrated need"; the need is now demonstrated for saved sessions, in two forms: sessions that should not exist, and
sessions that should not be in the way.

## Decision

Two actions on **saved** sessions, both in the row's context menu and the Session menu. Live sessions have neither:
the menu items are disabled with the help text `End the session first`, so that an agent is never pulled out from under
its own record.

### Delete Session…

Removes the session for good: its record, its events, its prompt queue, and any other row that references it, in one
transaction with foreign-key cascade in `PersistenceStore.deleteSession`. The project row stays: it is the Project menu
of the draft.

- **Confirmation** is an alert that names the title and the state: `This session was merged`, `… was discarded`,
  `… still has a worktree with N uncommitted files and M commits` (the discard summary of ADR-0032), or `… failed to
  start`. Delete is the destructive button; there is no undo.
- **A worktree goes first.** If the session still has one, the deletion runs ADR-0032's removal before the database
  change, under the same checks: only Agenthesia's worktrees, only the session's own branch. If removal fails, nothing is
  deleted and the error is shown. A session that cannot be removed by those rules cannot be deleted either, so that a
  record never disappears while its files stay behind unexplained.
- **Windows.** Every window refreshes history as it does after a merge or discard. A window that displays the deleted
  session returns to the overview ([ADR-0046](0046-session-board-and-menu-bar.md)); its composer draft and view state
  are dropped. Its viewed marks (ADR-0041) go with the window state.
- **The log.** This is the one operation that removes events. ADR-0005 stands for a session that exists: its log is
  never edited, compacted or rewritten. Deleting the whole session is not an edit of history but the end of it, and it
  is the user's explicit act, confirmed.

### Archive Session

Hides a saved session from Settled without touching its log. A nullable `archivedAt` column (migration) records it.

- An archived session is **not in Settled** and not in Previous and Next Session. It appears in search results with
  `Archived` as its reason (ADR-0039's amendment), where **Unarchive** in the context menu brings it back.
- **Continue** on an archived session clears `archivedAt`: a session the user talks to again is not archived.
- Archive has no confirmation; it is reversible.
- The Settled header counts unarchived sessions. There is no Archived section and no "show archived" switch: search
  is the way in, which keeps the sidebar a list of what is current and the state at one bit.

### What stays

Needs You and Working are derived from live state and cannot be pinned, snoozed or settled by hand; that part of
ADR-0039 stands. Notifications and the Dock badge do not change: a saved session posts nothing.

## Alternatives

- **Delete only.** One mechanism and the smaller change, but a merged session is worth keeping and only in the way; the
  owner chose both.
- **Archive only.** Keeps append-only intact, but a failed start or a test session then stays in the database forever
  and in every search.
- **An Archived section in the sidebar.** Puts archived sessions one click away, but it is another list that grows
  without bound, which is the problem being solved.
- **Soft delete (a `deletedAt` flag).** Reversible and append-only in spirit, but nothing would ever be removed, the
  worktree question would be the same, and a hidden row with a worktree is worse than a visible one.
- **Delete live sessions too, ending them first.** Fewer steps, but it folds End Session's cleanup and a destructive
  database change into one click; the two-step form is clearer.

## Consequences and risks

- `PersistenceStore` gains `deleteSession` and `setArchived`; the schema gains foreign keys with cascade where they are
  missing, or the deletion names every table. Tests delete a session with events and a queue and check that nothing of
  it remains and that other sessions are untouched.
- `SessionSidebar` filters by `archivedAt`; `lastEvents()` and the sort are unchanged.
- `SessionManager.delete` composes the worktree removal of ADR-0032 and the store call; it needs the same real-repository
  tests as discard, including the case where removal fails.
- A window showing a deleted session needs a defined place to go; ADR-0046's overview is it. Until the overview lands,
  it shows the draft.
- Documentation: AGENTS.md's warning about test sessions becomes "delete test sessions before the pull request".

## Implementation notes (2026-11-09, #230)

- The schema keeps refusing to delete events. Migration `v8-session-deletion` adds a `session_deletion` table that
  `deleteSession` fills and empties inside its transaction; the delete guard lets only the events of a session listed
  there go, so any other deletion is still refused by the database.
- The folder of a session without a project ([ADR-0048](0048-sessions-without-a-project.md)) is moved to the Trash
  rather than deleted, by the owner's choice: the agent may have written files there that the user still wants. The
  confirmation says so. Worktrees are removed with Git as in ADR-0032.
- `failed to start` is a session that stored no event. Live rows have no Delete item in the context menu, as with
  Archive; the Session menu item is disabled with `End the session first`.
