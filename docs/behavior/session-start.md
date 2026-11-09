# Session start

A new session starts from the draft (`SessionDraftView`), which fills the detail column of a window that shows no
session: a heading that names the project, and under it the composer card with the agent and checkout chips above the
first message, and Send. The agent starts only with that
first message; there is no way to start one without it ([ADR-0040](../adr/0040-composer-first-session-start.md), which
replaced the launch form of [ADR-0026](../adr/0026-app-wide-session-manager.md)).

## Opening the draft

- New Session (⇧⌘N, Session menu) and the `+` button in the sidebar's toolbar show the draft in the current window,
  also from the session board. A new window, and a restored window that had no session, show it too. The board
  ([board.md](board.md)) shows only on ⌘0 and the sidebar's Overview row, and when the displayed session is deleted.
- `New Session in Project` in the context menu of a session row (live or saved) opens the draft with that row's
  project selected; the typed message and the agent stay. A starting session has no project yet and offers nothing.
- The `New Session` button of a failure banner that offers it (for example `The agent no longer has this session.`)
  also opens the draft.
- The window title reads `New Session`, with no subtitle. The session the window showed before stays live behind the
  draft; selecting its row returns to it.
- The draft belongs to the window: its text, attachments and picks stay while the window shows other sessions and
  come back with ⇧⌘N. They do not survive a relaunch.

## Layout

- Centered in the column: the heading `What should we build in <project>?` in the large title font, regular weight,
  the project name a borderless menu (see *Project menu*). When the line does not fit the column, the project moves
  to a second line, `<project>?`. Without a project the heading is the menu alone: `Choose a project to start`.
- Under the heading, in secondary text, `or start without a project` (see *Without a project*).
- The composer card sits directly under the heading, centered with it, as wide as a session's composer at most. It has
  the Agent and Checkout chips on top, the text field, and a bottom row with Attach (⇧⌘A, tooltip `Attach files or
  folders (⇧⌘A)`), the hint pills and Send.
- On Send the heading fades and the card moves to the bottom edge, where the `Starting…` card appears, fading as it
  goes while the first message fades in at the top of the column (0.3 s; none under Reduce Motion). A failed or cancelled start returns the draft with the heading and the centered
  card at once.
- Text editing, attachments (Attach, drop, paste) and Return work as in a live session's composer, see
  [composer.md](composer.md). The draft has no slash commands and no config controls other than the hint pills.
- **No agent.** Once the installed agents are read, if none is installed or listed and no custom command is picked,
  the card shows, in place of the text field and its bottom row (Attach, hint pills, Send), the secondary line `Add an
  agent to start a session.` and a prominent `Add Agent…` button that opens Settings → Agents
  ([agents-settings.md](agents-settings.md)). Nothing can be typed, attached or sent until there is an agent; a custom
  command or an agent added in Settings brings the text field back, with the text typed before.

## Project menu

