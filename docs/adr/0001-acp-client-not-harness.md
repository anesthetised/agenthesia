# 0001. ACP client, not an agent harness

- Status: Accepted
- Date: 2026-10-05

## Context

An "AI harness" can mean two things: an agent (model loop, tools, prompts, context management) or a
front end for agents. Building our own agent means competing with Claude Code, Codex and others on
agent quality, and paying for API access, because consumer subscriptions are generally only usable
through the vendors' official tools. The Agent Client Protocol (ACP) lets any client drive any
compliant agent, and the official adapters keep subscription sign-in working.

## Decision

Agenthesia is an ACP client. It has no agent loop of its own. It competes on user experience:
orchestrating sessions, permissions, review, isolation and native polish.

## Consequences

- Agents improve without our involvement, and users keep their subscriptions.
- We are limited to what ACP exposes. Agent-specific features are visible only when they are expressed
  through the protocol or its extensions.
- We depend on ACP's evolution and must track it (see [0003](0003-own-acp-implementation.md)).
