# 0037. Local agents

- Status: Accepted
- Date: 2026-10-28
- Decider: Project owner
- Issues: #36 (M6)
- Extends: [0036](0036-agent-settings-and-installed-sessions.md)

## Context

ADR-0036 puts local discovery in #36's second slice: a built-in table of known ACP commands, ordinary
Claude and Codex CLIs as suggestions that need an adapter, and a bounded initialize probe. It leaves open
how found commands reach the launch form, where they are kept and when the probe runs. Users already run
agents they installed themselves, such as `opencode` from Homebrew, and today type them into the launch
form's custom command fields for every session.

## Decision

**Local agents are added explicitly.** Settings → Agents lists the known commands found on the login
shell's `PATH`, with their path and ACP arguments; discovery only looks for files and never runs them.
*Add* makes a found command a local agent, and *Add Custom…* adds any command with a name, an executable
and arguments. Local agents appear in the launch form's agent picker after the installed versions, and the
custom command fields stay for one-off commands. A found command is recorded with the path where it was
found, not with its symlink target, so a package manager upgrade behind the same link keeps working.

**Stored in `UserDefaults`.** The list of local agents is configuration, like the editor choice, and is
kept as a small Codable array: ID, name, executable, arguments and the registry ID of a known command.
Removing a local agent only removes it from the list. A session with a local agent records a manual
`agent_install` row as before, so its history and Continue do not depend on the list.

**Check on request.** *Check* launches a command in an empty temporary directory with the login shell's
environment, sends ACP `initialize`, then closes the connection and terminates the process group. It is
bounded by a timeout and creates no session. It shows the agent's name and version, the protocol version
and the sign-in methods it offers; a successful check does not mean the user is signed in. The picker does
not depend on the result: a session sends its own `initialize`.

**Suggestions for ordinary CLIs.** A `claude` or `codex` CLI on `PATH` does not speak ACP. Settings names
the registry adapter it needs (Claude Agent, Codex) and offers to install it, unless that adapter is
installed or found already.

## Alternatives

- **Offer found commands in the picker directly:** nothing to store, but every name collision on `PATH`
  appears as an agent and cannot be dismissed. Rejected by the owner.
- **Only fill the custom command fields:** no new state, but an extra step for every session. Rejected.
- **A table in the history database:** transactional, but it mixes configuration with append-only history
  and needs an irreversible migration. Rejected for `UserDefaults`.
- **Probe automatically on discovery, or gate the picker on a passed check:** discovery would start
  programs without being asked, and a gate adds a mandatory step while the check itself still runs the
  program. Rejected.

## Consequences

AgentRuntime gains the table and a `PATH` lookup; AgenthesiaCore gains the probe and the stored list in
`AgentCatalog`. The table needs updates as agents rename commands or flags, and a known name can belong to
another program: on this machine `kimi` is Moonshot's Kimi Code, not the registry's Kimi CLI, which is
what *Check* is for. Local agents are not versioned or leased: Agenthesia does not own their files.