- The project name in the heading, in the accent color with a chevron. A menu of known projects, most recently used
  first (by each project's newest session), then `Choose Folder…`, which opens a folder panel. The selected project
  has a checkmark.
- Default: the project of the newest session in history, so the last project is remembered across launches. With no
  history the heading reads `Choose a project to start`. Its tooltip is the selected path, else `Choose the project
  the agent works in`; its accessibility label is `Project: <name>`.

## Without a project

[ADR-0048](../adr/0048-sessions-without-a-project.md) stores and removes such sessions.

- `or start without a project` under the heading switches the draft: the heading reads `What should we work on?`
  with no project menu, the Checkout label is hidden, and the line under the heading reads `in a project`, which
  switches back. The agent, the text, the attachments and the hint pills stay.
- Per draft, not remembered: Send switches the next draft back to a project, and a new window starts in one. A failed
  or cancelled start returns the draft without a project, as it was sent.
- At Send the session gets a new, empty folder `~/.agenthesia/scratch/<words>-<8 hex digits>`, named like a session
  branch from the first line of the message, and works there: no worktree, no Git. The folder is the agent's only
  filesystem root. A folder of that name that already exists fails the start rather than being shared.
- All such sessions belong to the project `No project`, which the project menu never offers and which is never the
  draft's default. `New Session in Project` on such a row opens a draft without a project.
- The session has no Review, Merge or Discard; the inspector's Changes read `Not tracked: this session has no
  project`. Show in Finder and Open in Editor open its folder, and Continue runs there again.

## Agent chip

- A menu of installed agents (the newest version of each, named `<name> <version>`), then
  local agents from Settings → Agents, then `Custom Command…` and `Manage Agents…` (opens Settings → Agents). Tooltip:
  `The agent that starts the session`. With nothing to pick it reads `Choose Agent` and offers only `Custom Command…`,
  since the card's `Add Agent…` leads to Settings.
- Default: the agent of the last session that started, kept across launches while that agent is still offered, else
  the first in the list. An agent is remembered only once its session's first message was submitted, so a failed or
  cancelled start keeps the previous default.
- `Custom Command…` opens a sheet with `Executable` (placeholder `/path/to/agent or command on PATH`) and `Arguments`
  (`One argument per line. Use an installed, authenticated ACP agent.`), `Cancel` and `Use Command`, which is disabled
  while the executable is blank. `~` is expanded. The chip then shows the executable's file name; opening the sheet
  again edits that command. A custom command can be remembered as the default like any other agent.

## Checkout

- For a Git project the chip is a menu ([ADR-0043](../adr/0043-sessions-in-the-project-folder.md)) with two items, the
  chosen one checked:
  - `New worktree from <base>`, the default: the upstream of the branch checked out in the project when it has one
    (`New worktree from origin/main`), the branch itself without one, or the short commit when `HEAD` is detached;
    tooltip `The session works in a new Git worktree of the committed files. Uncommitted and untracked files are not
    copied.` The session gets its own worktree and branch ([ADR-0006](../adr/0006-worktree-isolation.md),
    [ADR-0032](../adr/0032-worktree-merge-and-discard.md)); the branch is named after the first line of the message.
  - `Project folder`: the session works in the selected folder itself, on whatever is checked out there, with no
    worktree, no branch and no fetch; tooltip `The agent works in your checkout. Edits land on <branch> directly and
    are not isolated from your own changes.` (the short commit when `HEAD` is detached).
- The chip shows the chosen item with a branch symbol, or a folder for the project folder; its tooltip is the chosen
  item's, and VoiceOver reads `Checkout: <item>`.
- The choice is per draft and never remembered: every draft starts with the worktree, and Send, picking another
  project and New Session in Project return to it. A failed or cancelled start returns the draft with the choice it
  was sent with.
- With an upstream, a worktree's Send fetches that one branch (at most 20 seconds) and the worktree starts from it, so the agent
  works on the latest code even when the local branch was not pulled
  ([ADR-0047](../adr/0047-worktrees-from-the-fetched-upstream.md)). The local branch is never moved. When the fetch
  fails or takes longer, the session starts from the local branch, and the Workspace block of the inspector reads
  `Started from local main: could not fetch origin/main` under the session branch instead of `from main`.
- Merge into the local branch waits until that branch contains the commit the session started from: until then Merge
  explains `The session started from a newer origin/main than “main” contains. Pull origin/main into “main” first,
  then merge.`, and Review compares with the session's start rather than the merge base.
- Outside Git it is a label, not a menu: `Project folder`, tooltip `Not a Git repository: the session works in the
  folder itself.`
- The chip appears once the project has been checked, and is absent without a project
  ([ADR-0048](../adr/0048-sessions-without-a-project.md)).
- A project-folder session's Changes and Review compare with the commit checked out when it started, under the header
  `Changes since the session started`; it offers no Merge, Discard Worktree…, Push or Open Pull Request…
  ([inspector.md](inspector.md), [merge.md](merge.md)).

## Mode, model and effort hints

- If the app has seen the selected agent's config options before, the bottom row shows its **mode**, **model** and
  **effort** as pill menus after Attach, in the agent's order, drawn as secondary. They are the session's control row
  of [composer.md](composer.md): when they do not fit, they move from the end into the `…` menu. Only select options the agent
  categorises as `mode`, `model` or `thought_level` become pills; other options wait for the session
  ([ADR-0040's amendment of 2026-11-02](../adr/0040-composer-first-session-start.md)).
- Tooltip and accessibility note: `Last used with this agent; confirmed when the session starts`. A pill's label is
  the value only; the option's name is in the accessibility label.
- The cache holds what the agent last confirmed in any session (start, Continue, or a change in a live session), per
  agent across its versions, and per custom command. An agent never run before shows no pills.
- The **model** and **effort** pills show the cached value, and Send applies each unless another is picked. A value
  the agent no longer offers, after `session/new` and after the model was set, returns the draft with the error
  (`The agent does not offer “High” any more.`), as for the model; the agent's list becomes the cache.
- The **mode** pill opens the mode popover of [composer.md](composer.md), with the agent's descriptions and no mark on
  a row until one is picked. It reads `Default mode` and is applied only when a mode is picked in this draft; otherwise
  the session keeps the mode the agent starts in.
  *Why:* the app cannot tell from a name whether a mode stops asking for permission, so such a mode must never come
  back by itself.
- A pick changes only this draft. Changing the agent drops the picks; changing the project does not. Send clears the
  picks; if the start fails or is cancelled they come back with the text and attachments, except a value the agent
  no longer offers (see *Stale hint*).
- The agent's confirmed values replace the hints once the session starts; its composer shows them as config controls
  (see [composer.md](composer.md)).

## Send

- Send (the arrow button or Return, tooltip `Start the session with this message (Return)`) needs a message with
  non-whitespace text or an attachment, a project (or a draft without one) and an agent; otherwise the button is
  disabled and Return does nothing.
- Send starts the session with the selected project, agent and hints, holds the message as its first prompt, and
  clears the draft at once. The window switches to the starting session.
- The first message is submitted like a typed prompt (when ready) as soon as the session is idle for the first time.

## While starting

- From Send until the session is idle, the detail column shows the transcript layout with the first message as its
  only row: a user bubble with its attachments, as the session's own transcript will show it, so the message stays
  where it is when that arrives ([ADR-0040's amendment of 2026-11-07](../adr/0040-composer-first-session-start.md)).
  Under it, where the composer will be, a status line and the compact card `Starting…`; there is no composer. The
  inspector, which needs the session, appears once it exists.
- The status line reads `Fetching origin/main…` while the fetch of the branch's upstream runs (at most 20 seconds,
  [ADR-0047](../adr/0047-worktrees-from-the-fetched-upstream.md)), then `Starting <agent> in a new worktree…`, or
  `Starting <agent> in the project folder…` for the project folder (a project outside Git, or `Project folder`
  chosen), or `Starting <agent> in a new folder…` for a
  session without a project. It is blank for the moment before the place is known.
- The app checks the agent's executable or installed version first (so a mistyped command leaves no worktree), then
  fetches and creates the worktree.
- The sidebar lists the session under Working as `New Session` with the reason `Starting` ([sidebar.md](sidebar.md)).
- The toolbar button and the Session menu item read `Cancel Startup` (⇧⌘E).
- If the agent asks to sign in ([ADR-0033](../adr/0033-agent-sign-in.md)), the sign-in panel replaces the card, the
  message stays above it, and the button reads `End Session`; after sign-in succeeds the session starts and the first
  message is submitted.

## Failed or cancelled start

- If the start fails, or is cancelled (`Cancel Startup`, or `End Session` at sign-in), the window returns to the
  draft with the message and its attachments, and the error in a red banner above the card (none for a
  cancellation). The banner offers `Manage Agents…` for a missing executable or agent version, and `Details` with the
  raw text when it shortens the error. The error clears on Send or when the project or agent changes.
- A start that never reached a history record leaves nothing behind: its worktree and branch are removed unless they
  hold work, the folder of a session without a project is removed while it is empty, and the sidebar does not list
  it ([ADR-0033's amendment](../adr/0033-agent-sign-in.md)).
- A start that fails while the window shows something else stays in the sidebar as failed; selecting it returns its
  message to that window's draft, replacing the text there.
- **Stale hint.** If the agent no longer offers a hinted value, or rejects it, the start fails with `The agent does
  not offer “<value>” any more.` or `The agent did not accept “<value>”: <reason>`. The pills then show what the agent
  just reported, and a pick it no longer lists is dropped, so the next Send works: at most one bounce per stale hint.
  A value the agent still lists but rejected stays picked, so the user can choose another.
  *Why:* a session that silently ran in another mode than its pill showed could write when the user expected
  read-only.

Continuing a saved session (Continue, ⇧⌘C) does not go through the draft; see
[ADR-0017](../adr/0017-continue-saved-sessions.md).

## Changes

- 2026-11-09, #227: blank and restored windows keep the draft; the session board shows on ⌘0, the Overview row and
  after the displayed session is deleted.
- 2026-11-09, #229: the Checkout label becomes a menu for Git projects, `New worktree from <base>` or `Project folder`,
  per draft (ADR-0043).
- 2026-11-09, #225: while a session starts, the detail column shows the first message as the transcript's only
  row with the line `Fetching origin/<branch>…`, then `Starting <agent> in …`, and the `Starting…` card, instead of
  `Starting session…`.
- 2026-11-09, #301: VoiceOver reads the Agent chip as `Agent: <name>` (not its symbol, `CPU chip`) and the
  heading's project menu once.
- 2026-11-08, #279: `or start without a project` under the heading; such a session works in its own folder under
  `~/.agenthesia/scratch` in the project `No project`, without Review, Merge or Discard.
- 2026-11-08, #278: the draft's heading `What should we build in <project>?` holds the project menu, which leaves the
  card; the card sits centered under it and moves to the bottom edge on Send. Without an agent the card offers
  `Add Agent…` instead of the text field, replacing the `No agent is installed.` line.
- 2026-11-08, #276: the hints are the session's control row and overflow into its `…` menu.
- 2026-11-08, #277: the Checkout label names the upstream; the start falls back to the local branch with a line in
  the inspector; Merge waits for the local branch to contain the session's start (ADR-0047).
- 2026-11-08, #271: the draft's mode pill opens the mode popover.
- 2026-11-08, #264: Manage Agents… opens Settings on the Agents tab ([agents-settings.md](agents-settings.md)).
- 2026-11-08, #270: effort is a hint like the model: the cache keeps the `thought_level` option, its pill is applied by
  default.
- 2026-11-08, #265: a failed or cancelled start returns the draft's mode and model picks with the text, except a
  value the agent no longer offers.
- 2026-11-08, #271: the draft's mode pill opens the mode popover.
- 2026-11-08, M18: planned changes added from the owner's first-use feedback.
- 2026-11-08, #261: summarised from ADR-0040 and its amendment of 2026-11-02, ADR-0033's amendment (#176) and
  ADR-0026, checked against main at c65b8a1.
