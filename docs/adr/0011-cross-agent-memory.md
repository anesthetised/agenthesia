# 0011. Cross-agent memory

- Status: Superseded by [0012](0012-defer-cross-agent-memory.md)
- Date: 2026-10-06
- Amends: [0009](0009-tools-and-mcp.md) (the built-in MCP server moves into the MVP)

## Context

Agents keep their own memory (`CLAUDE.md`, Claude's memory directory, Codex memories), and none of it is
visible to other agents. With interchangeable agents (principle 8), knowledge learned in a Claude session
should be available to the next Codex session on the same project.

A client cannot change an agent's loop, but it can give every agent tools: stdio MCP servers passed in
`session/new` must be supported by all ACP agents. MCP servers may also provide `instructions`, which some
agents (Claude Code) add to their context.

## Decision

- **Memory is part of the MVP**, served by the built-in `agenthesia` MCP server. The server's
  infrastructure (stdio helper in the app bundle, IPC to the app) moves into the MVP; its other tools
  (`show`, `screenshot`, `ready_for_review`, `delegate`) stay after it.
- **Storage:** one memory per Markdown file with front matter (name, description, scope, timestamps) in
  `~/.agenthesia/memory/global/` and `~/.agenthesia/memory/<project>/`. Files are the source of truth;
  a SQLite FTS5 index is derived from them and follows hand edits through an FSEvents watcher.
- **Scopes:** `global` for preferences that apply everywhere, `project` for repository-specific knowledge.
- **Tools:** `memory_search`, `memory_get`, `memory_save`, `memory_delete`. Calls go through the agent's
  permission flow and appear in the transcript.
- **Index in context:** a compact index (one line per memory) is exposed in the MCP server's
  `instructions`, within a fixed size budget.
- **Every session gets the server**, for every agent, in `session/new`, `session/resume` and
  `session/load`.
- **Memories are visible and editable** in a memory browser, including which agent and session wrote them.

## Consequences

- Knowledge carries over between agents and sessions without agents knowing about Agenthesia.
- Plain files are readable, editable by hand, can be kept in git and survive reinstalling the app.
- Agents that ignore MCP `instructions` only see memory when they call the tools; the index makes the
  common case cheap where it is supported.
- Memory is local to the machine; syncing is out of scope.
