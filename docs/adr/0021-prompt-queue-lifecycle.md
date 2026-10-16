# 0021. Prompt queue lifecycle

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Scope: prompt queue and steering (#65); clarifies ADR-0010 and builds on ADR-0017 and ADR-0018

## Context

ADR-0010 defines queueing and steering, but leaves manual Stop, recovery and the interaction between
the draft and the queue unspecified. The current controller closes the connection after a turn
error, so resuming a queue may require reattaching the session first.

## Decision

- Preserve ADR-0010: Enter sends immediately only when idle with an empty, unpaused queue; otherwise
  it queues the message. A normally completed turn sends the queued entries together as one prompt,
  while the transcript retains individual messages and identifies the shared send.
- Queue entries retain text and attachments together in the event log. Editing, deleting and
  reordering are durable changes; editing an entry must retain its attachments.
- Manual Stop pauses the queue. It does not trigger an automatic next turn. Error and refusal also
  pause the queue as required by ADR-0010.
- Command-Return sends the current draft now and leaves queued entries in place. Command-Shift-Return
  sends the whole queue now, with the current draft appended last when nonempty.
- Explicit send-now actions use the connection's steering capability: inject when supported,
  otherwise cancel the current turn and wait for cancellation to settle before starting the new one.
  These actions are distinct from manual Stop. Protocol-version decisions remain in ACP adapters.
- Opening saved history restores the queue for display only. After Continue succeeds, require an
  explicit queue resume before sending restored entries. A paused queue on a usable live connection
  can resume directly; a failed connection must be reattached first.
- Keep queue coordination in `SessionController` and durable state in the existing event log and
  reducer. Retain the current ordered write path and ownership of turn/cancellation tasks.

## Alternatives

- **Drain after manual Stop:** mechanically treats cancellation like another turn ending, but starts
  work immediately after the user asked it to stop. Rejected.
- **Drain on reattach:** fewer actions, but can unexpectedly execute old queued work. Explicit resume
  preserves user control.
- **Exclude the draft from send-whole-queue-now:** leaves the latest typed instruction behind.
  Including it last preserves the order in which the user composed the follow-ups.

## Consequences

Stopping work and restoring history cannot silently dispatch pending prompts. Steering, queue drain,
configuration changes and pending user requests share one controller lifecycle; their integration
must be tested together, including persistence failures and cancellation races.
