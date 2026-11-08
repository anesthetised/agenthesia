# Composer

The composer is the card at the bottom of a live session's transcript column, where the user writes the next message,
attaches files, picks an agent command, changes the session's settings and sends or stops. Above it sit the docked
permission request, errors and the status line. A session that cannot take a prompt shows a compact card with Continue
instead. The draft before a session exists is described in [session-start.md](session-start.md), and the prompt queue
(Send or Queue, steering, pause, editing queued messages) in [queue.md](queue.md).

## Layout

- From the top of the transcript pane down: the transcript, the docked permission request, errors, the status line,
  and the composer card. The dock, errors, status line and card share the transcript column (at most 720 pt wide,
  16 pt side and 12 pt bottom margins); the card has rounded corners, bar material and a hairline border.
- Inside the card, top to bottom: the queue and its editing hint ([queue.md](queue.md)), the command list, the
  attachment chips, the text, and the bottom row.
- The bottom row, left to right: Attach (paperclip), the control row with the session's settings, then on the
  trailing edge the Send options menu (chevron) and the round primary button. The draft's card has the same row
  ([session-start.md](session-start.md)).
- While the agent asks the user to sign in, the sign-in panel takes the place of the dock, errors and card.

## Text

- A plain-text editor with the placeholder `Message the agent…` (accessibility label `Message`). It grows from two to
  six lines, then scrolls. Smart quotes and dashes are off.
- Return sends or queues the draft; ⇧Return and ⌥Return insert a line break. Escape never inserts anything (it closes
  the command list when one shows). ⌘Return and ⇧⌘Return are the Send options below; ⌘. stops the turn.
- The text takes keyboard focus when the card appears. Session → Focus Composer (⌘L) moves focus back to it from any
  pane. Ask agent in the review inserts the selected diff lines at the caret, after any selected text, on lines of
  their own; Undo removes them and nothing is sent.
- The text stays editable while a turn runs. It is read-only only for the moment a send is being accepted.
- Each session keeps its own unsent text, attachments and queue edit while the window lives, so switching sessions
  loses nothing. Drafts do not survive a relaunch, and two windows on one session have separate drafts. A draft clears
  only once the session has durably accepted it; if that fails, the draft stays.

## Attachments

- Files and folders are added by dropping them on the card, by pasting them, or with Attach Files… (paperclip, ⇧⌘A),
  an open panel that allows several files and folders and starts in the session's working directory. Pasted or dropped
  files become attachments, never inserted paths.
- Each attachment is a chip: the file's icon and name, with a remove button (`Remove <name>`); the tooltip is the full
  path. Chips sit in one row that scrolls sideways. A file already attached is not added twice. There is no limit on
  the number or size of attachments.
- Attachments alone are a valid message. The agent receives the text first, then one link per attachment in the order
  added, never the contents; a path in the main checkout points to the same file in the session's worktree when it
  exists there ([ADR-0018](../adr/0018-composer-attachments.md)).
- While a queued message is being edited, Attach is disabled, chips cannot be removed and drops are refused.

## Slash commands

- The list exists only when the agent has announced commands, and shows while the whole draft is a bare `/word` (no
  whitespace): the commands whose names start with the typed word, ignoring case. A lone `/` lists them all.
- Each row shows `/name`, the description and, if the command takes input, its hint. The list is at most 180 pt tall
  and scrolls.
- ↑ and ↓ move the selection, Return or Tab (or a click) replaces the draft with `/name ` and closes the list. Escape
  hides the list until the draft stops being a command word. Choosing a command sends nothing; it is plain text.

## Session settings

- The agent's config options appear as pills in the control row of the bottom row, in the agent's order
  ([ADR-0019](../adr/0019-session-config-controls.md)). The draft shows its hints in the same row. A select option is a borderless menu whose label is the current
  value's name only; the tooltip is `<option>: <description>` (or the option name), and the accessibility label is
  `<option>: <value>`. The menu lists the agent's choices, in the agent's groups as sections, with a checkmark on the
  current one; each choice's tooltip is its description.
- The **mode** (the select option categorised as `mode`) is a pill that opens a popover instead of a menu: one row per
  mode with its name and, under it, the description the agent sends with it (in secondary text; a mode without one
  shows the name only), in the agent's groups under their headers, with a checkmark on the current one. The pill shows
  the mode's name and a chevron. The current mode is highlighted when the popover opens; ↑ and ↓ move the highlight,
  Return or a click chooses (the popover closes and the change goes the way a menu pick does), Escape closes it. A row's
  accessibility label is `<name>. <description>`, and the current row is marked selected. There are no icons and no
  fixed access levels: the app does not know what an agent's modes mean (VISION principle 8). The draft's mode hint
  works the same way (see [session-start.md](session-start.md)).
- A boolean option (for example `Fast mode`) is a toggle pill: the option's name, in the accent color on a filled
  capsule while on and plain while off; its tooltip is the description, and VoiceOver reads it as a toggle with its
  value (`On`, `Off`). A click asks the agent for the other value, as a menu pick does.
- **Overflow.** When the pills do not fit beside Attach and the Send buttons, options move, from the end, into a `…`
  pill menu (accessibility label and tooltip `More settings`): first the options other than mode, model and effort,
  then those three, also from the end. The menu lists them in the agent's order: a select option as a submenu
  `<option>: <value>` with its choices, a boolean as a checkable item. No pill is ever cut by the card's edge; at the
  narrowest only `…` is left. Widening the window brings the pills back.
