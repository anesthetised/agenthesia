# 0015. Agent terminals

- Status: Accepted
- Date: 2026-10-11
- Decider: Project owner
- Scope: ACP v1 `terminal/*` (#30) and terminal output in tool call cards (#31); complements
  ADR-0003, ADR-0004, ADR-0009 and ADR-0014.

## Context

ADR-0009 offers `terminal/*` so that agents run commands in the client. The wire types, the
`ACP.TerminalProvider` protocol and the adapter routing exist, but nothing implements them, so the
capability is not advertised. The protocol requires `terminal/create` to return an id immediately,
retained output to be truncated from the start at a character boundary when it exceeds
`outputByteLimit`, `terminal/release` to kill a running command and invalidate the id, and an embedded
terminal's output to stay visible after release. It does not say whether the command runs through a
shell. Terminal output is not part of `session/update`, so the event log does not record it.

## Decision

**Processes.** Each terminal runs its command in a pseudo-terminal, in a new session and process group
with the PTY as controlling terminal. The PTY process lives in `AgentRuntime` next to `AgentProcess` and
shares its process-group termination: SIGTERM, then SIGKILL after a grace period. The command and
arguments are executed directly, without an implicit shell; `command` is resolved through the session
environment's `PATH`. The environment is the resolved login-shell environment, then the request's
`env`, with `TERM=xterm-256color` and `PAGER=cat`/`GIT_PAGER=cat` so that pagers do not wait for input.
Nothing is written to the PTY's input; a command waiting for input runs until the agent kills or
releases it.

**Output.** Raw PTY bytes are retained in a bounded buffer of at most 1 MiB, dropping the oldest bytes.
`terminal/output` returns text derived from those bytes: escape sequences removed, CRLF normalized, and
a carriage return inside a line keeping only the text after it. That text is truncated from the start
at a character boundary to the agent's `outputByteLimit`, capped at 1 MiB, and `truncated` reports any
loss. The UI renders the raw bytes, so colors survive in tool call cards.

**ACP semantics.** A Core `SessionTerminals` provider, modeled on `SessionFileSystem`, owns terminal ids
and per-session state. `cwd` defaults to the session's working directory and must be absolute and,
after resolving symlinks, inside the session's roots — the same roots as the filesystem capability.
This is a guard against accidental use outside the worktree, not a sandbox (ADR-0009). There is no
limit on the number of terminals per session. `terminal/kill` stops the process group and keeps the
output; `terminal/release` kills if needed, then invalidates the id. The capability is advertised only
for live sessions served by `SessionTerminals`.

**Lifecycle.** Terminals belong to their session's window (ADR-0014). Closing the session stops
accepting `terminal/*`, kills every running terminal, and waits for all of them to exit before the
controller finishes closing.

**History.** When a terminal's process exits — on its own, by kill, by release or by session close —
one event records the terminal id, command, arguments, cwd, exit status and the last 64 KiB of raw
output, marked if truncated. The live window reads output from `SessionTerminals`; restored sessions
render the recorded snapshot in the tool call card that references the terminal id.

## Alternatives

- **Pipes without a TTY:** plain output and stdin from `/dev/null`, so nothing waits for input. Tools
  behave differently than in the user's terminal, colors are lost, and terminal authentication (#32)
  needs a PTY anyway. Rejected.
- **PTY with a headless terminal emulator for agent text:** the most faithful text (like Zed), but moves
  SwiftTerm below the UI layer. Revisit if escape removal proves insufficient for real agents.
- **PTY in `Workspace`:** matched the earlier module table, but would duplicate process-group
  termination or add a `Workspace` → `AgentRuntime` dependency. Rejected.
- **Streaming output chunks to the event log:** exact replay of progress, at the cost of many writes for
  noisy commands. **Not saving output:** restored cards would show no output. Both rejected.

## Consequences

Agents see the same tools and environment as in the user's terminal. Escape removal is a heuristic:
full-screen programs and cursor movement produce imperfect agent text. A command that reads from stdin
hangs until killed. Output beyond 1 MiB, and beyond 64 KiB in history, is lost and marked as such.
Terminals cannot outlive their window; moving a command to the background (#67) needs a later decision.
Whether agents send a full command line in `command` without `args` must be checked against real
agents before the capability ships; supporting that would require a separate decision about shells.
