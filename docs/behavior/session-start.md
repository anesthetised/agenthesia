# Session start

A new session starts from the draft (`SessionDraftView`), which fills the detail column of a window that shows no
session: the project, agent and checkout chips above the first message, and Send. The agent starts only with that
first message; there is no way to start one without it ([ADR-0040](../adr/0040-composer-first-session-start.md), which
replaced the launch form of [ADR-0026](../adr/0026-app-wide-session-manager.md)).

## Opening the draft

- New Session (⇧⌘N, Session menu) and the `+` button in the sidebar's toolbar show the draft in the current window. A
  new window, and a restored window that had no session, show it too.
- `New Session in Project` in the context menu of a session row (live or saved) opens the draft with that row's
  project selected; the typed message and the agent stay. A starting session has no project yet and offers nothing.
- The `New Session` button of a failure banner that offers it (for example `The agent no longer has this session.`)
  also opens the draft.
- The window title reads `New Session`, with no subtitle. The session the window showed before stays live behind the
  draft; selecting its row returns to it.
- The draft belongs to the window: its text, attachments and picks stay while the window shows other sessions and
  come back with ⇧⌘N. They do not survive a relaunch.

## Layout

- The empty transcript area holds the line `What should the agent do?`. The composer card below it has the chips on
  top, the text field, and a bottom row with Attach (⇧⌘A, tooltip `Attach files or folders (⇧⌘A)`), the hint pills
  and Send.
- Text editing, attachments (Attach, drop, paste) and Return work as in a live session's composer, see
  [composer.md](composer.md). The draft has no slash commands and no config controls other than the hint pills.
- When no agent is installed or listed (and no custom command is picked), a line above the card reads
  `No agent is installed.` with a `Manage Agents…` link to Settings → Agents ([agents-settings.md](agents-settings.md)).

## Project chip

