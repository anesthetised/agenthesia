# Prompt queue

Each live session has its own prompt queue: messages typed while the agent cannot take them yet wait there, in order,
until the current turn ends or the user sends them explicitly. The queue sits at the top of the composer card, above
the text, and is shown only while it holds messages. The queue belongs to the session record and is stored in its
event log, so it survives a relaunch ([ADR-0005](../adr/0005-event-log.md),
[ADR-0021](../adr/0021-prompt-queue-lifecycle.md)).
The composer itself is described in [composer.md](composer.md).

## Send and Queue

- Return sends the draft immediately when the session is idle and the queue is empty; otherwise it adds the draft to
  the end of the queue. ⇧Return and ⌥Return insert a line break.
- The round button says what Return will do: an arrow alone for `Send`, the arrow with `Queue` beside it when the draft
  will be queued, `Save` while editing a queued message, and a stop symbol (`Stop`, ⌘.) while a turn runs, is stopping
  or waits for an input form and the draft is empty. Help texts: `Send the message (Return)`, `Queue the message until
  the agent is ready (Return)`, `Save the queued message (Return)`, `Stop the current turn (⌘.)`.
- Send and Queue are disabled for an empty draft. A draft is empty when it has no attachments and its text is only
  whitespace. Send, Queue and the Send options items are also disabled while a config option change is being confirmed.
- When a turn ends normally, all queued messages go to the agent together as one prompt. The transcript shows them as
  separate messages captioned `sent together`.
  *Why:* the agent sees every follow-up at once instead of answering them one turn at a time.

## Send options and steering

The Send options menu (chevron beside the round button) sends at once instead of waiting. ⌘Return with an empty draft
sends the queue ([ADR-0028](../adr/0028-empty-draft-sends-queue.md)):

| Item | Shortcut | Sends |
|---|---|---|
| `Send Draft Now` | ⌘Return | Only the draft; queued messages stay where they are |
| `Send Queue Now` | ⌘Return | The whole queue; shown instead of the item above when the draft is empty |
| `Send Whole Queue Now` | ⇧⌘Return | The whole queue, with a nonempty draft appended last |
| `Stop Turn` | (⌘. in the Session menu) | Listed only while Stop is available |

- While a turn runs, is stopping or waits for an input form, the first item reads `Send Draft Now (Interrupts Turn)` or
  `Send Queue Now (Interrupts Turn)`.
- Both send items are disabled when there is neither a draft nor a queued message, and while a queued message is edited.
  Both work while the queue is paused.
- Sending now while a turn runs is steering. Every agent today is steered by interrupting: the running turn is
  cancelled, the transcript shows an `Interrupted` notice, and the new prompt starts once the cancellation has settled.
  Agents keep the changes they already made. A steering interrupt does not pause the queue, so entries left behind by
  `Send Draft Now` drain when the new turn ends. If the interrupted turn ends with an error, the steering prompt is
  still sent. ([ADR-0010](../adr/0010-prompt-queue-and-steering.md) and ADR-0021 also allow inserting the message into
  the running turn without interrupting it; no current agent connection offers that.)

## Queue rows and header

- The header reads `Queued messages`, or `Queue paused` while the queue is paused. A paused queue shows a `Resume Queue`
  button (help `Resume queued messages (⇧⌘R)`), disabled while the session is stopping.
- Each row shows the message text on up to two lines (`Attachments` when it has no text) and, under it, each
  attachment's name with a paperclip. The list scrolls past 180 pt.
- Each row has icon buttons `Edit queued message`, `Move queued message up`, `Move queued message down` (disabled at the
  ends) and `Delete queued message`. Delete takes effect at once, without confirmation. The buttons are hidden while a
  send is being accepted.
- Every edit, move and delete is written to the event log; queued messages keep their identity and attachments.

## Editing a queued message

- Edit, or ↑ in a completely empty composer (which recalls the last queued message), puts the message into the composer.
  The line `Editing queued message · Return saves` and a `Cancel Edit` button appear above the text.
- Only the text can change: the attachments stay with the message and cannot be removed or added while editing.
- Return (`Save`) writes the new text; Cancel Edit discards it. Either way the composer gets back the draft it had
  before editing started. ⌘Return and ⇧⌘Return do nothing while editing.
- If the message is sent while another session is shown, the edit is dropped when the window returns to this session.

## Pausing

The queue pauses, and no queued message is sent automatically, when:

- the user stops the turn (Stop, ⌘. in the composer or the Session menu, or the round button), even if nothing was
  queued; none of them does anything while Stop is unavailable, such as on an idle session;
- the turn ends with a refusal;
- the agent answers the prompt with an error ([ADR-0027](../adr/0027-recoverable-prompt-errors.md));
- the connection or the agent process fails.

A turn that ends by hitting a limit (`max_tokens`, `max_turn_requests`) does not pause the queue.
*Why:* after Stop or an error the user decides what runs next ([ADR-0021](../adr/0021-prompt-queue-lifecycle.md)).

A prompt that Stop catches before it reached the agent goes back to the front of the queue, and its transcript rows are
captioned `not sent`.

## Recovery

- After a prompt error the session stays live and idle: same agent process, connection and workspace. The failed prompt
  stays in the transcript and is not put back in the queue or retried. Remaining entries stay queued and paused.
- Resume Queue (button or Session → `Resume Queue`, ⇧⌘R) clears the pause. When idle, the queue is sent at once; while a
  turn runs, it drains when that turn ends. The menu item is enabled for an idle or running session with a paused
  queue, also when that queue is empty.
- An empty queue never holds back a fresh prompt: after Stop, an error or Continue, Return on an idle session with an
  empty queue sends immediately and clears the pause ([ADR-0029](../adr/0029-empty-queue-recovery.md)).
- With entries still queued and paused, Return queues the new draft behind them. Sending a draft now leaves them paused;
  sending the last queued entry now (Send Queue Now, Send Whole Queue Now) clears the pause.
- A saved session opens read-only, with the Continue card in place of the composer, so its queue is not shown. After
  Continue, retained entries stay paused until the user resumes or sends them; an empty queue starts unpaused
  ([ADR-0017](../adr/0017-continue-saved-sessions.md), ADR-0029).
- The sidebar row of an idle session with a paused, nonempty queue reads `Queue paused`; after a prompt error it reads
  `Prompt failed` instead. Neither moves the row ([sidebar.md](sidebar.md)).

## Changes

- 2026-11-08, #261: summarised from ADR-0010, ADR-0021, ADR-0027, ADR-0028, ADR-0029 and ADR-0039, checked against main
  at c65b8a1.
- 2026-11-08, #263: ⌘. in the composer and the round button follow Session → Stop: nothing happens while Stop is
  unavailable, so an idle session's queue is not paused.
