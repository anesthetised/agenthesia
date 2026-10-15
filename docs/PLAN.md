# Work plan

The near-term order of work, for agents and humans picking up the next task. Milestones and issues on
GitHub stay the source of truth for scope; this file records order, dependencies, and the pitfalls known
so far. Update it when a step lands or the order changes.

Every step follows [AGENTS.md](../AGENTS.md): issue → branch → tests and docs → pull request after the
owner's approval. Architectural choices are presented to the owner as options with a recommendation
before implementation.

## State (2026-10-15)

- Live sessions run end-to-end in one window ([ADR-0014](adr/0014-window-bound-live-sessions.md)): tool call
  cards, permission requests, scoped filesystem, agent-reported command output
  ([ADR-0016](adr/0016-agent-reported-command-output.md)).
- Saved history opens read-only; it does not reconnect to the agent.
- Client-side `terminal/*` is deferred (#104), so the rest of M5 waits.

## Next steps

| # | Issue | Depends on | Model and effort |
|---|-------|------------|------------------|
| 1 | #25 Session resume and load | — | Opus, high |
| 2 | #20 DiffView | — | Opus, medium |
| 3 | #18 Composer with attachments and slash commands | — | Opus, high |
| 4 | #23 Config options picker | #18 | Opus, medium |
| 5 | #65 Prompt queue and steering | #18 | Opus, high |
| 6 | #24 Native elicitation forms | — | Opus, medium |

Then M4 (Files), M7 (Parallel sessions), M8 (Worktrees). Small independent chores such as #73 (CI with
Xcode 27) fit Sonnet at medium effort.

### 1. Session resume and load (#25)

- The protocol side exists: `AgentConnection.reopenSession` tries `session/resume`, then `session/load`
  with replayed updates suppressed in the v1 adapter, and returns `.unavailable` otherwise.
- Missing: Core and UI. `SessionController.restore` only reduces the log and sets `.readOnly`;
  `LiveSession.launch` always creates a new workspace and calls `newSession`.
- Decide with the owner before coding: what triggers reconnecting, what happens to a turn or permission
  request left unfinished by a crash, how to keep one live owner per saved session, and what to do when
  the session's worktree is gone. ADR-0014 states that history does not reconnect, so the outcome needs a
  new ADR.
- The session record does not store additional directories; a reopened session gets none unless that
  changes.

### 2. DiffView (#20)

- Tool call cards show a placeholder for diff content (`LiveTranscript.swift`, `case .diff`).
- Prefer the standard library (`CollectionDifference`) over a dependency. Word-level highlights on large
  files are performance-sensitive: add a case to `rendering-bench` and agree on the run with the owner.

### 3–5. Composer, config options, prompt queue (#18, #23, #65)

- #18 is the base for #23 and #65. The behavior of #65 is fixed by
  [ADR-0010](adr/0010-prompt-queue-and-steering.md); queue entries are persisted in the event log.
- `AgentProfile.steering` already reports whether the agent supports injection.

### 6. Elicitation forms (#24)

- The adapter is created with `elicitation: false` in `LiveSession`; the delegate's default declines.
  See [ADR-0009](adr/0009-tools-and-mcp.md).

## Open research

Not scheduled, pick up when they block something: #77, #78, #83 (transcript and highlighting hitches),
#97 (streaming performance), #98 (raw-notification contract), #91 (`posix_spawn` lifecycle).
