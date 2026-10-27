# 0035. Installer storage and npm script policy

- Status: Accepted
- Date: 2026-10-27
- Issues: #35, #36 (M6)
- Extends: [0034](0034-agent-installs-with-user-runtimes.md)

## Context

The installation scope is accepted in ADR-0034. Its implementation needs a home for version metadata,
an archive reader, and an explicit npm lifecycle-script policy. The owner accepted these boundaries
before implementation.

## Decision

Keep the installer and its versioned metadata in `AgentRuntime`. Store metadata beside each private
installation so validation and publication use the same version directory. Connecting those installations
to the app's windows, session history and setup UI belongs to #36; the existing manual command records
do not need a schema migration in #35.

Use macOS's system libarchive through a small C module. Copy validated regular files and directories
from tar/zip archives; refuse links, special files, escaping paths and excessive expansion. No archive
extraction shell command or additional third-party runtime is bundled.

Run npm with lifecycle scripts disabled. Installations needing those scripts must fail with an
actionable explanation rather than enabling scripts on retry. Preserve the package manifest and lockfile,
and keep npm's cache and configuration inside the operation's private directory. Do not alter global
packages or the user's npm configuration.

## Alternatives

- Store metadata in the history database: couples runtime installation to Core/Persistence before the
  browser and history integration exist.
- Extract with a command-line archive tool: harder to inspect each entry and enforce limits without
  relying on a human-readable listing.
- Enable npm lifecycle scripts: supports more packages, but executes package/dependency code during
  setup. The owner chose disabled scripts.

## Consequences

The setup UI must retain an installation's lease throughout sign-in and chat, and release it only
after its processes exit. A working installation and its runtime remain the same for both flows.
Installation validation establishes filesystem and package prerequisites; #36's bounded ACP initialize
probe establishes protocol readiness. Neither check establishes successful authentication.

Some npm packages may install their entrypoint successfully yet require a script-generated dependency
at runtime. Report that failure through setup validation; do not claim every script-dependent package
can be identified without running it.

## References

- [libarchive streaming reader](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read.3)
- [npm install and ignore-scripts](https://docs.npmjs.com/cli/v11/commands/npm-install/)
