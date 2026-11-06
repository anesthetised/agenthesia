# 0039. A window layout after T3 Code

- Status: Accepted
- Date: 2026-10-29
- Decider: Project owner
- Supersedes: the Sidebar decision of [0026](0026-app-wide-session-manager.md)
- Related: [0040](0040-composer-first-session-start.md)

## Context

The vision makes T3 Code the reference for UI and UX. A review of the running app against T3 Code
(2026-10-29) found the window below that bar:

- The sidebar has one section per project. Every row repeats its project in the title (`MockAgent ·
  agh-attn-check`) and shows a full date. With a few dozen sessions the list does not fit, nothing can be
  collapsed, and live sessions are mixed with history. Refresh History is redundant because history already
  refreshes on every change.
- Transcript rows span the whole window width. Every row carries a role label (You, Agent, Session) and a
  permanent Copy button. Session notices look like messages. Prompt errors show the raw
  `RPCError(code:message:data:)` description.
- The composer is a flat bar with labelled menus (`Mode: Ask`), a status line, and a path bar with Show in
  Finder under it. Changed files live at the bottom of the sidebar, away from the session they belong to.

T3 Code (`apps/web`, read 2026-10-29) answers these with: a sidebar grouped by status (Working, Settled)
with a project badge and relative time on each row and search on top; a centered chat column
(`--chat-content-max-width: 46rem`) in which user messages are right-aligned bubbles, assistant text has
no label, Copy appears on hover, and consecutive tool calls fold into one summary row ("Ran 6 commands
and read 1 file"); a floating composer card whose bottom row holds pill menus for model, effort and access
and a round Send/Stop button; and a details panel on the right with the checkout, Open in editor, the
branch and the changes with line counts.

## Decision

Agenthesia adopts that layout with native controls. Departures from T3 Code are listed with their reason.

**Window.** `NavigationSplitView` (sidebar | transcript and composer) plus an inspector pane on the
right (see the amendment below). The window title is the session title and the subtitle is its project (`navigationSubtitle`), the
native form of T3 Code's `project / thread` breadcrumb (principle 3). Refresh History is removed. The path
bar under the composer is removed; its content moves to the inspector.

**Session titles.** A session's title is, in order: the agent's title (`session_info_update`), the first
line of the first accepted prompt (at most 80 characters, cut at a word boundary with an ellipsis), or
"New Session". The chosen title is stored in the session's metadata row so the sidebar shows it without
replaying history. Sessions created earlier keep their stored titles.

**Sidebar.** Search filters rows by title and project. Three sections, in this order:

- *Needs You*: live sessions that wait for a permission or input, that failed, or whose finished turn has
  not been seen (the *done* mark of ADR-0026).
- *Working*: other live sessions, including starting ones, in start order.
- *Settled*: saved sessions, newest first, collapsed by default, with their count in the header.

Empty sections are hidden. A row shows a project badge (the project's initials on a tinted rounded square;
the tint is derived from the project name so it is stable), the title, a second line with the project
name and, for merged or discarded sessions, the outcome, and on the trailing edge the status symbol and
a relative time ("3m", "5d"). Previous and Next Session follow this order. T3 Code's pins, snoozing and
manual settling are not adopted: they are settings-like state without a demonstrated need (principle 6).

**Transcript.** Content sits in a centered column at most 720 pt wide (46 rem). User messages are
right-aligned bubbles at most 80 % of the column wide. Agent messages have no role label; thoughts stay
secondary text. Copy appears while the pointer is over a row and remains an accessibility action. Session
notices (continued, ended, merged) are centered captions between hairlines. A prompt error shows the
agent's message; the full error is behind a Details disclosure. While a turn runs, a "Working for 1m 12s"
line follows the last row. Consecutive tool calls between two messages fold into one summary row
("Ran 3 commands, edited 2 files") that expands to the existing tool cards. Pending permission requests
and input forms are never folded, so a request for a decision is always visible (principle 7).

**Composer.** A floating card with rounded corners in the transcript column, above its bottom edge.
Attachments and the queue sit above the text; the bottom row holds the session config controls as
borderless pill menus that show the value only (the option name moves to the tooltip), the attach button,
and a round Send button that becomes Stop while a turn runs and the draft is empty. The Send options menu
stays beside it. The status line is removed: running is shown by the transcript, a pending permission
shows its shortcuts on its card, and a paused queue says so in the queue header. A read-only, ended or
failed session shows a compact card with its state and Continue instead of a disabled editor.

**Inspector.** Toggled from the toolbar and with ⌥⌘I; its visibility is remembered per window. Sections:
*Workspace* (path, Show in Finder, Open in Editor), *Branch* (session branch and base branch), *Changes*
(file count, added and removed lines, the changed-file list that opens the file pane, and Review
Changes… and Merge…), and *Agent* (agent name and the Agent Log). Changed Files leaves the sidebar.

**Visual language.** System fonts, materials, colors and SF Symbols. Custom chrome is limited to the
composer card, the user bubble and the project badge, each of which T3 Code shows to be clearer than a
plain list cell or bar.

## Amendment (2026-10-30)

The inspector is the rightmost pane of the detail column's `HSplitView`, beside the transcript and the file
pane, not a native `.inspector`. Scripted checks of the running app found that the native `.inspector` combined
with that `HSplitView` crashed the app: starting the first live session at 1000 pt, opening or closing the file
pane, showing the inspector while the file pane was open, and resizing the window all ended in `EXC_BREAKPOINT`
in `-[NSWindow _postWindowNeedsUpdateConstraints]` with "The window has been marked as needing another Update
Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views
in the window." The file pane already opened and closed reliably as a pane of the `HSplitView`, so the inspector
uses the same mechanism. Visibility, the toolbar button, ⌥⌘I, the per-window memory, the 220–360 pt width and the
sections are unchanged.

Amendment 2, same day: a re-check of the running app found no crashes but three layout faults of that
`HSplitView`: its split view did not shrink the transcript when a pane appeared (the inspector overflowed the
right edge), kept the old divider sizes when the window shrank (the file pane overflowed) and stopped 19–40 pt short
of the window's edge at 740 pt. The detail column therefore lays its panes out itself: explicit widths from
`DetailPanes` (a pure function of the measured column width and the widths the user chose), with a drag handle
(`PaneDivider`) on the leading edge of the file pane and of the inspector. The transcript gives way first, then
the file pane shrinks to its minimum, then the inspector; the widths always add up to the column.

Rule for narrow windows: the transcript always keeps at least 240 pt. The file pane the user opened needs another
240 pt and the inspector 220 pt on top of the panes shown, so the inspector gives way first, then the file pane.
At the 740 pt window minimum the inspector is therefore hidden while a file is open. A hidden pane keeps its state
and returns when the window widens; it is not closed or toggled. The rule is `DetailPanes`, a pure function of
the detail column's width.

## Alternatives

- **Sidebar grouped by project, with an Active section on top.** Keeps projects visible, but a dozen
  projects with a few sessions each still do not fit, and the question the sidebar answers is "which agent
  needs me", not "which project is this".
- **Labels kept in the transcript, no bubbles.** Reads as a document, but the eye has to read labels to
  find turns; bubbles show them at a glance.
- **Toolbar menus instead of an inspector.** Fewer surfaces, but changed files, review and merge stay
  split between the sidebar and the toolbar.

## Consequences

- `SessionSidebar` is rebuilt around status sections; its tests and the navigation order change with it.
- Persistence gains a title update for sessions.
- Transcript rows change look; tool folding changes the row model of `TranscriptTable` and needs the
  streaming benchmarks to be rerun.
- Workspace gains line counts for changed files.
- Previous screenshots and documentation of the sidebar and composer become outdated and are updated by
  the issues that change them.

## Amendment (2026-10-30)

The owner chose to pin *Settled* to the bottom of the window, as T3 Code does, instead of letting it flow
after *Working* inside one list. *Needs You* and *Working* stay in the scrolling list on top. *Settled* is
a footer of the sidebar: a header row (`Settled · N`, a disclosure chevron) that is always visible while
there are saved sessions and hidden otherwise. Collapsed by default, it shows only the header; expanded, it
grows upward with a list of its own, at most 45 % of the sidebar's height. It still opens while one of its
rows is selected, and Previous and Next Session keep the order Needs You, Working, Settled. The search
field of #148 will sit above the list.

## Amendment (2026-11-02): the sidebar row says why

- Status: Accepted by the owner on 2026-11-06 (#195); implemented in #203.

### Context

Two UI/UX reviews after M15 read the row the same way: it tells that a session needs the user, not what for.
`SessionRow.subtitle` (`SessionRow.swift:45`) is the project plus a merge or discard outcome, and a symbol is the
only status (`155-permission-request-dark.png`: an orange badge). So the user opens each row in Needs You to learn
whether it asks for a permission, failed or simply finished. The trailing time is the session's age
(`started: session?.createdAt`, `SessionSidebarRows.swift:27`): a session started last week that finished a minute
ago reads `1w`. Settled sorts by the same date (`SessionSidebar.swift:92`).

### Decision

The second line is `project · reason`, and the time is the last activity.

The reason follows the priority of `LiveSession.Activity` (ADR-0026), so that it never contradicts the status
symbol. It is derived in Core by a pure function:

| State | Reason |
|---|---|
| Waits for sign-in | `Sign in` |
| Pending permission | `Allow? <tool title>`; `Allow? <tool title> +2` with two more pending; `Permission` without a title |
| Pending input form | `Question` |
| Connection or startup failed | `Failed` |
| Starting, stopping, merging | `Starting`, `Stopping`, `Merging` |
| Running | none: the symbol and the section say it |
| Done, turn ended with `end_turn` | `Finished` |
| Done, turn ended with `refusal` | `Refused` |
| Done, turn ended with `max_tokens` or `max_turn_requests` | `Hit a limit` |
| Idle after a rejected prompt | `Prompt failed` |
| Idle with a paused, nonempty queue | `Queue paused` |
| Idle otherwise | none |
| Saved, merged or discarded | `Merged`, `Discarded`, as today |
| Saved otherwise | none |

Without a reason the line is the project alone, and without a project the reason alone. `Prompt failed` and `Queue
paused` do not move the row: a rejected prompt stays out of Needs You, as ARCHITECTURE.md describes. A pending
permission names the oldest request, the one the shortcuts answer.

**Long reasons.** One line, never wrapped, so that rows keep one height. The reason is what the user came for, so
it gets the room: the project truncates first, down to about 40 % of the line, then the reason truncates at its
tail. The title is agent-authored text and can hold anything, so it is reduced to its first line with whitespace
collapsed and capped at 120 characters before display. The full text is in the tooltip and the accessibility label
(`title, project, reason, last active 3m`). The row is a summary: the permission card shows the kind and the paths
in full, as the ACP specification asks of a client that describes an operation.

**Last activity.** The timestamp of the session's last event in the log (ADR-0005), or its `createdAt` without
one. Saved sessions read it from `PersistenceStore.lastEvents()` (`PersistenceStore.swift:181`), the one-lookup-per-session query
that already supplies worktree outcomes, so nothing is migrated and no query is added. A live session keeps it in
`SessionController`, assigned only when the minute changes: `record` runs for every streamed batch, and the row has
no use for finer resolution. Settled sorts by it, because a list whose visible times are out of order reads as a
bug; Needs You and Working keep start order, so rows do not jump while the user aims at them.

### Alternatives

- **Text only in Needs You.** Less text, but Working and Settled would have no room for `Stopping` or `Merged`, and
  the line would change meaning between sections.
- **The reason as a third line.** Nothing truncates, but the list holds a third fewer rows, against the reason this
  sidebar exists.
- **A new `lastActivity` column.** No need to read the log, but another value to keep consistent with an append-only
  log that already holds the answer.
- **Keep the age.** Stable and simple, but it answers a question nobody asks of this list.

### Consequences and risks

- `PendingPermission` carries the tool title already; the reducer gains the last turn's stop reason.
- A Continue, or any event written while closing, counts as activity and moves a session up in Settled. That is
  accepted: it did happen.
- A tool title is agent-authored and now appears outside the transcript, next to the user's own titles. It stays
  plain text and secondary, and `Allow?` stays in front of it, so a title cannot impersonate another state.
- Wording is English only, like the rest of the app.

### Not decided

Whether the Dock badge or notifications reuse the reason text, a per-tool-call count in the reason, and the color
of "needs you" (#190).

## Amendment (2026-11-02): the inspector leads with the work

- Status: Accepted by the owner on 2026-11-06 (#195); not yet implemented. Until it lands, the inspector text above describes the code.
- Supersedes: "generated branch names are not adopted" in
  [0032](0032-worktree-merge-and-discard.md), and the matching removal check described there.

### Context

The inspector's job in this window is to get the user from a finished turn to a reviewed merge, yet that comes last.
`155-permission-request-dark.png` shows the order: Workspace and Branch fill the first half, with `Branch` repeated
as section and row and the branch wrapped over three lines; Changes starts below them and, with a long file list, its
actions scroll out of view because they follow the list (`SessionInspector.swift:72-98`). Merge is enabled with no
changes (`canMerge`, `SessionWindowModel.swift:185`) and the merge then has nothing to commit. Discard has the same
weight as Merge. Refresh Files is always shown although the file watcher refreshes the list.

**What is stored for the branch.** Nothing. `SessionRecord` stores `baseBranch` but no session branch
(`Records.swift`). `prepare` creates `agenthesia/<lowercased session id>` (`SessionWorkspace.swift:54,70`), removal
derives the same name (`SessionWorkspace+Removal.swift:22,33`), and so does the inspector
(`SessionInspector.swift:44`). ADR-0006 specified a slug; ADR-0032 then wrote down that the session id is the slug.
So the display is correct, and a readable name needs a real decision: the name users see in `git branch` is the
UUID. #191 lists this item and the repeated labels; this amendment takes them over.

### Decision

**Order.** *Changes*, then a compact *Workspace* block, then *Agent*.

**Changes.** A summary (`+12 −3 · 4 files`), then **Review** and **Merge into `<base>`…**, then the file list, so
that the actions stay in view. Review is the prominent one while there are changes.

- Merge is disabled, with the help text `No changes to merge`, when the file list is known to be empty. While the
  list is loading or failed to load, the check stays with the merge sheet, as today. The Session menu and the review
  pane follow the same state. This is a pre-check for the common case: the sheet's checks remain the authority.
- Refresh Files is shown only with `files.watchError`, beside its message. Its other copy in review follows.

**Workspace.** One block replaces the sections Workspace and Branch: the branch and its base (`from main`) and the
path. Values have no repeated label, wrap instead of truncating, and are selectable, so the full value is always
visible and can be copied. Show in Finder and Open in Editor become icon buttons with tooltips and accessibility
labels in the block's header. **Discard Worktree…** sits at the end of the block as a plain borderless button: it
concerns the worktree, keeps its confirmation (ADR-0032), and is no longer beside the action that is usually meant.

**A readable branch name.** New sessions name the real branch, and the name is stored:

- `agenthesia/<words>-<first 8 hex digits of the session id>`, for example `agenthesia/fix-note-parser-baaeedd5`.
- `<words>` come from the first line of the initial prompt (ADR-0040), which is known when the worktree is created,
  transliterated with the system's Latin transform and reduced to at most 40 characters of `[a-z0-9-]`. Text with no
  usable characters gives `session`. The result is valid for `git check-ref-format` by construction.
- A nullable `branch` column stores it (migration). Sessions without one keep the derived UUID name and show it in
  full.
- The worktree directory stays `<session id>`, so paths and the location check do not change.
- A branch is never renamed afterwards: a rename under a running agent would surprise it, and an agent's later title
  is not worth that.
- **The removal check stays tied to the session.** `Worktree` takes the stored name and accepts it only with the
  prefix `agenthesia/` and the suffix of this session's id, or as the exact legacy name; otherwise the session is not
  removable, as today for sessions Agenthesia did not create. Discard and merge never delete a name that fails this.

### Alternatives

For the branch, which is the only part of this amendment with a real cost:

- **Keep the UUID and shorten the display (`agenthesia/baaeedd5…`).** One line and no migration, and it leaves ADR-0032
  and removal untouched. But it is not readable, only shorter, and a display that differs from the name misleads
  whoever types it in a terminal. This is the fallback if the owner rejects the rename: display only, with the full
  name still selectable.
- **Show the session title instead of the branch.** Readable but false: it is not the branch, and the window title
  says it already.
- **Name from the agent's title and rename when it arrives.** The best name, but it renames a branch under a running
  agent, and the title may come late or never.

For the layout:

- **Discard in a `…` menu.** Quieter still, but one more click and less visible. The sidebar's context menu and the
  Session menu reach it as well, so this stays a matter of taste; a plain button is the smaller change.
- **Keep Refresh always visible.** Harmless, but it suggests that the list is not live, which is false.

### Consequences and risks

- The rename touches a safety path. ADR-0032's check exists so that removal can never delete a branch the app did
  not create; it needs tests with real repositories for the legacy name, a new name, another session's name and a
  stored name outside `agenthesia/`.
- First-prompt words become part of a branch name. It is local and never pushed by the app, but a user who pushes it
  publishes those words; a prompt that begins with a secret would put it in `git branch` output.
- Without Refresh, a watcher that runs yet misses a change leaves no manual way out except reopening the session. No
  such miss is known. If one is reported, refresh when the window becomes key rather than bringing the button back.
- `canMerge` now depends on `SessionFiles`, so tests for the menu and the inspector need a loaded index.

### Not decided

A manual branch name, pushing or pull requests (ADR-0032), and hiding Discard when there are no changes: it remains
useful then, to clean up.

## Amendment (2026-11-02): a pending permission docks above the composer

- Status: Accepted by the owner on 2026-11-06 (#195); not yet implemented. Until it lands, the transcript and composer text above describes the code.

### Context

A request for a decision is a transcript row today. `155-permission-request-dark.png` shows the cost for a single
small edit: the same diff twice (the tool card, then the permission card), a sentence of explanation, buttons stacked
vertically (`TranscriptTable.swift:536-537`), and shortcuts only in a tooltip and a status caption. `Working for 1s`
sits under it while the agent is blocked (#190). The row can also leave the screen: the reader may have scrolled up,
and with several requests the buttons of an older one are further up. ADR-0039 keeps requests unfolded so that they
stay visible, but unfolded is not on screen. The shortcuts are attached to the editor card
(`RootView.swift:345,411-420`).

### Decision

**One card, above the composer.** It sits in the transcript column between the status line and the composer card,
outside the table, so it stays on screen whatever the scroll position. In order:

- the operation, built from what the protocol defines: kind and paths or the command in full; then the title, as
  agent-authored secondary text. This is the order the ACP specification recommends;
- **one diff**: the request's first diff, or `+2 more files` that expands in place. The body scrolls inside the card,
  which is at most 40 % of the column's height. The tool card in the transcript hides its own diff while its request
  is pending and shows it again afterwards;
- **buttons in a row**, in the agent's order, each with its name exactly as the agent states it and its shortcut
  visible (`Allow once ⌥⌘1`). They wrap at narrow widths and never truncate. No button is styled as default. The
  scope is the agent's words: the app does not reinterpret `once` or `always`, and the note that "always" is remembered
  by the agent stays in the help text. Beyond nine options, only the first nine have shortcuts, as today.

The status line above the card says `Waiting for you` (#190 owns the line in general).

**The transcript keeps the record.** One line: `Allowed once · Edit · Write note.txt`, in a row that no longer has
buttons, with a Details disclosure holding the tool call as known when the agent asked. While pending it reads
`Waiting for you · Edit · Write note.txt`. The log and its events do not change, so saved history gets the same
presentation. Pending rows stay unfolded, as above, so they still end a tool group.

**Several pending requests.** One card, oldest first, which is the order of `pendingPermissions` and the one the
shortcuts already answer. A header counts them (`1 of 3`). There is no list, no navigation between them and no "Allow
all": each request gets its own decision. Requests the agent withdraws, or that Stop settles, leave the queue at once.

**Typing focus is protected.**

- The card never takes first responder, on appearing or when the next request replaces it; the composer keeps its
  text, caret and focus.
- Return and Escape choose nothing, and Return still sends or queues the draft. Only a click or ⌥⌘1…⌥⌘9 answers.
- **Arming.** Buttons and shortcuts ignore input for 400 ms after a request appears on the card, including when the
  next one replaces an answered one. Otherwise a double click or a held ⌥⌘1, meant for the first request, also answers
  the second, which appears under the same pointer. The buttons look disabled while unarmed, and the counter changes
  at once, so the replacement is visible.
- Full keyboard access can still reach the buttons with Tab. VoiceOver announces a new request.

Unchanged: notifications and their actions (ADR-0026), the Dock badge, and `answerPermission` as the only way to
answer, which rejects stale and repeated answers, so two windows showing one card are safe.

### Alternatives

- **Keep the row and scroll it into view.** No new surface, but it moves the reader's scroll position, against
  follow-bottom's rule of keeping the reader's intent, and it still shows the diff twice.
- **A sheet.** Impossible to miss, but it stops typing and every other session's work behind one modal, against
  principle 7. The review sheet shows the same problem (ADR-0041).
- **Inside the composer card.** One surface, but the card is already the busiest in the window, and its contents are
  replaced for read-only sessions.
- **Answer with bare keys while the card shows** (`1`, `2`, `y`). Fast, but it takes keys from the draft, so someone
  typing a sentence answers a request by accident.
- **No arming delay.** Simpler, and nothing to explain, but an accidental second allow is the most expensive mistake
  on this surface. 400 ms is a judgment, not a measurement; the implementation may tune it.

### Consequences and risks

- The docked card shrinks the table's clip view. `followEnd` runs from the table's own layout (`TranscriptTable.swift:51`),
  and a clip view that shrinks may not trigger it, so the reader following the end could lose the last lines behind
  the card. The implementation must test this; ADR-0026's amendment watches the same geometry.
- A short window with a large request leaves little transcript. The 40 % bound keeps a usable rest, and the transcript
  keeps its minimum.
- A tool row that hides its diff while pending and restores it later changes height at the answer; follow-bottom
  handles that, a reader scrolled up keeps their origin.
- Input forms (ADR-0020) still live in the transcript, so "a request for a decision is docked" is true only for
  permissions, and a form can still be off screen; the status line and the sidebar reason still say that it waits.
- MockAgent needs a way to raise several requests at once, or the queue can be tested only in hosted views.

### Not decided

Docking input forms, an order between a pending form and a pending permission, and any app-side "always", which
ADR-0042 addresses in its own, narrower way.
