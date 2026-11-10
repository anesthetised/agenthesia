# 0050. Settled is the user's decision

- Status: Accepted (2026-11-10, #353)
- Date: 2026-11-10
- Decider: Project owner
- Supersedes: "Needs You and Working are derived from live state and cannot be … settled by hand" in
  [0044](0044-delete-and-archive-sessions.md), and what is left of "manual settling is not adopted" in
  [0039](0039-t3-style-window-layout.md)
- Related: [0005](0005-event-log.md), [0017](0017-continue-saved-sessions.md),
  [0026](0026-app-wide-session-manager.md), [0032](0032-worktree-merge-and-discard.md),
  [0046](0046-session-board-and-menu-bar.md); #352 (the list and the Working shelf, UI only)

## Context

The sidebar's Settled shelf holds every session that is not live (ADR-0039). A session stops being live when the user
ends it, and also when the app quits, the agent's process dies or its start fails. So "settled" says that a process
ended, not that the work did: after a relaunch every session of the day before is on a collapsed shelf, between merged
and abandoned ones, and the list above it is empty. Settled had 45 rows on the owner's machine on 2026-11-10; the one
session in progress was the only row outside it.

T3 Code, the UI reference, keeps a thread in its list until it is settled. A thread settles when the user says so,
after a number of days without activity (a setting), or when its pull request merges or closes; a pinned thread never
settles by itself (`apps/server/src/orchestration-v2/ThreadSettlementService.ts`,
`apps/web/src/components/Sidebar.logic.ts`, read 2026-11-10). Whether its agent is running decides only whether the row
is on the Working shelf.

#352 moves idle live sessions from the Working shelf into the list, without touching stored data. This ADR is the second
step: what Settled means.

## Decision

**Settled is a stored state of the session, set by the user or by two rules.** A nullable `settledAt` on the session
record says when. A session with `settledAt` is on the Settled shelf; one without it is in the list (or on the Working
shelf while a turn runs), whether or not its agent process is alive.

- **A live session is never settled.** Settling ends the process first; starting or continuing a session clears
  `settledAt`, as Continue already clears `archivedAt` (ADR-0044).
- **Settle Session**, on any row of the list or the Working shelf: ends the agent's process when the session is live,
  then sets `settledAt`. It replaces End Session everywhere (the Session menu, the toolbar, the row): one verb, since a
  session that ended and stayed in the list would be a third state with no use.
- **Unsettle Session**, on a Settled row: clears `settledAt` and appends a `sessionUnsettled` event to the session's
  log. It does not start the agent. Continue on a settled session does the same and then continues.
- **A session that is not live settles by itself** in two cases:
  1. its worktree was merged or discarded (ADR-0032): the work has an outcome;
  2. its last activity is seven days old. One period, no setting (principle 6).

  Last activity is the time of the log's last event, as the sidebar already shows it. Unsettle is an event, so the seven
  days count again from it and a session the user brought back is not settled at the next check.
- **When the rules run.** One pure function decides from the record, the outcome, liveness, the last activity and the
  clock. It runs at launch, when a session ends, after a merge or a discard, and when a window refreshes history. What
  it settles is written (`settledAt` is the time of the check), so every window and every later launch agree.
- **Migration.** Every session that exists when the column is added gets `settledAt`: the time of its last event, or
  its start without one. The sidebar looks the same after the update; the new meaning starts with the next session.
- **Archive and Delete** (ADR-0044) do not change. An archived session is in neither list; Unarchive returns it to
  where `settledAt` says. Both still need a session that is not live, and their help text on a live row becomes
  `Settle the session first`.

The sidebar's behavior (sections, order, row texts) is in [docs/behavior/sidebar.md](../behavior/sidebar.md), which the
pull request of #353 edits.

## Alternatives

- **Keep Settled as "not live"** and only regroup the live rows (#352 alone). No migration, but a relaunch still hides
  the work in progress, which is the complaint.
- **Settle by hand only.** The simplest rule, but the list then grows until it is cleaned up, and a merged session
  waits for a click that says nothing new.
- **A setting for the number of days**, as T3 Code has. A setting is a decision not made (principle 6); seven days is
  changed here if it proves wrong.
- **Derive "settled" at read time** from the last activity instead of writing `settledAt` for the rules. No write, but
  Unsettle then needs a second stored value to override the rule, two windows can disagree for a minute, and the
  Settled shelf's query has to read every session's last event.
- **A second column, `unsettledAt`,** instead of the `sessionUnsettled` event. T3 Code stores such timestamps, and its
  migrations include three that repair them. An event is the form this project already has for "the user did
  something to the session" (ADR-0005), and it makes the last activity move, which is the effect wanted.
- **End Session kept beside Settle**: End stops the agent and leaves the row in the list. Two verbs for neighbouring
  actions; the owner chose one.
- **Recent sessions returned to the list by the migration.** Consistent with the seven days, but the first launch
  after the update would fill the list with test sessions.
- **Pins and snoozing**, the rest of T3 Code's sidebar state. Still not adopted: no need is shown (ADR-0039).

## Consequences and risks

- **Data.** A migration adds `session.settledAt` and fills it; a new event kind, `sessionUnsettled`, that the reducer
  ignores and older builds skip. The migration gets a test on the previous schema file. `SessionController.createRemote`
  rebuilds the record field by field and has already lost `fallbackUpstream` that way; every copy must keep `settledAt`,
  with a test that starts a session and reads its row.
- **A second writer on a saved session's log.** Unsettle appends to the log of a session that is not live, through
  `SessionLibrary.record`, as a pull request's record does. A Continue started at the same moment can load the log
  before the append; the single log writer planned for M13 closes that window, and until then Unsettle is refused while
  a Continue of the same session is starting.
- **`SessionSidebar`** takes saved sessions into the list and splits them by `settledAt`; `SessionManager` gains settle
  and unsettle, and the rule's calls.
- **Rows in the list that are not live** look like idle live ones. The transcript says which with its Continue card
  (ADR-0017). If that proves confusing, the row gets a mark; no change is planned.
- **Seven days** settles a session the user meant to return to after a holiday. It is one Unsettle away, and Settled
  is searchable.
- **Delegated sessions** (ADR-0049) are settled and unsettled with their parent; the issue that puts trees in the
  sidebar decides the details.
- **AGENTS.md**: test sessions are settled or deleted before the pull request; the wording about End Session changes.
