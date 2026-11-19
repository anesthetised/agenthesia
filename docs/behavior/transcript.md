# Transcript

The conversation of a session fills the center of its window: one row per message, tool call or notice, in a column
at most 720 pt wide that the composer card below it shares ([ADR-0039](../adr/0039-t3-style-window-layout.md)). This
document covers how rows are laid out, selected and copied, how the keyboard moves through them, how tool calls, the
agent's thoughts and a finished turn's work show and fold, and how Find and following the end work.

## First message of a starting session

While a session started from the draft is starting, its first message is the transcript's only row, before the session
has a transcript ([session-start.md](session-start.md), *While starting*). It is rendered by the same table from a
one-item source, with the user's bubble and the attachments as placeholders, so it keeps its place when the session's
own first row replaces it.

## Prompts the user did not send

A turn started by another session through the app's tools ([ADR-0049](../adr/0049-built-in-agenthesia-mcp-server.md))
is never shown as the developer's message: its prompt is a left-aligned row with a quiet label instead of the user's
bubble, the label being where it came from:

| Origin | Label |
|---|---|
| `session_send` from another session | `From <title> · <agent>`; `From another session` when that session is not open in this launch, and `From another session · <agent>` while it has no title |
| A delegated task, in the child session | `Delegated task` |
| A delegated task's result, in the parent | `Delegated result` |
| A finished `task_run` command | `Background task` |

- The label sits where a card's title does (small, semibold, secondary); the text below it is plain, never linked, as
  in the user's bubble. A steering prompt ([below](#interruptions-and-errors)) adds `· Steer` after its origin, as
  `From Fix CI · Steer`. Copy returns the message alone, and `not sent` and `sent together` captions still apply.
- The agent receives such a prompt marked as coming from another agent session, which stays anonymous to it: the
  receiver is not told the sender's title or agent.

## Questions from the agent

