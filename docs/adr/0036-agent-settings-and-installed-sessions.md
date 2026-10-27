# 0036. Agent settings and sessions of installed agents

- Status: Accepted
- Date: 2026-10-27
- Decider: Project owner
- Issues: #36 (M6)
- Extends: [0034](0034-agent-installs-with-user-runtimes.md), [0035](0035-installer-storage-and-script-policy.md)

## Context

#35 installs registry agents into private versioned directories and hands out launch leases, but nothing
in the app uses them: the launch form takes an executable and arguments, and saved sessions refer to an
`agent_install` row that holds only a command. #36 adds the agent browser, local discovery and
pre-session sign-in. It needs a place in the app, a link from history to an installed version, and an
order of work.

T3 Code, our UI reference, manages providers in Settings: a card per configured provider with its
status, update and sign-in, and an *Add provider* dialog that offers built-in drivers, a search of the
ACP Registry and a local command.

## Decision

**Settings → Agents.** Agents are managed in a new Agents tab of Settings: the installed agents with
their version, prerequisites, Update, Remove and (later) Sign In, and the registry catalog with search,
source and license shown before installation. Node/npm diagnostics and Check Again appear where an npm
agent needs them. The launch form replaces the executable field with an agent picker: installed agents,
newest version first, plus a custom command that keeps today's executable and argument fields.

**One history row per installed version.** Migration `v4-agent-install-installation` adds a nullable
`installationID` to `agent_install`. Starting a session with an installed agent creates (or reuses) a row
for that exact installation, so a saved session keeps the version it ran with; an update installs a new
version and new sessions use it. Rows without an installation ID are manual commands, as before.

**Leases follow the session.** Starting or continuing a session with an installed agent acquires its
installation's lease before any worktree is created and holds it until the agent's processes, including
a sign-in terminal, have exited and the session has ended or failed. Chat and terminal sign-in launch the
leased command, so they use the same installation and runtime. If the version was removed, Continue
fails with a message that names it; the user installs it again or starts a new session.

**Short installer critical sections.** The installer's exclusive operation lock covers only synchronous
steps (listing, validation, publication, removal), never a download, an npm run or a shell capture.
Installing one agent therefore does not block starting sessions with another, and parallel starts with
the same agent do not refuse each other. A lease protects its version from removal across those gaps.

**Three slices.** 1) Agents tab: registry, install, update, remove, prerequisites and Check Again; the
agent picker; leases for start and Continue. 2) Local discovery from a built-in table of known ACP
commands (registry ID, executable, ACP arguments), plus ordinary `claude`/`codex` CLIs as suggestions
that need an adapter, and the bounded initialize probe. 3) Sign-in before any session. Each slice is a
pull request with its own verification in the built app.

## Alternatives

- **A separate Agents window:** more room for the catalog, but another window route and agent settings
  split across two places. Rejected.
- **Install from the launch form:** shortest first run, but it overloads the form and leaves no place for
  updates and removal. Rejected.
- **Reuse the installation UUID as the row ID:** no migration, but the link is implicit and a manual row
  can be mistaken for an installation. Rejected.
- **A separate registry table:** more flexible, but another table and join for one field. Rejected.
- **Discovery from registry command names only:** nothing hard-coded, but npm agents and their ACP flags
  would not be found. Rejected for a small built-in table that ships with the app.

## Consequences

The `agent_install` table grows one column; Persistence stays independent of AgentRuntime and stores the
ID only. AgenthesiaCore acquires and releases leases, so `SessionLibrary` gains an installer seam for tests.
Removing an installation used by saved sessions is allowed when no session runs it; those sessions show
why they cannot continue. The built-in discovery table needs updates as agents change their commands.
