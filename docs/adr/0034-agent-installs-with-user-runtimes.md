# 0034. Agent installs with user-provided runtimes

- Status: Accepted
- Date: 2026-10-27
- Supersedes: the managed Node and installation decisions of [0004](0004-agent-runtime.md)
- Issues: #33, #34, #35, #36 (M6)

## Context

ADR-0004 planned a downloaded Node runtime so npm agents would work on a clean Mac. This makes
Agenthesia responsible for another runtime's distribution and updates before the registry workflow
has shipped. Restricting installation to binary distributions would reduce that work but leave
important ACP adapters to manual setup: the registry currently distributes Claude and Codex adapters
through npm. A native `claude` or `codex` installation does not itself supply the ACP adapter or Node.

T3 Code's registry installer uses npm or uv from the host environment, installs exact package versions
into application-owned directories, and launches installed commands directly. This is a useful boundary
for Agenthesia too: manage agent installations, use the developer's runtimes. We already resolve the
interactive login-shell environment for agents launched from Finder.

## Decision

**Installation scope.** M6 supports registry `binary` and `npx` distributions, preferring a binary
for the current platform when both exist. `npx` describes the registry distribution; it does not mean
running npx at session startup. `uvx` remains visibly unsupported in M6. Locally installed ACP commands
remain usable regardless of the runtime or package manager the user installed them with.

**User-provided Node and npm.** Discover both through the login-shell environment. Check that they
execute successfully, satisfy the selected package's runtime requirements, and use a consistent
toolchain for installation and launch. Do not install, upgrade or remove Node, npm, Homebrew or version
managers. A missing, incompatible or broken tool has an actionable message, installation instructions
and a **Check Again** action. The app promises to explain prerequisites, not to install every agent
on a clean Mac.

**Refresh and launch.** Check Again captures a fresh shell environment and repeats discovery instead
of reusing `ShellEnvironment`'s lifetime cache. Concurrent refreshes share work, and an older in-flight
capture must not overwrite a refreshed result. Running sessions retain their launch environment;
refresh applies to subsequent operations. Installation and launch use the selected runtime explicitly
enough that changing a project directory or a version-manager shim cannot silently select a different
Node. Before a later launch, detect an unavailable or incompatible runtime and offer recovery.

**Application-owned installs.** Install an exact registry package version in a private npm prefix
under `Application Support/Agenthesia/Agents/<id>/<version>`. Use a local package manifest and retain
the generated lockfile so reinstalling that installation can preserve resolved dependencies; pinning
only the top-level package does not fix transitive versions. Record the runtime used and installation
metadata. Never modify the user's global packages or package-manager configuration. Launch the
installed command directly with its declared arguments and environment; no network resolution at
session startup. Authentication uses the same installation and runtime as chat (ADR-0033).

Binary distributions are downloaded for the current platform and verified against their declared
SHA-256 when present, with safe archive extraction and executable validation before use. Installation
must finish and validate before becoming available; cancellation or failure must not replace a working
installation. An update is explicit and installs a separate version, keeping the previous working
version available. Existing sessions keep their version. Remove only application-owned installation
files, never the user's credentials, external CLI or runtime, and do not remove files in use.

**Local discovery.** Offer known installed ACP commands from the resolved environment, with their
paths, alongside manual executable and argument entry. Discovery does not start agents or create
sessions; after the user chooses a command, validate ACP with a bounded initialize handshake, clean up
the probe process, and do not claim that initialization proves authentication. Unsupported commands or
protocol versions produce an actionable result. Use ADR-0033's authentication flow for actual sessions.

Finding an ordinary Claude or Codex CLI is useful as a setup suggestion, not proof of ACP readiness.
Connect through the corresponding adapter. Reusing an existing CLI requires a supported executable
override and verified version compatibility; otherwise use the adapter's supported distribution rather
than silently substituting an arbitrary CLI. Adapter dependencies can include their own CLI, so finding
an installed CLI does not promise that no additional agent files will be downloaded. Keep these launch
details in agent setup; Core continues to communicate only through ACP (ADR-0001).

**Dependencies and distribution.** The GPLv3-compatible dependency rule continues to apply to code
linked into or bundled with Agenthesia. User-selected agents, adapters and their dependencies are
separately installed external programs, run through ACP under their own terms; show their source and
license before installation. This decision does not approve embedding Claude Agent SDK or other
proprietary libraries in the app, repackaging agents, or distributing our own standalone adapters.

## Alternatives

- **Managed Node (ADR-0004):** consistent runtime and easier clean-machine setup, but we own runtime
  delivery, updates and support. Revisit only if missing runtimes materially obstruct adoption.
- **Binary-only registry installs:** a smaller installer, but shifts Claude/Codex adapter setup to
  users. Rejected as the default M6 scope.
- **Our own standalone adapter builds:** remove the user's Node prerequisite but add packaging,
  compatibility and licensing responsibilities. Outside M6.
- **Global npm installs or npx at launch:** can change user tools or resolve dependencies when starting
  a session. Rejected in favor of isolated, installed versions.

## Consequences

M6 must test missing and incompatible runtimes, shell refresh, version-manager changes, failed and
cancelled installations, retained versions and ACP readiness. A developer can break a working setup by
changing their runtime; recovery must explain the failure without mutating that runtime. Binary agents
and already usable local commands remain available when npm prerequisites are missing.

The process-per-session, login-shell environment and process-group lifecycle decisions of ADR-0004
remain in force. This ADR records the accepted scope; installers and discovery are not implemented yet.

## References

- [T3 registry installation at inspected revision 71df573f2d](https://github.com/pingdotgg/t3code/blob/71df573f2d/packages/provider-acp-registry/src/server/AcpRegistrySupport.ts)
- [ACP Registry](https://agentclientprotocol.com/get-started/registry)
- [Codex adapter executable override and compatibility](https://github.com/agentclientprotocol/codex-acp/blob/v2.3.0/readme-dev.md)
- [Claude adapter dependencies and Node requirement](https://github.com/agentclientprotocol/claude-agent-acp/blob/v0.97.0/package.json)
- [Claude SDK license](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/LICENSE.md)