- A menu of known projects, most recently used first (by each project's newest session), then `Choose Folder…`, which
  opens a folder panel. The selected project has a checkmark.
- Default: the project of the newest session in history, so the last project is remembered across launches. With no
  history the chip reads `Choose Project`. Its tooltip is the selected path, else `Choose the project the agent works
  in`.

## Agent chip

- A menu of installed agents (the newest version of each, named `<name> <version>`), then
  local agents from Settings → Agents, then `Custom Command…` and `Manage Agents…` (opens Settings → Agents). Tooltip:
  `The agent that starts the session`. With nothing to pick it reads `Choose Agent`.
- Default: the agent of the last session that started, kept across launches while that agent is still offered, else
  the first in the list. An agent is remembered only once its session's first message was submitted, so a failed or
  cancelled start keeps the previous default.
- `Custom Command…` opens a sheet with `Executable` (placeholder `/path/to/agent or command on PATH`) and `Arguments`
  (`One argument per line. Use an installed, authenticated ACP agent.`), `Cancel` and `Use Command`, which is disabled
  while the executable is blank. `~` is expanded. The chip then shows the executable's file name; opening the sheet
  again edits that command. A custom command can be remembered as the default like any other agent.

## Checkout label

- Not a menu. For a Git project it reads `New worktree from <branch>`, the branch checked out in the project, or the
  short commit when `HEAD` is detached; tooltip `The session works in a new Git worktree of the committed files.
  Uncommitted and untracked files are not copied.` Every Git session gets its own worktree and branch
  ([ADR-0006](../adr/0006-worktree-isolation.md), [ADR-0032](../adr/0032-worktree-merge-and-discard.md)); the branch
  is named after the first line of the message.
- Outside Git it reads `Project folder`, tooltip `Not a Git repository: the session works in the folder itself.`
- The label appears once the project has been checked, and is absent without a project.

## Mode, model and effort hints

- If the app has seen the selected agent's config options before, the bottom row shows its **mode**, **model** and
  **effort** as pill menus after Attach, in the agent's order, drawn as secondary. Only select options the agent
  categorises as `mode`, `model` or `thought_level` become pills; other options wait for the session
  ([ADR-0040's amendment of 2026-11-02](../adr/0040-composer-first-session-start.md)).
- Tooltip and accessibility note: `Last used with this agent; confirmed when the session starts`. A pill's label is
  the value only; the option's name is in the accessibility label.
- The cache holds what the agent last confirmed in any session (start, Continue, or a change in a live session), per
  agent across its versions, and per custom command. An agent never run before shows no pills.
<<<<<<< HEAD
- The **model** and **effort** pills show the cached value, and Send applies each unless another is picked. A value
  the agent no longer offers, after `session/new` and after the model was set, returns the draft with the error
  (`The agent does not offer “High” any more.`), as for the model; the agent's list becomes the cache.
- The **mode** pill reads `Default mode` and is applied only when a mode is picked in this draft; otherwise the
=======
- The **model** pill shows the cached model, and Send applies it unless another is picked.
- The **mode** pill opens the mode popover of [composer.md](composer.md), with the agent's descriptions and no mark on
  a row until one is picked. It reads `Default mode` and is applied only when a mode is picked in this draft; otherwise the
>>>>>>> f858d63 (feat: a mode popover with the agent's descriptions)
  session keeps the mode the agent starts in.
  *Why:* the app cannot tell from a name whether a mode stops asking for permission, so such a mode must never come
  back by itself.
- A pick changes only this draft. Changing the agent drops the picks; changing the project does not. Send clears the
  picks; if the start fails or is cancelled they come back with the text and attachments, except a value the agent
  no longer offers (see *Stale hint*).
- The agent's confirmed values replace the hints once the session starts; its composer shows them as config controls
  (see [composer.md](composer.md)).

## Send

- Send (the arrow button or Return, tooltip `Start the session with this message (Return)`) needs a message with
  non-whitespace text or an attachment, a project and an agent; otherwise the button is disabled and Return does
  nothing.
- Send starts the session with the selected project, agent and hints, holds the message as its first prompt, and
  clears the draft at once. The window switches to the starting session.
- The first message is submitted like a typed prompt (when ready) as soon as the session is idle for the first time.

## While starting

- Until the session exists, the detail column shows `Starting session…`. The app checks the agent's executable or
  installed version first (so a mistyped command leaves no worktree), then creates the worktree. Once the session
  exists, the window shows its empty transcript with the compact card `Starting…`.
- The sidebar lists the session under Working as `New Session` with the reason `Starting` ([sidebar.md](sidebar.md)).
- The toolbar button and the Session menu item read `Cancel Startup` (⇧⌘E).
- If the agent asks to sign in ([ADR-0033](../adr/0033-agent-sign-in.md)), the sign-in panel replaces the card and the
  button reads `End Session`; after sign-in succeeds the session starts and the first message is submitted.

## Failed or cancelled start

- If the start fails, or is cancelled (`Cancel Startup`, or `End Session` at sign-in), the window returns to the
  draft with the message and its attachments, and the error in a red banner above the card (none for a
  cancellation). The banner offers `Manage Agents…` for a missing executable or agent version, and `Details` with the
  raw text when it shortens the error. The error clears on Send or when the project or agent changes.
- A start that never reached a history record leaves nothing behind: its worktree and branch are removed unless they
  hold work, and the sidebar does not list it ([ADR-0033's amendment](../adr/0033-agent-sign-in.md)).
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

## Planned (M18)

Accepted by the owner on 2026-11-08 (first-use feedback); not implemented yet. The pull request that implements an item
moves it into the text above and deletes it here.

- **A heading with the project.** The draft shows, centered, `What should we build in <project>?` in a large title
  font; the project name is a borderless menu with the Project chip's items, and moves to a second line in a narrow
  column. The composer card sits directly under it, centered, and the Project chip leaves the card. After Send the card
  moves to the bottom edge (without animation under Reduce Motion).
- **Without a project** ([ADR-0048](../adr/0048-sessions-without-a-project.md)): `or start without a project` under the
  heading switches the draft to `What should we work on?` and hides the Checkout chip; `in a project` switches back.
  Per draft, not remembered.
- **The Checkout label names the upstream** when the branch has one, `New worktree from origin/main`, because the
  worktree starts from it ([ADR-0047](../adr/0047-worktrees-from-the-fetched-upstream.md)). When the fetch fails, the
  inspector's Workspace block says the session started from the local branch.

## Changes

<<<<<<< HEAD
- 2026-11-08, #264: Manage Agents… opens Settings on the Agents tab ([agents-settings.md](agents-settings.md)).
- 2026-11-08, #270: effort is a hint like the model: the cache keeps the `thought_level` option, its pill is applied by
  default.
- 2026-11-08, #265: a failed or cancelled start returns the draft's mode and model picks with the text, except a
  value the agent no longer offers.
=======
- 2026-11-08, #271: the draft's mode pill opens the mode popover.
>>>>>>> f858d63 (feat: a mode popover with the agent's descriptions)
- 2026-11-08, M18: planned changes added from the owner's first-use feedback.
- 2026-11-08, #261: summarised from ADR-0040 and its amendment of 2026-11-02, ADR-0033's amendment (#176) and
  ADR-0026, checked against main at c65b8a1.
