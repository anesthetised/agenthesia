# 0017. Continue saved sessions

- Status: Accepted
- Date: 2026-10-15
- Decider: Project owner
- Supersedes in part: [0014](0014-window-bound-live-sessions.md) (saved history no longer stays
  disconnected)
- Scope: session resume and load (#25); builds on [0005](0005-event-log.md)

## Context

ADR-0005 decides how a saved session reattaches: `session/resume` when the agent supports it, otherwise
`session/load` with the replayed updates suppressed, otherwise read-only. The ACP layer implements this
as `AgentConnection.reopenSession`. ADR-0014 left saved history read-only after restart, so nothing in
Core or the app uses it yet.

Reconnecting has to settle what triggers it, what to do with a log that ends in the middle of a turn,
who may write to a session's log, and what happens when the session's environment is gone.

## Decision

- **Explicit trigger.** Saved history opens read-only, as today. A Continue action reattaches it; viewing
  history never starts an agent.
- **Same window owner.** Continuing replaces the window's live session, like starting a new one
  (ADR-0014). It reuses the session's agent install and working directory; it does not create a
  workspace.
- **One owner per session.** `SessionLibrary` tracks the sessions that have a live owner in this app.
  Continue is unavailable for a session that is live in another window. Two app instances are not
  guarded against.
- **Close what a crash left open.** Once the agent accepts the reattach, the controller appends
  `failed` for a turn without an outcome and `permissionResolved(.cancelled)` for requests without a
  response, before any new event. Read-only viewing and failed attempts write nothing.
- **Marker event.** A successful reattach appends `SessionEvent.reopened` with the session's config
  options and whether it was resumed or loaded. It serves as the new baseline, like `started`, and the
  transcript shows it as a divider.
- **Failure leaves history readable.** A missing working directory or agent executable, an agent that
  can neither resume nor load (`.unavailable`), or a failed request ends the process, keeps the session
  read-only, and explains why.
- **Additional directories are not restored.** The session record does not store them and the window does
  not pass them yet; a continued session runs without them.

## Alternatives

- **Reconnect on opening history:** fewer clicks, but starts an agent process for every look at history.
  Rejected.
- **Close open turns on quit:** covers orderly quits only; a crash still leaves an open turn, so the
  reopen path is needed anyway.
- **File lock per session:** also guards against a second app instance, at the cost of more code and
  tests. Revisit if several instances become a supported setup.
- **Recreate a missing worktree from its branch:** belongs with worktree lifecycle (M8).

## Consequences

- Sessions survive app restarts for agents that support resume or load.
- With `session/load`, the agent's memory of the conversation can differ from the log, for example a turn
  the app recorded as interrupted. The log stays the source of truth for display (ADR-0005).
- Sessions started with additional directories lose them when continued, until the record stores them.
