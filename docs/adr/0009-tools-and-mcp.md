# 0009. Tools and MCP

- Status: Accepted; original MCP scope restored by [0012](0012-defer-cross-agent-memory.md),
  superseding the amendment in [0011](0011-cross-agent-memory.md)
- Date: 2026-10-05

## Context

There are three ways tools reach an agent:

1. The agent's own MCP configuration (`.mcp.json`, `~/.claude.json`, Codex config), which the agent
   loads by itself.
2. `mcpServers` passed by the client in `session/new` (stdio is mandatory for agents; http/sse
   depending on agent capabilities).
3. MCP over ACP (`mcp/message`), which is unstable.

In ACP v1 the client also offers capabilities that replace agent tools: `fs/*`, `terminal/*` and
`elicitation`.

## Decision

- **Never touch the agent's own MCP configuration.**
- **MVP:**
  - offer `fs/*`: we see every write (live diffs, changed files) and enforce a path policy — access only
    inside the session's `cwd` and `additionalDirectories`, an error otherwise;
  - offer `terminal/*` (v1);
  - offer `elicitation`, rendered as native forms;
  - pass no `mcpServers`.
- **After the MVP — shared MCP servers:** configured once in Agenthesia, passed to every agent through
  `session/new`, secrets in the Keychain. The policy for duplicates with the agent's own configuration
  will be a separate ADR.
- **After the MVP — built-in `agenthesia` MCP server:** a stdio helper inside the app bundle that talks to
  the app over a unix socket or XPC. Tools:
  - `show` — open a file or diff in the viewer at a given line;
  - `screenshot` — capture a window or the Simulator via ScreenCaptureKit (requires the Screen
    Recording permission);
  - `ready_for_review` — summarize the work and open the review view;
  - `delegate` — start a session with another agent or in another worktree and return its result.
- `mcp/message` is not used while it is unstable.

## Consequences

- Shared MCP servers make "configure once, works with every agent" possible, in line with principle 8.
- Every built-in tool call goes through the agent's normal permission flow and is visible in the
  transcript.
- In ACP v2 `fs/*` and `terminal/*` disappear; FSEvents remains the source of truth for changed files.
