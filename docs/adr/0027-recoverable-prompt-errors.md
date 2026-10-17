# 0027. Keep sessions alive after prompt error responses

- Status: Accepted
- Date: 2026-10-17
- Decider: Project owner
- Scope: #117; narrows the turn-error recovery behavior described by ADR-0021 and the use of
  ADR-0017's Continue flow; clarifies failure status under ADR-0026

## Context

`SessionController.performTurn` currently treats every thrown error as a session failure. It records
the failed turn, closes the connection, and causes `LiveSession` to terminate the agent. Even an
agent's explicit error response requires Continue, which cannot work if the agent supports neither
resume nor load. MockAgent's `fail` command reproduces this with a healthy process.

[JSON-RPC](https://www.jsonrpc.org/specification#response_object) distinguishes an error response to
a request from transport failure. The existing connection preserves that distinction as `RPCError`
versus connection errors. Keeping the session usable after the former is an application policy;
it does not guarantee that the agent will accept the next request.

## Decision

- **Recover the turn.** An error response from the established session's `session/prompt` ends that
  turn unsuccessfully, records its message, pauses the queue, and returns the controller to idle.
  Keep the same process, connection, agent session identifier and workspace. Do not retry, reconnect
  or resend the failed prompt automatically. Apply this to all error-response codes, without
  agent-specific message matching or a retry-code allowlist.
- **Limit the boundary.** Classify the error where `AgentConnection.prompt` returns it. An error
  from event persistence, response decoding, transport, cancellation delivery or another operation
  is not made recoverable merely because it occurs during a turn. Startup, reopen and injection
  behavior remain outside this change. Process exit and fatal failures retain cleanup and Continue.
- **Persist before accepting more work.** Record the queue pause and the existing
  `SessionEvent.failed(id:message:)` through the ordered write path before making the session idle.
  A failed write remains fatal. Cancel the turn's pending permissions and forms through the existing
  durable resolution path. Await admitted cancellation work before another prompt can start.
- **Keep queue semantics.** The failed prompt stays in the transcript; do not put it back in the
  queue, since the agent may already have acted on it. Remaining queued messages and attachments
  stay intact and paused. Return queues a new draft while paused; Command-Return sends the draft
  immediately, and Resume Queue or Command-Shift-Return explicitly dispatches queued work, as in
  ADR-0021. A failed interrupted turn must not silently lose a newer steering draft.
- **Keep terminal states terminal.** A racing Stop, End Session, process exit or persistence failure
  must not be overwritten by recovery to idle. Stop retains its pause and cancellation ordering;
  deliberate close retains cancellation semantics.
- **Presentation.** Show the failed turn in the transcript without a session-ended message or a
  Continue requirement. The failure does not add a successful completion or a new done mark; the
  session becomes idle rather than failed, subject to existing unseen-result state. A structured
  refusal stop reason keeps its existing handling.
- **History.** Reuse the existing failed-turn event: it closes the active turn and displays the
  error; it does not establish that the connection is currently alive or dead. No schema migration
  is needed. Saved history still opens read-only and requires explicit Continue; restored queues
  remain paused. Do not reinterpret old errors as permission to launch an agent.

## Alternatives

- **End every session on an error:** keeps current handling simple, but discards a usable agent and
  prevents recovery for agents without resume/load.
- **Recover only selected codes:** can reserve special handling for known errors, but custom codes
  vary across agents and a code alone does not establish process or connection health.
- **Retry or reconnect automatically:** may repeat partially completed work, incur additional model
  usage, and bypass the user's decision about the paused queue.

## Consequences

The next explicit prompt can use the same session even when resume/load is unavailable. A still-live
agent may reject it again; the user can end the session and start another. No generic retry framework,
new dependency or persistent connection-health state is needed.

Verification must cover error response followed by a successful prompt on the same connection,
paused queues with attachments, explicit queue resume, pending permission/form cancellation, Stop
and steering races, deliberate close, error-record write failure, malformed responses, transport loss
and process exit. Replay must retain the error and pause without an unfinished turn. Keep MockAgent's
`fail` as a recoverable error and add a separate process-exit fixture for the fatal manual check.
