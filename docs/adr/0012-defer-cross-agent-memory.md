# 0012. Defer cross-agent memory until after the MVP

- Status: Accepted
- Date: 2026-10-06
- Supersedes: [0011](0011-cross-agent-memory.md)
- Restores the original MCP scope of [0009](0009-tools-and-mcp.md)

## Context

ADR-0011 moved cross-agent memory and the built-in MCP server into the MVP. This adds a stdio helper,
IPC, file storage, a search index, file watching and a memory browser before the core session and review
workflow is complete. Exposing memory tools also does not guarantee that every agent will use them.

Keeping memory in the MVP would test knowledge sharing earlier, but would delay validating the primary
workflow: launch an agent, handle permissions, review its changes, accept or discard the work, and
restore the session after an app restart or agent crash. We choose to complete that workflow first.

## Decision

- **Cross-agent memory is outside the MVP.** Defer its storage, indexing, tools, context index and UI.
- **The built-in `agenthesia` MCP server and its IPC infrastructure remain after the MVP**, as originally
  decided in ADR-0009. The MVP passes no `mcpServers` and leaves agents' own MCP and memory configuration
  untouched.
- Prioritize reliable session lifecycle, permissions, worktree review and acceptance, and history
  restoration. Memory is not a prerequisite for shipping that workflow.
- Revisit memory after the core workflow is usable end to end. ADR-0011 remains a historical design
  reference; validate how the supported agents discover and use memory before committing to its
  implementation details. No post-MVP release date is set.

## Consequences

- The MVP has fewer components to build, test and maintain, and its core behavior can be validated sooner.
- Agenthesia does not provide shared memory in the MVP; agents continue to use their own memory features.
- Cross-agent knowledge sharing remains a product direction, with its value and integration to be tested
  when that milestone starts.
