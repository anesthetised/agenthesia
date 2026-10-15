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
- Saved history opens read-only; Continue reattaches it to its agent
  ([ADR-0017](adr/0017-continue-saved-sessions.md)).
- Tool call diffs render as unified diffs with word-level highlights (#20); side-by-side is not scheduled.
- Client-side `terminal/*` is deferred (#104), so the rest of M5 waits.

## Next steps

| # | Issue | Depends on | Model and effort |
|---|-------|------------|------------------|
| 1 | #18 Composer with attachments and slash commands | — | Opus, high |
| 2 | #23 Config options picker | #18 | Opus, medium |
| 3 | #65 Prompt queue and steering | #18 | Opus, high |
| 4 | #24 Native elicitation forms | — | Opus, medium |

Then M4 (Files), M7 (Parallel sessions), M8 (Worktrees). Small independent chores such as #73 (CI with
Xcode 27) fit Sonnet at medium effort.

### 1–3. Composer, config options, prompt queue (#18, #23, #65)

- #18 is the base for #23 and #65. The behavior of #65 is fixed by
  [ADR-0010](adr/0010-prompt-queue-and-steering.md); queue entries are persisted in the event log.
- `AgentProfile.steering` already reports whether the agent supports injection.

### 4. Elicitation forms (#24)

- The adapter is created with `elicitation: false` in `LiveSession`; the delegate's default declines.
  See [ADR-0009](adr/0009-tools-and-mcp.md).

## Open research

Not scheduled, pick up when they block something: #77, #78, #83 (transcript and highlighting hitches),
#97 (streaming performance), #98 (raw-notification contract), #91 (`posix_spawn` lifecycle).
