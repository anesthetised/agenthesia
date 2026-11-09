# Transcript

The conversation of a session fills the center of its window: one row per message, tool call or notice, in a column
at most 720 pt wide that the composer card below it shares ([ADR-0039](../adr/0039-t3-style-window-layout.md)). This
document covers how rows are selected and copied and how the keyboard moves through them, and how the agent's thoughts
show; what the other kinds of row show is not summarised here yet.

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
- The row is never folded into a group of tool calls. Copy returns each question with its answer on the next line,
  indented by two spaces, the steps separated by a blank line, then `Declined` or `Cancelled` when the form was not
  submitted.

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
  and some of its expanded cards are both selected, the cards are copied once.
- Pointing at a row shows a `Copy` button in its header (tooltip `Copy message as Markdown`) that copies that one
  row; VoiceOver gets the same action as a custom action `Copy` on the row. It is a small bordered button in the
  system's label colors, readable on the selection in light, dark and Increase Contrast.

## Keyboard navigation

- ↑ and ↓ move the selection by one row, ⇧↑ and ⇧↓ extend it; Page Up, Page Down, Home and End scroll by a page
  or to the start or end of the transcript. These are the table's own keys.
- Any of these keys, like scrolling with the wheel or trackpad, stops the transcript from following the end of a
  running turn; reaching the end again resumes it.

## Changes

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
