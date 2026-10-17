# 0028. Send the queue when Command-Return has no draft

- Status: Accepted
- Date: 2026-10-17
- Decider: Project owner
- Scope: #39 manual acceptance; supersedes in part ADR-0010 and ADR-0021's Command-Return behavior

## Context

Command-Return sends the current draft immediately. With an empty composer and a retained queue,
the shortcut currently does nothing. The owner requested that it send the queued messages instead.

## Decision

- With an empty draft, Command-Return sends the whole queue using the existing explicit send-now
  path, including while the queue is paused or a turn is running. Whitespace-only text is empty;
  attachments make a draft nonempty.
- With a nonempty draft, Command-Return keeps sending only that draft and leaves the queue in place.
- Command-Shift-Return keeps sending the whole queue with a nonempty draft appended last.
- With neither a draft nor queued messages, no request is sent. Existing steering, persistence and
  queue-pause semantics remain unchanged; this adds no automatic dispatch or retry.

## Alternatives

Keeping Command-Return inactive requires the user to switch shortcuts after clearing the composer,
despite queued messages being ready to send. Replacing it with queue-only sending would lose the
existing draft-only action. The empty-draft fallback preserves both uses.

## Consequences

Composer keyboard handling and its send menu use the same Core submission policy. Tests cover idle
and running sessions, queued message identity and attachments, and unchanged draft-only sending.
