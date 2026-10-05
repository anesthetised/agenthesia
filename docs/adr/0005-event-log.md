# 0005. Event log as the source of truth

- Status: Accepted
- Date: 2026-10-05

## Context

Sessions must survive app restarts and agent crashes. ACP offers `session/resume` (reattach without
replay), `session/load` (the agent replays the full history as updates) and `session/list`; support
varies by agent.

## Decision

- Persist every session as an append-only event log in SQLite (GRDB): raw ACP `session/update` payloads
  plus our own events (user prompt, permission decision, stop reason, errors).
- The transcript shown in the UI is a pure reduction of the log. The log, not the agent, is the source
  of truth for display.
- Reattach with `session/resume` when the agent supports it. Otherwise use `session/load` and suppress
  the replayed updates until the load response arrives. If neither is supported, the session is
  read-only.

## Consequences

- Old sessions can be re-rendered when the renderer improves, because raw updates are kept.
- Sessions are viewable even when the agent is gone.
- The log grows with streaming chunks; compaction (merging chunks of a finished message) can come later
  without changing the model.
