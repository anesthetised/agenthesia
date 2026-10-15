# 0016. Agent-reported command output

- Status: Accepted
- Date: 2026-10-15
- Decider: Project owner
- Supersedes in part: [0015](0015-agent-terminals.md) (ACP semantics, lifecycle and history are deferred)
- Scope: command output in tool call cards (#31); ACP v1 `terminal/*` (#30)

## Context

ADR-0015 assumed that agents run commands through the client's `terminal/*`. The agents Agenthesia
targets do not:

- `claude-agent-acp` runs Bash itself. A client that declares `clientCapabilities._meta`
  `terminal_output` or `terminal_output_delta` gets the command's output once, when it finishes, in
  tool call `_meta`; any other client gets it as text `content`.
- `codex-acp` runs commands itself and streams output in tool call `_meta`. A client that declares
  `terminal_output_delta`, or declares nothing, gets appended chunks for every command; a client that
  declares `terminal_output` (Zed) gets chunks only for commands shown as a terminal.
- Gemini CLI's ACP integration does not call `terminal/create`.

Both adapters use the same keys on `tool_call` and `tool_call_update`: `terminal_info` (`terminal_id`,
`cwd`) announces a terminal that the tool call's `content` references, `terminal_output` or
`terminal_output_delta` (`terminal_id`, `data`) carries output to append, and `terminal_exit`
(`terminal_id`, `exit_code`, `signal`) marks the end. ACP v2 drops client-side `terminal/*` and
standardizes this as display-only terminals (`terminal_update`, `terminal_output_chunk`); both
adapters already translate their keys to it.

Agenthesia already receives Codex's chunks and records them in the event log, but `ToolCall.apply`
replaces `meta` on every update, so only the last chunk survives, and cards show a terminal
placeholder.

## Decision

**Capability.** The v1 adapter declares `clientCapabilities._meta.terminal_output_delta = true`, the
one key whose semantics both adapters agree on: every chunk is appended. `terminal: true` stays
unadvertised.

**Transcript.** The transcript reducer accumulates on each tool call the `data` of the
`terminal_output_delta` and `terminal_output` it carries, in arrival order, and the exit status from
`terminal_exit`. Output belongs to the tool call rather than to a terminal reference: Codex also
streams output of read, search and list commands, which have no `terminal_info` and no terminal
`content`. Chunks are kept out of the tool call's `meta`. Retained output is bounded at 1 MiB per tool
call, dropping the oldest data and marking the loss.

**Rendering.** A tool call card shows its output, in place of the terminal placeholder, as text
derived with `TerminalText` (escape sequences removed, carriage returns collapsed) in a monospaced
block that, collapsed, shows the last lines; and the exit status, if reported. The text is derived
when the card is rendered, not per chunk. Cards do not embed a terminal emulator.

**History.** Chunks arrive in `session/update`, which the event log records verbatim (ADR-0005), so
a restored session replays them through the same reducer. No separate terminal event is written.

**ACP `terminal/*`.** `SessionTerminals`, the capability, and ADR-0015's ACP semantics, lifecycle
and history sections are deferred until an agent Agenthesia supports needs them. ADR-0015's
processes and output sections stand: `TerminalProcess` and `TerminalText` remain in `AgentRuntime`,
for terminal authentication (#32) and for `terminal/*` if it is revived.

## Alternatives

- **Implement `terminal/*` as ADR-0015 decided:** spec completeness, but no supported agent calls it,
  and ACP v2 removes it. Deferred.
- **Declare `terminal_output` (Zed's key):** the adapters document it differently (Claude as a
  snapshot, Codex as a chunk to append), and Codex then sends read, search and list output as text
  `content` instead, so cards would handle two shapes. Rejected.
- **SwiftTerm in every card:** keeps colors and cursor movement, but adds an emulator view per command
  to a transcript table, and the agents' output is mostly plain text. Rejected for cards; SwiftTerm
  still arrives with terminal authentication (#32). Color from SGR sequences can be added to the text
  rendering later.
- **Keep showing text `content` only (declare nothing):** Claude's output already arrives that way,
  but Codex's chunks keep being lost. Rejected.

## Consequences

Command output appears in cards for Claude and Codex, live for Codex and at completion for Claude,
and survives restore without new persistence. Noisy commands produce many `session/update` events;
this already happens with Codex today. Colors are lost in cards. A full-screen program's output is
approximated. The keys are a convention between adapters, not ACP v1; ACP v2 support maps its
terminal updates onto the same transcript model. Moving a command to the background (#67) and the
background processes panel (#61) assumed client-run terminals; with agents running commands
themselves, they need agent support and a later decision.
