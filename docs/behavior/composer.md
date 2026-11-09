# Composer

The composer is the card at the bottom of a live session's transcript column, where the user writes the next message,
attaches files, picks an agent command, changes the session's settings and sends or stops, and where the agent's
questions are answered. Above it sit the docked permission request, errors and the status line. A session that cannot take a prompt shows a compact card with Continue
instead. The draft before a session exists is described in [session-start.md](session-start.md), and the prompt queue
(Send or Queue, steering, pause, editing queued messages) in [queue.md](queue.md).

## Layout

- From the top of the transcript pane down: the transcript, the docked permission request, errors, the status line,
  and the composer card. The dock, errors, status line and card share the transcript column (at most 720 pt wide,
  16 pt side and 12 pt bottom margins); the card has rounded corners, bar material and a hairline border.
- Inside the card, top to bottom: the docked questions (below), the queue and its editing hint ([queue.md](queue.md)),
  the command list, the attachment chips, the text, and the bottom row.
- The bottom row, left to right: Attach (paperclip), the control row with the session's settings, then on the
  trailing edge the context ring (from 70 %, see below), the Send options menu (chevron) and the round primary button. The draft's card has the same row
  ([session-start.md](session-start.md)).
- While the agent asks the user to sign in, the sign-in panel takes the place of the dock, errors and card.

## Text

- A plain-text editor with the placeholder `Message the agent…` (accessibility label `Message`). It grows from two to
  six lines, then scrolls. Smart quotes and dashes are off.
- Return sends or queues the draft (while questions are docked, it answers them instead; see below); ⇧Return and
  ⌥Return insert a line break. Escape never inserts anything (it closes
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
- While questions are docked, the chips are hidden, Attach is disabled and drops are refused; the draft's attachments
  come back with it.

## Slash commands

- The list exists only when the agent has announced commands and no questions are docked, and shows while the whole draft is a bare `/word` (no
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
  accessibility label is `<name>. <description>`, and the current row is marked selected. The popover is as tall as its
  rows (up to 360 pt, then it scrolls). There are no icons and no
  fixed access levels: the app does not know what an agent's modes mean (VISION principle 8). The draft's mode hint
  works the same way (see [session-start.md](session-start.md)).
- A boolean option (for example `Fast mode`) is a toggle pill: the option's name, in the accent color on a filled
  capsule while on and plain while off; its tooltip is the description, and VoiceOver reads it as a toggle with its
  value (`On`, `Off`). A click asks the agent for the other value, as a menu pick does.
- **Context ring.** From 70 % of the agent's context window ([ADR-0039's
  amendment](../adr/0039-t3-style-window-layout.md), `usage_update`), a small ring with the percentage, `75 %`, sits in
  a fixed slot before the Send options menu: secondary below 90 %, orange from 90 %. Its tooltip and accessibility label
  carry the numbers, `Context 150k of 200k · 75 %`, and the cost when the agent reports one. The percentage is rounded
  down. Below 70 % it takes no room. Its width comes out of the pills' room and it never moves into `…`. The draft has
  no ring.
- **Overflow.** When the pills do not fit beside Attach, the context ring and the Send buttons, options move, from the end, into a `…`
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
  stops and the draft is empty. While questions are docked it reads `Next` with the arrow, or `Answer` on the last
  step, whatever the draft. Which of Send and Queue applies is in [queue.md](queue.md).
- Tooltips: `Send the message (Return)`, `Queue the message until the agent is ready (Return)`, `Save the queued
  message (Return)`, `Stop the current turn (⌘.)`, `Answer this question and go to the next (Return)`, `Send the
  answers to the agent (Return)`.
- Next and Answer are disabled while the step, or on the last step the whole form, has errors.
- Send, Queue and Save are disabled for an empty draft (whitespace only and no attachments), while a send is being
  accepted, and while a settings change is pending. Stop is disabled once the turn is stopping and the queue is paused.
- The Send options menu (chevron, `Send options`) holds `Send Draft Now` (or `Send Queue Now` when the draft is empty)
  with ⌘Return, and `Send Whole Queue Now` with ⇧⌘Return; while a turn runs both names end in ` (Interrupts Turn)`.
  When the turn can be stopped, `Stop Turn` follows a divider. Their rules are in [queue.md](queue.md). Both send items
  are disabled while questions are docked.
- Stop is also Session → Stop (⌘.).

## Status line

