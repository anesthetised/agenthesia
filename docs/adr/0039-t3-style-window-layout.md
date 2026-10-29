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

**Window.** `NavigationSplitView` (sidebar | transcript and composer) plus a native `.inspector` on the
right. The window title is the session title and the subtitle is its project (`navigationSubtitle`), the
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
