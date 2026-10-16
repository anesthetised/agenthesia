# 0022. Session-scoped elicitation first

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Scope: initial scope of #24; narrows ADR-0020, with request-scoped forms deferred to #111

## Context

The pinned ACP schema allows forms scoped to a session or to an outgoing JSON-RPC request before a
session exists, for example during authentication. The current session record is created only after
`session/new` returns. Waiting for a startup form to be recorded in that session would block the
operation that must create the record. Request-scoped forms also need explicit association with the
originating request and its cancellation lifetime.

## Decision

- The initial native form implementation supports requests scoped to an established session only.
- Explicitly decline request-scoped forms, including pre-session forms. Do not display controls that
  cannot be recorded or whose lifetime cannot be established.
- Keep the session-scoped lifecycle and durability decisions in ADR-0020. Do not add startup
  persistence, a new interaction owner or JSON-RPC request tracking as part of #24.
- Track request-scoped support in [#111](https://github.com/anesthetised/agenthesia/issues/111), with
  separate architectural agreement before implementation.

## Alternatives

- **Support startup forms now:** more complete ACP support, but introduces presentation and durable
  ownership outside the session model. Deferred so it can be designed explicitly.

## Consequences

Agents may use forms within a live session. A form needed before session creation receives a decline,
so agents that require such an interaction may be unable to start until #111 is implemented.