- An input form ([ADR-0020](../adr/0020-native-elicitation-forms.md)) is answered in the composer
  ([composer.md](composer.md#docked-questions)). While it waits, its row is compact: `Input` and `Asked 2 questions ·
  answer below` (`Asked 1 question`), counting the composer's steps.
- Once the form is answered, declined or cancelled, it is **one row like a tool row**, as in T3 Code: the disclosure,
  a question icon, the questions in secondary text joined with ` · `, then the answers in primary text joined with
  ` · `; both truncate at the end of the line, the questions first. A declined form reads `Declined` in place of the
  answers, a cancelled one `Cancelled`, and `Recording answer…` shows until the response is stored. A form of a saved
  session that was never answered reads `Cancelled`.
- Expanded, the row lists each question in secondary text with its answer indented below it (12 pt), and the answers
  in the heading turn secondary too. A step without an answer shows only its question.
- Questions and answers follow the composer's steps ([composer.md](composer.md#docked-questions)), never raw field
  names: a step's question is its first field's description, else its title, else its name. A choice reads as its
  title; the step's text, when given, replaces the pick, as the adapter's custom field means; a multiple choice joins
  its picks with `, `; a toggle reads `Yes` or `No`.
- The row is never folded into a group of tool calls, and it stays outside a finished turn's fold
  ([below](#finished-turns)). Copy returns each question with its answer on the next line,
  indented by two spaces, the steps separated by a blank line, then `Declined` or `Cancelled` when the form was not
  submitted.

## Permission records

- A permission request is a one-line record in the transcript, folded to its header (the outcome, then what was asked)
  with a `Details` disclosure. Expanded, it shows the call with its outcome, and for a shell call the whole command in a
  code block below the title, while the request is waiting too (#375). A waiting request shows the command of its
  call as it is now, which includes a `rawInput` that arrived after the request.

## Interruptions and errors

- A turn the user stopped (Stop, ⌘.) ends with a thin centered divider, as in T3 Code: a hairline, an X symbol,
  `Run interrupted · Stopped by user` in small red type (`Run interrupted` in medium weight, the rest dimmed), a
  hairline; no box, no Copy button.
- A prompt sent now while a turn runs (steering: Send Now, ⌘Return; [queue.md](queue.md)) is the user's ordinary
  bubble with `↪ Steer` (the `arrow.uturn.right` symbol and `Steer`, small, semibold, secondary) right-aligned directly
  above it, as in T3 Code; every message sent now together carries it. The turn it interrupted ends with a plain
  hairline across the column: no text, no symbol, no red, nothing for VoiceOver or Copy.
- The divider and the hairline sit where the turn ended, after anything the agent sent while the stop settled. A turn
  that finished on its own before the stop reached the agent, or that ended because the session was closed, has
  neither; a prompt sent now is a steer even when the turn it meant to interrupt finished first. A steering prompt
  that never went out, because the user stopped meanwhile, leaves no label on the next one.
- Which it was comes from the stored events: steering records `interrupted` with its stop request, Stop does not.
- A failed turn's error is a row with a red alert symbol and a bold red `Error` label, and the message below it in the
  primary text color at 80 % opacity, wrapping. Its Details disclosure, when the stored text says more than the
  message, still shows that text, and Copy still returns what the row shows.
- VoiceOver reads the divider as one element with its text, a steer's bubble as one element, `Steer, <text>`, and the
  error as one element,
  `Error: <message>`, with the row's `Copy` and, when there is more to show, `Details` (`Hide details`) as actions.

## Thoughts

The agent's thoughts are collapsed ([ADR-0039](../adr/0039-t3-style-window-layout.md), amendment of 2026-11-07). A
thought is one row with a disclosure, like a tool card: a brain icon and one line of small secondary text, no body.

- While the agent is thinking (the thoughts end the transcript of the running turn), the row reads `Thinking…` followed
  by the last line of the latest thought so far, without code and bold marks and truncated at the column's edge. It
  changes with every streamed chunk.
- Once the agent moves on, the row reads `Thought for 12s` (`1m 12s`, `1h 2m` as the working line words them): the time
  from the first thought chunk to the next item of another kind, or to the end of the turn when nothing follows it.
  The time comes from the stored events' timestamps, so a saved transcript shows it too. Updates that are not items,
  such as the plan or context usage, do not end a thought.
- Consecutive thoughts fold into one row, as consecutive tool calls do, and its time is their sum. A tool call, a
  message or any other item ends the run.
- The disclosure expands the row: the full text of its thoughts below the header, dimmed (65 % opacity, so the code
  colors of their Markdown stay), separated by a blank line. While expanded and thinking, the header reads only
  `Thinking…` and the text streams below it. The row is collapsed by default and keeps its expansion while more
  thoughts stream into it, as a tool card keeps its own.
- Find in Transcript searches the full text of every thought, collapsed or not; stepping to a match in a collapsed row
  expands it, selects it and marks the match.
- Copy returns the full text of the row's thoughts, whether the row is collapsed or expanded: the hover `Copy` button
  in its header, the `Copy` accessibility action and ⌘C on a table selection, which copies the row once.
- VoiceOver reads the header text; the disclosure is `Show all` when collapsed and `Show less` when expanded.

## Finished turns

When a turn ends on its own, its work folds into one row, as in T3 Code: everything between its prompt and its answer
(the last agent message) collapses under `Worked for 1m 3s`.

- The row sits directly below the prompt (below the last of prompts sent together): `Worked for` and the turn's time
  in secondary text with tabular digits, then a small chevron (`chevron.right` collapsed, `chevron.down` expanded),
  over a hairline across the column. The time runs from the turn's prompt to its end, by the stored events'
  timestamps, and reads as the working line does (`12s`, `1m 3s`, `1h 2m`), so a saved session shows it too.
- It hides tool calls and groups, thoughts, permission records, earlier agent messages and any work after the answer.
  The answer stays open below it, and so do answered questions, in their place. A turn without an answer folds all its
  work; a turn with nothing to hide gets no row.
- Nothing folds while the turn runs: the row appears when it ends. A turn stopped with Stop, interrupted by a steer
  or ended by an error never folds, so the divider, the hairline or the error stays below its work in view.
- Clicking the label or the chevron expands the turn: its rows appear below the row as they show today (groups and
  thoughts keep their own disclosures) and the chevron points down; clicking again folds them. Each turn remembers its
  own expansion, also while a later turn streams. Turns are collapsed when a session opens.
- Find in Transcript searches the folded work; stepping to a match inside a collapsed turn expands it, then the row
  that holds the match as for thoughts and groups. Stepping to the answer or a question leaves the turn folded.
- The row has no Copy: it is not copied from a selection, has no hover button and no `Copy` action. The rows inside an
  expanded turn select and copy as before.
- VoiceOver reads the row as a disclosure triangle labelled `Worked for 1m 3s`, collapsed or expanded.

## Rows

- Rows lie in the same column as the composer card: centered, at most 720 pt wide, with at least 24 pt on each side.
- A user message is a bubble at the column's trailing edge, in the quiet `.quaternary` fill with rounded corners, that
  hugs its text and stops at 80 % of the column; a caption under it (`not sent`, `sent together`) is right-aligned.
  Agent messages have no role label, and tool, permission and question rows keep their headers.
- A row's Copy button shows only while the pointer is over the row; VoiceOver gets the same action as a custom
  action.
- Session notices (continued, ended, merged, discarded, pull request opened) are a centered caption between two
  hairlines, with no label and no Copy. After a Continue the transcript shows a `Continued · <date and time>` divider.

## Tool calls

- A tool call is a card: a header (the kind's symbol, the kind, the status, a disclosure) and a body with the title,
  the reported locations and the text content. Selecting and copying the body works as for messages. A status the agent
  did not report reads `Status not reported`; content the app cannot show is a placeholder, never dropped silently.
- Two or more consecutive tool calls fold into one row, `Ran 3 commands, made 2 edits`, worded from the ACP tool
  kinds, with `· 1 failed` in the failure color. While the session runs and the group's last call is pending or in
  progress, the row shows that call's title instead (`just test…`). It is collapsed by default; its disclosure expands
  the cards below it as rows. Any other item, a permission request or a form included, ends a group; a single call
  stays a plain card.
- A diff shows its path and unified hunks with three lines of context in a code block, with added and removed lines
  tinted and the words that changed between adjacent lines marked (not for runs over 200 lines). An edit with more than
  1,000 unmatched lines shows as a whole replacement. There are no side-by-side diffs.
- A command's output replaces the terminal placeholder: text without escape sequences, in a code block with the exit
  status; collapsed, it keeps the last lines. A body of more than 12 lines or 2,000 characters is collapsed, and its
  expansion survives streamed updates. A header-only update leaves the body and its text selection alone.
- A tool row whose call has a pending permission request leaves its diff out and shows it again once the request is
  answered.
- Paths in a tool call's locations and diffs, and inline code in agent messages and thoughts that names a file of the
  session, are links that open the file ([file-pane.md](file-pane.md)); Copy still returns the plain Markdown.
  Streaming rows and the user's prompts are not linked.
- A permission request's record names what the agent offered and what was answered. The agent's own "always" options
  are listed as the agent returned them, labeled as remembered by the agent, and Agenthesia keeps no permission policy
  of its own. An answered record states only the recorded response (the option's name and kind, or cancellation), never
  an inferred approval or decline; a request without a recorded response after a restart says so.

## Find in the transcript

- ⌘F opens the find bar; ⌘G steps to the next match, ⇧⌘G to the previous one, ⌥⌘G to the next failed tool call.
- Find reads the full text of every row, so it finds what a folded group, a collapsed card or a folded turn does not
  show. Matches are rows, not occurrences.
- Typing counts the matches and marks them in the visible rows, 150 ms after the last key. Only Return or a step
  expands the group, card or turn that hides the match, scrolls to its row and selects it. A row that is still
  streaming is marked once it finishes.

## Following the end

- While a turn streams, the transcript follows its end. Scrolling up, or the keys of
  [keyboard navigation](#keyboard-navigation), stops it; reaching the end again resumes it.
- When the reader scrolled up and the end then grew, a `New response below` capsule appears at the bottom edge of the
  transcript, above the status line. Scrolling up alone does not show it.
- Clicking the capsule, or Session → Jump to Latest (⌥⌘↓, disabled while following), scrolls to the end without
  animation and resumes following. ⌘↓ stays with the composer's text.

## Row selection

- Clicking a row selects it; ⇧-click and ⌘-click extend the selection to a range and toggle single rows, as in any
  table. Several rows can be selected at once.
- A selected row gets a quiet background: the color of `.quaternary` fills (`NSColor.quaternarySystemFill`), in
  a rounded rectangle (10 pt radius) as high as the row, behind its content, and 8 pt wider than the text column on each
  side so the text does not touch its edge (the column's margin keeps it inside the window). There is
  no system selection band across the window, whether or not the window is key.
- The text of a selected row keeps its normal colors: status labels such as `1 failed` stay red, the running status
  keeps the accent color. Nothing turns white.
- The background fades in and out in 0.12 s when a row on screen is selected or deselected, and appears and
  disappears at once under Reduce Motion. Rows that are created already selected (after scrolling or a rebuild) show
  the background at once.
- The system adapts the fill to light and dark appearance and to Increase Contrast.
- Find in Transcript (⌘F) selects the row of the current match and scrolls to it.
- VoiceOver reports the selection as it does for any table row; the background is not an accessibility element.

*Why quiet:* the system band is a saturated bar across a window whose content is a 720 pt column, and it recolors
the text; a selection here marks which message ⌘C or a keystroke acts on, not a state to read at a glance.

## Copy

- ⌘C (Edit → Copy) with rows selected puts them on the pasteboard as Markdown, whole rows in transcript order,
  separated by a blank line.
- An answered question copies its questions and answers ([above](#questions-from-the-agent)). A tool call row copies
  its output, and a folded summary of several calls copies what its cards hold. A row of thoughts copies their full
  text, collapsed or not. When a summary
  and some of its expanded cards are both selected, the cards are copied once. A finished turn's `Worked for` row
  copies nothing.
- Pointing at a row shows a `Copy` button in its header (tooltip `Copy message as Markdown`) that copies that one
  row; VoiceOver gets the same action as a custom action `Copy` on the row. It is a small bordered button in the
  system's label colors, readable on the selection in light, dark and Increase Contrast.

## Keyboard navigation

- ↑ and ↓ move the selection by one row, ⇧↑ and ⇧↓ extend it; Page Up, Page Down, Home and End scroll by a page
  or to the start or end of the transcript. These are the table's own keys.
- Any of these keys, like scrolling with the wheel or trackpad, stops the transcript from following the end of a
  running turn; reaching the end again resumes it.

## Changes

- 2026-11-19, #388: tool calls and groups, notices, Find and following the end moved here from ARCHITECTURE.md.
- 2026-11-10, #375: an expanded permission record shows a shell call's whole command.
- 2026-11-10, #341: a finished turn's work (calls, thoughts, permission records, earlier agent messages) folds into
  one `Worked for 1m 3s` row with a chevron above its answer; previously every row of a turn stayed open.
- 2026-11-09, #340: an answered, declined or cancelled form is one question row with its answers behind a disclosure
  instead of the `Input` card with raw field names; a stopped turn ends with the red `Run interrupted · Stopped by
  user` divider; a prompt sent now is a bubble labelled `↪ Steer` and the turn it interrupted ends with a plain hairline
  instead of the `Interrupted` notice; a failed turn is a red `Error` row
  instead of `Prompt failed`.
- 2026-11-09, #223: thoughts are one collapsed disclosure row (`Thinking… <last line>`, then `Thought for 12s`), and
  consecutive thoughts fold into it; previously they streamed in full, dimmed, under a `Thinking` caption.
- 2026-11-09, #326: a waiting input form is a compact row; it is answered in the composer instead of in the row.
- 2026-11-09, #225: the first message of a starting session is shown as the transcript's only row.
- 2026-11-09, #311: prompts the user did not send are labelled rows instead of the user's bubble.
- 2026-11-09, #301: a row's hover Copy follows the pointer when a layout moves the row from under it.
- 2026-11-09, #160: a row fits its content again after the transcript changes width, with no empty band above the
  text.
- 2026-11-08, #269: a quiet selection: a rounded `.quaternary` background of the text column's width instead of the
  system band across the window; text keeps its colors; the transcript area written.
- 2026-11-08, #288: the selection background reaches 8 pt past the text column on each side; the hover `Copy` button is a
  small bordered button instead of the inline one, whose light text vanished on the selection in light mode.
