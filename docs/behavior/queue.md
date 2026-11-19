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
- **Return never queues while an input form waits.** The turn waits for the form, so a queued message would wait for a
  turn that cannot end. While a form is docked in the composer ([composer.md](composer.md#docked-questions)), Return
  answers it and the draft is set aside until the form is answered, declined or cancelled.
- The round button says what Return will do: an arrow alone for `Send`, the arrow with `Queue` beside it when the draft
  will be queued, `Save` while editing a queued message, `Next` or `Answer` while an input form is docked, and a stop
  symbol (`Stop`, ⌘.) while a turn runs or is stopping and the draft is empty. Help texts: `Send the message (Return)`, `Queue the message until
  the agent is ready (Return)`, `Save the queued message (Return)`, `Stop the current turn (⌘.)`.
- Send and Queue are disabled for an empty draft. A draft is empty when it has no attachments and its text is only
  whitespace. Send, Queue and the Send options items are also disabled while a config option change is being confirmed.
- When a turn ends normally, all queued messages go to the agent together as one prompt. The transcript shows them as
  separate messages captioned `sent together`. Settings picked during the turn are applied first; they belong to the
  session, not to a queued message.
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
- Both send items are disabled when there is neither a draft nor a queued message, while a queued message is edited,
  and while an input form is docked.
  Both work while the queue is paused.
- Sending now while a turn runs is steering. Every agent today is steered by interrupting: the running turn is
  cancelled and ends with a plain hairline, and the new prompt, labelled `↪ Steer` above its bubble
  ([transcript.md](transcript.md#interruptions-and-errors)), starts once the cancellation has settled.
  Agents keep the changes they already made. A steering interrupt does not pause the queue, so entries left behind by
  `Send Draft Now` drain when the new turn ends. If the interrupted turn ends with an error, the steering prompt is
  still sent. ([ADR-0010](../adr/0010-prompt-queue-and-steering.md) and ADR-0021 also allow inserting the message into
  the running turn without interrupting it; no current agent connection offers that.)

## Queue rows and header

- The header reads `Queued messages`, or `Queue paused` while the queue is paused. A paused queue shows a `Resume Queue`
  button (help `Resume queued messages (⇧⌘R)`), disabled while the session is stopping.
- Each row shows the message text on up to two lines (`Attachments` when it has no text) and, under it, each
  attachment's name with a paperclip. The list is as tall as its rows up to 180 pt, then scrolls; a tall window gives
  it no extra height.
- Each row has icon buttons `Edit queued message`, `Move queued message up`, `Move queued message down` (disabled at the
  ends) and `Delete queued message`. Delete takes effect at once, without confirmation; it is disabled on the row whose
  message this window's composer is editing. The buttons are hidden while a send is being accepted.
- Every edit, move and delete is written to the event log; queued messages keep their identity and attachments.

## Editing a queued message

- Edit, or ↑ in a completely empty composer (which recalls the last queued message), puts the message into the composer.
  The line `Editing queued message · Return saves` and a `Cancel Edit` button appear above the text.
- Only the text can change: the attachments stay with the message and cannot be removed or added while editing.
- Return (`Save`) writes the new text; Cancel Edit discards it. Either way the composer gets back the draft it had
  before editing started. ⌘Return and ⇧⌘Return do nothing while editing, and Cancel Edit is disabled while a Save is
  being written.
- **An open edit holds the queue.** While a queued message is edited, the end of a turn does not send the queue; the
  header reads `Queue waits for your edit` (`Queue paused` still wins while the queue is paused). Save or Cancel Edit
  releases the hold and the queue drains as the turn's end would have, together and with the message in its place.
  The hold counts the open edits, so with the session in two windows the queue waits for both. Showing another session
  or the New Session draft in the window, closing the window and the end of the session release it; returning to a session whose message is
  still queued holds it again. The hold is not stored.
  *Why:* correcting a message queued while the agent works is the main use of the edit, and the turn can end at any
  moment.
- The hold does not stop explicit sends: Send Queue Now and Send Whole Queue Now from another window still send. Once
  the edited message leaves the queue (sent from another window, sent by a turn that started before the edit, or
  deleted in another window), the edit becomes an ordinary draft: the typed text stays, followed by the draft the edit
  replaced; the message's attachments are not kept. A line replaces the editing line until the draft is sent, emptied
  or another edit begins: `The message was already sent; your edit is now a draft` for a sent message, `The message was
  removed from the queue; your edit is now a draft` for a deleted one. The edit stays a draft even if Stop then returns
  the message to the queue, so both are kept. No error is shown and nothing is lost.

## Pausing

The queue pauses, and no queued message is sent automatically, when:

- the user stops the turn (Stop, ⌘. in the composer or the Session menu, or the round button), even if nothing was
  queued; none of them does anything while Stop is unavailable, such as on an idle session;
- the turn ends with a refusal;
- the agent answers the prompt with an error ([ADR-0027](../adr/0027-recoverable-prompt-errors.md));
- the agent refuses a settings change picked during the turn when it is applied at the turn's end
  ([composer.md](composer.md#session-settings)), so no queued message goes out with the old settings;
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
- A saved session opens read-only, with the Continue card in place of the composer. Its retained queue shows above the
  card, read-only, captioned `Queued · sent after Continue`, without edit, move or delete buttons; it is read from the
  session's history, and a session that cannot continue (merged, discarded) does not show it. After
  Continue, retained entries stay paused until the user resumes or sends them; an empty queue starts unpaused
  ([ADR-0017](../adr/0017-continue-saved-sessions.md), ADR-0029).
- The sidebar row of an idle session with a paused, nonempty queue reads `Queue paused`; after a prompt error it reads
  `Prompt failed` instead. Neither moves the row ([sidebar.md](sidebar.md)).

## Changes

- 2026-11-19, #397: settings picked during a turn are applied before the queue drains; a refused one pauses the queue.
- 2026-11-19, #416: the list takes its rows' height up to 180 pt instead of a share of the column's height, which left a
  blank area under a short queue and scrolled a longer one early.
- 2026-11-19, #390: an open edit holds the queue, the header reads `Queue waits for your edit`, and an edit whose
  message was sent anyway becomes a draft instead of being dropped.
- 2026-11-19, #390 (review): a message deleted in another window gets its own line; Delete is disabled on the row being
  edited, Cancel Edit while a Save is written, and the New Session draft releases the hold.
- 2026-11-09, #340: steering shows the new prompt with a `↪ Steer` label and ends the interrupted turn with a plain
  hairline, instead of the `Interrupted` notice shown when the stop was requested.
- 2026-11-09, #326: Return never queues while an input form waits; the round button reads `Next` or `Answer` instead,
  and the send items are disabled.

- 2026-11-08, #261: summarised from ADR-0010, ADR-0021, ADR-0027, ADR-0028, ADR-0029 and ADR-0039, checked against main
  at c65b8a1.
- 2026-11-08, #267: a saved session shows its retained queue read-only above the Continue card.
- 2026-11-08, #263: ⌘. in the composer and the round button follow Session → Stop: nothing happens while Stop is
  unavailable, so an idle session's queue is not paused.