- Pills that appear or disappear (another agent, the agent's new list) fade in and out in about 0.2 s; under Reduce
  Motion they change at once.
- Options of unknown types are not shown.
- Settings can be changed only while the session is idle; while a turn runs, all pills are disabled.
- A pick shows nothing as accepted at first: the pill keeps the confirmed value, a small spinner (`Changing session
  settings`) appears and all pills are disabled until the agent's answer has been recorded. The pills then show the
  agent's full returned settings, which may differ from the pick. While the change is pending, Send and Send Now are
  disabled too. *Why:* the agent may refuse or adjust a value, and a turn must not start before the setting applies;
  showing the pick early would mean rolling it back.
- A refused change keeps the confirmed values, leaves the session usable and shows the error above the card; it clears
  when the next change starts.

## Send, Queue, Save and Stop

- The round button shows an arrow for Send, `Queue` with the arrow when the draft would wait behind a running turn or
  other queued messages, and `Save` while a queued message is edited. It becomes Stop (square) while a turn runs or
  stops, or an input form waits, and the draft is empty. Which of Send and Queue applies is in [queue.md](queue.md).
- Tooltips: `Send the message (Return)`, `Queue the message until the agent is ready (Return)`, `Save the queued
  message (Return)`, `Stop the current turn (⌘.)`.
- Send, Queue and Save are disabled for an empty draft (whitespace only and no attachments), while a send is being
  accepted, and while a settings change is pending. Stop is disabled once the turn is stopping and the queue is paused.
- The Send options menu (chevron, `Send options`) holds `Send Draft Now` (or `Send Queue Now` when the draft is empty)
  with ⌘Return, and `Send Whole Queue Now` with ⇧⌘Return; while a turn runs both names end in ` (Interrupts Turn)`.
  When the turn can be stopped, `Stop Turn` follows a divider. Their rules are in [queue.md](queue.md).
- Stop is also Session → Stop (⌘.).

## Status line

- While a turn runs or stops, a caption directly above the composer card, aligned with its leading edge in the
  transcript column (under the docked request and errors), reads `Working for 12s` (`1m 12s`, `1h 2m`) with a small
  spinner, ticking once a second.
- While a permission request or an input form is pending, it reads `Waiting for you` with an orange symbol instead.
- There is no status line while the session is idle.

## Docked permission request

- The oldest pending permission request is a card above the composer card, outside the transcript, so it stays on
  screen whatever the scroll position ([ADR-0039](../adr/0039-t3-style-window-layout.md), amendment of 2026-11-02).
- It shows the tool kind's symbol and `<kind> · <paths>` (the call's locations, then the files its diffs edit), the
  agent's title as secondary text, and `1 of 3` while several requests are pending; there is no navigation between
  them. The first diff follows with its path (` (new file)` when it creates one); `+1 more file`, `+2 more files`
  expands the others in place. The card is at most 40 % of the column's height; the diff scrolls inside it.
- Buttons follow the agent's order and names, each with its shortcut beside it (`⌥⌘1` to `⌥⌘9` for the first nine);
  they wrap instead of truncating, and none is the default. An "always" option's tooltip is `“Always” is remembered by
  the agent, not by Agenthesia.`
- The card never takes focus: Return and Escape stay with the composer. Only a click or ⌥⌘1…⌥⌘9 answers.
- For 400 ms after a request appears, including the next one after an answer, the buttons look disabled and ignore
  clicks and shortcuts. *Why:* a double click or a held ⌥⌘1 meant for one request would otherwise answer the next,
  which appears under the same pointer.
- VoiceOver announces `Permission request: <kind> · <paths>`, with `, 3 pending` when several are.

## Errors

- An error of a send, a queue action or a settings change shows above the card in red: a short sentence with a warning
  symbol, the actions that fit it (`Agent Log`, `New Session`, `Manage Agents…`) and the full text under `Details`.
  Sending again clears a send or queue error; a settings error stays until the next settings change.

## Sessions that cannot take a prompt

- Instead of the composer card, a compact card of the same shape shows a symbol and the state, and Continue
  (`Continue`, tooltip `Reconnect to the agent.`) when the session can be reattached:

  | State | Text | Continue |
  |---|---|---|
  | Saved history | `Saved session` | if it has an agent session ID |
  | Ended | `Session ended` | if it has an agent session ID and a saved record |
  | Connection failed | `Connection failed` | as for ended |
  | Starting | `Starting…` | no |
  | Merging | `Merging…` | no |
  | Merged or discarded | `Merged · read-only`, `Discarded · read-only` | no |

- When the card offers Continue, it has a second line with the last confirmed settings, read from the session's
  history: the current value name of each select option in the agent's order, then the booleans that are on by name,
  joined by ` · `, for example `Opus 5.5 · High · Plan`. No line when there are none.
- When the session has retained queued entries, they show above the card, read-only, as in
  [queue.md](queue.md#recovery).

## Changes

- 2026-11-08, #276: one control row in the draft and the session; booleans are toggle pills instead of checkboxes;
  options that do not fit move into a `…` menu; the status line sits directly above the card.
- 2026-11-08, #271: the mode pill opens a popover with the agent's descriptions instead of a menu.
- 2026-11-08, M18: planned changes added from the owner's first-use feedback.
- 2026-11-08, #261: summarised from ADR-0018, ADR-0019 and ADR-0039 (Composer, amendment of 2026-11-02), checked
  against main at c65b8a1.
- 2026-11-08, #267: the Continue card shows the last confirmed settings and the retained queue above it.
