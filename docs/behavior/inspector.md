# Inspector

The right column of a session window (⌥⌘I shows and hides it) holds the displayed session's details in a grouped form:
Plan, Changes, Workspace and Agent, top to bottom. A section without anything to show is absent.

## Plan

- The agent's plan ([ADR-0039's amendment](../adr/0039-t3-style-window-layout.md)) leads the inspector while the
  session has one: one row per entry, the text in full. A checkmark marks `completed` (the row is dimmed), a filled dot
  in the accent color `in_progress`, an empty circle `pending` and any status the app does not know. The priority is
  not drawn: it is the row's tooltip (`High priority`) and ends its accessibility label (`In progress: Write tests,
  high priority`).
- The header reads `Plan · 3 of 7`, the completed entries of all. Each update from the agent replaces the list.
- The section is open while a turn runs and collapses to its header when the turn ends; the header's disclosure opens
  and closes it by hand, and that choice holds until the next turn starts or ends.
- A new turn clears the plan: the section disappears at Send and comes back with the turn's first plan update. A
  saved session shows the plan of its last turn, collapsed.

The same plan drives the [status line](composer.md#status-line) and a Working row's
[reason](sidebar.md#reasons).

## Changed files

- The Changes section lists the changed files with their line counts, Review and Merge (`Review` is prominent while
  there are changes), Open Pull Request… when `gh` can open one, and once a pull request is open `Pull request #12` as a
  link with Push beside it instead of Merge ([merge.md](merge.md#pull-requests)), and a manual refresh when the file watcher is unavailable. A session without a project reads `Not tracked: this session has no
  project` ([ADR-0048](../adr/0048-sessions-without-a-project.md)).

## Workspace

- The branch and where it started (`from main`, or `Started from local main: could not fetch origin/main`,
  [ADR-0047](../adr/0047-worktrees-from-the-fetched-upstream.md)), the working directory, Show in Finder and Open in
  Editor in the header, and Discard Worktree… for a session with a worktree.

## Agent

- The agent's name and the Agent Log switch, for a live session.
- Once the agent reported its context usage (`usage_update`), `Context` reads `84k of 200k · 42 %` (tokens in context
  of the window's size, the percentage rounded down), and `Cost` the cost the agent reports, formatted by the system
  in the agent's currency (`$1.23`). Nothing shows before the first report. Beyond 70 % the composer also shows it
  ([context ring](composer.md#session-settings)).

## Changes

- 2026-11-09, #233: Open Pull Request…, the pull request link and Push in Changes.
- 2026-11-09, #222: Context and Cost in the Agent section.
- 2026-11-09, #221: the Plan section; the rest of the inspector summarised from the code at f5a8232.
