# Vision

## What Agenthesia is

Agenthesia is a native macOS client for coding agents. It is the place where a developer starts agents,
watches them work, answers their questions, reviews their changes and accepts the result.

It is **not** an agent (it has no agent loop of its own) and **not** an IDE. Agents are reached through
the [Agent Client Protocol](https://agentclientprotocol.com), so any ACP-compatible agent works and
agents are interchangeable.

## Who it is for

Developers who delegate real work to coding agents, often several at once, and want to stay in control
of what lands in their branch.

## Where it fits

Existing ACP clients are editors (Zed, JetBrains, Neovim) or web/Electron apps. Agent-first apps exist,
but they are tied to a single agent. Agenthesia is agent-first, agent-agnostic and truly native:
run N agents in isolated worktrees, keep an eye on them, approve what needs approval, review diffs, merge.

## Principles

These principles decide what goes into the product and what does not. When in doubt, they win.

1. **Agent-centric, not an IDE.** The app exists to start agents, watch them, review and accept their
   work. Files, diffs and Markdown are first-class for review. Editing is basic — no autocomplete, no
   LSP; for serious work, *Open in Editor*.
2. **Minimal, yet beautiful.** Show less, but make everything that is shown impeccable.
3. **The platform is the design system.** System controls, typography and materials. Custom chrome
   only where it is clearly better than the system's.
4. **Keyboard-first.** Every action is reachable from the keyboard.
5. **Visible and reversible.** Every agent action is visible. Every change can be reviewed and undone
   before it reaches your branch.
6. **Decisions over settings.** A setting is a decision not made. Add one only when there is no single
   right answer.
7. **Calm by default.** Interrupt the user only when an agent truly needs a human.
8. **Agent-agnostic.** No core feature works with only one agent. Agent-specific behavior goes through
   ACP extensions only.
9. **Speed is a feature.** Instant launch, 60 fps while streaming, modest memory use. A performance
   regression is a bug.

## Non-goals (for now)

- Code editing beyond basic changes; autocomplete; language servers.
- A plugin system. It comes once the core is stable; internal extension points are designed with it
  in mind.
- Platforms other than macOS.

## After 1.0

- Basic editing in the viewer.
- Shared MCP servers configured once for every agent.
- Built-in tools for agents (show, screenshot, ready for review, delegate).
- User-launched background tasks next to agent sessions.