- While a turn runs or stops, a caption directly above the composer card, aligned with its leading edge in the
  transcript column (under the docked request and errors), reads `Working for 12s` (`1m 12s`, `1h 2m`) with a small
  spinner, ticking once a second. With a plan ([inspector](inspector.md#plan)) it goes on with the completed entries
  and the entry in progress, `Working for 1m 12s · 3 of 7 · Writing tests`, or `· 3 of 7 done` while none is; one
  line, truncated at the end.
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

## Docked questions

An agent's form ([ADR-0020](../adr/0020-native-elicitation-forms.md), [ADR-0022](../adr/0022-session-scoped-elicitation.md)),
such as Claude's AskUserQuestion, is answered from the composer, as in T3 Code (#326).

- The oldest pending form docks at the top of the composer card, above the queue; others wait behind it and dock in
  turn. The transcript shows each waiting form as a compact row ([transcript.md](transcript.md#questions-from-the-agent)).
- The form is asked one step at a time. A choice field followed by an optional text field is one step: the choices,
  and the composer's text as the "Other" answer, which joins or replaces the pick as the agent reads it. Any other
  field is a step of its own. Steps are grouped from the form's schema alone, never from an agent's field names
  (VISION principle 8), in the order of the field names with numbers compared by value (`q_2` before `q_10`).
- The dock shows, top to bottom: the form's message in small secondary text when the step has a question of its own;
  the step's title (the field's title, else its name, with ` (required)`), `1 of 3` while the form has several steps,
  and `Skip`; the step's question (the field's description, else the form's message); its choices; its errors in red
  (on the last step also those of fields no step shows, as `<name>: <error>`).
- A choice is a row with its number (1–9), a radio or checkbox mark, the title and the agent's description in secondary
  text; the picked one has a tinted background. A click picks it; a multiple choice toggles. A field that is neither a
  choice nor text (a toggle) shows its control instead.
- **The composer's text is the step's text answer.** Its placeholder is that field's description (else its title, else
  `Your answer`); on a step without a text field it is read-only and reads `Return continues`. The accessibility label
  is `Answer` instead of `Message`. An optional text left empty is left out of the response. The draft the user had,
  text and attachments, is set aside and comes back when the form is answered, declined or cancelled; a queued
  message cannot be edited meanwhile.
- **Keys.** Return answers the step and moves to the next; on the last step it sends the response (Next and Answer).
  Return never queues while a form waits ([queue.md](queue.md)). ⇧Return and ⌥Return insert a line break. In an
  empty composer, 1–9 pick a choice and ↑ ↓ move a single choice (from none, ↓ picks the first and ↑ the last); once
  text is typed, digits and arrows edit it. Escape declines the form, as Skip does. ⌘. still stops the turn, which
  cancels the form. ⌘Return and ⇧⌘Return do nothing.
- Skip and Escape decline the form (the agent reads that the user skipped); Stop, a withdrawn request, a failure and
  the end of the turn cancel it. Validation (patterns, limits, required fields) is the form's as before.
- The dock never takes focus. VoiceOver reads it as `Question 1 of 3 <title>: <question>` and announces that when a
  step appears; each choice is a button read as its title and description, marked selected when picked, with the hint
  `Press 1 to choose`.

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

- 2026-11-09, #326: an agent's questions dock in the composer and are answered one step at a time; Return reads Next
  or Answer and never queues while a form waits; Stop no longer replaces the round button while a form waits.

- 2026-11-09, #222: the context ring before the Send options, from 70 % of the context window.
- 2026-11-09, #221: the status line counts the plan's completed entries and names the one in progress.
- 2026-11-08, #276: one control row in the draft and the session; booleans are toggle pills instead of checkboxes;
  options that do not fit move into a `…` menu; the status line sits directly above the card.
- 2026-11-08, #271: the mode pill opens a popover with the agent's descriptions instead of a menu.
- 2026-11-08, M18: planned changes added from the owner's first-use feedback.
- 2026-11-08, #261: summarised from ADR-0018, ADR-0019 and ADR-0039 (Composer, amendment of 2026-11-02), checked
  against main at c65b8a1.
- 2026-11-08, #288: the mode popover is as tall as its rows (a described row is taller than a plain one), up to 360 pt,
  so two modes leave no empty space under them.
- 2026-11-08, #267: the Continue card shows the last confirmed settings and the retained queue above it.
