# 0004. Agent runtime

- Status: Accepted
- Date: 2026-10-05

## Context

Agents are installed from the [ACP Registry](https://agentclientprotocol.com/get-started/registry). Each
entry is distributed as `binary` (archive per platform, optional sha256), `npx` or `uvx`. The most
important agents — Claude (`claude-acp`), Codex (`codex-acp`) and Gemini CLI — are npm packages and
need Node.js 22 or later. GUI apps launched from Finder do not inherit the user's shell `PATH`, so tools
installed via nvm, Homebrew and the like are invisible to them.

## Decision

- **One agent process per session.** A crash affects only its own session; each session has its own
  environment and working directory (its worktree).
- **Managed Node.** The app downloads the official Node.js LTS build for darwin-arm64 into
  `~/Library/Application Support/Agenthesia/Runtimes`, verified against `SHASUMS256.txt`. It never relies
  on a system Node.
- **Installs are pinned and local.** npm agents are installed with `npm install --prefix` at the exact
  registry version into `Application Support/Agenthesia/Agents/<id>/<version>`; no `npx` resolution at
  launch. Binary agents are downloaded, verified (sha256 when present) and extracted. `uvx` agents are
  shown as unsupported for now.
- **Environment.** The user's login-shell environment is resolved once (`$SHELL -l -i -c 'env -0'`,
  with markers and a timeout, including fish) and used for agent processes and terminals, so agents see
  the same tools as in the user's terminal.
- **Lifecycle.** Agents run in their own process group; shutdown is SIGTERM, then SIGKILL after a grace
  period. stderr goes to a ring buffer shown in the session's log view.

## Consequences

- One-click install works on a clean machine, with predictable versions.
- Memory cost: roughly 100–200 MB per Node-based session. Acceptable for a handful of parallel sessions.
- We own updating the Node runtime and the installed agents.
