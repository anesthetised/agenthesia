# 0029. Empty queues do not block fresh prompts after recovery

- Status: Accepted
- Date: 2026-10-17
- Decider: Project owner
- Scope: #39/#117 manual acceptance; partially supersedes ADR-0010, ADR-0021, ADR-0027 and ADR-0028
  on empty paused queues and explicit sends

## Context

After a prompt error or Continue, a retained pause keeps placing fresh drafts into the queue even
when it is empty. Explicitly sending those drafts or flushing the queue does not remove the pause.
The owner considers this persistent queueing a bug and chose to protect retained work while letting
fresh prompts use an empty queue normally.

## Decision

- Return sends immediately when the session is idle and the queue is empty, including after Stop,
  an error or Continue. That explicit fresh send durably clears the empty queue's pause.
- Continue keeps retained queued entries paused. With no retained entries it clears the pause as part
  of the successful reattach baseline. It never automatically retries the failed prompt.
- Explicit send-now clears the pause when it sends the last queued entry, or sends a fresh draft with
  no queued entries. Record the unpause with prompt admission/dequeue in the same event batch.
- A draft-only send that leaves old queued entries retains their pause. Return while working still
  queues a new draft; only an unpaused queue drains after the active turn finishes.
- Stop that races an explicit send retains priority, including while waiting for an injection
  acknowledgement. Persistence failures remain fatal; a stopped pre-wire prompt still returns its
  content to the queue with its original identity.
- Show Send for an idle session with an empty queue. An empty pause must not advertise that Return
  will queue the next draft.

## Alternatives

Keeping an empty queue paused requires a separate Resume Queue action after recovery and after each
explicit send; rejected by manual acceptance. Always resuming on Continue would execute retained
messages without an explicit decision; the owner chose to keep those entries paused instead.

## Consequences

Fresh drafts work after recovery, and explicitly draining the queue restores ordinary sending.
Retained messages still require Resume Queue or an explicit send. No new event type or schema change
is needed. Regressions cover repeated Return after a prompt error/Continue, durable unpause, retained
queues and attachments, injection acknowledgements, Stop races and write failures.
