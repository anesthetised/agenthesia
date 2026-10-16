# 0019. Session config controls

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Scope: config options picker (#23); builds on ADR-0003 and ADR-0005

## Context

The agent exposes session settings through config options. The ACP adapter already normalizes legacy
modes into these options. The composer needs controls without introducing agent-specific settings or
ambiguous changes to a running turn.

## Decision

- Render supported options in the composer toolbar with native pickers/menus and toggles. Use the
  agent's names, choices and grouping; hide unknown option types.
- Allow changes only while the session is idle. Saved history displays the recorded settings read-only.
- Treat the agent's returned settings as authoritative. Show a change as accepted only after the
  response has been committed to the event log; keep the last confirmed values on request failure
  and show the error. Agent notifications continue through the existing ordered recording path.
- Keep coordination in `SessionController`, with config state reduced from the existing event log.
  Legacy-mode fallback remains in the ACP adapter; the UI does not branch on protocol versions.

## Alternatives

- **Optimistic selection:** faster visual feedback, but requires rollback and can display a setting
  the agent rejected. Rejected in favor of confirmed state with pending feedback.
- **Change settings during a turn:** more flexible, but the point of application depends on the agent.
  Deferred; the first implementation changes settings between turns.

## Consequences

Users see the configuration the agent has confirmed. Config requests and prompt submission must be
coordinated so a new turn cannot overtake an in-flight setting change. No new settings store or
session manager is needed.
