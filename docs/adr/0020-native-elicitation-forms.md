# 0020. Native elicitation forms

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Scope: native elicitation forms (#24); builds on ADR-0005, ADR-0009 and ADR-0017

## Context

The ACP layer models elicitation forms, but live sessions disable the capability and the default
delegate declines requests. Forms need to coexist with permission requests and continued typing,
and their history must remain meaningful after the connection has ended.

## Decision

- Render each form as a transcript card using native controls, field validation and Submit, Decline
  and Cancel actions. Multiple requests can coexist; the composer remains accessible.
- Support the form field types represented by the pinned ACP schema: text, number, integer, boolean,
  single choice and multiple choice. Respect required fields and applicable constraints; do not
  silently submit unsupported required fields.
- Advertise form elicitation when the complete request/response path is implemented. URL elicitation
  remains separate work and is not advertised by this feature.
- Record the request before displaying it and the final response before returning it to the agent.
  Form drafts are temporary UI state; submitted values and the final outcome are durable events.
- `SessionController` owns pending requests and their cancellation, following the existing permission
  lifecycle. Stop, cancellation, failure and close must settle affected requests without leaving
  suspended callers or accepting stale answers.
- Saved history is read-only. Forms left unanswered when a session ended are shown as cancelled;
  continuing the session records their cancellation before accepting new interaction, following the
  interrupted-request recovery pattern in ADR-0017. Reading history alone writes no events.

## Alternatives

- **A sheet per request:** a familiar form presentation, but blocks access to the session and makes
  simultaneous requests harder to manage. Transcript cards preserve context and access to the composer.
- **Persist every draft edit:** preserves unfinished typing, but adds events and recovery behavior
  for a request that cannot survive its original connection. Deferred.

## Consequences

The transcript preserves submitted answers and outcomes. Reopening history never revives a request
to a disconnected agent. Forms extend the existing controller and reducer instead of introducing a
separate session owner or persistence store.
